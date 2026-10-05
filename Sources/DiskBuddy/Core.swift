import SwiftUI
import AppKit
import Foundation

// MARK: - Theme

enum Theme {
    static func dyn(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
    static let bg = dyn(NSColor(white: 0.992, alpha: 1), NSColor(white: 0.115, alpha: 1))
    static let card = Color.primary.opacity(0.04)
    static let hair = Color.primary.opacity(0.09)
    static let faint = Color.primary.opacity(0.45)
    static let orange = Color(red: 0.96, green: 0.65, blue: 0.14)
    static let red = Color(red: 0.90, green: 0.28, blue: 0.33)
    static let purple = Color(red: 0.55, green: 0.40, blue: 0.96)
    static let green = Color(red: 0.30, green: 0.69, blue: 0.31)
    static let blue = Color(red: 0.25, green: 0.52, blue: 0.96)
    static let pink = Color(red: 0.93, green: 0.30, blue: 0.55)
    static let ink = dyn(NSColor(white: 0.09, alpha: 1), NSColor(white: 0.95, alpha: 1))
    static let inkText = dyn(.white, NSColor(white: 0.1, alpha: 1))
}

// MARK: - Formatting

func bytesString(_ n: Int64) -> String {
    if n <= 0 { return "0 KB" }
    let d = Double(n)
    if d >= 1e12 { return String(format: "%.2f TB", d / 1e12) }
    if d >= 1e9 { return String(format: "%.1f GB", d / 1e9) }
    if d >= 1e6 { return "\(Int((d / 1e6).rounded())) MB" }
    if d >= 1e3 { return "\(Int((d / 1e3).rounded())) KB" }
    return "\(n) B"
}

func bytesShort(_ n: Int64) -> String {
    if n < 1_000_000 { return n <= 0 ? "0 KB" : "Under 1 MB" }
    return bytesString(n)
}

func countString(_ n: Int) -> String {
    let f = NumberFormatter(); f.numberStyle = .decimal
    return f.string(from: NSNumber(value: n)) ?? "\(n)"
}

func percentOfDisk(_ n: Int64, _ total: Int64) -> String {
    guard total > 0 else { return "" }
    let p = Double(n) / Double(total) * 100
    if n > 0 && p < 1 { return "<1% of disk" }
    return "\(Int(p.rounded()))% of disk"
}

private let relFmt: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter(); f.unitsStyle = .full; return f
}()

func relativeDate(_ d: Date?) -> String {
    guard let d else { return "" }
    if abs(d.timeIntervalSinceNow) < 60 { return "1 minute ago" }
    return relFmt.localizedString(for: d, relativeTo: Date())
}

func abbreviated(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

// MARK: - Disk info

struct DiskInfo {
    var total: Int64
    var free: Int64
    var used: Int64 { max(0, total - free) }
    var name: String

    static func read() -> DiskInfo {
        let url = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey, .volumeNameKey]
        let v = try? url.resourceValues(forKeys: keys)
        let total = Int64(v?.volumeTotalCapacity ?? 0)
        let free = v?.volumeAvailableCapacityForImportantUsage ?? Int64(v?.volumeAvailableCapacity ?? 0)
        return DiskInfo(total: total, free: free, name: v?.volumeName ?? "Macintosh HD")
    }
}

// MARK: - File system helpers

enum FileKind: String { case document, image, video, audio, archive, code, folder, other }

enum FS {
    static let fm = FileManager.default
    static var home: URL { fm.homeDirectoryForCurrentUser }

    static let docExt: Set<String> = ["pdf","doc","docx","xls","xlsx","ppt","pptx","txt","rtf","pages","numbers","key","md","csv","odt","ods","epub","tex"]
    static let imageExt: Set<String> = ["jpg","jpeg","png","gif","heic","heif","tiff","tif","bmp","webp","avif","raw","cr2","nef","arw","dng","svg","psd","icns"]
    static let videoExt: Set<String> = ["mov","mp4","m4v","avi","mkv","webm","mpg","mpeg","wmv","flv","3gp"]
    static let audioExt: Set<String> = ["mp3","m4a","wav","aiff","aif","flac","aac","ogg","opus","wma"]
    static let archiveExt: Set<String> = ["zip","rar","7z","tar","gz","tgz","bz2","xz","dmg","pkg","iso","xip","mpkg"]
    static let codeExt: Set<String> = ["swift","js","ts","tsx","jsx","py","rb","go","rs","c","h","cpp","hpp","m","mm","java","kt","json","yaml","yml","toml","html","css","scss","sh","zsh","php","sql","xml","plist","lock","gradle"]
    static let installerExt: Set<String> = ["dmg","pkg","iso","xip","mpkg"]

