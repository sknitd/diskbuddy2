import SwiftUI
import Observation

struct AppPart: Identifiable { let id = UUID(); let label: String; let color: Color; let bytes: Int64; let paths: [URL] }

struct AppEntry: Identifiable, Hashable {
    let url: URL
    let name: String
    let bundleID: String
    let version: String
    var bundleSize: Int64?
    var parts: [Int]? = nil   // placeholder to keep Hashable simple
    var leftover: Int64?
    var id: String { url.path }
    var total: Int64 { (bundleSize ?? 0) + (leftover ?? 0) }
    func hash(into h: inout Hasher) { h.combine(id) }
    static func == (a: AppEntry, b: AppEntry) -> Bool { a.id == b.id && a.bundleSize == b.bundleSize && a.leftover == b.leftover }
}

struct UpdateRow: Identifiable { let id = UUID(); let title: String; let detail: String }
struct LoginRow: Identifiable { let id = UUID(); let label: String; let program: String; let url: URL }

@Observable @MainActor
final class AppsModel {
    enum SubTab { case apps, updates, login }
    weak var app: AppModel?
    var entries: [AppEntry] = []
    var selected: String?
    var search = ""
    var sub: SubTab = .apps
    var loading = false
    var loaded = false
    var parts: [String: [AppPart]] = [:]
    var updates: [UpdateRow] = []
    var updatesLoaded = false
    var logins: [LoginRow] = []

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true; loading = true
        let home = FS.home
        let dirs = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        var list: [AppEntry] = []
        for d in dirs {
            for u in FS.children(d) where u.pathExtension == "app" {
                let info = Bundle(url: u)?.infoDictionary ?? [:]
                let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? u.deletingPathExtension().lastPathComponent
                list.append(AppEntry(url: u, name: name, bundleID: info["CFBundleIdentifier"] as? String ?? "",
                                     version: info["CFBundleShortVersionString"] as? String ?? ""))
            }
        }
        entries = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        selected = nil
        Task { [weak self] in
            let urls = list.map(\.url)
            await FS.parallel(urls, limit: 6, work: { await FS.treeAsync($0).bytes }, onResult: { i, b in
                guard let self, let idx = self.entries.firstIndex(where: { $0.url == urls[i] }) else { return }
                self.entries[idx].bundleSize = b
            })
            self?.entries.sort { $0.total > $1.total }
            if self?.selected == nil { self?.selected = self?.entries.first?.id }
            let snapshot = self?.entries ?? []
            await FS.parallel(snapshot, limit: 4, work: { e in
                let p = AppsModel.leftovers(for: e)
                return p
            }, onResult: { i, p in
                guard let self, let idx = self.entries.firstIndex(where: { $0.id == snapshot[i].id }) else { return }
                self.parts[snapshot[i].id] = p
                self.entries[idx].leftover = p.filter { $0.label != "App bundle" }.reduce(0) { $0 + $1.bytes }
            })
            self?.entries.sort { $0.total > $1.total }
            self?.loading = false
        }
    }

    nonisolated static func leftovers(for e: AppEntry) -> [AppPart] {
        let lib = FS.home.appendingPathComponent("Library")
        let id = e.bundleID, name = e.url.deletingPathExtension().lastPathComponent
        func existing(_ paths: [URL]) -> [URL] { paths.filter { FS.fm.fileExists(atPath: $0.path) } }
        func sum(_ urls: [URL]) -> Int64 { urls.reduce(0) { $0 + FS.tree($1).bytes } }
        var containers = existing(id.isEmpty ? [] : [lib.appendingPathComponent("Containers/\(id)")])
        let group = FS.children(lib.appendingPathComponent("Group Containers")).filter { !id.isEmpty && $0.lastPathComponent.hasSuffix(id) }
        containers += group
        var prefs = existing(id.isEmpty ? [] : [lib.appendingPathComponent("Preferences/\(id).plist"),
                                                  lib.appendingPathComponent("Saved Application State/\(id).savedState")])
        prefs += FS.children(lib.appendingPathComponent("Preferences/ByHost")).filter { !id.isEmpty && $0.lastPathComponent.hasPrefix(id) }
        var other = existing(([name] + (id.isEmpty ? [] : [id])).map { lib.appendingPathComponent("Application Support/\($0)") })
        other += existing((id.isEmpty ? [] : [lib.appendingPathComponent("Caches/\(id)"), lib.appendingPathComponent("HTTPStorages/\(id)"),
                                              lib.appendingPathComponent("WebKit/\(id)")]) + [lib.appendingPathComponent("Caches/\(name)"), lib.appendingPathComponent("Logs/\(name)")])
        var out: [AppPart] = [AppPart(label: "App bundle", color: Color.primary.opacity(0.45), bytes: FS.tree(e.url).bytes, paths: [e.url])]
        for (label, color, urls) in [("Containers", Theme.blue, containers), ("Preferences", Theme.purple, prefs), ("Other", Theme.orange, other)] {
            out.append(AppPart(label: label, color: color, bytes: sum(urls), paths: urls))
        }
        return out
    }

    var filtered: [AppEntry] {
        search.isEmpty ? entries : entries.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    func cachePaths(for e: AppEntry) -> [URL] {
        let lib = FS.home.appendingPathComponent("Library")
        let id = e.bundleID, name = e.url.deletingPathExtension().lastPathComponent
        let c = [lib.appendingPathComponent("Caches/\(id)"), lib.appendingPathComponent("Caches/\(name)"),
                 lib.appendingPathComponent("HTTPStorages/\(id)"), lib.appendingPathComponent("WebKit/\(id)"),
                 lib.appendingPathComponent("Containers/\(id)/Data/Library/Caches")]
        return id.isEmpty ? [] : c.filter { FS.fm.fileExists(atPath: $0.path) }
    }

    func clearCaches(_ e: AppEntry) {
        let items = cachePaths(for: e).map { CleanItem(url: $0, size: FS.tree($0).bytes) }
        guard !items.isEmpty else { app?.showToast("No caches found for \(e.name)"); return }
        Task.detached {
            let (ok, _) = FS.trash(items)
            let bytes = ok.reduce(0) { $0 + $1.size }
            await MainActor.run {
                self.app?.activity.record(.cleanup, title: "Cleared caches", detail: e.name, bytes: bytes)
                self.app?.showToast("Cleared \(bytesString(bytes)) of \(e.name) caches")
                self.recompute(e)
            }
        }
    }

    func recompute(_ e: AppEntry) {
        Task { [weak self] in
            let p = await Task.detached { AppsModel.leftovers(for: e) }.value
            guard let self, let idx = self.entries.firstIndex(where: { $0.id == e.id }) else { return }
            self.parts[e.id] = p
            self.entries[idx].leftover = p.filter { $0.label != "App bundle" }.reduce(0) { $0 + $1.bytes }
        }
    }

    func uninstall(_ e: AppEntry) {
        let p = parts[e.id] ?? []
        let total = e.total
        let a = NSAlert()
        a.messageText = "Uninstall \(e.name) completely?"
        a.informativeText = "\(e.name) and \(bytesString(total - (e.bundleSize ?? 0))) of its data will be moved to the Trash (\(bytesString(total)) in all). You can put them back from the Trash."
        a.addButton(withTitle: "Move to Trash"); a.addButton(withTitle: "Cancel")
        a.alertStyle = .warning
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let items = p.flatMap { $0.paths }.map { CleanItem(url: $0, size: FS.size(of: $0)) }
        Task.detached {
            let (ok, failed) = FS.trash(items)
            await MainActor.run {
                if ok.contains(where: { $0.path == e.url.path }) {
                    self.entries.removeAll { $0.id == e.id }
                    self.selected = self.entries.first?.id
                    self.app?.activity.record(.uninstall, title: "Uninstalled \(e.name)", detail: "\(ok.count) items", bytes: total)
                    self.app?.showToast("Uninstalled \(e.name)")
                } else {
                    self.app?.showToast("Couldn't move \(e.name) to the Trash\(failed.isEmpty ? "" : " — check permissions")")
                }
            }
        }
    }

    func loadUpdates() {
        guard !updatesLoaded else { return }
        updatesLoaded = true
        Task { [weak self] in
            let out = await Shell.run("/usr/sbin/softwareupdate", ["-l"], timeout: 90)
            var rows: [UpdateRow] = []
            for line in out.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("Title:") {
                    let parts = t.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    let title = parts.first.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) } ?? t
                    rows.append(UpdateRow(title: title, detail: parts.dropFirst().joined(separator: " · ")))
                }
            }
            self?.updates = rows
        }
    }

    func loadLogins() {
        let home = FS.home
        let dirs = [home.appendingPathComponent("Library/LaunchAgents"), URL(fileURLWithPath: "/Library/LaunchAgents"), URL(fileURLWithPath: "/Library/LaunchDaemons")]
        var rows: [LoginRow] = []
        for d in dirs {
            for u in FS.children(d) where u.pathExtension == "plist" {
                guard let dict = NSDictionary(contentsOf: u) as? [String: Any] else { continue }
                let label = dict["Label"] as? String ?? u.deletingPathExtension().lastPathComponent
                let prog = (dict["Program"] as? String) ?? (dict["ProgramArguments"] as? [String])?.first ?? ""
                rows.append(LoginRow(label: label, program: prog, url: u))
            }
        }
        logins = rows.sorted { $0.label < $1.label }
    }
}

