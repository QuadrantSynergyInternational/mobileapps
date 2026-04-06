#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# repack_common.sh — Shared functions for repack_android.sh / repack_ios.sh
#
# Source this file, set your script-specific defaults, then call the helpers:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/repack_common.sh"
#   common_load_env          # load .env in local mode
#   common_validate_vars     # validate REQUIRED_VARS array
#   common_clone_source      # clone source repo (local mode only)
#   common_load_sentry       # read sentry.properties
#   common_bundle <platform> # run react-native bundle
#   common_upload_sentry     # upload sourcemaps to Sentry
# ---------------------------------------------------------------------------

# ── Load .env (local mode only) ─────────────────────────────────────────────
common_load_env() {
  if [[ "${CI:-false}" != "true" ]]; then
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
    for env_file in "$script_dir/.env" "$script_dir/../.env" ".env"; do
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
}

# ── Validate required vars ───────────────────────────────────────────────────
# Caller must populate REQUIRED_VARS array before calling this.
common_validate_vars() {
  for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
      echo "❌ Required env var '$var' is not set."
      exit 1
    fi
  done
}

# ── Clone source repo + yarn install (local mode only) ─────────────────────
# iOS callers should clone the provision repo themselves (different token/URL).
common_clone_source() {
  if [[ "${CI:-false}" != "true" ]]; then
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
}

# ── Load sentry.properties (optional) ───────────────────────────────────────
# Reads from $SOURCE_DIR/sentry.properties. Env vars take precedence.
common_load_sentry() {
  local props_file="$SOURCE_DIR/sentry.properties"
  if [[ -f "$props_file" ]]; then
    echo ""
    echo "📋 Loading Sentry config from $props_file..."
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
    done < "$props_file"
  fi
}

# ── Bundle React Native ──────────────────────────────────────────────────────
# Usage: common_bundle android|ios
# Expects: SOURCE_DIR, BUNDLE_OUTPUT_DIR, APP_VERSION to be set.
common_bundle() {
  local platform="${1:?platform argument required (android|ios)}"
  local bundle_file entry_file

  if [[ "$platform" == "android" ]]; then
    bundle_file="$BUNDLE_OUTPUT_DIR/index.android.bundle"
    entry_file="index.js"
  else
    bundle_file="$BUNDLE_OUTPUT_DIR/main.jsbundle"
    entry_file="index.js"
  fi

  APP_VERSION="${APP_VERSION:-$(node -e "console.log(require('$SOURCE_DIR/package.json').version)")}"

  echo ""
  echo "🏗️  Bundling React Native ($platform) — v$APP_VERSION..."
  (
    cd "$SOURCE_DIR"
    npx react-native bundle \
      --platform "$platform" \
      --dev false \
      --entry-file "$entry_file" \
      --bundle-output "$bundle_file" \
      --sourcemap-output "${bundle_file}.map" \
      --assets-dest "$BUNDLE_OUTPUT_DIR"
  )
}

# ── Upload sourcemaps to Sentry (optional) ──────────────────────────────────
# Expects: SENTRY_AUTH_TOKEN, SENTRY_ORG, SENTRY_PROJECT, APP_VERSION,
#          BUNDLE_OUTPUT_DIR to be set.
common_upload_sentry() {
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
}
