#!/usr/bin/env bash
# Installs the Android TV emulator and the TV system image.
# Then it creates the 1080p TV device "TVDroid". You can run this script again safely.
set -euo pipefail

IMAGE="system-images;android-34;google-tv;arm64-v8a"
AVD="TVDroid"

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
if ! command -v brew >/dev/null; then
  echo "Install Homebrew first: https://brew.sh" >&2
  exit 1
fi

# Java 17 or later. Homebrew installs openjdk@17 "keg-only", so plain `java` may not find it.
java_major() {
  "$1/bin/java" -version 2>&1 | awk -F'"' '/version "/ { split($2, v, "."); print (v[1] == "1" ? v[2] : v[1]); exit }'
}
find_java() {
  local home
  for home in "${JAVA_HOME:-}" "$(/usr/libexec/java_home -v 17+ 2>/dev/null || true)" \
      /opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
      /opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home \
      /opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home \
      /usr/local/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home; do
    if [ -n "$home" ] && [ -x "$home/bin/java" ] && [ "$(java_major "$home")" -ge 17 ] 2>/dev/null; then
      echo "$home"
      return 0
    fi
  done
  return 1
}
if ! JAVA_HOME="$(find_java)"; then
  echo "==> Install Java 17"
  brew install openjdk@17
  JAVA_HOME="$(find_java)" || { echo "Java 17 or later was not found. Set JAVA_HOME and run again." >&2; exit 1; }
fi
export JAVA_HOME
export PATH="$JAVA_HOME/bin:$PATH"
echo "==> Using Java $(java_major "$JAVA_HOME") from $JAVA_HOME"
if ! /usr/libexec/java_home -v 17+ >/dev/null 2>&1; then
  echo "    Note: Terminal does not find this Java by itself. To fix it, run:"
  echo "    sudo ln -sfn \"${JAVA_HOME%/Contents/Home}\" /Library/Java/JavaVirtualMachines/openjdk-17.jdk"
fi

echo "==> Install the Android command-line tools"
brew list --cask android-commandlinetools >/dev/null 2>&1 || brew install --cask android-commandlinetools

export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}"
export ANDROID_HOME="$ANDROID_SDK_ROOT"
export PATH="$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$PATH"

FREE_GB=$(df -g "$HOME" | awk 'NR == 2 { print $4 }')
if [ "${FREE_GB:-0}" -lt 8 ]; then
  echo "Only ${FREE_GB} GB is free. TVDroid needs about 8 GB." >&2
  exit 1
fi

echo "==> Install the emulator and the Google TV image (about 2 GB)"
yes | sdkmanager --licenses >/dev/null 2>&1 || true
sdkmanager --install "platform-tools" "emulator" "build-tools;34.0.0" "$IMAGE" | tr "\r" "\n" | { grep -vE "^\[|^$" || true; }

echo "==> Create the 1080p TV device \"$AVD\""
if [ ! -f "$HOME/.android/avd/$AVD.ini" ]; then
  echo "no" | avdmanager create avd -n "$AVD" -k "$IMAGE" -d tv_1080p
fi

CONFIG="$HOME/.android/avd/$AVD.avd/config.ini"
set_key() {
  if grep -q "^$1=" "$CONFIG"; then
    sed -i '' "s|^$1=.*|$1=$2|" "$CONFIG"
  else
    echo "$1=$2" >> "$CONFIG"
  fi
}
set_key hw.lcd.width 1920
set_key hw.lcd.height 1080
set_key hw.initialOrientation landscape
set_key hw.gpu.enabled yes
set_key hw.gpu.mode host
set_key hw.ramSize 4096
set_key hw.cpu.ncore 4
set_key hw.keyboard yes
set_key showDeviceFrame no
set_key hw.audioOutput yes
set_key disk.dataPartition.size 16G
set_key fastboot.forceColdBoot no

mkdir -p "$HOME/TVDroid/APKs"
echo "==> Done. Put .apk files in ~/TVDroid/APKs"
echo "To use sdkmanager, adb and emulator in Terminal, add this to your ~/.zshrc:"
echo "  export JAVA_HOME=\"$JAVA_HOME\""
echo "  export ANDROID_HOME=\"$ANDROID_SDK_ROOT\""
echo "  export PATH=\"\$JAVA_HOME/bin:\$ANDROID_HOME/cmdline-tools/latest/bin:\$ANDROID_HOME/platform-tools:\$ANDROID_HOME/emulator:\$PATH\""
