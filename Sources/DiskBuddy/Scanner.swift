import Foundation
import AppKit

struct ScanResult {
    var groups: [CleanGroup] = []
    var apps: Int64 = 0, appCount = 0
    var docs: Int64 = 0, docCount = 0
    var media: Int64 = 0, mediaCount = 0
    var other: Int64 = 0, otherCount = 0
    var system: Int64 = 0
    var disk = DiskInfo(total: 0, free: 0, name: "Macintosh HD")
    var folders: [String: Int64] = [:]
    var itemsScanned = 0
    var duration: TimeInterval = 0
    var date = Date()
}

final class ScanProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var _done = 0, _total = 1
    private var _path = ""
    func setTotal(_ n: Int) { lock.lock(); _total = max(1, n); lock.unlock() }
    func finishUnit() { lock.lock(); _done += 1; lock.unlock() }
    func setPath(_ p: String) { lock.lock(); _path = p; lock.unlock() }
    var snapshot: (Double, String) { lock.lock(); defer { lock.unlock() }; return (Double(_done) / Double(_total), _path) }
}

private struct Local {
    var groups: [GroupID: [CleanItem]] = [:]
    var apps: Int64 = 0, appCount = 0
    var docs: Int64 = 0, docCount = 0
    var media: Int64 = 0, mediaCount = 0
    var other: Int64 = 0, otherCount = 0
    var total: Int64 = 0
    var items = 0
    mutating func add(_ g: GroupID, _ it: CleanItem) { groups[g, default: []].append(it); total += it.size }
}

private enum Special {
    case perChild(GroupID)
    case whole(GroupID, String)
    case containers
    case downloads
    case ollama, huggingface, lmstudio, jan
    case skip
}

enum Scanner {
    private static let buildNames: [String: [String]] = [
        "build": ["package.json", "build.gradle", "build.gradle.kts", "pom.xml", "CMakeLists.txt", "setup.py", "pubspec.yaml"],
        "dist": ["package.json", "setup.py", "pyproject.toml"],
        "out": ["package.json"],
        "target": ["Cargo.toml", "pom.xml"],
        ".build": ["Package.swift"],
        ".next": [], ".nuxt": [], ".turbo": [], ".parcel-cache": [], ".svelte-kit": [],
    ]

    private static func specials() -> [String: Special] {
        let h = FS.home.path
        return [
            h + "/Library/Caches": .perChild(.caches),
            h + "/Library/Logs": .perChild(.logs),
            h + "/Library/Containers": .containers,
            h + "/Library/Developer/Xcode/DerivedData": .perChild(.buildOutput),
            h + "/Library/Group Containers/group.com.docker": .whole(.docker, "Docker"),
            h + "/Library/Application Support/LM Studio": .whole(.ai, "LM Studio"),
            h + "/Library/Application Support/Jan": .whole(.ai, "Jan"),
            h + "/.ollama": .ollama,
            h + "/.lmstudio": .lmstudio,
            h + "/.cache/huggingface": .huggingface,
            h + "/.cache/torch": .whole(.ai, "PyTorch"),
            h + "/jan": .jan,
            h + "/.npm": .whole(.packageCaches, "npm"),
            h + "/.cargo/registry": .whole(.packageCaches, "Cargo"),
            h + "/.gradle/caches": .whole(.packageCaches, "Gradle"),
            h + "/.m2/repository": .whole(.packageCaches, "Maven"),
            h + "/.pnpm-store": .whole(.packageCaches, "pnpm"),
            h + "/Library/pnpm": .whole(.packageCaches, "pnpm"),
            h + "/.yarn/cache": .whole(.packageCaches, "Yarn"),
            h + "/.docker": .whole(.docker, "Docker"),
            h + "/Parallels": .whole(.docker, "Parallels"),
            h + "/.Trash": .skip,
            h + "/Library/CloudStorage": .skip,
            h + "/Downloads": .downloads,
        ]
    }