@MainActor struct ApplicationsView: View {
    @Environment(AppModel.self) var model
    var body: some View {
        @Bindable var a = model.apps
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                subTab("Apps", .apps)
                subTab("Updates\(a.updatesLoaded ? " \(a.updates.count)" : "")", .updates)
                subTab("Login items", .login)
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(.tertiary)
                    TextField("Search apps", text: $a.search).textFieldStyle(.plain).font(.system(size: 11))
                }
                .padding(.horizontal, 8).padding(.vertical, 5).frame(width: 220)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 8)
            switch a.sub {
            case .apps: AppsList()
            case .updates: UpdatesList()
            case .login: LoginList()
            }
        }
        .onAppear { a.loadIfNeeded() }
    }

    func subTab(_ t: String, _ s: AppsModel.SubTab) -> some View {
        let on = model.apps.sub == s
        return Button {
            model.apps.sub = s
            if s == .updates { model.apps.loadUpdates() }
            if s == .login { model.apps.loadLogins() }
        } label: {
            Text(t).font(.system(size: 11, weight: on ? .semibold : .regular))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(on ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(on ? Color.primary : Color.secondary)
        }.buttonStyle(.plain)
    }
}

@MainActor struct AppsList: View {
    @Environment(AppModel.self) var model
    var body: some View {
        let a = model.apps
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    let mx = Double(a.entries.map(\.total).max() ?? 1)
                    ForEach(a.filtered) { e in
                        HStack(spacing: 10) {
                            FileIcon(url: e.url, size: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                                Text(e.version.isEmpty || e.version.contains("$") ? " " : "Version \(e.version)").font(.system(size: 10)).foregroundStyle(.secondary)
                            }.frame(width: 220, alignment: .leading)
                            GeometryReader { g in
                                let w = max(4, g.size.width * CGFloat(Double(e.total) / max(mx, 1)))
                                let leftFrac = e.total > 0 ? Double(e.leftover ?? 0) / Double(e.total) : 0
                                HStack(spacing: 0) {
                                    Capsule().fill(Color.primary.opacity(0.3)).frame(width: w * CGFloat(1 - leftFrac))
                                    Capsule().fill(Theme.pink).frame(width: w * CGFloat(leftFrac))
                                }.frame(maxHeight: .infinity, alignment: .leading)
                            }.frame(height: 3)
                            Text(e.bundleSize == nil ? "…" : bytesString(e.total)).font(.system(size: 11.5)).monospacedDigit().frame(width: 72, alignment: .trailing)
                        }
                        .padding(.vertical, 6).padding(.horizontal, 10)
                        .background(a.selected == e.id ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                        .onTapGesture { a.selected = e.id }
                    }
                }
                .padding(.horizontal, 12)
            }
            AppDetail().frame(width: 270).padding(.trailing, 14).padding(.bottom, 14)
        }
    }
}

