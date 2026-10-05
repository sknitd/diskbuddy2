import SwiftUI
import Observation
import IOKit
import IOKit.ps
import Darwin
import CoreWLAN

struct ProcRow: Identifiable, Hashable {
    let pid: Int32
    let name: String
    let app: String?
    let appPath: String?
    let cpu: Double
    let mem: Int64
    var id: Int32 { pid }
}

struct PortRow: Identifiable, Hashable {
    let port: Int
    let process: String
    let pid: Int32
    let address: String
    var id: String { "\(port)-\(pid)" }
}

struct CPUSample: Codable { var t: Double; var cpu: Double }

enum SysStats {
    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
    static func sysctlInt(_ name: String) -> Int? {
        var v: Int32 = 0; var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
        return Int(v)
    }

    static func cpuTicks() -> (busy: UInt64, total: UInt64) {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return (0, 0) }
        let u = UInt64(info.cpu_ticks.0), s = UInt64(info.cpu_ticks.1), i = UInt64(info.cpu_ticks.2), n = UInt64(info.cpu_ticks.3)
        return (u + s + n, u + s + i + n)
    }

    static func memoryUsed() -> Int64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return 0 }
        let page = Int64(getpagesize())
        let app = Int64(stats.internal_page_count) - Int64(stats.purgeable_count)
        return (max(0, app) + Int64(stats.wire_count) + Int64(stats.compressor_page_count)) * page
    }

    static func swapUsed() -> Int64 {
        var s = xsw_usage(); var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &s, &size, nil, 0) == 0 else { return 0 }
        return Int64(s.xsu_used)
    }

    static func gpu() -> (util: Int, cores: Int?)? {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        var util: Int?; var cores: Int?
        var svc = IOIteratorNext(it)
        while svc != 0 {
            if let p = IORegistryEntryCreateCFProperty(svc, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
               let v = p["Device Utilization %"] as? Int { util = max(util ?? 0, v) }
            if let c = IORegistryEntryCreateCFProperty(svc, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int { cores = c }
            IOObjectRelease(svc)
            svc = IOIteratorNext(it)
        }
        guard let util else { return nil }
        return (util, cores)
    }

    struct Battery { var percent: Int; var charging: Bool; var onAC: Bool; var minutes: Int?; var health: Int?; var cycles: Int?; var tempC: Double? }

    static func battery() -> Battery? {
        guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snap)?.takeRetainedValue() as? [CFTypeRef], !list.isEmpty else { return nil }
        var b: Battery?
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(snap, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            let onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            var mins: Int? = charging ? d[kIOPSTimeToFullChargeKey] as? Int : d[kIOPSTimeToEmptyKey] as? Int
            if let m = mins, m < 0 { mins = nil }
            b = Battery(percent: cur, charging: charging, onAC: onAC, minutes: mins, health: nil, cycles: nil, tempC: nil)
        }
        guard var batt = b else { return nil }
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if svc != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS, let d = props?.takeRetainedValue() as? [String: Any] {
                batt.cycles = d["CycleCount"] as? Int
                if let t = d["Temperature"] as? Int { batt.tempC = Double(t) / 100 }
                let design = d["DesignCapacity"] as? Int ?? 0
                let raw = d["AppleRawMaxCapacity"] as? Int ?? d["NominalChargeCapacity"] as? Int ?? 0
                if design > 0, raw > 0 { batt.health = min(100, Int((Double(raw) / Double(design) * 100).rounded())) }
            }
            IOObjectRelease(svc)
        }
        return batt
    }

    static func networkBytes() -> (down: UInt64, up: UInt64) {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return (0, 0) }
        defer { freeifaddrs(ifap) }
        var d: UInt64 = 0, u: UInt64 = 0
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let name = String(cString: cur.pointee.ifa_name)
            if cur.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), name.hasPrefix("en"), let data = cur.pointee.ifa_data {
                let ifd = data.assumingMemoryBound(to: if_data.self).pointee
                d += UInt64(ifd.ifi_ibytes); u += UInt64(ifd.ifi_obytes)
            }
            p = cur.pointee.ifa_next
        }
        return (d, u)
    }
}

@Observable @MainActor
final class MonitorModel {
    weak var app: AppModel?
    var visible = false

