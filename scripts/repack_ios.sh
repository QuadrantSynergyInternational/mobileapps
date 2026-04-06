#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# repack_ios.sh — Repack and resign an iOS IPA with a fresh JS bundle
#
# Usage (local):
#   export REPO=git.example.com/org/repo
#   export REPO_BRANCH=main
#   export RELEASE_REPO=org/release-repo
#   export RELEASE_TAG=v1.0.0-Release-main
#   export PROJECT_ID=my-app
#   export P12_PASSWORD=...
#   export PROVISION_REPO_TOKEN=ghp_...
#   export GH_TOKEN=...
#   chmod +x scripts/repack_ios.sh && ./scripts/repack_ios.sh
#
# Usage (CI — set CI=true, dirs pre-populated by workflow steps):
#   Workflow sets WORK_DIR, SOURCE_DIR, PROVISION_DIR, BUNDLE_OUTPUT_DIR,
#   RELEASE_DOWNLOAD_DIR and calls this script after checkout + yarn install.
#
# Required env vars:
#   RELEASE_REPO          GitHub repo holding the release   (e.g. org/repo)
#   RELEASE_TAG           Release tag to download from      (e.g. v1.0.0-Release-main)
#   PROJECT_ID            Folder name inside ios-provision repo
#   P12_PASSWORD          Password for the .p12 certificate
#   GH_TOKEN              GitHub token (used by gh CLI)
#
# Optional env vars:
#   REPO                  Self-hosted git host+path — required in local mode
#   REPO_BRANCH           Branch to clone            — required in local mode
#   GIT_USERNAME          Git username               — required in local mode
#   GIT_PASSWORD          Git password/token         — required in local mode
#   PROVISION_REPO_TOKEN  Token for ios-provision    — required in local mode
#   PROVISION_FILE        Provision filename without extension (default: $REPO_BRANCH)
#   IPA_FILENAME          IPA glob/filename to download (default: *.ipa)
#   WORK_DIR              Root working dir   (default: /tmp/repack_ios_$$)
#   SOURCE_DIR            Path to cloned source       (default: $WORK_DIR/input)
#   PROVISION_DIR         Path to provision repo      (default: $WORK_DIR/provision)
#   BUNDLE_OUTPUT_DIR     Bundle output dir           (default: $WORK_DIR/bundle_output)
#   RELEASE_DOWNLOAD_DIR  Download dir                (default: $WORK_DIR/release_download)
#   CI                    Set to 'true' to skip clone + install steps
#   SENTRY_AUTH_TOKEN     Sentry auth token  (optional — skip upload if unset)
#   SENTRY_ORG            Sentry org slug    (optional)
#   SENTRY_PROJECT        Sentry project slug (optional)
#   APP_VERSION           Override version string for Sentry release (optional)
#
# macOS-only (requires: security, codesign, zip, gh CLI)
# ---------------------------------------------------------------------------

set -euo pipefail

if [[ "$(uname)" != "Darwin" ]]; then
  echo "❌ This script must be run on macOS."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=repack_common.sh
source "$SCRIPT_DIR/repack_common.sh"

# ── Load .env + defaults ─────────────────────────────────────────────────────
common_load_env

IPA_FILENAME="${IPA_FILENAME:-*.ipa}"
CI="${CI:-false}"
WORK_DIR="${WORK_DIR:-/tmp/repack_ios_$$}"
SOURCE_DIR="${SOURCE_DIR:-$WORK_DIR/input}"
PROVISION_DIR="${PROVISION_DIR:-$WORK_DIR/provision}"
BUNDLE_OUTPUT_DIR="${BUNDLE_OUTPUT_DIR:-$WORK_DIR/bundle_output}"
RELEASE_DOWNLOAD_DIR="${RELEASE_DOWNLOAD_DIR:-$WORK_DIR/release_download}"
PROVISION_FILE="${PROVISION_FILE:-${REPO_BRANCH:-}}"
KEYCHAIN_NAME="repack-$$.keychain"
KEYCHAIN_PASSWORD="tempKeychainPass"

# ── Validate required vars ───────────────────────────────────────────────────
REQUIRED_VARS=(RELEASE_REPO RELEASE_TAG PROJECT_ID P12_PASSWORD GH_TOKEN)
if [[ "$CI" != "true" ]]; then
  REQUIRED_VARS+=(REPO REPO_BRANCH GIT_USERNAME GIT_PASSWORD PROVISION_REPO_TOKEN)
fi
common_validate_vars

if [[ -z "$PROVISION_FILE" ]]; then
  echo "❌ PROVISION_FILE (or REPO_BRANCH) is required to locate .p12 / .mobileprovision."
  exit 1
fi

mkdir -p "$WORK_DIR" "$BUNDLE_OUTPUT_DIR" "$RELEASE_DOWNLOAD_DIR"
echo "🗂️  Work dir:      $WORK_DIR"
echo "📂 Source dir:    $SOURCE_DIR"
echo "🔐 Provision dir: $PROVISION_DIR"
echo "📦 Bundle dir:    $BUNDLE_OUTPUT_DIR"
echo "⬇️  Download dir:  $RELEASE_DOWNLOAD_DIR"

