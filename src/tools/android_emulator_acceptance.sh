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
test -f integration_test/android_remote_server_test.dart
drive_log="$(mktemp)"
drive_pid=""
cleanup() {
  adb forward --remove tcp:18735 >/dev/null 2>&1 || true
  if [[ -n "$drive_pid" ]] && kill -0 "$drive_pid" 2>/dev/null; then
    kill "$drive_pid" 2>/dev/null || true
    wait "$drive_pid" 2>/dev/null || true
  fi
  rm -f "$drive_log"
}
trap cleanup EXIT

timeout --signal=TERM --kill-after=30s 8m flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/android_remote_server_test.dart \
  --no-dds \
  -d emulator-5554 >"$drive_log" 2>&1 &
drive_pid=$!

ready=0
for attempt in {1..180}; do
  if adb logcat -d -s flutter:I | grep -F 'HTC_ANDROID_BG_ACCEPTANCE_READY:' >/dev/null; then
    ready=1
    break
  fi
  if ! kill -0 "$drive_pid" 2>/dev/null; then
    cat "$drive_log"
    echo '::error::Android integration test exited before the background-server checkpoint.'
    exit 1
  fi
  sleep 1
done

if [[ "$ready" -ne 1 ]]; then
  cat "$drive_log"
  echo '::error::Timed out waiting for the Android server background checkpoint.'
  exit 1
fi

adb shell input keyevent KEYCODE_HOME
sleep 2
service_dump="$(adb shell dumpsys activity services)"
if ! grep -Fq 'RadioWebServerService' <<< "$service_dump"; then
  cat "$drive_log"
  echo '::error::Android foreground radio/server service was not running after the app went to background.'
  exit 1
fi

adb forward tcp:18735 tcp:18735
background_status=''
for attempt in {1..8}; do
  background_status="$(curl --connect-timeout 2 --max-time 4 --silent --output /dev/null --write-out '%{http_code}' http://127.0.0.1:18735/login || true)"
  if [[ "$background_status" == '200' ]]; then
    break
  fi
  sleep 1
done
if [[ "$background_status" != '200' ]]; then
  cat "$drive_log"
  echo "::error::Android server did not serve /login while backgrounded (HTTP ${background_status:-no response})."
  exit 1
fi
echo 'Android foreground service remained active and served /login after MainActivity moved to the background.'

adb shell am start -n com.meshcentral.htcommander/.MainActivity >/dev/null
if ! wait "$drive_pid"; then
  cat "$drive_log"
  exit 1
fi
cat "$drive_log"
