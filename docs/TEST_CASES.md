# TVDroid end-user test cases

Manual tests from a user's point of view. Run them on a release build (`./build.sh`) installed in Applications, not `swift run`.

Each case lists the steps and what should happen. **[Fixed: retest]** marks a case that the code review found failing and that has since been fixed. Test these first: none has been checked on a running TV yet.

Status column: ✅ pass · ❌ fail · ⏭ skipped.

## 1. Install and first launch

| ID | Steps | Expected | Status |
|---|---|---|---|
| IN-1 | Open the DMG, drag TVDroid to Applications, open it | App opens. Gatekeeper warning only for an ad-hoc build | |
| IN-2 | TVDroid ▸ About TVDroid | Shows the released version (for example 1.3.0) | |
| IN-3 | Install a new version over an old one, open it | Settings, controller mappings, remote QR, and TV apps are all still there | |
| IN-4 | Have two copies (Applications and ~/Applications), open each | Both read the same settings. Spotlight shows two. Remove one | |
| IN-5 | Launch with no internet | App opens. No update alert. No hang | |

## 2. First-run setup

| ID | Steps | Expected | Status |
|---|---|---|---|
| SU-1 | Fresh Mac account, open TVDroid | "Set up the TV" with 5 steps, each "Not installed" or "Done" | |
| SU-2 | Click Install | Steps run in order with spinners, and each ends "Done". Library appears | |
| SU-3 | Run Install with less than 8 GB free | SDK step fails with a disk-space message | |
| SU-4 | Homebrew missing: click Install, then close Terminal without installing | "Stop Waiting" button appears. Clicking it ends the wait and Install works again **[Fixed: retest]** | |
| SU-5 | Quit during the SDK download, reopen, click Install | Quitting stops brew and sdkmanager. Install again runs only one download **[Fixed: retest]** | |
| SU-6 | Make a step fail (turn off Wi-Fi mid-download) | Orange triangle plus error. "Open in Terminal" and "Copy Command" work | |
| SU-7 | Show Log | Finder opens ~/TVDroid/logs | |
| SU-8 | Advanced: choose a folder without bin/java, Save and Check | Rejected with a message | |
| SU-9 | Advanced: "Add to .zshrc" then "Update .zshrc" | Block written once, backup created. New Terminal finds adb | |
| SU-10 | "Add to .zshrc" when ~/.zshrc is a symlink (dotfiles repo) | The file the link points to gets the block. The link stays a link **[Fixed: retest]** | |
| SU-11 | Default shell is fish | .zshrc button refuses with a clear message | |

## 3. App library (main window)

| ID | Steps | Expected | Status |
|---|---|---|---|
| LB-1 | Empty APK folder | "No apps yet" and an "Open APK Folder" button | |
| LB-2 | Drop one .apk on the window | Tile appears with name, icon, and "TV app" or "Phone app" plus version | |
| LB-3 | Drop .xapk, .apks, .apkm bundles | Each shows as one tile and installs | |
| LB-4 | Drop a 2 GB+ game bundle | UI stays responsive during the copy. The tile appears with name and icon when the copy ends **[Fixed: retest]** | |
| LB-5 | Drop a non-APK file (PDF) | Ignored or a clear message. No crash | |
| LB-6 | Add a file with Finder directly into ~/TVDroid/APKs | Tile appears within about 1 s | |
| LB-7 | Corrupt APK (rename a .txt to .apk) | Tile says "Cannot read this APK". Open shows an error | |
| LB-8 | Double-click a tile with the TV off | "Starting TV…" → "Installing…" → "Opening…", then the TV opens full screen in that app | |
| LB-9 | Double-click the same tile again | No reinstall. Opens straight away | |
| LB-10 | Replace the APK with a newer version, double-click | Reinstalls, keeps app data | |
| LB-11 | Double-click a second tile while the first is installing | Message: "TVDroid is busy: … Try again when it is done." **[Fixed: retest]** | |
| LB-12 | Game with OBB data | "Copying game data…" then the game loads its data | |
| LB-13 | x86-only APK | Message: "This APK has no ARM version…" | |
| LB-14 | APK with a different signature than the installed one | Message tells you to uninstall first | |
| LB-15 | Right-click ▸ Uninstall from TV | App removed from the TV. Tile stays | |
| LB-16 | Right-click ▸ Move to Trash | File goes to Trash (note: no confirmation) | |
| LB-17 | Right-click ▸ Show in Finder | Finder selects the file | |
| LB-18 | Keyboard: arrows to select, Return to open | Works like double-click | |

