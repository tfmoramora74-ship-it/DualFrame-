import CoreGraphics
import Foundation

/// One file produced by a take. All of them are cut from the same sensor frame.
enum OutputKind: String, CaseIterable, Codable, Identifiable {
    case vertical, horizontal, full

    var id: String { rawValue }

    var label: String {
        switch self {
        case .vertical: return "Vertical 9:16"
        case .horizontal: return "Horizontal 16:9"
        case .full: return "Sensor 4:3"
        }
    }

    var shortLabel: String {
        switch self {
        case .vertical: return "9:16"
        case .horizontal: return "16:9"
        case .full: return "4:3"
        }
    }

    var menuTitle: String {
        switch self {
        case .vertical: return "VERTICAL"
        case .horizontal: return "HORIZONTAL"
        case .full: return "SENSOR 4:3"
        }
    }

    var fileSuffix: String {
        switch self {
        case .vertical: return "Vertical"
        case .horizontal: return "Horizontal"
        case .full: return "Sensor"
        }
    }

    /// Upright width / height of the file.
    var uprightAspect: Double {
        switch self {
        case .vertical: return 9.0 / 16.0
        case .horizontal: return 16.0 / 9.0
        case .full: return 3.0 / 4.0
        }
    }
}

enum OutputResolution: String, CaseIterable, Codable, Identifiable {
    case hd, uhd, native
    var id: String { rawValue }
    var label: String {
        switch self {
        case .hd: return "HD"
        case .uhd: return "4K"
        case .native: return "Nativa"
        }
    }
    /// Long side of the output in pixels. `nil` keeps the cropped sensor pixels unscaled.
    var longSide: Int? {
        switch self {
        case .hd: return 1920
        case .uhd: return 3840
        case .native: return nil
        }
    }
}

enum CaptureMode: String, Codable, CaseIterable, Identifiable {
    case photo, video, longExposure
    var id: String { rawValue }
    var label: String {
        switch self {
        case .photo: return "Foto"
        case .video: return "Vídeo"
        case .longExposure: return "Longa exp."
        }
    }
    var isStill: Bool { self != .video }
}

enum DynamicRange: String, Codable, CaseIterable, Identifiable {
    case sdr, hdr, log
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sdr: return "SDR"
        case .hdr: return "HDR"
        case .log: return "Log"
        }
    }
}

/// How photos are processed.
enum PhotoProcessing: String, Codable, CaseIterable, Identifiable {
    /// Apple's own pipeline (Deep Fusion / Smart HDR); the only one that can also save RAW.
    case apple
    /// 8-frame aligned burst, shot slightly under and tone-mapped (HDR+-style).
    case fusion
    /// 10-frame aligned burst merged onto a 1.5× grid (~27 MP from a 12 MP sensor).
    case superResolution
    var id: String { rawValue }
    var label: String {
        switch self {
        case .apple: return "Apple"
        case .fusion: return "Fusão HDR"
        case .superResolution: return "Super-res"
        }
    }
    var frameCount: Int {
        switch self {
        case .apple: return 1
        case .fusion: return 8
        case .superResolution: return 10
        }
    }
    var upscale: CGFloat { self == .superResolution ? 1.5 : 1 }
}

/// How long-exposure frames are combined.
enum StackBlend: String, Codable, CaseIterable, Identifiable {
    /// Mean of all frames: less noise, stars stay points (astro, night scenes).
    case average
    /// Brightest pixel wins: light and star trails.
    case lighten
    var id: String { rawValue }
    var label: String { self == .average ? "Estrelas (média)" : "Rastros de luz" }
}

enum PreviewLayout: String, Codable {
    /// Vertical tile on top, horizontal tile below.
    case split
    /// One format fills the screen, the other floats as a small draggable window.
    case pip
}

enum VideoCodecChoice: String, CaseIterable, Codable, Identifiable {
    case hevc, h264, prores
    var id: String { rawValue }
    var label: String {
        switch self {
        case .hevc: return "HEVC (H.265)"
        case .h264: return "H.264"
        case .prores: return "ProRes 422"
        }
    }
}

enum BitrateQuality: String, CaseIterable, Codable, Identifiable {
    case standard, high, max
    var id: String { rawValue }
    var label: String {
        switch self {
        case .standard: return "Padrão"
        case .high: return "Alta"
        case .max: return "Máxima"
        }
    }
    /// Bits per pixel per frame for HEVC; H.264 uses 1.6x.
    var bitsPerPixel: Double {
        switch self {
        case .standard: return 0.10
        case .high: return 0.16
        case .max: return 0.26
        }
    }
}

enum StabilizationChoice: String, CaseIterable, Codable, Identifiable {
    case off, standard, cinematic, cinematicExtended, maximum
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Desligada"
        case .standard: return "Padrão"
        case .cinematic: return "Cinemática"
        case .cinematicExtended: return "Cinemática estendida"
        case .maximum: return "Máxima (iOS 18)"
        }
    }
}

enum LensChoice: String, CaseIterable, Codable, Identifiable {
    case ultraWide, wide, telephoto, front, auto
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ultraWide: return "Ultra-angular"
        case .wide: return "Grande-angular"
        case .telephoto: return "Teleobjetiva"
        case .front: return "Frontal"
        case .auto: return "Troca automática (virtual)"
        }
    }
}

