import SwiftUI
import CryptoKit
import Observation

struct DupeGroup: Identifiable {
    let id = UUID()
    var files: [CleanItem]     // sorted oldest first
    var each: Int64 { files.first?.size ?? 0 }
    var wasted: Int64 { each * Int64(files.count - 1) }
}

@Observable @MainActor
final class DupesModel {
    weak var app: AppModel?
    var groups: [DupeGroup] = []
    var scanning = false
    var scanned = false
    var status = ""
    var expanded: Set<UUID> = []
    var marked: Set<String> = []       // files to remove (never the keeper)
    var minSizeMB = 1
    private var task: Task<Void, Never>?

    var wastedTotal: Int64 { groups.reduce(0) { $0 + $1.wasted } }
    var markedItems: [CleanItem] { groups.flatMap(\.files).filter { marked.contains($0.id) } }

    func scan() {
        guard !scanning else { return }
        scanning = true; scanned = false; groups = []; marked = []; expanded = []
        let minSize = Int64(minSizeMB) * 1_000_000
        task = Task { [weak self] in
            let result: [[CleanItem]] = await Task.detached(priority: .userInitiated) { () -> [[CleanItem]] in
                let home = FS.home
                let roots = ["Documents", "Downloads", "Desktop", "Pictures", "Movies", "Music"].map { home.appendingPathComponent($0) }
                var bySize: [Int64: [URL]] = [:]
                let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isDirectoryKey]
                // Dependency and version-control folders are full of intentional copies; deleting them breaks projects.
                let skipNames: Set<String> = ["node_modules", ".git", ".venv", "venv", "Pods", ".build", "site-packages", "DerivedData", ".gradle", "target", "__pycache__"]
                for root in roots {
                    guard let e = FS.fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]) else { continue }
                    while true {
                        var done = false
                        autoreleasepool {
                            guard let u = e.nextObject() as? URL else { done = true; return }
                            if skipNames.contains(u.lastPathComponent), (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                                e.skipDescendants(); return
                            }
                            if let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true, let s = v.fileSize, Int64(s) >= minSize {
                                bySize[Int64(s), default: []].append(u)
                            }
                        }
                        if done { break }
                    }
                }
                var out: [[CleanItem]] = []
                for (size, urls) in bySize where urls.count > 1 {
                    var byHash: [String: [URL]] = [:]
                    for u in urls {
                        guard let h = Self.hash(u) else { continue }
                        byHash[h, default: []].append(u)
                    }
                    for (_, same) in byHash where same.count > 1 {
                        let items = same.map { CleanItem(url: $0, size: size) }.sorted { ($0.modified ?? .distantFuture) < ($1.modified ?? .distantFuture) }
                        out.append(items)
                    }
                }
                return out
            }.value
            guard let self else { return }
            self.groups = result.map { DupeGroup(files: $0) }.sorted { $0.wasted > $1.wasted }
            for g in self.groups { for f in g.files.dropFirst() { self.marked.insert(f.id) } }
            self.scanning = false; self.scanned = true
        }
    }

    nonisolated static func hash(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            let chunk = autoreleasepool { () -> Data? in (try? h.read(upToCount: 1 << 20)) }
            guard let d = chunk, !d.isEmpty else { break }
            hasher.update(data: d)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func toggle(_ f: CleanItem, in g: DupeGroup) {
        if marked.contains(f.id) { marked.remove(f.id) }
        else if g.files.filter({ marked.contains($0.id) }).count < g.files.count - 1 { marked.insert(f.id) }
        else { app?.showToast("Keep at least one copy") }
    }
}

@MainActor struct DuplicatesView: View {
    @Environment(AppModel.self) var model
    var body: some View {
        let d = model.dupes
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Duplicates").font(.system(size: 15, weight: .semibold))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if d.scanned && !d.groups.isEmpty {
                    Button("Add \(d.markedItems.count) to Cleanup · \(bytesString(d.markedItems.reduce(0) { $0 + $1.size }))") {
                        model.stage(d.markedItems)
                    }.buttonStyle(DarkButtonStyle()).disabled(d.markedItems.isEmpty)
                }
                Button(d.scanning ? "Looking…" : (d.scanned ? "Scan again" : "Find duplicates")) { d.scan() }
                    .buttonStyle(d.scanned ? AnyButtonStyle(SoftButtonStyle()) : AnyButtonStyle(DarkButtonStyle())).disabled(d.scanning)
            }
            .padding(.horizontal, 28).padding(.top, 18).padding(.bottom, 10)
            Hairline().opacity(0.6)
            if d.scanning {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Comparing files byte for byte in Documents, Downloads, Desktop, Pictures, Movies and Music")
                        .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 320)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !d.scanned {
                EmptyHint(icon: "square.on.square", title: "Find identical files",
                          text: "DiskBuddy matches files byte for byte, so two files are only called duplicates if they are exactly the same. Files under \(d.minSizeMB) MB are skipped.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if d.groups.isEmpty {
                EmptyHint(icon: "checkmark.circle", title: "No duplicates found", text: "Nothing in your personal folders is stored twice.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) { ForEach(d.groups) { g in groupRow(g) } }
                        .padding(.horizontal, 28).padding(.vertical, 6)
                }
            }
        }
    }

    var subtitle: String {
        let d = model.dupes
        if d.scanned, !d.groups.isEmpty { return "\(countString(d.groups.count)) sets of identical files · \(bytesString(d.wastedTotal)) used by extra copies" }
        return "Byte-for-byte matching, nothing guessed"
    }

    func groupRow(_ g: DupeGroup) -> some View {
        let d = model.dupes
        let open = d.expanded.contains(g.id)
        return VStack(spacing: 0) {
            Button { if open { d.expanded.remove(g.id) } else { d.expanded.insert(g.id) } } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                    FileIcon(url: g.files[0].url, size: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(g.files[0].name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                        Text("\(g.files.count) copies · \(bytesString(g.each)) each").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(bytesString(g.wasted)) extra").font(.system(size: 11.5)).monospacedDigit()
                }
                .padding(.vertical, 7).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if open {
                ForEach(Array(g.files.enumerated()), id: \.element.id) { i, f in
                    HStack(spacing: 10) {
                        TickBox(state: d.marked.contains(f.id)) { d.toggle(f, in: g) }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(f.subtitle).font(.system(size: 10.5)).lineLimit(1).truncationMode(.middle)
                            Text(i == 0 ? "Oldest · kept by default · \(relativeDate(f.modified))" : relativeDate(f.modified))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Reveal") { FS.reveal(f.url) }.buttonStyle(SoftButtonStyle())
                    }
                    .padding(.leading, 30).padding(.vertical, 4)
                }
            }
            Hairline().opacity(0.5)
        }
    }
}

struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ s: S) { make = { AnyView(s.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