## 4. TV power and state

| ID | Steps | Expected | Status |
|---|---|---|---|
| PW-1 | Show TV (⇧⌘T) from off | Status "TV is starting…" then "TV is on". Picture appears | |
| PW-2 | Turn Off TV | Window hides, status "TV is off". No emulator in Activity Monitor (qemu) | |
| PW-3 | Turn Off TV while an app is installing | Turn Off TV is disabled until the install ends **[Fixed: retest]** | |
| PW-4 | ⇧⌘T while an app is installing | TV window comes forward. The install progress stays, buttons stay disabled **[Fixed: retest]** | |
| PW-5 | TV ▸ Restart TV | TV turns off and back on. Picture returns | |
| PW-6 | Quit TVDroid (⌘Q) with the TV on | No qemu process left in Activity Monitor | |
| PW-7 | Quit within 3 s of Show TV | No qemu left in Activity Monitor. The next Show TV works **[Fixed: retest]** | |
| PW-8 | Quit with the TV on but force-quit TVDroid (Activity Monitor), reopen | App adopts the running TV and shows "TV is on" | |
| PW-9 | After PW-8: Restart TV, change Screen size, or Reset TV | Restart, Screen size and Reset each work. Status matches the TV **[Fixed: retest]** | |
| PW-10 | Kill the qemu process in Activity Monitor while the TV is on | Within 5 s the TV window closes and the main window says "The TV stopped unexpectedly…" **[Fixed: retest]** | |
| PW-11 | Close the main window while the TV window is open | App keeps running | |
| PW-12 | Close the TV window while the main window is closed | TV window hides. App and TV keep running. Dock icon or ⇧⌘T brings them back **[Fixed: retest]** | |
| PW-13 | Android Studio open with its own emulator, then Show TV | TVDroid's TV starts on its own port, and both work | |

## 5. TV window

| ID | Steps | Expected | Status |
|---|---|---|---|
| TW-1 | Resize the window | Picture stays 16:9 with black bars. Can't go under 640×360 | |
| TW-2 | ⌘F and the green button | Toggles full screen both ways | |
| TW-3 | Leave the mouse still for 3 s | Window buttons, Back/Home, and the cursor hide. Moving brings them back | |
| TW-4 | Back and Home buttons | Go back and home on the TV | |
| TW-5 | Close the TV window, then Show TV | Same app still on screen (the TV kept running) | |
| TW-6 | Quit and reopen | TV window opens at the same size and position | |
| TW-7 | Put the TV window on an external monitor, quit, unplug the monitor, reopen, Show TV | Window appears on the built-in screen (unverified: it may open off-screen) | |
| TW-8 | Turn Off TV while entering full screen | Window hides and does not reappear later | |

## 6. Keyboard, mouse, trackpad on the Mac

| ID | Steps | Expected | Status |
|---|---|---|---|
| KM-1 | Arrows, Return | Move focus, select | |
| KM-2 | Esc, right-click | Back | |
| KM-3 | ⌥H | Home | |
| KM-4 | Type in a TV search field | Text appears, including Shift for capitals | |
| KM-5 | Hold an arrow | Repeats smoothly, stops at once on release | |
| KM-6 | Hold an arrow, ⌘-Tab away, release | Key does not stay held on the TV | |
| KM-7 | Click a button in a touch-friendly app | Tapped | |
| KM-8 | Press in the picture, drag into the black bar or off the window, release; then click again | The touch ends at the edge of the picture. Next clicks work **[Fixed: retest]** | |
| KM-9 | Hold left Shift, press right Shift, release left then right, then type | Typing goes back to lowercase after both Shift keys are up. Same for Control **[Fixed: retest]** | |
| KM-10 | Two-finger scroll on the trackpad | Focus moves up or down one row per step, no runaway from momentum | |
| KM-11 | Non-US Mac keyboard layout, type letters | Types US key positions (by design). Note what the user sees | |
| KM-12 | ⌘Q, ⌘, with the TV window focused | Stay on the Mac (quit, settings) | |

