import Foundation
import AppKit
import Combine
import UserNotifications
import ServiceManagement

final class DownloadStore: ObservableObject {
    static let shared = DownloadStore()

    static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    @Published var downloads: [DownloadItem] = []
    @Published var sleepTimerEnd: Date?
    @Published var detectedMedia: [DetectedMedia] = []

    private let http = HTTPDownloadManager()
    private let media = MediaDownloadManager()
    private let youtube = YouTubeManager()
    let engines = EngineManager.shared
    private let dashClient = DASHClient()
    private var cancellables = Set<AnyCancellable>()
    private var sleepTimer: Timer?
    private var sleepProcess: Process?
    private var pendingYouTubeListings = Set<String>()

    var activeCount: Int {
        downloads.filter { $0.status == .downloading || $0.status == .queued || $0.status == .seeding }.count
    }

    var downloadDirectory: URL {
        get {
            if let path = UserDefaults.standard.string(forKey: "downloadDirectory"), !path.isEmpty {
                let url = URL(fileURLWithPath: path)
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                return url
            }
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        }
        set {
            UserDefaults.standard.set(newValue.path, forKey: "downloadDirectory")
            http.downloadDirectory = newValue
            let liveTorrents = downloads.contains {
                ($0.kind == .torrent || $0.kind == .magnet)
                    && ($0.status == .downloading || $0.status == .queued
                        || $0.status == .seeding || $0.status == .paused)
            }
            if !liveTorrents {
                // The torrent daemon's --dir is fixed at launch; restart it
                // so local torrent files land in the new folder too.
                if engines.torrentEnabled {
                    TorrentEngine.shared.restart(downloadDir: newValue)
                }
            }
        }
    }

