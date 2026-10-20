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
VM_HARDWARE_KEYBOARD="${VM_HARDWARE_KEYBOARD:-enabled}"
VM_GPU_MODE="${VM_GPU_MODE:-swiftshader}"
BROWSER_TO_INSTALL="${BROWSER_TO_INSTALL:-None}"
ANDROID_GOOGLE_PLAY_STORE="${ANDROID_GOOGLE_PLAY_STORE:-false}"
ANDROID_ARM="${ANDROID_ARM:-false}"
case "$ANDROID_ARM" in
  true|false) ;;
  *) echo "::error::Invalid ANDROID_ARM: $ANDROID_ARM (expected true or false)"; exit 2 ;;
esac

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
case "$VM_HARDWARE_KEYBOARD" in
  enabled) HW_KEYBOARD_CONFIG=yes ;;
  disabled) HW_KEYBOARD_CONFIG=no ;;
  *) echo "::error::Invalid VM_HARDWARE_KEYBOARD: $VM_HARDWARE_KEYBOARD"; exit 2 ;;
esac
case "$VM_GPU_MODE" in
  auto|host|software|swiftshader|lavapipe|swangle|off) ;;
  *) echo "::error::Invalid VM_GPU_MODE: $VM_GPU_MODE"; exit 2 ;;
esac
case "$BROWSER_TO_INSTALL" in
  "None") BROWSER_MIN_API=0; BROWSER_MAX_API=999 ;;
  "Firefox 68.11.0") BROWSER_MIN_API=16; BROWSER_MAX_API=999 ;;
  "Chrome 81.0.4044.138") BROWSER_MIN_API=19; BROWSER_MAX_API=23 ;;
  "Opera 58.8.2878.72999") BROWSER_MIN_API=19; BROWSER_MAX_API=20 ;;
  *) echo "::error::Invalid BROWSER_TO_INSTALL: $BROWSER_TO_INSTALL"; exit 2 ;;
esac

export ANDROID_HOME="$HOME/.android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export ANDROID_AVD_HOME="$RUNNER_TEMP/android-avd"
export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"
mkdir -p "$ANDROID_HOME" "$ANDROID_AVD_HOME"
source "${GITHUB_WORKSPACE:-$PWD}/scripts/android-version.sh"
if [ "$ANDROID_ARM" = "true" ] && [ "$BROWSER_TO_INSTALL" != "None" ]; then
  echo "::error::The built-in browser downloads are x86 APKs and cannot be used in ARM Android mode."
  echo "::error::Choose Browser to install = None and put a compatible ARM APK in apks/ instead."
  exit 2
fi
if [ "$ANDROID_GOOGLE_PLAY_STORE" = "true" ]; then
  if [ "$VM_DEVICE_MODE" = "tablet" ]; then
    echo "::error::The official Android 7.0 Google Play image is configured for phone mode only in AndroidVM."
    echo "::error::Choose Phone mode or disable Google Play Store to use a tablet profile."
    exit 2
  fi
  if [ "${ROOT_ACCESS:-disabled}" = "enabled" ]; then
    echo "::error::Google Play Store system images do not support ADB root. Set Root access to disabled."
    exit 2
  fi
  if find "${GITHUB_WORKSPACE:-$PWD}/systemapks" -maxdepth 1 -type f -iname '*.apk' -print -quit 2>/dev/null | grep -q .; then
    echo "::error::System APK injection requires ADB root, which is unavailable on Google Play Store images."
    exit 2
  fi
fi
if [ "$ANDROID_API_LEVEL" -lt "$BROWSER_MIN_API" ]; then
  echo "::error::$BROWSER_TO_INSTALL requires Android API $BROWSER_MIN_API or newer; selected $ANDROID_RELEASE (API $ANDROID_API_LEVEL)."
  exit 2
fi
if [ "$ANDROID_API_LEVEL" -gt "$BROWSER_MAX_API" ]; then
  echo "::error::$BROWSER_TO_INSTALL is configured for Android API $BROWSER_MAX_API or older; selected $ANDROID_RELEASE (API $ANDROID_API_LEVEL). Choose a compatible Android release."
  exit 2
fi

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
ALSA_PACKAGE=libasound2t64
if grep -qE '^VERSION_ID="22[.]04"' /etc/os-release; then
  ALSA_PACKAGE=libasound2
