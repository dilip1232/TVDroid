import MediaPlayer

/// The Mac media keys (and the Now Playing controls) control the TV while its window is in front.
/// Volume keys stay with the Mac: macOS gives them to no app.
@MainActor
final class MediaKeys {
    static let shared = MediaKeys()

    private var registered = false

    private init() {}

    /// Call when the TV window becomes the key window (true) and when it stops being it (false).
    func setActive(_ active: Bool) {
        if !registered { register() }
        let info = MPNowPlayingInfoCenter.default()
        if active {
            info.nowPlayingInfo = [MPMediaItemPropertyTitle: "TVDroid TV"]
            info.playbackState = .playing
        } else {
            info.nowPlayingInfo = nil
            info.playbackState = .stopped
        }
    }

    private func register() {
        registered = true
        let center = MPRemoteCommandCenter.shared()
        let keys: [(MPRemoteCommand, EmulatorConsole.Key)] = [
            (center.togglePlayPauseCommand, .playpause), (center.playCommand, .play), (center.pauseCommand, .pause),
            (center.nextTrackCommand, .next), (center.previousTrackCommand, .previous),
            (center.skipForwardCommand, .forward), (center.skipBackwardCommand, .rewind),
        ]
        for (command, key) in keys {
            command.isEnabled = true
            command.addTarget { _ in
                // Without a TV, a key would only try to start adb.
                guard RemoteServer.isTVOn.withLock({ $0 }) else { return .noActionableNowPlayingItem }
                EmulatorConsole.shared.press(key)
                return .success
            }
        }
    }
}
