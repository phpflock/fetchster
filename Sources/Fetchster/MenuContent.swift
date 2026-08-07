import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MenuRootView: View {
    @ObservedObject var store: DownloadStore
    @State private var route: Route = .list
    @State private var showSleepPanel = false

    enum Route {
        case list
        case add
        case settings
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if showSleepPanel {
                sleepPanel
                Divider()
            }
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Fetchster")
                .font(.headline)
            if store.activeCount > 0 {
                Text("\(store.activeCount)")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.tint))
            }
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showSleepPanel.toggle()
                }
            } label: {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(store.sleepTimerEnd != nil ? Color.orange : Color.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Prevent sleep — keeps downloads running")
            if store.sleepTimerEnd != nil {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.sleepCountdown(store.sleepTimerEnd?.timeIntervalSinceNow ?? 0))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.orange)
                        .frame(minWidth: 34, alignment: .trailing)
                }
            }
            Button {
                route = .add
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Add download")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var sleepPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prevent Mac sleep for:")
                .font(.system(size: 12, weight: .medium))
            HStack(spacing: 8) {
                ForEach([30, 60, 120, 360], id: \.self) { minutes in
                    Button(Self.sleepLabel(minutes)) {
                        store.setSleepTimer(minutes: minutes)
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showSleepPanel = false
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button("Off") {
                    store.setSleepTimer(minutes: nil)
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showSleepPanel = false
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if store.sleepTimerEnd != nil {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Mac stays awake for \(Self.sleepCountdown(store.sleepTimerEnd?.timeIntervalSinceNow ?? 0))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private static func sleepLabel(_ minutes: Int) -> String {
        if minutes >= 60 {
            let hours = minutes / 60
            return hours == 1 ? "1 hr" : "\(hours) hrs"
        }
        return "\(minutes) min"
    }

    private static func sleepCountdown(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval).rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }

    @ViewBuilder
    private var content: some View {
        switch route {
        case .list:
            VStack(spacing: 0) {
                if !store.detectedMedia.isEmpty {
                    MediaSectionView(store: store)
                    Divider()
                }
                DownloadsListView(store: store)
                    // Fixed height: a ScrollView contributes no intrinsic
                    // height the first time the popover opens, which
                    // collapses the whole list until a re-render.
                    .frame(height: 320)
            }
        case .add:
            AddDownloadView(store: store) {
                route = .list
            }
        case .settings:
            SettingsView(store: store) {
                route = .list
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                store.openDownloadFolder()
            } label: {
                Label("Open Downloads", systemImage: "folder")
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .help("Reveal the download folder in Finder")

            Spacer()

            Button {
                route = .settings
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Quit Fetchster")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

struct MediaSectionView: View {
    @ObservedObject var store: DownloadStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(store.detectedMedia) { media in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.rectangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.blue)
                        Text("Video detected")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Button {
                            store.clearMedia()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                        .help("Clear detected videos")
                    }
                    if let page = media.pageTitle, !page.isEmpty {
                        Text(page)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    ForEach(media.streams) { stream in
                        HStack(spacing: 8) {
                            Text(stream.displayLabel)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.blue))
                            if let size = stream.size, size > 0 {
                                Text(FileUtils.byteString(size))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                store.downloadMedia(stream)
                            } label: {
                                Image(systemName: "arrow.down.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                            .help("Download \(stream.displayLabel)")
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DownloadsListView: View {
    @ObservedObject var store: DownloadStore

    var body: some View {
        Group {
            if store.downloads.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                    Text("No downloads")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("Click + to add a link, magnet, or .torrent")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            } else {
                ScrollView {
                    // Deliberately non-lazy: lazy containers can lay out to
                    // zero height the first time the popover opens, hiding
                    // the whole list until a re-render.
                    VStack(spacing: 0) {
                        ForEach(store.downloads) { item in
                            DownloadRowView(item: item, store: store)
                            Divider()
                                .padding(.leading, 44)
                        }
                    }
                }
            }
        }
    }
}

struct DownloadRowView: View {
    let item: DownloadItem
    @ObservedObject var store: DownloadStore
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.system(size: 15))
                    .foregroundStyle(iconColor)
                    .frame(width: 20)
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                if item.status == .completed || item.status == .failed || item.status == .paused {
                    Button {
                        store.reveal(item)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Reveal in Finder")
                }
                if item.kind != .media,
                   item.status == .downloading || item.status == .queued || item.status == .seeding {
                    Button {
                        store.pause(item)
                    } label: {
                        Image(systemName: "pause.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(item.status == .seeding ? "Stop Seeding" : "Pause")
                } else if item.status == .paused || item.status == .failed {
                    Button {
                        store.resume(item)
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Resume")
                }
                Button {
                    store.remove(item)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Remove")
            }

            ProgressView(value: item.progress)
                .progressViewStyle(.linear)
                .controlSize(.small)
                .tint(progressTint)

            HStack {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isHovering ? Color(nsColor: .systemBlue).opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .onTapGesture(count: 2) { store.open(item) }
        .contextMenu {
            if item.kind == .media {
                Button("Retry") { store.resume(item) }
                    .disabled(item.status != .failed)
                Divider()
                Button("Open") { store.open(item) }
                    .disabled(item.destinationURL == nil)
                Button("Reveal in Finder") { store.reveal(item) }
                Button("Remove", role: .destructive) { store.remove(item) }
            } else if item.kind == .torrent || item.kind == .magnet {
                if item.status == .seeding {
                    Button("Stop Seeding") { store.pause(item) }
                } else {
                    Button("Pause") { store.pause(item) }
                        .disabled(item.status != .downloading && item.status != .queued)
                }
                Button("Resume") { store.resume(item) }
                    .disabled(item.status != .paused && item.status != .failed)
                Divider()
                Button("Update Trackers") { store.updateTrackers(item) }
                    .disabled(item.ariaGID == nil)
                Divider()
                Button("Copy Magnet Link") { store.copyMagnet(item) }
                    .disabled(!(item.url?.scheme?.lowercased() == "magnet" || item.infoHash != nil))
                Button("Copy Info Hash") { store.copyInfoHash(item) }
                    .disabled(item.infoHash == nil)
                Divider()
                Button("Open") { store.open(item) }
                    .disabled(item.destinationURL == nil)
                Button("Reveal in Finder") { store.reveal(item) }
                Button("Remove & Delete Files", role: .destructive) { store.removeWithFiles(item) }
                Button("Remove", role: .destructive) { store.remove(item) }
            } else {
                Button("Pause") { store.pause(item) }
                    .disabled(!(item.status == .downloading || item.status == .queued || item.status == .seeding))
                Button("Resume") { store.resume(item) }
                    .disabled(item.status != .paused && item.status != .failed)
                Divider()
                Button("Open") { store.open(item) }
                    .disabled(item.destinationURL == nil)
                Button("Reveal in Finder") { store.reveal(item) }
                Button("Remove", role: .destructive) { store.remove(item) }
            }
        }
    }

    private var iconName: String {
        switch item.status {
        case .completed: return "checkmark.circle.fill"
        case .downloading: return item.kind == .media ? "film" : "arrow.down.circle.fill"
        case .paused: return "pause.circle.fill"
        case .queued: return "clock.fill"
        case .seeding: return "arrow.up.arrow.down.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .removed: return "trash"
        }
    }

    private var iconColor: Color {
        switch item.status {
        case .completed: return .green
        case .seeding: return .green
        case .downloading: return .blue
        case .paused: return .orange
        case .queued: return .secondary
        case .failed: return .red
        case .removed: return .secondary
        }
    }

    private var progressTint: Color {
        item.status == .failed ? .red : (item.status == .completed ? .green : .blue)
    }

    private var detail: String {
        switch item.status {
        case .downloading:
            if item.kind == .media {
                var parts = [item.mediaPhase ?? "Processing"]
                if item.downloadedBytes > 0 {
                    parts.append(FileUtils.byteString(item.downloadedBytes))
                }
                return parts.joined(separator: " · ")
            }
            if item.kind != .http && (item.totalBytes ?? 0) == 0 && item.downloadedBytes == 0 {
                return "Fetching metadata…"
            }
            var parts: [String] = []
            if item.speed > 0 {
                parts.append(item.kind == .http
                    ? FileUtils.speedString(item.speed)
                    : "↓ \(FileUtils.speedString(item.speed))")
            }
            if item.kind != .http, item.uploadSpeed > 0 {
                parts.append("↑ \(FileUtils.speedString(item.uploadSpeed))")
            }
            parts.append("\(Int((item.progress * 100).rounded()))%")
            if let total = item.totalBytes, total > 0 {
                parts.append("\(FileUtils.byteString(item.downloadedBytes)) of \(FileUtils.byteString(total))")
            } else if item.downloadedBytes > 0 {
                parts.append(FileUtils.byteString(item.downloadedBytes))
            }
            if item.kind != .http {
                let swarm = swarmText
                if !swarm.isEmpty {
                    parts.append(swarm)
                }
            }
            if let eta = item.eta, eta.isFinite, eta > 0, item.speed > 0 {
                parts.append("ETA \(FileUtils.etaString(eta))")
            }
            return parts.joined(separator: " · ")
        case .paused:
            var text = "Paused"
            if item.downloadedBytes > 0 {
                text += " · \(FileUtils.byteString(item.downloadedBytes))"
            }
            if let total = item.totalBytes, total > 0 {
                text += " of \(FileUtils.byteString(total))"
            }
            return text
        case .queued:
            return "Queued"
        case .seeding:
            var parts = ["Seeding"]
            if item.uploadSpeed > 0 {
                parts.append("↑ \(FileUtils.speedString(item.uploadSpeed))")
            }
            if item.uploadedBytes > 0, item.downloadedBytes > 0 {
                parts.append(String(format: "ratio %.2f", Double(item.uploadedBytes) / Double(item.downloadedBytes)))
            }
            let swarm = swarmText
            if !swarm.isEmpty {
                parts.append(swarm)
            }
            return parts.joined(separator: " · ")
        case .completed:
            var text = "Completed"
            if item.downloadedBytes > 0 {
                text += " · \(FileUtils.byteString(item.downloadedBytes))"
            }
            if item.kind != .http, item.uploadedBytes > 0, item.downloadedBytes > 0 {
                text += String(format: " · ratio %.2f", Double(item.uploadedBytes) / Double(item.downloadedBytes))
            }
            if let date = item.completedAt {
                text += " · \(FileUtils.dateString(date))"
            }
            return text
        case .failed:
            return item.errorMessage ?? "Failed"
        case .removed:
            return "Removed"
        }
    }

    private var swarmText: String {
        var bits: [String] = []
        if item.seeders > 0 {
            bits.append("\(item.seeders) seeders")
        }
        if item.peers > 0 {
            bits.append("\(item.peers) peers")
        }
        return bits.joined(separator: " · ")
    }
}

struct AddDownloadView: View {
    @ObservedObject var store: DownloadStore
    var onDone: () -> Void

    @State private var urlText = ""
    @State private var errorText: String?
    @FocusState private var urlFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Download")
                .font(.headline)

            TextField("https://…, magnet:…, or .torrent", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .focused($urlFocused)
                .onSubmit(add)

            HStack(spacing: 8) {
                Button(action: pasteClipboard) {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .controlSize(.small)

                Button(action: chooseTorrentFile) {
                    Label("Torrent File…", systemImage: "doc.badge.plus")
                }
                .controlSize(.small)

                Spacer()
            }

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") { onDone() }
                Spacer()
                Button("Download", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .onAppear {
            pasteClipboard()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                urlFocused = true
            }
        }
    }

    private func add() {
        guard store.addURLString(urlText) else {
            errorText = "That doesn't look like a valid URL."
            return
        }
        onDone()
    }

    private func pasteClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty,
            looksDownloadable(text) else {
            return
        }
        urlText = text
    }

    private func looksDownloadable(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.hasPrefix("http://")
            || lower.hasPrefix("https://")
            || lower.hasPrefix("ftp://")
            || lower.hasPrefix("magnet:")
    }

    private func chooseTorrentFile() {
        let panel = NSOpenPanel()
        if let torrentType = UTType(filenameExtension: "torrent") {
            panel.allowedContentTypes = [torrentType]
        }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a .torrent file"
        if panel.runModal() == .OK, let url = panel.url {
            store.addTorrentFile(url)
            onDone()
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: DownloadStore
    @ObservedObject var engines = EngineManager.shared
    var onDone: () -> Void

    @State private var loginError: String?
    @State private var pendingEngine: PendingEngine?

    /// Engine the user wants to enable; pending user consent before the
    /// binary is downloaded and installed.
    enum PendingEngine: String, Identifiable {
        case torrent
        case media
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings")
                .font(.headline)

            HStack {
                Text("Download folder")
                Spacer()
                Button(store.downloadDirectory.lastPathComponent) {
                    chooseFolder()
                }
                .buttonStyle(.link)
                .help(store.downloadDirectory.path)
            }

            HStack {
                Text("Concurrent HTTP downloads")
                Spacer()
                Picker("", selection: concurrentBinding) {
                    ForEach(1...8, id: \.self) { count in
                        Text("\(count)")
                    }
                }
                .labelsHidden()
                .frame(width: 60)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Default User-Agent")
                    .font(.system(size: 12))
                TextField("Mozilla/5.0 …", text: userAgentBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .help("Sent on every download unless the browser supplies one")
            }

            Toggle("Completion notifications", isOn: notificationsBinding)

            Toggle("Launch at login", isOn: launchBinding)

            if let loginError {
                Text(loginError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()

            Text("Engines (downloaded on demand)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Toggle("Torrent downloads", isOn: torrentEngineBinding)
            engineStatus(.aria2)

            Toggle("Media downloads", isOn: youtubeEngineBinding)
            Text("YouTube, HLS & DASH video")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 22)
            engineStatus(.ytdlp)
            engineStatus(.ffmpeg)

            HStack {
                Spacer()
                Button("Done") { onDone() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 340)
        .alert(item: $pendingEngine) { engine in
            switch engine {
            case .torrent:
                Alert(
                    title: Text("Enable Torrent downloads?"),
                    message: Text("Fetchster will download the aria2 download engine (aria2c) and run it on your Mac to handle .torrent files and magnet links."),
                    primaryButton: .default(Text("Agree")) {
                        store.setTorrentEngineEnabled(true)
                    },
                    secondaryButton: .cancel(Text("Cancel"))
                )
            case .media:
                Alert(
                    title: Text("Enable Media downloads?"),
                    message: Text("Fetchster will download the yt-dlp and ffmpeg download engines and run them on your Mac to handle YouTube, HLS and DASH video downloads."),
                    primaryButton: .default(Text("Agree")) {
                        store.setMediaEngineEnabled(true)
                    },
                    secondaryButton: .cancel(Text("Cancel"))
                )
            }
        }
    }

    private var concurrentBinding: Binding<Int> {
        Binding(
            get: { store.maxConcurrentHTTP },
            set: { store.maxConcurrentHTTP = $0 }
        )
    }

    private var notificationsBinding: Binding<Bool> {
        Binding(
            get: { store.notificationsEnabled },
            set: { store.notificationsEnabled = $0 }
        )
    }

    private var userAgentBinding: Binding<String> {
        Binding(
            get: { store.defaultUserAgent },
            set: { store.defaultUserAgent = $0 }
        )
    }

    private var launchBinding: Binding<Bool> {
        Binding(
            get: { store.launchAtLogin },
            set: { loginError = store.setLaunchAtLogin($0) }
        )
    }

    private var torrentEngineBinding: Binding<Bool> {
        Binding(
            get: { engines.torrentEnabled },
            set: { newValue in
                if newValue {
                    pendingEngine = .torrent
                } else {
                    store.setTorrentEngineEnabled(false)
                }
            }
        )
    }

    private var youtubeEngineBinding: Binding<Bool> {
        Binding(
            get: { engines.mediaEnabled },
            set: { newValue in
                if newValue {
                    pendingEngine = .media
                } else {
                    store.setMediaEngineEnabled(false)
                }
            }
        )
    }

    private func engineStatus(_ binary: EngineBinary) -> some View {
        let info: (String, Color)
        switch engines.state(for: binary) {
        case .missing:
            info = ("Not downloaded", .secondary)
        case .downloading(let fraction):
            info = (String(format: "Downloading… %.0f%%", fraction * 100), .secondary)
        case .ready:
            info = ("Ready", .green)
        case .failed(let message):
            info = (message, .red)
        }
        return Text(info.0)
            .font(.caption)
            .foregroundStyle(info.1)
            .padding(.leading, 22)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            store.downloadDirectory = url
        }
    }
}
