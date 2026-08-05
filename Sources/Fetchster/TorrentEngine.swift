import Foundation
import Combine

final class TorrentEngine: ObservableObject {
    static let shared = TorrentEngine()

    @Published var available = false
    @Published var snapshots: [String: TorrentSnapshot] = [:]

    private let port: UInt16 = 6800
    private var daemon: Process?
    private var session: URLSession
    private var pollTimer: Timer?

    private var token: String {
        if let existing = UserDefaults.standard.string(forKey: "aria2Token") {
            return existing
        }
        let fresh = "fetchster-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
        UserDefaults.standard.set(fresh, forKey: "aria2Token")
        return fresh
    }

    private var rpcURL: URL {
        URL(string: "http://127.0.0.1:\(port)/jsonrpc")!
    }

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        session = URLSession(configuration: config)
    }

    static func locateBinary() -> URL? {
        let fm = FileManager.default
        let candidates = [
            EngineManager.enginesDirectory().appendingPathComponent("aria2/aria2c"),
            URL(fileURLWithPath: "/opt/homebrew/bin/aria2c"),
            URL(fileURLWithPath: "/usr/local/bin/aria2c"),
        ]
        for candidate in candidates.compactMap({ $0 }) where fm.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for dir in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("aria2c")
            if fm.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Lifecycle

    func ensureRunning(downloadDir: URL, completion: @escaping (Bool) -> Void) {
        if daemonIsAlive() {
            // The process exists, but its RPC port may still be binding right
            // after launch; confirm it's reachable before reporting ready so
            // an immediately-added download doesn't fail.
            waitForRPC(attempts: 10) { [weak self] ok in
                self?.available = ok
                completion(ok)
            }
            return
        }
        if let binary = Self.locateBinary(), daemon == nil {
            launchDaemon(binary, downloadDir: downloadDir)
        }
        waitForRPC(attempts: 20) { [weak self] ok in
            guard let self else {
                completion(false)
                return
            }
            self.available = ok
            completion(ok)
        }
    }

    func shutdown() {
        pollTimer?.invalidate()
        pollTimer = nil
        rpc("aria2.shutdown", params: ["token:\(token)"]) { _ in }
        daemon?.terminate()
        daemon = nil
    }

    /// Relaunch the daemon with a different download directory. Only call
    /// this when no torrents are active — in-flight downloads are lost when
    /// the daemon exits.
    func restart(downloadDir: URL) {
        guard daemonIsAlive() else {
            ensureRunning(downloadDir: downloadDir) { _ in }
            return
        }
        pollTimer?.invalidate()
        pollTimer = nil
        let old = daemon
        daemon = nil
        rpc("aria2.shutdown", params: ["token:\(token)"]) { _ in }
        old?.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.ensureRunning(downloadDir: downloadDir) { _ in }
        }
    }

    private func launchDaemon(_ binary: URL, downloadDir: URL) {
        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "--enable-rpc",
            "--rpc-listen-port=\(port)",
            "--rpc-secret=\(token)",
            "--rpc-allow-origin-all=true",
            "--dir=\(downloadDir.path)",
            "--max-concurrent-downloads=5",
            "--continue=true",
            "--check-integrity=true",
            "--file-allocation=none",
            // Seed forever after completion (ratio 0). The user stops
            // seeding explicitly via pause/remove. NOTE: --seed-time=0
            // disables seeding, so it must not be passed alongside this.
            "--seed-ratio=0",
            "--enable-dht=true",
            "--dht-listen-port=6881-6999",
            "--enable-peer-exchange=true",
            "--bt-enable-lpd=true",
            "--listen-port=6881-6999",
            "--bt-save-metadata=true",
            "--summary-interval=0",
            "--console-log-level=error",
            "--quiet=true",
            "--enable-color=false",
        ]
        process.terminationHandler = { [weak self] _ in
            self?.daemon = nil
        }
        // On-demand installs live next to their dylibs; point the loader at them.
        if binary.path.contains("/engines/") {
            var env = ProcessInfo.processInfo.environment
            env["DYLD_LIBRARY_PATH"] = binary.deletingLastPathComponent().path
            process.environment = env
        }
        do {
            try process.run()
            daemon = process
        } catch {
            daemon = nil
        }
    }

    private func daemonIsAlive() -> Bool {
        daemon?.isRunning == true
    }

    private func waitForRPC(attempts: Int, completion: @escaping (Bool) -> Void) {
        ping { ok in
            if ok {
                completion(true)
                return
            }
            guard attempts > 0 else {
                completion(false)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.waitForRPC(attempts: attempts - 1, completion: completion)
            }
        }
    }

    private func ping(completion: @escaping (Bool) -> Void) {
        rpc("aria2.getVersion", params: ["token:\(token)"]) { result in
            completion((try? result.get()) != nil)
        }
    }

    // MARK: - Download control

    func addURI(uri: String, downloadDir: URL, completion: @escaping (String?) -> Void) {
        // seed-ratio 0 = seed forever after completion (per-download, so it
        // applies even when talking to a daemon launched by an older build).
        rpc("aria2.addUri", params: ["token:\(token)", [uri], ["dir": downloadDir.path, "seed-ratio": "0"]]) { result in
            switch result {
            case .success(let value):
                completion(value as? String)
            case .failure:
                completion(nil)
            }
        }
    }

    func addTorrentFile(at fileURL: URL, downloadDir: URL, completion: @escaping (String?) -> Void) {
        guard let data = try? Data(contentsOf: fileURL) else {
            completion(nil)
            return
        }
        let base64 = data.base64EncodedString()
        // Note: this aria2 build rejects any third parameter on addTorrent,
        // so no options dict here — the daemon's --dir (set at launch) is
        // the download folder, and seeding is enforced via changeOption below.
        rpc("aria2.addTorrent", params: ["token:\(token)", base64]) { result in
            switch result {
            case .success(let value):
                let gid = value as? String
                if let gid {
                    self.changeOption(gid: gid, options: ["seed-ratio": "0"]) { _ in
                        completion(gid)
                    }
                } else {
                    completion(nil)
                }
            case .failure:
                completion(nil)
            }
        }
    }

    private func changeOption(gid: String, options: [String: String], completion: @escaping (Bool) -> Void) {
        rpc("aria2.changeOption", params: ["token:\(token)", gid, options]) { result in
            switch result {
            case .success:
                completion(true)
            case .failure:
                completion(false)
            }
        }
    }

    func pause(_ gid: String) {
        rpc("aria2.pause", params: ["token:\(token)", gid]) { _ in }
    }

    func unpause(_ gid: String) {
        rpc("aria2.unpause", params: ["token:\(token)", gid]) { _ in }
    }

    func remove(_ gid: String) {
        rpc("aria2.remove", params: ["token:\(token)", gid]) { _ in }
    }

    /// Whether the daemon still tracks this gid (so a relaunch doesn't
    /// duplicate an in-flight download when the daemon survived). A
    /// completed metadata gid with a follow-up still counts: polling will
    /// re-link the item to the real content gid.
    func hasDownload(gid: String, completion: @escaping (Bool) -> Void) {
        rpc("aria2.tellStatus", params: ["token:\(token)", gid]) { result in
            guard case .success(let value) = result,
                  let dict = value as? [String: Any] else {
                completion(false)
                return
            }
            let status = dict["status"] as? String ?? ""
            let followedBy = (dict["followedBy"] as? [String]) ?? []
            let alive = status == "active" || status == "waiting" || status == "paused"
                || (status == "complete" && !followedBy.isEmpty)
            completion(alive)
        }
    }

    /// Force a re-announce to the torrent's current trackers. If the torrent
    /// has no trackers (e.g. a bare magnet), a small set of public trackers
    /// is added so the swarm is still reachable. Completion's Bool is whether
    /// the tracker list was updated; the message explains what happened.
    func updateTrackers(gid: String, completion: @escaping (Bool, String) -> Void) {
        rpc("aria2.tellStatus", params: ["token:\(token)", gid]) { [weak self] result in
            guard let self else {
                completion(false, "Engine unavailable")
                return
            }
            guard case .success(let value) = result,
                  let dict = value as? [String: Any],
                  let bt = dict["bittorrent"] as? [String: Any] else {
                completion(false, "Could not read tracker list")
                return
            }
            var trackers: [String] = []
            if let groups = bt["announceList"] as? [[String]] {
                trackers = groups.flatMap { $0 }
            }
            var message = "Trackers updated — re-announced"
            if trackers.isEmpty {
                trackers = Self.publicTrackers
                message = "No trackers found — added public trackers"
            }
            self.rpc("aria2.changeOption", params: ["token:\(self.token)", gid, ["bt-tracker": trackers.joined(separator: ",")]]) { result in
                switch result {
                case .success:
                    completion(true, message)
                case .failure(let error):
                    completion(false, error.localizedDescription)
                }
            }
        }
    }

    /// Paths of all files of a download, for delete-on-remove.
    func filePaths(gid: String, completion: @escaping ([String]) -> Void) {
        rpc("aria2.getFiles", params: ["token:\(token)", gid]) { result in
            guard case .success(let value) = result,
                  let files = value as? [[String: Any]] else {
                completion([])
                return
            }
            completion(files.compactMap { $0["path"] as? String })
        }
    }

    private static let publicTrackers = [
        "udp://tracker.opentrackr.org:1337/announce",
        "udp://open.tracker.cl:1337/announce",
        "udp://tracker.openbittorrent.com:6969/announce",
        "udp://exodus.desync.com:6969/announce",
    ]

    // MARK: - Polling

    func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollOnce()
        }
        pollOnce()
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollOnce() {
        var merged: [String: TorrentSnapshot] = [:]
        let lock = NSLock()
        let group = DispatchGroup()

        group.enter()
        rpc("aria2.tellActive", params: ["token:\(token)"]) { result in
            defer { group.leave() }
            if case .success(let value) = result, let list = value as? [[String: Any]] {
                for dict in list {
                    if let snap = self.snapshot(from: dict) {
                        lock.lock()
                        merged[snap.gid] = snap
                        lock.unlock()
                    }
                }
            }
        }

        group.enter()
        rpc("aria2.tellWaiting", params: ["token:\(token)", 0, 100]) { result in
            defer { group.leave() }
            if case .success(let value) = result, let list = value as? [[String: Any]] {
                for dict in list {
                    if let snap = self.snapshot(from: dict) {
                        lock.lock()
                        merged[snap.gid] = snap
                        lock.unlock()
                    }
                }
            }
        }

        group.enter()
        rpc("aria2.tellStopped", params: ["token:\(token)", 0, 100]) { result in
            defer { group.leave() }
            if case .success(let value) = result, let list = value as? [[String: Any]] {
                for dict in list {
                    if let snap = self.snapshot(from: dict) {
                        lock.lock()
                        merged[snap.gid] = snap
                        lock.unlock()
                    }
                }
            }
        }

        group.notify(queue: .main) {
            self.snapshots = merged
        }
    }

    private func snapshot(from dict: [String: Any]) -> TorrentSnapshot? {
        guard let gid = dict["gid"] as? String, let status = dict["status"] as? String else {
            return nil
        }
        func i64(_ key: String) -> Int64 {
            Int64(dict[key] as? String ?? "") ?? 0
        }
        func intValue(_ key: String) -> Int {
            if let v = dict[key] as? Int { return v }
            return Int(dict[key] as? String ?? "") ?? 0
        }
        let name: String? = {
            guard let bt = dict["bittorrent"] as? [String: Any],
                  let info = bt["info"] as? [String: Any] else {
                return nil
            }
            return info["name"] as? String
        }()
        let fileNames: [String] = (dict["files"] as? [[String: Any]])?
            .compactMap { file in
                guard let path = file["path"] as? String else { return nil }
                return (path as NSString).lastPathComponent
            } ?? []
        return TorrentSnapshot(
            gid: gid,
            status: status,
            totalLength: i64("totalLength"),
            completedLength: i64("completedLength"),
            downloadSpeed: i64("downloadSpeed"),
            uploadSpeed: i64("uploadSpeed"),
            name: name,
            errorMessage: dict["errorMessage"] as? String,
            numSeeders: intValue("numSeeders"),
            infoHash: dict["infoHash"] as? String,
            uploadLength: i64("uploadLength"),
            connections: intValue("connections"),
            followedBy: (dict["followedBy"] as? [String]) ?? [],
            fileNames: fileNames
        )
    }

    // MARK: - RPC core

    private func rpc(_ method: String, params: [Any], completion: @escaping (Result<Any, Error>) -> Void) {
        var request = URLRequest(url: rpcURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": "req-\(UUID().uuidString)",
            "method": method,
            "params": params,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            completion(.failure(NSError(domain: "TorrentEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid request"])))
            return
        }
        request.httpBody = body

        session.dataTask(with: request) { data, _, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(NSError(domain: "aria2", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid RPC response"])))
                return
            }
            if let errorDict = json["error"] as? [String: Any],
               let message = errorDict["message"] as? String {
                completion(.failure(NSError(domain: "aria2", code: 3, userInfo: [NSLocalizedDescriptionKey: message])))
            } else if let result = json["result"] {
                completion(.success(result))
            } else {
                completion(.failure(NSError(domain: "aria2", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unknown RPC response"])))
            }
        }.resume()
    }
}
