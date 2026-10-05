import SwiftUI
import Observation

struct SpaceNode: Identifiable, Hashable {
    let url: URL
    var size: Int64?
    var items: Int?
    let isDir: Bool
    let isSymlink: Bool
    let modified: Date?
    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

@Observable @MainActor
final class SpaceModel {
    enum Mode { case map, largest }
    weak var app: AppModel?
    var trail: [URL] = [URL(fileURLWithPath: "/")]
    var nodes: [SpaceNode] = []
    var selected: String?
    var mode: Mode = .map
    var loading = false
    var currentSize: Int64?
    var currentItems: Int?
    private var cache: [String: (Int64, Int)] = [:]
    private var generation = 0
    private static let skip: Set<String> = ["/Volumes", "/dev", "/System/Volumes", "/cores", "/.vol"]

    var current: URL { trail.last! }

    func loadIfNeeded() { if nodes.isEmpty && !loading { load() } }

    func open(_ url: URL) { trail.append(url); selected = nil; load() }
    func up() { guard trail.count > 1 else { return }; trail.removeLast(); selected = nil; load() }
    func jump(to i: Int) { trail = Array(trail.prefix(i + 1)); selected = nil; load() }

    func load() {
        generation += 1
        let gen = generation
        let dir = current
        let kids = FS.children(dir).filter { !Self.skip.contains($0.path) }
        nodes = kids.map { u in
            let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
            let sym = v?.isSymbolicLink == true
            let cached = cache[u.path]
            return SpaceNode(url: u, size: sym ? 0 : cached?.0, items: sym ? 1 : cached?.1,
                             isDir: v?.isDirectory == true && !sym, isSymlink: sym, modified: v?.contentModificationDate)
        }
        currentSize = cache[dir.path]?.0
        currentItems = cache[dir.path]?.1
        let pending = nodes.filter { $0.size == nil }.map(\.url)
        loading = !pending.isEmpty
        if pending.isEmpty { return }
        Task { [weak self] in
            await FS.parallel(pending, limit: 6, work: { url in
                await FS.treeAsync(url, cancel: { false })
            }, onResult: { i, r in
                guard let self, gen == self.generation else { return }
                self.cache[pending[i].path] = (r.bytes, r.items)
                if let idx = self.nodes.firstIndex(where: { $0.url == pending[i] }) {
                    self.nodes[idx].size = r.bytes; self.nodes[idx].items = r.items
                }
                self.currentSize = self.nodes.reduce(0) { $0 + ($1.size ?? 0) }
                self.currentItems = self.nodes.reduce(0) { $0 + ($1.items ?? 0) }
            })
            guard let self, gen == self.generation else { return }
            self.loading = false
            self.cache[dir.path] = (self.currentSize ?? 0, self.currentItems ?? 0)
        }
    }

    var sorted: [SpaceNode] { nodes.sorted { ($0.size ?? -1) > ($1.size ?? -1) } }
    var selectedNode: SpaceNode? { nodes.first { $0.id == selected } }

    func cleanItem(_ n: SpaceNode) -> CleanItem { CleanItem(url: n.url, size: n.size ?? FS.size(of: n.url)) }
}

// MARK: - Treemap

func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
    var rects = [CGRect](repeating: .zero, count: values.count)
    let total = values.reduce(0, +)
    guard total > 0, rect.width > 0, rect.height > 0 else { return rects }
    let scale = Double(rect.width * rect.height) / total
    let areas = values.map { $0 * scale }
    var r = rect
    var i = 0
    func worst(_ row: ArraySlice<Double>, _ side: Double) -> Double {
        let s = row.reduce(0, +)
        guard s > 0, let mx = row.max(), let mn = row.min() else { return .infinity }
        return max(side * side * mx / (s * s), s * s / (side * side * mn))
    }
    while i < areas.count {
        let side = Double(min(r.width, r.height))
        var j = i + 1
        while j < areas.count, worst(areas[i...j], side) <= worst(areas[i..<j], side) { j += 1 }
        let row = areas[i..<j]
        let s = row.reduce(0, +)
        if r.width >= r.height {
            let w = CGFloat(s / Double(r.height)); var y = r.minY
            for k in i..<j { let h = CGFloat(areas[k]) / w; rects[k] = CGRect(x: r.minX, y: y, width: w, height: h); y += h }
            r = CGRect(x: r.minX + w, y: r.minY, width: r.width - w, height: r.height)
        } else {
            let h = CGFloat(s / Double(r.width)); var x = r.minX
            for k in i..<j { let w = CGFloat(areas[k]) / h; rects[k] = CGRect(x: x, y: r.minY, width: w, height: h); x += w }
            r = CGRect(x: r.minX, y: r.minY + h, width: r.width, height: r.height - h)
        }
        i = j
    }
    return rects
}

@MainActor struct SpaceView: View {
    @Environment(AppModel.self) var model