fi
RUNTIME_PACKAGES=(
  xvfb pulseaudio nginx apache2-utils
  openbox xdotool wmctrl
  curl unzip ca-certificates libnss3 "$ALSA_PACKAGE"
  libxkbcommon-x11-0 libxcb-cursor0
)
if [ "$ANDROID_ARM" = "true" ]; then
  # Android Emulator 28 and the self-contained Selkies AppImage are used for ARM KitKat.
  RUNTIME_PACKAGES+=(libfuse2 libncurses5 libtinfo5 libpulse0 x11-xserver-utils)
fi
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${RUNTIME_PACKAGES[@]}"

SELKIES_BIN=selkies
if [ "$ANDROID_ARM" = "true" ]; then
  echo "Installing checksum-verified Selkies 2.0.0 AppImage for the Ubuntu 22.04 ARM guest runner..."
  SELKIES_APP="$RUNNER_TEMP/selkies-2.0.0-x86_64.AppImage"
  curl -fL --retry 3 --retry-delay 2 \
    "https://github.com/selkies-project/selkies/releases/download/2.0.0/selkies-2.0.0-x86_64.AppImage" \
    -o "$SELKIES_APP"
  echo "8dcdbe239dc8930545819aae510c45283cf25922250b6b7348ff2fd790c41ed8  $SELKIES_APP" | sha256sum --check
  chmod +x "$SELKIES_APP"
  SELKIES_BIN="$SELKIES_APP"
else
  echo "Installing verified Selkies 2.0.0 Ubuntu 24.04 package..."
  SELKIES_DEB="$RUNNER_TEMP/selkies-2.0.0-ubuntu24.04-amd64.deb"
  curl -fL --retry 3 --retry-delay 2 \
    "https://github.com/selkies-project/selkies/releases/download/2.0.0/selkies-2.0.0-ubuntu24.04-amd64.deb" \
    -o "$SELKIES_DEB"
  echo "bbaa4d71012b9374a753b7dfddc1da07e31f34b04277fe4fb3d045f18fd88391  $SELKIES_DEB" | sha256sum --check
  sudo apt-get install -y "$SELKIES_DEB"
fi
"$SELKIES_BIN" --version

AVDMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager"
if [ ! -x "$ANDROID_HOME/platform-tools/adb" ] \
  || [ ! -x "$ANDROID_HOME/emulator/emulator" ] \
  || [ ! -f "$ANDROID_SYSTEM_IMAGE_DIR/system.img" ]; then
  echo "::error::The cached Android SDK or selected system image for $ANDROID_RELEASE is incomplete."
  echo "The prepare-android-sdk step should have installed all required packages."
  exit 1
fi

echo "Creating $ANDROID_RELEASE AVD..."
AVD_DEVICE_ARGS=()
if [ "$ANDROID_GOOGLE_PLAY_STORE" = "true" ]; then
  # Google Play API 24 images were originally published for compatible phone profiles.
  # Prefer Nexus 5, then Nexus 5X, rather than relying on an arbitrary default profile.
  "$AVDMANAGER" list device > "$RUNNER_TEMP/avd-device-list.txt"
  PLAY_DEVICE_SELECTION="$(awk '
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
      if (lower == "nexus 5") best=id "|" name
      else if (fallback == "" && lower == "nexus 5x") fallback=id "|" name
    }
    END {
      if (best != "") print best
      else if (fallback != "") print fallback
    }
  ' "$RUNNER_TEMP/avd-device-list.txt")"
  IFS='|' read -r PLAY_DEVICE_ID PLAY_PROFILE_NAME <<< "$PLAY_DEVICE_SELECTION"
  if [ -z "$PLAY_DEVICE_ID" ]; then
    echo "::error::No compatible Nexus 5/Nexus 5X phone profile was found for the Android 7.0 Google Play image."
    grep -i -A 2 -B 1 'nexus 5' "$RUNNER_TEMP/avd-device-list.txt" | head -n 80 || true
    exit 1
  fi
  echo "Using Google Play-compatible phone profile: $PLAY_PROFILE_NAME (ID: $PLAY_DEVICE_ID)"
  AVD_DEVICE_ARGS=(--device "$PLAY_DEVICE_ID")
