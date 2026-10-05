import SwiftUI

@MainActor struct MonitorView: View {
    @Environment(AppModel.self) var model
    var body: some View {
        let m = model.monitor
        ScrollView {
            VStack(spacing: 10) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    healthCard(m); cpuCard(m); gpuCard(m); memCard(m)
                    batteryCard(m); diskCard(m); netCard(m); fanCard(m)
                }
                HStack(alignment: .top, spacing: 10) {
                    ProcessTable().frame(maxWidth: .infinity)
                    PortsTable().frame(width: 410)
                }
                .frame(height: 340)
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
        }
        .onAppear { m.visible = true; Task { await m.refreshProcs(); await m.refreshPorts() } }
        .onDisappear { m.visible = false }
    }

    func card<C: View>(_ icon: String, _ title: String, badge: String? = nil, badgeColor: Color = .secondary, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(title, systemImage: icon).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                Spacer()
                if let badge { Text(badge).font(.system(size: 9.5, weight: .medium)).foregroundStyle(badgeColor) }
            }.frame(height: 14)
            content()
        }
        .padding(12).frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
    }

    func big(_ v: String, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(v).font(.system(size: 26, weight: .semibold)).monospacedDigit()
            Text(unit).font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(.top, 8)
    }
    func foot(_ t: String) -> some View { Text(t).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
    func spark(_ v: [Double], _ c: Color, max: Double? = nil) -> some View {
        ZStack {
            SparkFill(values: v, maxV: max).fill(LinearGradient(colors: [c.opacity(0.18), c.opacity(0)], startPoint: .top, endPoint: .bottom))
            Spark(values: v, maxV: max).stroke(c, lineWidth: 1)
        }.frame(height: 26).padding(.vertical, 6)
    }

    func healthCard(_ m: MonitorModel) -> some View {
        card("heart.text.square", "HEALTH", badge: m.health >= 70 ? "Good" : m.health >= 50 ? "Fair" : "Low",
             badgeColor: m.health >= 70 ? Theme.green : m.health >= 50 ? Theme.orange : Theme.red) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(m.health)").font(.system(size: 26, weight: .semibold)).monospacedDigit()
                Text("of 100").font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.top, 8)
            HStack(spacing: 5) {
                ForEach([m.chip, "\(Int(round(Double(m.ramTotal) / 1_073_741_824))) GB", m.osVersion], id: \.self) {
                    Text($0).font(.system(size: 9, weight: .medium)).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                }
            }.padding(.vertical, 6)
            foot(m.uptimeText)
        }
    }
    func cpuCard(_ m: MonitorModel) -> some View {
        card("cpu", "CPU") {
            big("\(Int(m.cpu.rounded()))", "%")
            spark(m.cpuHist, Theme.purple, max: 100)
            foot("\(m.cpu > 60 ? "busy" : m.cpu > 25 ? "moderate" : "light") · load \(String(format: "%.1f", m.load)) / \(m.cores) cores")
        }
    }
    func gpuCard(_ m: MonitorModel) -> some View {
        card("display", "GPU") {
            big(m.gpu.map(String.init) ?? "—", "%")
            spark(m.gpuHist, Theme.blue, max: 100)
            foot("\((m.gpu ?? 0) > 60 ? "busy" : "light")\(m.gpuCores.map { " · \($0) GPU cores" } ?? "")")
        }
    }
    func memCard(_ m: MonitorModel) -> some View {
        card("memorychip", "MEMORY", badge: "Pressure \(m.memPressure)%", badgeColor: m.memPressure > 70 ? Theme.red : Theme.green) {
            big(String(format: "%.1f", Double(m.memUsed) / 1e9), "GB")
            spark(m.memHist, Theme.green, max: 100)
            foot("\(String(format: "%.1f", Double(m.memUsed) / 1e9)) of \(Int(round(Double(m.ramTotal) / 1_073_741_824))) GB · \(String(format: "%.1f", Double(m.swap) / 1e9)) GB swap")
        }
    }
    func batteryCard(_ m: MonitorModel) -> some View {
        card("battery.75percent", "BATTERY", badge: m.battery?.health.map { "Health \($0)%" }) {
            if let b = m.battery {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        big("\(b.percent)", "%")
                        Text(b.minutes.map { "\($0 / 60) h \($0 % 60) min \(b.charging ? "to full" : "left")" } ?? (b.charging ? "Charging" : b.onAC ? "On power" : "Calculating…"))
                            .font(.system(size: 10, weight: .medium))
                    }
                    Spacer()
                    ZStack {
                        Circle().stroke(Color.primary.opacity(0.08), lineWidth: 4)
                        Circle().trim(from: 0, to: Double(b.percent) / 100).stroke(Theme.green, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90))
                    }.frame(width: 36, height: 36)
                }
                Spacer(minLength: 4)
                foot("\(b.cycles.map { "\($0) cycles" } ?? "") \(b.tempC.map { "· \(Int($0))°C" } ?? "") · \(b.onAC ? "on power" : "on battery")")
            } else {
                big("—", "")
                Spacer(minLength: 4)
                foot("No battery in this Mac")
            }
        }
    }
    func diskCard(_ m: MonitorModel) -> some View {
        let usedFrac = m.disk.total > 0 ? Double(m.disk.used) / Double(m.disk.total) : 0
        return card("internaldrive", "DISK", badge: bytesString(m.disk.total)) {
            big(String(format: "%.1f", Double(m.disk.free) / 1e9), "GB free")
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(Color.primary.opacity(0.5)).frame(width: g.size.width * usedFrac)
                }
            }.frame(height: 5).padding(.vertical, 10)
            foot("\(bytesString(m.disk.used)) used · \(Int((usedFrac * 100).rounded()))%")
        }
    }
    func netCard(_ m: MonitorModel) -> some View {
        card("wifi", "NETWORK", badge: m.netName) {
            big(rate(m.netDown).0, rate(m.netDown).1 + " down")
            spark(m.netHist, Theme.blue.opacity(0.9))
            foot("↑ \(rate(m.netUp).0) \(rate(m.netUp).1) up · ↓ \(bytesString(Int64(m.netTotal))) this session")
        }
    }
    func fanCard(_ m: MonitorModel) -> some View {
        card("fan", "FAN") {
            Text("Auto").font(.system(size: 26, weight: .semibold)).padding(.top, 8)
            Spacer(minLength: 4)
            foot("Managed by macOS")
        }
    }
    func rate(_ bps: Double) -> (String, String) {
        if bps >= 1_000_000 { return (String(format: "%.1f", bps / 1e6), "MB/s") }
        return (String(Int((bps / 1000).rounded())), "KB/s")
    }
}

