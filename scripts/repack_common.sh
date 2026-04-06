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
      
    echo "⚙️  Detecting Hermes compiler configuration..."
    
    # 1. Determine default based on RN Version (Hermes is default on >= 0.70)
    RN_VERSION=$(node -p "require('$SOURCE_DIR/package.json').dependencies['react-native']" 2>/dev/null | tr -d '^~' | cut -d'.' -f2 || echo "0")
    if [[ "$RN_VERSION" -ge 70 ]]; then
      PROJECT_USES_HERMES="true"
    else
      PROJECT_USES_HERMES="false"
    fi

    # 2. Check for explicit platform overrides
    if [[ "$platform" == "android" ]]; then
      if grep -E -qi "hermesEnabled=true|enableHermes:? *true|jsEngine=hermes" "$SOURCE_DIR/android/gradle.properties" "$SOURCE_DIR/android/app/build.gradle" 2>/dev/null; then
        PROJECT_USES_HERMES="true"
      elif grep -E -qi "hermesEnabled=false|enableHermes:? *false|jsEngine=jsc" "$SOURCE_DIR/android/gradle.properties" "$SOURCE_DIR/android/app/build.gradle" 2>/dev/null; then
        PROJECT_USES_HERMES="false"
      fi
    elif [[ "$platform" == "ios" ]]; then
      if grep -E -qi ":hermes_enabled *=> *false" "$SOURCE_DIR/ios/Podfile" 2>/dev/null; then
        PROJECT_USES_HERMES="false"
      elif grep -E -q "podfile_properties\['expo.jsEngine'\]" "$SOURCE_DIR/ios/Podfile" 2>/dev/null; then
        # Handle dynamic Expo property resolution
        if grep -qi '"expo.jsEngine" *: *"jsc"' "$SOURCE_DIR/ios/Podfile.properties.json" 2>/dev/null || \
           grep -qi '"jsEngine" *: *"jsc"' "$SOURCE_DIR/app.json" 2>/dev/null; then
          PROJECT_USES_HERMES="false"
        else
          PROJECT_USES_HERMES="true" # Expo modern default is Hermes
        fi
      elif grep -E -qi ":hermes_enabled *=> *true" "$SOURCE_DIR/ios/Podfile" 2>/dev/null; then
        PROJECT_USES_HERMES="true"
      fi
    fi

    if [[ "$PROJECT_USES_HERMES" == "false" ]]; then
      echo "ℹ️  React Native project has Hermes DISABLED. Keeping standard minified JS bundle."
    else
      # Locate hermesc inside the RN installation based on OS
      OS_NAME=$(uname -s | tr '[:upper:]' '[:lower:]')
      HERMESC_PATH=""
      
      if [[ "$OS_NAME" == "darwin" ]]; then
        HERMESC_PATH=$(find "$SOURCE_DIR/node_modules" -path "*/react-native/sdks/hermesc/osx-bin/hermesc" -type f | head -n 1)
        if [[ -z "$HERMESC_PATH" ]]; then
          HERMESC_PATH=$(find "$SOURCE_DIR/node_modules" -path "*/@react-native/hermes-cli/osx-bin/hermesc" -type f | head -n 1)
        fi
      elif [[ "$OS_NAME" == "linux" ]]; then
        HERMESC_PATH=$(find "$SOURCE_DIR/node_modules" -path "*/react-native/sdks/hermesc/linux64-bin/hermesc" -type f | head -n 1)
        if [[ -z "$HERMESC_PATH" ]]; then
          HERMESC_PATH=$(find "$SOURCE_DIR/node_modules" -path "*/@react-native/hermes-cli/linux64-bin/hermesc" -type f | head -n 1)
        fi
      fi

      # Sometimes it's globally available or in another standard path
      if [[ -z "$HERMESC_PATH" && -f "$SOURCE_DIR/node_modules/react-native/sdks/hermesc/build/bin/hermesc" ]]; then
        HERMESC_PATH="$SOURCE_DIR/node_modules/react-native/sdks/hermesc/build/bin/hermesc"
      fi

      # 3. Extract custom Hermes Flags if defined in build configuration
      HERMES_FLAGS="-O -output-source-map"
      if [[ "$platform" == "android" ]]; then
        # Look for uncommented hermesFlags = ["-O", "-output-source-map"]
        EXTRACTED_FLAGS=$(grep -i 'hermesFlags *=' "$SOURCE_DIR/android/app/build.gradle" 2>/dev/null | grep -v '^ *//' | sed 's/.*\[\(.*\)\].*/\1/' | tr -d '"' | tr -d "'" | tr ',' ' ')
        if [[ -n "$EXTRACTED_FLAGS" ]]; then
          HERMES_FLAGS="$EXTRACTED_FLAGS"
          echo "ℹ️  Found Custom Android Hermes Flags: $HERMES_FLAGS"
        fi
      elif [[ "$platform" == "ios" ]]; then
        # Look for uncommented :hermes_flags => "-O -output-source-map"
        EXTRACTED_FLAGS=$(grep -i ':hermes_flags *=>' "$SOURCE_DIR/ios/Podfile" 2>/dev/null | grep -v '^ *#' | sed -E "s/.*:hermes_flags *=> *['\"]([^'\"]+)['\"].*/\1/")
        if [[ -n "$EXTRACTED_FLAGS" ]]; then
          HERMES_FLAGS="$EXTRACTED_FLAGS"
          echo "ℹ️  Found Custom iOS Hermes Flags: $HERMES_FLAGS"
        fi
      fi

      if [[ -n "$HERMESC_PATH" && -x "$HERMESC_PATH" ]]; then
        echo "🔥 Compiling JS bundle to Hermes bytecode: $HERMESC_PATH"
        # Notice parameter expansion doesn't quote HERMES_FLAGS so arguments split correctly
        "$HERMESC_PATH" -emit-binary $HERMES_FLAGS -out "$bundle_file.hbc" "$bundle_file"
        mv "$bundle_file.hbc" "$bundle_file"
        
        # Compose Hermes sourcemap with Metro packager sourcemap for accurate Sentry crash reporting
        COMPOSE_SCRIPT="$SOURCE_DIR/node_modules/react-native/scripts/compose-source-maps.js"
        if [[ -f "$COMPOSE_SCRIPT" && -f "${bundle_file}.hbc.map" ]]; then
          echo "🧩 Composing Hermes sourcemap with packager sourcemap..."
          node "$COMPOSE_SCRIPT" "${bundle_file}.map" "${bundle_file}.hbc.map" -o "${bundle_file}.map.composed"
          mv "${bundle_file}.map.composed" "${bundle_file}.map"
        elif [[ -f "${bundle_file}.hbc.map" ]]; then
          echo "⚠️  compose-source-maps.js not found. Using raw Hermes sourcemap."
          mv "${bundle_file}.hbc.map" "${bundle_file}.map"
        fi
        
        echo "✅ Hermes bytecode compilation complete."
      else
        echo "⚠️  hermesc not found — skipping Hermes bytecode compilation. (Native app may expect ABC/HBC bytecode)"
      fi
    fi
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
