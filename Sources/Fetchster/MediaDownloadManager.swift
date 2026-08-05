import Foundation

protocol MediaDownloadDelegate: AnyObject {
    func mediaProgress(id: UUID, downloaded: Int64, total: Int64?, phase: String)
    func mediaFinished(id: UUID, destinationURL: URL)
    func mediaFailed(id: UUID, error: Error?)
}

/// Downloads media that isn't a plain file: HLS playlists (assembled by
/// ffmpeg) and DASH manifests (segments fetched, then muxed by ffmpeg).
final class MediaDownloadManager {
    weak var delegate: MediaDownloadDelegate?
    var downloadDirectory: URL?
    var fallbackName: ((UUID) -> String?)?
    var mediaMode: ((UUID) -> String?)?      // "hls" | "dash"
    var mediaURLs: ((UUID) -> [String]?)?    // [manifest URL]
    var mediaHeaders: ((UUID) -> [String: String]?)?
    var mediaLabel: ((UUID) -> String?)?     // quality label for DASH choice

    private let dash = DASHClient()
    private var tasks: [UUID: TaskState] = [:]
    private var progressTimers: [UUID: Timer] = [:]

    private struct TaskState {
        var mode: String
        var urls: [String]
        var headers: [String: String]
        var name: String
        var tempDir: URL
        var finalURL: URL
        var process: Process?
        var cancelled = false
        var downloaded: Int64 = 0
        var total: Int64?
        var phase = "Processing"
    }

