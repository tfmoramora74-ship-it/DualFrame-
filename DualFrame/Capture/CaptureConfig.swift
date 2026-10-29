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
    case photo, video
    var id: String { rawValue }
    var label: String { self == .photo ? "Foto" : "Vídeo" }
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
    case off, standard, cinematic, cinematicExtended
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Desligada"
        case .standard: return "Padrão"
        case .cinematic: return "Cinemática"
        case .cinematicExtended: return "Cinemática estendida"
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
    var hdr: Bool = false
    var codec: VideoCodecChoice = .hevc
    var quality: BitrateQuality = .high
    var stabilization: StabilizationChoice = .standard
    var lens: LensChoice = .wide
    /// `FormatInfo.id` of a sensor format chosen by hand, or nil for automatic.
    var formatOverride: String? = nil
    var followDeviceRotation = false
    var mirrorFront = true

    var layout: PreviewLayout = .split
    var pipPrimary: OutputKind = .vertical

    var showGrid = false
    var showCrosshair = false
    var showLevel = true
    var showHistogram = false
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

    mutating func setEnabled(_ kind: OutputKind, _ on: Bool) {
        var set = outputs.filter { $0 != kind }
        if on { set.append(kind) }
        outputs = OutputKind.allCases.filter(set.contains)
    }

    /// Smallest sensor width that feeds every enabled output without upscaling. Held upright, the
    /// 16:9 file's width is the sensor's *height*, so even HD wants the 4032×3024 format
    /// (1440 rows would be upscaled). Formats that can't reach the frame rate fall back to the largest that can.
    var requiredFormatWidth: Int {
        mode == .photo ? Int.max : 3840
    }

    /// Fields that require rebuilding the capture session when changed.
    var sessionKey: String {
        "\(mode.rawValue)|\(lens.rawValue)|\(requiredFormatWidth)|\(fps)|\(hdr)|\(stabilization.rawValue)|\(formatOverride ?? "-")"
    }

    static let storageKey = "captureConfig.v2"

    static func load() -> CaptureConfig {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let cfg = try? JSONDecoder().decode(CaptureConfig.self, from: data) else { return CaptureConfig() }
        return cfg
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
    let hdr: Bool
    /// Degrees that turn the delivered buffer upright (0 when the buffer is already upright).
    let rotationDegrees: Double
    let mirror: Bool
    let folder: URL
    let baseName: String
}

struct PhotoRequest {
    let outputs: [OutputKind]
    let rotationDegrees: Double
    let mirror: Bool
    let folder: URL
    let baseName: String
}

struct TakeResult {
    let folder: URL?
    let urls: [URL]
    let droppedFrames: Int
    let error: String?
}
