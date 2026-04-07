#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# repack_android.sh — Repack and resign an Android APK with a fresh JS bundle
#
# Usage (local):
#   chmod +x scripts/repack_android.sh && ./scripts/repack_android.sh
#   (env vars auto-loaded from scripts/.env or .env if present)
#
# Usage (CI — set CI=true, dirs pre-populated by workflow steps):
#   The workflow sets WORK_DIR, SOURCE_DIR, BUNDLE_OUTPUT_DIR, RELEASE_DOWNLOAD_DIR
#   and calls this script after checkout + yarn install steps.
#
# Required env vars:
#   RELEASE_REPO          GitHub repo holding the release   (e.g. org/repo)
#   RELEASE_TAG           Release tag to download from      (e.g. v1.0.0-Release-main)
#   KEYSTORE_PATH         Keystore path relative to SOURCE_DIR
#   KEYSTORE_PASSWORD     Keystore password
#   KEY_ALIAS             Key alias
#   KEY_PASSWORD          Key password
#   GH_TOKEN              GitHub token (used by gh CLI)
#
# Optional env vars:
#   REPO                  Self-hosted git host+path — required in local mode
#   REPO_BRANCH           Branch to clone            — required in local mode
#   GIT_USERNAME          Git username               — required in local mode
#   GIT_PASSWORD          Git password/token         — required in local mode
#   APK_FILENAME          APK glob/filename to download (default: *.apk)
#   WORK_DIR              Root working dir  (default: /tmp/repack_android_$$)
#   SOURCE_DIR            Path to cloned source (default: $WORK_DIR/input)
#   BUNDLE_OUTPUT_DIR     Bundle output dir  (default: $WORK_DIR/bundle_output)
#   RELEASE_DOWNLOAD_DIR  Download dir       (default: $WORK_DIR/release_download)
#   CI                    Set to 'true' to skip clone + install steps
#   APP_VERSION           Override version string for Sentry release (optional)
#   SENTRY_AUTH_TOKEN     Sentry auth token  (optional — also read from sentry.properties)
#   SENTRY_ORG            Sentry org slug    (optional — also read from sentry.properties)
#   SENTRY_PROJECT        Sentry project slug (optional — also read from sentry.properties)
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=repack_common.sh
source "$SCRIPT_DIR/repack_common.sh"

# ── Load .env + defaults ─────────────────────────────────────────────────────
common_load_env

APK_FILENAME="${APK_FILENAME:-*.apk}"
CI="${CI:-false}"
WORK_DIR="${WORK_DIR:-/tmp/repack_android_$$}"
SOURCE_DIR="${SOURCE_DIR:-$WORK_DIR/input}"
BUNDLE_OUTPUT_DIR="${BUNDLE_OUTPUT_DIR:-$WORK_DIR/bundle_output}"
RELEASE_DOWNLOAD_DIR="${RELEASE_DOWNLOAD_DIR:-$WORK_DIR/release_download}"

# ── Validate required vars ───────────────────────────────────────────────────
REQUIRED_VARS=(RELEASE_REPO RELEASE_TAG KEYSTORE_PATH KEYSTORE_PASSWORD KEY_ALIAS KEY_PASSWORD GH_TOKEN)
if [[ "$CI" != "true" ]]; then
  REQUIRED_VARS+=(REPO REPO_BRANCH GIT_USERNAME GIT_PASSWORD)
fi
common_validate_vars

mkdir -p "$WORK_DIR" "$BUNDLE_OUTPUT_DIR" "$RELEASE_DOWNLOAD_DIR"
echo "🗂️  Work dir:     $WORK_DIR"
echo "📂 Source dir:   $SOURCE_DIR"
echo "📦 Bundle dir:   $BUNDLE_OUTPUT_DIR"
echo "⬇️  Download dir: $RELEASE_DOWNLOAD_DIR"

# ── Clone + install (local mode only) ───────────────────────────────────────
common_clone_source

# ── Load sentry.properties + bundle ─────────────────────────────────────────
common_load_sentry android
common_bundle android

# ── Download release APK ─────────────────────────────────────────────────────
echo ""
echo "⬇️  Downloading APK from $RELEASE_REPO@$RELEASE_TAG..."
GH_TOKEN="$GH_TOKEN" gh release download "$RELEASE_TAG" \
  -R "$RELEASE_REPO" \
  -p "*.apk" \
  -D "$RELEASE_DOWNLOAD_DIR"

# Resolve the downloaded file.
# If APK_FILENAME is a specific name (no wildcards), use it as a find filter.
# Otherwise (default *.apk) pick the first APK found.
if [[ "$APK_FILENAME" != *"*"* && "$APK_FILENAME" != *"?"* ]]; then
  DOWNLOADED_APK=$(find "$RELEASE_DOWNLOAD_DIR" -maxdepth 1 -name "$APK_FILENAME" | head -n 1)
  if [[ -z "$DOWNLOADED_APK" ]]; then
    echo "⚠️  APK named '$APK_FILENAME' not found — falling back to first available APK."
    DOWNLOADED_APK=$(find "$RELEASE_DOWNLOAD_DIR" -maxdepth 1 -name '*.apk' | sort | head -n 1)
  fi
else
  DOWNLOADED_APK=$(find "$RELEASE_DOWNLOAD_DIR" -maxdepth 1 -name '*.apk' | sort | head -n 1)
fi
if [[ -z "$DOWNLOADED_APK" ]]; then
  echo "❌ No APK file found in $RELEASE_DOWNLOAD_DIR after download."
  exit 1
fi
echo "📦 Found APK: $(basename "$DOWNLOADED_APK")"