    static func locateBinary() -> URL? {
        let candidates = [
            EngineManager.enginesDirectory().appendingPathComponent("ffmpeg"),
            URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
            URL(fileURLWithPath: "/usr/local/bin/ffmpeg"),
        ]
        for candidate in candidates.compactMap({ $0 })
        where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    func start(id: UUID, urls: [String], mode: String, headers: [String: String]?) {
        guard let directory = downloadDirectory ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            fail(id, NSError(domain: "Media", code: 1, userInfo: [NSLocalizedDescriptionKey: "No download folder"]))
            return
        }
        let name = sanitize(mediaName(for: id))
        let tempDir = directory.appendingPathComponent(".Fetchster-\(id.uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let finalURL = FileUtils.uniqueDestination(suggestedName: name, in: directory)
        tasks[id] = TaskState(
            mode: mode,
            urls: urls,
            headers: headers ?? [:],
            name: name,
            tempDir: tempDir,
            finalURL: finalURL
        )
        switch mode {
        case "hls":
            runHLS(id: id)
        case "dash":
            runDASH(id: id)
        default:
            fail(id, NSError(domain: "Media", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown media mode"]))
        }
    }

    func cancel(id: UUID) {
        guard var task = tasks[id] else { return }
        task.cancelled = true
        tasks[id] = task
        task.process?.terminate()
        stopTimer(id: id)
        DispatchQueue.global().async {
            try? FileManager.default.removeItem(at: task.tempDir)
        }
        tasks[id] = nil
    }

    // MARK: - HLS

    private func runHLS(id: UUID) {
        guard let task = tasks[id], let url = task.urls.first, let binary = Self.locateBinary() else {
            fail(id, NSError(domain: "Media", code: 3, userInfo: [NSLocalizedDescriptionKey: "ffmpeg not available"]))
            return
        }
        report(id: id, phase: "Processing")
        let output = task.tempDir.appendingPathComponent("media.mp4")
        runFFmpeg(
            binary: binary,
            arguments: ["-y", "-v", "error", "-headers", headerString(task.headers), "-i", url, "-c", "copy", output.path],
            id: id
        ) { [weak self] success in
            guard let self, let task = self.tasks[id], !task.cancelled else { return }
            if success && FileManager.default.fileExists(atPath: output.path) {
                self.finish(id: id, from: output)
            } else if success {
                // mp4 muxer may reject TS HLS — retry as MKV.
                let mkvOutput = task.tempDir.appendingPathComponent("media.mkv")
                self.runFFmpeg(
                    binary: binary,
                    arguments: ["-y", "-v", "error", "-headers", self.headerString(task.headers), "-i", url, "-c", "copy", mkvOutput.path],
                    id: id
                ) { ok in
                    if ok, FileManager.default.fileExists(atPath: mkvOutput.path) {
                        self.finish(id: id, from: mkvOutput)
                    } else {
                        self.fail(id, NSError(domain: "Media", code: 4, userInfo: [NSLocalizedDescriptionKey: "ffmpeg could not assemble the stream"]))
                    }
                }
            } else {
                self.fail(id, NSError(domain: "Media", code: 4, userInfo: [NSLocalizedDescriptionKey: "ffmpeg could not assemble the stream"]))
            }
        }
    }

    // MARK: - DASH

    private func runDASH(id: UUID) {
        guard let task = tasks[id], let url = task.urls.first, let manifestURL = URL(string: url) else {
            fail(id, NSError(domain: "Media", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid manifest"]))
            return
        }
        report(id: id, phase: "Reading manifest")
        dash.fetchManifest(url: manifestURL, headers: task.headers) { [weak self] manifest in
            guard let self, let task = self.tasks[id], !task.cancelled else { return }
            guard let manifest, !manifest.video.isEmpty else {
                self.fail(id, NSError(domain: "Media", code: 6, userInfo: [NSLocalizedDescriptionKey: "No playable formats in manifest"]))
                return
            }
            let video = self.chooseVideo(from: manifest.video, label: self.mediaLabel?(id))
            let audio = self.chooseAudio(from: manifest.audio)
            self.downloadDASHRepresentations(id: id, video: video, audio: audio)
        }
    }

    private func chooseVideo(from reps: [DashRepresentation], label: String?) -> DashRepresentation {
        let mp4 = reps.filter { $0.mimeType.hasPrefix("video/mp4") }
        let pool = mp4.isEmpty ? reps : mp4
        if let label {
            let digits = label.filter(\.isNumber)
            if let height = Int(digits) {
                if let match = pool.first(where: { $0.height == height }) {
                    return match
                }
            }
        }
        return pool.max { $0.height < $1.height } ?? pool[0]
    }

    private func chooseAudio(from reps: [DashRepresentation]) -> DashRepresentation? {
        let mp4a = reps.filter { $0.mimeType.contains("mp4a") || $0.mimeType.hasPrefix("audio/mp4") }
        let pool = mp4a.isEmpty ? reps : mp4a
        return pool.max { $0.bandwidth < $1.bandwidth }
    }

    private func downloadDASHRepresentations(id: UUID, video: DashRepresentation, audio: DashRepresentation?) {
        guard let task = tasks[id] else { return }
        report(id: id, phase: "Downloading")
        let group = DispatchGroup()
        var videoFiles: [URL]?
        var audioFiles: [URL]?

        group.enter()
        downloadSegments(id: id, rep: video, prefix: "video", headers: task.headers) { file in
            videoFiles = file
            group.leave()
        }

        if let audio {
            group.enter()
            downloadSegments(id: id, rep: audio, prefix: "audio", headers: task.headers) { file in
                audioFiles = file
                group.leave()
            }
        }

        group.notify(queue: .global(qos: .utility)) { [weak self] in
            self?.muxDASH(id: id, videoFiles: videoFiles, audioFiles: audioFiles)
        }
    }

    private func downloadSegments(id: UUID, rep: DashRepresentation, prefix: String,
                                  headers: [String: String], completion: @escaping ([URL]?) -> Void) {
        guard let task = tasks[id], !task.cancelled else {
            completion(nil)
            return
        }
        var all = rep.segments
        if let initURL = rep.initialization {
            all.insert(initURL, at: 0)
        }
        guard !all.isEmpty else {
            completion(nil)
            return
        }

        let dir = task.tempDir
        var files: [URL] = []
        func next(_ index: Int) {
            guard !(tasks[id]?.cancelled ?? true) else {
                completion(nil)
                return
            }
            guard index < all.count else {
                completion(files.isEmpty ? nil : files)
                return
            }
            let dest = dir.appendingPathComponent(String(format: "%@-%06d.m4s", prefix, index + 1))
            var request = URLRequest(url: all[index])
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            let taskRef = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                guard let self else { return }
                if let data, error == nil, (response as? HTTPURLResponse)?.statusCode == 200 {
                    try? data.write(to: dest)
                    files.append(dest)
                    self.bumpProgress(id: id, by: Int64(data.count))
                    next(index + 1)
                } else {
                    // End of stream (404) — treat as done.
                    completion(files.isEmpty ? nil : files)
                }
            }
            taskRef.resume()
        }
        next(0)
    }

    private func muxDASH(id: UUID, videoFiles: [URL]?, audioFiles: [URL]?) {
        guard let task = tasks[id], let binary = Self.locateBinary(), let videoFiles, !videoFiles.isEmpty else {
            fail(id, NSError(domain: "Media", code: 7, userInfo: [NSLocalizedDescriptionKey: "No video segments"]))
            return
        }
        report(id: id, phase: "Merging")

        // fMP4 fragments concatenate byte-for-byte (init + segments).
        let videoFile = task.tempDir.appendingPathComponent("video.mp4")
        guard concatenate(files: videoFiles, to: videoFile) else {
            fail(id, NSError(domain: "Media", code: 8, userInfo: [NSLocalizedDescriptionKey: "Could not assemble video"]))
            return
        }
        guard let audioFiles, !audioFiles.isEmpty else {
            finish(id: id, from: videoFile)
            return
        }
        let audioFile = task.tempDir.appendingPathComponent("audio.mp4")
        guard concatenate(files: audioFiles, to: audioFile) else {
            fail(id, NSError(domain: "Media", code: 9, userInfo: [NSLocalizedDescriptionKey: "Could not assemble audio"]))
            return
        }
        let output = task.tempDir.appendingPathComponent("final.mp4")
        runFFmpeg(
            binary: binary,
            arguments: ["-y", "-v", "error", "-i", videoFile.path, "-i", audioFile.path, "-c", "copy", output.path],
            id: id
        ) { [weak self] merged in
            guard let self, let task = self.tasks[id] else { return }
            if merged, FileManager.default.fileExists(atPath: output.path) {
                self.finish(id: id, from: output)
                return
            }
            // Some audio codecs (e.g. Opus) can't live in MP4 — retry as MKV.
            let mkv = task.tempDir.appendingPathComponent("final.mkv")
            self.runFFmpeg(
                binary: binary,
                arguments: ["-y", "-v", "error", "-i", videoFile.path, "-i", audioFile.path, "-c", "copy", mkv.path],
                id: id
            ) { ok in
                if ok, FileManager.default.fileExists(atPath: mkv.path) {
                    self.finish(id: id, from: mkv)
                } else {
                    self.fail(id, NSError(domain: "Media", code: 10, userInfo: [NSLocalizedDescriptionKey: "Could not merge audio and video"]))
                }
            }
        }
    }

    private func concatenate(files: [URL], to output: URL) -> Bool {
        FileManager.default.createFile(atPath: output.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: output) else { return false }
        defer { handle.closeFile() }
        for file in files {
            guard let data = try? Data(contentsOf: file) else { return false }
            handle.write(data)
        }
        return true
    }

    // MARK: - ffmpeg runner

    private func runFFmpeg(binary: URL, arguments: [String], id: UUID,
                           completion: @escaping (Bool) -> Void) {
        guard var task = tasks[id], !task.cancelled else {
            completion(false)
            return
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in
            DispatchQueue.main.async {
                completion(process.terminationStatus == 0)
            }
        }
        task.process = process
        tasks[id] = task
        startProgressTimer(id: id)
        do {
            try process.run()
        } catch {
            completion(false)
        }
    }

    private func startProgressTimer(id: UUID) {
        stopTimer(id: id)
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let task = self.tasks[id] else { return }
            let size = FileUtils.fileSize(at: task.tempDir)
            self.report(id: id, downloaded: size, total: nil, phase: task.phase)
        }
        progressTimers[id] = timer
    }

    private func stopTimer(id: UUID) {
        progressTimers[id]?.invalidate()
        progressTimers[id] = nil
    }

    // MARK: - helpers

    private func headerString(_ headers: [String: String]) -> String {
        headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n") + "\r\n"
    }

    private func mediaName(for id: UUID) -> String {
        let fallback = fallbackName?(id) ?? "video.mp4"
        return fallback
    }

    private func sanitize(_ name: String) -> String {
        var cleaned = name.replacingOccurrences(of: "/", with: "_")
        if cleaned.isEmpty { cleaned = "video.mp4" }
        return cleaned
    }

    private func bumpProgress(id: UUID, by bytes: Int64) {
        guard var task = tasks[id] else { return }
        task.downloaded += bytes
        tasks[id] = task
        report(id: id, downloaded: task.downloaded, total: task.total, phase: task.phase)
    }

    private func report(id: UUID, phase: String) {
        guard let task = tasks[id] else { return }
        report(id: id, downloaded: task.downloaded, total: task.total, phase: phase)
    }

    private func report(id: UUID, downloaded: Int64, total: Int64?, phase: String) {
        guard var task = tasks[id] else { return }
        task.downloaded = downloaded
        task.total = total
        task.phase = phase
        tasks[id] = task
        DispatchQueue.main.async {
            self.delegate?.mediaProgress(id: id, downloaded: downloaded, total: total, phase: phase)
        }
    }

    private func finish(id: UUID, from tempFile: URL) {
        guard let task = tasks[id] else { return }
        stopTimer(id: id)
        let finalURL: URL
        if tempFile.pathExtension.lowercased() == task.finalURL.pathExtension.lowercased() {
            finalURL = task.finalURL
        } else {
            finalURL = task.finalURL
                .deletingPathExtension()
                .appendingPathExtension(tempFile.pathExtension)
        }
        do {
            try FileManager.default.moveItem(at: tempFile, to: finalURL)
        } catch {
            try? FileManager.default.copyItem(at: tempFile, to: finalURL)
        }
        try? FileManager.default.removeItem(at: task.tempDir)
        tasks[id] = nil
        DispatchQueue.main.async {
            self.delegate?.mediaFinished(id: id, destinationURL: finalURL)
        }
    }

    private func fail(_ id: UUID, _ error: Error) {
        guard let task = tasks[id] else { return }
        stopTimer(id: id)
        try? FileManager.default.removeItem(at: task.tempDir)
        tasks[id] = nil
        DispatchQueue.main.async {
            self.delegate?.mediaFailed(id: id, error: error)
        }
    }
}
