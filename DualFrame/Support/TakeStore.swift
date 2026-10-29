import AVFoundation
import UIKit

struct Take: Identifiable, Hashable {
    let id: String
    let folder: URL
    let files: [URL]
    let date: Date
    let bytes: Int64
}

/// Takes live in Documents/Takes/<name>/, visible in the Files app.
@MainActor
final class TakeStore: ObservableObject {
    static let didChange = Notification.Name("TakeStore.didChange")

    nonisolated static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Takes")
    }

    @Published private(set) var takes: [Take] = []
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: Self.didChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        reload()
    }

    func reload() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.root, withIntermediateDirectories: true)
        let folders = (try? fm.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: [.creationDateKey],
                                                   options: [.skipsHiddenFiles])) ?? []
        takes = folders.compactMap { folder -> Take? in
            let files = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey],
                                                      options: [.skipsHiddenFiles])) ?? [])
                .filter { ["mov", "mp4"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard !files.isEmpty else { return nil }
            let date = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let bytes = files.reduce(Int64(0)) { sum, url in
                sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            return Take(id: folder.lastPathComponent, folder: folder, files: files, date: date, bytes: bytes)
        }
        .sorted { $0.date > $1.date }
    }

    func delete(_ take: Take) {
        try? FileManager.default.removeItem(at: take.folder)
        reload()
    }

    static func label(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        if name.hasSuffix("_Vertical") { return "Vertical 9:16" }
        if name.hasSuffix("_Horizontal") { return "Horizontal 16:9" }
        if name.hasSuffix("_Sensor") { return "Sensor 4:3" }
        return name
    }
}

enum Thumbnailer {
    static func image(for url: URL) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 400, height: 400)
        guard let result = try? await generator.image(at: .zero) else { return nil }
        return UIImage(cgImage: result.image)
    }

    static func details(for url: URL) async -> String {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let loaded = try? await track.load(.naturalSize, .preferredTransform, .nominalFrameRate),
              let duration = try? await asset.load(.duration) else { return "" }
        let upright = loaded.0.applying(loaded.1)
        return "\(Int(abs(upright.width)))×\(Int(abs(upright.height))) · \(Int(loaded.2.rounded())) fps · \(formatDuration(duration.seconds))"
    }
}
