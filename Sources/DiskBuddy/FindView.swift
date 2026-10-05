import SwiftUI
import Observation

struct FoundFile: Identifiable, Hashable {
    let url: URL
    let isDir: Bool
    let size: Int64
    let modified: Date?
    let score: Int
    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var kind: FileKind { FS.kind(ext: url.pathExtension, isDir: isDir) }
}

@Observable @MainActor
final class FindModel {
    enum Filter: String, CaseIterable { case all = "All", documents = "Documents", images = "Images", videos = "Videos", archives = "Archives", code = "Code", folders = "Folders"
        var icon: String {
            switch self { case .all: "square.grid.2x2"; case .documents: "doc.text"; case .images: "photo"; case .videos: "film"; case .archives: "archivebox"; case .code: "chevron.left.forwardslash.chevron.right"; case .folders: "folder" }
        }
        func matches(_ k: FileKind) -> Bool {
            switch self { case .all: true; case .documents: k == .document; case .images: k == .image; case .videos: k == .video || k == .audio; case .archives: k == .archive; case .code: k == .code; case .folders: k == .folder }
        }
    }
    weak var app: AppModel?
    var query = "" { didSet { if query != oldValue { restart() } } }
    var filter: Filter = .all
    var results: [FoundFile] = []
    var searching = false
    var elapsedMS = 0
    var truncated = false
    var selected: String?
    var sortBest = true
    private var task: Task<Void, Never>?
    private var generation = 0

