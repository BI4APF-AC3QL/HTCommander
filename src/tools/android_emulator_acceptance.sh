#!/usr/bin/env bash
set -euo pipefail

src_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_root="$(cd "$src_root/.." && pwd)"

adb logcat -c
adb install -r "$repo_root/src/build/app/outputs/flutter-apk/app-x86_64-release.apk"
adb shell am start -n com.meshcentral.htcommander/.MainActivity

for attempt in {1..45}; do
  if adb shell pidof com.meshcentral.htcommander >/dev/null; then
    break
  fi
  sleep 1
done

if ! adb shell pidof com.meshcentral.htcommander >/dev/null; then
  echo '::error::HTCommander exited before starting on the Android emulator.'
  adb logcat -d -t 3000 | tail -n 3000
  exit 1
fi

sleep 15
crash_log="$(adb logcat -d -b crash)"
if grep -Fq 'Process: com.meshcentral.htcommander' <<< "$crash_log"; then
  echo '::error::HTCommander crashed on the Android emulator.'
  printf '%s\n' "$crash_log"
  exit 1
fi
echo 'HTCommander x86_64 release APK installed and remained running for 15 seconds.'

# The release APK can use a repository signing key, while `flutter test` signs
# the integration-test APK with the debug key. The emulator is disposable, so
# remove the release install before the instrumented test installs its build.
adb uninstall com.meshcentral.htcommander
cd "$src_root"
flutter test integration_test/android_remote_server_test.dart -d emulator-5554
