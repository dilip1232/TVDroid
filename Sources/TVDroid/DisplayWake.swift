import Foundation
import IOKit.pwr_mgt
import os

/// The last input to the TV: keys, mouse, touch, controllers and the phone remote.
/// Times are system uptime, which stops while the Mac sleeps: a night with the lid closed is no unused time.
enum TVActivity {
    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    static let lastInput = OSAllocatedUnfairLock(initialState: ProcessInfo.processInfo.systemUptime)
    static func touch() { lastInput.withLock { $0 = now } }
}

/// Keeps the Mac display awake while a video plays on the TV, like a video player does.
/// When the video pauses or stops, or the TV window is closed, the Mac sleeps on its normal timer again.
/// It also calls `onIdle` when the TV had no input and no video for the time in Settings (battery saver).
@MainActor
final class DisplayWake {
    static let shared = DisplayWake()

    private static let interval: Duration = .seconds(10)
    private var task: Task<Void, Never>?
    private var assertion: IOPMAssertionID = 0
    private var lastPlaying = TVActivity.now
    /// The TV was not used for `Prefs.idleTurnOffMinutes`. TVController turns it off.
    var onIdle: (() -> Void)?

    private init() {}

    /// Only check while the TV runs. Otherwise each check would try to start adb.
    var isTVOn = false {
        didSet {
            guard isTVOn != oldValue else { return }
            task?.cancel()
            task = nil
            if isTVOn {
                lastPlaying = TVActivity.now
                TVActivity.touch()
                task = Task { [weak self] in
                    while !Task.isCancelled {
                        let playing = await Self.isPlaying()
                        guard !Task.isCancelled else { return }
                        // Sound with a closed TV window needs no screen.
                        self?.setAwake(playing && TVWindowController.shared.isShown)
                        self?.checkIdle(playing: playing)
                        try? await Task.sleep(for: Self.interval)
                    }
                }
            } else {
                setAwake(false)
            }
        }
    }

    /// True when an app on the TV reports a playing media session (YouTube, Netflix and most video apps do).
    /// Android 13 and later print "state=PLAYING(3)", older versions print "state=3,".
    private nonisolated static func isPlaying() async -> Bool {
        let result = await Shell.run(Tools.adb, ["-s", TVController.serial, "shell",
                                                 "dumpsys media_session | grep -E 'PlaybackState \\{state=(3,|PLAYING)'"],
                                     timeout: 8)
        return result.ok && !result.output.isEmpty
    }

    private func checkIdle(playing: Bool) {
        let now = TVActivity.now
        if playing { lastPlaying = now }
        let minutes = Prefs.idleTurnOffMinutes
        guard minutes > 0 else { return }
        let lastUse = max(lastPlaying, TVActivity.lastInput.withLock { $0 })
        if now - lastUse > TimeInterval(minutes * 60) {
            // Count again from now, so a TV that stays on (busy, recording) is not asked every 10 s.
            lastPlaying = now
            onIdle?()
        }
    }

    private func setAwake(_ awake: Bool) {
        if awake, assertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Video is playing on the TV" as CFString, &assertion)
        } else if !awake, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }
}
