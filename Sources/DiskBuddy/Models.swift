import SwiftUI
import Observation
import AppKit

enum Tab: String, CaseIterable, Identifiable {
    case overview, space, cleanup, duplicates, applications, monitor, activity, find, compress
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .space: "square.split.2x1"
        case .cleanup: "paintbrush.pointed"
        case .duplicates: "square.on.square"
        case .applications: "square.stack.3d.up"
        case .monitor: "waveform.path.ecg"
        case .activity: "clock.arrow.circlepath"
        case .find: "magnifyingglass"
        case .compress: "rectangle.compress.vertical"
        }
    }
}

// MARK: - App model

@Observable @MainActor
final class AppModel {
    var tab: Tab = .overview
    var toast: String?
    let scan = ScanModel()
    let cleanup = CleanupModel()
    let activity = ActivityStore()
    let monitor = MonitorModel()
    let space = SpaceModel()
    let dupes = DupesModel()
    let apps = AppsModel()
    let find = FindModel()
    let compress = CompressModel()
    private var toastTask: Task<Void, Never>?

    init() {
        cleanup.app = self; scan.app = self; space.app = self; dupes.app = self
        apps.app = self; compress.app = self; find.app = self; monitor.app = self
    }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            if !Task.isCancelled { withAnimation { self?.toast = nil } }
        }
    }

    func stage(_ items: [CleanItem]) {
        cleanup.stage(items)
        showToast(items.count == 1 ? "Added to Cleanup" : "Added \(items.count) items to Cleanup")
    }

    func go(_ t: Tab) { withAnimation(.easeOut(duration: 0.15)) { tab = t } }
}

// MARK: - Scan

@Observable @MainActor
final class ScanModel {
    enum Phase { case idle, scanning, done }
    weak var app: AppModel?
    var phase: Phase = .idle
    var progress: Double = 0
    var currentPath = ""
    var result: ScanResult?
    var sorting = false