# ── Clone + install (local mode only) ───────────────────────────────────────
# iOS also needs the provision repo cloned locally.
if [[ "$CI" != "true" ]]; then
  common_clone_source

  echo ""
  echo "🔐 Cloning provision repo..."
  git clone --depth=1 --single-branch --branch=main \
    "https://admindevopsqsi:${PROVISION_REPO_TOKEN}@github.com/admindevopsqsi/ios-provision.git" \
    "$PROVISION_DIR"
fi

# ── Resolve provision file paths ────────────────────────────────────────────
P12_PATH="$PROVISION_DIR/$PROJECT_ID/$PROVISION_FILE.p12"
MOBILEPROVISION_PATH="$PROVISION_DIR/$PROJECT_ID/$PROVISION_FILE.mobileprovision"

# ── Load sentry.properties ───────────────────────────────────────────────────
common_load_sentry

# ── Setup keychain ────────────────────────────────────────────────────────────
echo ""
echo "🔑 Setting up keychain..."
ORIGINAL_KEYCHAINS=$(security list-keychains -d user | xargs)

cleanup() {
  echo ""
  echo "🧹 Cleaning up keychain..."
  # shellcheck disable=SC2086
  security list-keychains -d user -s $ORIGINAL_KEYCHAINS 2>/dev/null || true
  security delete-keychain "$KEYCHAIN_NAME" 2>/dev/null || true
}
trap cleanup EXIT

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"
security set-keychain-settings -t 3600 -l "$KEYCHAIN_NAME"

# Add to search list and make default so codesign can find the private key
security list-keychains -d user -s "$KEYCHAIN_NAME" $ORIGINAL_KEYCHAINS
security default-keychain -s "$KEYCHAIN_NAME"

if security import "$P12_PATH" -k "$KEYCHAIN_NAME" \
     -P "$P12_PASSWORD" \
     -T /usr/bin/codesign \
     -T /usr/bin/security \
     -T /usr/bin/productbuild \
     -T /usr/bin/productsign; then
  echo "✅ P12 imported"
else
  echo "❌ P12 import failed"
  exit 1
fi

security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"

# ── Bundle React Native ──────────────────────────────────────────────────────
common_bundle ios

# ── Download release IPA ─────────────────────────────────────────────────────
echo ""
echo "⬇️  Downloading IPA from $RELEASE_REPO@$RELEASE_TAG..."
GH_TOKEN="$GH_TOKEN" gh release download "$RELEASE_TAG" \
  -R "$RELEASE_REPO" \
  -p "*.ipa" \
  -D "$RELEASE_DOWNLOAD_DIR"

# Resolve the downloaded file.
if [[ "$IPA_FILENAME" != *"*"* && "$IPA_FILENAME" != *"?"* ]]; then
  DOWNLOADED_IPA=$(find "$RELEASE_DOWNLOAD_DIR" -maxdepth 1 -name "$IPA_FILENAME" | head -n 1)
  if [[ -z "$DOWNLOADED_IPA" ]]; then
    echo "⚠️  IPA named '$IPA_FILENAME' not found — falling back to first available IPA."
    DOWNLOADED_IPA=$(find "$RELEASE_DOWNLOAD_DIR" -maxdepth 1 -name '*.ipa' | sort | head -n 1)
  fi
else
  DOWNLOADED_IPA=$(find "$RELEASE_DOWNLOAD_DIR" -maxdepth 1 -name '*.ipa' | sort | head -n 1)
fi
if [[ -z "$DOWNLOADED_IPA" ]]; then
  echo "❌ No IPA file found in $RELEASE_DOWNLOAD_DIR after download."
  exit 1
fi
echo "📦 Found IPA: $(basename "$DOWNLOADED_IPA")"

# ── Unpack IPA ───────────────────────────────────────────────────────────────
echo ""
echo "📦 Unpacking IPA..."
mkdir -p "$RELEASE_DOWNLOAD_DIR/unpacked_ipa"
unzip -qo "$DOWNLOADED_IPA" -d "$RELEASE_DOWNLOAD_DIR/unpacked_ipa"

APP_NAME=$(find "$RELEASE_DOWNLOAD_DIR/unpacked_ipa/Payload" -maxdepth 1 -name "*.app" -type d | head -n 1 | xargs basename)
if [[ -z "$APP_NAME" ]]; then
  echo "❌ Could not find .app bundle inside IPA."
  exit 1
fi
echo "📱 Found app bundle: $APP_NAME"

# ── Replace bundle + assets ──────────────────────────────────────────────────
echo "🔄 Replacing main.jsbundle..."
cp "$BUNDLE_OUTPUT_DIR/main.jsbundle" "$RELEASE_DOWNLOAD_DIR/unpacked_ipa/Payload/$APP_NAME/main.jsbundle"