struct CaptureConfig: Codable, Equatable {
    var mode: CaptureMode = .video
    var outputs: [OutputKind] = [.vertical, .horizontal]
    var verticalResolution: OutputResolution = .hd
    var horizontalResolution: OutputResolution = .hd
    var fullResolution: OutputResolution = .native
    var fps: Int = 30
    var dynamicRange: DynamicRange = .sdr
    var rawPhoto = false
    var photoProcessing: PhotoProcessing = .apple
    var longExposureSeconds = 10
    var longExposureBlend: StackBlend = .average
    var longExposureInfinityFocus = true
    var codec: VideoCodecChoice = .hevc
    var quality: BitrateQuality = .high
    var stabilization: StabilizationChoice = .standard
    /// When the full-sensor mode can't stabilize (iPhone 13 Pro and others): false keeps the
    /// full 4032×3024 sensor (sharpest), true drops to the largest mode that does stabilize.
    var preferStabilization = false
    var lens: LensChoice = .wide
    /// `FormatInfo.id` of a sensor format chosen by hand, or nil for automatic.
    var formatOverride: String? = nil
    /// The interface rotates with the phone and files follow the way it is held.
    /// Off: everything stays upright-portrait.
    var followDeviceRotation = true
    var mirrorFront = true

    var layout: PreviewLayout = .split
    var pipPrimary: OutputKind = .vertical
    /// Front + back: the selfie camera is burned into the back-camera files as a movable window.
    var frontOverlay = false
    var overlay = OverlaySpec()
    var pipLarge = false

    var showGrid = false
    var showCrosshair = false
    var showLevel = true
    var showHistogram = false
    /// Diagonal stripes over areas about to clip.
    var zebra = false
    /// Colours in-focus edges.
    var focusPeaking = false
    var timerSeconds = 0
    var audioMeter = true
    var saveToPhotos = false
    var keepManualControls = false

    func resolution(for kind: OutputKind) -> OutputResolution {
        switch kind {
        case .vertical: return verticalResolution
        case .horizontal: return horizontalResolution
        case .full: return fullResolution
        }
    }

    mutating func setResolution(_ resolution: OutputResolution, for kind: OutputKind) {
        switch kind {
        case .vertical: verticalResolution = resolution
        case .horizontal: horizontalResolution = resolution
        case .full: fullResolution = resolution
        }
    }

    func isEnabled(_ kind: OutputKind) -> Bool { outputs.contains(kind) }

    /// The big format in the window layout: the one that matches how the phone is held,
    /// unless the user swapped them (stored as `pipPrimary == .horizontal`).
    func pipMain(landscape: Bool) -> OutputKind {
        let swapped = pipPrimary == .horizontal
        return swapped != landscape ? .horizontal : .vertical
    }

    mutating func setEnabled(_ kind: OutputKind, _ on: Bool) {
        var set = outputs.filter { $0 != kind }
        if on { set.append(kind) }
        outputs = OutputKind.allCases.filter(set.contains)
    }

    /// Smallest sensor width that feeds every enabled output without upscaling. Held upright, the
    /// 16:9 file's width is the sensor's *height*, so even HD wants the 4032×3024 format
    /// (1440 rows would be upscaled). Formats that can't reach the frame rate fall back to the largest that can.
    var requiredFormatWidth: Int {
        mode.isStill ? Int.max : 3840
    }

    /// Fields that require rebuilding the capture session when changed.
    var sessionKey: String {
        "\(frontOverlay && mode == .video)|\(mode.rawValue)|\(lens.rawValue)|\(requiredFormatWidth)|\(preferStabilization)|\(fps)|\(dynamicRange.rawValue)|\(stabilization.rawValue)|\(formatOverride ?? "-")"
    }

    static let storageKey = "captureConfig.v5"

    /// Saved values are laid over the defaults, so new settings added in an update don't wipe the old ones.
    static func load() -> CaptureConfig {
        let defaults = CaptureConfig()
        let store = UserDefaults.standard
        let current = store.data(forKey: storageKey)
        let previous = store.data(forKey: "captureConfig.v4")
        guard let saved = current ?? previous ?? store.data(forKey: "captureConfig.v3"),
              var savedObject = try? JSONSerialization.jsonObject(with: saved) as? [String: Any],
              let defaultData = try? JSONEncoder().encode(defaults),
              var merged = try? JSONSerialization.jsonObject(with: defaultData) as? [String: Any] else { return defaults }
        // Defaults that changed on purpose in an update are not carried over from older versions:
        // rotation (on since 1.4) and photo processing (Apple again since 1.5).
        if current == nil {
            if previous == nil { savedObject["followDeviceRotation"] = nil }
            savedObject["photoProcessing"] = nil
        }
        merged.merge(savedObject) { _, new in new }
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              let config = try? JSONDecoder().decode(CaptureConfig.self, from: mergedData) else { return defaults }
        return config
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

/// Everything the writer needs, frozen at the moment the record button is pressed.
struct PendingTake {
    let outputs: [OutputKind]
    let resolutions: [OutputKind: OutputResolution]
    let codec: VideoCodecChoice
    let quality: BitrateQuality
    let fps: Double
    let dynamicRange: DynamicRange
    /// Degrees that turn the delivered buffer upright (0 when the buffer is already upright).
    let rotationDegrees: Double
    let mirror: Bool
    /// Front + back: pixels are turned upright before encoding so the selfie window can be drawn in
    /// upright coordinates (files then carry no rotation transform).
    let bakeRotation: Bool
    let folder: URL
    let baseName: String
}

struct PhotoRequest {
    let outputs: [OutputKind]
    let rotationDegrees: Double
    let mirror: Bool
    let raw: Bool
    let folder: URL
    let baseName: String
}

struct BurstRequest {
    let photo: PhotoRequest
    let processing: PhotoProcessing
}

struct LongExposureRequest {
    let photo: PhotoRequest
    let seconds: Double
    let blend: StackBlend
}

struct TakeResult {
    let folder: URL?
    let urls: [URL]
    let droppedFrames: Int
    let error: String?
}