    var visible: [FoundFile] {
        var l = results.filter { filter.matches($0.kind) }
        if !sortBest || query.isEmpty { l.sort { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) } }
        return l
    }

    func restart() {
        task?.cancel()
        generation += 1
        let gen = generation
        let q = query.trimmingCharacters(in: .whitespaces)
        results = []; truncated = false; selected = nil
        if q.isEmpty { loadRecent(gen); return }
        searching = true
        let started = Date()
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 140_000_000)
            if Task.isCancelled { return }
            let stream = AsyncStream<[FoundFile]> { cont in
                let work = Task.detached(priority: .userInitiated) {
                    FindModel.search(q, emit: { cont.yield($0) }, cancelled: { Task.isCancelled })
                    cont.finish()
                }
                cont.onTermination = { _ in work.cancel() }
            }
            for await batch in stream {
                guard let self, gen == self.generation else { return }
                self.results.append(contentsOf: batch)
                if self.results.count >= 4000 { self.truncated = true }
                self.elapsedMS = Int(Date().timeIntervalSince(started) * 1000)
            }
            guard let self, gen == self.generation else { return }
            self.results.sort { $0.score != $1.score ? $0.score > $1.score : $0.url.path.count < $1.url.path.count }
            self.searching = false
            self.elapsedMS = Int(Date().timeIntervalSince(started) * 1000)
        }
    }

    func loadRecent(_ gen: Int) {
        searching = true
        task = Task { [weak self] in
            let out = await Shell.run("/usr/bin/mdfind", ["-onlyin", FS.home.path, "kMDItemFSContentChangeDate >= $time.today(-7) && kMDItemContentTypeTree != 'public.folder'"], timeout: 15)
            let paths = out.split(separator: "\n").prefix(600).map(String.init).filter { !$0.contains("/Library/Caches/") }
            let files: [FoundFile] = await Task.detached {
                var l: [FoundFile] = []
                for p in paths {
                    let u = URL(fileURLWithPath: p)
                    let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .totalFileAllocatedSizeKey, .isDirectoryKey])
                    l.append(FoundFile(url: u, isDir: v?.isDirectory == true, size: Int64(v?.totalFileAllocatedSize ?? 0), modified: v?.contentModificationDate, score: 0))
                }
                return l.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }.prefix(60).map { $0 }
            }.value
            guard let self, gen == self.generation else { return }
            self.results = files; self.searching = false
        }
    }

    nonisolated static func search(_ q: String, emit: ([FoundFile]) -> Void, cancelled: () -> Bool) {
        let tokens = q.lowercased().split(separator: " ").map(String.init)
        let home = FS.home
        let roots = [home, URL(fileURLWithPath: "/Applications")]
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]
        var batch: [FoundFile] = []; var total = 0
        var lastEmit = Date()
        var seen = Set<String>()

        // Fast pass: Spotlight's index answers instantly; the walk below then adds hidden and unindexed files.
        let esc = { (t: String) in t.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "") }
        let predicate = tokens.map { "kMDItemFSName == \"*\(esc($0))*\"c" }.joined(separator: " && ")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = ["-onlyin", home.path, predicate]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            let q0 = tokens.joined(separator: " ")
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n").prefix(1500) {
                if cancelled() { return }
                let u = URL(fileURLWithPath: String(line))
                let name = u.lastPathComponent.lowercased()
                let v = try? u.resourceValues(forKeys: Set(keys))
                let score = name == q0 ? 100 : name.hasPrefix(q0) ? 60 : 30
                seen.insert(u.path)
                batch.append(FoundFile(url: u, isDir: v?.isDirectory == true, size: Int64(v?.totalFileAllocatedSize ?? 0), modified: v?.contentModificationDate, score: score))
                total += 1
            }
            if !batch.isEmpty { emit(batch); batch = []; lastEmit = Date() }
        }
        let skipPrefix = home.path + "/Library/CloudStorage"
        for root in roots {
            guard let e = FS.fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { continue }
            while true {
                var done = false
                autoreleasepool {
                    guard let u = e.nextObject() as? URL else { done = true; return }
                    if total >= 4000 || cancelled() { done = true; return }
                    let name = u.lastPathComponent.lowercased()
                    let isDirKey = (try? u.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]))
                    if isDirKey?.isSymbolicLink == true { return }
                    if isDirKey?.isDirectory == true, u.path == skipPrefix { e.skipDescendants(); return }
                    guard tokens.allSatisfy({ name.contains($0) }), !seen.contains(u.path) else { return }
                    let v = try? u.resourceValues(forKeys: Set(keys))
                    let q0 = tokens.joined(separator: " ")
                    let score = name == q0 ? 100 : name.hasPrefix(q0) ? 60 : (name.contains(q0) ? 30 : 10)
                    batch.append(FoundFile(url: u, isDir: v?.isDirectory == true, size: Int64(v?.totalFileAllocatedSize ?? 0), modified: v?.contentModificationDate, score: score))
                    total += 1
                    if batch.count >= 150 || Date().timeIntervalSince(lastEmit) > 0.2 { emit(batch); batch = []; lastEmit = Date() }
                }
                if done { break }
            }
        }
        if !batch.isEmpty { emit(batch) }
    }
}

