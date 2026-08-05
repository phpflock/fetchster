import Foundation

protocol HTTPDownloadDelegate: AnyObject {
    func httpProgress(id: UUID, downloaded: Int64, total: Int64?, speed: Int64)
    func httpFinished(id: UUID, destinationURL: URL, suggestedName: String?)
    func httpFailed(id: UUID, error: Error?)
}

/// Streaming HTTP downloader that writes to a `.part` file, so failed or
/// paused downloads can be resumed with a byte-range request instead of
/// restarting from scratch.
final class HTTPDownloadManager: NSObject, URLSessionDataDelegate {
    weak var delegate: HTTPDownloadDelegate?
    var downloadDirectory: URL?
    var fallbackName: ((UUID) -> String?)?
    var explicitFilename: ((UUID) -> String?)?
    var absoluteDestination: ((UUID) -> String?)?
    var partialFileURL: ((UUID) -> URL?)?
    var partialFileChanged: ((UUID, URL?) -> Void)?

    private var session: URLSession!
    private var tasks: [UUID: URLSessionDataTask] = [:]
    private var requestHeaders: [UUID: [String: String]] = [:]
    private var handles: [UUID: FileHandle] = [:]
    private var partialURLs: [UUID: URL] = [:]
    private var offsets: [UUID: Int64] = [:]
    private var received: [UUID: Int64] = [:]
    private var expected: [UUID: Int64] = [:]
    private var lastBytes: [UUID: Int64] = [:]
    private var lastSample: [UUID: Date] = [:]

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForRequest = 60
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func start(id: UUID, url: URL, headers: [String: String]?) {
        var request = URLRequest(url: url)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        for (key, value) in headers ?? [:] {
            request.setValue(value, forHTTPHeaderField: key)
        }
        requestHeaders[id] = headers ?? [:]

        var offset: Int64 = 0
        if let partial = partialFileURL?(id) {
            partialURLs[id] = partial
            let size = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.int64Value ?? 0
            offset = size
            if offset > 0 {
                request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            }
        }
        offsets[id] = offset
        received[id] = 0
        expected[id] = 0
        lastBytes[id] = offset
        lastSample[id] = Date()

        let task = session.dataTask(with: request)
        tasks[id] = task
        task.resume()
    }

    func pause(id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
    }

    func cancel(id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        closeHandle(id)
        if let partial = partialURLs[id] {
            try? FileManager.default.removeItem(at: partial)
        }
        partialURLs[id] = nil
        partialFileChanged?(id, nil)
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let id = taskID(for: dataTask) else {
            completionHandler(.cancel)
            return
        }
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        let status = http.statusCode

        if status == 416 {
            // The server can't honor our range — restart the download fresh.
            completionHandler(.cancel)
            closeHandle(id)
            if let partial = partialURLs[id] {
                try? FileManager.default.removeItem(at: partial)
            }
            partialURLs[id] = nil
            offsets[id] = 0
            received[id] = 0
            if let url = dataTask.originalRequest?.url {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.start(id: id, url: url, headers: self?.requestHeaders[id])
                }
            }
            return
        }

        if !(200...299).contains(status) {
            let reason = HTTPURLResponse.localizedString(forStatusCode: status)
            let message = "Server returned HTTP \(status)\(reason.isEmpty ? "" : " (\(reason))")"
            fail(id, NSError(domain: "HTTPStatus", code: status, userInfo: [NSLocalizedDescriptionKey: message]))
            completionHandler(.cancel)
            return
        }

        var offset = offsets[id] ?? 0
        if status == 206 {
            if let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
               let parsed = parseContentRange(contentRange) {
                offset = parsed.start
                offsets[id] = offset
                expected[id] = parsed.total
            } else if http.expectedContentLength > 0 {
                expected[id] = offset + http.expectedContentLength
            }
        } else {
            // 200 — server ignored our range; start over.
            offset = 0
            offsets[id] = 0
            received[id] = 0
            if let partial = partialURLs[id] {
                try? FileManager.default.removeItem(at: partial)
            }
            partialURLs[id] = nil
            expected[id] = http.expectedContentLength > 0 ? http.expectedContentLength : 0
        }

        if partialURLs[id] == nil {
            let name = baseName(for: id, suggested: http.suggestedFilename)
            let partial = partialURL(for: id, name: name)
            partialURLs[id] = partial
            partialFileChanged?(id, partial)
        }
        lastBytes[id] = offset
        lastSample[id] = Date()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let id = taskID(for: dataTask) else { return }
        guard let handle = fileHandle(for: id) else { return }
        handle.write(data)
        received[id] = (received[id] ?? 0) + Int64(data.count)

