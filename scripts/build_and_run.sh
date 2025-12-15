#!/usr/bin/env zsh
set -euo pipefail
setopt NULL_GLOB

# Build + run helper for MacCleaner
# Usage: ./scripts/build_and_run.sh

PROJECT_ROOT="${0:A:h:h}"
SCHEME="MacCleaner"
PROJECT_FILE="${PROJECT_ROOT}/MacCleaner.xcodeproj"
DESTINATION="platform=macOS"
DERIVED_BASE="${HOME}/Library/Developer/Xcode/DerivedData"
APP_NAME="MacCleaner.app"

clean_old_builds() {
  echo "🧹 Cleaning old MacCleaner builds..."
  local matches=(${DERIVED_BASE}/MacCleaner-*)
  if [[ ${#matches} -eq 0 ]]; then
    echo "ℹ️  No prior MacCleaner DerivedData found."
    return
  fi

  for dd in ${matches}; do
    if [[ -d "${dd}/Build" ]]; then
      echo " - Removing ${dd}/Build"
      rm -rf "${dd}/Build"
    fi
  done
}

build_app() {
  echo "🔨 Building ${SCHEME}..."
  if command -v xcbeautify >/dev/null 2>&1; then
    /usr/bin/xcodebuild \
      -scheme "${SCHEME}" \
      -project "${PROJECT_FILE}" \
      -destination "${DESTINATION}" \
      clean build | xcbeautify
  else
    /usr/bin/xcodebuild \
      -scheme "${SCHEME}" \
      -project "${PROJECT_FILE}" \
      -destination "${DESTINATION}" \
      clean build
  fi
}

find_and_open_app() {
  local latest_dd
  latest_dd=$(ls -dt ${DERIVED_BASE}/MacCleaner-* 2>/dev/null | head -1 || true)
  if [[ -z "${latest_dd}" ]]; then
    echo "❌ Could not locate DerivedData for ${SCHEME}."
    return 1
  fi

  local app_path="${latest_dd}/Build/Products/Debug/${APP_NAME}"
  if [[ ! -d "${app_path}" ]]; then
    echo "❌ Build output not found at ${app_path}."
    return 1
  fi

  echo "🚀 Opening ${app_path}"
  open "${app_path}"
}

main() {
  pushd "${PROJECT_ROOT}" >/dev/null
  clean_old_builds
  build_app
  find_and_open_app
  popd >/dev/null
}

main "$@"