# ── Repack APK (preserve per-entry compression) ──────────────────────────────
# Using Python instead of unzip+zip because zip(1) recompresses every entry
# with DEFLATE by default, including .so libraries and resources.arsc which
# the Android runtime requires to be STORED (uncompressed). This causes a
# halved APK size and prevents the app from loading native libraries.
echo ""
echo "💻 Repacking APK (preserving original compression per entry)..."
mkdir -p "$(dirname "$DOWNLOADED_APK")"

echo "📋 Native Android Resource Build: Re-compiling APK with apktool..."
APKTOOL_JAR="$(dirname "$0")/apktool.jar"
if [[ ! -f "$APKTOOL_JAR" ]]; then
  echo "   - Fetching latest Apktool release..."
  LATEST_APKTOOL_URL=$(curl -sL "https://api.github.com/repos/iBotPeaches/Apktool/releases/latest" | grep "browser_download_url" | grep "\.jar" | head -n 1 | cut -d '"' -f 4)
  if [[ -z "$LATEST_APKTOOL_URL" ]]; then
    echo "❌ Failed to fetch latest Apktool URL."
    exit 1
  fi
  wget -qO "$APKTOOL_JAR" "$LATEST_APKTOOL_URL"
  echo "   - Downloaded seamlessly to $APKTOOL_JAR"
fi

DECODED_DIR="$RELEASE_DOWNLOAD_DIR/decoded_apk"
echo "   - Unpacking original APK resources.arsc..."
java -jar "$APKTOOL_JAR" d -s -f -o "$DECODED_DIR" "$DOWNLOADED_APK"

echo "🔄 Bumping Android version string to $APP_VERSION in apktool metadata..."
sed -i.bak -E "s/versionName: .*/versionName: $APP_VERSION/" "$DECODED_DIR/apktool.yml"
rm -f "$DECODED_DIR/apktool.yml.bak"

echo "   - Injecting regenerated bundles & native assets..."
# Inject main JS bundle natively
cp "$BUNDLE_OUTPUT_DIR/index.android.bundle" "$DECODED_DIR/assets/index.android.bundle"

# Inject Expo Updates Manifest unmodified for native resourcesFolder parsing
if [[ -f "$BUNDLE_OUTPUT_DIR/app.manifest" ]]; then
  cp "$BUNDLE_OUTPUT_DIR/app.manifest" "$DECODED_DIR/assets/app.manifest"
fi

# Overlay React Native asset directories (drawable-*, raw, etc.) precisely onto native /res
if [ -d "$BUNDLE_OUTPUT_DIR/drawable-mdpi" ] || [ -d "$BUNDLE_OUTPUT_DIR/raw" ]; then
  # Dynamically copy natively scaled folders created by RN straight into standard Android resource hierarchy
  cp -r "$BUNDLE_OUTPUT_DIR/drawable-"* "$DECODED_DIR/res/" 2>/dev/null || true
  cp -r "$BUNDLE_OUTPUT_DIR/raw" "$DECODED_DIR/res/" 2>/dev/null || true
fi

echo "   - Recompiling modified APK + resources.arsc via aapt2 natively (This may take a minute)..."
java -jar "$APKTOOL_JAR" b "$DECODED_DIR" -o "$RELEASE_DOWNLOAD_DIR/repacked-unsigned.apk"

# Cleanup unpacked heavy payload
rm -rf "$DECODED_DIR"

# ── Align APK (4-byte alignment required; 4KB for page-aligned .so) ──────────
ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ANDROID_BUILD_TOOLS=$(ls -d "$ANDROID_HOME/build-tools/"* 2>/dev/null | sort -V | tail -1)
ZIPALIGN="$ANDROID_BUILD_TOOLS/zipalign"

if [[ -x "$ZIPALIGN" ]]; then
  echo ""
  echo "📐 Aligning APK..."
  "$ZIPALIGN" -f -p 4 \
    "$RELEASE_DOWNLOAD_DIR/repacked-unsigned.apk" \
    "$RELEASE_DOWNLOAD_DIR/repacked-aligned.apk"
  UNSIGNED_APK="$RELEASE_DOWNLOAD_DIR/repacked-aligned.apk"
else
  echo "⚠️  zipalign not found — skipping alignment (app may warn on install)."
  UNSIGNED_APK="$RELEASE_DOWNLOAD_DIR/repacked-unsigned.apk"
fi

# ── Sign APK ─────────────────────────────────────────────────────────────────
FULL_KEYSTORE_PATH="$SOURCE_DIR/$KEYSTORE_PATH"
if [[ ! -f "$FULL_KEYSTORE_PATH" ]]; then
  echo "❌ Keystore not found at $FULL_KEYSTORE_PATH"
  exit 1
fi

APKSIGNER="$ANDROID_BUILD_TOOLS/apksigner"
if [[ ! -x "$APKSIGNER" ]]; then
  echo "❌ apksigner not found at $APKSIGNER"
  echo "   Ensure ANDROID_HOME is set and build-tools are installed."
  exit 1
fi

echo ""
echo "✍️  Signing APK..."
"$APKSIGNER" sign \
  --ks "$FULL_KEYSTORE_PATH" \
  --ks-key-alias "$KEY_ALIAS" \
  --ks-pass "pass:$KEYSTORE_PASSWORD" \
  --key-pass "pass:$KEY_PASSWORD" \
  --out "$RELEASE_DOWNLOAD_DIR/resigned-output.apk" \
  "$UNSIGNED_APK"

# ── Upload sourcemaps to Sentry ──────────────────────────────────────────────
common_upload_sentry

echo ""
echo "✅ Done! Signed APK: $RELEASE_DOWNLOAD_DIR/resigned-output.apk"
