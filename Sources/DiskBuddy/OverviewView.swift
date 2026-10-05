import SwiftUI

struct DonutSegment: Identifiable {
    let id = UUID()
    let value: Double
    let color: Color
}

@MainActor struct Donut: View {
    var segments: [DonutSegment]
    var lineWidth: CGFloat = 26
    var body: some View {
        let total = max(segments.reduce(0) { $0 + $1.value }, 1)
        ZStack {
            ForEach(Array(segments.enumerated()), id: \.element.id) { i, s in
                let start = segments.prefix(i).reduce(0) { $0 + $1.value } / total
                let end = start + s.value / total
                Circle()
                    .trim(from: start, to: max(start, end - 0.0035))
                    .stroke(s.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
        }
        .padding(lineWidth / 2)
    }
}

@MainActor struct OverviewView: View {
    @Environment(AppModel.self) var model

    var body: some View {
        let scan = model.scan
        Group {
            if scan.phase == .done, let r = scan.result {
                ResultsView(r: r).transition(.opacity)
            } else {
                ScanningView().transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.3), value: scan.phase == .done)
    }
}

@MainActor struct ScanningView: View {
    @Environment(AppModel.self) var model
    var body: some View {
        let s = model.scan
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                Circle().stroke(Color.primary.opacity(0.06), lineWidth: 18)
                Circle().trim(from: 0, to: s.progress)
                    .stroke(Color.primary.opacity(0.22), style: StrokeStyle(lineWidth: 18, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 8) {
                    Text("\(Int(s.progress * 100))%")
                        .font(.system(size: 32, weight: .semibold)).monospacedDigit()
                    Text(s.sorting ? "Sorting what was found" : s.currentPath)
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).frame(width: 150)
                }
            }
            .frame(width: 210, height: 210)
            Text("Looking through \(model.cleanup.disk.name)")
                .font(.system(size: 10.5)).foregroundStyle(.secondary).padding(.top, 24)
            Button("Scanning…") {}.buttonStyle(DarkButtonStyle()).disabled(true).padding(.top, 14)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

@MainActor struct ResultsView: View {
    @Environment(AppModel.self) var model
    let r: ScanResult

    var body: some View {
        let c = model.cleanup
        HStack(alignment: .center, spacing: 0) {
            VStack(spacing: 0) {
                Spacer()
                ZStack {
                    Donut(segments: segments)
                    VStack(spacing: 4) {
                        Text(bytesString(c.selectedBytes))
                            .font(.system(size: 31, weight: .semibold)).monospacedDigit()
                        Text("ready to clear").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 290, height: 290)
                Text(summaryText)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(width: 300).padding(.top, 22)
                Button("Move \(bytesString(c.selectedBytes)) to Trash") { c.trashSelected() }
                    .buttonStyle(DarkButtonStyle()).disabled(c.selectedBytes == 0 || c.working).padding(.top, 12)
                Button("Scan again") { model.scan.start() }
                    .buttonStyle(.plain).font(.system(size: 10.5)).foregroundStyle(.tertiary).padding(.top, 10)
                Spacer()
            }
            .frame(maxWidth: .infinity)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) { rows }
                    .padding(.vertical, 40).padding(.horizontal, 6)
            }
            .frame(width: 380)
            .padding(.trailing, 28)
        }
    }

    var summaryText: String {
        let c = model.cleanup
        let look = OverviewRow.all.reduce(Int64(0)) { $0 + c.bytes(in: $1.groups) }
        let safe = OverviewRow.all.filter { $0.section == .safe }.reduce(Int64(0)) { $0 + c.bytes(in: $1.groups) }
        if look == 0 { return "Nothing to clear right now. Your Mac is tidy." }
        return "Found \(bytesString(look)) you could clear. \(bytesString(safe)) of it is safe to clear right now."
    }

    var segments: [DonutSegment] {
        let c = model.cleanup
        var segs: [DonutSegment] = []
        func g(_ v: Int64, _ col: Color) { if v > 0 { segs.append(.init(value: Double(v), color: col)) } }
        g(r.system, Color.primary.opacity(0.34))
        g(r.other, Color.primary.opacity(0.27))
        g(r.media, Color.primary.opacity(0.17))
        g(r.docs, Color.primary.opacity(0.22))
        g(r.apps, Color.primary.opacity(0.13))
        for row in OverviewRow.all { g(c.bytes(in: row.groups), row.color) }
        let trashed = c.groups.reduce(Int64(0)) { $0 + $1.trashedBytes }
        _ = trashed
        g(max(0, c.disk.free), Color.primary.opacity(0.07))
        return segs
    }

    @ViewBuilder var rows: some View {
        let c = model.cleanup
        section("Safe to clear", rows: OverviewRow.all.filter { $0.section == .safe })
        section("Worth a look", rows: OverviewRow.all.filter { $0.section == .look })
        keptHeader
        keptRow("Apps", "\(countString(r.appCount)) apps and app parts", r.apps, .applications, Color.primary.opacity(0.2))
        keptRow("Documents", "\(countString(r.docCount)) documents", r.docs, .space, Color.primary.opacity(0.35))
        keptRow("Photos and media", "\(countString(r.mediaCount)) photos, videos and songs", r.media, .space, Color.primary.opacity(0.12))
        keptRow("Other files", "\(countString(r.otherCount)) files", r.other, .space, Color.primary.opacity(0.5))
        keptRow("System", "macOS, and what a scan cannot see", r.system, .space, Color.primary.opacity(0.6))
        let _ = c
    }

    var keptHeader: some View {
        let t = r.apps + r.docs + r.media + r.other + r.system
        return HStack {
            Text("Kept on your Mac"); Spacer(); Text(bytesString(t))
        }
        .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 14).padding(.bottom, 2)
    }

    @ViewBuilder func section(_ title: String, rows: [OverviewRow]) -> some View {
        let c = model.cleanup
        let visible = rows.filter { row in c.count(in: row.groups) > 0 || c.groups.contains { g in row.groups.contains(g.id) && g.inTrash } }
        if !visible.isEmpty {
            HStack {
                Text(title); Spacer()
                Text(bytesString(visible.reduce(0) { $0 + c.bytes(in: $1.groups) }))
            }
            .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.top, title == "Safe to clear" ? 0 : 14).padding(.bottom, 2)
            ForEach(visible) { row in clearRow(row) }
        }
    }