elif [ "$VM_DEVICE_MODE" = "tablet" ]; then
  # Prefer Google's first-generation Nexus 7 hardware profile from the SDK.
  # The selected profile supplies display geometry/density and hardware settings;
  # the selected Android system image's build identity is preserved.
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
  --name "$ANDROID_AVD_NAME" \
  --package "$ANDROID_SYSTEM_IMAGE_PACKAGE" \
  "${AVD_DEVICE_ARGS[@]}" \
  --force
GPU_ENABLED=yes
if [ "$VM_GPU_MODE" = "off" ]; then
  GPU_ENABLED=no
fi
cat >> "$ANDROID_AVD_HOME/$ANDROID_AVD_NAME.avd/config.ini" <<AVD_CONFIG
hw.cpu.ncore=$VM_CPU_CORES
hw.ramSize=$VM_RAM_MB
hw.keyboard=$HW_KEYBOARD_CONFIG
hw.gpu.enabled=$GPU_ENABLED
hw.gpu.mode=$VM_GPU_MODE
showDeviceFrame=no
disk.dataPartition.size=$VM_DATA_PARTITION_SIZE
AVD_CONFIG

if [ "$VM_DEVICE_MODE" = "tablet" ]; then
  # Keep the real profile's native pixels and tvdpi density; rotate it to landscape.
  # 1440x900 is the host canvas so a 1280x800 tablet window plus its Openbox titlebar fits.
  cat >> "$ANDROID_AVD_HOME/$ANDROID_AVD_NAME.avd/config.ini" <<'AVD_TABLET_CONFIG'
hw.initialOrientation=landscape
AVD_TABLET_CONFIG
  echo "Configured tablet hardware profile in landscape; hardware keyboard setting: $VM_HARDWARE_KEYBOARD."
else
  # Preserve the existing phone behavior and browser keyboard support.
  cat >> "$ANDROID_AVD_HOME/$ANDROID_AVD_NAME.avd/config.ini" <<'AVD_PHONE_CONFIG'
skin.dynamic=no
AVD_PHONE_CONFIG
  echo "Using the existing default phone display profile."
fi

ANDROID_EMULATOR_BIN="$ANDROID_HOME/emulator/emulator"
ANDROID_EMULATOR_GPU_MODE="$VM_GPU_MODE"
if [ "$ANDROID_ARM" = "true" ]; then
  echo "Downloading the known-working legacy Android Emulator 28.0.22 for ARM KitKat..."
  LEGACY_SDK_DIR="$RUNNER_TEMP/legacy-sdk"
  LEGACY_EMULATOR="$LEGACY_SDK_DIR/emulator/emulator"
  curl -fL --retry 3 --retry-delay 2 --progress-bar \
    "https://dl.google.com/android/repository/emulator-linux-5194135.zip" \
    -o "$RUNNER_TEMP/emulator-linux-5194135.zip"
  rm -rf "$LEGACY_SDK_DIR"
  mkdir -p "$LEGACY_SDK_DIR"
  unzip -q "$RUNNER_TEMP/emulator-linux-5194135.zip" -d "$LEGACY_SDK_DIR"
  if [ ! -x "$LEGACY_EMULATOR" ]; then
    echo "::error::Legacy emulator 28.0.22 executable was not found."
    find "$LEGACY_SDK_DIR" -maxdepth 3 -type f -name emulator -print || true
    exit 1
  fi
  "$LEGACY_EMULATOR" -version | tee "$RUNNER_TEMP/legacy-emulator-version.txt"
  if ! "$LEGACY_EMULATOR" -version 2>&1 | grep -q '28[.]0[.]22'; then
    echo "::error::Downloaded emulator is not version 28.0.22."
    exit 1
  fi

  # Emulator 28 expects an absolute image directory and legacy SwiftShader mode.
  AVD_CONFIG="$ANDROID_AVD_HOME/$ANDROID_AVD_NAME.avd/config.ini"
  if [ ! -f "$ANDROID_SYSTEM_IMAGE_DIR/system.img" ]; then
    echo "::error::ARM system.img is missing: $ANDROID_SYSTEM_IMAGE_DIR/system.img"
    exit 1
  fi
  if grep -q '^image.sysdir.1=' "$AVD_CONFIG"; then
    sed -i "s|^image.sysdir.1=.*|image.sysdir.1=$ANDROID_SYSTEM_IMAGE_DIR/|" "$AVD_CONFIG"
  else
    printf 'image.sysdir.1=%s/\n' "$ANDROID_SYSTEM_IMAGE_DIR" >> "$AVD_CONFIG"
  fi
  if grep -q '^hw.gpu.enabled=' "$AVD_CONFIG"; then
    sed -i 's/^hw.gpu.enabled=.*/hw.gpu.enabled=yes/' "$AVD_CONFIG"
  else
    echo 'hw.gpu.enabled=yes' >> "$AVD_CONFIG"
  fi
  if grep -q '^hw.gpu.mode=' "$AVD_CONFIG"; then
    sed -i 's/^hw.gpu.mode=.*/hw.gpu.mode=swiftshader_indirect/' "$AVD_CONFIG"
  else
    echo 'hw.gpu.mode=swiftshader_indirect' >> "$AVD_CONFIG"
  fi
  ANDROID_EMULATOR_BIN="$LEGACY_EMULATOR"
  ANDROID_EMULATOR_GPU_MODE=swiftshader_indirect
  cp "$AVD_CONFIG" "$RUNNER_TEMP/arm-avd-config.txt"
  echo "ARM mode uses Android API 19 default (AOSP) image, Emulator 28.0.22, and SwiftShader."
  echo "Google Play Services is intentionally absent to prevent recurring legacy GMS crashes."
