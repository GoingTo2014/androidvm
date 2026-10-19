#!/usr/bin/env bash
set -Eeuo pipefail

case "$SESSION_MINUTES" in
  30|60|120|180|240|300) ;;
  *) echo "Invalid SESSION_MINUTES: $SESSION_MINUTES"; exit 2 ;;
esac

VM_RAM_MB="${VM_RAM_MB:-2048}"
VM_CPU_CORES="${VM_CPU_CORES:-1}"
VM_DATA_PARTITION_SIZE="${VM_DATA_PARTITION_SIZE:-2G}"
VM_SD_CARD_ENABLED="${VM_SD_CARD_ENABLED:-disabled}"
VM_SD_CARD_SIZE="${VM_SD_CARD_SIZE:-1G}"
VM_DEVICE_MODE="${VM_DEVICE_MODE:-phone}"

case "$VM_RAM_MB" in
  1536|2048|3072|4096) ;;
  *) echo "::error::Invalid VM_RAM_MB: $VM_RAM_MB"; exit 2 ;;
esac
case "$VM_CPU_CORES" in
  1|2|4) ;;
  *) echo "::error::Invalid VM_CPU_CORES: $VM_CPU_CORES"; exit 2 ;;
esac
case "$VM_DATA_PARTITION_SIZE" in
  1G|2G|4G|8G) ;;
  *) echo "::error::Invalid VM_DATA_PARTITION_SIZE: $VM_DATA_PARTITION_SIZE"; exit 2 ;;
esac
case "$VM_SD_CARD_ENABLED" in
  disabled|enabled) ;;
  *) echo "::error::Invalid VM_SD_CARD_ENABLED: $VM_SD_CARD_ENABLED"; exit 2 ;;
esac
case "$VM_SD_CARD_SIZE" in
  256M|512M|1G|2G|4G|8G) ;;
  *) echo "::error::Invalid VM_SD_CARD_SIZE: $VM_SD_CARD_SIZE"; exit 2 ;;
esac
case "$VM_DEVICE_MODE" in
  phone|tablet) ;;
  *) echo "::error::Invalid VM_DEVICE_MODE: $VM_DEVICE_MODE"; exit 2 ;;
esac

export ANDROID_HOME="$HOME/.android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export ANDROID_AVD_HOME="$RUNNER_TEMP/android-avd"
export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"
mkdir -p "$ANDROID_HOME" "$ANDROID_AVD_HOME"