    func clearRow(_ row: OverviewRow) -> some View {
        let c = model.cleanup
        let size = c.bytes(in: row.groups)
        let n = c.count(in: row.groups)
        return Button {
            c.openGroup = row.groups.count == 1 ? row.groups[0] : nil
            model.go(.cleanup)
        } label: {
            HStack(spacing: 10) {
                if row.tickable {
                    TickBox(state: c.state(of: row.groups), color: row.color) {
                        c.toggle(ids: c.groups.filter { row.groups.contains($0.id) }.flatMap { $0.items.map(\.id) })
                    }
                } else {
                    Circle().fill(row.color).frame(width: 6, height: 6).frame(width: 14)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title).font(.system(size: 11.5, weight: .medium))
                    Text("\(countString(n)) items · \(row.blurb)").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(bytesString(size)).font(.system(size: 11.5)).monospacedDigit()
                    Text(percentOfDisk(size, c.disk.total)).font(.system(size: 9.5)).foregroundStyle(.tertiary)
                }
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 5).padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func keptRow(_ title: String, _ sub: String, _ size: Int64, _ tab: Tab, _ dot: Color) -> some View {
        Button { model.go(tab) } label: {
            HStack(spacing: 10) {
                Circle().fill(dot).frame(width: 6, height: 6).frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 11.5, weight: .medium))
                    Text(sub).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(bytesString(size)).font(.system(size: 11.5)).monospacedDigit()
                    Text(percentOfDisk(size, r.disk.total)).font(.system(size: 9.5)).foregroundStyle(.tertiary)
                }
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 5).padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