fi

SDCARD_ARGS=()
if [ "$VM_SD_CARD_ENABLED" = "enabled" ]; then
  echo "Creating $VM_SD_CARD_SIZE virtual SD card..."
  "$ANDROID_HOME/emulator/mksdcard" -l AndroidVM "$VM_SD_CARD_SIZE" "$ANDROID_AVD_HOME/$ANDROID_AVD_NAME.avd/sdcard.img"
  SDCARD_ARGS=(-sdcard "$ANDROID_AVD_HOME/$ANDROID_AVD_NAME.avd/sdcard.img")
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

echo "Checking CPU acceleration mode..."
if [ "$ANDROID_ARM" = "true" ]; then
  # The tested legacy ARM guest requires QEMU software CPU emulation, even on a KVM host.
  ACCEL_MODE=off
  echo "ARM KitKat uses software CPU emulation. Performance will be slower than x86 Android."
  export ANDROID_I_WANT_MY_TCG=yes
else
  if [ -e /dev/kvm ]; then
    sudo chmod a+rw /dev/kvm || true
  fi
  ACCEL_MODE=off
  if "$ANDROID_EMULATOR_BIN" -accel-check > "$RUNNER_TEMP/accel-check.log" 2>&1; then
    ACCEL_MODE=on
  fi
  if [ "$ACCEL_MODE" = "on" ]; then
    echo "KVM is available. Android Emulator will use hardware acceleration."
  else
    echo "::warning::KVM is not available on this runner; Android will use software emulation and may be very slow."
    cat "$RUNNER_TEMP/accel-check.log" || true
    export ANDROID_I_WANT_MY_TCG=yes
  fi
fi

AUDIO_AVAILABLE=0
AUDIO_DEVICE_NAME=vm_audio.monitor
if pulseaudio --start --exit-idle-time=-1; then
  sleep 1
  AUDIO_MODULE_ID="$(pactl load-module module-null-sink sink_name=vm_audio sink_properties=device.description=AndroidVM 2>&1 || true)"
  if [[ "$AUDIO_MODULE_ID" =~ ^[0-9]+$ ]] && pactl set-default-sink vm_audio; then
    sleep 1
    if pactl list short sources | awk '$2 == "vm_audio.monitor" { found=1 } END { exit !found }'; then
      AUDIO_AVAILABLE=1
      echo "PulseAudio capture source is ready: $AUDIO_DEVICE_NAME"
      pactl list short sinks || true
      pactl list short sources || true
    else
      echo "::warning::The AndroidVM PulseAudio sink exists, but its monitor source was not found."
      pactl list short sources || true
    fi
  else
    echo "::warning::Could not create/set the AndroidVM PulseAudio sink."
    pactl list short sinks || true
    pactl list short sources || true
  fi
else
  echo "::warning::PulseAudio failed to start."
fi
if [ "$AUDIO_AVAILABLE" = "0" ]; then
  echo "::warning::PulseAudio capture is unavailable; VM audio will be disabled."
fi

