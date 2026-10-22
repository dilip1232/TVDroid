# TVDroid

TVDroid is a macOS app that runs Android TV apps on your Mac at TV size (1080p).
Put `.apk` files in a folder, then double-click an app to open it on the TV.

TVDroid uses the official Android emulator with a Google TV system image.
It shows the TV picture in its own window and adds a phone remote.

## Features

- **APK library.** TVDroid watches `~/TVDroid/APKs` and shows each app with its icon or TV banner.
  Double-click an app to install it (if necessary) and open it.
- **TV window.** The window shows the emulator picture directly from shared memory.
  It uses Metal with the host GPU, so there is no video encoding and no quality loss.
  - Aspect-fit 16:9 picture with black bars and bicubic upscaling.
  - Full-screen mode (⌘F).
  - The cursor and controls hide after 2.5 seconds without mouse movement.
  - **Back** and **Home** buttons in the top-left corner.
- **Keyboard and mouse.** Mac keys go to Android through a virtual USB keyboard (`uinput`).
  Clicks go to Android as touches.
- **Phone remote.** Scan a QR code to open a D-pad remote in your phone's browser.
  The remote sends keys and text over your Wi-Fi network.
- **Google Play.** The Google TV image includes Google Play Services and the Play Store.

## Requirements

- A Mac with Apple silicon (arm64) and macOS 14 or later.
- [Homebrew](https://brew.sh).
- The Xcode Command Line Tools (`xcode-select --install`). You do not need the full Xcode.
- Java 17 (for the Android SDK tools), for example `brew install openjdk@17`.
- About 10 GB of free disk space.

## Setup

1. Clone the repository:
   ```bash
   git clone https://github.com/dilip1232/TVDroid.git
   cd TVDroid
   ```
2. Install the emulator and the Google TV image, and create the TV device:
   ```bash
   ./setup.sh
   ```
3. Build the app:
   ```bash
   ./build.sh            # builds build/TVDroid.app
   ./build.sh --install  # also copies it to /Applications
   ```
4. Open `TVDroid.app`.
5. Click **Show TV**. The first start takes about 15 seconds.
6. Sign in to your Google account on the TV if you want to use the Play Store.

## Use

| Action | How |
|---|---|
| Open an app | Put the `.apk` in `~/TVDroid/APKs`, then double-click it in TVDroid |
| Move the focus | Arrow keys |
| Select (OK) | Return |
| Back | Esc, right-click, or the **Back** button |
| Home | ⌥H or the **Home** button |
| Type | Type on the Mac keyboard when a text box is open |
| Scroll | Mouse wheel or trackpad (sends Up and Down) |
| Full screen | ⌘F or the green window button |
| Turn off the TV | **Turn Off TV** in the main window, or quit TVDroid |

**Note:** TV apps are made for a remote. Many TV screens do not react to mouse clicks.
If a click does nothing, move to the item with the arrow keys and press Return.

### Phone remote

1. In the main window, click **Phone Remote**.
2. Scan the QR code with your phone. The phone must be on the same Wi-Fi network as the Mac.
3. Use the D-pad, the media keys, or the text box to control the TV.

**CAUTION:** If the macOS firewall is on, it can block the remote.
Allow TVDroid with these commands (change the path if you installed the app somewhere else):

```bash
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add /Applications/TVDroid.app/Contents/MacOS/TVDroid
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp /Applications/TVDroid.app/Contents/MacOS/TVDroid
```

Each new build has a new ad-hoc signature, so you can have to do this again after you rebuild.

## How it works

```
TVDroid.app
 ├─ TVController      starts the emulator (headless, -share-vid, -no-snapshot), installs and opens APKs with adb
 ├─ TVScreen          maps the emulator frame buffer (POSIX shm "videmulator5580") and draws it with Metal
 ├─ VirtualKeyboard   runs `adb shell uinput -` and sends key events as a virtual USB keyboard
 ├─ EmulatorConsole   sends touch events through the emulator console (telnet port 5580)
 └─ RemoteServer      HTTP server on port 8765 with a token URL for the phone remote
```

- The emulator runs on console port 5580 (adb serial `emulator-5580`) with `-gpu host` and `-no-window`.
- With `-share-vid`, the emulator writes each frame (BGRA, 1920×1080) to shared memory.
  The C target `CShm` maps it, because Swift cannot call the variadic `shm_open`.
- The TV always starts with a cold boot (`-no-snapshot`). After a Quick Boot snapshot restore,
  the host GPU can show an old picture for new screens.
- Logs: `~/TVDroid/logs/emulator.log`.

## Project layout

```
Package.swift          SwiftPM package (macOS 14, no external dependencies)
Sources/CShm/          C helper to map POSIX shared memory
Sources/TVDroid/       the app (SwiftUI + AppKit + Metal)
scripts/make_icon.swift  draws the app icon
setup.sh               installs the SDK packages and creates the "TVDroid" AVD
build.sh               builds and signs build/TVDroid.app
```

## Known limits

- **YouTube for TV** shows "not supported on this device", because the emulator is not a certified device.
  Use [SmartTube](https://github.com/yuliskov/SmartTube) or a TV browser instead.
- **DRM.** The emulator has Widevine L3 only. Netflix and similar apps play at low resolution or do not play.
- **4K is not supported.** The emulator frame sharing needs a larger `kern.sysv.shmmax` than macOS allows by default.
- **Root.** The Google TV image is a `user` build. `adb root` is not available.

## Disclaimer

This is a personal project. It is not affiliated with Google or Android.
Install only APKs that you trust and that you have the right to use.
