import SwiftUI

@MainActor struct CleanupView: View {
    @Environment(AppModel.self) var model

    var body: some View {
        let c = model.cleanup
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                Group {
                    if let g = c.openGroup, let group = c.groups.first(where: { $0.id == g }) {
                        GroupDetail(group: group)
                    } else {
                        groupList
                    }
                }
                .frame(maxWidth: .infinity)
                AfterCleanupPanel().frame(width: 280).padding(.trailing, 14).padding(.top, 14)
            }
            footer
        }
    }

    var groupList: some View {
        let c = model.cleanup
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !c.staged.isEmpty {
                    stagedSection
                } else {
                    Text("Staged from other rooms").font(.system(size: 11, weight: .semibold)).padding(.top, 16)
                    Text("Add files and folders from Find, Space or Duplicates and they land here.")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary).padding(.top, 2).padding(.bottom, 6)
                }
                label("Safe to clear")
                ForEach(c.groups.filter { $0.id.isSafe }) { g in row(g) }
                if c.groups.contains(where: { $0.id.isSafe && $0.inTrash }) == false, c.groups.filter({ $0.id.isSafe }).isEmpty {
                    Text("Nothing here right now.").font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 6)
                }
                label("Worth a look")
                Text("Not ticked for you. Tick a group, or open it and tick each file you are sure about.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).padding(.bottom, 4)
                ForEach(c.groups.filter { !$0.id.isSafe }) { g in row(g) }
            }
            .padding(.horizontal, 28).padding(.bottom, 20)
        }
    }

    var stagedSection: some View {
        let c = model.cleanup
        return VStack(alignment: .leading, spacing: 0) {
            Text("Staged from other rooms").font(.system(size: 11, weight: .semibold)).padding(.top, 16)
            Text("\(c.staged.count) item\(c.staged.count == 1 ? "" : "s") waiting here").font(.system(size: 10.5)).foregroundStyle(.secondary).padding(.bottom, 6)
            ForEach(c.staged) { it in
                HStack(spacing: 10) {
                    TickBox(state: c.selected.contains(it.id)) { c.toggle(item: it) }
                    FileIcon(url: it.url, size: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(it.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                        Text(it.subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(bytesString(it.size)).font(.system(size: 11.5)).monospacedDigit()
                    Button { c.staged.removeAll { $0.id == it.id }; c.selected.remove(it.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    }.buttonStyle(.plain)
                }
                .padding(.vertical, 5)
            }
        }
    }

    func label(_ t: String) -> some View {
        Text(t).font(.system(size: 11, weight: .semibold)).padding(.top, 16).padding(.bottom, 4)
    }

    func row(_ g: CleanGroup) -> some View {
        let c = model.cleanup
        return Button { c.openGroup = g.id } label: {
            HStack(spacing: 10) {
                if g.id.tickable {
                    TickBox(state: g.inTrash ? false : c.state(of: g), color: g.id.color) { c.toggle(group: g) }
                        .disabled(g.inTrash)
                } else {
                    Circle().fill(g.id.color).frame(width: 6, height: 6).frame(width: 14)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(g.id.title).font(.system(size: 11.5, weight: .medium))
                    Text(g.id.blurb).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                if g.inTrash {
                    Text("In Trash").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.green)
                } else {
                    Text(bytesString(g.size)).font(.system(size: 11.5)).monospacedDigit()
                }
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6).padding(.horizontal, 2)
            .opacity(g.inTrash ? 0.6 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var footer: some View {
        let c = model.cleanup
        return VStack(spacing: 0) {
            Hairline().opacity(0.6)
            HStack {
                Text(c.lastDeleted > 0 && c.selectedBytes == 0 ? "Deleted \(bytesString(c.lastDeleted)). That space is free now." : "Tick what to clear. Open a group to see every file in it.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                Spacer()
                Button("Unstage all") { c.selected = [] }.buttonStyle(SoftButtonStyle()).disabled(c.selected.isEmpty)
                Button(c.selectedBytes == 0 ? "Nothing ticked" : "Move \(bytesString(c.selectedBytes)) to Trash") { c.trashSelected() }
                    .buttonStyle(DarkButtonStyle()).disabled(c.selectedBytes == 0 || c.working)
            }
            .padding(.horizontal, 28).padding(.vertical, 12)
        }
    }
}

@MainActor struct AfterCleanupPanel: View {
    @Environment(AppModel.self) var model
    var body: some View {
        let c = model.cleanup
        let after = c.disk.free + c.selectedBytes
        let usedFrac = c.disk.total > 0 ? Double(c.disk.used) / Double(c.disk.total) : 0
        let afterFrac = c.disk.total > 0 ? Double(max(0, c.disk.used - c.selectedBytes)) / Double(c.disk.total) : 0
        VStack(alignment: .leading, spacing: 0) {
            Text("After cleanup").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            Text(bytesString(after)).font(.system(size: 26, weight: .semibold)).monospacedDigit().padding(.top, 6)
            Text("free on \(c.disk.name) once the Trash is emptied")
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(Color.primary.opacity(0.25)).frame(width: geo.size.width * usedFrac)
                    Capsule().fill(Color.primary.opacity(0.55)).frame(width: geo.size.width * afterFrac)
                }
            }
            .frame(height: 6).padding(.vertical, 14)
            HStack { Text("Free now"); Spacer(); Text(bytesString(c.disk.free)).monospacedDigit() }
                .font(.system(size: 10.5, weight: .medium)).padding(.bottom, 5)
            HStack { Text("Will move to Trash"); Spacer(); Text(bytesString(c.selectedBytes)).monospacedDigit() }
                .font(.system(size: 10.5, weight: .medium))
            Text("Everything goes to the Trash, never straight to deletion unless you ask. The space comes back when you empty the Trash; until then, drag anything back out.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary).padding(.top, 12)
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
    }
}

@MainActor struct GroupDetail: View {
    @Environment(AppModel.self) var model
    let group: CleanGroup
    @State private var filter = ""
    @State private var sortLargest = true

    var items: [CleanItem] {
        var l = group.items
        if !filter.isEmpty { l = l.filter { $0.name.localizedCaseInsensitiveContains(filter) } }
        return sortLargest ? l.sorted { $0.size > $1.size } : l.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        let c = model.cleanup
        let ticked = group.items.filter { c.selected.contains($0.id) }
        VStack(alignment: .leading, spacing: 0) {
            Button { c.openGroup = nil } label: {
                HStack(spacing: 4) { Image(systemName: "chevron.left").font(.system(size: 9, weight: .semibold)); Text("Cleanup") }
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }.buttonStyle(.plain).padding(.top, 14)
            HStack(alignment: .firstTextBaseline) {
                Circle().fill(group.id.color).frame(width: 7, height: 7)
                Text(group.id.title).font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(ticked.count) ticked · \(bytesString(ticked.reduce(0) { $0 + $1.size }))")
                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(group.id.color)
                Button(ticked.count == group.items.count ? "Untick all" : "Tick all") { c.toggle(group: group) }
                    .buttonStyle(SoftButtonStyle())
            }
            .padding(.top, 8)
            Text("\(group.items.count) items · \(bytesString(group.size)) · \(group.id.blurb)")
                .font(.system(size: 10.5)).foregroundStyle(.secondary).padding(.leading, 15)
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(.tertiary)
                    TextField("Filter by name", text: $filter).textFieldStyle(.plain).font(.system(size: 11))
                }
                .padding(.horizontal, 8).padding(.vertical, 5).frame(width: 220)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                Spacer()
                Seg(options: [(true, "Largest"), (false, "Name")], sel: $sortLargest)
            }
            .padding(.vertical, 10)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { it in
                        HStack(spacing: 10) {
                            TickBox(state: c.selected.contains(it.id), color: group.id.color) { c.toggle(item: it) }
                            FileIcon(url: it.url, size: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(it.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                                Text(it.subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(relativeDate(it.modified)).font(.system(size: 10)).foregroundStyle(.tertiary)
                            Text(bytesString(it.size)).font(.system(size: 11.5)).monospacedDigit().frame(width: 70, alignment: .trailing)
                        }
                        .padding(.vertical, 5)
                        .contextMenu {
                            Button("Reveal in Finder") { FS.reveal(it.url) }
                        }
                    }
                }
            }
            if group.items.isEmpty {
                Text(group.inTrash ? "Everything here is in the Trash." : "Nothing found.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 20)
            }
        }
        .padding(.horizontal, 28)
    }
}