echo "Starting $ANDROID_RELEASE emulator with graphics mode '$ANDROID_EMULATOR_GPU_MODE'..."
EMULATOR_AUDIO_ENV=()
EMULATOR_AUDIO_ARGS=()
if [ "$AUDIO_AVAILABLE" = "1" ]; then
  EMULATOR_AUDIO_ENV=(PULSE_SINK=vm_audio QEMU_AUDIO_DRV=pa)
  echo "Android Emulator audio backend: PulseAudio (vm_audio); Selkies will capture vm_audio.monitor."
else
  EMULATOR_AUDIO_ARGS=(-no-audio)
  echo "::warning::PulseAudio is unavailable; Android emulator audio and browser audio are disabled."
fi

EMULATOR_ARGS=(
  -avd "$ANDROID_AVD_NAME"
  -port 5554
  -accel "$ACCEL_MODE"
  -no-snapshot
  -no-boot-anim
  -gpu "$ANDROID_EMULATOR_GPU_MODE"
  -show-kernel
  -memory "$VM_RAM_MB"
)
if [ "$ANDROID_ARM" = "true" ]; then
  # Emulator 28.0.22 rejects -no-metrics and the newer -cores argument.
  EMULATOR_ARGS+=(-verbose)
else
  EMULATOR_ARGS+=(-logcat '*:E' -no-metrics -cores "$VM_CPU_CORES")
fi
if [ "$ANDROID_GOOGLE_PLAY_STORE" != "true" ]; then
  EMULATOR_ARGS+=(-writable-system)
else
  echo "Using the signed Google Play system image without -writable-system."
fi
if [ "$VM_SD_CARD_ENABLED" = "enabled" ]; then
  EMULATOR_ARGS+=("${SDCARD_ARGS[@]}")
fi

if [ "$ACCEL_MODE" = "off" ]; then
  nohup env "${EMULATOR_AUDIO_ENV[@]}" ANDROID_I_WANT_MY_TCG=yes \
    "$ANDROID_EMULATOR_BIN" "${EMULATOR_ARGS[@]}" "${EMULATOR_AUDIO_ARGS[@]}" \
    > "$RUNNER_TEMP/emulator.log" 2>&1 &
else
  nohup env "${EMULATOR_AUDIO_ENV[@]}" \
    "$ANDROID_EMULATOR_BIN" "${EMULATOR_ARGS[@]}" "${EMULATOR_AUDIO_ARGS[@]}" \
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
    window_id="$(wmctrl -l 2>/dev/null | grep -iE "android emulator|${ANDROID_AVD_NAME}" | awk 'NR==1 {print $1}' || true)"
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
if [ "$ANDROID_ARM" = "true" ]; then
  echo "Reproducing the short emulator screen-recording redraw workaround..."
  RECORD_DIR="$ANDROID_AVD_HOME/$ANDROID_AVD_NAME.avd/console_out"
  RECORD_FILE="$RECORD_DIR/androidvm-display-warmup.webm"
  mkdir -p "$RECORD_DIR"
  if timeout 8s adb -s emulator-5554 emu screenrecord start --time-limit 4 "$RECORD_FILE" > "$RUNNER_TEMP/screenrecord-start.log" 2>&1; then
    sleep 5
    timeout 8s adb -s emulator-5554 emu screenrecord stop "$RECORD_FILE" > "$RUNNER_TEMP/screenrecord-stop.log" 2>&1 || true
    sleep 2
    if [ -s "$RECORD_FILE" ]; then
      echo "Android guest screen-recording redraw completed ($(stat -c%s "$RECORD_FILE") bytes)."
    else
      echo "::warning::No recording file was created; normal Android display refresh will continue."
    fi
  else
    echo "::warning::The legacy emulator did not accept the screen-recording command; continuing with normal redraw."
    cat "$RUNNER_TEMP/screenrecord-start.log" || true
  fi
  adb -s emulator-5554 shell input keyevent 224 || true
  adb -s emulator-5554 shell input keyevent 3 || true
  sleep 3
  xrefresh -display "$DISPLAY" -root || true
fi
ANDROID_REPORTED_ABI="$(adb -s emulator-5554 shell getprop ro.product.cpu.abi | tr -d '\r')"
echo "Android reported ABI: $ANDROID_REPORTED_ABI"
if [ "$ANDROID_ARM" = "true" ]; then
  if ! printf '%s' "$ANDROID_REPORTED_ABI" | grep -qi '^armeabi-v7a$'; then
    echo "::error::ARM mode was selected, but Android reports ABI '$ANDROID_REPORTED_ABI'."
    exit 1
  fi
