import Foundation
import Combine

/// A downloader binary the app can fetch on demand.
enum EngineBinary: String, CaseIterable {
    case aria2   // torrents
    case ytdlp   // YouTube (and other yt-dlp sites)
    case ffmpeg  // muxing + HLS/DASH assembly

    var fileName: String {
        switch self {
        case .aria2: return "aria2c"
        case .ytdlp: return "yt-dlp"
        case .ffmpeg: return "ffmpeg"
        }
    }

    /// Relative path inside the engines directory.
    var relativePath: String {
        self == .aria2 ? "aria2/aria2c" : fileName
    }

    /// The download is an archive that must be extracted first.
    var isZip: Bool {
        self != .ytdlp
    }

    /// Official download sources, tried in order. yt-dlp and ffmpeg publish
    /// macOS binaries upstream, so we never need to host or update them.
    var defaultURLs: [String] {
        switch self {
        case .ytdlp:
            // Official standalone universal binary (no Python needed).
            return ["https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos"]
        case .ffmpeg:
            // ffmpeg.org's recommended macOS static builds: evermeet.cx
            // (canonical, always latest), with osxexperts.net as fallback.
            return [
                "https://evermeet.cx/ffmpeg/getrelease/ffmpeg/zip",
                "https://www.osxexperts.net/ffmpeg81arm.zip",
            ]
        case .aria2:
            // No official macOS binary; hosted on the Fetchster GitHub release.
            return ["https://github.com/phpflock/fetchster/releases/latest/download/aria2.zip"]
        }
    }

    var verifyArguments: [String] {
        self == .ffmpeg ? ["-version"] : ["--version"]
    }
}

enum EngineState: Equatable {
    case missing
    case downloading(Double)
    case ready(URL)
    case failed(String)
}

/// Downloads and verifies the optional engines (aria2, yt-dlp, ffmpeg) on
/// demand, so the shipped app stays small. Binaries live in
/// ~/Library/Application Support/Fetchster/engines/ and are fetched from a
/// configurable base URL (UserDefaults "engineBaseURL") when a feature is
/// enabled in Settings.
final class EngineManager: ObservableObject {
    static let shared = EngineManager()

    @Published private(set) var states: [EngineBinary: EngineState] = [:]

    private static let torrentKey = "engine.torrent.enabled"
    private static let mediaKey = "engine.media.enabled"
    private let queue = DispatchQueue(label: "EngineManager")
    private var downloadDelegates: [EngineBinary: DownloadDelegate] = [:]

    private init() {}

    // MARK: - Feature toggles

