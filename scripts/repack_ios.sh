#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# repack_ios.sh — Repack and resign an iOS IPA with a fresh JS bundle
#
# Usage (local):
#   export REPO_URL=https://user:token@github.com/org/repo
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
#   REPO                  Self-hosted git host+path (e.g. git.example.com/org/repo) — required in local mode
#   REPO_BRANCH           Branch to clone                — required in local mode
#   GIT_USERNAME          Git username for self-hosted    — required in local mode
#   GIT_PASSWORD          Git password/token              — required in local mode
#   PROVISION_REPO_TOKEN  Token for ios-provision         — required in local mode
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

# ── Load .env (local mode only) ─────────────────────────────────────────────
if [[ "${CI:-false}" != "true" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for env_file in "$SCRIPT_DIR/.env" "$SCRIPT_DIR/../.env" ".env"; do
    if [[ -f "$env_file" ]]; then
      echo "📄 Loading env from $env_file"
      set -o allexport
      # shellcheck source=/dev/null
      source "$env_file"
      set +o allexport
      break
    fi
  done
fi

# ── Defaults ────────────────────────────────────────────────────────────────
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

for var in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "❌ Required env var '$var' is not set."
    exit 1
  fi
done

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
if [[ "$CI" != "true" ]]; then
  echo ""
  echo "📥 Cloning source repo ($REPO_BRANCH)..."
  git clone --depth=1 --single-branch \
    --branch="$REPO_BRANCH" \
    "https://${GIT_USERNAME}:${GIT_PASSWORD}@${REPO}" \
    "$SOURCE_DIR"

  echo ""
  echo "🔐 Cloning provision repo..."
  git clone --depth=1 --single-branch --branch=main \
    "https://admindevopsqsi:${PROVISION_REPO_TOKEN}@github.com/admindevopsqsi/ios-provision.git" \
    "$PROVISION_DIR"

  echo ""
  echo "📦 Installing JS dependencies..."
  (cd "$SOURCE_DIR" && yarn install)
fi

# ── Resolve provision file paths ────────────────────────────────────────────
P12_PATH="$PROVISION_DIR/$PROJECT_ID/$PROVISION_FILE.p12"
MOBILEPROVISION_PATH="$PROVISION_DIR/$PROJECT_ID/$PROVISION_FILE.mobileprovision"

# ── Load sentry.properties (optional) ───────────────────────────────────────
# Reads from source root. Env vars take precedence over file values.
SENTRY_PROPS_FILE="$SOURCE_DIR/sentry.properties"
if [[ -f "$SENTRY_PROPS_FILE" ]]; then
  echo ""
  echo "📋 Loading Sentry config from $SENTRY_PROPS_FILE..."
  while IFS='=' read -r key value; do
    [[ "$key" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${key// }" ]] && continue
    key="${key// /}"
    value="${value// /}"
    case "$key" in
      auth.token)       SENTRY_AUTH_TOKEN="${SENTRY_AUTH_TOKEN:-$value}" ;;
      defaults.org)     SENTRY_ORG="${SENTRY_ORG:-$value}" ;;
      defaults.project) SENTRY_PROJECT="${SENTRY_PROJECT:-$value}" ;;
    esac
  done < "$SENTRY_PROPS_FILE"
fi

# ── Setup keychain ────────────────────────────────────────────────────────────
echo ""
echo "🔑 Setting up keychain..."
# Save the current search list so we can restore it on exit
ORIGINAL_KEYCHAINS=$(security list-keychains -d user | xargs)

cleanup() {
  echo ""
  echo "🧹 Cleaning up keychain..."
  # Restore original keychain search list
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
echo ""
echo "🏗️  Bundling React Native (ios)..."
APP_VERSION="${APP_VERSION:-$(node -e "console.log(require('$SOURCE_DIR/package.json').version)")}"
echo "📌 App version: $APP_VERSION"
(
  cd "$SOURCE_DIR"
  npx react-native bundle \
    --platform ios \
    --dev false \
    --entry-file index.js \
    --bundle-output "$BUNDLE_OUTPUT_DIR/main.jsbundle" \
    --sourcemap-output "$BUNDLE_OUTPUT_DIR/main.jsbundle.map" \
    --assets-dest "$BUNDLE_OUTPUT_DIR"
)

# ── Download release IPA ─────────────────────────────────────────────────────
echo ""
echo "⬇️  Downloading IPA from $RELEASE_REPO@$RELEASE_TAG..."
GH_TOKEN="$GH_TOKEN" gh release download "$RELEASE_TAG" \
  -R "$RELEASE_REPO" \
  -p "*.ipa" \
  -D "$RELEASE_DOWNLOAD_DIR"

# Resolve the downloaded file.
# If IPA_FILENAME is a specific name (no wildcards), use it as a find filter.
# Otherwise (default *.ipa) pick the first IPA found.
if [[ "$IPA_FILENAME" != *"*"* && "$IPA_FILENAME" != *"?"* ]]; then
  DOWNLOADED_IPA=$(find "$RELEASE_DOWNLOAD_DIR" -maxdepth 1 -name "$IPA_FILENAME" | head -n 1)
  if [[ -z "$DOWNLOADED_IPA" ]]; then
    echo "⚠️  IPA named '$IPA_FILENAME' not found — falling back to first available IPA."
    DOWNLOADED_IPA=$(find "$RELEASE_DOWNLOAD_DIR" -maxdepth 1 -name '*.ipa' | head -n 1)
  fi
else
  DOWNLOADED_IPA=$(find "$RELEASE_DOWNLOAD_DIR" -maxdepth 1 -name '*.ipa' | head -n 1)
fi
if [[ -z "$DOWNLOADED_IPA" ]]; then
  echo "❌ No IPA file found in $RELEASE_DOWNLOAD_DIR after download."
  exit 1
fi
echo "📦 Found IPA: $(basename "$DOWNLOADED_IPA")"

# ── Unpack + replace bundle ──────────────────────────────────────────────────
echo ""
echo "📦 Unpacking IPA..."
unzip -qo "$DOWNLOADED_IPA" -d "$RELEASE_DOWNLOAD_DIR/unpacked_ipa"

APP_NAME=$(ls "$RELEASE_DOWNLOAD_DIR/unpacked_ipa/Payload" | grep '\.app$' | head -n 1)
echo "📱 Found app bundle: $APP_NAME"

echo "🔄 Replacing main.jsbundle..."
cp "$BUNDLE_OUTPUT_DIR/main.jsbundle" "$RELEASE_DOWNLOAD_DIR/unpacked_ipa/Payload/$APP_NAME/main.jsbundle"

if [ -d "$BUNDLE_OUTPUT_DIR/assets" ]; then
  echo "🖼️  Syncing assets..."
  cp -R "$BUNDLE_OUTPUT_DIR/assets/." "$RELEASE_DOWNLOAD_DIR/unpacked_ipa/Payload/$APP_NAME/assets/" || true
fi

# ── Embed provisioning profile ───────────────────────────────────────────────
echo "📋 Embedding provisioning profile..."
cp "$MOBILEPROVISION_PATH" "$RELEASE_DOWNLOAD_DIR/unpacked_ipa/Payload/$APP_NAME/embedded.mobileprovision"

# ── Resign ───────────────────────────────────────────────────────────────────
IDENTITY=$(security find-identity -v -p codesigning "$KEYCHAIN_NAME" \
  | head -1 | grep -o '"[^"]*"' | tr -d '"')
echo "🔑 Signing with identity: $IDENTITY"

/usr/bin/codesign \
  --force \
  --sign "$IDENTITY" \
  --keychain "$KEYCHAIN_NAME" \
  "$RELEASE_DOWNLOAD_DIR/unpacked_ipa/Payload/$APP_NAME"

# ── Repack ───────────────────────────────────────────────────────────────────
echo "📁 Repacking signed IPA..."
(cd "$RELEASE_DOWNLOAD_DIR/unpacked_ipa" && zip -qry ../resigned-output.ipa Payload)

# ── Upload sourcemaps to Sentry (optional) ──────────────────────────────────
if [[ -n "${SENTRY_AUTH_TOKEN:-}" && -n "${SENTRY_ORG:-}" && -n "${SENTRY_PROJECT:-}" ]]; then
  echo ""
  echo "📡 Uploading sourcemaps to Sentry (release: $APP_VERSION)..."
  SENTRY_AUTH_TOKEN="$SENTRY_AUTH_TOKEN" npx sentry-cli sourcemaps upload \
    --org "$SENTRY_ORG" \
    --project "$SENTRY_PROJECT" \
    --release "$APP_VERSION" \
    "$BUNDLE_OUTPUT_DIR"
  echo "✅ Sentry sourcemaps uploaded."
else
  echo "ℹ️  Skipping Sentry upload (SENTRY_AUTH_TOKEN / SENTRY_ORG / SENTRY_PROJECT not set)."
fi

echo ""
echo "✅ Done! Signed IPA: $RELEASE_DOWNLOAD_DIR/resigned-output.ipa"
