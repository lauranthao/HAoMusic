import AVFoundation
import MediaPlayer

enum RepeatMode: String, CaseIterable, Codable {
    case off
    case all
    case one

    var label: String {
        switch self {
        case .off: return "顺序播放"
        case .all: return "全部循环"
        case .one: return "单曲循环"
        }
    }
}

/// AVPlayer 播放引擎：队列、随机、循环、进度、锁屏/控制中心切歌。
/// 与 AVPlayer 的交互都在主线程（@MainActor），不跨线程传 player。
/// 网络曲目在 play(at:) 里现解析：第一个能播的地址立刻播，播不了按解析管线走解锁。
@MainActor
final class PlayerService: ObservableObject {
    @Published private(set) var queue: [PlaybackItem] = []
    @Published private(set) var currentIndex: Int?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var shuffleEnabled = false
    @Published var repeatMode: RepeatMode = .off
    /// 正在解析播放地址的曲目 ID（UI 显示“正在解析…”）。
    @Published private(set) var resolvingTrackID: String?
    /// 最近一次手动点播失败的原因（UI 显示；下次播放时清掉）。
    @Published private(set) var resolveError: String?

    private let resolver: PlaybackResolver?
    private var resolveTask: Task<Void, Never>?

    var currentItem: PlaybackItem? {
        guard let currentIndex, queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    var hasCurrentItem: Bool { currentItem != nil }

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var shuffledOrder: [Int] = []
    private var shuffledPosition: Int = 0

    init(resolver: PlaybackResolver? = nil) {
        self.resolver = resolver
        configureAudioSession()
        installTimeObserver()
        installEndObserver()
        installRemoteCommands()
    }

    deinit {
        resolveTask?.cancel()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    // MARK: - 播放控制

    /// 每次播放都记 PlaySource；manual 表示用户手动点播（手动点播先清失败记忆，
    /// 播不了停在原地提示；自动切歌播不了直接跳下一首）。
    func play(tracks: [Track], startAt index: Int = 0, source: PlaySource = .unknown, manual: Bool = true) {
        queue = tracks.map { PlaybackItem(track: $0, playSource: source) }
        shuffledOrder = []
        shuffledPosition = 0
        play(at: index, manual: manual)
    }

    func play(track: Track, source: PlaySource = .unknown) {
        play(tracks: [track], startAt: 0, source: source, manual: true)
    }

    func play(at index: Int, manual: Bool = true) {
        resolveTask?.cancel()
        resolveTask = nil
        resolvingTrackID = nil
        resolveError = nil
        guard queue.indices.contains(index) else { return }
        currentIndex = index
        currentTime = 0
        duration = 0
        if let url = queue[index].playURL {
            startPlayback(url: url)
            return
        }
        guard queue[index].needsResolution, let resolver else {
            // 没有可播地址、没有解析器：跳下一首
            advanceToNextAfterUnplayable()
            return
        }
        // 网络曲目：现解析。解析是异步的，切歌/停止会取消本次解析。
        resolvingTrackID = queue[index].id
        let itemID = queue[index].id
        let track = queue[index].track
        resolveTask = Task {
            let resolution = await resolver.resolve(track: track, manual: manual)
            guard !Task.isCancelled else { return }
            self.resolveTask = nil
            guard self.currentIndex == index,
                  self.queue.indices.contains(index),
                  self.queue[index].id == itemID else { return }
            self.resolvingTrackID = nil
            switch resolution {
            case let .ready(url, quality, source):
                self.queue[index].resolvedURL = url
                self.queue[index].resolvedQuality = quality
                self.queue[index].resolvedSource = source
                self.startPlayback(url: url)
            case let .unplayable(reason):
                if manual {
                    // 手动点播不了：停在原地，播放页显示原因，不自动跳歌。
                    self.resolveError = reason
                } else {
                    self.advanceToNextAfterUnplayable()
                }
            }
        }
    }

    private func startPlayback(url: URL) {
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        player.play()
        isPlaying = true
        updateNowPlayingInfo()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { resume() }
    }

    func pause() {
        player.pause()
        isPlaying = false
        updateNowPlayingElapsedTime()
    }

    func resume() {
        guard currentItem != nil else { return }
        player.play()
        isPlaying = true
        updateNowPlayingElapsedTime()
    }

    func stop() {
        resolveTask?.cancel()
        resolveTask = nil
        resolvingTrackID = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        currentTime = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func next(manual: Bool = true) {
        guard let currentIndex else { return }
        if shuffleEnabled {
            playNextShuffled(manual: manual)
            return
        }
        let nextIndex = currentIndex + 1
        if queue.indices.contains(nextIndex) {
            play(at: nextIndex, manual: manual)
        } else if repeatMode == .all {
            play(at: 0, manual: manual)
        } else {
            stop()
        }
    }

    func previous(manual: Bool = true) {
        guard let currentIndex else { return }
        // 播放超过 3 秒：回到开头；否则上一首
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        let prevIndex = currentIndex - 1
        if queue.indices.contains(prevIndex) {
            play(at: prevIndex, manual: manual)
        } else {
            seek(to: 0)
        }
    }

    func seek(to seconds: Double) {
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: target)
        currentTime = max(0, seconds)
        updateNowPlayingElapsedTime()
    }

    func toggleShuffle() {
        shuffleEnabled.toggle()
        shuffledOrder = []
        shuffledPosition = 0
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    // MARK: - 内部

    private func advanceToNextAfterUnplayable() {
        guard let currentIndex else { return }
        let next = currentIndex + 1
        if queue.indices.contains(next) {
            play(at: next, manual: false)
        } else {
            stop()
        }
    }

    private func handleTrackEnded() {
        if repeatMode == .one {
            seek(to: 0)
            player.play()
            isPlaying = true
            return
        }
        next(manual: false)
    }

    private func playNextShuffled(manual: Bool = true) {
        if shuffledOrder.isEmpty {
            shuffledOrder = Array(queue.indices).shuffled()
            if let currentIndex {
                shuffledOrder.removeAll { $0 == currentIndex }
            }
            shuffledPosition = 0
        }
        if shuffledPosition < shuffledOrder.count {
            let index = shuffledOrder[shuffledPosition]
            shuffledPosition += 1
            play(at: index, manual: manual)
        } else if repeatMode == .all {
            shuffledOrder = []
            next(manual: manual)
        } else {
            stop()
        }
    }

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // 后台播放失败不致命：前台仍可播放
            print("[PlayerService] audio session failed: \(error)")
        }
    }

    private func installTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.currentTime = time.seconds
                if let itemDuration = self.player.currentItem?.duration.seconds,
                   itemDuration.isFinite, itemDuration > 0 {
                    self.duration = itemDuration
                }
                self.updateNowPlayingElapsedTime()
            }
        }
    }

    private func installEndObserver() {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard let ended = note.object as? AVPlayerItem,
                      ended == self.player.currentItem else { return }
                self.handleTrackEnded()
            }
        }
    }

    // MARK: - 锁屏 / 控制中心（状态栏切歌走这里）

    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true

        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            MainActor.assumeIsolated { self.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            MainActor.assumeIsolated { self.pause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            MainActor.assumeIsolated { self.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            MainActor.assumeIsolated { self.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self,
                  let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self.seek(to: event.positionTime) }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let track = currentItem?.track else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingElapsedTime() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
