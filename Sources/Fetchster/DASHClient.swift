import Foundation

/// One quality/format inside a DASH manifest.
struct DashRepresentation: Identifiable, Equatable {
    var id: String
    var mimeType: String
    var codec: String
    var height: Int
    var bandwidth: Int64
    var segments: [URL]
    var initialization: URL?
    // SegmentTemplate expansion state (internal).
    var templateURLs: [URL] = []
    var segmentDuration: TimeInterval = 0

    var isAudio: Bool {
        mimeType.hasPrefix("audio/")
    }

    var displayLabel: String {
        if isAudio {
            let fmt = mimeType.contains("webm") ? "Opus" : "AAC"
            return "\(fmt) audio"
        }
        if height > 0 {
            return "\(height)p MP4"
        }
        return "MP4"
    }

    var totalBytes: Int64? {
        // Unknown until segments are fetched (no sizes in the manifest).
        nil
    }
}

/// Parses MPEG-DASH MPD manifests (YouTube and most DASH sites). Handles both
/// SegmentList (YouTube's on-demand profile, absolute segment URLs) and
/// SegmentTemplate ($Number$/$RepresentationID$, used by many CDNs).
final class DASHClient {
    struct Manifest {
        var video: [DashRepresentation] = []
        var audio: [DashRepresentation] = []
        var durationSeconds: TimeInterval?
    }

    func fetchManifest(url: URL, headers: [String: String]?, completion: @escaping (Manifest?) -> Void) {
        var request = URLRequest(url: url)
        for (key, value) in headers ?? [:] {
            request.setValue(value, forHTTPHeaderField: key)
        }
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data, error == nil else {
                completion(nil)
                return
            }
            guard let text = String(data: data, encoding: .utf8) else {
                completion(nil)
                return
            }
            let manifest = self.parse(mpd: text, baseURL: url)
            completion(manifest)
        }.resume()
    }

    func parse(mpd: String, baseURL: URL) -> Manifest? {
        guard let data = mpd.data(using: .utf8) else { return nil }
        let parser = MPDParser()
        guard parser.parse(data: data) else { return nil }
        let duration = parser.durationSeconds
        var manifest = Manifest(durationSeconds: duration)

        for rep in parser.representations {
            if rep.isAudio {
                manifest.audio.append(rep)
            } else {
                manifest.video.append(rep)
            }
        }

        // If a representation used a SegmentTemplate without an explicit
        // segment list, expand it now that we know the period duration.
        if let duration {
            manifest.video = manifest.video.map { expandTemplate($0, duration: duration) }
            manifest.audio = manifest.audio.map { expandTemplate($0, duration: duration) }
        }
        // Any remaining template-generated URLs become the segment list
        // (covers manifests with a timeline but no period duration).
        manifest.video = manifest.video.map { assignTemplateSegments($0) }
        manifest.audio = manifest.audio.map { assignTemplateSegments($0) }
        // Resolve every relative URL against the manifest's base URL.
        let resolve: (URL) -> URL = { self.absolutize($0, against: baseURL) }
        manifest.video = manifest.video.map { rep in resolveURLs(in: rep, using: resolve) }
        manifest.audio = manifest.audio.map { rep in resolveURLs(in: rep, using: resolve) }

        return manifest
    }

    private func resolveURLs(in rep: DashRepresentation, using resolve: (URL) -> URL) -> DashRepresentation {
        var rep = rep
        rep.segments = rep.segments.map(resolve)
        rep.templateURLs = rep.templateURLs.map(resolve)
        if let initURL = rep.initialization {
            rep.initialization = resolve(initURL)
        }
        return rep
    }

    private func absolutize(_ url: URL, against base: URL) -> URL {
        guard url.scheme == nil else { return url }
        return URL(string: url.relativeString, relativeTo: base)?.absoluteURL ?? url
    }

    private func expandTemplate(_ rep: DashRepresentation, duration: TimeInterval) -> DashRepresentation {
        var rep = rep
        guard rep.segments.isEmpty, !rep.templateURLs.isEmpty else { return rep }
        if rep.segmentDuration > 0 {
            let count = max(1, Int(ceil(duration / rep.segmentDuration)))
            rep.segments = rep.templateURLs.prefix(count).map { $0 }
            rep.templateURLs = []
        }
        return rep
    }

    private func assignTemplateSegments(_ rep: DashRepresentation) -> DashRepresentation {
        var rep = rep
        guard rep.segments.isEmpty, !rep.templateURLs.isEmpty else { return rep }
        rep.segments = rep.templateURLs
        rep.templateURLs = []
        return rep
    }
}

// MARK: - MPD XML parsing

private final class MPDParser: NSObject, XMLParserDelegate {
    var representations: [DashRepresentation] = []
    var durationSeconds: TimeInterval?

    private var current: RepState?
    private var elementStack: [String] = []

    private struct RepState {
        var representation: DashRepresentation
        var baseURL = ""
        var segments: [String] = []
        var template: String?
        var templateInit: String?
        var duration: Double = 0
        var timescale: Double = 1
        var timelineCount = 0
    }

