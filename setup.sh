#!/usr/bin/env bash
# Installs the Android TV emulator and the TV system image.
# Then it creates the 1080p TV device "TVDroid". You can run this script again safely.
set -euo pipefail

IMAGE="system-images;android-34;google-tv;arm64-v8a"
AVD="TVDroid"

if ! command -v brew >/dev/null; then
  echo "Install Homebrew first: https://brew.sh" >&2
  exit 1
fi

echo "==> Install the Android command-line tools"
brew list --cask android-commandlinetools >/dev/null 2>&1 || brew install --cask android-commandlinetools

export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}"
export ANDROID_HOME="$ANDROID_SDK_ROOT"

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
