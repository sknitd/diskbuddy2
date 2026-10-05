import SwiftUI

@MainActor struct ActivityView: View {
    @Environment(AppModel.self) var model

    var body: some View {
        let a = model.activity
        ScrollView {
            VStack(spacing: 10) {
                HStack(spacing: 10) { givenCard(a); cleanupsCard(a); appsCard(a); scansCard(a) }
                chartCard(a)
                HStack(alignment: .top, spacing: 10) { historyCard(a); snapshotsCard(a) }
            }.padding(.horizontal, 22).padding(.vertical, 14)
        }
    }

    func card<C: View>(_ icon: String, _ title: String, badge: String? = nil, badgeColor: Color = .secondary, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(title, systemImage: icon).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if let badge { Text(badge).font(.system(size: 9.5, weight: .medium)).foregroundStyle(badgeColor).padding(.horizontal, 5).padding(.vertical, 1).background(badgeColor.opacity(0.12), in: Capsule()) }
            }.frame(height: 16)
            c()
        }
        .padding(12).frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
    }

    func monthStart() -> Date { Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date()))! }

    func givenCard(_ a: ActivityStore) -> some View {
        let month = a.given.filter { $0.date >= monthStart() }.reduce(Int64(0)) { $0 + $1.bytes }
        let df = DateFormatter(); df.dateFormat = "MMM"
        let cumulative: [Double] = {
            var t = 0.0; return a.given.reversed().map { t += Double($0.bytes); return t }
        }()
        return card("arrow.down.circle", "GIVEN BACK", badge: month > 0 ? "+\(bytesString(month)) in \(df.string(from: Date()))" : nil, badgeColor: Theme.green) {
            let parts = bytesString(a.givenBack).split(separator: " ")
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(String(parts.first ?? "0")).font(.system(size: 26, weight: .semibold)).monospacedDigit()
                Text(String(parts.dropFirst().first ?? "KB")).font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.top, 8)
            Spark(values: cumulative.count > 1 ? cumulative : [0, 0]).stroke(Theme.green, lineWidth: 1.2).frame(height: 24).padding(.vertical, 6)
            Text("Since you started").font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
    func cleanupsCard(_ a: ActivityStore) -> some View {
        let total = max(1, a.cleanups.count + a.uninstalls.count + a.compressions.count)
        return card("paintbrush.pointed", "CLEANUPS", badge: "\(Int(Double(a.cleanups.count) / Double(total) * 100))% of all") {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(a.cleanups.count)").font(.system(size: 26, weight: .semibold)).monospacedDigit()
                Text("cleanups").font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.top, 8)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(Theme.green).frame(width: g.size.width * CGFloat(a.cleanups.count) / CGFloat(total))
                }
            }.frame(height: 5).padding(.vertical, 12)
            Text("\(bytesString(a.cleanups.reduce(0) { $0 + $1.bytes })) moved to the Trash").font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
    func appsCard(_ a: ActivityStore) -> some View {
        let saved = a.compressions.reduce(Int64(0)) { $0 + $1.bytes }
        return card("square.stack.3d.up", "APPS & COMPRESS", badge: bytesString(saved), badgeColor: Theme.pink) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(a.uninstalls.count)").font(.system(size: 26, weight: .semibold)).monospacedDigit()
                Text("apps · \(a.compressions.count) compressed").font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.top, 8)
            Spacer(minLength: 8)
            Text("\(bytesString(saved)) saved by compressing").font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
    func scansCard(_ a: ActivityStore) -> some View {
        card("magnifyingglass", "SCANS", badge: model.cleanup.disk.name) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(a.scans.count)").font(.system(size: 26, weight: .semibold)).monospacedDigit()
                Text("scans").font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.top, 8)
            HStack(spacing: 1.5) { ForEach(0..<min(40, max(a.scans.count, 1)), id: \.self) { _ in Capsule().fill(Color.primary.opacity(0.25)).frame(width: 2, height: 14) } }.padding(.vertical, 8)
            Text(a.scans.first.map { "Last scan \(relativeDate($0.date)) · \($0.detail.components(separatedBy: " in ").last ?? "")" } ?? "No scans yet")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    func chartCard(_ a: ActivityStore) -> some View {
        let cal = Calendar.current
        let weekStart = cal.dateInterval(of: .weekOfYear, for: Date())!.start
        struct Bucket { var cleanup: Int64 = 0, uninstall: Int64 = 0, compress: Int64 = 0; var total: Int64 { cleanup + uninstall + compress } }
        var buckets = [Bucket](repeating: Bucket(), count: 12)
        for e in a.given {
            let w = cal.dateComponents([.weekOfYear], from: cal.dateInterval(of: .weekOfYear, for: e.date)!.start, to: weekStart).weekOfYear ?? 99
            guard w >= 0, w < 12 else { continue }
            let i = 11 - w
            switch e.kind { case .cleanup: buckets[i].cleanup += e.bytes; case .uninstall: buckets[i].uninstall += e.bytes; default: buckets[i].compress += e.bytes }
        }
        let mx = max(buckets.map(\.total).max() ?? 1, 1)
        let df = DateFormatter(); df.dateFormat = "d MMM"
        return card("chart.bar", "GIVEN BACK OVER TIME · LAST 12 WEEKS") {
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(0..<12, id: \.self) { i in
                    let b = buckets[i]
                    VStack(spacing: 4) {
                        Spacer(minLength: 0)
                        VStack(spacing: 0) {
                            Rectangle().fill(Theme.blue).frame(height: 110 * CGFloat(Double(b.compress) / Double(mx)))
                            Rectangle().fill(Theme.pink).frame(height: 110 * CGFloat(Double(b.uninstall) / Double(mx)))
                            Rectangle().fill(Theme.green).frame(height: 110 * CGFloat(Double(b.cleanup) / Double(mx)))
                        }.clipShape(RoundedRectangle(cornerRadius: 2))
                        Rectangle().fill(Color.primary.opacity(0.15)).frame(height: b.total == 0 ? 2 : 0)
                        Text(i == 11 ? "This week" : df.string(from: cal.date(byAdding: .weekOfYear, value: i - 11, to: weekStart)!))
                            .font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1).fixedSize()
                    }.frame(maxWidth: .infinity)
                }
            }.frame(height: 150).padding(.top, 10)
            HStack(spacing: 12) {
                legend("Cleanups", Theme.green); legend("Uninstalls", Theme.pink); legend("Compressions", Theme.blue)
            }.padding(.top, 6)
        }
    }
    func legend(_ t: String, _ c: Color) -> some View {
        HStack(spacing: 4) { Rectangle().fill(c).frame(width: 7, height: 7); Text(t).font(.system(size: 9.5)).foregroundStyle(.secondary) }
    }

    func historyCard(_ a: ActivityStore) -> some View {
        let groups = Dictionary(grouping: a.events.prefix(80)) { Calendar.current.startOfDay(for: $0.date) }.sorted { $0.key > $1.key }
        let df = DateFormatter(); df.dateFormat = "h:mm a"
        return card("clock", "HISTORY", badge: "\(a.events.count) event\(a.events.count == 1 ? "" : "s")") {
            ForEach(groups, id: \.key) { day, evs in
                HStack {
                    Text(Calendar.current.isDateInToday(day) ? "Today" : Calendar.current.isDateInYesterday(day) ? "Yesterday" : day.formatted(date: .abbreviated, time: .omitted))
                    Spacer()
                    let b = evs.filter { $0.kind != .scan }.reduce(Int64(0)) { $0 + $1.bytes }
                    if b > 0 { Text("\(bytesString(b)) given back") }
                }.font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 10).padding(.bottom, 4)
                ForEach(evs) { e in
                    HStack(spacing: 8) {
                        Image(systemName: icon(e.kind)).font(.system(size: 11)).foregroundStyle(color(e.kind)).frame(width: 18)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(e.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                            Text(e.detail).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 0) {
                            if e.bytes > 0 { Text(bytesString(e.bytes)).font(.system(size: 11, weight: .medium)).foregroundStyle(e.kind == .scan ? Color.secondary : color(e.kind)) }
                            Text(df.string(from: e.date)).font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                    }.padding(.vertical, 3)
                }
            }
            if a.events.isEmpty { Text("Nothing yet. Clean something up and it shows here.").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 14) }
        }
    }
    func icon(_ k: ActivityEvent.Kind) -> String {
        switch k { case .cleanup: "paintbrush.pointed"; case .scan: "magnifyingglass"; case .uninstall: "trash"; case .compress: "rectangle.compress.vertical"; case .stop: "stop.circle" }
    }
    func color(_ k: ActivityEvent.Kind) -> Color {
        switch k { case .cleanup: Theme.green; case .scan: .secondary; case .uninstall: Theme.pink; case .compress: Theme.blue; case .stop: Theme.orange }
    }

    func snapshotsCard(_ a: ActivityStore) -> some View {
        let latest = a.snapshots.first
        let current = a.lastScan?.folders ?? [:]
        let changes: [(String, Int64)] = latest.map { s in
            current.map { ($0.key, $0.value - (s.folders[$0.key] ?? 0)) }.filter { abs($0.1) > 1_000_000 }.sorted { abs($0.1) > abs($1.1) }
        } ?? []
        return card("camera.viewfinder", "SNAPSHOTS") {
            Text("Saved").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 10)
            ForEach(a.snapshots.prefix(4)) { s in
                HStack {
                    Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(Theme.purple)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Home folder").font(.system(size: 11, weight: .medium))
                        Text("~ · \(bytesString(s.folders.values.reduce(0, +)))").font(.system(size: 9.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(s.label).font(.system(size: 9.5)).foregroundStyle(.tertiary)
                }.padding(.vertical, 3)
            }
            if latest == nil || changes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "camera.viewfinder").font(.system(size: 18)).foregroundStyle(Theme.purple)
                    Text(latest == nil ? "Nothing to compare yet" : "Nothing has changed since your snapshot").font(.system(size: 11.5, weight: .semibold))
                    Text("Save a snapshot of this scan. After your next scan this shows which folders grew and which shrank.")
                        .font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Save snapshot") { a.saveSnapshot(); model.showToast("Snapshot saved") }.buttonStyle(SoftButtonStyle()).disabled(a.lastScan == nil)
                }.frame(maxWidth: .infinity).padding(.top, 14)
            } else {
                Text("Since \(latest!.label)").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 10)
                ForEach(changes.prefix(6), id: \.0) { name, delta in
                    HStack {
                        Text(name).font(.system(size: 11)); Spacer()
                        Text("\(delta > 0 ? "+" : "−")\(bytesString(abs(delta)))").font(.system(size: 11, weight: .medium)).foregroundStyle(delta > 0 ? Theme.red : Theme.green)
                    }.padding(.vertical, 2)
                }
                Button("Save new snapshot") { a.saveSnapshot(); model.showToast("Snapshot saved") }.buttonStyle(SoftButtonStyle()).padding(.top, 10)
            }
        }
    }
}
