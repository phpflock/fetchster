import Foundation

/// One selectable YouTube format/quality shown in the popover.
struct YTFormatInfo: Equatable {
    var id: String          // yt-dlp format_id or a spec like "137+ba/b"
    var label: String       // e.g. "1080p MP4"
    var size: Int64?
    var ext: String
    var height: Int
}

/// Result of listing a video's formats.
struct YTListing {
    var title: String
    var duration: TimeInterval?
    var formats: [YTFormatInfo]
}

/// Downloads YouTube videos with the bundled yt-dlp binary. yt-dlp handles
/// YouTube's proprietary streaming protocols (UMP/SABR, nsig, POT tokens) and
/// uses the user's browser session via --cookies-from-browser, so downloads
/// behave exactly like the logged-in browser.
final class YouTubeManager {
    weak var delegate: MediaDownloadDelegate?
    var downloadDirectory: URL?

    private struct TaskState {
        var process: Process?
        var cancelled = false
        var tempDir: URL?
        var directorySnapshot: Set<String> = []
        var lastReport: Date = .distantPast
    }

    private var tasks: [UUID: TaskState] = [:]
    private var formatCache: [String: YTListing] = [:]
    private let queue = DispatchQueue(label: "YouTubeManager")

    static func locateBinary() -> URL? {
        let candidates = [
            EngineManager.enginesDirectory().appendingPathComponent("yt-dlp"),
            URL(fileURLWithPath: "/opt/homebrew/bin/yt-dlp"),
            URL(fileURLWithPath: "/usr/local/bin/yt-dlp"),
        ]
        for candidate in candidates.compactMap({ $0 })
        where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    static func videoId(from urlString: String?) -> String? {
        guard let urlString, let url = URL(string: urlString) else { return nil }
        if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "v" })?.value, !v.isEmpty {
            return v
        }
        if url.host == "youtu.be" {
            let id = url.lastPathComponent
            if !id.isEmpty && id != "/" { return id }
        }
        return nil
    }

    // MARK: - Format listing

    func listFormats(videoId: String, browser: String?, completion: @escaping (YTListing?) -> Void) {
        if let cached = formatCache[videoId] {
            completion(cached)
            return
        }
        guard let binary = Self.locateBinary() else {
            completion(nil)
            return
        }
        let watchURL = "https://www.youtube.com/watch?v=\(videoId)"
        let args = ["--cookies-from-browser", browser ?? "brave", "-J", "--no-playlist", watchURL]
        runYTDLP(binary: binary, args: args) { exitCode, stdout, _ in
            guard exitCode == 0, let data = stdout.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil)
                return
            }
            let listing = Self.parseListing(json: json)
            if !listing.formats.isEmpty {
                self.formatCache[videoId] = listing
            }
            completion(listing)
        }
    }

    private static func parseListing(json: [String: Any]) -> YTListing {
        let title = (json["title"] as? String) ?? "YouTube video"
        let duration = (json["duration"] as? NSNumber)?.doubleValue
        let rawFormats = (json["formats"] as? [[String: Any]]) ?? []

        var muxed: [YTFormatInfo] = []
        var videoOnly: [YTFormatInfo] = []
        var audioABRs: [Int: YTFormatInfo] = [:]

        for f in rawFormats {
            let vcodec = (f["vcodec"] as? String) ?? "none"
            let acodec = (f["acodec"] as? String) ?? "none"
            let protocolName = (f["protocol"] as? String) ?? ""
            let url = f["url"] as? String
            if protocolName == "mhtml" || protocolName.isEmpty { continue }
            if url == nil && protocolName != "sabr" { continue }
            let hasVideo = vcodec != "none"
            let hasAudio = acodec != "none"
            let ext = (f["ext"] as? String) ?? "mp4"
            let height = (f["height"] as? NSNumber)?.intValue ?? 0
            let size = ((f["filesize"] as? NSNumber) ?? (f["filesize_approx"] as? NSNumber))?.int64Value
            let formatID = (f["format_id"] as? String) ?? ""
            if formatID.isEmpty { continue }

            if hasVideo && hasAudio {
                muxed.append(YTFormatInfo(
                    id: formatID,
                    label: height > 0 ? "\(height)p \(ext.uppercased()) (muxed)" : "\(ext.uppercased()) (muxed)",
                    size: size,
                    ext: ext,
                    height: height
                ))
            } else if hasVideo {
                // Merge with the best audio track so "1080p" always yields a
                // playable file. Falls back to a muxed format.
                videoOnly.append(YTFormatInfo(
                    id: "\(formatID)+ba[ext=m4a]/\(formatID)+ba/\(formatID)+b/b",
                    label: height > 0 ? "\(height)p \(ext.uppercased())" : "\(ext.uppercased())",
                    size: size,
                    ext: ext,
                    height: height
                ))
            } else if hasAudio {
                let abr = (f["abr"] as? NSNumber)?.intValue ?? 0
                let abrKey = max(1, abr)
                let codecHint = acodec.contains("mp4a") ? "AAC" : (acodec.contains("opus") ? "Opus" : ext.uppercased())
                audioABRs[abrKey] = YTFormatInfo(
                    id: formatID,
                    label: abr > 0 ? "Audio \(abr)kbps \(codecHint)" : "Audio \(codecHint)",
                    size: size,
                    ext: ext,
                    height: 0
                )
            }
        }

        // Dedupe video rows by height: prefer MP4 (H.264), then VP9, then AV1.
        func bestPerHeight(_ items: [YTFormatInfo]) -> [YTFormatInfo] {
            var best: [Int: YTFormatInfo] = [:]
            for item in items {
                let score: Int
                switch item.ext.lowercased() {
                case "mp4": score = 3
                case "webm": score = 2
                default: score = 1
                }
                if best[item.height] != nil {
                    if score > 2 { best[item.height] = item }
                } else {
                    best[item.height] = item
                }
            }
            return best.values.sorted { $0.height > $1.height }
        }

        let videoRows = bestPerHeight(videoOnly)
        let muxedRows = muxed.sorted { $0.height > $1.height }
        let audioRows = audioABRs.values.sorted { $0.label < $1.label }
        return YTListing(title: title, duration: duration, formats: videoRows + muxedRows + audioRows)
    }

    // MARK: - Download

    func start(id: UUID, videoId: String, formatSpec: String, browser: String?) {
        guard let binary = Self.locateBinary() else {
            fail(id: id, error: NSError(domain: "YouTube", code: 1, userInfo: [NSLocalizedDescriptionKey: "Media engine not ready — enable Media downloads in Settings"]))
            return
        }
        guard let directory = downloadDirectory ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            fail(id: id, error: NSError(domain: "YouTube", code: 2, userInfo: [NSLocalizedDescriptionKey: "No download folder"]))
            return
        }
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fetchster-yt-\(id.uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let snapshot = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        tasks[id] = TaskState(tempDir: tempDir, directorySnapshot: snapshot)

        let ffmpegDir = MediaDownloadManager.locateBinary()?.deletingLastPathComponent().path
        var args = [
            "--cookies-from-browser", browser ?? "brave",
            "--newline",
            "--no-playlist",
            "--merge-output-format", "mp4",
            "--force-overwrites",
            "-f", formatSpec,
            "-o", directory.appendingPathComponent("%(title)s.%(ext)s").path,
            "-P", "temp:\(tempDir.path)",
            "--print", "after_move:filepath",
        ]
        if let ffmpegDir {
            args += ["--ffmpeg-location", ffmpegDir]
        }
        args.append("https://www.youtube.com/watch?v=\(videoId)")

        report(id: id, phase: "Preparing")
        runProcess(binary: binary, args: args, id: id) { [weak self] exitCode, output, errorText in
            guard let self, let task = self.tasks[id], !task.cancelled else { return }
            if exitCode == 0 {
                let finalURL = self.detectFinalFile(task: task, output: output)
                if let finalURL {
                    self.finish(id: id, destinationURL: finalURL)
                } else {
                    self.fail(id: id, error: NSError(domain: "YouTube", code: 3, userInfo: [NSLocalizedDescriptionKey: "yt-dlp finished but the file wasn't found"]))
                }
            } else {
                let message = Self.extractError(output: output, errorText: errorText)
                self.fail(id: id, error: NSError(domain: "YouTube", code: 4, userInfo: [NSLocalizedDescriptionKey: message]))
            }
        }
    }

    func cancel(id: UUID) {
        guard var task = tasks[id] else { return }
        task.cancelled = true
        tasks[id] = task
        task.process?.terminate()
        cleanupTemp(task: task)
        tasks[id] = nil
    }

    // MARK: - Process helpers

    private func runYTDLP(binary: URL, args: [String], completion: @escaping (Int32, String, String) -> Void) {
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            completion(-1, "", error.localizedDescription)
            return
        }
        let outData = NSMutableData()
        let errData = NSMutableData()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                outPipe.fileHandleForReading.readabilityHandler = nil
            } else {
                outData.append(data)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                errPipe.fileHandleForReading.readabilityHandler = nil
            } else {
                errData.append(data)
            }
        }
        process.terminationHandler = { _ in
            let out = String(data: outData as Data, encoding: .utf8) ?? ""
            let err = String(data: errData as Data, encoding: .utf8) ?? ""
            completion(process.terminationStatus, out, err)
        }
    }

    private func runProcess(binary: URL, args: [String], id: UUID,
                            completion: @escaping (Int32, String, String) -> Void) {
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            completion(-1, "", error.localizedDescription)
            return
        }
        tasks[id]?.process = process

        var buffer = Data()
        var outAll = Data()
        var errAll = Data()
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            if data.isEmpty {
                outPipe.fileHandleForReading.readabilityHandler = nil
                return
            }
            outAll.append(data)
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                if let line = String(data: lineData, encoding: .utf8) {
                    self.handleOutputLine(line, id: id)
                }
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                errPipe.fileHandleForReading.readabilityHandler = nil
            } else {
                errAll.append(data)
            }
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            if !buffer.isEmpty, let tail = String(data: buffer, encoding: .utf8) {
                self.handleOutputLine(tail, id: id)
            }
            let out = String(data: outAll as Data, encoding: .utf8) ?? ""
            let err = String(data: errAll as Data, encoding: .utf8) ?? ""
            completion(process.terminationStatus, out, err)
        }
    }

    private let progressRegex = try! NSRegularExpression(
        pattern: #"\[download\]\s+([\d.]+)% of\s+~?([\d.]+)([KMG])?i?B"#
    )
    private let speedRegex = try! NSRegularExpression(
        pattern: #"at\s+([\d.]+)([KMG])i?B/s"#
    )

    private func handleOutputLine(_ line: String, id: UUID) {
        guard let task = tasks[id], !task.cancelled else { return }
        let ns = line as NSString

        if line.contains("[Merger]") {
            report(id: id, phase: "Merging audio & video")
            return
        }
        if line.contains("[ExtractAudio]") {
            report(id: id, phase: "Extracting audio")
            return
        }
        if line.contains("[VideoRemuxer]") || line.contains("[FixupM3u8]") {
            report(id: id, phase: "Finalizing")
            return
        }
        if line.contains("Destination:") {
            report(id: id, phase: "Downloading")
        }

        guard let match = progressRegex.firstMatch(in: line, options: [], range: NSRange(location: 0, length: ns.length)) else {
            return
        }
        let pct = Double(ns.substring(with: match.range(at: 1))) ?? 0
        let value = Double(ns.substring(with: match.range(at: 2))) ?? 0
        let unit = match.range(at: 3).location != NSNotFound
            ? ns.substring(with: match.range(at: 3))
            : ""
        let multiplier: Double
        switch unit {
        case "K": multiplier = 1024
        case "M": multiplier = 1024 * 1024
        case "G": multiplier = 1024 * 1024 * 1024
        default: multiplier = 1
        }
        let total = Int64(value * multiplier)
        let downloaded = Int64(Double(total) * pct / 100)

        var speed: Int64 = 0
        if let s = speedRegex.firstMatch(in: line, options: [], range: NSRange(location: 0, length: ns.length)) {
            let sv = Double(ns.substring(with: s.range(at: 1))) ?? 0
            let su = ns.substring(with: s.range(at: 2))
            let sm: Double
            switch su {
            case "K": sm = 1024
            case "M": sm = 1024 * 1024
            case "G": sm = 1024 * 1024 * 1024
            default: sm = 1
            }
            speed = Int64(sv * sm)
        }
        _ = speed

        let now = Date()
        if now.timeIntervalSince(task.lastReport) >= 0.2 || pct >= 100 {
            var t = task
            t.lastReport = now
            tasks[id] = t
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.mediaProgress(id: id, downloaded: downloaded, total: total, phase: "Downloading")
            }
        }
    }

    private func detectFinalFile(task: TaskState, output: String) -> URL? {
        // 1. yt-dlp --print after_move:filepath prints the final absolute path.
        let finalRegex = try! NSRegularExpression(pattern: #"^(/.*\.(mp4|mkv|webm|m4a|mp3|opus|flac|wav|mov|avi|3gp))$"#, options: [.anchorsMatchLines])
        let ns = output as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = finalRegex.matches(in: output, options: [], range: range)
        if let last = matches.last {
            let path = ns.substring(with: last.range(at: 1))
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        // 2. Fallback: newest file that appeared in the download directory.
        if let directory = downloadDirectory {
            let now = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            let candidates = now.filter { !task.directorySnapshot.contains($0) && !$0.hasSuffix(".part") }
            if let newest = candidates.map({ directory.appendingPathComponent($0) })
                .filter({ FileManager.default.fileExists(atPath: $0.path) })
                .max(by: { fileModification($0) < fileModification($1) }) {
                return newest
            }
        }
        return nil
    }

    private func fileModification(_ url: URL) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
    }

    private func cleanupTemp(task: TaskState) {
        if let tempDir = task.tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    private static func extractError(output: String, errorText: String) -> String {
        let combined = output + "\n" + errorText
        for line in combined.split(separator: "\n").reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("ERROR:") {
                return String(trimmed.dropFirst("ERROR:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        let tail = errorText.split(separator: "\n").suffix(3).joined(separator: " ")
        return tail.isEmpty ? "yt-dlp failed" : String(tail)
    }

    private func report(id: UUID, phase: String) {
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.mediaProgress(id: id, downloaded: 0, total: nil, phase: phase)
        }
    }

    private func finish(id: UUID, destinationURL: URL) {
        cleanupTemp(task: tasks[id] ?? TaskState())
        tasks[id] = nil
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.mediaFinished(id: id, destinationURL: destinationURL)
        }
    }

    private func fail(id: UUID, error: Error) {
        cleanupTemp(task: tasks[id] ?? TaskState())
        tasks[id] = nil
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.mediaFailed(id: id, error: error)
        }
    }
}
