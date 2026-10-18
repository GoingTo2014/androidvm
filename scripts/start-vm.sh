#!/usr/bin/env bash
set -Eeuo pipefail

case "$SESSION_MINUTES" in
  30|60|120|180|240|300) ;;
  *) echo "Invalid SESSION_MINUTES: $SESSION_MINUTES"; exit 2 ;;
esac

export ANDROID_HOME="$RUNNER_TEMP/android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export ANDROID_AVD_HOME="$RUNNER_TEMP/android-avd"
export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"
mkdir -p "$ANDROID_HOME" "$ANDROID_AVD_HOME"

EMULATOR_PID=""
XVFB_PID=""
VNC_PID=""
NOVNC_PID=""
AUDIO_PID=""
TUNNEL_PID=""
cleanup() {
  echo "Stopping AndroidVM session processes..."
  for pid in "$TUNNEL_PID" "$AUDIO_PID" "$NOVNC_PID" "$VNC_PID" "$EMULATOR_PID" "$XVFB_PID"; do
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi
  done
  wait 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "Installing system packages..."
sudo apt-get update
echo "icecast2 icecast2/icecast-setup boolean true" | sudo debconf-set-selections
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  xvfb x11vnc novnc websockify pulseaudio ffmpeg icecast2 nginx apache2-utils \
  curl unzip ca-certificates libnss3 libasound2t64 libxkbcommon-x11-0 libxcb-cursor0

echo "Downloading Android SDK command-line tools..."
curl -fL --retry 3 --retry-delay 2 \
  https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip \
  -o "$RUNNER_TEMP/android-commandline-tools.zip"
mkdir -p "$RUNNER_TEMP/android-tools-unpack" "$ANDROID_HOME/cmdline-tools"
unzip -q "$RUNNER_TEMP/android-commandline-tools.zip" -d "$RUNNER_TEMP/android-tools-unpack"
mv "$RUNNER_TEMP/android-tools-unpack/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest"
SDKMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
AVDMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager"

echo "Accepting Android SDK licenses..."
yes | "$SDKMANAGER" --sdk_root="$ANDROID_HOME" --licenses >/dev/null || true

echo "Installing emulator and Android 4.4 x86 system image..."
"$SDKMANAGER" --sdk_root="$ANDROID_HOME" --install \
  "platform-tools" \
  "emulator" \
  "system-images;android-19;default;x86"

echo "Creating KitKat AVD..."
printf 'no\n' | "$AVDMANAGER" create avd \
  --name KitKat \
  --package "system-images;android-19;default;x86" \
  --force
cat >> "$ANDROID_AVD_HOME/KitKat.avd/config.ini" <<'AVD_CONFIG'
hw.cpu.ncore=2
hw.ramSize=2048
hw.keyboard=yes
hw.gpu.enabled=yes
hw.gpu.mode=swiftshader
showDeviceFrame=no
skin.dynamic=no
disk.dataPartition.size=2G
AVD_CONFIG

echo "Starting virtual display..."
Xvfb :99 -screen 0 1280x800x24 -ac +extension RANDR -nolisten tcp > "$RUNNER_TEMP/xvfb.log" 2>&1 &
XVFB_PID=$!
export DISPLAY=:99
sleep 2
x11vnc -display :99 -forever -shared -rfbport 5900 -nopw -quiet > "$RUNNER_TEMP/x11vnc.log" 2>&1 &
VNC_PID=$!

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

AUDIO_AVAILABLE=1
ICECAST_PASSWORD="$(openssl rand -hex 20)"
if pulseaudio --start --exit-idle-time=-1; then
  sleep 2
  if pactl load-module module-null-sink sink_name=vm_audio sink_properties=device.description=AndroidVM >/dev/null 2>&1 && pactl set-default-sink vm_audio; then
    if sudo sed -i "s#<source-password>[^<]*</source-password>#<source-password>$ICECAST_PASSWORD</source-password>#" /etc/icecast2/icecast.xml \
      && sudo sed -i 's/ENABLE=false/ENABLE=true/' /etc/default/icecast2 \
      && sudo systemctl restart icecast2; then
      AUDIO_AVAILABLE=1
    else
      AUDIO_AVAILABLE=0
    fi
  else
    AUDIO_AVAILABLE=0
  fi
else
  AUDIO_AVAILABLE=0
fi
if [ "$AUDIO_AVAILABLE" = "0" ]; then
  echo "::warning::PulseAudio could not be configured; video may work without streamed audio."
fi

echo "Starting Android 4.4 emulator..."
EMULATOR_AUDIO_ENV=""
EMULATOR_AUDIO_FLAG=""
if [ "$AUDIO_AVAILABLE" = "1" ]; then
  EMULATOR_AUDIO_ENV="PULSE_SINK=vm_audio QEMU_AUDIO_DRV=pa"
else
  EMULATOR_AUDIO_FLAG="-no-audio"
fi
if [ "$ACCEL_MODE" = "off" ]; then
  nohup env $EMULATOR_AUDIO_ENV ANDROID_I_WANT_MY_TCG=yes \
    "$ANDROID_HOME/emulator/emulator" -avd KitKat -port 5554 -accel off \
    -no-snapshot -no-boot-anim -gpu swiftshader -memory 2048 -cores 2 \
    $EMULATOR_AUDIO_FLAG > "$RUNNER_TEMP/emulator.log" 2>&1 &
else
  nohup env $EMULATOR_AUDIO_ENV \
    "$ANDROID_HOME/emulator/emulator" -avd KitKat -port 5554 -accel on \
    -no-snapshot -no-boot-anim -gpu swiftshader -memory 2048 -cores 2 \
    $EMULATOR_AUDIO_FLAG > "$RUNNER_TEMP/emulator.log" 2>&1 &
fi
EMULATOR_PID=$!

echo "Waiting for Android to finish booting (up to 8 minutes)..."
BOOTED=0
for i in $(seq 1 240); do
  if adb devices 2>/dev/null | grep -q 'emulator-5554[[:space:]]*device'; then
    if adb -s emulator-5554 shell getprop sys.boot_completed 2>/dev/null | grep -q '^1$'; then
      BOOTED=1
      break
    fi
  fi
  if ! kill -0 "$EMULATOR_PID" 2>/dev/null; then
    echo "::error::Android Emulator exited during startup. Recent emulator log:"
    tail -n 120 "$RUNNER_TEMP/emulator.log" || true
    exit 1
  fi
  sleep 2
done
if [ "$BOOTED" -ne 1 ]; then
  echo "::error::Android did not finish booting in time. Recent emulator log:"
  tail -n 160 "$RUNNER_TEMP/emulator.log" || true
  exit 1
fi
adb -s emulator-5554 shell settings put system screen_off_timeout 2147483647 || true
adb -s emulator-5554 shell input keyevent 82 || true
echo "Android 4.4 booted successfully."

if [ "$AUDIO_AVAILABLE" = "1" ]; then
  echo "Starting live audio encoder..."
  nohup ffmpeg -hide_banner -loglevel warning -f pulse -i vm_audio.monitor \
    -vn -ac 2 -ar 44100 -c:a libmp3lame -b:a 96k -content_type audio/mpeg \
    -f mp3 "icecast://source:$ICECAST_PASSWORD@127.0.0.1:8000/androidvm.mp3" \
    > "$RUNNER_TEMP/audio.log" 2>&1 &
  AUDIO_PID=$!
  sleep 2
  if ! kill -0 "$AUDIO_PID" 2>/dev/null; then
    echo "::warning::FFmpeg audio streaming did not start. Check audio.log in the workflow's runner logs."
    AUDIO_AVAILABLE=0
  fi
fi

echo "Starting noVNC web display..."
websockify --web=/usr/share/novnc 6080 127.0.0.1:5900 > "$RUNNER_TEMP/novnc.log" 2>&1 &
NOVNC_PID=$!
sleep 2

echo "Configuring web gateway..."
sudo cp nginx/androidvm.conf.template /etc/nginx/sites-available/androidvm
sudo sed -i "s|__SITE_ROOT__|$GITHUB_WORKSPACE/site|g" /etc/nginx/sites-available/androidvm
if [ -n "$VM_ACCESS_PASSWORD" ]; then
  printf '%s\n' "$(htpasswd -Bbn vm "$VM_ACCESS_PASSWORD")" | sudo tee /etc/nginx/.androidvm.htpasswd >/dev/null
  sudo chmod 600 /etc/nginx/.androidvm.htpasswd
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
echo "Audio stream setup: $AUDIO_AVAILABLE"
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
  sleep 30
  REMAINING=$((REMAINING - 30))
done

echo "Configured VM session duration has elapsed."
