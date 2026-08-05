import Foundation

enum DownloadKind: String, Codable {
    case http
    case torrent
    case magnet
    case media
}

enum DownloadStatus: String, Codable {
    case queued
    case downloading
    case paused
    case completed
    case failed
    case seeding
    case removed
}

struct DownloadItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var kind: DownloadKind
    var url: URL?
    var torrentFilePath: String?
    var title: String
    var status: DownloadStatus = .queued
    var progress: Double = 0
    var downloadedBytes: Int64 = 0
    var totalBytes: Int64?
    var speed: Int64 = 0
    var eta: TimeInterval?
    var destinationURL: URL?
    var errorMessage: String?
    var createdAt = Date()
    var completedAt: Date?
    var resumeDataFile: String?
    var ariaGID: String?
    var httpHeaders: [String: String]?
    var explicitFilename: String?
    var absoluteDestination: String?
    var partialFilePath: String?
    // Torrent-only live stats (fed by aria2 polling; 0/nil until known).
    var seeders: Int = 0
    var peers: Int = 0
    var uploadSpeed: Int64 = 0
    var uploadedBytes: Int64 = 0
    var infoHash: String?
    // Media (HLS/DASH) downloads.
    var mediaMode: String?
    var mediaURLs: [String]?
    var mediaHeaders: [String: String]?
    var mediaLabel: String?
    var mediaPhase: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, url, torrentFilePath, title, status, progress
        case downloadedBytes, totalBytes, speed, eta, destinationURL
        case errorMessage, createdAt, completedAt, resumeDataFile, ariaGID
        case httpHeaders, explicitFilename, absoluteDestination, partialFilePath
        case seeders, peers, uploadSpeed, uploadedBytes, infoHash
        case mediaMode, mediaURLs, mediaHeaders, mediaLabel, mediaPhase
    }

    init(
        id: UUID = UUID(),
        kind: DownloadKind,
        url: URL? = nil,
        torrentFilePath: String? = nil,
        title: String,
        status: DownloadStatus = .queued,
        progress: Double = 0,
        downloadedBytes: Int64 = 0,
        totalBytes: Int64? = nil,
        speed: Int64 = 0,
        eta: TimeInterval? = nil,
        destinationURL: URL? = nil,
        errorMessage: String? = nil,
        createdAt: Date = Date(),
        completedAt: Date? = nil,
        resumeDataFile: String? = nil,
        ariaGID: String? = nil,
        httpHeaders: [String: String]? = nil,
        explicitFilename: String? = nil,
        absoluteDestination: String? = nil,
        partialFilePath: String? = nil,
        mediaMode: String? = nil,
        mediaURLs: [String]? = nil,
        mediaHeaders: [String: String]? = nil,
        mediaLabel: String? = nil,
        mediaPhase: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.url = url
        self.torrentFilePath = torrentFilePath
        self.title = title
        self.status = status
        self.progress = progress
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.speed = speed
        self.eta = eta
        self.destinationURL = destinationURL
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.resumeDataFile = resumeDataFile
        self.ariaGID = ariaGID
        self.httpHeaders = httpHeaders
        self.explicitFilename = explicitFilename
        self.absoluteDestination = absoluteDestination
        self.partialFilePath = partialFilePath
        self.mediaMode = mediaMode
        self.mediaURLs = mediaURLs
        self.mediaHeaders = mediaHeaders
        self.mediaLabel = mediaLabel
        self.mediaPhase = mediaPhase
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decodeIfPresent(DownloadKind.self, forKey: .kind) ?? .http
        url = try c.decodeIfPresent(URL.self, forKey: .url)
        torrentFilePath = try c.decodeIfPresent(String.self, forKey: .torrentFilePath)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Download"
        status = try c.decodeIfPresent(DownloadStatus.self, forKey: .status) ?? .queued
        progress = try c.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        downloadedBytes = try c.decodeIfPresent(Int64.self, forKey: .downloadedBytes) ?? 0
        totalBytes = try c.decodeIfPresent(Int64.self, forKey: .totalBytes)
        speed = try c.decodeIfPresent(Int64.self, forKey: .speed) ?? 0
        eta = try c.decodeIfPresent(TimeInterval.self, forKey: .eta)
        destinationURL = try c.decodeIfPresent(URL.self, forKey: .destinationURL)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        resumeDataFile = try c.decodeIfPresent(String.self, forKey: .resumeDataFile)
        ariaGID = try c.decodeIfPresent(String.self, forKey: .ariaGID)
        httpHeaders = try c.decodeIfPresent([String: String].self, forKey: .httpHeaders)
        explicitFilename = try c.decodeIfPresent(String.self, forKey: .explicitFilename)
        absoluteDestination = try c.decodeIfPresent(String.self, forKey: .absoluteDestination)
        partialFilePath = try c.decodeIfPresent(String.self, forKey: .partialFilePath)
        seeders = try c.decodeIfPresent(Int.self, forKey: .seeders) ?? 0
        peers = try c.decodeIfPresent(Int.self, forKey: .peers) ?? 0
        uploadSpeed = try c.decodeIfPresent(Int64.self, forKey: .uploadSpeed) ?? 0
        uploadedBytes = try c.decodeIfPresent(Int64.self, forKey: .uploadedBytes) ?? 0
        infoHash = try c.decodeIfPresent(String.self, forKey: .infoHash)
        mediaMode = try c.decodeIfPresent(String.self, forKey: .mediaMode)
        mediaURLs = try c.decodeIfPresent([String].self, forKey: .mediaURLs)
        mediaHeaders = try c.decodeIfPresent([String: String].self, forKey: .mediaHeaders)
        mediaLabel = try c.decodeIfPresent(String.self, forKey: .mediaLabel)
        mediaPhase = try c.decodeIfPresent(String.self, forKey: .mediaPhase)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(torrentFilePath, forKey: .torrentFilePath)
        try c.encode(title, forKey: .title)
        try c.encode(status, forKey: .status)
        try c.encode(progress, forKey: .progress)
        try c.encode(downloadedBytes, forKey: .downloadedBytes)
        try c.encodeIfPresent(totalBytes, forKey: .totalBytes)
        try c.encode(speed, forKey: .speed)
        try c.encodeIfPresent(eta, forKey: .eta)
        try c.encodeIfPresent(destinationURL, forKey: .destinationURL)
        try c.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(completedAt, forKey: .completedAt)
        try c.encodeIfPresent(resumeDataFile, forKey: .resumeDataFile)
        try c.encodeIfPresent(ariaGID, forKey: .ariaGID)
        try c.encodeIfPresent(httpHeaders, forKey: .httpHeaders)
        try c.encodeIfPresent(explicitFilename, forKey: .explicitFilename)
        try c.encodeIfPresent(absoluteDestination, forKey: .absoluteDestination)
        try c.encodeIfPresent(partialFilePath, forKey: .partialFilePath)
        try c.encode(seeders, forKey: .seeders)
        try c.encode(peers, forKey: .peers)
        try c.encode(uploadSpeed, forKey: .uploadSpeed)
        try c.encode(uploadedBytes, forKey: .uploadedBytes)
        try c.encodeIfPresent(infoHash, forKey: .infoHash)
        try c.encodeIfPresent(mediaMode, forKey: .mediaMode)
        try c.encodeIfPresent(mediaURLs, forKey: .mediaURLs)
        try c.encodeIfPresent(mediaHeaders, forKey: .mediaHeaders)
        try c.encodeIfPresent(mediaLabel, forKey: .mediaLabel)
        try c.encodeIfPresent(mediaPhase, forKey: .mediaPhase)
    }
}