    var torrentEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.torrentKey)
    }

    var mediaEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.mediaKey)
    }

    func setTorrentEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.torrentKey)
        objectWillChange.send()
    }

    func setMediaEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.mediaKey)
        objectWillChange.send()
    }

    // MARK: - Locations

    static func enginesDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fetchster", isDirectory: true)
        let dir = base.appendingPathComponent("engines", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func installedURL(_ binary: EngineBinary) -> URL? {
        let url = Self.enginesDirectory().appendingPathComponent(binary.relativePath)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// True if the binary exists in the app bundle (dev builds that still
    /// bundle engines can seed the engines directory from it).
    private func bundledURL(_ binary: EngineBinary) -> URL? {
        let url = Bundle.main.resourceURL?.appendingPathComponent(binary.fileName)
        guard let url, FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    func state(for binary: EngineBinary) -> EngineState {
        states[binary] ?? .missing
    }

    // MARK: - Ensure / download

    func ensure(_ binary: EngineBinary, completion: ((EngineState) -> Void)? = nil) {
        if let installed = installedURL(binary) {
            setState(.ready(installed), for: binary)
            completion?(.ready(installed))
            return
        }
        if let bundled = bundledURL(binary) {
            queue.async { [weak self] in
                guard let self else { return }
                let target = Self.enginesDirectory().appendingPathComponent(binary.relativePath)
                if binary == .aria2 {
                    self.installAria2FromBundle(bundled)
                } else {
                    try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? FileManager.default.copyItem(at: bundled, to: target)
                    self.makeExecutable(target)
                }
                self.finishInstall(binary)
                if let url = self.installedURL(binary) {
                    completion?(.ready(url))
                } else {
                    self.setState(.failed("Could not copy engine from app bundle"), for: binary)
                    completion?(self.state(for: binary))
                }
            }
            return
        }
        download(binary, completion: completion)
    }

    private func download(_ binary: EngineBinary, completion: ((EngineState) -> Void)?) {
        setState(.downloading(0), for: binary)
        let urls = candidateURLs(for: binary)
        guard !urls.isEmpty else {
            let message = binary == .aria2
                ? "No torrent engine source configured (aria2 has no official macOS build)"
                : "No download source configured for \(binary.fileName)"
            setState(.failed(message), for: binary)
            completion?(state(for: binary))
            return
        }
        attemptDownload(binary, urls: urls, index: 0, completion: completion)
    }

    private func attemptDownload(_ binary: EngineBinary,
                                 urls: [URL],
                                 index: Int,
                                 completion: ((EngineState) -> Void)?) {
        guard index < urls.count else {
            setState(.failed("All download sources failed"), for: binary)
            completion?(state(for: binary))
            return
        }
        let url = urls[index]
        queue.async { [weak self] in
            guard let self else { return }
            let delegate = DownloadDelegate()
            self.downloadDelegates[binary] = delegate
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 30 * 60
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            let task = session.downloadTask(with: url)
            delegate.progress = { [weak self] fraction in
                DispatchQueue.main.async {
                    self?.setState(.downloading(fraction), for: binary)
                }
            }
            delegate.completion = { [weak self] result in
                session.invalidateAndCancel()
                guard let self else { return }
                self.queue.async {
                    self.downloadDelegates[binary] = nil
                }
                switch result {
                case .success(let tempURL):
                    self.installDownloaded(binary, tempURL: tempURL)
                    if let installed = self.installedURL(binary) {
                        completion?(.ready(installed))
                    } else {
                        self.setState(.failed("Engine install failed"), for: binary)
                        self.queue.async {
                            self.attemptDownload(binary, urls: urls, index: index + 1, completion: completion)
                        }
                    }
                case .failure(let error):
                    if index + 1 < urls.count {
                        self.setState(.downloading(0), for: binary)
                        self.attemptDownload(binary, urls: urls, index: index + 1, completion: completion)
                    } else {
                        self.setState(.failed(error.localizedDescription), for: binary)
                        completion?(self.state(for: binary))
                    }
                }
            }
            task.resume()
        }
    }

    private func candidateURLs(for binary: EngineBinary) -> [URL] {
        // Per-engine override: UserDefaults "engine.<name>.url".
        if let override = UserDefaults.standard.string(forKey: "engine.\(binary.rawValue).url"),
           !override.isEmpty,
           let url = URL(string: override) {
            return [url]
        }
        return binary.defaultURLs.compactMap { URL(string: $0) }
    }

    private func installDownloaded(_ binary: EngineBinary, tempURL: URL) {
        let engines = Self.enginesDirectory()
        if binary == .ytdlp {
            let target = engines.appendingPathComponent(binary.relativePath)
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.moveItem(at: tempURL, to: target)
            makeExecutable(target)
        } else if binary == .aria2 {
            let target = engines.appendingPathComponent("aria2", isDirectory: true)
            try? FileManager.default.removeItem(at: target)
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", tempURL.path, target.path]
            try? ditto.run()
            ditto.waitUntilExit()
            makeExecutable(target.appendingPathComponent("aria2c"))
        } else {
            // ffmpeg: the official builds ship as a zip containing "ffmpeg".
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("fetchster-ffmpeg-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", tempURL.path, staging.path]
            try? ditto.run()
            ditto.waitUntilExit()
            let target = engines.appendingPathComponent(binary.relativePath)
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.moveItem(at: staging.appendingPathComponent(binary.fileName), to: target)
            makeExecutable(target)
            try? FileManager.default.removeItem(at: staging)
        }
        finishInstall(binary)
    }

    private func makeExecutable(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        // Downloaded files may carry quarantine/provenance attributes that
        // Gatekeeper would otherwise block.
        for attr in ["com.apple.quarantine", "com.apple.provenance"] {
            let xattr = Process()
            xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattr.arguments = ["-dr", attr, url.path]
            try? xattr.run()
            xattr.waitUntilExit()
        }
    }

    private func installAria2FromBundle(_ bundled: URL) {
        let engines = Self.enginesDirectory()
        let target = engines.appendingPathComponent("aria2", isDirectory: true)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: bundled, to: target.appendingPathComponent("aria2c"))
        makeExecutable(target.appendingPathComponent("aria2c"))
        // Also copy the bundle's dylibs next to the binary so it can find them.
        let frameworks = Bundle.main.resourceURL?.appendingPathComponent("../Frameworks", isDirectory: true)
        if let frameworks {
            let dylibs = (try? FileManager.default.contentsOfDirectory(atPath: frameworks.path)) ?? []
            for name in dylibs where name.hasSuffix(".dylib") {
                try? FileManager.default.copyItem(
                    at: frameworks.appendingPathComponent(name),
                    to: target.appendingPathComponent(name)
                )
            }
        }
    }

    private func finishInstall(_ binary: EngineBinary) {
        guard let installed = installedURL(binary) else {
            setState(.failed("Engine install failed"), for: binary)
            return
        }
        let ok = verify(binary, at: installed)
        DispatchQueue.main.async { [weak self] in
            if ok {
                self?.setState(.ready(installed), for: binary)
            } else {
                try? FileManager.default.removeItem(at: installed.deletingLastPathComponent())
                self?.setState(.failed("Downloaded engine failed verification"), for: binary)
            }
        }
    }

    private func verify(_ binary: EngineBinary, at url: URL) -> Bool {
        let process = Process()
        process.executableURL = url
        process.arguments = binary.verifyArguments
        if binary == .aria2 {
            var env = ProcessInfo.processInfo.environment
            let dir = url.deletingLastPathComponent().path
            env["DYLD_LIBRARY_PATH"] = dir
            // The aria2 build needs OpenSSL 3's `legacy` provider, which ships
            // as a separate module (ossl-modules/legacy.dylib) in the release
            // zip. Point OpenSSL at it or aria2 aborts on startup.
            env["OPENSSL_MODULES"] = "\(dir)/ossl-modules"
            process.environment = env
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            NSLog("aria2 verification failed (exit %d): %@",
                  process.terminationStatus, stderr)
        }
        return process.terminationStatus == 0
    }

    private func setState(_ state: EngineState, for binary: EngineBinary) {
        DispatchQueue.main.async {
            self.states[binary] = state
            self.objectWillChange.send()
        }
    }
}

/// URLSession delegate that reports download progress and completion.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    var progress: ((Double) -> Void)?
    var completion: ((Result<URL, Error>) -> Void)?

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            progress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        completion?(.success(location))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            completion?(.failure(error))
        }
    }
}