    // Static
    let chip: String = (SysStats.sysctlString("machdep.cpu.brand_string") ?? "Mac").replacingOccurrences(of: "Apple ", with: "")
    let cores = ProcessInfo.processInfo.activeProcessorCount
    let ramTotal = Int64(ProcessInfo.processInfo.physicalMemory)
    let osVersion: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion)"
    }()
    var uptimeText = ""

    // Live
    var cpu: Double = 0
    var cpuHist: [Double] = []
    var load: Double = 0
    var gpu: Int?
    var gpuCores: Int?
    var gpuHist: [Double] = []
    var memUsed: Int64 = 0
    var memPressure: Int = 0
    var swap: Int64 = 0
    var memHist: [Double] = []
    var battery: SysStats.Battery?
    var disk = DiskInfo.read()
    var netDown: Double = 0
    var netUp: Double = 0
    var netTotal: UInt64 = 0
    var netHist: [Double] = []
    var netName = "Network"
    var procs: [ProcRow] = []
    var procCount = 0
    var ports: [PortRow] = []
    var health: Int = 100

    private var lastTicks = SysStats.cpuTicks()
    private var lastNet = SysStats.networkBytes()
    private var netBase: (UInt64, UInt64)?
    private var started = false
    private var lastProcs = Date.distantPast
    private var lastPorts = Date.distantPast
    private var lastHistoryAt = Date.distantPast
    var history: [String: [CPUSample]] = [:]
    private var historyDirty = false

    func start() {
        guard !started else { return }
        started = true
        loadHistory()
        netBase = SysStats.networkBytes()
        netName = CWWiFiClient.shared().interface()?.powerOn() == true ? "Wi-Fi" : "Network"
        Task { [weak self] in
            while true {
                await self?.tick()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func push(_ arr: inout [Double], _ v: Double) { arr.append(v); if arr.count > 45 { arr.removeFirst() } }

    private func tick() async {
        let t = SysStats.cpuTicks()
        let dBusy = Double(t.busy &- lastTicks.busy), dTotal = Double(t.total &- lastTicks.total)
        lastTicks = t
        cpu = dTotal > 0 ? min(100, dBusy / dTotal * 100) : cpu
        push(&cpuHist, cpu)
        var la = [Double](repeating: 0, count: 1); getloadavg(&la, 1); load = la[0]

        if let g = SysStats.gpu() { gpu = g.util; gpuCores = g.cores; push(&gpuHist, Double(g.util)) }
        memUsed = SysStats.memoryUsed(); swap = SysStats.swapUsed()
        memPressure = max(0, min(100, 100 - (SysStats.sysctlInt("kern.memorystatus_level") ?? 100)))
        push(&memHist, Double(memUsed) / Double(ramTotal) * 100)
        battery = SysStats.battery()
        disk = DiskInfo.read()

        let n = SysStats.networkBytes()
        let dd = Double(n.down &- lastNet.down) / 2, du = Double(n.up &- lastNet.up) / 2
        netDown = max(0, dd); netUp = max(0, du); lastNet = n
        netTotal = n.down &- (netBase?.0 ?? n.down)
        push(&netHist, netDown)

        var hscore = 100.0
        hscore -= max(0, cpu - 50) * 0.3
        hscore -= max(0, Double(memPressure) - 50) * 0.5
        let usedPct = disk.total > 0 ? Double(disk.used) / Double(disk.total) * 100 : 0
        hscore -= max(0, usedPct - 80) * 1.2
        if let h = battery?.health { hscore -= Double(100 - h) * 0.3 }
        health = max(0, min(100, Int(hscore.rounded())))

        let boot = SysStats.sysctlBootDate()
        if let boot {
            let days = Int(Date().timeIntervalSince(boot) / 86400)
            let df = DateFormatter(); df.dateFormat = "d MMM, h:mm a"
            uptimeText = "Up \(days == 0 ? "today" : "\(days) day\(days == 1 ? "" : "s")") · since \(df.string(from: boot))"
        }

        let procInterval: TimeInterval = visible ? 2 : 30
        if Date().timeIntervalSince(lastProcs) >= procInterval - 0.5 {
            lastProcs = Date()
            await refreshProcs()
        }
        if visible, Date().timeIntervalSince(lastPorts) >= 9.5 {
            lastPorts = Date()
            await refreshPorts()
        }
    }

    func refreshProcs() async {
        let out = await Shell.run("/bin/ps", ["-Axo", "pid=,pcpu=,rss=,comm="])
        var rows: [ProcRow] = []
        var appCPU: [String: Double] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int32(parts[0]), let cpu = Double(parts[1]), let rss = Int64(parts[2]) else { continue }
            let path = String(parts[3])
            var appName: String?; var appPath: String?
            if let r = path.range(of: ".app/") {
                let appDir = String(path[path.startIndex..<r.lowerBound]) + ".app"
                appName = ((appDir as NSString).lastPathComponent as NSString).deletingPathExtension
                appPath = appDir
                appCPU[appName!, default: 0] += cpu
            }
            let name = (path as NSString).lastPathComponent
            rows.append(ProcRow(pid: pid, name: name, app: appName == name ? nil : appName, appPath: appPath, cpu: cpu, mem: rss * 1024))
        }
        procCount = rows.count
        procs = Array(rows.sorted { $0.cpu > $1.cpu }.prefix(40))
        if Date().timeIntervalSince(lastHistoryAt) >= 29 {
            lastHistoryAt = Date()
            let now = Date().timeIntervalSince1970
            for (k, v) in appCPU where v > 0 { history[k, default: []].append(CPUSample(t: now, cpu: v)) }
            let cutoff = now - 86400
            for k in history.keys { history[k]?.removeAll { $0.t < cutoff }; if history[k]?.isEmpty == true { history[k] = nil } }
            historyDirty = true
            saveHistory()
        }
    }

    func refreshPorts() async {
        let out = await Shell.run("/usr/sbin/lsof", ["-iTCP", "-sTCP:LISTEN", "-nP", "-F", "pcn"])
        var rows: [PortRow] = []
        var pid: Int32 = 0; var cmd = ""
        var seen = Set<String>()
        for line in out.split(separator: "\n") {
            guard let f = line.first else { continue }
            let v = String(line.dropFirst())
            switch f {
            case "p": pid = Int32(v) ?? 0
            case "c": cmd = v.replacingOccurrences(of: "\\x20", with: " ")
            case "n":
                guard let colon = v.lastIndex(of: ":"), let port = Int(v[v.index(after: colon)...]) else { continue }
                let host = String(v[v.startIndex..<colon])
                let local = host == "127.0.0.1" || host == "[::1]" || host == "localhost"
                let key = "\(port)-\(pid)"
                if seen.insert(key).inserted { rows.append(PortRow(port: port, process: cmd, pid: pid, address: local ? "local" : "all")) }
            default: break
            }
        }
        ports = rows.sorted { $0.port < $1.port }
    }

    func stop(pid: Int32, name: String) {
        let a = NSAlert()
        a.messageText = "Stop \(name)?"
        a.informativeText = "This sends a quit signal to process \(pid). Anything unsaved in it may be lost."
        a.addButton(withTitle: "Stop"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        if kill(pid, SIGTERM) == 0 {
            app?.activity.record(.stop, title: "Stopped \(name)", detail: "pid \(pid)")
            app?.showToast("Stopped \(name)")
            Task { try? await Task.sleep(nanoseconds: 600_000_000); await refreshPorts(); await refreshProcs() }
        } else { app?.showToast("Couldn't stop \(name)") }
    }

    // MARK: per-app CPU history

    private var historyFile: URL {
        let d = FS.fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DiskBuddy")
        try? FS.fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("cpu-history.json")
    }
    private func loadHistory() {
        if let d = try? Data(contentsOf: historyFile), let h = try? JSONDecoder().decode([String: [CPUSample]].self, from: d) { history = h }
    }
    private func saveHistory() {
        guard historyDirty, let d = try? JSONEncoder().encode(history) else { return }
        try? d.write(to: historyFile); historyDirty = false
    }

    /// 24 hourly buckets (oldest first) of the app's average CPU.
    func hourly(for app: String) -> (values: [Double], busiest: String?, peak: Double)? {
        guard let s = history[app], s.count > 1 else { return nil }
        let now = Date().timeIntervalSince1970
        var buckets = [Double](repeating: 0, count: 24), counts = [Double](repeating: 0, count: 24)
        for x in s {
            let idx = 23 - Int((now - x.t) / 3600)
            if idx >= 0 && idx < 24 { buckets[idx] = max(buckets[idx], x.cpu); counts[idx] += 1 }
        }
        let peak = s.map(\.cpu).max() ?? 0
        guard let best = s.max(by: { $0.cpu < $1.cpu }) else { return nil }
        let df = DateFormatter(); df.dateFormat = "h a"
        return (buckets, df.string(from: Date(timeIntervalSince1970: best.t)).lowercased(), peak)
    }
}

extension SysStats {
    static func sysctlBootDate() -> Date? {
        var tv = timeval(); var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
    }
}