    func parse(data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        return parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        elementStack.append(elementName)
        switch elementName {
        case "MPD":
            if let dur = attributeDict["mediaPresentationDuration"] {
                durationSeconds = parseISO8601Duration(dur)
            }
        case "AdaptationSet", "Representation", "BaseURL", "SegmentList", "SegmentTemplate",
             "SegmentTimeline", "Initialization", "SegmentURL", "S":
            break
        default:
            break
        }

        if elementName == "Representation" {
            current = RepState(
                representation: DashRepresentation(
                    id: attributeDict["id"] ?? UUID().uuidString,
                    mimeType: attributeDict["mimeType"] ?? "",
                    codec: attributeDict["codecs"] ?? "",
                    height: Int(attributeDict["height"] ?? "") ?? 0,
                    bandwidth: Int64(attributeDict["bandwidth"] ?? "") ?? 0,
                    segments: [],
                    initialization: nil
                )
            )
        } else if elementName == "BaseURL", current != nil {
            // captured in foundCharacters
        } else if elementName == "SegmentTemplate", current != nil {
            var state = current!
            state.template = attributeDict["media"]
            state.templateInit = attributeDict["initialization"]
            state.duration = Double(attributeDict["duration"] ?? "") ?? 0
            state.timescale = Double(attributeDict["timescale"] ?? "") ?? 1
            state.representation.segmentDuration = state.duration
            current = state
        } else if elementName == "Initialization", current != nil {
            // SegmentList initialization has sourceURL attr
            if let src = attributeDict["sourceURL"] {
                var state = current!
                state.representation.initialization = URL(string: src)
                current = state
            }
        } else if elementName == "SegmentURL", current != nil {
            if let media = attributeDict["media"] {
                var state = current!
                state.segments.append(media)
                current = state
            }
        } else if elementName == "S", current != nil {
            var state = current!
            state.timelineCount += 1
            current = state
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard elementStack.last == "BaseURL" else { return }
        current?.baseURL = string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        elementStack.removeLast()
        if elementName == "Representation" {
            if let current {
                finalizeRepresentation(current)
            }
            self.current = nil
        }
    }

    private func finalizeRepresentation(_ rep: RepState) {
        var representation = rep.representation
        let base = rep.baseURL
        func resolve(_ path: String) -> URL? {
            if let url = URL(string: path), url.scheme != nil { return url }
            let joined = base.isEmpty ? path : base + (path.hasPrefix("/") ? "" : "/") + path
            return URL(string: joined)
        }

        if !rep.segments.isEmpty {
            representation.segments = rep.segments.compactMap { resolve($0) }
        } else if let template = rep.template {
            // Prefer the exact count from SegmentTimeline; otherwise fall
            // back to the period duration, or a large candidate list that
            // the downloader trims when segments start returning 404.
            var count: Int?
            if rep.timelineCount > 0 {
                count = rep.timelineCount
            } else if rep.duration > 0 {
                let seconds = rep.duration / rep.timescale
                if seconds > 0 {
                    count = max(1, Int(ceil((durationSeconds ?? 0) / seconds)))
                }
            }
            let limit = count ?? 4096
            var urls: [URL] = []
            for number in 1...limit {
                let substituted = expandTemplate(template, number: number, id: representation.id)
                guard let url = resolve(substituted) else { break }
                urls.append(url)
            }
            representation.templateURLs = urls
            representation.segmentDuration = rep.timescale > 0 ? rep.duration / rep.timescale : 0
        }
        if let initURL = rep.templateInit {
            let substituted = expandTemplate(initURL, number: 1, id: representation.id)
            representation.initialization = resolve(substituted)
        }
        representations.append(representation)
    }

    private func expandTemplate(_ template: String, number: Int, id: String) -> String {
        let result = template.replacingOccurrences(of: "$RepresentationID$", with: id)
        let ns = result as NSString
        guard let regex = try? NSRegularExpression(pattern: #"\$Number(%0(\d+)d)?\$"#),
              let match = regex.firstMatch(in: result, range: NSRange(location: 0, length: ns.length)) else {
            return result
        }
        let token = ns.substring(with: match.range)
        var digits = 0
        if match.numberOfRanges > 2 {
            let digitsRange = match.range(at: 2)
            if digitsRange.location != NSNotFound {
                digits = Int(ns.substring(with: digitsRange)) ?? 0
            }
        }
        let replacement = digits > 0 ? String(format: "%0\(digits)d", number) : "\(number)"
        _ = token
        return result.replacingOccurrences(of: token, with: replacement)
    }

    private func parseISO8601Duration(_ value: String) -> TimeInterval? {
        // "PT1H2M3.5S" -> seconds
        var s = value.uppercased()
        guard s.hasPrefix("PT") else { return nil }
        s.removeFirst(2)
        var total: TimeInterval = 0
        var number = ""
        for ch in s {
            if ch.isNumber || ch == "." {
                number.append(ch)
            } else {
                let n = Double(number) ?? 0
                switch ch {
                case "H": total += n * 3600
                case "M": total += n * 60
                case "S": total += n
                default: break
                }
                number = ""
            }
        }
        return total
    }
}
