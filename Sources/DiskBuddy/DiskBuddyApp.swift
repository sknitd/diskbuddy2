import SwiftUI

@main
@MainActor struct DiskBuddyApp: App {
    @State private var model = AppModel()
    @AppStorage("appearance") private var appearance = "auto"

    var scheme: ColorScheme? { appearance == "light" ? .light : appearance == "dark" ? .dark : nil }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(scheme)
                .frame(minWidth: 1020, minHeight: 640)
                .task {
                    model.monitor.start()
                    model.scan.start()
                    await SelfSnapshot.runIfRequested(model: model)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1230, height: 740)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

@MainActor struct RootView: View {
    @Environment(AppModel.self) var model
    @State private var showSettings = false
    @AppStorage("appearance") private var appearance = "auto"

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Hairline().opacity(0.6)
            Group {
                switch model.tab {
                case .overview: OverviewView()
                case .space: SpaceView()
                case .cleanup: CleanupView()
                case .duplicates: DuplicatesView()
                case .applications: ApplicationsView()
                case .monitor: MonitorView()
                case .activity: ActivityView()
                case .find: FindView()
                case .compress: CompressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.bg)
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .top) {
            if let t = model.toast {
                Text(t)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.inkText)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Theme.ink, in: Capsule())
                    .padding(.top, 58)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.toast)
        .onChange(of: model.tab) { _, t in model.monitor.visible = (t == .monitor) }
    }

    var topBar: some View {
        ZStack {
            HStack(spacing: 4) {
                ForEach(Tab.allCases) { t in tabButton(t) }
            }
            HStack {
                Spacer()
                Button { showSettings.toggle() } label: {
                    Image(systemName: "gearshape").font(.system(size: 13)).foregroundStyle(.secondary)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showSettings, arrowEdge: .bottom) { SettingsPopover() }
                .padding(.trailing, 14)
            }
        }
        .frame(height: 46)
        .padding(.top, 4)
    }

    func tabButton(_ t: Tab) -> some View {
        let on = model.tab == t
        return Button { model.go(t) } label: {
            HStack(spacing: 5) {
                Image(systemName: t.icon).font(.system(size: 11))
                Text(t.title).font(.system(size: 12, weight: on ? .semibold : .regular))
                if t == .cleanup, model.cleanup.tickedGroups > 0 {
                    Text("\(model.cleanup.tickedGroups)")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.inkText)
                        .frame(minWidth: 14, minHeight: 14).padding(.horizontal, 2)
                        .background(Theme.ink, in: Capsule())
                }
            }
            .foregroundStyle(on ? Color.primary : Color.primary.opacity(0.55))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .overlay(alignment: .bottom) {
                if on { Rectangle().fill(Color.primary).frame(height: 1.5).padding(.horizontal, 6).offset(y: 5) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

@MainActor struct SettingsPopover: View {
    @AppStorage("appearance") private var appearance = "auto"
    @Environment(AppModel.self) var model
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings").font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 5) {
                Text("Appearance").font(.system(size: 11)).foregroundStyle(.secondary)
                Seg(options: [("auto", "Auto"), ("light", "Light"), ("dark", "Dark")], sel: $appearance)
            }
            Divider()
            Button("Rescan Macintosh HD") { model.scan.start() }.buttonStyle(SoftButtonStyle())
            Button("Open Full Disk Access settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            }.buttonStyle(SoftButtonStyle())
            Text("Everything you clear goes to the Trash first.\nDiskBuddy runs entirely on this Mac.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        .padding(16).frame(width: 250)
    }
}

// MARK: - Developer aid: DISKBUDDY_SNAPSHOT=<dir> renders every tab of the app's own window to PNG files.
@MainActor enum SelfSnapshot {
    static func runIfRequested(model: AppModel) async {
        guard let dir = ProcessInfo.processInfo.environment["DISKBUDDY_SNAPSHOT"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func shot(_ name: String) {
            guard let v = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView,
                  let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            if let d = rep.representation(using: .png, properties: [:]) { try? d.write(to: URL(fileURLWithPath: "\(dir)/\(name).png")) }
        }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        shot("00-scanning")
        for _ in 0..<120 { if model.scan.phase == .done { break }; try? await Task.sleep(nanoseconds: 1_000_000_000) }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if ProcessInfo.processInfo.environment["DISKBUDDY_ONLY_AI"] != nil {
            model.tab = .cleanup; model.cleanup.openGroup = .ai
            try? await Task.sleep(nanoseconds: 1_500_000_000); shot("cleanup-ai")
            if let first = model.cleanup.groups.first(where: { $0.id == .ai })?.items.first { model.cleanup.toggle(item: first) }
            try? await Task.sleep(nanoseconds: 800_000_000); shot("cleanup-ai-ticked")
            NSApp.terminate(nil); return
        }
        for t in Tab.allCases {
            model.tab = t
            if t == .space { model.space.mode = .map }
            if t == .find { model.find.query = "movies" }
            try? await Task.sleep(nanoseconds: t == .space || t == .applications || t == .find ? 9_000_000_000 : 3_500_000_000)
            shot("\(t.rawValue)")
        }
        if let f = ProcessInfo.processInfo.environment["DISKBUDDY_COMPRESS_FILE"] {
            model.tab = .compress
            model.compress.add([URL(fileURLWithPath: f)])
            try? await Task.sleep(nanoseconds: 1_000_000_000); shot("compress-before")
            model.compress.run()
            for _ in 0..<120 { if !model.compress.running { break }; try? await Task.sleep(nanoseconds: 1_000_000_000) }
            try? await Task.sleep(nanoseconds: 800_000_000); shot("compress-after")
        }
        model.tab = .duplicates; model.dupes.scan()
        for _ in 0..<120 { if model.dupes.scanned { break }; try? await Task.sleep(nanoseconds: 1_000_000_000) }
        for g in model.dupes.groups.prefix(2) { model.dupes.expanded.insert(g.id) }
        try? await Task.sleep(nanoseconds: 1_500_000_000); shot("duplicates-after")
        model.tab = .cleanup; model.cleanup.openGroup = .caches
        try? await Task.sleep(nanoseconds: 1_500_000_000); shot("cleanup-detail")
        model.tab = .space; model.space.mode = .largest
        try? await Task.sleep(nanoseconds: 2_000_000_000); shot("space-largest")
        try? await Task.sleep(nanoseconds: 500_000_000)
        NSApp.terminate(nil)
    }
}
