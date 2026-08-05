import Foundation

enum FileUtils {
    static var appSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Fetchster", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var resumeDirectory: URL {
        let dir = appSupportDirectory.appendingPathComponent("resume", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var stateFileURL: URL {
        appSupportDirectory.appendingPathComponent("downloads.json")
    }

    static func safeFilename(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "_")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func uniqueDestination(suggestedName name: String, in directory: URL) -> URL {
        let fm = FileManager.default
        var base = safeFilename(name)
        if base.isEmpty { base = "download" }
        var candidate = directory.appendingPathComponent(base)
        var counter = 1
        while fm.fileExists(atPath: candidate.path) {
            let ext = (base as NSString).pathExtension
            let stem = (base as NSString).deletingPathExtension
            let newName = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            candidate = directory.appendingPathComponent(newName)
            counter += 1
        }
        return candidate
    }

    static func uniqueFileURL(_ url: URL) -> URL {
        let fm = FileManager.default
        var candidate = url
        var counter = 1
        while fm.fileExists(atPath: candidate.path) {
            let ext = candidate.pathExtension
            let stem = candidate.deletingPathExtension().lastPathComponent
            let directory = candidate.deletingLastPathComponent()
            let newName = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            candidate = directory.appendingPathComponent(newName)
            counter += 1
        }
        return candidate
    }

    static func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func speedString(_ speed: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: speed, countStyle: .file) + "/s"
    }

    static func etaString(_ eta: TimeInterval?) -> String {
        guard let eta, eta.isFinite, eta > 0 else { return "" }
        let total = Int(eta.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return String(format: "%d:%02d", total / 60, total % 60) }
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    static func dateString(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func fileSize(at url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