@MainActor struct FindView: View {
    @Environment(AppModel.self) var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var f = model.find
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search every file and folder on your Mac", text: $f.query)
                    .textFieldStyle(.plain).font(.system(size: 13)).focused($focused)
                    .onSubmit { if let s = selectedFile { NSWorkspace.shared.open(s.url) } }
                if !f.query.isEmpty {
                    Text("\(countString(f.results.count))\(f.truncated ? "+" : "") results · \(f.elapsedMS) ms").font(.system(size: 10)).foregroundStyle(.tertiary)
                    Button { f.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.bg))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(focused ? Theme.blue.opacity(0.6) : Theme.hair, lineWidth: focused ? 1.5 : 1))
            .padding(.horizontal, 60).padding(.top, 16)

            hints.padding(.horizontal, 60).padding(.top, 8)

            HStack(spacing: 6) {
                ForEach(FindModel.Filter.allCases, id: \.self) { c in
                    Button { f.filter = c } label: {
                        Label(c.rawValue, systemImage: c.icon).font(.system(size: 10.5, weight: .medium))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .foregroundStyle(f.filter == c ? Theme.inkText : Color.secondary)
                            .background(f.filter == c ? Theme.ink : Color.primary.opacity(0.05), in: Capsule())
                    }.buttonStyle(.plain)
                }
                Spacer()
                if !f.query.isEmpty {
                    Text("Sort:").font(.system(size: 10)).foregroundStyle(.tertiary)
                    Button(f.sortBest ? "Best match" : "Recently changed") { f.sortBest.toggle() }.buttonStyle(.plain).font(.system(size: 10, weight: .medium))
                }
            }.padding(.horizontal, 60).padding(.top, 10)

            Text(f.query.isEmpty ? "Changed recently · This week" : "Results \(countString(f.visible.count))")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 60).padding(.top, 14).padding(.bottom, 4)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(f.visible.prefix(500)) { r in row(r) }
                }
                .padding(.horizontal, 54)
            }
            .overlay { if f.searching && f.results.isEmpty { ProgressView().controlSize(.small) } }
            .overlay { if !f.searching && f.results.isEmpty && !f.query.isEmpty { EmptyHint(icon: "magnifyingglass", title: "Nothing found", text: "No file or folder name contains “\(f.query)”.") } }
        }
        .onAppear { focused = true; if f.results.isEmpty && f.query.isEmpty { f.restart() } }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.escape) { f.query = ""; return .handled }
    }

    var selectedFile: FoundFile? { model.find.visible.first { $0.id == model.find.selected } }

    func move(_ d: Int) {
        let l = Array(model.find.visible.prefix(500))
        guard !l.isEmpty else { return }
        let i = l.firstIndex { $0.id == model.find.selected } ?? (d > 0 ? -1 : l.count)
        model.find.selected = l[max(0, min(l.count - 1, i + d))].id
    }

    var hints: some View {
        HStack(spacing: 12) {
            hint("↑↓", "Move"); hint("⏎", "Open")
            Button { if let s = selectedFile { FS.reveal(s.url) } } label: { hint("⌘R", "Reveal") }.buttonStyle(.plain).keyboardShortcut("r", modifiers: .command)
            Button { if let s = selectedFile { Task { _ = await Shell.run("/usr/bin/qlmanage", ["-p", s.url.path], timeout: 20) } } } label: { hint("⌘Y", "Quick Look") }.buttonStyle(.plain).keyboardShortcut("y", modifiers: .command)
            hint("esc", "Clear")
            Spacer()
            if let n = model.activity.lastScan?.itemsScanned { Text("Across \(countString(n)) items").font(.system(size: 10)).foregroundStyle(.tertiary) }
        }
    }
    func hint(_ k: String, _ t: String) -> some View {
        HStack(spacing: 4) {
            Text(k).font(.system(size: 9, weight: .semibold)).padding(.horizontal, 4).padding(.vertical, 1).background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 3))
            Text(t).font(.system(size: 9.5))
        }.foregroundStyle(.tertiary)
    }

    func row(_ r: FoundFile) -> some View {
        let f = model.find
        return HStack(spacing: 10) {
            FileIcon(url: r.url, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(r.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(abbreviated(r.url.deletingLastPathComponent().path).replacingOccurrences(of: "/", with: " › "))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer()
            Text(r.isDir ? "Folder" : (r.url.pathExtension.isEmpty ? "File" : r.url.pathExtension.uppercased()))
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1.5).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 3))
            Text(bytesString(r.size)).font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
            Text(relativeDate(r.modified)).font(.system(size: 10)).foregroundStyle(.tertiary).frame(width: 90, alignment: .trailing)
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(f.selected == r.id ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSWorkspace.shared.open(r.url) }
        .onTapGesture { f.selected = r.id }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(r.url) }
            Button("Reveal in Finder") { FS.reveal(r.url) }
            Button("Add to Cleanup") { model.stage([CleanItem(url: r.url, size: r.isDir ? FS.tree(r.url).bytes : r.size)]) }
            Button("Copy path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(r.url.path, forType: .string) }
        }
    }
}