    var maxConcurrentHTTP: Int {
        get {
            UserDefaults.standard.object(forKey: "maxConcurrentHTTP") as? Int ?? 3
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "maxConcurrentHTTP")
            startNextQueuedHTTP()
        }
    }

    var notificationsEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "notificationsEnabled")
        }
    }

    var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    var defaultUserAgent: String {
        get {
            UserDefaults.standard.string(forKey: "defaultUserAgent") ?? Self.browserUserAgent
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "defaultUserAgent")
        }
    }

    var controlPort: UInt16 {
        get {
            let saved = UserDefaults.standard.integer(forKey: "controlPort")
            return saved > 0 ? UInt16(saved) : 8765
        }
        set {
            UserDefaults.standard.set(Int(newValue), forKey: "controlPort")
            startControlServer()
        }
    }

    private init() {
        http.delegate = self
        http.downloadDirectory = downloadDirectory
        http.fallbackName = { [weak self] id in
            self?.downloads.first { $0.id == id }?.title
        }
        http.explicitFilename = { [weak self] id in
            self?.downloads.first { $0.id == id }?.explicitFilename
        }
        http.absoluteDestination = { [weak self] id in
            self?.downloads.first { $0.id == id }?.absoluteDestination
        }
        http.partialFileURL = { [weak self] id in
            guard let path = self?.downloads.first(where: { $0.id == id })?.partialFilePath else { return nil }
            return URL(fileURLWithPath: path)
        }
        http.partialFileChanged = { [weak self] id, url in
            guard let self, let idx = self.index(of: id) else { return }
            self.downloads[idx].partialFilePath = url?.path
            self.save()
        }
        media.delegate = self
        media.downloadDirectory = downloadDirectory
        media.fallbackName = { [weak self] id in
            self?.downloads.first { $0.id == id }?.title
        }
        media.mediaMode = { [weak self] id in
            self?.downloads.first { $0.id == id }?.mediaMode
        }
        media.mediaURLs = { [weak self] id in
            self?.downloads.first { $0.id == id }?.mediaURLs
        }
        media.mediaHeaders = { [weak self] id in
            self?.downloads.first { $0.id == id }?.mediaHeaders
        }
        youtube.delegate = self
        youtube.downloadDirectory = downloadDirectory
        media.mediaLabel = { [weak self] id in
            self?.downloads.first { $0.id == id }?.mediaLabel
        }
        LocalControlServer.shared.handler = { [weak self] path, body in
            self?.handleControlRequest(path, body: body) ?? ["ok": false, "error": "App not ready"]
        }
        load()
        TorrentEngine.shared.$snapshots
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.mergeTorrentSnapshots()
            }
            .store(in: &cancellables)
        requestNotificationPermissionIfNeeded()
        restoreTorrentsIfNeeded()
        startControlServer()
        // On-demand engines: only start the torrent daemon when the feature is
        // enabled (fetching the binary first if needed).
        if engines.torrentEnabled {
            engines.ensure(.aria2) { [weak self] state in
                guard case .ready = state else { return }
                DispatchQueue.main.async {
                    TorrentEngine.shared.ensureRunning(downloadDir: self?.downloadDirectory ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]) { _ in }
                }
            }
        }
        if engines.mediaEnabled {
            engines.ensure(.ytdlp) { _ in }
            engines.ensure(.ffmpeg) { _ in }
        }
    }

    // MARK: - On-demand engines

    func setTorrentEngineEnabled(_ enabled: Bool) {
        engines.setTorrentEnabled(enabled)
        if enabled {
            engines.ensure(.aria2) { [weak self] state in
                guard case .ready = state else { return }
                DispatchQueue.main.async {
                    TorrentEngine.shared.ensureRunning(downloadDir: self?.downloadDirectory ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]) { _ in }
                }
            }
        } else {
            TorrentEngine.shared.shutdown()
        }
    }

    func setMediaEngineEnabled(_ enabled: Bool) {
        engines.setMediaEnabled(enabled)
        if enabled {
            engines.ensure(.ytdlp) { _ in }
            engines.ensure(.ffmpeg) { _ in }
        }
    }

    // MARK: - Adding downloads

    @discardableResult
    func addURLString(_ raw: String) -> Bool {
        addDownload(urlString: raw, headers: nil, suggestedTitle: nil, absolutePath: nil)
    }

    @discardableResult
    func addDownload(
        urlString raw: String,
        headers: [String: String]?,
        suggestedTitle: String?,
        absolutePath: String?
    ) -> Bool {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        let lower = text.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") && !lower.hasPrefix("ftp://") && !lower.hasPrefix("magnet:") {
            text = "https://" + text
        }
        guard let url = URL(string: text) ?? URL(string: text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text) else {
            return false
        }

        let lowered = text.lowercased()
        let kind: DownloadKind
        if lowered.hasPrefix("magnet:") {
            kind = .magnet
        } else if url.pathExtension.lowercased() == "torrent" {
            kind = .torrent
        } else {
            kind = .http
        }

        var title: String
        switch kind {
        case .magnet:
            title = magnetDisplayName(url.absoluteString) ?? "Magnet link"
        case .torrent:
            title = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        case .http:
            let last = url.lastPathComponent.removingPercentEncoding ?? ""
            title = last.isEmpty ? (url.host ?? "Download") : last
        case .media:
            title = url.lastPathComponent.removingPercentEncoding ?? "Media"
        }

        if let absolutePath, !absolutePath.isEmpty, kind == .http {
            title = URL(fileURLWithPath: absolutePath).lastPathComponent
        } else if let suggestedTitle, !suggestedTitle.isEmpty, kind == .http {
            title = suggestedTitle
        }

        var effectiveHeaders: [String: String]?
        if kind == .http {
            var merged = headers ?? [:]
            if merged["User-Agent"] == nil, !defaultUserAgent.isEmpty {
                merged["User-Agent"] = defaultUserAgent
            }
            effectiveHeaders = merged.isEmpty ? nil : merged
        }

        let item = DownloadItem(
            kind: kind,
            url: url,
            title: title.isEmpty ? "Download" : title,
            httpHeaders: effectiveHeaders,
            explicitFilename: suggestedTitle,
            absoluteDestination: (kind == .http ? absolutePath : nil)
        )
        downloads.insert(item, at: 0)
        save()
        start(item)
        return true
    }

    func addTorrentFile(_ fileURL: URL) {
        let title = fileURL.lastPathComponent
        let item = DownloadItem(
            kind: .torrent,
            url: fileURL,
            torrentFilePath: fileURL.path,
            title: title
        )
        downloads.insert(item, at: 0)
        save()
        start(item)
    }

    // MARK: - Start / pause / resume / remove

    func start(_ item: DownloadItem) {
        guard let idx = index(of: item.id) else { return }
        switch item.kind {
        case .http:
            if activeHTTPCount < maxConcurrentHTTP {
                downloads[idx].status = .downloading
                save()
                guard let url = item.url else {
                    downloads[idx].status = .failed
                    downloads[idx].errorMessage = "Invalid URL"
                    save()
                    return
                }
                http.start(id: item.id, url: url, headers: item.httpHeaders)
            } else {
                downloads[idx].status = .queued
                save()
            }
        case .torrent, .magnet:
            downloads[idx].status = .queued
            save()
            reAddTorrent(item)
        case .media:
            downloads[idx].status = .downloading
            save()
            guard let mode = item.mediaMode, let urls = item.mediaURLs else {
                downloads[idx].status = .failed
                downloads[idx].errorMessage = "Invalid media stream"
                save()
                return
            }
            if mode == "youtube" {
                youtube.start(
                    id: item.id,
                    videoId: urls.first ?? "",
                    formatSpec: item.mediaLabel ?? "b",
                    browser: item.mediaHeaders?["Browser"] ?? "brave"
                )
            } else {
                media.start(id: item.id, urls: urls, mode: mode, headers: item.mediaHeaders)
            }
        }
    }

    func pause(_ item: DownloadItem) {
        guard let idx = index(of: item.id) else { return }
        switch item.kind {
        case .http:
            http.pause(id: item.id)
            downloads[idx].status = .paused
            downloads[idx].speed = 0
            downloads[idx].eta = nil
            save()
            startNextQueuedHTTP()
        case .torrent, .magnet:
            if let gid = item.ariaGID {
                TorrentEngine.shared.pause(gid)
                downloads[idx].status = .paused
                downloads[idx].speed = 0
                downloads[idx].eta = nil
                save()
            }
        case .media:
            // Media assembly can't be paused mid-flight; cancel instead.
            break
        }
    }

    func resume(_ item: DownloadItem) {
        guard let idx = index(of: item.id) else { return }
        switch item.kind {
        case .http:
            if activeHTTPCount < maxConcurrentHTTP {
                downloads[idx].status = .downloading
                save()
                guard let url = item.url else { return }
                http.start(id: item.id, url: url, headers: item.httpHeaders)
            } else {
                downloads[idx].status = .queued
                save()
            }
        case .torrent, .magnet:
            if let gid = item.ariaGID {
                TorrentEngine.shared.unpause(gid)
                TorrentEngine.shared.startPolling()
                downloads[idx].status = .downloading
                save()
            } else {
                downloads[idx].status = .queued
                save()
                reAddTorrent(item)
            }
        case .media:
            downloads[idx].status = .downloading
            save()
            guard let mode = item.mediaMode, let urls = item.mediaURLs else { return }
            if mode == "youtube" {
                youtube.start(
                    id: item.id,
                    videoId: urls.first ?? "",
                    formatSpec: item.mediaLabel ?? "b",
                    browser: item.mediaHeaders?["Browser"] ?? "brave"
                )
            } else {
                media.start(id: item.id, urls: urls, mode: mode, headers: item.mediaHeaders)
            }
        }
    }

    func remove(_ item: DownloadItem) {
        http.cancel(id: item.id)
        if item.kind == .media {
            media.cancel(id: item.id)
            youtube.cancel(id: item.id)
        }
        if let gid = item.ariaGID {
            TorrentEngine.shared.remove(gid)
        }
        deleteResumeData(for: item.id)
        if let partialPath = item.partialFilePath {
            try? FileManager.default.removeItem(atPath: partialPath)
        }
        downloads.removeAll { $0.id == item.id }
        save()
        startNextQueuedHTTP()
    }

    func clearCompleted() {
        downloads.removeAll { $0.status == .completed || $0.status == .failed || $0.status == .removed }
        save()
    }

    func reveal(_ item: DownloadItem) {
        if let dest = item.destinationURL, FileManager.default.fileExists(atPath: dest.path) {
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } else {
            NSWorkspace.shared.open(downloadDirectory)
        }
    }

    func open(_ item: DownloadItem) {
        guard let dest = item.destinationURL,
              FileManager.default.fileExists(atPath: dest.path) else {
            return
        }
        NSWorkspace.shared.open(dest)
    }

    func openDownloadFolder() {
        NSWorkspace.shared.open(downloadDirectory)
    }

    // MARK: - Torrent extras (context menu)

    func updateTrackers(_ item: DownloadItem) {
        guard let gid = item.ariaGID else { return }
        TorrentEngine.shared.updateTrackers(gid: gid) { [weak self] ok, message in
            DispatchQueue.main.async {
                self?.notify(
                    title: ok ? "Trackers updated" : "Trackers update failed",
                    body: message
                )
            }
        }
    }

    func removeWithFiles(_ item: DownloadItem) {
        guard let gid = item.ariaGID else {
            remove(item)
            return
        }
        TorrentEngine.shared.filePaths(gid: gid) { [weak self] paths in
            DispatchQueue.main.async {
                guard let self else { return }
                self.remove(item)
                let fm = FileManager.default
                for path in paths where !path.isEmpty {
                    try? fm.removeItem(atPath: path)
                }
                self.removeEmptyParents(of: paths, stopAt: self.downloadDirectory.path)
            }
        }
    }

    func copyMagnet(_ item: DownloadItem) {
        var magnet: String?
        if let url = item.url, url.scheme?.lowercased() == "magnet" {
            magnet = url.absoluteString
        } else if let hash = item.infoHash, !hash.isEmpty {
            let dn = item.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? item.title
            magnet = "magnet:?xt=urn:btih:\(hash)&dn=\(dn)"
        }
        guard let magnet else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(magnet, forType: .string)
    }

    func copyInfoHash(_ item: DownloadItem) {
        guard let hash = item.infoHash, !hash.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(hash, forType: .string)
    }

    // MARK: - Video grab (detected streams)

    func downloadMedia(_ stream: DetectedMediaStream) {
        let kind = stream.kind ?? "direct"
        if kind == "hls" || kind == "dash" || kind == "youtube" {
            if (kind == "hls" || kind == "dash"), !engines.mediaEnabled {
                return // video grab is disabled
            }
            if kind == "youtube", stream.formatId == nil {
                return // formats still loading
            }
            addMediaStream(stream)
            return
        }
        var headers: [String: String] = [:]
        if let ua = stream.userAgent, !ua.isEmpty {
            headers["User-Agent"] = ua
        }
        if let referer = stream.referer, !referer.isEmpty {
            headers["Referer"] = referer
        }
        if let cookies = stream.cookies, !cookies.isEmpty {
            headers["Cookie"] = cookies
        }
        if let captured = stream.headers {
            for (key, value) in captured where headers[key] == nil {
                headers[key] = value
            }
        }
        _ = addDownload(
            urlString: stream.url,
            headers: headers.isEmpty ? nil : headers,
            suggestedTitle: nil,
            absolutePath: nil
        )
        removeMedia(stream.id)
    }

    @discardableResult
    func addMediaStream(_ stream: DetectedMediaStream) -> Bool {
        guard let url = URL(string: stream.url) else { return false }
        var headers: [String: String] = [:]
        if let ua = stream.userAgent, !ua.isEmpty {
            headers["User-Agent"] = ua
        }
        if let referer = stream.referer, !referer.isEmpty {
            headers["Referer"] = referer
        }
        if let cookies = stream.cookies, !cookies.isEmpty {
            headers["Cookie"] = cookies
        }
        if let captured = stream.headers {
            for (key, value) in captured where headers[key] == nil {
                headers[key] = value
            }
        }
        if stream.kind == "youtube" {
            headers["Browser"] = stream.browser ?? "brave"
        }
        var title = url.lastPathComponent
        if title.isEmpty {
            title = "\(stream.displayLabel) video.mp4"
        } else if title.lowercased().hasSuffix(".mpd") || title.lowercased().hasSuffix(".m3u8") {
            title = String(title.dropLast(5)) + ".mp4"
        }
        if stream.kind == "youtube" {
            title = "YouTube — \(stream.displayLabel)"
        }
        let item = DownloadItem(
            kind: .media,
            url: url,
            title: title,
            mediaMode: stream.kind == "hls" ? "hls" : (stream.kind == "youtube" ? "youtube" : "dash"),
            mediaURLs: stream.kind == "youtube"
                ? [YouTubeManager.videoId(from: stream.url) ?? url.lastPathComponent]
                : [stream.url],
            mediaHeaders: headers.isEmpty ? nil : headers,
            mediaLabel: stream.kind == "youtube"
                ? (stream.formatId ?? stream.label ?? "b")
                : stream.label
        )
        downloads.insert(item, at: 0)
        save()
        start(item)
        removeMedia(stream.id)
        return true
    }

    func removeMedia(_ id: UUID) {
        for idx in detectedMedia.indices {
            detectedMedia[idx].streams.removeAll { $0.id == id }
        }
        detectedMedia.removeAll { $0.streams.isEmpty }
    }

    func clearMedia() {
        detectedMedia = []
    }

    private func removeEmptyParents(of paths: [String], stopAt: String) {
        guard let first = paths.first, !first.isEmpty else { return }
        let stop = URL(fileURLWithPath: stopAt).standardizedFileURL
        var dir = URL(fileURLWithPath: first).deletingLastPathComponent()
        while dir.standardizedFileURL != stop {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            if contents.isEmpty {
                try? FileManager.default.removeItem(at: dir)
            } else {
                break
            }
            let parent = dir.deletingLastPathComponent()
            guard parent.path != dir.path else { break }
            dir = parent
        }
    }

    // MARK: - Prevent sleep (like caffeinate)

    func setSleepTimer(minutes: Int?) {
        sleepTimer?.invalidate()
        sleepTimer = nil
        stopCaffeinate()
        guard let minutes, minutes > 0 else {
            sleepTimerEnd = nil
            return
        }

        // Keep the system awake (same mechanism as `caffeinate -t`).
        startCaffeinate(seconds: minutes * 60)
        let end = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTimerEnd = end
        // Poll every second and fire when the end time is reached. A single
        // one-shot work item is unreliable here: App Nap / timer throttling
        // can delay it past the deadline, leaving the countdown stuck at 0.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkSleepTimer()
        }
        // `.common` keeps the timer firing while a menu or the popover is
        // tracking, not just in the default run loop mode.
        RunLoop.main.add(timer, forMode: .common)
        sleepTimer = timer
    }

    private func checkSleepTimer() {
        guard let end = sleepTimerEnd else {
            sleepTimer?.invalidate()
            sleepTimer = nil
            return
        }
        if Date() >= end {
            sleepTimerFired()
        }
    }

    private func sleepTimerFired() {
        guard sleepTimerEnd != nil else { return }
        sleepTimerEnd = nil
        sleepTimer?.invalidate()
        sleepTimer = nil
        stopCaffeinate()
        notify(title: "Prevent sleep ended", body: "Your Mac can sleep again.")
    }

    private func startCaffeinate(seconds: Int) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-t", "\(seconds)"]
        do {
            try process.run()
            sleepProcess = process
        } catch {
            sleepProcess = nil
        }
    }

    private func stopCaffeinate() {
        sleepProcess?.terminate()
        sleepProcess = nil
    }

    func handleOpenURL(_ url: URL) {
        if url.isFileURL, url.pathExtension.lowercased() == "torrent" {
            addTorrentFile(url)
            return
        }
        switch url.scheme?.lowercased() {
        case "magnet":
            _ = addURLString(url.absoluteString)
        case "fetchster":
            if url.host == "add" || url.path.hasPrefix("/add") {
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                if let target = components?.queryItems?.first(where: { $0.name == "url" })?.value {
                    _ = addURLString(target)
                }
            }
        default:
            break
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) -> String? {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Torrent orchestration

    private func reAddTorrent(_ item: DownloadItem) {
        guard engines.torrentEnabled else {
            if let idx = index(of: item.id) {
                downloads[idx].status = .failed
                downloads[idx].errorMessage = "Torrent downloads are disabled — enable them in Settings"
                save()
            }
            return
        }
        let engine = TorrentEngine.shared
        engine.ensureRunning(downloadDir: downloadDirectory) { [weak self] ok in
            DispatchQueue.main.async {
                guard let self, let idx = self.index(of: item.id) else { return }
                guard ok else {
                    self.downloads[idx].status = .failed
                    self.downloads[idx].errorMessage = "Torrent engine (aria2) failed to start"
                    self.save()
                    return
                }
                engine.startPolling()
                let onGID: (String?) -> Void = { gid in
                    DispatchQueue.main.async {
                        self.assignGID(gid, to: item.id)
                    }
                }
                if let path = item.torrentFilePath {
                    engine.addTorrentFile(at: URL(fileURLWithPath: path), downloadDir: self.downloadDirectory, completion: onGID)
                } else if let uri = item.url?.absoluteString {
                    engine.addURI(uri: uri, downloadDir: self.downloadDirectory, completion: onGID)
                }
            }
        }
    }

    private func assignGID(_ gid: String?, to id: UUID) {
        guard let idx = index(of: id) else { return }
        if let gid {
            downloads[idx].ariaGID = gid
            if downloads[idx].status == .paused {
                TorrentEngine.shared.pause(gid)
            }
        } else {
            downloads[idx].status = .failed
            downloads[idx].errorMessage = "Torrent engine could not add this download."
        }
        save()
    }

    private func mergeTorrentSnapshots() {
        let snapshots = TorrentEngine.shared.snapshots
        var completedAny = false
        for idx in downloads.indices {
            guard let gid = downloads[idx].ariaGID, let snap = snapshots[gid] else { continue }
            var item = downloads[idx]
            switch snap.status {
            case "active":
                let total = snap.totalLength
                let done = snap.completedLength
                // A magnet's metadata download is itself an "active" torrent
                // whose totalLength equals the few-hundred-byte metadata.
                // Don't treat it as content: keep "Fetching metadata…" and
                // let the followedBy re-link pick up the real download.
                if snap.fileNames.first?.hasPrefix("[METADATA]") == true {
                    item.status = .downloading
                    item.downloadedBytes = 0
                    item.totalBytes = nil
                    item.progress = 0
                    item.speed = 0
                    item.uploadSpeed = 0
                    item.eta = nil
                    if let hash = snap.infoHash, !hash.isEmpty {
                        item.infoHash = hash
                    }
                    downloads[idx] = item
                    continue
                }
                item.downloadedBytes = done
                item.totalBytes = total > 0 ? total : nil
                item.speed = snap.downloadSpeed
                item.uploadSpeed = snap.uploadSpeed
                item.uploadedBytes = snap.uploadLength
                item.seeders = snap.numSeeders
                item.peers = snap.connections
                if let hash = snap.infoHash, !hash.isEmpty {
                    item.infoHash = hash
                }
                item.eta = nil
                if total > 0 {
                    item.progress = min(1, Double(done) / Double(total))
                    if snap.downloadSpeed > 0 {
                        item.eta = Double(total - done) / Double(snap.downloadSpeed)
                    }
                    if done >= total {
                        let wasActive = item.status == .downloading || item.status == .queued
                        item.status = .seeding
                        if wasActive && item.completedAt == nil {
                            item.progress = 1
                            item.completedAt = Date()
                            item.uploadSpeed = snap.uploadSpeed
                            if item.destinationURL == nil, !item.title.isEmpty {
                                let candidate = downloadDirectory.appendingPathComponent(item.title)
                                if FileManager.default.fileExists(atPath: candidate.path) {
                                    item.destinationURL = candidate
                                }
                            }
                            completedAny = true
                        }
                    } else {
                        item.status = .downloading
                    }
                } else {
                    item.status = .downloading
                }
                if let name = snap.name, !name.isEmpty, shouldAdoptTorrentName(item.title) {
                    item.title = name
                }
            case "waiting":
                item.status = .queued
                item.speed = 0
                item.uploadSpeed = 0
            case "paused":
                item.status = .paused
                item.speed = 0
                item.uploadSpeed = 0
                item.uploadedBytes = snap.uploadLength
            case "complete":
                if !snap.followedBy.isEmpty, let next = snap.followedBy.first {
                    // Metadata download (magnet or .torrent URL) finished;
                    // the real content continues under a new gid. Re-link
                    // instead of marking the item complete at a few KB.
                    item.ariaGID = next
                    item.status = .downloading
                    item.progress = 0
                    item.downloadedBytes = 0
                    item.totalBytes = nil
                    item.speed = 0
                    item.uploadSpeed = 0
                    item.eta = nil
                    item.completedAt = nil
                    item.destinationURL = nil
                    if let hash = snap.infoHash, !hash.isEmpty {
                        item.infoHash = hash
                    }
                    downloads[idx] = item
                    continue
                }
                if snap.fileNames.first?.hasPrefix("[METADATA]") == true {
                    // Metadata finished without a follow-up visible yet;
                    // keep the item in the metadata phase, not "complete".
                    item.status = .downloading
                    item.downloadedBytes = 0
                    item.totalBytes = nil
                    item.progress = 0
                    item.speed = 0
                    item.uploadSpeed = 0
                    item.eta = nil
                    downloads[idx] = item
                    continue
                }
                if item.status != .completed {
                    item.status = .completed
                    item.progress = 1
                    item.downloadedBytes = max(snap.completedLength, snap.totalLength)
                    item.speed = 0
                    item.uploadSpeed = 0
                    item.uploadedBytes = snap.uploadLength
                    item.seeders = snap.numSeeders
                    item.peers = snap.connections
                    if let hash = snap.infoHash, !hash.isEmpty {
                        item.infoHash = hash
                    }
                    item.eta = nil
                    item.completedAt = Date()
                    if item.destinationURL == nil, !item.title.isEmpty {
                        let candidate = downloadDirectory.appendingPathComponent(item.title)
                        if FileManager.default.fileExists(atPath: candidate.path) {
                            item.destinationURL = candidate
                        }
                    }
                    completedAny = true
                }
            case "error":
                if item.status != .failed {
                    item.status = .failed
                    item.errorMessage = snap.errorMessage ?? "Torrent failed"
                }
            case "removed":
                item.status = .removed
            default:
                break
            }
            downloads[idx] = item
        }
        if completedAny {
            save()
            if let completed = downloads.last(where: { $0.status == .completed && $0.completedAt != nil }) {
                notify(title: "Download complete", body: completed.title)
            }
        }
        // Keep polling while any torrent/magnet item is still in an active
        // state — including items whose GID hasn't been assigned yet, so a
        // just-added download doesn't get stranded before its first poll.
        let needsPolling = downloads.contains {
            ($0.kind == .torrent || $0.kind == .magnet)
                && ($0.status == .downloading || $0.status == .queued || $0.status == .seeding)
        }
        if !needsPolling {
            TorrentEngine.shared.stopPolling()
        }
    }

    // MARK: - HTTP queue

    private var activeHTTPCount: Int {
        downloads.filter { $0.kind == .http && $0.status == .downloading }.count
    }

    private func startNextQueuedHTTP() {
        guard activeHTTPCount < maxConcurrentHTTP else { return }
        guard let idx = downloads.firstIndex(where: { $0.kind == .http && $0.status == .queued }) else { return }
        downloads[idx].status = .downloading
        save()
        let item = downloads[idx]
        guard let url = item.url else {
            downloads[idx].status = .failed
            downloads[idx].errorMessage = "Invalid URL"
            save()
            return
        }
        http.start(id: item.id, url: url, headers: item.httpHeaders)
    }

    // MARK: - Persistence

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(downloads) {
            try? data.write(to: FileUtils.stateFileURL, options: .atomic)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: FileUtils.stateFileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let items = try? decoder.decode([DownloadItem].self, from: data) else { return }
        downloads = items
        for idx in downloads.indices where downloads[idx].kind == .http && downloads[idx].status == .downloading {
            downloads[idx].status = .paused
        }
        save()
    }

    private func restoreTorrentsIfNeeded() {
        let active = downloads.filter {
            ($0.kind == .torrent || $0.kind == .magnet)
                && ($0.status == .downloading || $0.status == .queued || $0.status == .paused)
        }
        guard !active.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            let group = DispatchGroup()
            for item in active {
                group.enter()
                if let gid = item.ariaGID {
                    TorrentEngine.shared.hasDownload(gid: gid) { alive in
                        DispatchQueue.main.async {
                            if !alive {
                                self.reAddTorrent(item)
                            }
                            group.leave()
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        self.reAddTorrent(item)
                        group.leave()
                    }
                }
            }
            group.notify(queue: .main) {
                self.save()
            }
        }
    }

    // MARK: - Legacy resume data cleanup

    private func deleteResumeData(for id: UUID) {
        try? FileManager.default.removeItem(at: FileUtils.resumeDirectory.appendingPathComponent("\(id.uuidString).resume"))
    }

    // MARK: - Helpers

    private func index(of id: UUID) -> Int? {
        downloads.firstIndex { $0.id == id }
    }

    private func shouldAdoptTorrentName(_ title: String) -> Bool {
        title.isEmpty
            || title == "Magnet link"
            || title.lowercased().hasSuffix(".torrent")
    }

    private func magnetDisplayName(_ uri: String) -> String? {
        guard let components = URLComponents(string: uri) else { return nil }
        let dn = components.queryItems?.first(where: { $0.name == "dn" })?.value
        if let dn, !dn.isEmpty {
            return dn.removingPercentEncoding ?? dn
        }
        return nil
    }

    private func notify(title: String, body: String) {
        guard notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    private func requestNotificationPermissionIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - Browser capture (local control server)

    private func startControlServer() {
        LocalControlServer.shared.start(port: controlPort)
    }

    private func handleControlRequest(_ path: String, body: [String: Any]) -> [String: Any] {
        // The control server calls us from its own queue; all store state must
        // be touched on the main thread.
        if !Thread.isMainThread {
            return DispatchQueue.main.sync {
                self.handleControlRequest(path, body: body)
            }
        }
        switch path {
        case "/api/ping":
            return ["ok": true, "app": "Fetchster"]
        case "/api/status":
            return ["ok": true, "active": activeCount, "total": downloads.count]
        case "/api/download":
            guard let url = body["url"] as? String, !url.isEmpty else {
                return ["ok": false, "error": "Missing url"]
            }
            var headers = body["headers"] as? [String: String] ?? [:]
            if let userAgent = body["userAgent"] as? String, !userAgent.isEmpty, headers["User-Agent"] == nil {
                headers["User-Agent"] = userAgent
            }
            if let cookies = body["cookies"] as? String, !cookies.isEmpty, headers["Cookie"] == nil {
                headers["Cookie"] = cookies
            }
            if let referer = body["referer"] as? String, !referer.isEmpty, headers["Referer"] == nil {
                headers["Referer"] = referer
            }
            let filename = body["filename"] as? String
            let absolutePath = filename?.hasPrefix("/") == true ? filename : nil
            let suggestedTitle = absolutePath == nil ? filename : nil
            guard addDownload(
                urlString: url,
                headers: headers,
                suggestedTitle: suggestedTitle,
                absolutePath: absolutePath
            ) else {
                return ["ok": false, "error": "Could not add download"]
            }
            if let first = downloads.first {
                return ["ok": true, "id": first.id.uuidString, "title": first.title]
            }
            return ["ok": true]
        case "/api/media":
            return handleMediaRequest(body)
        case "/api/engine":
            let engine = body["engine"] as? String ?? ""
            let action = body["action"] as? String ?? ""
            switch engine {
            case "torrent":
                setTorrentEngineEnabled(action == "enable")
                return ["ok": true]
            case "media", "youtube":
                setMediaEngineEnabled(action == "enable")
                return ["ok": true]
            default:
                return ["ok": false, "error": "Unknown engine: \(engine)"]
            }
        case "/api/youtube":
            guard let videoId = body["videoId"] as? String, !videoId.isEmpty else {
                return ["ok": false, "error": "Missing videoId"]
            }
            let format = body["format"] as? String ?? "b"
            let browser = body["browser"] as? String ?? "brave"
            guard let watchURL = URL(string: "https://www.youtube.com/watch?v=\(videoId)") else {
                return ["ok": false, "error": "Invalid videoId"]
            }
            var stream = DetectedMediaStream(
                url: watchURL.absoluteString,
                label: "YouTube \(videoId)",
                kind: "youtube",
                formatId: format,
                browser: browser
            )
            stream.headers = ["Browser": browser]
            let ok = addMediaStream(stream)
            return ok ? ["ok": true] : ["ok": false, "error": "Could not start download"]
        default:
            return ["ok": false, "error": "Not found: \(path)"]
        }
    }

    private func handleMediaRequest(_ body: [String: Any]) -> [String: Any] {
        let rawStreams = (body["streams"] as? [[String: Any]]) ?? []
        var streams: [DetectedMediaStream] = []
        for raw in rawStreams {
            guard let url = raw["url"] as? String, !url.isEmpty else { continue }
            streams.append(DetectedMediaStream(
                url: url,
                mime: raw["mime"] as? String,
                size: (raw["size"] as? NSNumber)?.int64Value,
                label: raw["label"] as? String,
                referer: raw["referer"] as? String,
                userAgent: raw["userAgent"] as? String,
                cookies: raw["cookies"] as? String,
                kind: raw["kind"] as? String,
                manifestBody: raw["manifestBody"] as? String,
                formatId: raw["formatId"] as? String,
                browser: raw["browser"] as? String
            ))
        }
        let pageTitle = body["pageTitle"] as? String
        let pageURL = body["pageURL"] as? String
        let browser = body["browser"] as? String ?? "brave"
        if streams.isEmpty && pageURL == nil {
            // Read path (e.g. GET /api/media) — return what's currently known.
            return ["ok": true, "media": detectedMedia.map { media in
                [
                    "pageTitle": media.pageTitle ?? "",
                    "pageURL": media.pageURL ?? "",
                    "streams": media.streams.map { stream in
                        [
                            "id": stream.id.uuidString,
                            "url": stream.url,
                            "mime": stream.mime ?? "",
                            "size": stream.size ?? 0,
                            "label": stream.label ?? "",
                            "kind": stream.kind ?? "",
                        ]
                    },
                ]
            }]
        }
        let pageKey = pageURL ?? ""
        if !streams.isEmpty && !engines.mediaEnabled {
            // Video grab (direct/HLS/DASH/YouTube) is an opt-in media feature
            // that needs the yt-dlp/ffmpeg engines.
            insertMediaHint(
                pageTitle: pageTitle,
                pageURL: pageKey,
                label: "Video grab is disabled — enable Media downloads in Settings"
            )
            return ["ok": true, "count": 0]
        }
        if streams.isEmpty {
            detectedMedia.removeAll { $0.pageURL == pageKey }
        } else if let idx = detectedMedia.firstIndex(where: { $0.pageURL == pageKey }) {
            detectedMedia[idx] = DetectedMedia(pageTitle: pageTitle, pageURL: pageURL, streams: streams)
        } else {
            detectedMedia.insert(DetectedMedia(pageTitle: pageTitle, pageURL: pageURL, streams: streams), at: 0)
        }
        if !streams.isEmpty {
            NotificationCenter.default.post(name: .mediaDetected, object: nil)
        }
        expandDashStreams(streams: streams, pageTitle: pageTitle, pageURL: pageURL)
        if let pageURL, let videoId = YouTubeManager.videoId(from: pageURL) {
            queueYouTubeFormats(pageTitle: pageTitle, pageURL: pageURL, videoId: videoId, browser: browser)
        }
        return ["ok": true, "count": streams.count]
    }

    /// Per-quality format list for YouTube: list formats with the bundled
    /// yt-dlp (using the browser's session) and replace the detected rows
    /// with one row per quality. Falls back to a placeholder while loading.
    private func queueYouTubeFormats(pageTitle: String?, pageURL: String, videoId: String, browser: String) {
        guard !pendingYouTubeListings.contains(videoId) else { return }
        guard engines.mediaEnabled else {
            insertMediaHint(
                pageTitle: pageTitle,
                pageURL: pageURL,
                label: "Video grab is disabled — enable Media downloads in Settings"
            )
            return
        }
        guard case .ready = engines.state(for: .ytdlp) else {
            pendingYouTubeListings.insert(videoId)
            insertMediaHint(pageTitle: pageTitle, pageURL: pageURL, label: "Downloading media engine…")
            engines.ensure(.ytdlp) { [weak self] state in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.pendingYouTubeListings.remove(videoId)
                    if case .ready = state {
                        self.queueYouTubeFormats(pageTitle: pageTitle, pageURL: pageURL, videoId: videoId, browser: browser)
                    } else {
                        self.insertMediaHint(pageTitle: pageTitle, pageURL: pageURL, label: "Media engine unavailable")
                    }
                }
            }
            return
        }
        pendingYouTubeListings.insert(videoId)
        insertYouTubePlaceholder(pageTitle: pageTitle, pageURL: pageURL, videoId: videoId, browser: browser)
        youtube.listFormats(videoId: videoId, browser: browser) { [weak self] listing in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingYouTubeListings.remove(videoId)
                guard let listing, !listing.formats.isEmpty else {
                    // Keep whatever the extension captured; the engine will
                    // report a clear error if a row is clicked.
                    return
                }
                var streams: [DetectedMediaStream] = []
                for format in listing.formats {
                    var s = DetectedMediaStream(
                        url: pageURL,
                        mime: nil,
                        size: format.size,
                        label: format.label,
                        referer: nil,
                        userAgent: nil,
                        cookies: nil,
                        kind: "youtube",
                        formatId: format.id,
                        browser: browser
                    )
                    s.headers = ["Browser": browser]
                    streams.append(s)
                }
                if let idx = self.detectedMedia.firstIndex(where: { $0.pageURL == pageURL }) {
                    self.detectedMedia[idx] = DetectedMedia(pageTitle: pageTitle, pageURL: pageURL, streams: streams)
                } else {
                    self.detectedMedia.insert(DetectedMedia(pageTitle: pageTitle, pageURL: pageURL, streams: streams), at: 0)
                }
                NotificationCenter.default.post(name: .mediaDetected, object: nil)
            }
        }
    }

    private func insertMediaHint(pageTitle: String?, pageURL: String, label: String) {
        var stream = DetectedMediaStream(
            url: pageURL,
            label: label,
            kind: "youtube",
            formatId: nil,
            browser: "brave"
        )
        stream.headers = ["Browser": "brave"]
        let hint = DetectedMedia(pageTitle: pageTitle, pageURL: pageURL, streams: [stream])
        if let idx = detectedMedia.firstIndex(where: { $0.pageURL == pageURL }) {
            detectedMedia[idx] = hint
        } else {
            detectedMedia.insert(hint, at: 0)
        }
        NotificationCenter.default.post(name: .mediaDetected, object: nil)
    }

    private func insertYouTubePlaceholder(pageTitle: String?, pageURL: String, videoId: String, browser: String) {
        var stream = DetectedMediaStream(
            url: pageURL,
            label: "Loading formats…",
            kind: "youtube",
            formatId: nil,
            browser: browser
        )
        stream.headers = ["Browser": browser]
        let placeholder = DetectedMedia(pageTitle: pageTitle, pageURL: pageURL, streams: [stream])
        if let idx = detectedMedia.firstIndex(where: { $0.pageURL == pageURL }) {
            detectedMedia[idx] = placeholder
        } else {
            detectedMedia.insert(placeholder, at: 0)
        }
        NotificationCenter.default.post(name: .mediaDetected, object: nil)
    }

    /// Format list: replace a single DASH row with one row per
    /// quality found in the manifest (the downloader picks the matching
    /// representation via the row's label).
    private func expandDashStreams(streams: [DetectedMediaStream],
                                   pageTitle: String?, pageURL: String?) {
        let dashStreams = streams.filter { $0.kind == "dash" }
        guard !dashStreams.isEmpty else { return }
        for stream in dashStreams {
            guard let url = URL(string: stream.url) else { continue }
            var headers: [String: String] = [:]
            if let ua = stream.userAgent, !ua.isEmpty { headers["User-Agent"] = ua }
            if let ref = stream.referer, !ref.isEmpty { headers["Referer"] = ref }
            if let cookies = stream.cookies, !cookies.isEmpty { headers["Cookie"] = cookies }
            if let captured = stream.headers {
                for (key, value) in captured where headers[key] == nil {
                    headers[key] = value
                }
            }
            let manifestClosure: (DASHClient.Manifest?) -> Void = { [weak self] manifest in
                guard let self else { return }
                DispatchQueue.main.async {
                    guard let manifest else { return }
                    let videos = manifest.video.filter { $0.mimeType.hasPrefix("video/") }
                    guard !videos.isEmpty,
                          let idx = self.detectedMedia.firstIndex(where: { $0.pageURL == pageURL }) else {
                        return
                    }
                    let expanded = videos.map { rep -> DetectedMediaStream in
                        var s = stream
                        s.label = rep.height > 0 ? "\(rep.height)p MP4" : "MP4"
                        s.mime = rep.mimeType
                        return s
                    }
                    var media = self.detectedMedia[idx]
                    media.streams.removeAll { $0.url == stream.url }
                    media.streams.insert(contentsOf: expanded, at: 0)
                    self.detectedMedia[idx] = media
                    NotificationCenter.default.post(name: .mediaDetected, object: nil)
                }
            }
            if let body = stream.manifestBody, !body.isEmpty {
                manifestClosure(dashClient.parse(mpd: body, baseURL: url))
            } else {
                dashClient.fetchManifest(url: url, headers: headers.isEmpty ? nil : headers, completion: manifestClosure)
            }
        }
    }
}

