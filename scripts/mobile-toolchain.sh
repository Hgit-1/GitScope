#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
local_flutter_root="$repo_root/.toolchains/flutter"
local_android_root="$repo_root/.toolchains/android-sdk"

if [[ -x "$local_flutter_root/bin/flutter" ]]; then
  flutter_cmd="$local_flutter_root/bin/flutter"
elif command -v flutter >/dev/null 2>&1; then
  flutter_cmd="$(command -v flutter)"
else
  echo "Flutter is missing. Install Flutter 3.47 or place it in .toolchains/flutter." >&2
  exit 1
fi

if [[ -d "$local_android_root/platforms/android-36" ]]; then
  android_root="$local_android_root"
else
  android_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
fi

if [[ -z "$android_root" || ! -d "$android_root/platforms/android-36" ]]; then
  echo "Android SDK Platform 36 is missing." >&2
  exit 1
fi

export ANDROID_SDK_ROOT="$android_root"
export PATH="$(dirname "$flutter_cmd"):$android_root/platform-tools:$PATH"

case "${1:-build}" in
  doctor)
    "$flutter_cmd" doctor -v
    ;;
  test)
    cd "$repo_root/apps/mobile"
    "$flutter_cmd" analyze
    "$flutter_cmd" test
    (cd android && ./gradlew :app:testDebugUnitTest)
    ;;
  build)
    cd "$repo_root/apps/mobile"
    "$flutter_cmd" pub get
    "$flutter_cmd" analyze
    "$flutter_cmd" test
    (cd android && ./gradlew :app:testDebugUnitTest)
    "$flutter_cmd" build apk --release
    ;;
  *)
    echo "Usage: $0 {doctor|test|build}" >&2
    exit 2
    ;;
esac