        let offset = offsets[id] ?? 0
        let downloaded = offset + (received[id] ?? 0)
        let now = Date()
        var speed: Int64 = 0
        if let last = lastSample[id], let lastB = lastBytes[id] {
            let dt = now.timeIntervalSince(last)
            if dt >= 0.8 {
                speed = Int64(Double(downloaded - lastB) / dt)
                lastSample[id] = now
                lastBytes[id] = downloaded
            }
        } else {
            lastSample[id] = now
            lastBytes[id] = downloaded
        }
        let total = (expected[id] ?? 0) > 0 ? expected[id] : nil
        DispatchQueue.main.async {
            self.delegate?.httpProgress(id: id, downloaded: downloaded, total: total, speed: speed)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = taskID(for: task) else { return }
        tasks[id] = nil
        closeHandle(id)

        if let error = error as? URLError, error.code == .cancelled {
            // Paused or removed — the partial file is kept or deleted by the caller.
            return
        }
        if let error {
            DispatchQueue.main.async {
                self.delegate?.httpFailed(id: id, error: error)
            }
            return
        }

        guard let partial = partialURLs[id] else {
            DispatchQueue.main.async {
                self.delegate?.httpFailed(
                    id: id,
                    error: NSError(domain: "HTTPDownload", code: 1, userInfo: [NSLocalizedDescriptionKey: "No file was produced"])
                )
            }
            return
        }

        let suggested = (task.response as? HTTPURLResponse)?.suggestedFilename
        let destination = finalDestination(for: id, suggested: suggested)
        do {
            try FileManager.default.moveItem(at: partial, to: destination)
            partialURLs[id] = nil
            partialFileChanged?(id, nil)
            DispatchQueue.main.async {
                self.delegate?.httpFinished(id: id, destinationURL: destination, suggestedName: suggested)
            }
        } catch {
            DispatchQueue.main.async {
                self.delegate?.httpFailed(id: id, error: error)
            }
        }
    }

    // MARK: - Helpers

    private func fail(_ id: UUID, _ error: Error) {
        closeHandle(id)
        DispatchQueue.main.async {
            self.delegate?.httpFailed(id: id, error: error)
        }
    }

    private func taskID(for task: URLSessionTask) -> UUID? {
        tasks.first(where: { $0.value == task })?.key
    }

    private func closeHandle(_ id: UUID) {
        try? handles[id]?.close()
        handles[id] = nil
    }

    private func fileHandle(for id: UUID) -> FileHandle? {
        if let existing = handles[id] {
            return existing
        }
        guard let partial = partialURLs[id] else { return nil }
        let fm = FileManager.default
        try? fm.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: partial.path) {
            fm.createFile(atPath: partial.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: partial) else { return nil }
        handle.seekToEndOfFile()
        handles[id] = handle
        return handle
    }

    private func baseName(for id: UUID, suggested: String?) -> String {
        if let absolute = absoluteDestination?(id), !absolute.isEmpty {
            return URL(fileURLWithPath: absolute).lastPathComponent
        }
        if let explicit = explicitFilename?(id)?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return explicit
        }
        if let suggested = suggested?.trimmingCharacters(in: .whitespacesAndNewlines), !suggested.isEmpty {
            return suggested
        }
        return fallbackName?(id) ?? "download"
    }

    private func destinationDirectory(for id: UUID) -> URL {
        if let absolute = absoluteDestination?(id), !absolute.isEmpty {
            return URL(fileURLWithPath: absolute).deletingLastPathComponent()
        }
        return downloadDirectory ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    private func partialURL(for id: UUID, name: String) -> URL {
        destinationDirectory(for: id).appendingPathComponent(".\(name).part")
    }

    private func finalDestination(for id: UUID, suggested: String?) -> URL {
        if let absolute = absoluteDestination?(id), !absolute.isEmpty {
            let chosen = URL(fileURLWithPath: absolute)
            try? FileManager.default.createDirectory(at: chosen.deletingLastPathComponent(), withIntermediateDirectories: true)
            return FileUtils.uniqueFileURL(chosen)
        }
        return FileUtils.uniqueDestination(suggestedName: baseName(for: id, suggested: suggested), in: destinationDirectory(for: id))
    }

    private func parseContentRange(_ value: String) -> (start: Int64, total: Int64)? {
        // "bytes 300000-1048575/1048576"
        let parts = value.split(separator: " ")
        guard parts.count == 2, parts[0] == "bytes" else { return nil }
        let range = parts[1].split(separator: "/")
        guard range.count == 2 else { return nil }
        let bounds = range[0].split(separator: "-")
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let total = Int64(range[1]) else { return nil }
        return (start, total)
    }
}