extension Notification.Name {
    static let mediaDetected = Notification.Name("Fetchster.mediaDetected")
}

// MARK: - HTTPDownloadDelegate

extension DownloadStore: HTTPDownloadDelegate {
    func httpProgress(id: UUID, downloaded: Int64, total: Int64?, speed: Int64) {
        guard let idx = index(of: id) else { return }
        downloads[idx].downloadedBytes = downloaded
        downloads[idx].totalBytes = total
        downloads[idx].speed = speed
        if let total, total > 0 {
            downloads[idx].progress = min(1, Double(downloaded) / Double(total))
            if speed > 0 {
                downloads[idx].eta = Double(total - downloaded) / Double(speed)
            }
        }
    }

    func httpFinished(id: UUID, destinationURL: URL, suggestedName: String?) {
        guard let idx = index(of: id) else { return }
        var item = downloads[idx]
        item.destinationURL = destinationURL
        item.title = destinationURL.lastPathComponent
        item.status = .completed
        item.progress = 1
        item.downloadedBytes = item.totalBytes ?? FileUtils.fileSize(at: destinationURL)
        item.speed = 0
        item.eta = nil
        item.completedAt = Date()
        downloads[idx] = item
        deleteResumeData(for: id)
        item.partialFilePath = nil
        downloads[idx] = item
        save()
        notify(title: "Download complete", body: item.title)
        startNextQueuedHTTP()
    }

