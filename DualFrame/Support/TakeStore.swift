import AVFoundation
import UIKit

struct Take: Identifiable, Hashable {
    let id: String
    let folder: URL
    let files: [URL]
    let date: Date
    let bytes: Int64

    var isPhoto: Bool { files.allSatisfy(TakeStore.isPhoto) }
}

/// Takes live in Documents/Takes/<name>/, visible in the Files app.
@MainActor
final class TakeStore: ObservableObject {
    static let didChange = Notification.Name("TakeStore.didChange")
    nonisolated static let mediaExtensions: Set<String> = ["mov", "mp4", "heic", "jpg", "dng"]

    nonisolated static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Takes")
    }

    nonisolated static func isPhoto(_ url: URL) -> Bool {
        ["heic", "jpg", "dng"].contains(url.pathExtension.lowercased())
    }

    @Published private(set) var takes: [Take] = []
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: Self.didChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        reload()
    }

    nonisolated static func files(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey],
                                                        options: [.skipsHiddenFiles])) ?? [])
            .filter { mediaExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { order($0) < order($1) }
    }

    /// Vertical, horizontal, sensor.
    nonisolated private static func order(_ url: URL) -> Int {
        let name = url.deletingPathExtension().lastPathComponent
        if name.hasSuffix("_Vertical") { return 0 }
        if name.hasSuffix("_Horizontal") { return 1 }
        if name.hasSuffix("_RAW") { return 3 }
        return 2
    }

    nonisolated static func folders() -> [(URL, Date)] {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey],
                                                   options: [.skipsHiddenFiles])) ?? []
        return folders.map { folder in
            (folder, (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
        }
        .sorted { $0.1 > $1.1 }
    }

    nonisolated static func latestFile() -> URL? {
        for (folder, _) in folders() {
            if let first = files(in: folder).first { return first }
        }
        return nil
    }

    func reload() {
        takes = Self.folders().compactMap { folder, date -> Take? in
            let files = Self.files(in: folder)
            guard !files.isEmpty else { return nil }
            let bytes = files.reduce(Int64(0)) { sum, url in
                sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            return Take(id: folder.lastPathComponent, folder: folder, files: files, date: date, bytes: bytes)
        }
    }

    func delete(_ take: Take) {
        try? FileManager.default.removeItem(at: take.folder)
        reload()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    nonisolated static func label(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        if name.hasSuffix("_Vertical") { return "9:16" }
        if name.hasSuffix("_Horizontal") { return "16:9" }
        if name.hasSuffix("_Sensor") { return "4:3" }
        if name.hasSuffix("_RAW") { return "RAW" }
        return name
    }
}

enum Thumbnailer {
    static func image(for url: URL) async -> UIImage? {
        if TakeStore.isPhoto(url) {
            return await UIImage(contentsOfFile: url.path)?.byPreparingThumbnail(ofSize: CGSize(width: 300, height: 300))
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 400, height: 400)
        guard let result = try? await generator.image(at: .zero) else { return nil }
        return UIImage(cgImage: result.image)
    }

    static func details(for url: URL) async -> String {
        if TakeStore.isPhoto(url) {
            guard let image = UIImage(contentsOfFile: url.path) else { return "" }
            let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
            return "\(Int(pixels.width))×\(Int(pixels.height)) · \(url.pathExtension.uppercased())"
        }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let loaded = try? await track.load(.naturalSize, .preferredTransform, .nominalFrameRate),
              let duration = try? await asset.load(.duration) else { return "" }
        let upright = loaded.0.applying(loaded.1)
        return "\(Int(abs(upright.width)))×\(Int(abs(upright.height))) · \(Int(loaded.2.rounded())) fps · \(formatDuration(duration.seconds))"
    }
}
