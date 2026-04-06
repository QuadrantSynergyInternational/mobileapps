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
#   REPO                  Self-hosted git host+path (e.g. git.example.com/org/repo) — required in local mode
#   REPO_BRANCH           Branch to clone                — required in local mode
#   GIT_USERNAME          Git username for self-hosted    — required in local mode
#   GIT_PASSWORD          Git password/token              — required in local mode
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
APK_FILENAME="${APK_FILENAME:-*.apk}"
WORK_DIR="${WORK_DIR:-/tmp/repack_android_$$}"
SOURCE_DIR="${SOURCE_DIR:-$WORK_DIR/input}"
BUNDLE_OUTPUT_DIR="${BUNDLE_OUTPUT_DIR:-$WORK_DIR/bundle_output}"
RELEASE_DOWNLOAD_DIR="${RELEASE_DOWNLOAD_DIR:-$WORK_DIR/release_download}"
CI="${CI:-false}"

# ── Validate required vars ───────────────────────────────────────────────────
REQUIRED_VARS=(RELEASE_REPO RELEASE_TAG KEYSTORE_PATH KEYSTORE_PASSWORD KEY_ALIAS KEY_PASSWORD GH_TOKEN)
if [[ "$CI" != "true" ]]; then
  REQUIRED_VARS+=(REPO REPO_BRANCH GIT_USERNAME GIT_PASSWORD)
fi

for var in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "❌ Required env var '$var' is not set."
    exit 1
  fi
done

mkdir -p "$WORK_DIR" "$BUNDLE_OUTPUT_DIR" "$RELEASE_DOWNLOAD_DIR"
echo "🗂️  Work dir:     $WORK_DIR"
echo "📂 Source dir:   $SOURCE_DIR"
echo "📦 Bundle dir:   $BUNDLE_OUTPUT_DIR"
echo "⬇️  Download dir: $RELEASE_DOWNLOAD_DIR"

# ── Clone + install (local mode only) ───────────────────────────────────────
if [[ "$CI" != "true" ]]; then
  echo ""
  echo "📥 Cloning source repo ($REPO_BRANCH)..."
  git clone --depth=1 --single-branch \
    --branch="$REPO_BRANCH" \
    "https://${GIT_USERNAME}:${GIT_PASSWORD}@${REPO}" \
    "$SOURCE_DIR"

  echo ""
  echo "📦 Installing JS dependencies..."
  (cd "$SOURCE_DIR" && yarn install)
fi

# ── Load sentry.properties (optional) ───────────────────────────────────────
# Reads defaults.properties or sentry.properties from the source root.
# Env vars take precedence over values in the file.
SENTRY_PROPS_FILE="$SOURCE_DIR/sentry.properties"
if [[ -f "$SENTRY_PROPS_FILE" ]]; then
  echo ""
  echo "📋 Loading Sentry config from $SENTRY_PROPS_FILE..."
  while IFS='=' read -r key value; do
    # Skip comments and blank lines
    [[ "$key" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${key// }" ]] && continue
    key="${key// /}"
    value="${value// /}"
    case "$key" in
      auth.token)   SENTRY_AUTH_TOKEN="${SENTRY_AUTH_TOKEN:-$value}" ;;
      defaults.org) SENTRY_ORG="${SENTRY_ORG:-$value}" ;;
      defaults.project) SENTRY_PROJECT="${SENTRY_PROJECT:-$value}" ;;
    esac
  done < "$SENTRY_PROPS_FILE"
fi

# ── Bundle React Native ──────────────────────────────────────────────────────
echo ""
echo "🏗️  Bundling React Native (android)..."
APP_VERSION="${APP_VERSION:-$(node -e "console.log(require('$SOURCE_DIR/package.json').version)")}"
echo "📌 App version: $APP_VERSION"
(
  cd "$SOURCE_DIR"
  npx react-native bundle \
    --platform android \
    --dev false \
    --entry-file index.js \
    --bundle-output "$BUNDLE_OUTPUT_DIR/index.android.bundle" \
    --sourcemap-output "$BUNDLE_OUTPUT_DIR/index.android.bundle.map" \
    --assets-dest "$BUNDLE_OUTPUT_DIR"
)

# ── Download release APK ─────────────────────────────────────────────────────
echo ""
echo "⬇️  Downloading APK ($APK_FILENAME) from $RELEASE_REPO@$RELEASE_TAG..."
GH_TOKEN="$GH_TOKEN" gh release download "$RELEASE_TAG" \
  -R "$RELEASE_REPO" \
  -p "$APK_FILENAME" \
  -D "$RELEASE_DOWNLOAD_DIR"

# Resolve the actual downloaded filename (supports glob patterns like *.apk)
DOWNLOADED_APK=$(find "$RELEASE_DOWNLOAD_DIR" -maxdepth 1 -name '*.apk' | sort | head -n 1)
if [[ -z "$DOWNLOADED_APK" ]]; then
  echo "❌ No APK file found in $RELEASE_DOWNLOAD_DIR after download."
  exit 1
fi
echo "📦 Found APK: $(basename "$DOWNLOADED_APK")"

# ── Unpack + replace bundle ──────────────────────────────────────────────────
UNPACKED_DIR="$RELEASE_DOWNLOAD_DIR/unpacked_apk"
echo ""
echo "📦 Unpacking APK..."
unzip -qo "$DOWNLOADED_APK" -d "$UNPACKED_DIR"

echo "🔄 Replacing index.android.bundle..."
mkdir -p "$UNPACKED_DIR/assets"
cp "$BUNDLE_OUTPUT_DIR/index.android.bundle" "$UNPACKED_DIR/assets/index.android.bundle"

if [ -d "$BUNDLE_OUTPUT_DIR/assets" ]; then
  echo "🖼️  Syncing assets..."
  cp -R "$BUNDLE_OUTPUT_DIR/assets/." "$UNPACKED_DIR/assets/" || true
fi

echo "🗑️  Removing old signature..."
rm -rf "$UNPACKED_DIR/META-INF"

echo "📁 Repacking unsigned APK..."
(cd "$UNPACKED_DIR" && zip -qr ../repacked-unsigned.apk .)

# ── Sign APK ─────────────────────────────────────────────────────────────────
FULL_KEYSTORE_PATH="$SOURCE_DIR/$KEYSTORE_PATH"
if [[ ! -f "$FULL_KEYSTORE_PATH" ]]; then
  echo "❌ Keystore not found at $FULL_KEYSTORE_PATH"
  exit 1
fi

ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ANDROID_BUILD_TOOLS=$(ls -d "$ANDROID_HOME/build-tools/"* | sort -V | tail -1)
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
  "$RELEASE_DOWNLOAD_DIR/repacked-unsigned.apk"

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
echo "✅ Done! Signed APK: $RELEASE_DOWNLOAD_DIR/resigned-output.apk"