    var body: some View {
        @Bindable var space = model.space
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    breadcrumb
                    Spacer()
                    Seg(options: [(SpaceModel.Mode.map, "Map"), (.largest, "Largest")], sel: $space.mode)
                }
                if space.nodes.isEmpty && !space.loading {
                    EmptyHint(icon: "folder", title: "Empty folder", text: "Nothing to show here.").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if space.mode == .map {
                    TreemapView()
                } else {
                    LargestList()
                }
            }
            .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 16)
            SpaceInspector().frame(width: 260).padding(.trailing, 14).padding(.top, 14).padding(.bottom, 16)
        }
        .onAppear { space.loadIfNeeded() }
    }

    var breadcrumb: some View {
        let s = model.space
        return HStack(spacing: 6) {
            if s.trail.count > 1 {
                Button { s.up() } label: { Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold)) }.buttonStyle(.plain)
            }
            ForEach(Array(s.trail.enumerated()), id: \.offset) { i, u in
                if i > 0 { Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.tertiary) }
                Button { if i < s.trail.count - 1 { s.jump(to: i) } } label: {
                    Text(i == 0 ? model.cleanup.disk.name : u.lastPathComponent)
                        .font(.system(size: 12, weight: i == s.trail.count - 1 ? .semibold : .regular))
                        .foregroundStyle(i == s.trail.count - 1 ? Color.primary : Color.secondary)
                }.buttonStyle(.plain)
            }
            if s.loading { ProgressView().controlSize(.mini).padding(.leading, 4) }
        }
    }
}

@MainActor struct TreemapView: View {
    @Environment(AppModel.self) var model
    var body: some View {
        let s = model.space
        let nodes = Array(s.sorted.filter { ($0.size ?? 0) > 0 }.prefix(48))
        GeometryReader { geo in
            let rects = squarify(nodes.map { Double($0.size ?? 0) }, in: CGRect(origin: .zero, size: geo.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(nodes.enumerated()), id: \.element.id) { i, n in
                    let r = rects[i].insetBy(dx: 1.5, dy: 1.5)
                    if r.width > 2 && r.height > 2 {
                        let on = s.selected == n.id
                        ZStack(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.primary.opacity(0.07 + 0.16 * (1 - Double(i) / Double(max(nodes.count, 1)))))
                            RoundedRectangle(cornerRadius: 5).stroke(on ? Color.primary : .clear, lineWidth: 1.5)
                            if r.width > 54 && r.height > 30 {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(n.name).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                                    Text(bytesString(n.size ?? 0)).font(.system(size: 10)).foregroundStyle(.secondary)
                                }.padding(7)
                            }
                        }
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { if n.isDir { s.open(n.url) } }
                        .onTapGesture { s.selected = n.id }
                    }
                }
            }
        }
    }
}

@MainActor struct LargestList: View {
    @Environment(AppModel.self) var model
    var body: some View {
        let s = model.space
        let list = s.sorted
        let mx = Double(list.first?.size ?? 1)
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(list) { n in
                    HStack(spacing: 10) {
                        FileIcon(url: n.url, size: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(n.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                            Text(abbreviated(n.url.path)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(width: 220, alignment: .leading)
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.06))
                                Capsule().fill(Color.primary.opacity(0.35))
                                    .frame(width: max(2, g.size.width * CGFloat(Double(n.size ?? 0) / max(mx, 1))))
                            }
                        }.frame(height: 3)
                        if let sz = n.size { Text(bytesString(sz)).font(.system(size: 11.5)).monospacedDigit().frame(width: 72, alignment: .trailing) }
                        else { ProgressView().controlSize(.mini).frame(width: 72, alignment: .trailing) }
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(n.isDir ? .tertiary : .quaternary)
                    }
                    .padding(.vertical, 6).padding(.horizontal, 8)
                    .background(s.selected == n.id ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { if n.isDir { s.open(n.url) } }
                    .onTapGesture { s.selected = n.id }
                }
            }
        }
    }
}

@MainActor struct SpaceInspector: View {
    @Environment(AppModel.self) var model
    var body: some View {
        let s = model.space
        let node = s.selectedNode
        let url = node?.url ?? s.current
        let size = node != nil ? node?.size : s.currentSize
        let items = node != nil ? node?.items : s.currentItems
        let mod = node != nil ? node?.modified : FS.modified(s.current)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                FileIcon(url: url, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(node?.name ?? (s.trail.count == 1 ? model.cleanup.disk.name : url.lastPathComponent)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(abbreviated(url.path)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Text(size.map(bytesString) ?? "Measuring…").font(.system(size: 26, weight: .semibold)).monospacedDigit().padding(.top, 14)
            VStack(spacing: 6) {
                kv("Items", items.map(countString) ?? "—")
                if model.cleanup.disk.total > 0, let size {
                    kv("Disk used", "\(Int((Double(size) / Double(model.cleanup.disk.total) * 100).rounded()))%")
                }
                kv("Modified", mod.map(relativeDate) ?? "—")
            }.padding(.top, 10)
            if let size, model.cleanup.disk.total > 0 {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(Color.primary.opacity(0.5)).frame(width: max(2, g.size.width * CGFloat(Double(size) / Double(model.cleanup.disk.total))))
                    }
                }.frame(height: 4).padding(.top, 12)
            }
            Spacer()
            HStack(spacing: 8) {
                Button("Reveal in Finder") { FS.reveal(url) }.buttonStyle(SoftButtonStyle())
                Button("Open") { s.selectedNode.map { if $0.isDir { s.open($0.url) } } }
                    .buttonStyle(SoftButtonStyle()).disabled(!(node?.isDir ?? false))
            }
            Button("Add to Cleanup") { if let n = node { model.stage([s.cleanItem(n)]) } }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(node == nil ? Color.primary.opacity(0.3) : Color.primary.opacity(0.7))
                .disabled(node == nil).padding(.top, 10)
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
    }
    func kv(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v).monospacedDigit() }.font(.system(size: 10.5))
    }
}