## 7. Phone remote

| ID | Steps | Expected | Status |
|---|---|---|---|
| RM-1 | Click Phone Remote, scan the QR on a phone on the same Wi-Fi | Remote page opens, status "Connected" | |
| RM-2 | Every Remote-tab button: D-pad, OK, Back, Home, Search, Rewind, Play/Pause, Forward, Vol−, Mute, Vol+ | Each acts on the TV. Held arrows and volume repeat | |
| RM-3 | Type text, Send; press Delete | Text appears in the TV field. Delete removes characters | |
| RM-4 | Send é, ü, or an emoji | Supported letters are typed. The remote shows "Cannot type: é…" for the rest **[Fixed: retest]** | |
| RM-5 | Trackpad tab: move, tap, two-finger scroll, two-finger tap, hold-and-drag, Speed slider | Pointer moves, clicks, scrolls web pages, Back, drags. Speed is remembered | |
| RM-6 | Reload the page | Last tab and speed are remembered | |
| RM-7 | Phone remote with the TV off | Remote shows "TV is off" **[Fixed: retest]** | |
| RM-8 | Mac on Ethernet plus Wi-Fi, or a Mac mini/iMac | QR shows the home-network address (192.168…, 10…, or 172.16–31…), never 169.254… **[Fixed: retest]** | |
| RM-9 | Save the remote to the phone home screen, reconnect the Mac to Wi-Fi so it gets a new IP | Popover shows the new address at once. Scan again on the phone **[Fixed: retest]** | |
| RM-10 | Another app already uses port 8765, open TVDroid | Server starts by itself within about 5 s after the port is free, or when you open the popover **[Fixed: retest]** | |
| RM-11 | Mac sleeps and wakes, use the remote | Still works (unverified) | |
| RM-12 | Open the URL with a wrong token | Rejected | |
| RM-13 | A guest scanned the QR once | Click "New Link" in the popover. The old link stops working; scan the new one **[Fixed: retest]** | |

## 8. Game controllers

| ID | Steps | Expected | Status |
|---|---|---|---|
| GC-1 | Pair an Xbox or PlayStation pad, TV on | A selects, B is Back, stick and D-pad move focus, games see a gamepad | |
| GC-2 | Hold Select + RB / LB / Y / X | Vol+, Vol−, Home, Mute. Tapping Select alone sends Select | |
| GC-3 | Two pads at once | Both work | |
| GC-4 | Turn the pad off while holding a button | Button does not stay held on the TV | |
| GC-5 | Switch to another Mac app or a Steam game, use the pad | TV ignores the pad while another app is in front and the TV window is hidden or covered **[Fixed: retest]** | |
| GC-6 | Generic USB pad: Settings ▸ TV ▸ Set Up Buttons…, map all 13, test | Each mapped button works. Reset clears it | |
| GC-7 | Map the "Home / Guide" button on a generic pad, press it | Home button goes to the TV home screen **[Fixed: retest]** | |
| GC-8 | Generic pad while a menu or alert is open | Pad keeps working while a menu or alert is open **[Fixed: retest]** | |
| GC-9 | No pad connected, open Settings | "None connected…" message | |

## 9. Video, sound, and display sleep

| ID | Steps | Expected | Status |
|---|---|---|---|
| VD-1 | Play a YouTube video full screen for 30 min | Smooth picture and sound. Mac display does **not** sleep | |
| VD-2 | Pause the video, wait past your display-sleep time | Display sleeps normally | |
| VD-3 | During VD-1, check with `pmset -g assertions` | Shows "Video is playing on the TV" | |
| VD-4 | Stop the TV during playback | Assertion goes away (check `pmset -g assertions`) | |
| VD-5 | Close the TV window while a video plays | Display sleeps normally once the TV window is closed or minimized (within 10 s) **[Fixed: retest]** | |
| VD-6 | Netflix, Prime Video, and a local player app | Same as VD-1. Apps that don't report playback won't keep the display awake | |
| VD-7 | Volume keys on the Mac vs TV volume | TV volume from the remote or a controller; Mac volume changes overall level | |

