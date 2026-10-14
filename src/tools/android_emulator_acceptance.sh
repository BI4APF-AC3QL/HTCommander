#!/usr/bin/env bash
set -euo pipefail

src_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_root="$(cd "$src_root/.." && pwd)"

adb logcat -c
adb install -r "$repo_root/src/build/app/outputs/flutter-apk/app-x86_64-release.apk"
adb shell am start -n com.meshcentral.htcommander/.MainActivity

app_process_ids() {
  local pids
  pids="$(adb shell pidof com.meshcentral.htcommander 2>/dev/null | tr -d '\r' || true)"
  if [[ -n "$pids" ]]; then
    printf '%s\n' "$pids"
    return
  fi

  adb shell ps -A -o PID,NAME 2>/dev/null \
    | awk '$2 == "com.meshcentral.htcommander" || index($2, "com.meshcentral.htcommander:") == 1 { print $1 }' \
    | tr -d '\r'
}

for attempt in {1..45}; do
  app_pids="$(app_process_ids)"
  if [[ -n "$app_pids" ]]; then
    break
  fi
  sleep 1
done

if [[ -z "${app_pids:-}" ]]; then
  echo '::error::HTCommander process was not found after launching on the Android emulator.'
  adb shell ps -A -o PID,NAME || true
  adb shell dumpsys activity activities | grep -E 'mResumedActivity|topResumedActivity|com\.meshcentral\.htcommander' | tail -n 80 || true
  adb logcat -d -b crash -v threadtime || true
  adb logcat -d -v threadtime \
    | grep -E 'com\.meshcentral\.htcommander|AndroidRuntime|FATAL EXCEPTION|Fatal signal|ActivityTaskManager|ActivityManager' \
    | tail -n 500 || true
  exit 1
fi

sleep 15
crash_log="$(adb logcat -d -b crash)"
if grep -Fq 'Process: com.meshcentral.htcommander' <<< "$crash_log"; then
  echo '::error::HTCommander crashed on the Android emulator.'
  printf '%s\n' "$crash_log"
  exit 1
fi
app_pids="$(app_process_ids)"
if [[ -z "$app_pids" ]]; then
  echo '::error::HTCommander stopped running during the 15-second Android emulator launch check.'
  adb shell ps -A -o PID,NAME || true
  adb logcat -d -b crash -v threadtime || true
  adb logcat -d -v threadtime \
    | grep -E 'com\.meshcentral\.htcommander|AndroidRuntime|FATAL EXCEPTION|Fatal signal|ActivityTaskManager|ActivityManager' \
    | tail -n 500 || true
  exit 1
fi
echo "HTCommander x86_64 release APK installed and remained running for 15 seconds (PID(s): ${app_pids//$'\n'/, })."

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

wait_for_flutter_marker() {
  local marker="$1"
  local checkpoint="$2"
  for attempt in {1..180}; do
    if adb logcat -d -s flutter:I | grep -F "$marker" >/dev/null; then
      return 0
    fi
    if ! kill -0 "$drive_pid" 2>/dev/null; then
      cat "$drive_log"
      echo "::error::Android integration test exited before the ${checkpoint} checkpoint."
      return 1
    fi
    sleep 1
  done
  cat "$drive_log"
  echo "::error::Timed out waiting for the Android ${checkpoint} checkpoint."
  return 1
}

wait_for_flutter_marker 'HTC_ANDROID_BG_ACCEPTANCE_READY:' 'background-server'

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
wait_for_flutter_marker 'HTC_ANDROID_MQTT_BG_ACCEPTANCE_READY' 'MQTT-background'

adb shell input keyevent KEYCODE_HOME
sleep 2
service_dump="$(adb shell dumpsys activity services)"
if ! grep -Fq 'RadioWebServerService' <<< "$service_dump"; then
  cat "$drive_log"
  echo '::error::Android foreground service stopped when Home Assistant MQTT was the only active network feature.'
  exit 1
fi

mqtt_only_status="$(curl --connect-timeout 2 --max-time 4 --silent --output /dev/null --write-out '%{http_code}' http://127.0.0.1:18735/login || true)"
if [[ "$mqtt_only_status" == '200' ]]; then
  cat "$drive_log"
  echo '::error::Android web server was still listening after its setting was disabled.'
  exit 1
fi
echo 'Android foreground service remained active for Home Assistant MQTT with the web server stopped.'

adb shell am start -n com.meshcentral.htcommander/.MainActivity >/dev/null
if ! wait "$drive_pid"; then
  cat "$drive_log"
  exit 1
fi
cat "$drive_log"

for attempt in {1..10}; do
  service_dump="$(adb shell dumpsys activity services)"
  if ! grep -Fq 'RadioWebServerService' <<< "$service_dump"; then
    echo 'Android foreground service stopped after Home Assistant MQTT was disabled.'
    exit 0
  fi
  sleep 1
done
echo '::error::Android foreground service stayed active after all test network features were disabled.'
exit 1
