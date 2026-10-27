# TVDroid

[![CI](https://github.com/dilip1232/TVDroid/actions/workflows/ci.yml/badge.svg)](https://github.com/dilip1232/TVDroid/actions/workflows/ci.yml)

TVDroid is a macOS app that runs Android TV apps on your Mac at TV size (1080p).
Put `.apk` files in a folder, then double-click an app to open it on the TV.

TVDroid uses the official Android emulator with a Google TV system image.
It shows the TV picture in its own window and adds a phone remote.

## Features

- **APK library.** TVDroid watches `~/TVDroid/APKs` and shows each app with its icon or TV banner.
  Double-click an app to install it (if necessary) and open it. Drop files on the window to add them.
  Right-click an app to uninstall it from the TV or move the file to the Trash.
- **Split APKs.** `.xapk` (APKPure), `.apks` (bundletool, SAI) and `.apkm` (APKMirror) bundles install with
  `adb install-multiple`. x86 splits are skipped. OBB game data in an `.xapk` is copied to the TV.
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
  The **Trackpad** tab moves a mouse pointer on the TV: tap to click, two fingers to scroll
  (for web pages in TV browsers), hold to drag.
- **Game controllers.** PlayStation, Xbox, MFi and Switch Pro controllers that are connected to the Mac
  work on the TV at once, as a virtual USB gamepad. A selects, B goes back, the stick and D-pad move the focus.
  Hold Select (View / Share / −) and press RB / LB for volume up / down, Y for Home, X for mute.
  The controller's own Home button is not used, because macOS opens the Games app with it.
  Generic USB and Bluetooth pads for Windows ("DirectInput" pads, arcade sticks) that macOS does not support
  work too: TVDroid reads them as raw HID devices, the same way Wine and GPTK do. Their button numbers differ
  from pad to pad, so use **Settings ▸ TV ▸ Set Up Buttons…** once if A/B are wrong. The mapping is saved per
  controller model. Wired Xbox 360 pads (and clones) are not HID devices and need a driver, as with Wine.
- **Screenshots and recordings.** **TV ▸ Take Screenshot** (⇧⌘S) and **TV ▸ Start Recording** (⇧⌘R)
  save to the Desktop. Android stops a recording after 3 minutes.
- **Settings (⌘,).** Screen size 1080p or 720p, home app, Reset TV (factory reset), Java and SDK folders.
- **Home app.** Google TV always opens its own launcher and ignores other launchers such as Projectivy.
  **Settings ▸ TV ▸ Home app** turns the Google TV launcher off (`pm disable-user`, not removed), so Home
  and the boot go to the launcher you choose. Choose Google TV to turn it on again. A Reset TV also turns it on again.
- **Rooted TV (experimental).** **Settings ▸ Root** patches a copy of the TV's ramdisk with Magisk 26.4
  (made with [rootAVD](https://gitlab.com/newbit/rootAVD), downloaded on first use) and starts the TV with
  `-ramdisk`. The SDK files are not changed; turn it off to start the original TV again. Google TV and the
  Play Store stay. `adb -s emulator-5580 shell su` works without a prompt on the TV. With root:
  - **Ad blocking** for the whole TV: the StevenBlack hosts list as a Magisk module.
  - **App backup** with data (logins, settings) to `~/TVDroid/Backups`, and restore, for example after a Reset TV.

  Root does not improve DRM (Widevine L3) or Play Integrity. Log: `~/TVDroid/logs/root.log`.
- **Update check.** TVDroid checks GitHub for a new release once a day (or **TVDroid ▸ Check for Updates…**).
- **Google Play.** The Google TV image includes Google Play Services and the Play Store.

## Requirements

- A Mac with Apple silicon (arm64) and macOS 14 or later.
- About 10 GB of free disk space.
- To build from source: the Xcode Command Line Tools (`xcode-select --install`). You do not need the full Xcode.

TVDroid installs the rest for you on the first start: [Homebrew](https://brew.sh) (if it is missing),
Java 17, the Android command-line tools, the emulator and the Google TV image.

## Setup

1. Get the app:
   - Download the DMG from [Releases](https://github.com/dilip1232/TVDroid/releases) and drag TVDroid to Applications.
     If the release is not notarized, run this once before the first start:
     ```bash
     xattr -dr com.apple.quarantine /Applications/TVDroid.app
     ```
   - Or build it from source:
     ```bash
     git clone https://github.com/dilip1232/TVDroid.git
     cd TVDroid
     ./build.sh            # builds build/TVDroid.app
     ./build.sh --install  # also copies it to /Applications
     ./build.sh --dmg      # also makes build/TVDroid-<version>.dmg
     ```
2. Open `TVDroid.app`. The first time, it shows **Set up the TV** with these steps:

   | Step | What TVDroid does |
   |---|---|
   | Homebrew | Opens the official installer in Terminal. Enter your Mac password there. |
   | Java 17 | `brew install openjdk@17` |
   | Android command-line tools | `brew install --cask android-commandlinetools` |
   | Emulator and Google TV image | Accepts the SDK licenses and installs `platform-tools`, `emulator`, `build-tools;34.0.0` and `system-images;android-34;google-tv;arm64-v8a` (about 2 GB) |
   | TV device | Creates the 1080p AVD `TVDroid` and sets its config |

   Click **Install**. Steps that are already done are skipped. The log is in `~/TVDroid/logs/setup.log`.
   If a step fails, fix the problem and click **Install** again. A failed step also shows:
   - **Open in Terminal**: opens the command in Terminal, in your own shell with your `~/.zshrc`.
     The command is on the command line, so you can edit it before you press Return.
   - **Copy Command**: copies the command with the same `JAVA_HOME` and `ANDROID_HOME` that TVDroid uses.
3. Click **Show TV**. The first start takes about 15 seconds.
4. Sign in to your Google account on the TV if you want to use the Play Store.

### Java, the SDK and your shell

Apps from the Dock do not read `~/.zshrc`. TVDroid starts your login shell once at launch and reads
`JAVA_HOME`, `ANDROID_HOME` and `PATH` from it, so it finds the same tools as Terminal.

- TVDroid needs Java 17 or later. It checks the version, not only the folder.
- Homebrew's `openjdk@17` is "keg-only": macOS's `/usr/bin/java` does not know it, so `java` and `sdkmanager`
  fail in Terminal although TVDroid works. Click **Register Java** next to the Java step
  (or run the command below). It needs your password once.
  ```bash
  sudo ln -sfn /opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk /Library/Java/JavaVirtualMachines/openjdk-17.jdk
  ```
- **Advanced** (on the setup screen, and in Settings ▸ Tools) lets you choose a Java home and an SDK folder,
  open Terminal with the SDK on the `PATH`, or add the TVDroid lines to `~/.zshrc`.
  TVDroid marks its lines with `# >>> TVDroid >>>` and saves a backup in `~/.zshrc.tvdroid-backup`.
- Before the 2 GB download, TVDroid checks that the disk has 8 GB free.
You can also do the setup in a terminal with `./setup.sh`. It does the same steps, but you must install Homebrew and Java first.

### Test the setup

To test the setup screen without touching your real SDK and TV device, start the app with a test folder:

```bash
./build.sh
TVDROID_TEST_HOME=/tmp/tvd-test build/TVDroid.app/Contents/MacOS/TVDroid
```

In test mode, the SDK, the TV device, the APK folder and the logs are in `/tmp/tvd-test`.
Homebrew, Java and the command-line tools are still the ones on your Mac, so these steps show as done.
**Install** downloads the emulator and the TV image again (about 2 GB) into the test folder.
Delete `/tmp/tvd-test` to start again. Turn off your real TV first: both use console port 5580.

## Use

| Action | How |
|---|---|
| Add an app | Drop an `.apk`, `.xapk`, `.apks` or `.apkm` on the window, or put it in `~/TVDroid/APKs` |
| Open an app | Double-click it in TVDroid |
| Uninstall an app | Right-click it ▸ **Uninstall from TV** |
| Move the focus | Arrow keys |
| Select (OK) | Return |
| Back | Esc, right-click, or the **Back** button |
| Home | ⌥H or the **Home** button |
| Type | Type on the Mac keyboard when a text box is open |
| Scroll | Mouse wheel or trackpad (sends Up and Down) |
| Full screen | ⌘F or the green window button |
| Screenshot / recording | ⇧⌘S / ⇧⌘R (saved to the Desktop) |
| Game controller | Connect it to the Mac (Bluetooth or USB). It works on the TV at once |
| Turn off the TV | **Turn Off TV** in the main window, or quit TVDroid |

**Note:** TV apps are made for a remote. Many TV screens do not react to mouse clicks.
If a click does nothing, move to the item with the arrow keys and press Return.

### Phone remote

1. In the main window, click **Phone Remote**.
2. Scan the QR code with your phone. The phone must be on the same Wi-Fi network as the Mac.
3. Use the D-pad, the media keys, or the text box to control the TV.
4. Open the **Trackpad** tab for a mouse pointer: one finger moves, tap clicks, two fingers scroll,
   a two-finger tap goes back, and a long press starts a drag. The slider sets the pointer speed.

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
 ├─ SetupManager      first-start setup: installs Java, the SDK, the emulator and the TV image, creates the AVD
 ├─ TVController      starts the emulator (headless, -share-vid, -no-snapshot), installs and opens APKs with adb
 ├─ TVScreen          maps the emulator frame buffer (POSIX shm "videmulator5580") and draws it with Metal
 ├─ VirtualKeyboard   runs `adb shell uinput -` and sends key events as a virtual USB keyboard (also VirtualMouse)
 ├─ GameController    maps Mac game controllers (GameController framework) to a virtual uinput gamepad
 ├─ RootManager       rooted TV (Magisk ramdisk via rootAVD), ad blocking, app backup
 ├─ HIDGamepads       reads other gamepads and joysticks with IOHIDManager, with a per-model button map
 ├─ TerminalLauncher  opens setup commands in Terminal with the user's shell files and TVDroid's variables
 ├─ UpdateChecker     asks the GitHub releases API for a newer version
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
setup.sh               terminal version of the in-app setup (SDK packages and the "TVDroid" AVD)
build.sh               builds and signs build/TVDroid.app (and the DMG)
VERSION                the app version (used by build.sh and the release workflow)
.github/               CI and release workflows, Dependabot
```

## CI and releases

| Workflow | When it runs | What it does |
|---|---|---|
| `ci.yml` | Push to `main`, `dev` or `feature/*`, and pull requests | Runs ShellCheck, builds the app and the DMG on macOS, checks the bundle, uploads the DMG |
| `release.yml` | `VERSION` changes on `main`, or a manual run | Builds the DMG and creates the GitHub release `v<version>` with a SHA-256 file |
| Dependabot | Weekly | Updates the GitHub Actions versions |

To make a release:
1. Change the version in `VERSION` (for example `v1.1.0`).
2. Commit and push the change to `main`.

If the tag already exists, the release workflow stops and does not change the old release.

**Signing and notarization (optional).** Without secrets, the DMG has an ad-hoc signature. To sign with a
Developer ID and notarize, add these repository secrets: `MACOS_CERT_P12` (base64 of the `.p12`),
`MACOS_CERT_PASSWORD`, `MACOS_SIGN_IDENTITY` (for example `Developer ID Application: Name (TEAMID)`),
`NOTARY_APPLE_ID`, `NOTARY_TEAM_ID` and `NOTARY_PASSWORD` (an app-specific password).
Locally: `SIGN_IDENTITY="Developer ID Application: …" NOTARY_APPLE_ID=… NOTARY_TEAM_ID=… NOTARY_PASSWORD=… ./build.sh --dmg`.

## Known limits

- **YouTube for TV** shows "not supported on this device", because the emulator is not a certified device.
  Use [SmartTube](https://github.com/yuliskov/SmartTube) or a TV browser instead.
- **DRM.** The emulator has Widevine L3 only. Netflix and similar apps play at low resolution or do not play.
- **4K is not supported.** The emulator frame sharing needs a larger `kern.sysv.shmmax` than macOS allows by default.
- **Root.** The Google TV image is a `user` build. `adb root` is not available.

## Disclaimer

This is a personal project. It is not affiliated with Google or Android.
Install only APKs that you trust and that you have the right to use.