## 10. Screenshots and recordings

| ID | Steps | Expected | Status |
|---|---|---|---|
| SR-1 | ⇧⌘S | PNG on the Desktop, Finder shows it | |
| SR-2 | ⇧⌘S while in TV full screen | Saved to the Desktop. You stay in full screen (Finder does not open) **[Fixed: retest]** | |
| SR-3 | ⇧⌘R, wait 10 s, ⇧⌘R | MP4 on the Desktop plays | |
| SR-4 | Record more than 3 minutes | Stops at 3 minutes (Android limit). File saved | |
| SR-5 | Stop a recording and start a new one right away | Both recordings are saved **[Fixed: retest]** | |
| SR-6 | Quit while recording | The recording is saved to the Desktop before the app quits **[Fixed: retest]** | |
| SR-7 | Screenshot fails (TV off) | Menu item disabled | |

## 11. Settings

| ID | Steps | Expected | Status |
|---|---|---|---|
| ST-1 | Screen size 1080p ↔ 720p with the TV on | TV restarts at the new size | |
| ST-2 | Home app: install Projectivy, choose it | Home goes to Projectivy | |
| ST-3 | Choose Google TV again | Google TV home is back | |
| ST-4 | After ST-2, Uninstall Projectivy from the library | Google TV home is turned back on. Home works **[Fixed: retest]** | |
| ST-5 | Reset TV… ▸ Reset TV | Apps and accounts wiped. TV restarts to the setup screen | |
| ST-6 | Reset TV… ▸ Cancel | Nothing changes | |
| ST-7 | Error while the main window is closed (for example a home-app switch fails) | Error appears as an alert on the TV window, or on its own when no window is open **[Fixed: retest]** | |

## 12. Root (experimental)

| ID | Steps | Expected | Status |
|---|---|---|---|
| RT-1 | Turn on "Rooted TV", confirm | Progress inline, TV restarts, "Root works." | |
| RT-2 | Quit during patching, reopen | Stock image restored at launch. TV boots | |
| RT-3 | Block ads and trackers | Android restarts. Ads gone in a browser | |
| RT-4 | Update Block List | Updates without error | |
| RT-5 | Back Up Apps, Reset TV, Restore Backup… | Apps and their data return | |
| RT-6 | Turn root off | TV boots stock. "Root is off." | |
| RT-7 | Update the system image, open Settings ▸ Root | "Set Up Root Again" appears | |

## 13. Updates

| ID | Steps | Expected | Status |
|---|---|---|---|
| UP-1 | Older build, TVDroid ▸ Check for Updates… | "TVDroid X is available" with Download, Later, Skip | |
| UP-2 | Latest build, Check for Updates… | "TVDroid is up to date" with the version | |
| UP-3 | No internet, Check for Updates… | "Cannot check for updates" | |
| UP-4 | Skip This Version, relaunch next day | No alert for that version. A manual check still offers it | |
| UP-5 | Download | Browser downloads the DMG | |

## 14. Mac events

| ID | Steps | Expected | Status |
|---|---|---|---|
| MC-1 | TV on, close the lid for 10 min, open | Picture and input work again, or a clear error (unverified) | |
| MC-2 | TV on, switch Wi-Fi networks | TV internet works again. Remote needs a re-scan (see RM-9) | |
| MC-3 | Low battery / Low Power Mode during video | Plays. Note frame drops | |
| MC-4 | Run for 2 hours | No memory growth in Activity Monitor (TVDroid and qemu) | |
| MC-5 | Run `adb kill-server` in Terminal with the TV on | Input and picture recover, or a clear error (unverified: adb calls have no timeout, so the app can stay "busy" forever. `Shell.swift:58`) | |
| MC-6 | Fill the disk, then install an APK | Clear "not enough space" error | |