    static func kind(ext: String, isDir: Bool) -> FileKind {
        if isDir { return .folder }
        let e = ext.lowercased()
        if docExt.contains(e) { return .document }
        if imageExt.contains(e) { return .image }
        if videoExt.contains(e) { return .video }
        if audioExt.contains(e) { return .audio }
        if archiveExt.contains(e) { return .archive }
        if codeExt.contains(e) { return .code }
        return .other
    }

    private static let sizeKeys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey]

    static func allocated(_ v: URLResourceValues) -> Int64 {
        Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
    }

    static func size(of url: URL) -> Int64 {
        guard let v = try? url.resourceValues(forKeys: sizeKeys) else { return 0 }
        return allocated(v)
    }

    /// Recursive allocated size and item count. Symlinks are never followed.
    static func tree(_ url: URL, cancel: (() -> Bool)? = nil) -> (bytes: Int64, items: Int) {
        guard let rv = try? url.resourceValues(forKeys: sizeKeys) else { return (0, 0) }
        if rv.isSymbolicLink == true { return (0, 1) }
        if rv.isDirectory != true { return (allocated(rv), 1) }
        var total = allocated(rv)
        var count = 1
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: Array(sizeKeys), options: [], errorHandler: { _, _ in true }) else { return (total, count) }
        while true {
            var finished = false
            autoreleasepool {
                if let u = e.nextObject() as? URL {
                    if let v = try? u.resourceValues(forKeys: sizeKeys) { total += allocated(v) }
                    count += 1
                    if count & 0x3FF == 0, let cancel, cancel() { finished = true }
                } else { finished = true }
            }
            if finished { break }
        }
        return (total, count)
    }

    static func treeAsync(_ url: URL, cancel: (() -> Bool)? = nil) async -> (bytes: Int64, items: Int) {
        await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: tree(url, cancel: cancel)) }
        }
    }

    static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    static func children(_ url: URL) -> [URL] {
        (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])) ?? []
    }

    static func isDirectory(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }

    static func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    /// Runs `work` over items with bounded parallelism; results delivered on the main actor.
    static func parallel<T: Sendable, R: Sendable>(_ items: [T], limit: Int = 6,
                                                   work: @escaping @Sendable (T) async -> R,
                                                   onResult: @MainActor @escaping (Int, R) -> Void) async {
        await withTaskGroup(of: (Int, R).self) { group in
            var next = 0
            func feed(_ g: inout TaskGroup<(Int, R)>) {
                guard next < items.count else { return }
                let i = next; next += 1
                let item = items[i]
                g.addTask { (i, await work(item)) }
            }
            for _ in 0..<min(limit, items.count) { feed(&group) }
            while let (i, r) = await group.next() {
                await onResult(i, r)
                if Task.isCancelled { group.cancelAll(); break }
                feed(&group)
            }
        }
    }

    static func trash(_ items: [CleanItem]) -> (trashed: [CleanItem], failed: [String]) {
        var ok: [CleanItem] = []; var failed: [String] = []
        for it in items {
            do {
                try fm.trashItem(at: it.url, resultingItemURL: nil)
                for e in it.extra { try? fm.trashItem(at: URL(fileURLWithPath: e), resultingItemURL: nil) }
                ok.append(it)
            } catch {
                failed.append(it.name)
            }
        }
        return (ok, failed)
    }

    static func icon(for url: URL) -> NSImage {
        let i = NSWorkspace.shared.icon(forFile: url.path)
        i.size = NSSize(width: 32, height: 32)
        return i
    }
}