struct TorrentSnapshot {
    var gid: String
    var status: String
    var totalLength: Int64
    var completedLength: Int64
    var downloadSpeed: Int64
    var uploadSpeed: Int64
    var name: String?
    var errorMessage: String?
    var numSeeders: Int
    var infoHash: String?
    var uploadLength: Int64 = 0
    var connections: Int = 0
    // For magnet/.torrent URLs, the first download is just the metadata
    // (a few KB). When it finishes, aria2 starts the real content download
    // and reports its gid here.
    var followedBy: [String] = []
    // File names of the download; the metadata download's file is named
    // "[METADATA]<name>" and must not be treated as real content.
    var fileNames: [String] = []
}

/// A single playable stream detected on a web page (video grab).
struct DetectedMediaStream: Codable, Identifiable, Equatable {
    var id = UUID()
    var url: String
    var mime: String?
    var size: Int64?
    var label: String?
    var referer: String?
    var userAgent: String?
    var cookies: String?
    var kind: String? // "direct" | "hls" | "dash"
    var manifestBody: String? // captured manifest body (YouTube UMP etc.)
    var headers: [String: String]? // full request headers captured by the browser
    var formatId: String? // yt-dlp format spec for YouTube rows
    var browser: String? // browser name for yt-dlp --cookies-from-browser

    var displayLabel: String {
        if let label, !label.isEmpty { return label }
        if kind == "hls" { return "HLS" }
        if kind == "dash" { return "DASH" }
        if let mime, !mime.isEmpty {
            return mime.split(separator: "/").last?.uppercased() ?? "VIDEO"
        }
        let ext = (url as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "VIDEO" : ext
    }
}

/// The set of streams detected on one page/tab.
struct DetectedMedia: Codable, Equatable, Identifiable {
    var id = UUID()
    var pageTitle: String?
    var pageURL: String?
    var streams: [DetectedMediaStream]
}
