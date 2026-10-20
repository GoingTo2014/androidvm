#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE_SOURCE="${IMAGE_SOURCE:-Exton Build 9 (GAPPS)}"
SESSION_MINUTES="${SESSION_MINUTES:-120}"
VM_RAM_MB="${VM_RAM_MB:-2048}"
VM_CPU_CORES="${VM_CPU_CORES:-2}"
VM_ACCESS_PASSWORD="${VM_ACCESS_PASSWORD:-}"
EXTON_KITKAT_ISO_URL="${EXTON_KITKAT_ISO_URL:-}"

case "$IMAGE_SOURCE" in
  "Exton Build 9 (GAPPS)")
    if [ -z "$EXTON_KITKAT_ISO_URL" ]; then
      echo "::error::Exton Build 9 needs an authorized direct ISO URL. Add it as the repository Actions secret EXTON_KITKAT_ISO_URL."
      echo "The original publisher's page does not provide a public direct download link."
      exit 2
    fi
    case "$EXTON_KITKAT_ISO_URL" in
      https://*) ;;
      *) echo "::error::EXTON_KITKAT_ISO_URL must be an HTTPS URL."; exit 2 ;;
    esac
    # Keep the source URL out of the Actions logs; it may be a signed/personal download URL.
    echo "::add-mask::$EXTON_KITKAT_ISO_URL"
    ISO_URL="$EXTON_KITKAT_ISO_URL"
    ISO_LABEL="Exton Android-x86 KitKat 4.4.4 Build 9"
    OFFICIAL_SHA1=""
    ;;
  "Official Android-x86 4.4-r3 (free baseline)")
    ISO_URL="https://sourceforge.net/projects/android-x86/files/Release%204.4/android-x86-4.4-r3.iso/download"
    ISO_LABEL="Official Android-x86 4.4-r3 (Android 4.4.4; no bundled Google apps)"
    OFFICIAL_SHA1="6c1488a36f24795796bd9158e77effc5e3acaa2d"
    ;;
  *)
    echo "::error::Unknown IMAGE_SOURCE: $IMAGE_SOURCE"
    exit 2
    ;;
esac

case "$SESSION_MINUTES" in
  30|60|120|180|240|300) ;;
  *) echo "::error::Invalid SESSION_MINUTES: $SESSION_MINUTES"; exit 2 ;;
esac
case "$VM_RAM_MB" in
  2048|3072|4096) ;;
  *) echo "::error::Invalid VM_RAM_MB: $VM_RAM_MB"; exit 2 ;;
esac
case "$VM_CPU_CORES" in
  1|2|4) ;;
  *) echo "::error::Invalid VM_CPU_CORES: $VM_CPU_CORES"; exit 2 ;;
esac

RUNNER_TEMP="${RUNNER_TEMP:-/tmp}"
GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"
ISO_PATH="$RUNNER_TEMP/android-x86-kitkat.iso"
SELKIES_PID=""
QEMU_PID=""
XVFB_PID=""
WM_PID=""
TUNNEL_PID=""