else
  if ! printf '%s' "$ANDROID_REPORTED_ABI" | grep -qi '^x86'; then
    echo "::error::x86 mode was selected, but Android reports ABI '$ANDROID_REPORTED_ABI'."
    exit 1
  fi
fi
adb -s emulator-5554 shell input keyevent 82 || true
echo "Raising Android's startup volume so ringtone tests are audible..."
# On the home screen these key events raise the ring volume on legacy Android
# releases instead of leaving a newly created emulator effectively silent.
for _ in 1 2 3 4 5; do
  adb -s emulator-5554 shell input keyevent 24 >/dev/null 2>&1 || true
done
sleep 1
echo "Android audio stream and ringer state:"
adb -s emulator-5554 shell dumpsys audio 2>/dev/null | grep -iE 'ring|ringer|stream.*(volume|music)|volume.*stream' | head -n 80 || true
echo "$ANDROID_RELEASE booted successfully."

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
    echo "::warning::Could not install normal APK: $(basename "$apk"). Check that it supports $ANDROID_RELEASE (API $ANDROID_API_LEVEL)."
  fi
done

bash "${GITHUB_WORKSPACE:-$PWD}/scripts/install-browser.sh" "$BROWSER_TO_INSTALL" "$ANDROID_API_LEVEL" "$ANDROID_RELEASE"

# Copy arbitrary user-provided files into Android's shared Downloads storage.
# Preserve subdirectories so the repo's files/ tree is reflected on the device.
FILES_DIR="${GITHUB_WORKSPACE:-$PWD}/files"
USER_FILES=()
if [ -d "$FILES_DIR" ]; then
  mapfile -d '' USER_FILES < <(find "$FILES_DIR" -type f ! -name '.gitkeep' -print0 | sort -z)
fi
echo "Found ${#USER_FILES[@]} file(s) in files/."
if [ "${#USER_FILES[@]}" -gt 0 ]; then
  if ! adb -s emulator-5554 shell mkdir -p /sdcard/Download; then
    echo "::warning::Could not prepare Android Downloads storage; files/ contents will not be copied."
  else
    for user_file in "${USER_FILES[@]}"; do
      relative_path="${user_file#"$FILES_DIR"/}"
      relative_dir="$(dirname "$relative_path")"
      remote_dir="/sdcard/Download"
      if [ "$relative_dir" != "." ]; then
        remote_dir="$remote_dir/$relative_dir"
        if ! adb -s emulator-5554 shell mkdir -p "$remote_dir"; then
          echo "::warning::Could not create device folder for: $relative_path"
          continue
        fi
      fi

      if adb -s emulator-5554 push "$user_file" "$remote_dir/"; then
        echo "Copied files/$relative_path to Android Downloads."
        # Ask Android's media scanner to index photos, audio, and videos too.
        encoded_path="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe="/"))' "$relative_path")"
        adb -s emulator-5554 shell am broadcast \
          -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
          -d "file:///sdcard/Download/$encoded_path" >/dev/null 2>&1 || true
      else
        echo "::warning::Failed to copy files/$relative_path to the device."
      fi
    done
  fi
fi

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
  SELKIES_ARGS+=(--audio-enabled=true --audio-on-start=true "--audio-device-name=$AUDIO_DEVICE_NAME")
  echo "Selkies audio streaming enabled; capturing $AUDIO_DEVICE_NAME."
else
  echo "::warning::PulseAudio is unavailable; starting Selkies with audio disabled."
  SELKIES_ARGS+=(--audio-enabled=false)
fi
nohup "$SELKIES_BIN" "${SELKIES_ARGS[@]}" > "$RUNNER_TEMP/selkies.log" 2>&1 &
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
echo "Android: $ANDROID_RELEASE, API $ANDROID_API_LEVEL, $ANDROID_ARCH"
if [ "$ANDROID_GOOGLE_PLAY_STORE" = "true" ]; then
  echo "Google Play Store: enabled (official Google Play system image)"
else
  echo "Google Play Store: disabled (Google APIs system image)"
fi
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
echo "Hardware keyboard: $VM_HARDWARE_KEYBOARD"
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
; then
  echo "::error::ARM mode was selected, but Android reports ABI '$ANDROID_REPORTED_ABI'."
  exit 1
