import SwiftUI
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import Observation

struct CompressItem: Identifiable {
    enum Status: Equatable { case pending, working(Double), done, failed(String) }
    let id = UUID()
    let url: URL
    let isVideo: Bool
    let before: Int64
    var after: Int64?
    var status: Status = .pending
    var output: URL?
    var thumb: NSImage?
    var name: String { url.lastPathComponent }
}

@Observable @MainActor
final class CompressModel {
    enum Quality: String { case smaller = "Smaller", balanced = "Balanced", best = "Best" }
    enum PhotoFormat: String, CaseIterable { case same = "Same", jpg = "JPG", png = "PNG", webp = "WebP", avif = "AVIF", heic = "HEIC"
        var utType: String? {
            switch self { case .same: nil; case .jpg: "public.jpeg"; case .png: "public.png"; case .webp: "org.webmproject.webp"; case .avif: "public.avif"; case .heic: "public.heic" }
        }
        var ext: String? { switch self { case .jpg: "jpg"; case .png: "png"; case .webp: "webp"; case .avif: "avif"; case .heic: "heic"; case .same: nil } }
        var supported: Bool {
            guard let t = utType else { return true }
            let ids = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
            return ids.contains(t)
        }
    }
    weak var app: AppModel?
    var items: [CompressItem] = []
    var quality: Quality = .smaller
    var photoFormat: PhotoFormat = .same
    var keepOriginals = true
    var photoQuality = 0.72
    var running = false
    private var task: Task<Void, Never>?

    static func isMedia(_ u: URL) -> Bool { let e = u.pathExtension.lowercased(); return FS.videoExt.contains(e) || FS.imageExt.contains(e) && e != "svg" && e != "icns" && e != "psd" }

    func add(_ urls: [URL]) {
        for u in urls where Self.isMedia(u) && !items.contains(where: { $0.url == u }) {
            let video = FS.videoExt.contains(u.pathExtension.lowercased())
            var it = CompressItem(url: u, isVideo: video, before: FS.size(of: u))
            it.thumb = Self.thumbnail(u, video: video)
            items.append(it)
        }
    }