enum Shell {
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 30) async -> String {
        await withCheckedContinuation { c in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { c.resume(returning: ""); return }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                c.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }
}

// MARK: - Cleanup domain types

struct CleanItem: Identifiable, Hashable {
    let path: String
    let name: String
    let subtitle: String
    let size: Int64
    let modified: Date?
    let isDir: Bool
    /// Extra paths that go to the Trash together with this item (e.g. an Ollama model's weight files).
    let extra: [String]
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }

    init(url: URL, size: Int64, name: String? = nil, subtitle: String? = nil, extra: [String] = []) {
        self.extra = extra
        path = url.path
        self.name = name ?? url.lastPathComponent
        self.subtitle = subtitle ?? abbreviated(url.deletingLastPathComponent().path)
        self.size = size
        modified = FS.modified(url)
        isDir = FS.isDirectory(url)
    }
}

enum GroupID: String, CaseIterable, Hashable {
    case nodeModules, buildOutput, packageCaches, caches, sandboxCaches, logs
    case docker, ai, largeMedia, installers, downloads

    var title: String {
        switch self {
        case .nodeModules: "node_modules"
        case .buildOutput: "Build output"
        case .packageCaches: "Package caches"
        case .caches: "Caches"
        case .sandboxCaches: "Sandboxed app caches"
        case .logs: "Logs and temp files"
        case .docker: "Docker and virtual machines"
        case .ai: "Local AI models"
        case .largeMedia: "Large media"
        case .installers: "Disk images and installers"
        case .downloads: "Downloads"
        }
    }
    var blurb: String {
        switch self {
        case .nodeModules: "Packages for your JavaScript projects"
        case .buildOutput: "What your projects' build tools made"
        case .packageCaches: "Downloads kept by npm, Cargo, Gradle and others"
        case .caches: "Browser and app caches"
        case .sandboxCaches: "The cache inside each App Store app"
        case .logs: "Crash reports and old logs"
        case .docker: "Container storage and VM disks"
        case .ai: "From Ollama, LM Studio, Hugging Face, Jan and others"
        case .largeMedia: "Video and audio files. Compress may suit them better"
        case .installers: "Installers you may have already used"
        case .downloads: "Everything in your Downloads folder"
        }
    }
    /// Listed under "Safe to clear" in the Cleanup room (the rest are "Worth a look").
    var isSafe: Bool {
        switch self {
        case .nodeModules, .buildOutput, .packageCaches, .caches, .sandboxCaches, .logs: true
        default: false
        }
    }
    /// Every group can be ticked straight from its row; only the safe ones start ticked.
    var tickable: Bool { true }
    var ticksByDefault: Bool { self == .caches || self == .sandboxCaches || self == .logs }
    var color: Color {
        switch self {
        case .caches, .sandboxCaches: Theme.orange
        case .logs: Theme.red
        case .nodeModules, .buildOutput, .packageCaches, .docker: Theme.purple
        case .ai: Theme.green
        case .largeMedia, .installers, .downloads: Theme.blue
        }
    }
}

struct CleanGroup: Identifiable {
    let id: GroupID
    var items: [CleanItem]
    var trashedBytes: Int64 = 0
    var size: Int64 { items.reduce(0) { $0 + $1.size } }
    var inTrash: Bool { items.isEmpty && trashedBytes > 0 }
}

struct OverviewRow: Identifiable {
    enum Section { case safe, look }
    let id: String
    let title: String
    let blurb: String
    let groups: [GroupID]
    let section: Section
    let color: Color
    let tickable: Bool

