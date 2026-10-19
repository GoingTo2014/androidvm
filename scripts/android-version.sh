#!/usr/bin/env bash
# Shared Android release-to-SDK-image mapping.
# API 13 / Android 3.2 is intentionally omitted: the official Google APIs SDK
# repository does not list an installable x86 image for that release.
ANDROID_VERSION="${ANDROID_VERSION:-4.4 (API 19)}"

case "$ANDROID_VERSION" in
  "2.3.3 (API 10)")
    ANDROID_API_LEVEL=10
    ANDROID_ARCH=x86
    ANDROID_RELEASE="Android 2.3.3 Gingerbread"
    ANDROID_AVD_NAME=Gingerbread
    ;;
  "4.0.4 (API 15)")
    ANDROID_API_LEVEL=15
    ANDROID_ARCH=x86
    ANDROID_RELEASE="Android 4.0.4 Ice Cream Sandwich"
    ANDROID_AVD_NAME=IceCreamSandwich
    ;;
  "4.1 (API 16)")
    ANDROID_API_LEVEL=16
    ANDROID_ARCH=x86
    ANDROID_RELEASE="Android 4.1 Jelly Bean"
    ANDROID_AVD_NAME=JellyBean41
    ;;
  "4.3 (API 18)")
    ANDROID_API_LEVEL=18
    ANDROID_ARCH=x86
    ANDROID_RELEASE="Android 4.3 Jelly Bean"
    ANDROID_AVD_NAME=JellyBean43
    ;;
  "4.4 (API 19)")
    ANDROID_API_LEVEL=19
    ANDROID_ARCH=x86
    ANDROID_RELEASE="Android 4.4 KitKat"
    ANDROID_AVD_NAME=KitKat
    ;;
  "5.0 (API 21)")
    ANDROID_API_LEVEL=21
    ANDROID_ARCH=x86
    ANDROID_RELEASE="Android 5.0 Lollipop"
    ANDROID_AVD_NAME=Lollipop50
    ;;
  "5.1 (API 22)")
    ANDROID_API_LEVEL=22
    ANDROID_ARCH=x86
    ANDROID_RELEASE="Android 5.1 Lollipop"
    ANDROID_AVD_NAME=Lollipop51
    ;;
  "6.0 (API 23)")
    ANDROID_API_LEVEL=23
    ANDROID_ARCH=x86
    ANDROID_RELEASE="Android 6.0 Marshmallow"
    ANDROID_AVD_NAME=Marshmallow
    ;;
  "7.0 (API 24)")
    ANDROID_API_LEVEL=24
    ANDROID_ARCH=x86
    ANDROID_RELEASE="Android 7.0 Nougat"
    ANDROID_AVD_NAME=Nougat
    ;;
  *)
    echo "::error::Unsupported ANDROID_VERSION: $ANDROID_VERSION"
    exit 2
    ;;
esac

ANDROID_SYSTEM_IMAGE_PACKAGE="system-images;android-${ANDROID_API_LEVEL};google_apis;${ANDROID_ARCH}"
ANDROID_SYSTEM_IMAGE_DIR="${ANDROID_HOME:-$HOME/.android-sdk}/system-images/android-${ANDROID_API_LEVEL}/google_apis/${ANDROID_ARCH}"
