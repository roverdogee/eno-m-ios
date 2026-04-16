import AVFoundation
import Foundation
import MediaPlayer
import UIKit

enum NativeAudioError: LocalizedError {
    case invalidURL
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid audio URL"
        case .downloadFailed(let message):
            return message
        }
    }
}

final class NativeAudioPlayer {
    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var statusObserver: NSKeyValueObservation?
    private var timeControlObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var periodicTimeObserver: Any?
    private var currentTitle = ""
    private var currentArtist = ""
    private var currentArtwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?
    private var downloadedAudioURL: URL?
    private let sendEvent: (String, [String: Any]) -> Void

    init(sendEvent: @escaping (String, [String: Any]) -> Void = { _, _ in }) {
        self.sendEvent = sendEvent
        configureRemoteCommands()
    }

    func play(url: String, title: String?, artist: String?, artworkURL: String?, cookie: String = "") async throws -> Any {
        guard let audioURL = URL(string: url) else {
            throw NativeAudioError.invalidURL
        }

        artworkTask?.cancel()
        artworkTask = nil
        currentArtwork = nil
        cleanupObservers()
        player?.pause()
        player = nil
        playerItem = nil
        removeDownloadedAudio()
        currentTitle = title ?? ""
        currentArtist = artist ?? ""
        loadArtwork(from: artworkURL)
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        try AVAudioSession.sharedInstance().setActive(true)

        sendState("loading", message: "正在下载音频...")
        let localURL = try await downloadAudio(from: audioURL, cookie: cookie)
        downloadedAudioURL = localURL

        let item = AVPlayerItem(url: localURL)
        let player = AVPlayer(playerItem: item)
        self.playerItem = item
        self.player = player
        observe(item: item, player: player)
        updateNowPlaying(playbackRate: 1)
        sendState("loading")
        player.play()

        return [
            "success": true,
            "title": title ?? "",
            "artist": artist ?? ""
        ]
    }

    func pause() -> Any {
        player?.pause()
        updateNowPlaying(playbackRate: 0)
        sendState("paused")
        return ["success": true]
    }

    func resume() -> Any {
        player?.play()
        updateNowPlaying(playbackRate: 1)
        sendState("playing")
        return ["success": true]
    }

    func stop() -> Any {
        player?.pause()
        cleanupObservers()
        player = nil
        playerItem = nil
        artworkTask?.cancel()
        artworkTask = nil
        currentArtwork = nil
        removeDownloadedAudio()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        sendState("stopped")
        return ["success": true]
    }

    func seek(seconds: Double) -> Any {
        guard let player else {
            return ["success": false]
        }

        let safeSeconds = max(0, seconds)
        let time = CMTime(seconds: safeSeconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                self?.sendProgress()
                self?.updateNowPlaying(playbackRate: player.rate)
            }
        }