@MainActor struct AppDetail: View {
    @Environment(AppModel.self) var model
    var body: some View {
        let a = model.apps
        if let e = a.entries.first(where: { $0.id == a.selected }) {
            let parts = a.parts[e.id] ?? []
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    FileIcon(url: e.url, size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                        Text(e.version.isEmpty || e.version.contains("$") ? "" : "Version \(e.version)").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Text(bytesString(e.total)).font(.system(size: 26, weight: .semibold)).monospacedDigit().padding(.top, 12)
                if let l = e.leftover {
                    Text("\(bytesString(l)) of it lives outside the app bundle").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                VStack(spacing: 5) {
                    ForEach(parts) { p in
                        HStack(spacing: 7) {
                            Circle().fill(p.color).frame(width: 6, height: 6)
                            Text(p.label).foregroundStyle(.secondary)
                            Spacer()
                            Text(bytesShort(p.bytes)).monospacedDigit()
                        }.font(.system(size: 10.5))
                    }
                }.padding(.top, 10)
                cpuSection(e)
                Spacer()
                HStack {
                    Button("Clear caches") { a.clearCaches(e) }.buttonStyle(SoftButtonStyle()).disabled(a.cachePaths(for: e).isEmpty)
                    Spacer()
                    Button("Uninstall completely") { a.uninstall(e) }.buttonStyle(DarkButtonStyle())
                }
            }
            .padding(14).background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        } else {
            Color.clear
        }
    }

    @ViewBuilder func cpuSection(_ e: AppEntry) -> some View {
        let key = e.url.deletingPathExtension().lastPathComponent
        VStack(alignment: .leading, spacing: 4) {
            Text("CPU over the last day").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 14)
            if let h = model.monitor.hourly(for: key) {
                Spark(values: h.values).stroke(Theme.blue, lineWidth: 1).frame(height: 38)
                Text("Busiest at \(h.busiest ?? "—"), peaking at \(Int(h.peak))%").font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                Text("Nothing recorded for \(e.name) yet. DiskBuddy takes a reading every half minute while it's open.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor struct UpdatesList: View {
    @Environment(AppModel.self) var model
    var body: some View {
        let a = model.apps
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !a.updatesLoaded || (a.updates.isEmpty && a.updatesLoaded && model.apps.sub == .updates && false) {
                    ProgressView().controlSize(.small).padding(30)
                } else if a.updates.isEmpty {
                    EmptyHint(icon: "checkmark.circle", title: "Everything is up to date", text: "No macOS or App Store updates are waiting.").frame(maxWidth: .infinity).padding(.top, 60)
                } else {
                    ForEach(a.updates) { u in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(u.title).font(.system(size: 11.5, weight: .medium))
                            Text(u.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                        }.padding(.vertical, 8)
                        Hairline().opacity(0.5)
                    }
                    Button("Open Software Update") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!) }
                        .buttonStyle(SoftButtonStyle()).padding(.top, 12)
                }
            }.padding(.horizontal, 28)
        }
    }
}

@MainActor struct LoginList: View {
    @Environment(AppModel.self) var model
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text("Background items that start with your Mac. Reveal one to remove it yourself.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).padding(.bottom, 8)
                ForEach(model.apps.logins) { l in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(l.label).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                            Text(abbreviated(l.program)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button("Reveal") { FS.reveal(l.url) }.buttonStyle(SoftButtonStyle())
                    }.padding(.vertical, 6)
                    Hairline().opacity(0.5)
                }
            }.padding(.horizontal, 28)
        }
    }
}
