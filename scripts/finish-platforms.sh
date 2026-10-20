#!/bin/bash
# Run after manually installing/launching Xcode and Android Studio.
set -euo pipefail
ROOT="${HOME}/Developer/mac-setup"
[[ ! -r "${ROOT}/configs/env.zsh" ]] || source "${ROOT}/configs/env.zsh"
PROJECT="${ROOT}/state/flutter_smoke"
case "${1:-doctor}" in
  apple)
    [[ -d /Applications/Xcode.app ]] || { echo '先从 App Store 安装 Xcode'; exit 1; }
    echo '将用 sudo 选择完整 Xcode 开发目录。许可需阅读后自行接受。'
    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
    sudo xcodebuild -license
    sudo xcodebuild -runFirstLaunch
    xcrun simctl list devices available
    (cd "${PROJECT}"; flutter build macos --debug; flutter build ios --simulator)
    ;;
  android)
    STUDIO='/Applications/Android Studio.app/Contents/jbr/Contents/Home'
    [[ -d "${STUDIO}" ]] || { echo '先安装并首次启动 Android Studio'; exit 1; }
    export JAVA_HOME="${STUDIO}"
    export ANDROID_HOME="${HOME}/Library/Android/sdk"
    flutter config --jdk-dir "${JAVA_HOME}" --android-sdk "${ANDROID_HOME}"
    sdkmanager="${ANDROID_HOME}/cmdline-tools/latest/bin/sdkmanager"
    [[ -x "${sdkmanager}" ]] || { echo '在 Android Studio > SDK Manager > SDK Tools 安装 Android SDK Command-line Tools (latest) 后重跑'; exit 1; }
    "${sdkmanager}" --sdk_root="${ANDROID_HOME}" --licenses
    # Resolve compile SDK from the installed Flutter SDK, instead of freezing today's API level.
    FLUTTER_BIN=$(python3.13 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$(command -v flutter)")
    FLUTTER_ROOT=$(cd "$(dirname "${FLUTTER_BIN}")/.." && pwd -P)
    extension="${FLUTTER_ROOT}/packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt"
    api=$(sed -nE 's/.*compileSdkVersion[^=]*= *([0-9]+).*/\1/p' "${extension}" | head -1)
    [[ "${api}" =~ ^[0-9]+$ ]] || { echo '无法解析 SDK 版本；请根据 flutter doctor -v 在 SDK Manager 安装平台'; exit 1; }
    "${sdkmanager}" --sdk_root="${ANDROID_HOME}" 'platform-tools' "platforms;android-${api}"
    flutter doctor --android-licenses
    (cd "${PROJECT}"; flutter build apk --debug)
    ;;
  doctor) flutter doctor -v;;
  *) echo 'Usage: bash finish-platforms.sh [apple|android|doctor]'; exit 2;;
esac
