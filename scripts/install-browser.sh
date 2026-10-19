#!/usr/bin/env bash
set -Eeuo pipefail

BROWSER_TO_INSTALL="${1:-None}"
ANDROID_API_LEVEL="${2:-}"
ANDROID_RELEASE="${3:-selected Android release}"
ANDROID_API_LEVEL="${ANDROID_API_LEVEL:-0}"
ANDROID_HOME="${ANDROID_HOME:-$HOME/.android-sdk}"
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$ANDROID_HOME}"
export ANDROID_HOME ANDROID_SDK_ROOT
export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"

if ! [[ "$ANDROID_API_LEVEL" =~ ^[0-9]+$ ]]; then
  echo "::error::Invalid Android API level: $ANDROID_API_LEVEL"
  exit 2
fi

case "$BROWSER_TO_INSTALL" in
  "None")
    echo "No additional browser selected."
    exit 0
    ;;
  "Firefox 68.11.0")
    MIN_API=16
    APK_NAME="fennec-68.11.0.en-US.android-i386.apk"
    APK_URL="https://archive.mozilla.org/pub/mobile/releases/68.11.0/android-x86/en-US/fennec-68.11.0.en-US.android-i386.apk"
    APK_SHA256="333a551c0e91153640c180b2e56d270bf7b07428a7a4fcf9fec3f0d83b3771cb"
    ;;
  "Chrome 81.0.4044.138")
    MIN_API=19
    APK_NAME="chrome-81.0.4044.138-x86.apk"
    APK_URL="https://d.apkpure.com/b/APK/com.android.chrome?versionCode=404413801&from=details"
    APK_SHA256="1979345d2c581fac0e48588869207bc2ec4fa01c3d25562e85c0cea16faba4c6"
    ;;
  "Opera 58.8.2878.72999")
    MIN_API=19
    APK_NAME="opera-58.8.2878.72999-x86.apk"
    APK_URL="https://d.apkpure.com/b/APK/com.opera.browser?versionCode=1905822801&from=details"
    APK_SHA256="7ee73f623b5275a663dcca7b57f49a8335b58be9e4270b06affc7b1fcc927c51"
    ;;
  *)
    echo "::error::Unsupported BROWSER_TO_INSTALL: $BROWSER_TO_INSTALL"
    exit 2
    ;;
esac

if [ "$ANDROID_API_LEVEL" -lt "$MIN_API" ]; then
  echo "::error::$BROWSER_TO_INSTALL requires Android API $MIN_API or newer; selected $ANDROID_RELEASE (API $ANDROID_API_LEVEL)."
  exit 2
fi

APK_PATH="${RUNNER_TEMP:-/tmp}/$APK_NAME"
echo "Downloading $BROWSER_TO_INSTALL for x86 from its configured archive..."
curl -fL --retry 3 --retry-delay 2 "$APK_URL" -o "$APK_PATH"
echo "$APK_SHA256  $APK_PATH" | sha256sum --check

if ! adb -s emulator-5554 install -r "$APK_PATH"; then
  echo "::error::Could not install $BROWSER_TO_INSTALL. Check the Android version and installation logs."
  exit 1
fi

echo "$BROWSER_TO_INSTALL installed successfully."