    func start() {
        guard phase != .scanning else { return }
        phase = .scanning; progress = 0; currentPath = ""; sorting = false
        let prog = ScanProgress()
        let ticker = Task { [weak self] in
            while !Task.isCancelled {
                let (p, path) = prog.snapshot
                if let self {
                    withAnimation(.linear(duration: 0.12)) { self.progress = max(self.progress, min(p, 0.99)) }
                    self.currentPath = path
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        Task.detached(priority: .userInitiated) {
            let r = Scanner.run(progress: prog)
            ticker.cancel()
            await MainActor.run {
                withAnimation { self.progress = 1; self.sorting = true }
            }
            try? await Task.sleep(nanoseconds: 450_000_000)
            await MainActor.run {
                self.result = r
                self.sorting = false
                withAnimation(.easeOut(duration: 0.3)) { self.phase = .done }
                self.app?.cleanup.load(groups: r.groups, disk: r.disk)
                self.app?.activity.recordScan(r)
            }
        }
    }
}

// MARK: - Cleanup

@Observable @MainActor
final class CleanupModel {
    weak var app: AppModel?
    var groups: [CleanGroup] = []
    var staged: [CleanItem] = []
    var selected: Set<String> = []
    var openGroup: GroupID?
    var disk = DiskInfo.read()
    var working = false
    var lastDeleted: Int64 = 0

    func load(groups: [CleanGroup], disk: DiskInfo) {
        self.groups = groups
        self.disk = disk
        selected = []
        for g in groups where g.id.ticksByDefault { for it in g.items { selected.insert(it.id) } }
        staged = staged.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func stage(_ items: [CleanItem]) {
        for it in items where !staged.contains(where: { $0.id == it.id }) {
            staged.append(it); selected.insert(it.id)
        }
    }

    func state(of ids: [String]) -> Bool? {
        guard !ids.isEmpty else { return false }
        let n = ids.filter { selected.contains($0) }.count
        return n == 0 ? false : (n == ids.count ? true : nil)
    }
    func state(of g: CleanGroup) -> Bool? { state(of: g.items.map(\.id)) }
    func state(of gs: [GroupID]) -> Bool? { state(of: groups.filter { gs.contains($0.id) }.flatMap { $0.items.map(\.id) }) }

    func toggle(ids: [String]) {
        if state(of: ids) == true { ids.forEach { selected.remove($0) } } else { ids.forEach { selected.insert($0) } }
    }
    func toggle(group g: CleanGroup) { toggle(ids: g.items.map(\.id)) }
    func toggle(item: CleanItem) {
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }

    var selectedItems: [CleanItem] {
        var seen = Set<String>(); var out: [CleanItem] = []
        for it in groups.flatMap(\.items) + staged where selected.contains(it.id) && !seen.contains(it.id) {
            seen.insert(it.id); out.append(it)
        }
        return out
    }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    var tickedGroups: Int {
        groups.filter { g in g.items.contains { selected.contains($0.id) } }.count + (staged.contains { selected.contains($0.id) } ? 1 : 0)
    }
    func bytes(in gs: [GroupID]) -> Int64 { groups.filter { gs.contains($0.id) }.reduce(0) { $0 + $1.size } }
    func count(in gs: [GroupID]) -> Int { groups.filter { gs.contains($0.id) }.reduce(0) { $0 + $1.items.count } }

    func trashSelected() { trash(selectedItems) }

    func trash(_ items: [CleanItem]) {
        guard !items.isEmpty, !working else { return }
        working = true
        Task.detached {
            let (ok, failed) = FS.trash(items)
            await MainActor.run {
                self.working = false
                let ids = Set(ok.map(\.id))
                for i in self.groups.indices {
                    let removed = self.groups[i].items.filter { ids.contains($0.id) }
                    self.groups[i].trashedBytes += removed.reduce(0) { $0 + $1.size }
                    self.groups[i].items.removeAll { ids.contains($0.id) }
                }
                self.staged.removeAll { ids.contains($0.id) }
                self.selected.subtract(ids)
                self.disk = DiskInfo.read()
                let bytes = ok.reduce(0) { $0 + $1.size }
                self.lastDeleted = bytes
                if !ok.isEmpty {
                    self.app?.activity.record(.cleanup, title: "Deleted \(ok.count) item\(ok.count == 1 ? "" : "s")",
                                              detail: ok.prefix(3).map(\.name).joined(separator: ", "), bytes: bytes)
                    self.app?.showToast("Deleted \(ok.count) items")
                }
                if !failed.isEmpty { self.app?.showToast("Couldn't move \(failed.count) item(s): \(failed.first ?? "")") }
            }
        }
    }
}

// MARK: - Activity

struct ActivityEvent: Codable, Identifiable {
    enum Kind: String, Codable { case cleanup, scan, uninstall, compress, stop }
    var id = UUID()
    var date: Date
    var kind: Kind
    var title: String
    var detail: String
    var bytes: Int64
}

struct FolderSnapshot: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var label: String
    var folders: [String: Int64]
}

@Observable @MainActor
final class ActivityStore {
    var events: [ActivityEvent] = []
    var snapshots: [FolderSnapshot] = []
    var lastScan: ScanResult?

    private static var dir: URL {
        let d = FS.fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DiskBuddy")
        try? FS.fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private var file: URL { Self.dir.appendingPathComponent("activity.json") }
    private var snapFile: URL { Self.dir.appendingPathComponent("snapshots.json") }

    init() {
        if let d = try? Data(contentsOf: file), let e = try? JSONDecoder().decode([ActivityEvent].self, from: d) { events = e }
        if let d = try? Data(contentsOf: snapFile), let s = try? JSONDecoder().decode([FolderSnapshot].self, from: d) { snapshots = s }
    }

    func record(_ kind: ActivityEvent.Kind, title: String, detail: String = "", bytes: Int64 = 0) {
        events.insert(.init(date: Date(), kind: kind, title: title, detail: detail, bytes: bytes), at: 0)
        if let d = try? JSONEncoder().encode(events) { try? d.write(to: file) }
    }

    func recordScan(_ r: ScanResult) {
        lastScan = r
        record(.scan, title: "Scanned \(r.disk.name)", detail: "\(countString(r.itemsScanned)) files in \(Int(r.duration.rounded())) s",
               bytes: r.disk.used)
    }

    func saveSnapshot() {
        guard let r = lastScan else { return }
        let df = DateFormatter(); df.dateFormat = "d MMM"
        snapshots.insert(.init(date: Date(), label: df.string(from: Date()), folders: r.folders), at: 0)
        if let d = try? JSONEncoder().encode(snapshots) { try? d.write(to: snapFile) }
    }

    // Derived
    var given: [ActivityEvent] { events.filter { [.cleanup, .uninstall, .compress].contains($0.kind) } }
    var givenBack: Int64 { given.reduce(0) { $0 + $1.bytes } }
    var cleanups: [ActivityEvent] { events.filter { $0.kind == .cleanup } }
    var uninstalls: [ActivityEvent] { events.filter { $0.kind == .uninstall } }
    var compressions: [ActivityEvent] { events.filter { $0.kind == .compress } }
    var scans: [ActivityEvent] { events.filter { $0.kind == .scan } }
}