cleanup() {
  echo "Stopping Android-x86 session processes..."
  for pid in "$TUNNEL_PID" "$SELKIES_PID" "$QEMU_PID" "$WM_PID" "$XVFB_PID"; do
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi
  done
  wait 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "Starting standalone Android-x86 KitKat workflow."
echo "Selected image: $ISO_LABEL"
echo "Session length: $SESSION_MINUTES minutes; RAM: $VM_RAM_MB MB; CPUs: $VM_CPU_CORES"
echo "Installing QEMU, desktop, audio, and gateway packages..."
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  qemu-system-x86 qemu-system-gui qemu-utils \
  xvfb pulseaudio pulseaudio-utils nginx apache2-utils \
  openbox xdotool wmctrl x11-xserver-utils \
  curl ca-certificates file

echo "Downloading selected KitKat ISO..."
curl --fail --location --silent --show-error --retry 3 --retry-delay 2 \
  --connect-timeout 30 --max-time 1200 \
  "$ISO_URL" -o "$ISO_PATH"

ISO_BYTES="$(stat -c '%s' "$ISO_PATH")"
if [ "$ISO_BYTES" -lt 150000000 ]; then
  echo "::error::Downloaded file is unexpectedly small ($ISO_BYTES bytes); it may be an HTML page instead of an ISO."
  file "$ISO_PATH" || true
  exit 1
fi
ISO_DESCRIPTION="$(file -b "$ISO_PATH")"
echo "Downloaded image size: $ISO_BYTES bytes"
echo "ISO file identification: $ISO_DESCRIPTION"
case "$ISO_DESCRIPTION" in
  *"ISO 9660"*|*"DOS/MBR boot sector"*) ;;
  *)
    echo "::error::The downloaded file does not appear to be a bootable ISO image."
    exit 1
    ;;
esac

if [ -n "$OFFICIAL_SHA1" ]; then
  printf '%s  %s\n' "$OFFICIAL_SHA1" "$ISO_PATH" | sha1sum --check -
  echo "Official Android-x86 ISO checksum verified against the published release note."
else
  echo "::notice::The Exton publisher page does not list a public checksum for Build 9; the URL is user-provided and the ISO format/size are checked."
fi

echo "Installing checksum-verified Selkies 2.0.0..."
SELKIES_DEB="$RUNNER_TEMP/selkies-2.0.0-ubuntu24.04-amd64.deb"
curl -fL --retry 3 --retry-delay 2 \
  "https://github.com/selkies-project/selkies/releases/download/2.0.0/selkies-2.0.0-ubuntu24.04-amd64.deb" \
  -o "$SELKIES_DEB"
echo "bbaa4d71012b9374a753b7dfddc1da07e31f34b04277fe4fb3d045f18fd88391  $SELKIES_DEB" | sha256sum --check
sudo apt-get install -y "$SELKIES_DEB"
selkies --version

echo "Starting virtual display at 1280x800..."
Xvfb :99 -screen 0 1280x800x24 -s 0 -dpms -ac \
  +extension COMPOSITE +extension DAMAGE +extension GLX +extension RANDR \
  +extension RENDER +extension MIT-SHM +extension XFIXES +extension XTEST \
  +iglx +render -nolisten tcp -noreset > "$RUNNER_TEMP/exton-xvfb.log" 2>&1 &
XVFB_PID=$!
export DISPLAY=:99
sleep 2
xsetroot -solid "#151820" || true
openbox --sm-disable > "$RUNNER_TEMP/exton-openbox.log" 2>&1 &
WM_PID=$!
sleep 2

AUDIO_AVAILABLE=0
if pulseaudio --start --exit-idle-time=-1; then
  sleep 1
  AUDIO_MODULE_ID="$(pactl load-module module-null-sink sink_name=vm_audio sink_properties=device.description=AndroidVM 2>&1 || true)"
  if [[ "$AUDIO_MODULE_ID" =~ ^[0-9]+$ ]] && pactl set-default-sink vm_audio; then
    sleep 1
    if pactl list short sources | awk '$2 == "vm_audio.monitor" { found=1 } END { exit !found }'; then
      AUDIO_AVAILABLE=1
      echo "PulseAudio capture source ready: vm_audio.monitor"
    fi
  fi
fi
if [ "$AUDIO_AVAILABLE" -eq 0 ]; then
  echo "::warning::PulseAudio monitor unavailable; audio streaming will be disabled."
fi