EMULATOR_PID=""
XVFB_PID=""
SELKIES_PID=""
WM_PID=""
TUNNEL_PID=""
cleanup() {
  echo "Stopping AndroidVM session processes..."
  for pid in "$TUNNEL_PID" "$SELKIES_PID" "$WM_PID" "$EMULATOR_PID" "$XVFB_PID"; do
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi
  done
  wait 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "Installing system packages..."
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  xvfb pulseaudio nginx apache2-utils \
  openbox xdotool wmctrl \
  curl unzip ca-certificates libnss3 libasound2t64 libxkbcommon-x11-0 libxcb-cursor0

echo "Installing verified Selkies 2.0.0 package..."
SELKIES_DEB="$RUNNER_TEMP/selkies-2.0.0-ubuntu24.04-amd64.deb"
curl -fL --retry 3 --retry-delay 2 \
  "https://github.com/selkies-project/selkies/releases/download/2.0.0/selkies-2.0.0-ubuntu24.04-amd64.deb" \
  -o "$SELKIES_DEB"
echo "bbaa4d71012b9374a753b7dfddc1da07e31f34b04277fe4fb3d045f18fd88391  $SELKIES_DEB" | sha256sum --check
sudo apt-get install -y "$SELKIES_DEB"
selkies --version

AVDMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager"
if [ ! -x "$ANDROID_HOME/platform-tools/adb" ] \
  || [ ! -x "$ANDROID_HOME/emulator/emulator" ] \
  || [ ! -f "$ANDROID_HOME/system-images/android-19/google_apis/x86/system.img" ]; then
  echo "::error::The cached Android SDK or KitKat x86 system image is incomplete."
  echo "The prepare-android-sdk step should have installed all required packages."
  exit 1
fi

echo "Creating KitKat AVD..."
AVD_DEVICE_ARGS=()
if [ "$VM_DEVICE_MODE" = "tablet" ]; then
  # Prefer Google's real first-generation Nexus 7 hardware profile from the SDK.
  # It supplies the tablet's 800x1280 tvdpi display, hardware identity, sensors,
  # and other profile settings; we only force landscape below.
  "$AVDMANAGER" list device > "$RUNNER_TEMP/avd-device-list.txt"
  TABLET_DEVICE_SELECTION="$(awk '
    /^[[:space:]]*id:/ {
      id=$0
      sub(/^[[:space:]]*id:[[:space:]]*/, "", id)
      if (match(id, /"[^"]+"/)) id=substr(id, RSTART+1, RLENGTH-2)
      else sub(/[[:space:],].*$/, "", id)
    }
    /^[[:space:]]*Name:/ {
      name=$0
      sub(/^[[:space:]]*Name:[[:space:]]*/, "", name)
      gsub(/[[:space:]]+$/, "", name)
      lower=tolower(name)
      if (lower == "nexus 7" || lower == "nexus 7 (2012)") best=id "|" name
      else if (fallback == "" && lower ~ /7in wxga.*nexus 7/) fallback=id "|" name
      else if (fallback == "" && lower ~ /10[.]1in wxga.*tablet/) fallback=id "|" name
      else if (fallback == "" && lower ~ /7in wsvga.*tablet/) fallback=id "|" name
    }
    END {
      if (best != "") print best
      else if (fallback != "") print fallback
    }
  ' "$RUNNER_TEMP/avd-device-list.txt")"
  TABLET_PROFILE_NAME=""
  IFS='|' read -r TABLET_DEVICE_ID TABLET_PROFILE_NAME <<< "$TABLET_DEVICE_SELECTION"
  if [ -z "$TABLET_DEVICE_ID" ]; then
    echo "::error::No predefined Nexus 7 or compatible tablet profile was found in the installed Android SDK."
    grep -i -A 2 -B 1 'nexus 7\|tablet' "$RUNNER_TEMP/avd-device-list.txt" | head -n 120 || true
    exit 1
  fi
  echo "Using predefined Android tablet profile: $TABLET_PROFILE_NAME (ID: $TABLET_DEVICE_ID)"
  AVD_DEVICE_ARGS=(--device "$TABLET_DEVICE_ID")
fi

printf 'no\n' | "$AVDMANAGER" create avd \
  --name KitKat \
  --package "system-images;android-19;google_apis;x86" \
  "${AVD_DEVICE_ARGS[@]}" \
  --force
cat >> "$ANDROID_AVD_HOME/KitKat.avd/config.ini" <<AVD_CONFIG
hw.cpu.ncore=$VM_CPU_CORES
hw.ramSize=$VM_RAM_MB
hw.gpu.enabled=no
hw.gpu.mode=off
showDeviceFrame=no
disk.dataPartition.size=$VM_DATA_PARTITION_SIZE
AVD_CONFIG

if [ "$VM_DEVICE_MODE" = "tablet" ]; then
  # Keep the real profile's native pixels and tvdpi density; rotate it to landscape.
  # 1440x900 is the host canvas so a 1280x800 tablet window plus its Openbox titlebar fits.
  cat >> "$ANDROID_AVD_HOME/KitKat.avd/config.ini" <<'AVD_TABLET_CONFIG'
hw.initialOrientation=landscape
hw.keyboard=no
AVD_TABLET_CONFIG
  echo "Configured genuine Android tablet profile in landscape; original profile display density/resolution retained."
else
  # Preserve the existing phone behavior and browser keyboard support.
  cat >> "$ANDROID_AVD_HOME/KitKat.avd/config.ini" <<'AVD_PHONE_CONFIG'
hw.keyboard=yes
skin.dynamic=no
AVD_PHONE_CONFIG
  echo "Using the existing default phone display profile."
fi

SDCARD_ARGS=()
if [ "$VM_SD_CARD_ENABLED" = "enabled" ]; then
  echo "Creating $VM_SD_CARD_SIZE virtual SD card..."
  "$ANDROID_HOME/emulator/mksdcard" -l AndroidVM "$VM_SD_CARD_SIZE" "$ANDROID_AVD_HOME/KitKat.avd/sdcard.img"
  SDCARD_ARGS=(-sdcard "$ANDROID_AVD_HOME/KitKat.avd/sdcard.img")
else
  echo "Virtual SD card is disabled."
fi

DISPLAY_WIDTH=1280
DISPLAY_HEIGHT=800
if [ "$VM_DEVICE_MODE" = "tablet" ]; then
  DISPLAY_WIDTH=1440
  DISPLAY_HEIGHT=900
fi
echo "Starting virtual display at ${DISPLAY_WIDTH}x${DISPLAY_HEIGHT}..."
Xvfb :99 -screen 0 "${DISPLAY_WIDTH}x${DISPLAY_HEIGHT}x24" -s 0 -dpms -ac \
  +extension COMPOSITE +extension DAMAGE +extension GLX +extension RANDR \
  +extension RENDER +extension MIT-SHM +extension XFIXES +extension XTEST \
  +iglx +render -nolisten tcp -noreset > "$RUNNER_TEMP/xvfb.log" 2>&1 &
XVFB_PID=$!
export DISPLAY=:99
sleep 2
xsetroot -solid "#151820" || true
openbox --sm-disable > "$RUNNER_TEMP/openbox.log" 2>&1 &
WM_PID=$!
sleep 2

echo "Checking for KVM hardware acceleration..."
if [ -e /dev/kvm ]; then
  sudo chmod a+rw /dev/kvm || true
fi
ACCEL_MODE=off
if "$ANDROID_HOME/emulator/emulator" -accel-check > "$RUNNER_TEMP/accel-check.log" 2>&1; then
  ACCEL_MODE=on
fi
if [ "$ACCEL_MODE" = "on" ]; then
  echo "KVM is available. Android Emulator will use hardware acceleration."
else
  echo "::warning::KVM is not available on this runner; Android will use software emulation and may be very slow."
  cat "$RUNNER_TEMP/accel-check.log" || true
  export ANDROID_I_WANT_MY_TCG=yes
fi

AUDIO_AVAILABLE=0
if pulseaudio --start --exit-idle-time=-1; then
  sleep 1
  if pactl load-module module-null-sink sink_name=vm_audio sink_properties=device.description=AndroidVM >/dev/null 2>&1 \
    && pactl set-default-sink vm_audio; then
    AUDIO_AVAILABLE=1
  fi
fi
if [ "$AUDIO_AVAILABLE" = "0" ]; then
  echo "::warning::PulseAudio could not be configured; VM audio will be unavailable."
fi

echo "Starting Android 4.4 emulator..."
EMULATOR_AUDIO_ENV=""
EMULATOR_AUDIO_FLAG=""
if [ "$AUDIO_AVAILABLE" = "1" ]; then
  EMULATOR_AUDIO_ENV="PULSE_SINK=vm_audio QEMU_AUDIO_DRV=pa"
else
  EMULATOR_AUDIO_FLAG="-no-audio"
fi

EMULATOR_ARGS=(
  -avd KitKat
  -port 5554
  -accel "$ACCEL_MODE"
  -writable-system
  -no-snapshot
  -no-boot-anim
  -gpu off
  -show-kernel
  -logcat '*:E'
  -no-metrics
  -memory "$VM_RAM_MB"
  -cores "$VM_CPU_CORES"
)
if [ "$VM_SD_CARD_ENABLED" = "enabled" ]; then
  EMULATOR_ARGS+=("${SDCARD_ARGS[@]}")
fi

if [ "$ACCEL_MODE" = "off" ]; then
  nohup env $EMULATOR_AUDIO_ENV ANDROID_I_WANT_MY_TCG=yes \
    "$ANDROID_HOME/emulator/emulator" "${EMULATOR_ARGS[@]}" $EMULATOR_AUDIO_FLAG \
    > "$RUNNER_TEMP/emulator.log" 2>&1 &
else
  nohup env $EMULATOR_AUDIO_ENV \
    "$ANDROID_HOME/emulator/emulator" "${EMULATOR_ARGS[@]}" $EMULATOR_AUDIO_FLAG \
    > "$RUNNER_TEMP/emulator.log" 2>&1 &
fi
EMULATOR_PID=$!

wait_for_android() {
  local label="$1"
  local attempts="${2:-240}"
  local booted=0
  echo "Waiting for Android ($label; maximum $((attempts * 2)) seconds)..."
  for i in $(seq 1 "$attempts"); do
    if adb devices 2>/dev/null | grep -q 'emulator-5554[[:space:]]*device'; then
      if adb -s emulator-5554 shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' | grep -q '^1$'; then
        booted=1
        break
      fi
    fi
    if ! kill -0 "$EMULATOR_PID" 2>/dev/null; then
      echo "::error::Android Emulator exited during $label. Recent emulator log:"
      tail -n 160 "$RUNNER_TEMP/emulator.log" || true
      return 1
    fi
    sleep 2
  done
  if [ "$booted" -ne 1 ]; then
    echo "::error::Android did not finish booting during $label."
    echo "ADB device status:"
    adb devices -l || true
    echo "ADB get-state:"
    adb -s emulator-5554 get-state 2>&1 || true
    echo "Android system properties (boot/service state):"
    adb -s emulator-5554 shell getprop 2>&1 | tail -n 240 || true
    echo "Android process list:"
    adb -s emulator-5554 shell ps 2>&1 | tail -n 160 || true
    echo "Android main log buffer:"
    adb -s emulator-5554 shell logcat -d -b main -t 200 2>&1 | tail -n 140 || true
    echo "Android system log buffer:"
    adb -s emulator-5554 shell logcat -d -b system -t 200 2>&1 | tail -n 140 || true
    echo "Android events log buffer:"
    adb -s emulator-5554 shell logcat -d -b events -t 200 2>&1 | tail -n 100 || true
    echo "Kernel ring buffer:"
    adb -s emulator-5554 shell dmesg 2>&1 | tail -n 140 || true
    echo "Recent emulator and guest-kernel log:"
    tail -n 240 "$RUNNER_TEMP/emulator.log" || true
    return 1
  fi
}

wait_for_android "initial boot" 240

center_emulator_window() {
  local window_id="" geometry="" width="" height="" x="" y=""
  for i in $(seq 1 30); do
    window_id="$(wmctrl -l 2>/dev/null | grep -iE 'android emulator|kitkat' | awk 'NR==1 {print $1}' || true)"
    if [ -n "$window_id" ]; then
      geometry="$(xdotool getwindowgeometry --shell "$window_id" 2>/dev/null || true)"
      width="$(printf '%s\n' "$geometry" | awk -F= '$1=="WIDTH" {print $2}')"
      height="$(printf '%s\n' "$geometry" | awk -F= '$1=="HEIGHT" {print $2}')"
      if [[ "$width" =~ ^[0-9]+$ && "$height" =~ ^[0-9]+$ ]]; then
        x=$(( (DISPLAY_WIDTH - width) / 2 ))
        y=$(( (DISPLAY_HEIGHT - height) / 2 ))
        (( x < 0 )) && x=0
        (( y < 0 )) && y=0
        wmctrl -ir "$window_id" -e "0,$x,$y,-1,-1" || true
        echo "Centered the movable Android Emulator window at $x,$y (size $width x $height)."
        return 0
      fi
    fi
    sleep 1
  done
  echo "::warning::Could not auto-center the Android Emulator window; it may still be positioned manually."
  wmctrl -l || true
}
center_emulator_window
adb -s emulator-5554 shell settings put system screen_off_timeout 2147483647 || true
adb -s emulator-5554 shell input keyevent 82 || true
echo "Android 4.4 booted successfully."

ROOT_ACCESS="${ROOT_ACCESS:-disabled}"
mapfile -d '' NORMAL_APKS < <(find "$GITHUB_WORKSPACE/apks" -maxdepth 1 -type f -iname '*.apk' -print0 | sort -z)
mapfile -d '' SYSTEM_APKS < <(find "$GITHUB_WORKSPACE/systemapks" -maxdepth 1 -type f -iname '*.apk' -print0 | sort -z)
echo "Found ${#NORMAL_APKS[@]} normal APK(s) and ${#SYSTEM_APKS[@]} system APK(s)."

ROOT_ACTIVE=0
if [ "$ROOT_ACCESS" = "enabled" ] || [ "${#SYSTEM_APKS[@]}" -gt 0 ]; then
  echo "Requesting Android ADB root access..."
  ROOT_OUTPUT="$(adb -s emulator-5554 root 2>&1 || true)"
  echo "$ROOT_OUTPUT"
  sleep 2
  adb -s emulator-5554 wait-for-device
  if adb -s emulator-5554 shell id 2>/dev/null | grep -q 'uid=0'; then
    ROOT_ACTIVE=1
    echo "ADB root access is active."
  elif [ "$ROOT_ACCESS" = "enabled" ]; then
    echo "::error::Root access was requested, but this Android image did not allow adb root."
    exit 1
  elif [ "${#SYSTEM_APKS[@]}" -gt 0 ]; then
    echo "::error::System APKs were provided, but adb root is unavailable so they cannot be installed into /system/app."
    exit 1
  fi
fi

if [ "${#SYSTEM_APKS[@]}" -gt 0 ]; then
  echo "Installing system APKs into the Android /system/app partition..."
  if [ "$ROOT_ACTIVE" -ne 1 ]; then
    echo "::error::Cannot install system APKs without root access."
    exit 1
  fi
  if ! adb -s emulator-5554 remount; then
    echo "::error::Could not remount /system writable. Check emulator logs."
    exit 1
  fi
  SYSTEM_INDEX=0
  for apk in "${SYSTEM_APKS[@]}"; do
    SYSTEM_INDEX=$((SYSTEM_INDEX + 1))
    destination="/system/app/AndroidVMInjected${SYSTEM_INDEX}.apk"
    echo "Installing system APK: $(basename "$apk") -> $destination"
    if adb -s emulator-5554 push "$apk" "$destination" \
      && adb -s emulator-5554 shell chown 0.0 "$destination" \
      && adb -s emulator-5554 shell chmod 0644 "$destination"; then
      echo "System APK copied: $(basename "$apk")"
    else
      echo "::warning::Failed to copy system APK: $(basename "$apk")"
    fi
  done
  echo "Rebooting Android so Package Manager scans system APKs..."
  adb -s emulator-5554 reboot
  wait_for_android "system APK scan reboot" 240
fi

if [ "$ROOT_ACCESS" = "enabled" ]; then
  echo "Leaving ADB running as root..."
  ROOT_OUTPUT="$(adb -s emulator-5554 root 2>&1 || true)"
  echo "$ROOT_OUTPUT"
  sleep 2
  adb -s emulator-5554 wait-for-device
  if ! adb -s emulator-5554 shell id 2>/dev/null | grep -q 'uid=0'; then
    echo "::error::Could not keep ADB root access enabled after boot."
    exit 1
  fi
  echo "Root access enabled for this Android VM session."
else
  if [ "$ROOT_ACTIVE" -eq 1 ]; then
    echo "Disabling ADB root after system APK installation..."
    adb -s emulator-5554 unroot || true
    sleep 2
    adb -s emulator-5554 wait-for-device
  fi
  echo "Root access is disabled for this session."
fi

for apk in "${NORMAL_APKS[@]}"; do
  echo "Installing normal APK: $(basename "$apk")"
  if adb -s emulator-5554 install -r "$apk"; then
    echo "APK installed: $(basename "$apk")"
  else
    echo "::warning::Could not install normal APK: $(basename "$apk"). Check that it supports Android 4.4."
  fi
done

echo "Starting Selkies H.264 desktop streaming..."
SELKIES_ARGS=(
  --addr=127.0.0.1
  --port=6080
  --enable-https=false
  --enable-basic-auth=false
  --mode=websockets
  --enable-dual-mode=true
  --encoder=h264enc
  --use-cpu=true
  --enable-resize=false
  --framerate=60,8-60
)
if [ "$AUDIO_AVAILABLE" = "1" ]; then
  SELKIES_ARGS+=(--audio-device-name=vm_audio.monitor)
else
  echo "::warning::PulseAudio is unavailable; starting Selkies with audio disabled."
  SELKIES_ARGS+=(--audio-enabled=false)
fi
nohup selkies "${SELKIES_ARGS[@]}" > "$RUNNER_TEMP/selkies.log" 2>&1 &
SELKIES_PID=$!

echo "Waiting for Selkies HTTP service..."
SELKIES_HTTP_OK=0
for i in $(seq 1 45); do
  if curl --silent --show-error --fail http://127.0.0.1:6080/ \
    -o "$RUNNER_TEMP/selkies-homepage.html"; then
    if grep -qi "Selkies" "$RUNNER_TEMP/selkies-homepage.html"; then
      SELKIES_HTTP_OK=1
      break
    fi
  fi
  if ! kill -0 "$SELKIES_PID" 2>/dev/null; then
    echo "::error::Selkies exited during startup. Recent log:"
    tail -n 160 "$RUNNER_TEMP/selkies.log" || true
    exit 1
  fi
  sleep 1
done
if [ "$SELKIES_HTTP_OK" -ne 1 ]; then
  echo "::error::Selkies did not serve its expected web client."
  cat "$RUNNER_TEMP/selkies-homepage.html" 2>/dev/null | head -n 40 || true
  tail -n 160 "$RUNNER_TEMP/selkies.log" || true
  exit 1
fi
echo "Selkies HTTP smoke test passed."
echo "Configuring web gateway..."
sudo cp nginx/androidvm.conf.template /etc/nginx/sites-available/androidvm
if [ -n "$VM_ACCESS_PASSWORD" ]; then
  printf '%s\n' "$(htpasswd -Bbn vm "$VM_ACCESS_PASSWORD")" | sudo tee /etc/nginx/.androidvm.htpasswd >/dev/null
  sudo chown root:www-data /etc/nginx/.androidvm.htpasswd
  sudo chmod 640 /etc/nginx/.androidvm.htpasswd
  if ! sudo -u www-data test -r /etc/nginx/.androidvm.htpasswd; then
    echo "::error::Nginx worker (www-data) cannot read its Basic Auth password file."
    exit 1
  fi
  sudo sed -i '/__AUTH_DIRECTIVES__/c\    auth_basic "Android VM";\n    auth_basic_user_file /etc/nginx/.androidvm.htpasswd;' /etc/nginx/sites-available/androidvm
  echo "HTTP Basic Authentication is enabled (username: vm)."
else
  sudo sed -i '/__AUTH_DIRECTIVES__/d' /etc/nginx/sites-available/androidvm
  echo "::warning::VM_ACCESS_PASSWORD is not set. Anyone with the public tunnel URL can control this VM."
fi
sudo rm -f /etc/nginx/sites-enabled/default
sudo ln -sf /etc/nginx/sites-available/androidvm /etc/nginx/sites-enabled/androidvm
sudo nginx -t
sudo systemctl restart nginx

echo "Testing the local web gateway before publishing its tunnel..."
if [ -n "$VM_ACCESS_PASSWORD" ]; then
  if ! curl --silent --show-error --fail --user "vm:$VM_ACCESS_PASSWORD" \
    http://127.0.0.1:8080/ -o "$RUNNER_TEMP/androidvm-homepage.html"; then
    echo "::error::The authenticated homepage failed its local HTTP test."
    sudo tail -n 100 /var/log/nginx/error.log || true
    exit 1
  fi
else
  if ! curl --silent --show-error --fail \
    http://127.0.0.1:8080/ -o "$RUNNER_TEMP/androidvm-homepage.html"; then
    echo "::error::The homepage failed its local HTTP test."
    sudo tail -n 100 /var/log/nginx/error.log || true
    exit 1
  fi
fi
if ! grep -qi "Selkies" "$RUNNER_TEMP/androidvm-homepage.html"; then
  echo "::error::Nginx returned a response, but it was not the Selkies web client."
  sudo tail -n 100 /var/log/nginx/error.log || true
  exit 1
fi
echo "The gateway returned the Selkies web client successfully."

echo "Installing cloudflared..."
curl -fL --retry 3 --retry-delay 2 \
  https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb \
  -o "$RUNNER_TEMP/cloudflared.deb"
sudo dpkg -i "$RUNNER_TEMP/cloudflared.deb"

echo "Starting TryCloudflare tunnel..."
cloudflared tunnel --no-autoupdate --url http://127.0.0.1:8080 \
  > "$RUNNER_TEMP/cloudflared.log" 2>&1 &
TUNNEL_PID=$!

TUNNEL_URL=""
for i in $(seq 1 90); do
  TUNNEL_URL="$(grep -Eo 'https://[-a-z0-9]+\.trycloudflare\.com' "$RUNNER_TEMP/cloudflared.log" | head -n 1 || true)"
  if [ -n "$TUNNEL_URL" ]; then break; fi
  if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then break; fi
  sleep 2
done
if [ -z "$TUNNEL_URL" ]; then
  echo "::error::Cloudflare did not provide a URL. Tunnel log:"
  tail -n 100 "$RUNNER_TEMP/cloudflared.log" || true
  exit 1
fi

if [ -n "$GITHUB_OUTPUT" ]; then
  echo "url=$TUNNEL_URL" >> "$GITHUB_OUTPUT"
fi
echo ""
echo "=========================================================="
echo "ANDROID VM IS READY"
echo "Open: $TUNNEL_URL"
echo "Android: 4.4 KitKat x86"
echo "KVM acceleration: $ACCEL_MODE"
echo "Streaming: Selkies 2.0.0 H.264 over WebSocket (browser mouse/keyboard)"
echo "Audio: $AUDIO_AVAILABLE (Opus through Selkies)"
echo "RAM: $VM_RAM_MB MB"
echo "CPU cores: $VM_CPU_CORES"
if [ "$VM_DEVICE_MODE" = "tablet" ]; then
  echo "Device mode: Tablet ($TABLET_PROFILE_NAME; landscape with native profile resolution/density)"
else
  echo "Device mode: Phone (default display profile)"
fi
echo "Internal data storage: $VM_DATA_PARTITION_SIZE"
echo "SD card: $VM_SD_CARD_ENABLED"
if [ "$VM_SD_CARD_ENABLED" = "enabled" ]; then echo "SD card size: $VM_SD_CARD_SIZE"; fi
echo "Session length: $SESSION_MINUTES minutes"
echo "=========================================================="
echo "The URL is temporary and allows control of the running VM. Do not share it publicly."

REMAINING=$((SESSION_MINUTES * 60))
while [ "$REMAINING" -gt 0 ]; do
  if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
    echo "::error::TryCloudflare tunnel stopped."
    tail -n 100 "$RUNNER_TEMP/cloudflared.log" || true
    exit 1
  fi
  if ! kill -0 "$EMULATOR_PID" 2>/dev/null; then
    echo "::error::Android Emulator stopped."
    tail -n 160 "$RUNNER_TEMP/emulator.log" || true
    exit 1
  fi
  if ! kill -0 "$SELKIES_PID" 2>/dev/null; then
    echo "::error::Selkies streaming server stopped."
    tail -n 160 "$RUNNER_TEMP/selkies.log" || true
    exit 1
  fi
  sleep 30
  REMAINING=$((REMAINING - 30))
done

echo "Configured VM session duration has elapsed."