if [ -d "$BUNDLE_OUTPUT_DIR/assets" ]; then
  ASSET_COUNT=$(find "$BUNDLE_OUTPUT_DIR/assets" -type f | wc -l | tr -d ' ')
  echo "🖼️  Syncing $ASSET_COUNT assets..."
  mkdir -p "$RELEASE_DOWNLOAD_DIR/unpacked_ipa/Payload/$APP_NAME/assets"
  cp -R "$BUNDLE_OUTPUT_DIR/assets/." "$RELEASE_DOWNLOAD_DIR/unpacked_ipa/Payload/$APP_NAME/assets/" || true
  
  DEST_COUNT=$(find "$RELEASE_DOWNLOAD_DIR/unpacked_ipa/Payload/$APP_NAME/assets" -type f | wc -l | tr -d ' ')
  echo "  🔍 Verified $DEST_COUNT assets installed in IPA Payload."
else
  echo "⚠️  No 'assets' directory generated by React Native bundler."
fi

# ── Embed provisioning profile ───────────────────────────────────────────────
echo "📋 Embedding provisioning profile..."
cp "$MOBILEPROVISION_PATH" "$RELEASE_DOWNLOAD_DIR/unpacked_ipa/Payload/$APP_NAME/embedded.mobileprovision"

# ── Resign ───────────────────────────────────────────────────────────────────
IDENTITY=$(security find-identity -v -p codesigning "$KEYCHAIN_NAME" \
  | head -1 | grep -o '"[^"]*"' | tr -d '"')
echo "🔑 Signing with identity: $IDENTITY"

# Extract entitlements from the provisioning profile
echo "📜 Extracting entitlements from provisioning profile..."
security cms -D -i "$MOBILEPROVISION_PATH" > "$RELEASE_DOWNLOAD_DIR/provision.plist"
/usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$RELEASE_DOWNLOAD_DIR/provision.plist" > "$RELEASE_DOWNLOAD_DIR/entitlements.plist"

# Remove the old signature to ensure a clean resign
rm -rf "$RELEASE_DOWNLOAD_DIR/unpacked_ipa/Payload/$APP_NAME/_CodeSignature"

/usr/bin/codesign \
  --force \
  --sign "$IDENTITY" \
  --entitlements "$RELEASE_DOWNLOAD_DIR/entitlements.plist" \
  --keychain "$KEYCHAIN_NAME" \
  "$RELEASE_DOWNLOAD_DIR/unpacked_ipa/Payload/$APP_NAME"

# ── Repack ───────────────────────────────────────────────────────────────────
echo "📁 Repacking signed IPA..."
(cd "$RELEASE_DOWNLOAD_DIR/unpacked_ipa" && zip -qry ../resigned-output.ipa Payload)

# ── Generate manifest.plist ───────────────────────────────────────────────────
echo ""
echo "📋 Generating manifest.plist..."
APP_INFO_PLIST="$RELEASE_DOWNLOAD_DIR/unpacked_ipa/Payload/$APP_NAME/Info.plist"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_INFO_PLIST" 2>/dev/null || echo "")
DISPLAY_NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleDisplayName" "$APP_INFO_PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Print :CFBundleName" "$APP_INFO_PLIST" 2>/dev/null \
  || echo "$APP_NAME")

if [[ -n "$BUNDLE_ID" ]]; then
  cat > "$RELEASE_DOWNLOAD_DIR/manifest.plist" <<'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>items</key>
	<array>
		<dict>
			<key>assets</key>
			<array>
				<dict>
					<key>kind</key>
					<string>software-package</string>
					<key>url</key>
					<string>{IPA_URL}</string>
				</dict>
				<dict>
					<key>kind</key>
					<string>display-image</string>
					<key>url</key>
					<string>{DISPLAY_IMAGE}</string>
				</dict>
				<dict>
					<key>kind</key>
					<string>full-size-image</string>
					<key>url</key>
					<string>{FULLSIZE_IMAGE}</string>
				</dict>
			</array>
			<key>metadata</key>
			<dict>
				<key>bundle-identifier</key>
				<string>BUNDLE_ID_PLACEHOLDER</string>
				<key>bundle-version</key>
				<string>APP_VERSION_PLACEHOLDER</string>
				<key>kind</key>
				<string>software</string>
				<key>platform-identifier</key>
				<string>com.apple.platform.iphoneos</string>
				<key>title</key>
				<string>DISPLAY_NAME_PLACEHOLDER</string>
			</dict>
		</dict>
	</array>
</dict>
</plist>
PLIST_EOF
  sed -i '' \
    -e "s|BUNDLE_ID_PLACEHOLDER|$BUNDLE_ID|g" \
    -e "s|APP_VERSION_PLACEHOLDER|$APP_VERSION|g" \
    -e "s|DISPLAY_NAME_PLACEHOLDER|$DISPLAY_NAME|g" \
    "$RELEASE_DOWNLOAD_DIR/manifest.plist"
  echo "✅ manifest.plist generated (bundle: $BUNDLE_ID, version: $APP_VERSION)."
else
  echo "⚠️  Could not read bundle ID from Info.plist — skipping manifest.plist."
fi

# ── Upload sourcemaps to Sentry ──────────────────────────────────────────────
common_upload_sentry

echo ""
echo "✅ Done! Signed IPA: $RELEASE_DOWNLOAD_DIR/resigned-output.ipa"