echo "Launching the x86 KitKat guest in QEMU. Boot from the live ISO menu; no Android SDK emulator is used."
QEMU_ARGS=(
  -name "Android-x86 KitKat"
  -machine pc
  -accel tcg,thread=multi
  -cpu max
  -m "$VM_RAM_MB"
  -smp "$VM_CPU_CORES"
  -cdrom "$ISO_PATH"
  -boot order=d,menu=on
  -vga std
  -display gtk
  -netdev user,id=net0
  -device e1000,netdev=net0
  -usb
  -device usb-tablet
  -device usb-kbd
  -no-reboot
)
if [ "$AUDIO_AVAILABLE" -eq 1 ]; then
  QEMU_ARGS+=(-audiodev pa,id=pa0,out.mixing-engine=on,in.mixing-engine=on -device intel-hda -device hda-duplex,audiodev=pa0)
else
  QEMU_ARGS+=(-audiodev none,id=pa0 -device intel-hda -device hda-duplex,audiodev=pa0)
fi
nohup qemu-system-i386 "${QEMU_ARGS[@]}" > "$RUNNER_TEMP/qemu-android-x86.log" 2>&1 &
QEMU_PID=$!

echo "Giving QEMU a moment to initialize..."
sleep 15
if ! kill -0 "$QEMU_PID" 2>/dev/null; then
  echo "::error::QEMU exited before the desktop stream was ready. Recent QEMU log:"
  tail -n 160 "$RUNNER_TEMP/qemu-android-x86.log" || true
  exit 1
fi
echo "QEMU is running; Android guest boot state will be visible in the browser stream."
echo "QEMU acceleration is TCG software emulation for portability on hosted runners."

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
if [ "$AUDIO_AVAILABLE" -eq 1 ]; then
  SELKIES_ARGS+=(--audio-enabled=true --audio-on-start=true --audio-device-name=vm_audio.monitor)
else
  SELKIES_ARGS+=(--audio-enabled=false)
fi
nohup selkies "${SELKIES_ARGS[@]}" > "$RUNNER_TEMP/exton-selkies.log" 2>&1 &
SELKIES_PID=$!

SELKIES_HTTP_OK=0
for i in $(seq 1 45); do
  if curl --silent --show-error --fail http://127.0.0.1:6080/ -o "$RUNNER_TEMP/exton-selkies-homepage.html"; then
    if grep -qi "Selkies" "$RUNNER_TEMP/exton-selkies-homepage.html"; then
      SELKIES_HTTP_OK=1
      break
    fi
  fi
  if ! kill -0 "$SELKIES_PID" 2>/dev/null; then
    echo "::error::Selkies exited during startup. Recent log:"
    tail -n 160 "$RUNNER_TEMP/exton-selkies.log" || true
    exit 1
  fi
  sleep 1
done
if [ "$SELKIES_HTTP_OK" -ne 1 ]; then
  echo "::error::Selkies did not serve the expected browser client."
  tail -n 160 "$RUNNER_TEMP/exton-selkies.log" || true
  exit 1
fi

echo "Configuring authenticated reverse proxy..."
sudo cp "$GITHUB_WORKSPACE/nginx/androidvm.conf.template" /etc/nginx/sites-available/androidvm
if [ -n "$VM_ACCESS_PASSWORD" ]; then
  printf '%s\n' "$(htpasswd -Bbn vm "$VM_ACCESS_PASSWORD")" | sudo tee /etc/nginx/.androidvm.htpasswd >/dev/null
  sudo chown root:www-data /etc/nginx/.androidvm.htpasswd
  sudo chmod 640 /etc/nginx/.androidvm.htpasswd
  if ! sudo -u www-data test -r /etc/nginx/.androidvm.htpasswd; then
    echo "::error::Nginx cannot read the VM Basic Auth file."
    exit 1
  fi
  sudo sed -i '/__AUTH_DIRECTIVES__/c\    auth_basic "Android VM";\n    auth_basic_user_file /etc/nginx/.androidvm.htpasswd;' /etc/nginx/sites-available/androidvm
  echo "HTTP Basic Authentication enabled (username: vm)."