fi
if [ "$ANDROID_ARM" != "true" ] && ! printf '%s' "$ANDROID_REPORTED_ABI" | grep -qi '^x86'; then
  echo "::error::x86 mode was selected, but Android reports ABI '$ANDROID_REPORTED_ABI'."
  exit 1
fi
adb -s emulator-5554 shell input keyevent 82 || true
echo "Raising Android's startup volume so ringtone tests are audible..."
# On the home screen these key events raise the ring volume on legacy Android
# releases instead of leaving a newly created emulator effectively silent.
for _ in 1 2 3 4 5; do
  adb -s emulator-5554 shell input keyevent 24 >/dev/null 2>&1 || true
done
sleep 1
echo "Android audio stream and ringer state:"
adb -s emulator-5554 shell dumpsys audio 2>/dev/null | grep -iE 'ring|ringer|stream.*(volume|music)|volume.*stream' | head -n 80 || true
echo "$ANDROID_RELEASE booted successfully."

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
    echo "::warning::Could not install normal APK: $(basename "$apk"). Check that it supports $ANDROID_RELEASE (API $ANDROID_API_LEVEL)."
  fi
done

bash "${GITHUB_WORKSPACE:-$PWD}/scripts/install-browser.sh" "$BROWSER_TO_INSTALL" "$ANDROID_API_LEVEL" "$ANDROID_RELEASE"

# Copy arbitrary user-provided files into Android's shared Downloads storage.
# Preserve subdirectories so the repo's files/ tree is reflected on the device.
FILES_DIR="${GITHUB_WORKSPACE:-$PWD}/files"
USER_FILES=()
if [ -d "$FILES_DIR" ]; then
  mapfile -d '' USER_FILES < <(find "$FILES_DIR" -type f ! -name '.gitkeep' -print0 | sort -z)
fi
echo "Found ${#USER_FILES[@]} file(s) in files/."
if [ "${#USER_FILES[@]}" -gt 0 ]; then
  if ! adb -s emulator-5554 shell mkdir -p /sdcard/Download; then
    echo "::warning::Could not prepare Android Downloads storage; files/ contents will not be copied."
  else
    for user_file in "${USER_FILES[@]}"; do
      relative_path="${user_file#"$FILES_DIR"/}"
      relative_dir="$(dirname "$relative_path")"
      remote_dir="/sdcard/Download"
      if [ "$relative_dir" != "." ]; then
        remote_dir="$remote_dir/$relative_dir"
        if ! adb -s emulator-5554 shell mkdir -p "$remote_dir"; then
          echo "::warning::Could not create device folder for: $relative_path"
          continue
        fi
      fi

      if adb -s emulator-5554 push "$user_file" "$remote_dir/"; then
        echo "Copied files/$relative_path to Android Downloads."
        # Ask Android's media scanner to index photos, audio, and videos too.
        encoded_path="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe="/"))' "$relative_path")"
        adb -s emulator-5554 shell am broadcast \
          -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
          -d "file:///sdcard/Download/$encoded_path" >/dev/null 2>&1 || true
      else
        echo "::warning::Failed to copy files/$relative_path to the device."
      fi
    done
  fi
fi

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
  SELKIES_ARGS+=(--audio-enabled=true --audio-on-start=true "--audio-device-name=$AUDIO_DEVICE_NAME")
  echo "Selkies audio streaming enabled; capturing $AUDIO_DEVICE_NAME."
else
  echo "::warning::PulseAudio is unavailable; starting Selkies with audio disabled."
  SELKIES_ARGS+=(--audio-enabled=false)
fi
nohup "$SELKIES_BIN" "${SELKIES_ARGS[@]}" > "$RUNNER_TEMP/selkies.log" 2>&1 &
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
echo "Android: $ANDROID_RELEASE, API $ANDROID_API_LEVEL, $ANDROID_ARCH"
if [ "$ANDROID_ARM" = "true" ]; then
  echo "ARM Android: enabled (armeabi-v7a, plain AOSP image; Google Play Services absent)"
elif [ "$ANDROID_GOOGLE_PLAY_STORE" = "true" ]; then
  echo "Google Play Store: enabled (official Google Play system image)"
else
  echo "Google Play Store: disabled (Google APIs system image)"
fi
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
echo "Hardware keyboard: $VM_HARDWARE_KEYBOARD"
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
