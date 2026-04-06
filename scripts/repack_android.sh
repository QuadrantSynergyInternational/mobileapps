#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# repack_android.sh — Repack and resign an Android APK with a fresh JS bundle
#
# Usage (local):
#   export REPO_URL=https://user:token@github.com/org/repo
#   export REPO_BRANCH=main
#   export RELEASE_REPO=org/release-repo
#   export RELEASE_TAG=v1.0.0-Release-main
#   export KEYSTORE_PATH=android/app/release.keystore   # relative to source root
#   export KEYSTORE_PASSWORD=...
#   export KEY_ALIAS=...
#   export KEY_PASSWORD=...
#   export GH_TOKEN=...
#   chmod +x scripts/repack_android.sh && ./scripts/repack_android.sh
#
# Usage (CI — set WORK_DIR=. to skip clone/provision, dirs already exist):
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
#   APK_FILENAME          APK asset name (default: app-release.apk)
#   WORK_DIR              Root working dir  (default: /tmp/repack_android_$$)
#   SOURCE_DIR            Path to cloned source (default: $WORK_DIR/input)
#   BUNDLE_OUTPUT_DIR     Bundle output dir  (default: $WORK_DIR/bundle_output)
#   RELEASE_DOWNLOAD_DIR  Download dir       (default: $WORK_DIR/release_download)
#   CI                    Set to 'true' to skip clone + install steps
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
APK_FILENAME="${APK_FILENAME:-app-release.apk}"
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

# ── Bundle React Native ──────────────────────────────────────────────────────
echo ""
echo "🏗️  Bundling React Native (android)..."
(
  cd "$SOURCE_DIR"
  npx react-native bundle \
    --platform android \
    --dev false \
    --entry-file index.js \
    --bundle-output "$BUNDLE_OUTPUT_DIR/index.android.bundle" \
    --assets-dest "$BUNDLE_OUTPUT_DIR"
)

# ── Download release APK ─────────────────────────────────────────────────────
echo ""
echo "⬇️  Downloading $APK_FILENAME from $RELEASE_REPO@$RELEASE_TAG..."
GH_TOKEN="$GH_TOKEN" gh release download "$RELEASE_TAG" \
  -R "$RELEASE_REPO" \
  -p "$APK_FILENAME" \
  -D "$RELEASE_DOWNLOAD_DIR"

# ── Unpack + replace bundle ──────────────────────────────────────────────────
echo ""
echo "📦 Unpacking APK..."
unzip -q "$RELEASE_DOWNLOAD_DIR/$APK_FILENAME" -d "$RELEASE_DOWNLOAD_DIR/unpacked_apk"

echo "🔄 Replacing index.android.bundle..."
mkdir -p "$RELEASE_DOWNLOAD_DIR/unpacked_apk/assets"
cp "$BUNDLE_OUTPUT_DIR/index.android.bundle" "$RELEASE_DOWNLOAD_DIR/unpacked_apk/assets/index.android.bundle"

if [ -d "$BUNDLE_OUTPUT_DIR/assets" ]; then
  echo "🖼️  Syncing assets..."
  cp -R "$BUNDLE_OUTPUT_DIR/assets/." "$RELEASE_DOWNLOAD_DIR/unpacked_apk/assets/" || true
fi

# ── Remove old signature + repack ───────────────────────────────────────────
echo "🗑️  Removing old signature..."
rm -rf "$RELEASE_DOWNLOAD_DIR/unpacked_apk/META-INF"

echo "📁 Repacking unsigned APK..."
(cd "$RELEASE_DOWNLOAD_DIR/unpacked_apk" && zip -qr ../repacked-unsigned.apk .)

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

echo "✍️  Signing APK..."
"$APKSIGNER" sign \
  --ks "$FULL_KEYSTORE_PATH" \
  --ks-key-alias "$KEY_ALIAS" \
  --ks-pass "pass:$KEYSTORE_PASSWORD" \
  --key-pass "pass:$KEY_PASSWORD" \
  --out "$RELEASE_DOWNLOAD_DIR/resigned-output.apk" \
  "$RELEASE_DOWNLOAD_DIR/repacked-unsigned.apk"

echo ""
echo "✅ Done! Signed APK: $RELEASE_DOWNLOAD_DIR/resigned-output.apk"