    func httpFailed(id: UUID, error: Error?) {
        guard let idx = index(of: id) else { return }
        downloads[idx].status = .failed
        downloads[idx].errorMessage = error?.localizedDescription ?? "Download failed"
        save()
        startNextQueuedHTTP()
    }
}

// MARK: - MediaDownloadDelegate

extension DownloadStore: MediaDownloadDelegate {
    func mediaProgress(id: UUID, downloaded: Int64, total: Int64?, phase: String) {
        guard let idx = index(of: id) else { return }
        downloads[idx].downloadedBytes = downloaded
        downloads[idx].totalBytes = total
        downloads[idx].mediaPhase = phase
    }

    func mediaFinished(id: UUID, destinationURL: URL) {
        guard let idx = index(of: id) else { return }
        var item = downloads[idx]
        item.destinationURL = destinationURL
        item.title = destinationURL.lastPathComponent
        item.status = .completed
        item.progress = 1
        item.downloadedBytes = FileUtils.fileSize(at: destinationURL)
        item.speed = 0
        item.eta = nil
        item.completedAt = Date()
        item.mediaPhase = nil
        downloads[idx] = item
        save()
        notify(title: "Download complete", body: item.title)
    }

    func mediaFailed(id: UUID, error: Error?) {
        guard let idx = index(of: id) else { return }
        downloads[idx].status = .failed
        downloads[idx].errorMessage = error?.localizedDescription ?? "Media download failed"
        downloads[idx].mediaPhase = nil
        save()
    }
}