@MainActor struct ProcessTable: View {
    @Environment(AppModel.self) var model
    var body: some View {
        let m = model.monitor
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Processes").font(.system(size: 11.5, weight: .semibold))
                Text("\(m.procCount)").font(.system(size: 10.5)).foregroundStyle(.secondary)
                Spacer()
                Text("By CPU · every 2 s").font(.system(size: 10)).foregroundStyle(.tertiary)
            }.padding(.bottom, 8)
            HStack {
                Text("NAME").frame(maxWidth: .infinity, alignment: .leading)
                Text("PID").frame(width: 60, alignment: .trailing)
                Text("↓ CPU").frame(width: 80, alignment: .trailing)
                Text("MEM").frame(width: 70, alignment: .trailing)
                Spacer().frame(width: 20)
            }.font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary).padding(.bottom, 4)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(m.procs) { p in
                        HStack {
                            HStack(spacing: 8) {
                                procIcon(p)
                                Text(p.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                                if let a = p.app { Text(a).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(p.pid)").foregroundStyle(.tertiary).frame(width: 60, alignment: .trailing)
                            Text("\(Int(p.cpu.rounded()))%").frame(width: 80, alignment: .trailing)
                            Text(bytesString(p.mem)).frame(width: 70, alignment: .trailing)
                            Menu {
                                Button("Quit process") { m.stop(pid: p.pid, name: p.name) }
                                if let ap = p.appPath { Button("Reveal in Finder") { FS.reveal(URL(fileURLWithPath: ap)) } }
                            } label: { Image(systemName: "ellipsis").font(.system(size: 10)).foregroundStyle(.tertiary) }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 20)
                        }
                        .font(.system(size: 11)).monospacedDigit().padding(.vertical, 5)
                    }
                }
            }
        }
        .padding(14).background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder func procIcon(_ p: ProcRow) -> some View {
        if let ap = p.appPath { FileIcon(url: URL(fileURLWithPath: ap), size: 15) }
        else { RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.1)).frame(width: 15, height: 15) }
    }
}

@MainActor struct PortsTable: View {
    @Environment(AppModel.self) var model
    var body: some View {
        let m = model.monitor
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Listening ports").font(.system(size: 11.5, weight: .semibold))
                Text("\(m.ports.count)").font(.system(size: 10.5)).foregroundStyle(.secondary)
                Spacer()
                Text("TCP · every 10 s").font(.system(size: 10)).foregroundStyle(.tertiary)
            }.padding(.bottom, 8)
            HStack {
                Text("PORT").frame(width: 70, alignment: .leading)
                Text("PROCESS").frame(maxWidth: .infinity, alignment: .leading)
                Text("ADDRESS").frame(width: 60, alignment: .leading)
                Spacer().frame(width: 52)
            }.font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary).padding(.bottom, 4)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(m.ports) { p in
                        HStack {
                            Text(":\(p.port)").frame(width: 70, alignment: .leading).monospacedDigit()
                            Text(p.process).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            Text(p.address).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                            Button("Stop") { m.stop(pid: p.pid, name: p.process) }.buttonStyle(SoftButtonStyle()).fixedSize().frame(width: 52, alignment: .trailing)
                        }
                        .font(.system(size: 11)).padding(.vertical, 4)
                    }
                    if m.ports.isEmpty { Text("Nothing is listening.").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 10) }
                }
            }
        }
        .padding(14).background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
    }
}