    static let all: [OverviewRow] = [
        .init(id: "caches", title: "Caches", blurb: "Browser and app caches", groups: [.caches, .sandboxCaches], section: .safe, color: Theme.orange, tickable: true),
        .init(id: "logs", title: "Logs and temp files", blurb: "Crash reports and old logs", groups: [.logs], section: .safe, color: Theme.red, tickable: true),
        .init(id: "dev", title: "Developer files", blurb: "Build output and Xcode data", groups: [.nodeModules, .buildOutput, .packageCaches], section: .look, color: Theme.purple, tickable: true),
        .init(id: "docker", title: "Docker and virtual machines", blurb: "Container storage and VM disks", groups: [.docker], section: .look, color: Theme.purple, tickable: true),
        .init(id: "ai", title: "Local AI models", blurb: "Ollama, LM Studio, Hugging Face, Jan and others", groups: [.ai], section: .look, color: Theme.green, tickable: true),
        .init(id: "media", title: "Large media", blurb: "Video and audio files over 100 MB", groups: [.largeMedia], section: .look, color: Theme.blue, tickable: true),
        .init(id: "dl", title: "Downloads and installers", blurb: "Downloads and disk images", groups: [.installers, .downloads], section: .look, color: Theme.blue, tickable: true),
    ]
}

// MARK: - Reusable controls

struct DarkButtonStyle: ButtonStyle {
    struct Body: View {
        @Environment(\.isEnabled) var enabled
        let cfg: ButtonStyleConfiguration
        var body: some View {
            cfg.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(enabled ? Theme.inkText : Color.primary.opacity(0.35))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(enabled ? Theme.ink.opacity(cfg.isPressed ? 0.78 : 1) : Color.primary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 7))
        }
    }
    func makeBody(configuration: Configuration) -> Body { Body(cfg: configuration) }
}

struct SoftButtonStyle: ButtonStyle {
    struct Body: View {
        @Environment(\.isEnabled) var enabled
        let cfg: ButtonStyleConfiguration
        var body: some View {
            cfg.label
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.primary.opacity(enabled ? 0.85 : 0.3))
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(Color.primary.opacity(cfg.isPressed ? 0.12 : 0.07), in: RoundedRectangle(cornerRadius: 6))
        }
    }
    func makeBody(configuration: Configuration) -> Body { Body(cfg: configuration) }
}

@MainActor struct TickBox: View {
    var state: Bool?          // nil = mixed
    var color: Color = Theme.ink
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 3.5)
                    .fill(state != false ? color : Color.clear)
                RoundedRectangle(cornerRadius: 3.5)
                    .stroke(state != false ? color : Color.primary.opacity(0.28), lineWidth: 1)
                if state == true {
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white)
                } else if state == nil {
                    Image(systemName: "minus").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white)
                }
            }
            .frame(width: 14, height: 14)
            .padding(5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(-5)
    }
}

struct Seg<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var sel: T
    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { i in
                let (v, label) = options[i]
                Text(label)
                    .font(.system(size: 11, weight: sel == v ? .semibold : .regular))
                    .foregroundStyle(sel == v ? Color.primary : Color.primary.opacity(0.5))
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(sel == v ? Theme.bg : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                    .shadow(color: .black.opacity(sel == v ? 0.08 : 0), radius: 1, y: 0.5)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeOut(duration: 0.12)) { sel = v } }
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
    }
}

struct Spark: Shape {
    var values: [Double]
    var maxV: Double? = nil
    func path(in r: CGRect) -> Path {
        var p = Path()
        guard values.count > 1 else { return p }
        let mx = max(maxV ?? (values.max() ?? 1), 0.0001)
        for (i, v) in values.enumerated() {
            let x = r.minX + r.width * CGFloat(i) / CGFloat(values.count - 1)
            let y = r.maxY - r.height * CGFloat(min(v / mx, 1))
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        return p
    }
}

struct SparkFill: Shape {
    var values: [Double]
    var maxV: Double? = nil
    func path(in r: CGRect) -> Path {
        var p = Spark(values: values, maxV: maxV).path(in: r)
        guard values.count > 1 else { return p }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.closeSubpath()
        return p
    }
}

@MainActor struct Hairline: View {
    var body: some View { Rectangle().fill(Theme.hair).frame(height: 1) }
}

@MainActor struct FileIcon: View {
    let url: URL
    var size: CGFloat = 20
    var body: some View {
        Image(nsImage: FS.icon(for: url)).resizable().interpolation(.high).frame(width: size, height: size)
    }
}

@MainActor struct EmptyHint: View {
    let icon: String; let title: String; let text: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 22)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 300)
        }
    }
}
