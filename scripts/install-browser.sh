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
    MAX_API=999
    APK_NAME="fennec-68.11.0.en-US.android-i386.apk"
    APK_URL="https://archive.mozilla.org/pub/mobile/releases/68.11.0/android-x86/en-US/fennec-68.11.0.en-US.android-i386.apk"
    APK_SHA256="333a551c0e91153640c180b2e56d270bf7b07428a7a4fcf9fec3f0d83b3771cb"
    ;;
  "Chrome 81.0.4044.138")
    MIN_API=19
    MAX_API=23
    APK_NAME="chrome-81.0.4044.138-x86.apk"
    APK_PAGE_URL="https://chrome.apk.watch/81.0.4044.138/404413801"
    APK_URL=""
    APK_MD5="454f252bad312b8c576c7ffc6d64eb8a"
    ;;
  "Opera 58.8.2878.72999")
    MIN_API=19
    MAX_API=20
    APK_NAME="opera-58.8.2878.72999-x86.apk"
    APK_URL="https://d.apkpure.com/b/APK/com.opera.browser?versionCode=1905822801&from=details"
    APK_REFERER="https://apkpure.com/opera-browser/com.opera.browser"
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
if [ "$ANDROID_API_LEVEL" -gt "$MAX_API" ]; then
  echo "::error::$BROWSER_TO_INSTALL is configured for Android API $MAX_API or older; selected $ANDROID_RELEASE (API $ANDROID_API_LEVEL). Choose a compatible Android release."
  exit 2
fi

APK_PATH="${RUNNER_TEMP:-/tmp}/$APK_NAME"
echo "Downloading $BROWSER_TO_INSTALL for x86 from its configured archive..."
if [[ "$BROWSER_TO_INSTALL" == "Chrome 81.0.4044.138" ]]; then
  # Use APK.watch's exact x86 / Android 4.4+ variant page, not APKPure's
  # direct-download endpoint which returns 403 in GitHub Actions.
  PAGE_PATH="${RUNNER_TEMP:-/tmp}/chrome-apkwatch-page.html"
  curl -fLsS --retry 3 --retry-delay 2 \
    --user-agent "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/131.0.0.0 Safari/537.36" \
    "$APK_PAGE_URL" -o "$PAGE_PATH"

  mapfile -t DOWNLOAD_URLS < <(
    grep -Eo '(href|data-href|data-url)="[^"]+"' "$PAGE_PATH" |
      cut -d '"' -f 2 |
      grep -Ei 'download|\.apk|file' |
      python3 -c 'import sys; from urllib.parse import urljoin; base="https://chrome.apk.watch/81.0.4044.138/404413801"; print("\n".join(dict.fromkeys(urljoin(base, x.strip()) for x in sys.stdin if x.strip())))' |
      grep '^https://'
  )
  if [[ "${#DOWNLOAD_URLS[@]}" -eq 0 ]]; then
    echo "::error::APK.watch page loaded, but no download link could be extracted."
    exit 1
  fi

  downloaded=false
  for candidate in "${DOWNLOAD_URLS[@]}"; do
    echo "Trying APK.watch download candidate."
    rm -f "$APK_PATH"
    if curl -fLsS --retry 1 --retry-delay 1 \
      --user-agent "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/131.0.0.0 Safari/537.36" \
      --referer "$APK_PAGE_URL" "$candidate" -o "$APK_PATH"; then
      if file "$APK_PATH" | grep -qiE 'Android package|Zip archive'; then
        downloaded=true
        break
      fi
    fi
  done
  if [[ "$downloaded" != true ]]; then
    echo "::error::Could not retrieve the Chrome APK from APK.watch. Its download endpoint may require browser-side JavaScript."
    exit 1
  fi
  echo "$APK_MD5  $APK_PATH" | md5sum --check
else
  curl -fLsS --retry 3 --retry-delay 2 "$APK_URL" -o "$APK_PATH"
  echo "$APK_SHA256  $APK_PATH" | sha256sum --check
fi

if ! adb -s emulator-5554 install -r "$APK_PATH"; then
  echo "::error::Could not install $BROWSER_TO_INSTALL. Check the Android version and installation logs."
  exit 1
fi

echo "$BROWSER_TO_INSTALL installed successfully."