    static func thumbnail(_ u: URL, video: Bool) -> NSImage? {
        if video {
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: u)); g.appliesPreferredTrackTransform = true
            g.maximumSize = CGSize(width: 120, height: 120)
            if let cg = try? g.copyCGImage(at: .zero, actualTime: nil) { return NSImage(cgImage: cg, size: .zero) }
            return nil
        }
        return NSImage(contentsOf: u)
    }

    func pick() {
        let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.canChooseDirectories = false
        p.allowedContentTypes = [.movie, .image]
        if p.runModal() == .OK { add(p.urls) }
    }

    var pending: [CompressItem] { items.filter { $0.status == .pending } }
    var beforeTotal: Int64 { items.filter { $0.after != nil }.reduce(0) { $0 + $1.before } }
    var afterTotal: Int64 { items.compactMap(\.after).reduce(0, +) }
    var saved: Int64 { max(0, beforeTotal - afterTotal) }

    func run() {
        guard !running else { return }
        running = true
        task = Task { [weak self] in
            guard let self else { return }
            for i in self.items.indices where self.items[i].status == .pending {
                if Task.isCancelled { break }
                let it = self.items[i]
                self.items[i].status = .working(0)
                do {
                    let out = it.isVideo ? try await self.compressVideo(it, index: i) : try await self.compressPhoto(it)
                    let after = FS.size(of: out)
                    if after >= it.before {
                        try? FileManager.default.removeItem(at: out)
                        self.items[i].after = it.before; self.items[i].status = .failed("Already as small as it gets")
                        continue
                    }
                    self.items[i].after = after; self.items[i].output = out; self.items[i].status = .done
                    if !self.keepOriginals { _ = FS.trash([CleanItem(url: it.url, size: it.before)]) }
                    self.app?.activity.record(.compress, title: "Compressed 1 file", detail: it.name, bytes: it.before - after)
                    self.app?.showToast("Compressed 1 file")
                } catch {
                    self.items[i].status = .failed(error.localizedDescription)
                }
            }
            self.running = false
        }
    }

    func stop() {
        task?.cancel(); running = false
        for i in items.indices { if case .working = items[i].status { items[i].status = .pending } }
    }

    func outputURL(_ u: URL, ext: String? = nil) -> URL {
        let base = u.deletingPathExtension().lastPathComponent
        let e = ext ?? u.pathExtension
        var out = u.deletingLastPathComponent().appendingPathComponent("\(base) (compressed).\(e)")
        var n = 2
        while FS.fm.fileExists(atPath: out.path) { out = u.deletingLastPathComponent().appendingPathComponent("\(base) (compressed \(n)).\(e)"); n += 1 }
        return out
    }

    private func compressVideo(_ it: CompressItem, index: Int) async throws -> URL {
        let asset = AVURLAsset(url: it.url)
        let compatible = AVAssetExportSession.exportPresets(compatibleWith: asset)
        let wanted: String
        switch quality {
        case .smaller: wanted = AVAssetExportPreset960x540
        case .balanced: wanted = AVAssetExportPresetHEVC1920x1080
        case .best: wanted = AVAssetExportPresetHEVCHighestQuality
        }
        let preset = compatible.contains(wanted) ? wanted : (compatible.contains(AVAssetExportPresetMediumQuality) ? AVAssetExportPresetMediumQuality : AVAssetExportPresetPassthrough)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { throw NSError(domain: "DiskBuddy", code: 1, userInfo: [NSLocalizedDescriptionKey: "This video can't be read"]) }
        let isMov = it.url.pathExtension.lowercased() == "mov"
        let type: AVFileType = isMov && session.supportedFileTypes.contains(.mov) ? .mov : (session.supportedFileTypes.contains(.mp4) ? .mp4 : .mov)
        let out = outputURL(it.url, ext: type == .mov ? "mov" : "mp4")
        session.outputURL = out; session.outputFileType = type; session.shouldOptimizeForNetworkUse = true
        let poll = Task { [weak self] in
            while !Task.isCancelled {
                self?.items[safe: index]?.status = .working(Double(session.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        await session.export()
        poll.cancel()
        if session.status != .completed { try? FS.fm.removeItem(at: out); throw session.error ?? NSError(domain: "DiskBuddy", code: 2, userInfo: [NSLocalizedDescriptionKey: "Export did not finish"]) }
        return out
    }

    private func compressPhoto(_ it: CompressItem) async throws -> URL {
        let q = photoQuality, fmt = photoFormat
        return try await Task.detached(priority: .userInitiated) { () -> URL in
            guard let src = CGImageSourceCreateWithURL(it.url as CFURL, nil), let srcType = CGImageSourceGetType(src) as String? else {
                throw NSError(domain: "DiskBuddy", code: 3, userInfo: [NSLocalizedDescriptionKey: "This photo can't be read"])
            }
            let writable = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
            let type = fmt.utType ?? (writable.contains(srcType) ? srcType : "public.jpeg")
            guard writable.contains(type) else { throw NSError(domain: "DiskBuddy", code: 4, userInfo: [NSLocalizedDescriptionKey: "This Mac can't write that format"]) }
            let ext = fmt.ext ?? (UTType(type)?.preferredFilenameExtension ?? it.url.pathExtension)
            let out = await MainActor.run { self.outputURL(it.url, ext: ext) }
            guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type as CFString, 1, nil) else {
                throw NSError(domain: "DiskBuddy", code: 5, userInfo: [NSLocalizedDescriptionKey: "Couldn't create the output file"])
            }
            CGImageDestinationAddImageFromSource(dest, src, 0, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "DiskBuddy", code: 6, userInfo: [NSLocalizedDescriptionKey: "Couldn't write the photo"]) }
            return out
        }.value
    }
}

extension Array {
    subscript(safe i: Int) -> Element? {
        get { indices.contains(i) ? self[i] : nil }
        set { if let v = newValue, indices.contains(i) { self[i] = v } }
    }
}

@MainActor struct CompressView: View {
    @Environment(AppModel.self) var model
    @State private var targeted = false
    @State private var showMore = false

    var body: some View {
        let c = model.compress
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.items.isEmpty ? "Compress" : "\(c.items.count) file\(c.items.count == 1 ? "" : "s")").font(.system(size: 15, weight: .semibold))
                        Text(c.items.isEmpty ? "Shrink videos and photos instead of deleting them" :
                                "\(bytesString(c.items.reduce(0) { $0 + $1.before })) · \(c.items.filter(\.isVideo).count) video\(c.items.filter(\.isVideo).count == 1 ? "" : "s")")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if c.items.contains(where: { $0.status == .done }) {
                        Button("Clear finished") { c.items.removeAll { $0.status == .done } }.buttonStyle(SoftButtonStyle())
                    }
                    Button { c.pick() } label: { Label("Add files", systemImage: "plus") }.buttonStyle(SoftButtonStyle())
                }
                .padding(.bottom, 12)
                if c.items.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.doc").font(.system(size: 24)).foregroundStyle(.tertiary)
                        Text("Drop videos or photos anywhere here").font(.system(size: 12))
                        Text("Compressed copies are saved next to the originals.").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView { VStack(spacing: 0) { ForEach(c.items) { row($0) } }
                        Text("Drop more videos or photos anywhere here").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.top, 14) }
                }
            }
            .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 14)
            .overlay { if targeted { RoundedRectangle(cornerRadius: 10).stroke(Theme.blue, style: StrokeStyle(lineWidth: 1.5, dash: [6])).padding(8) } }
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in if let url { Task { @MainActor in c.add([url]) } } }
                }
                return true
            }
            settings.frame(width: 290).padding(.trailing, 14).padding(.top, 14).padding(.bottom, 14)
        }
    }

    func row(_ it: CompressItem) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08))
                if let t = it.thumb { Image(nsImage: t).resizable().scaledToFill() }
            }.frame(width: 42, height: 30).clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 1) {
                Text(it.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                Text(sub(it)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            switch it.status {
            case .working(let p):
                ProgressView(value: p).frame(width: 70).controlSize(.small)
            case .done:
                HStack(spacing: 6) {
                    Text("\(bytesString(it.before)) → \(bytesString(it.after ?? 0))").font(.system(size: 10.5)).monospacedDigit()
                    let pct = Int((1 - Double(it.after ?? 0) / Double(max(it.before, 1))) * 100)
                    Text("−\(pct)%").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.green)
                        .padding(.horizontal, 5).padding(.vertical, 1).background(Theme.green.opacity(0.14), in: Capsule())
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                }
            case .failed(let m):
                Text(m).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            case .pending:
                HStack(spacing: 8) {
                    Text(bytesString(it.before)).font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.secondary)
                    Button { model.compress.items.removeAll { $0.id == it.id } } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary) }.buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 7).padding(.horizontal, 8)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 7)).padding(.bottom, 4)
    }

    func sub(_ it: CompressItem) -> String {
        if case .done = it.status, let o = it.output { return "Saved as \(o.lastPathComponent)" }
        if case .working = it.status { return "Compressing…" }
        return abbreviated(it.url.deletingLastPathComponent().path)
    }

    var settings: some View {
        @Bindable var c = model.compress
        return VStack(alignment: .leading, spacing: 0) {
            Text("Settings").font(.system(size: 11.5, weight: .semibold))
            Text("Video quality").font(.system(size: 10.5, weight: .medium)).padding(.top, 12)
            Seg(options: [(CompressModel.Quality.smaller, "Smaller"), (.balanced, "Balanced"), (.best, "Best")], sel: $c.quality).padding(.top, 5)
            Text(c.quality == .smaller ? "Good for sharing" : c.quality == .balanced ? "Full HD, modern codec" : "Highest quality, bigger files")
                .font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 4)
            Text("Photo format").font(.system(size: 10.5, weight: .medium)).padding(.top, 12)
            HStack(spacing: 0) {
                ForEach(CompressModel.PhotoFormat.allCases, id: \.self) { f in
                    Text(f.rawValue).font(.system(size: 10.5, weight: c.photoFormat == f ? .semibold : .regular))
                        .foregroundStyle(f.supported ? (c.photoFormat == f ? Color.primary : Color.primary.opacity(0.5)) : Color.primary.opacity(0.2))
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(c.photoFormat == f ? Theme.bg : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                        .onTapGesture { if f.supported { c.photoFormat = f } }
                        .help(f.supported ? "" : "This Mac can't write \(f.rawValue)")
                }
            }.padding(2).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7)).padding(.top, 5)
            Text(c.photoFormat == .same ? "Each photo keeps its own format" : "Photos are converted to \(c.photoFormat.rawValue)").font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 4)
            Toggle(isOn: $c.keepOriginals) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Keep originals").font(.system(size: 10.5, weight: .medium))
                    Text(c.keepOriginals ? "Copies are saved next to them" : "Originals go to the Trash").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.toggleStyle(.switch).tint(Theme.green).padding(.top, 12)
            Button { showMore.toggle() } label: {
                HStack { Image(systemName: "gearshape"); Text("More options…"); Spacer(); Image(systemName: "chevron.right").font(.system(size: 9)) }
                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
            }.buttonStyle(.plain).padding(.top, 12)
                .popover(isPresented: $showMore) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Photo quality \(Int(c.photoQuality * 100))%").font(.system(size: 11, weight: .medium))
                        Slider(value: $c.photoQuality, in: 0.3...1).frame(width: 200)
                        Text("Lower is smaller. Applies to JPG, HEIC and AVIF.").font(.system(size: 10)).foregroundStyle(.secondary)
                    }.padding(14)
                }
            Hairline().padding(.vertical, 12)
            Text(c.items.contains { $0.after != nil } ? "Result" : "To compress").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
            if c.items.contains(where: { $0.after != nil }) {
                Text("\(bytesString(c.saved)) smaller").font(.system(size: 22, weight: .semibold)).monospacedDigit().padding(.top, 2)
                bar("Before", c.beforeTotal, 1, Color.primary.opacity(0.35)).padding(.top, 8)
                bar("After", c.afterTotal, c.beforeTotal > 0 ? Double(c.afterTotal) / Double(c.beforeTotal) : 0, Theme.green)
            } else {
                Text(bytesString(c.pending.reduce(0) { $0 + $1.before })).font(.system(size: 22, weight: .semibold)).monospacedDigit().padding(.top, 2)
                Text("The saving shows here as each file finishes.").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if c.running {
                Button { c.stop() } label: { HStack { ProgressView().controlSize(.mini); Text("Stop") }.frame(maxWidth: .infinity) }.buttonStyle(SoftButtonStyle())
            } else {
                Button { c.run() } label: { Text(c.pending.isEmpty ? "Compress" : "Compress \(c.pending.count) file\(c.pending.count == 1 ? "" : "s")").frame(maxWidth: .infinity) }
                    .buttonStyle(DarkButtonStyle()).disabled(c.pending.isEmpty)
            }
            Text("Videos use the Mac's own hardware encoder. Originals stay where they are.").font(.system(size: 9.5)).foregroundStyle(.tertiary).padding(.top, 8)
        }
        .padding(14).background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
    }

    func bar(_ label: String, _ bytes: Int64, _ frac: Double, _ color: Color) -> some View {
        VStack(spacing: 3) {
            HStack { Text(label); Spacer(); Text(bytesString(bytes)).monospacedDigit() }.font(.system(size: 10))
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(color).frame(width: max(3, g.size.width * CGFloat(frac)))
                }
            }.frame(height: 3)
        }.padding(.bottom, 6)
    }
}
