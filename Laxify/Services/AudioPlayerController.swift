import Foundation
import AVFoundation
import MediaPlayer
import UIKit

@MainActor
@Observable
final class AudioPlayerController {
    static let shared = AudioPlayerController()

    private(set) var currentSong: Song?
    private(set) var queue: [Song] = []
    private(set) var currentIndex = 0
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var errorMessage: String?

    var hasNext: Bool { currentIndex + 1 < queue.count }
    var hasPrevious: Bool { currentIndex > 0 }

    private var player: AVPlayer?
    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?
    private let service: any MusicService

    private init(service: any MusicService = YandexMusicService.shared) {
        self.service = service
        configureAudioSession()
        configureRemoteCommands()
    }

    func play(_ song: Song, queue newQueue: [Song] = []) {
        queue = newQueue.isEmpty ? [song] : newQueue
        currentIndex = queue.firstIndex(where: { $0.id == song.id }) ?? 0
        loadAndPlayCurrent()
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
        updateNowPlayingPlaybackState()
    }

    func next() {
        guard hasNext else { return }
        currentIndex += 1
        loadAndPlayCurrent()
    }

    func previous() {
        guard hasPrevious else { return }
        currentIndex -= 1
        loadAndPlayCurrent()
    }

    func seek(to time: TimeInterval) {
        currentTime = time
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        updateNowPlayingElapsedTime()
    }

    private func loadAndPlayCurrent() {
        guard queue.indices.contains(currentIndex) else { return }
        let song = queue[currentIndex]
        currentSong = song
        currentTime = 0
        duration = song.duration
        isLoading = true
        errorMessage = nil
        teardownPlayer()

        Task {
            do {
                let url = try await service.streamURL(for: song.id)
                guard currentSong?.id == song.id else { return }

                let item = AVPlayerItem(url: url)
                let newPlayer = AVPlayer(playerItem: item)
                player = newPlayer
                attachObservers(to: item)
                newPlayer.play()
                isPlaying = true
                isLoading = false
                updateNowPlayingInfo()
            } catch {
                isLoading = false
                isPlaying = false
                errorMessage = "Не удалось воспроизвести трек"
            }
        }
    }

    private func attachObservers(to item: AVPlayerItem) {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserverToken = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                self?.currentTime = time.seconds
            }
        }

        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.handleDidFinishPlaying()
            }
        }
    }

    private func handleDidFinishPlaying() {
        if hasNext {
            next()
        } else {
            isPlaying = false
        }
    }

    private func teardownPlayer() {
        if let timeObserverToken {
            player?.removeTimeObserver(timeObserverToken)
        }
        timeObserverToken = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        player?.pause()
        player = nil
    }

    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                if !self.isPlaying, self.player != nil {
                    self.togglePlayPause()
                }
            }
            return .success
        }

        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                if self.isPlaying {
                    self.togglePlayPause()
                }
            }
            return .success
        }

        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                self.next()
            }
            return .success
        }

        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                self.previous()
            }
            return .success
        }

        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in
                self.seek(to: position)
            }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let currentSong else { return }
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: currentSong.title,
            MPMediaItemPropertyArtist: currentSong.artistName,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        guard let coverURL = currentSong.coverURL else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: coverURL),
                  let image = UIImage(data: data) else { return }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            var updatedInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? info
            updatedInfo[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = updatedInfo
        }
    }

    private func updateNowPlayingPlaybackState() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingElapsedTime() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