else
  sudo sed -i '/__AUTH_DIRECTIVES__/d' /etc/nginx/sites-available/androidvm
  echo "::warning::VM_ACCESS_PASSWORD is not set. Anyone with the public tunnel URL can control the guest."
fi
sudo rm -f /etc/nginx/sites-enabled/default
sudo ln -sf /etc/nginx/sites-available/androidvm /etc/nginx/sites-enabled/androidvm
sudo nginx -t
sudo systemctl restart nginx

if [ -n "$VM_ACCESS_PASSWORD" ]; then
  curl --silent --show-error --fail --user "vm:$VM_ACCESS_PASSWORD" http://127.0.0.1:8080/ -o "$RUNNER_TEMP/exton-gateway.html"
else
  curl --silent --show-error --fail http://127.0.0.1:8080/ -o "$RUNNER_TEMP/exton-gateway.html"
fi
if ! grep -qi "Selkies" "$RUNNER_TEMP/exton-gateway.html"; then
  echo "::error::The local gateway did not return the Selkies web client."
  sudo tail -n 100 /var/log/nginx/error.log || true
  exit 1
fi
echo "Local gateway smoke test passed."

echo "Installing Cloudflare Tunnel..."
curl -fL --retry 3 --retry-delay 2 \
  "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb" \
  -o "$RUNNER_TEMP/cloudflared.deb"
sudo dpkg -i "$RUNNER_TEMP/cloudflared.deb"

echo "Starting temporary TryCloudflare tunnel..."
cloudflared tunnel --no-autoupdate --url http://127.0.0.1:8080 > "$RUNNER_TEMP/exton-cloudflared.log" 2>&1 &
TUNNEL_PID=$!
TUNNEL_URL=""
for i in $(seq 1 90); do
  TUNNEL_URL="$(grep -Eo 'https://[-a-z0-9]+\.trycloudflare\.com' "$RUNNER_TEMP/exton-cloudflared.log" | head -n 1 || true)"
  if [ -n "$TUNNEL_URL" ]; then break; fi
  if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then break; fi
  sleep 2
done
if [ -z "$TUNNEL_URL" ]; then
  echo "::error::Cloudflare did not provide a URL. Tunnel log:"
  tail -n 100 "$RUNNER_TEMP/exton-cloudflared.log" || true
  exit 1
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "url=$TUNNEL_URL" >> "$GITHUB_OUTPUT"
fi
echo ""
echo "=========================================================="
echo "ANDROID-X86 KITKAT SESSION IS READY"
echo "Open: $TUNNEL_URL"
echo "Image: $ISO_LABEL"
echo "QEMU: x86 guest, TCG software CPU emulation"
echo "Streaming: Selkies 2.0.0 H.264 over WebSocket"
echo "Audio: $AUDIO_AVAILABLE"
echo "RAM: $VM_RAM_MB MB; CPUs: $VM_CPU_CORES"
echo "Session length: $SESSION_MINUTES minutes"
echo "The live ISO session is temporary. Guest changes are not guaranteed to persist after this workflow ends."
echo "The URL is temporary and gives control of the VM; do not share it publicly."
echo "=========================================================="

REMAINING=$((SESSION_MINUTES * 60))
while [ "$REMAINING" -gt 0 ]; do
  if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
    echo "::error::TryCloudflare tunnel stopped."
    tail -n 100 "$RUNNER_TEMP/exton-cloudflared.log" || true
    exit 1
  fi
  if ! kill -0 "$SELKIES_PID" 2>/dev/null; then
    echo "::error::Selkies streaming server stopped."
    tail -n 160 "$RUNNER_TEMP/exton-selkies.log" || true
    exit 1
  fi
  if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    echo "::error::QEMU stopped. Recent log:"
    tail -n 160 "$RUNNER_TEMP/qemu-android-x86.log" || true
    exit 1
  fi
  sleep 30
  REMAINING=$((REMAINING - 30))
done

echo "Configured Android-x86 session duration has elapsed."