    private static func childItems(_ dir: URL, cancel: (() -> Bool)? = nil) -> [CleanItem] {
        let kids = FS.children(dir)
        var out = [CleanItem?](repeating: nil, count: kids.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: kids.count) { i in
            let k = kids[i]
            let (b, _) = FS.tree(k)
            if b > 0 {
                let item = CleanItem(url: k, size: b)
                lock.lock(); out[i] = item; lock.unlock()
            }
        }
        return out.compactMap { $0 }
    }

    /// One item per Ollama model. Weight files shared with another model are left alone.
    private static func ollamaModels(_ root: URL) -> [CleanItem] {
        let manifests = root.appendingPathComponent("models/manifests")
        let blobs = root.appendingPathComponent("models/blobs")
        struct Manifest { let url: URL; let name: String; let layers: [(digest: String, size: Int64)] }
        var list: [Manifest] = []
        if let e = FS.fm.enumerator(at: manifests, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let u as URL in e where (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                guard let data = try? Data(contentsOf: u),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                var layers: [(String, Int64)] = []
                if let c = json["config"] as? [String: Any], let d = c["digest"] as? String { layers.append((d, (c["size"] as? NSNumber)?.int64Value ?? 0)) }
                for l in json["layers"] as? [[String: Any]] ?? [] {
                    if let d = l["digest"] as? String { layers.append((d, (l["size"] as? NSNumber)?.int64Value ?? 0)) }
                }
                var parts = u.path.replacingOccurrences(of: manifests.path + "/", with: "").split(separator: "/").map(String.init)
                let tag = parts.popLast() ?? ""
                if parts.first == "registry.ollama.ai" { parts.removeFirst() }
                if parts.first == "library" { parts.removeFirst() }
                list.append(Manifest(url: u, name: parts.joined(separator: "/") + ":" + tag, layers: layers))
            }
        }
        var refs: [String: Int] = [:]
        for m in list { for l in Set(m.layers.map(\.digest)) { refs[l, default: 0] += 1 } }
        return list.compactMap { m in
            var size: Int64 = FS.size(of: m.url)
            var extra: [String] = []
            for l in Set(m.layers.map(\.digest)) where refs[l] == 1 {
                let blob = blobs.appendingPathComponent(l.replacingOccurrences(of: ":", with: "-"))
                if FS.fm.fileExists(atPath: blob.path) { size += FS.size(of: blob); extra.append(blob.path) }
            }
            return size > 0 ? CleanItem(url: m.url, size: size, name: m.name, subtitle: "Ollama · ~/.ollama/models", extra: extra) : nil
        }
    }

    private static func huggingFaceModels(_ root: URL) -> [CleanItem] {
        var out: [CleanItem] = []
        for c in FS.children(root.appendingPathComponent("hub")) {
            let n = c.lastPathComponent
            guard n.hasPrefix("models--") || n.hasPrefix("datasets--") || n.hasPrefix("spaces--") else { continue }
            let (b, _) = FS.tree(c)
            guard b > 0 else { continue }
            let kind = n.hasPrefix("datasets--") ? "Dataset " : ""
            let pretty = n.drop { $0 != "-" }.dropFirst(2).replacingOccurrences(of: "--", with: "/")
            out.append(CleanItem(url: c, size: b, name: kind + pretty, subtitle: "Hugging Face · ~/.cache/huggingface/hub"))
        }
        return out
    }