        return ["success": true, "position": safeSeconds]
    }

    private func observe(item: AVPlayerItem, player: AVPlayer) {
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                switch item.status {
                case .readyToPlay:
                    self?.updateNowPlaying(playbackRate: player.rate)
                    self?.sendProgress()
                    self?.sendState("ready")
                case .failed:
                    self?.sendState("failed", message: self?.failureMessage(for: item) ?? "播放失败")
                case .unknown:
                    self?.sendState("loading")
                @unknown default:
                    self?.sendState("unknown")
                }
            }
        }

        timeControlObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            DispatchQueue.main.async {
                switch player.timeControlStatus {
                case .paused:
                    self?.updateNowPlaying(playbackRate: 0)
                    self?.sendState("paused")
                case .waitingToPlayAtSpecifiedRate:
                    self?.sendState("buffering")
                case .playing:
                    self?.updateNowPlaying(playbackRate: 1)
                    self?.sendState("playing")
                @unknown default:
                    self?.sendState("unknown")
                }
            }
        }

        periodicTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            self?.sendProgress()
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.updateNowPlaying(playbackRate: 0)
            self?.sendState("ended")
        }
    }

    private func failureMessage(for item: AVPlayerItem) -> String {
        var messages: [String] = []
        if let error = item.error {
            messages.append(error.localizedDescription)
        }

        if let events = item.errorLog()?.events, let event = events.last {
            if let comment = event.errorComment, !comment.isEmpty {
                messages.append(comment)
            }
            if event.errorStatusCode != 0 {
                messages.append("HTTP \(event.errorStatusCode)")
            }
        }

        return messages.isEmpty ? "播放失败" : messages.joined(separator: " · ")
    }

    private func cleanupObservers() {
        statusObserver?.invalidate()
        statusObserver = nil
        timeControlObserver?.invalidate()
        timeControlObserver = nil

        if let periodicTimeObserver, let player {
            player.removeTimeObserver(periodicTimeObserver)
            self.periodicTimeObserver = nil
        }

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    private func downloadAudio(from audioURL: URL, cookie: String) async throws -> URL {
        var request = URLRequest(url: audioURL)
        request.timeoutInterval = 30
        for (key, value) in playbackHeaders(cookie: cookie) {
            request.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let (temporaryURL, response) = try await URLSession.shared.download(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                throw NativeAudioError.downloadFailed("音频下载失败 HTTP \(httpResponse.statusCode)")
            }

            let targetURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("eno-audio-\(UUID().uuidString)")
                .appendingPathExtension("m4a")
            try FileManager.default.moveItem(at: temporaryURL, to: targetURL)
            return targetURL
        } catch let error as NativeAudioError {
            throw error
        } catch {
            throw NativeAudioError.downloadFailed("音频下载失败：\(error.localizedDescription)")
        }
    }

    private func playbackHeaders(cookie: String) -> [String: String] {
        var headers = [
            "Referer": "https://www.bilibili.com/",
            "Origin": "https://www.bilibili.com",
            "Accept": "*/*",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        ]
        if !cookie.isEmpty {
            headers["Cookie"] = cookie
        }
        return headers
    }

    private func loadArtwork(from artworkURL: String?) {
        guard let artworkURL, !artworkURL.isEmpty, let url = URL(string: artworkURL) else {
            return
        }

        artworkTask = Task { [weak self] in
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 20
                for (key, value) in self?.playbackHeaders(cookie: "") ?? [:] {
                    request.setValue(value, forHTTPHeaderField: key)
                }

                let (data, response) = try await URLSession.shared.data(for: request)
                guard !Task.isCancelled,
                      let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode),
                      let image = UIImage(data: data)
                else {
                    return
                }

                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                await MainActor.run { [weak self] in
                    let rate = self?.player?.rate ?? 0
                    self?.currentArtwork = artwork
                    self?.updateNowPlaying(playbackRate: rate)
                }
            } catch {
                return
            }
        }
    }

    private func removeDownloadedAudio() {
        guard let downloadedAudioURL else {
            return
        }

        try? FileManager.default.removeItem(at: downloadedAudioURL)
        self.downloadedAudioURL = nil
    }

    private func sendState(_ state: String, message: String = "") {
        sendEvent("native-audio-state", [
            "state": state,
            "title": currentTitle,
            "artist": currentArtist,
            "message": message,
            "position": player?.currentTime().seconds ?? 0,
            "duration": playerItem?.duration.seconds.isFinite == true ? playerItem?.duration.seconds ?? 0 : 0
        ])
    }

    private func sendProgress() {
        let position = player?.currentTime().seconds ?? 0
        let duration = playerItem?.duration.seconds ?? 0
        sendEvent("native-audio-progress", [
            "position": position.isFinite ? position : 0,
            "duration": duration.isFinite ? duration : 0,
            "isPlaying": (player?.rate ?? 0) > 0
        ])
    }

    private func updateNowPlaying(playbackRate: Float) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentTitle,
            MPMediaItemPropertyArtist: currentArtist,
            MPNowPlayingInfoPropertyPlaybackRate: playbackRate,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player?.currentTime().seconds ?? 0
        ]

        if let duration = playerItem?.duration.seconds, duration.isFinite {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }

        if let currentArtwork {
            info[MPMediaItemPropertyArtwork] = currentArtwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            self?.player?.play()
            self?.updateNowPlaying(playbackRate: 1)
            self?.sendState("playing")
            return .success
        }

        center.pauseCommand.addTarget { [weak self] _ in
            self?.player?.pause()
            self?.updateNowPlaying(playbackRate: 0)
            self?.sendState("paused")
            return .success
        }

        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, let player = self.player else {
                return .commandFailed
            }

            if player.rate == 0 {
                player.play()
                self.updateNowPlaying(playbackRate: 1)
                self.sendState("playing")
            } else {
                player.pause()
                self.updateNowPlaying(playbackRate: 0)
                self.sendState("paused")
            }
            return .success
        }

        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.sendEvent("native-audio-command", ["command": "next"])
            return .success
        }

        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.sendEvent("native-audio-command", ["command": "previous"])
            return .success
        }
    }

    deinit {
        artworkTask?.cancel()
        cleanupObservers()
        removeDownloadedAudio()
    }
}
