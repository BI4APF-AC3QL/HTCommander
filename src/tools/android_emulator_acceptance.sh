#!/usr/bin/env bash
set -euo pipefail

src_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_root="$(cd "$src_root/.." && pwd)"

# This test uninstalls the release package before installing the debug
# integration APK, which clears app data. Never allow it to run on a phone.
emulator_serial="${ANDROID_SERIAL:-}"
if [[ -z "$emulator_serial" ]]; then
  mapfile -t connected_emulators < <(
    adb devices | awk 'NR > 1 && $2 == "device" && $1 ~ /^emulator-[0-9]+$/ { print $1 }'
  )
  if [[ "${#connected_emulators[@]}" -ne 1 ]]; then
    echo '::error::Set ANDROID_SERIAL to one connected emulator; this acceptance test must not run on a physical phone.'
    exit 1
  fi
  emulator_serial="${connected_emulators[0]}"
fi
if [[ ! "$emulator_serial" =~ ^emulator-[0-9]+$ ]]; then
  echo '::error::ANDROID_SERIAL must identify an Android emulator; physical devices are not allowed because the test uninstalls the app.'
  exit 1
fi
if [[ "$(adb -s "$emulator_serial" get-state 2>/dev/null || true)" != 'device' ]]; then
  echo "::error::Android emulator $emulator_serial is not connected and ready."
  exit 1
fi
adb_cmd() {
  command adb -s "$emulator_serial" "$@"
}

device_abi="$(adb_cmd shell getprop ro.product.cpu.abi | tr -d '\r')"
case "$device_abi" in
  x86_64|x86|arm64-v8a|armeabi-v7a) ;;
  *)
    echo "::error::Unsupported Android emulator ABI: ${device_abi:-unknown}."
    exit 1
    ;;
esac
release_apk="$repo_root/src/build/app/outputs/flutter-apk/app-${device_abi}-release.apk"
if [[ ! -f "$release_apk" ]]; then
  echo "::error::No release APK found for emulator ABI $device_abi: $release_apk"
  exit 1
fi

adb_cmd logcat -c
adb_cmd install -r "$release_apk"
adb_cmd shell am start -n com.meshcentral.htcommander/.MainActivity

