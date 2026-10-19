#!/usr/bin/env bash
set -Eeuo pipefail

export ANDROID_HOME="$HOME/.android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"
source "${GITHUB_WORKSPACE:-$PWD}/scripts/android-version.sh"
mkdir -p "$ANDROID_HOME/cmdline-tools" "$RUNNER_TEMP/android-tools-unpack"

echo "Installing libraries required by the Android Emulator..."
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  libpulse0 libasound2t64 libx11-6 libx11-xcb1 libxcb1 \
  libxkbcommon-x11-0 libxcb-cursor0 libgl1 libnss3

SDKMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
if [ ! -x "$SDKMANAGER" ]; then
  echo "Android SDK cache miss: downloading command-line tools..."
  curl -fL --retry 3 --retry-delay 2 \
    https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip \
    -o "$RUNNER_TEMP/android-commandline-tools.zip"
  unzip -q "$RUNNER_TEMP/android-commandline-tools.zip" -d "$RUNNER_TEMP/android-tools-unpack"
  rm -rf "$ANDROID_HOME/cmdline-tools/latest"
  mv "$RUNNER_TEMP/android-tools-unpack/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest"
fi

SDKMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
echo "Accepting Android SDK licenses..."
yes | "$SDKMANAGER" --sdk_root="$ANDROID_HOME" --licenses >/dev/null || true

if [ ! -x "$ANDROID_HOME/platform-tools/adb" ] || [ ! -x "$ANDROID_HOME/emulator/emulator" ]; then
  echo "Installing common Android SDK packages (emulator and platform-tools)..."
  "$SDKMANAGER" --sdk_root="$ANDROID_HOME" --install \
    "platform-tools" \
    "emulator"
else
  echo "Android platform-tools and emulator are already cached."
fi

if [ ! -f "$ANDROID_SYSTEM_IMAGE_DIR/system.img" ]; then
  echo "Installing $ANDROID_RELEASE system image: $ANDROID_SYSTEM_IMAGE_PACKAGE"
  # Remove only the selected image directory if a restored cache was incomplete.
  rm -rf "$ANDROID_SYSTEM_IMAGE_DIR"
  if ! "$SDKMANAGER" --sdk_root="$ANDROID_HOME" --install "$ANDROID_SYSTEM_IMAGE_PACKAGE"; then
    echo "::error::Could not install $ANDROID_RELEASE from the official Android SDK package $ANDROID_SYSTEM_IMAGE_PACKAGE."
    echo "::error::That legacy system image may no longer be downloadable from Google's SDK repository."
    exit 1
  fi
else
  echo "$ANDROID_RELEASE system image is already cached."
fi

if [ ! -x "$ANDROID_HOME/platform-tools/adb" ] \
  || [ ! -x "$ANDROID_HOME/emulator/emulator" ] \
  || [ ! -f "$ANDROID_SYSTEM_IMAGE_DIR/system.img" ]; then
  echo "::error::Android SDK preparation did not produce all required packages for $ANDROID_RELEASE."
  exit 1
fi

"$ANDROID_HOME/emulator/emulator" -version
echo "$ANDROID_RELEASE SDK preparation complete."