    private static func appName(forBundleID id: String) -> String {
        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return u.deletingPathExtension().lastPathComponent
        }
        return id
    }

    private static func handleSpecial(_ s: Special, url: URL, loc: inout Local) {
        switch s {
        case .skip: break
        case .perChild(let g):
            for it in childItems(url) { loc.add(g, it) }
        case .whole(let g, let name):
            let (b, _) = FS.tree(url)
            if b > 0 { loc.add(g, CleanItem(url: url, size: b, name: name)) }
        case .ollama: for it in ollamaModels(url) { loc.add(.ai, it) }
        case .huggingface: for it in huggingFaceModels(url) { loc.add(.ai, it) }
        case .lmstudio:
            for pub in FS.children(url.appendingPathComponent("models")) where FS.isDirectory(pub) {
                for m in FS.children(pub) {
                    let (b, _) = FS.tree(m)
                    if b > 0 { loc.add(.ai, CleanItem(url: m, size: b, name: "\(pub.lastPathComponent)/\(m.lastPathComponent)", subtitle: "LM Studio · ~/.lmstudio/models")) }
                }
            }
        case .jan:
            for m in FS.children(url.appendingPathComponent("models")) {
                let (b, _) = FS.tree(m)
                if b > 0 { loc.add(.ai, CleanItem(url: m, size: b, name: m.lastPathComponent, subtitle: "Jan · ~/jan/models")) }
            }
        case .containers:
            let kids = FS.children(url)
            let lock = NSLock()
            var cacheItems: [CleanItem] = [], dockerItems: [CleanItem] = []
            var otherBytes: Int64 = 0
            DispatchQueue.concurrentPerform(iterations: kids.count) { i in
                let c = kids[i]
                let id = c.lastPathComponent
                let lower = id.lowercased()
                if lower.contains("docker") || lower.contains("utmapp") || lower.contains("parallels") || lower.contains("vmware") {
                    let (b, _) = FS.tree(c)
                    if b > 0 {
                        let it = CleanItem(url: c, size: b, name: appName(forBundleID: id), subtitle: "~/Library/Containers")
                        lock.lock(); dockerItems.append(it); lock.unlock()
                    }
                    return
                }
                let caches = c.appendingPathComponent("Data/Library/Caches")
                let (cb, _) = FS.tree(caches)
                let (tb, _) = FS.tree(c)
                lock.lock()
                if cb > 0 {
                    cacheItems.append(CleanItem(url: caches, size: cb, name: appName(forBundleID: id),
                                                subtitle: "~/Library/Containers/\(id)"))
                }
                otherBytes += max(0, tb - cb)
                lock.unlock()
            }
            for it in cacheItems { loc.add(.sandboxCaches, it) }
            for it in dockerItems { loc.add(.docker, it) }
            loc.other += otherBytes; loc.total += otherBytes
        case .downloads:
            for k in FS.children(url) {
                let (b, _) = FS.tree(k)
                guard b > 0 else { continue }
                let item = CleanItem(url: k, size: b)
                if FS.installerExt.contains(k.pathExtension.lowercased()) { loc.add(.installers, item) }
                else { loc.add(.downloads, item) }
            }
        }
    }

    private static func walkUnit(_ unit: URL, specials: [String: Special], progress: ScanProgress) -> Local {
        var loc = Local()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        let keySet = Set(keys)
        let libPrefix = FS.home.path + "/Library/"

        func classifyFile(_ u: URL, _ size: Int64) {
            let ext = u.pathExtension.lowercased()
            loc.total += size
            if FS.videoExt.contains(ext) || FS.audioExt.contains(ext), size > 100_000_000, !u.path.hasPrefix(libPrefix) {
                loc.groups[.largeMedia, default: []].append(CleanItem(url: u, size: size))
                return
            }
            if FS.imageExt.contains(ext) || FS.videoExt.contains(ext) || FS.audioExt.contains(ext) {
                loc.media += size; loc.mediaCount += 1
            } else if FS.docExt.contains(ext) {
                loc.docs += size; loc.docCount += 1
            } else {
                loc.other += size; loc.otherCount += 1
            }
        }

        /// Returns true if the directory was fully handled (don't descend).
        func handleDir(_ u: URL) -> Bool {
            if let s = specials[u.path] {
                handleSpecial(s, url: u, loc: &loc)
                return true
            }
            let name = u.lastPathComponent
            if name == "node_modules" {
                let (b, _) = FS.tree(u)
                if b > 0 { loc.add(.nodeModules, CleanItem(url: u, size: b)) }
                return true
            }
            if let need = buildNames[name] {
                let parent = u.deletingLastPathComponent().path
                if need.isEmpty || need.contains(where: { FS.fm.fileExists(atPath: parent + "/" + $0) }) {
                    let (b, _) = FS.tree(u)
                    if b > 0 { loc.add(.buildOutput, CleanItem(url: u, size: b)) }
                    return true
                }
            }
            let ext = u.pathExtension.lowercased()
            if ext == "app" {
                let (b, _) = FS.tree(u); loc.apps += b; loc.appCount += 1; loc.total += b; return true
            }
            if ["photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle"].contains(ext) {
                let (b, _) = FS.tree(u); loc.media += b; loc.mediaCount += 1; loc.total += b; return true
            }
            return false
        }

        guard let rv = try? unit.resourceValues(forKeys: keySet), rv.isSymbolicLink != true else { return loc }
        if rv.isDirectory != true {
            classifyFile(unit, FS.allocated(rv)); loc.items += 1
            return loc
        }
        progress.setPath(abbreviated(unit.path))
        if handleDir(unit) { return loc }

        guard let e = FS.fm.enumerator(at: unit, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return loc }
        var n = 0
        while true {
            var finished = false
            autoreleasepool {
                guard let u = e.nextObject() as? URL else { finished = true; return }
                loc.items += 1
                n += 1
                guard let v = try? u.resourceValues(forKeys: keySet) else { return }
                if v.isSymbolicLink == true { return }
                if v.isDirectory == true {
                    if n & 0xFF == 0 { progress.setPath(abbreviated(u.path)) }
                    if handleDir(u) { e.skipDescendants() }
                } else {
                    classifyFile(u, FS.allocated(v))
                }
            }
            if finished { break }
        }
        return loc
    }

    static func run(progress: ScanProgress) -> ScanResult {
        let started = Date()
        let home = FS.home
        let specials = specials()

        // Work units: every home child, with ~/Library split into its own children.
        var units: [URL] = []
        for c in FS.children(home) {
            if c.lastPathComponent == ".Trash" { continue }
            if c.lastPathComponent == "Library" { units.append(contentsOf: FS.children(c)) }
            else { units.append(c) }
        }
        let appDirs = (FS.children(URL(fileURLWithPath: "/Applications")) + FS.children(home.appendingPathComponent("Applications")))
        progress.setTotal(units.count + 1)

        let lock = NSLock()
        var locals: [(URL, Local)] = []
        var appBytes: Int64 = 0, appCount = 0

        DispatchQueue.concurrentPerform(iterations: units.count + 1) { i in
            if i == units.count {
                var bytes: Int64 = 0; var cnt = 0
                let l2 = NSLock()
                DispatchQueue.concurrentPerform(iterations: appDirs.count) { j in
                    let (b, _) = FS.tree(appDirs[j])
                    l2.lock(); bytes += b; if appDirs[j].pathExtension == "app" { cnt += 1 }; l2.unlock()
                }
                lock.lock(); appBytes = bytes; appCount = cnt; lock.unlock()
            } else {
                let loc = walkUnit(units[i], specials: specials, progress: progress)
                lock.lock(); locals.append((units[i], loc)); lock.unlock()
            }
            progress.finishUnit()
        }

        var r = ScanResult()
        r.apps = appBytes; r.appCount = appCount
        var merged: [GroupID: [CleanItem]] = [:]
        for (unit, l) in locals {
            r.apps += l.apps; r.appCount += l.appCount
            r.docs += l.docs; r.docCount += l.docCount
            r.media += l.media; r.mediaCount += l.mediaCount
            r.other += l.other; r.otherCount += l.otherCount
            r.itemsScanned += l.items
            for (g, items) in l.groups { merged[g, default: []].append(contentsOf: items) }
            let parent = unit.deletingLastPathComponent().lastPathComponent
            let key = parent == "Library" ? "Library" : unit.lastPathComponent
            r.folders[key, default: 0] += l.total
        }
        r.groups = GroupID.allCases.compactMap { id in
            guard let items = merged[id], !items.isEmpty else { return nil }
            return CleanGroup(id: id, items: items.sorted { $0.size > $1.size })
        }
        r.disk = DiskInfo.read()
        let accounted = r.apps + r.docs + r.media + r.other + r.groups.reduce(0) { $0 + $1.size }
        r.system = max(0, r.disk.used - accounted)
        r.duration = Date().timeIntervalSince(started)
        r.date = Date()
        return r
    }
}