app_process_ids() {
  local pids
  pids="$(adb_cmd shell pidof com.meshcentral.htcommander 2>/dev/null | tr -d '\r' || true)"
  if [[ -n "$pids" ]]; then
    printf '%s\n' "$pids"
    return
  fi

  adb_cmd shell ps -A -o PID,NAME 2>/dev/null \
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
  adb_cmd shell ps -A -o PID,NAME || true
  adb_cmd shell dumpsys activity activities | grep -E 'mResumedActivity|topResumedActivity|com\.meshcentral\.htcommander' | tail -n 80 || true
  adb_cmd logcat -d -b crash -v threadtime || true
  adb_cmd logcat -d -v threadtime \
    | grep -E 'com\.meshcentral\.htcommander|AndroidRuntime|FATAL EXCEPTION|Fatal signal|ActivityTaskManager|ActivityManager' \
    | tail -n 500 || true
  exit 1
fi

sleep 15
crash_log="$(adb_cmd logcat -d -b crash)"
if grep -Fq 'Process: com.meshcentral.htcommander' <<< "$crash_log"; then
  echo '::error::HTCommander crashed on the Android emulator.'
  printf '%s\n' "$crash_log"
  exit 1
fi
app_pids="$(app_process_ids)"
if [[ -z "$app_pids" ]]; then
  echo '::error::HTCommander stopped running during the 15-second Android emulator launch check.'
  adb_cmd shell ps -A -o PID,NAME || true
  adb_cmd logcat -d -b crash -v threadtime || true
  adb_cmd logcat -d -v threadtime \
    | grep -E 'com\.meshcentral\.htcommander|AndroidRuntime|FATAL EXCEPTION|Fatal signal|ActivityTaskManager|ActivityManager' \
    | tail -n 500 || true
  exit 1
fi
echo "HTCommander $device_abi release APK installed and remained running for 15 seconds (PID(s): ${app_pids//$'\n'/, })."

# The release APK can use a repository signing key, while `flutter test` signs
# the integration-test APK with the debug key. The emulator is disposable, so
# remove the release install before the instrumented test installs its build.
adb_cmd uninstall com.meshcentral.htcommander
cd "$src_root"
test -f integration_test/android_remote_server_test.dart
drive_log="$(mktemp)"
drive_pid=""
cleanup() {
  adb_cmd forward --remove tcp:18735 >/dev/null 2>&1 || true
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
  -d "$emulator_serial" >"$drive_log" 2>&1 &
drive_pid=$!

wait_for_flutter_marker() {
  local marker="$1"
  local checkpoint="$2"
  # The hosted-browser checkpoint can spend up to 180 seconds loading the
  # packaged Flutter client, and the integration test keeps its server alive
  # for four minutes to cover that pass before advancing its own assertions.
  for attempt in {1..360}; do
    if adb_cmd logcat -d -s flutter:I | grep -F "$marker" >/dev/null; then
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

adb_cmd shell input keyevent KEYCODE_HOME
sleep 2
service_dump="$(adb_cmd shell dumpsys activity services)"
if ! grep -Fq 'RadioWebServerService' <<< "$service_dump"; then
  cat "$drive_log"
  echo '::error::Android foreground radio/server service was not running after the app went to background.'
  exit 1
fi

adb_cmd forward tcp:18735 tcp:18735
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

# Load both the authenticated mobile remote page and the actual Flutter web
# client from this release APK in Chromium. This catches broken packaged JS,
# CanvasKit, cookie auth and mobile-menu rendering that HTTP asset probes miss.
if ! node ../tools/android-hosted-browser-acceptance.cjs http://127.0.0.1:18735; then
  diagnostic_root="${HTC_ANDROID_BROWSER_OUTPUT:-${RUNNER_TEMP:-/tmp}/android-hosted-browser}"
  diagnostic_dir="$diagnostic_root/android-runtime"
  mkdir -p "$diagnostic_dir"
  cp "$drive_log" "$diagnostic_dir/flutter-drive.log"
  printf 'forwarded /login status: ' > "$diagnostic_dir/forwarded-login.txt"
  curl --connect-timeout 2 --max-time 4 --silent --output /dev/null \
    --write-out '%{http_code}\n' http://127.0.0.1:18735/login \
    >> "$diagnostic_dir/forwarded-login.txt" 2>&1 || true
  adb_cmd shell pidof com.meshcentral.htcommander \
    > "$diagnostic_dir/app-pid.txt" 2>&1 || true
  adb_cmd shell dumpsys activity services \
    | grep -E -A 12 -B 3 'RadioWebServerService|Foreground' \
    > "$diagnostic_dir/foreground-service.txt" 2>&1 || true
  adb_cmd shell dumpsys meminfo com.meshcentral.htcommander \
    > "$diagnostic_dir/app-memory.txt" 2>&1 || true
  adb_cmd logcat -d -b crash -v threadtime \
    > "$diagnostic_dir/crash-log.txt" 2>&1 || true
  adb_cmd logcat -d -v threadtime \
    | grep -E 'com\.meshcentral\.htcommander|AndroidRuntime|FATAL EXCEPTION|Fatal signal|OutOfMemory|ActivityTaskManager|ActivityManager' \
    | tail -n 500 > "$diagnostic_dir/app-log.txt" || true
  exit 1
fi

# The remote server also holds a Wi-Fi lock so the LAN endpoint stays
# reachable while Android turns the display off. Exercise this on the
# disposable emulator; this still does not model vendor-specific phone doze.
adb_cmd shell settings put global stay_on_while_plugged_in 0
adb_cmd shell input keyevent KEYCODE_SLEEP
screen_state=''
for attempt in {1..10}; do
  screen_state="$(adb_cmd shell dumpsys power | tr -d '\r')"
  if grep -Eq 'mWakefulness=Asleep|mInteractive=false' <<< "$screen_state"; then
    break
  fi
  sleep 1
done
if ! grep -Eq 'mWakefulness=Asleep|mInteractive=false' <<< "$screen_state"; then
  adb_cmd shell input keyevent KEYCODE_WAKEUP || true
  cat "$drive_log"
  echo '::error::Android emulator display did not turn off for the server reachability check.'
  exit 1
fi

screen_off_status="$(curl --connect-timeout 2 --max-time 4 --silent --output /dev/null --write-out '%{http_code}' http://127.0.0.1:18735/login || true)"
adb_cmd shell input keyevent KEYCODE_WAKEUP
if [[ "$screen_off_status" != '200' ]]; then
  cat "$drive_log"
  echo "::error::Android server did not serve /login with the display off (HTTP ${screen_off_status:-no response})."
  exit 1
fi
echo 'Android remote server remained reachable with the emulator display off.'

adb_cmd shell am start -n com.meshcentral.htcommander/.MainActivity >/dev/null
wait_for_flutter_marker 'HTC_ANDROID_RADIO_ONLY_BG_ACCEPTANCE_READY' 'radio-only-background'

adb_cmd shell input keyevent KEYCODE_HOME
sleep 2
service_dump="$(adb_cmd shell dumpsys activity services)"
if ! grep -Fq 'RadioWebServerService' <<< "$service_dump"; then
  cat "$drive_log"
  echo '::error::Android foreground service stopped when a connected radio was the only active feature.'
  exit 1
fi

radio_only_status="$(curl --connect-timeout 2 --max-time 4 --silent --output /dev/null --write-out '%{http_code}' http://127.0.0.1:18735/login || true)"
if [[ "$radio_only_status" == '200' ]]; then
  cat "$drive_log"
  echo '::error::Android HTTP server was still listening during the radio-only checkpoint.'
  exit 1
fi
echo 'Android foreground service remained active for a connected radio with the web server stopped.'

adb_cmd shell am start -n com.meshcentral.htcommander/.MainActivity >/dev/null
wait_for_flutter_marker 'HTC_ANDROID_RADIO_ONLY_RELEASE_READY' 'radio-only-service-release'

radio_service_stopped=0
for attempt in {1..10}; do
  service_dump="$(adb_cmd shell dumpsys activity services)"
  if ! grep -Fq 'RadioWebServerService' <<< "$service_dump"; then
    radio_service_stopped=1
    break
  fi
  sleep 1
done
if [[ "$radio_service_stopped" -ne 1 ]]; then
  cat "$drive_log"
  echo '::error::Android foreground service stayed active after the simulated radio disconnected.'
  exit 1
fi
echo 'Android foreground service stopped after the simulated radio disconnected.'

wait_for_flutter_marker 'HTC_ANDROID_RECORDING_BG_ACCEPTANCE_READY' 'rolling-recording-background'

adb_cmd shell input keyevent KEYCODE_HOME
sleep 2
service_dump="$(adb_cmd shell dumpsys activity services)"
if ! grep -Fq 'RadioWebServerService' <<< "$service_dump"; then
  cat "$drive_log"
  echo '::error::Android foreground service stopped while local rolling recording was enabled.'
  exit 1
fi
echo 'Android recording foreground service remained active after MainActivity moved to the background.'

wait_for_flutter_marker 'HTC_ANDROID_RECORDING_BACKGROUND_CHECKPOINT' 'rolling-recording-write'
service_dump="$(adb_cmd shell dumpsys activity services)"
if ! grep -Fq 'RadioWebServerService' <<< "$service_dump"; then
  cat "$drive_log"
  echo '::error::Android recording foreground service stopped before the background WAV write completed.'
  exit 1
fi
echo 'Android recorder wrote and finalized a synthetic WAV clip while backgrounded.'

wait_for_flutter_marker 'HTC_ANDROID_RECORDING_RELEASE_READY' 'rolling-recording-service-release'
recording_service_stopped=0
for attempt in {1..10}; do
  service_dump="$(adb_cmd shell dumpsys activity services)"
  if ! grep -Fq 'RadioWebServerService' <<< "$service_dump"; then
    recording_service_stopped=1
    break
  fi
  sleep 1
done
if [[ "$recording_service_stopped" -ne 1 ]]; then
  cat "$drive_log"
  echo '::error::Android foreground service stayed active after local rolling recording was disabled.'
  exit 1
fi
echo 'Android foreground service stopped after local rolling recording was disabled.'

adb_cmd shell am start -n com.meshcentral.htcommander/.MainActivity >/dev/null
wait_for_flutter_marker 'HTC_ANDROID_MQTT_BG_ACCEPTANCE_READY' 'MQTT-background'

adb_cmd shell input keyevent KEYCODE_HOME
sleep 2
service_dump="$(adb_cmd shell dumpsys activity services)"
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

adb_cmd shell am start -n com.meshcentral.htcommander/.MainActivity >/dev/null
if ! wait "$drive_pid"; then
  cat "$drive_log"
  exit 1
fi
cat "$drive_log"
if grep -Eq 'Some tests failed\.|Test timed out after' "$drive_log"; then
  echo '::error::Android Flutter integration test reported a failure or timeout.'
  exit 1
fi

for attempt in {1..10}; do
  service_dump="$(adb_cmd shell dumpsys activity services)"
  if ! grep -Fq 'RadioWebServerService' <<< "$service_dump"; then
    echo 'Android foreground service stopped after Home Assistant MQTT was disabled.'
    exit 0
  fi
  sleep 1
done
echo '::error::Android foreground service stayed active after all test network features were disabled.'
exit 1
