import Foundation

/// One file produced by a take. All of them are cut from the same sensor frame.
enum OutputKind: String, CaseIterable, Codable, Identifiable {
    case vertical, horizontal, full

    var id: String { rawValue }

    var label: String {
        switch self {
        case .vertical: return "Vertical 9:16"
        case .horizontal: return "Horizontal 16:9"
        case .full: return "Sensor 4:3 (sem corte)"
        }
    }

    var shortLabel: String {
        switch self {
        case .vertical: return "9:16"
        case .horizontal: return "16:9"
        case .full: return "4:3"
        }
    }

    var fileSuffix: String {
        switch self {
        case .vertical: return "Vertical"
        case .horizontal: return "Horizontal"
        case .full: return "Sensor"
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
    /// Long side of each output in pixels. `nil` keeps the cropped sensor pixels unscaled.
    var longSide: Int? {
        switch self {
        case .hd: return 1920
        case .uhd: return 3840
        case .native: return nil
        }
    }
    /// Minimum sensor-format width that can feed this resolution without upscaling the horizontal file much.
    var minimumFormatWidth: Int {
        switch self {
        case .hd: return 1920
        case .uhd, .native: return 3840
        }
    }
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
    case off, standard, cinematic, cinematicExtended, auto
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Desligada"
        case .standard: return "Padrão"
        case .cinematic: return "Cinemática"
        case .cinematicExtended: return "Cinemática estendida"
        case .auto: return "Automática"
        }
    }
}

enum LensChoice: String, CaseIterable, Codable, Identifiable {
    case auto, wide, ultraWide, telephoto, front
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Automática (troca suave 0.5×–3×)"
        case .wide: return "Grande-angular 1× (física)"
        case .ultraWide: return "Ultra-angular 0.5× (física)"
        case .telephoto: return "Teleobjetiva (física)"
        case .front: return "Frontal"
        }
    }
}

struct CaptureConfig: Codable, Equatable {
    var outputs: [OutputKind] = [.vertical, .horizontal]
    var resolution: OutputResolution = .hd
    var fps: Int = 30
    var hdr: Bool = false
    var codec: VideoCodecChoice = .hevc
    var quality: BitrateQuality = .high
    var stabilization: StabilizationChoice = .standard
    var lens: LensChoice = .auto
    /// `FormatInfo.id` of a sensor format chosen by hand, or nil for automatic.
    var formatOverride: String? = nil

    var showGrid = true
    var showCrosshair = false
    var showLevel = true
    var showHistogram = true
    var showGuides = true
    var saveToPhotos = false

    /// Fields that require rebuilding the capture session when changed.
    var sessionKey: String {
        "\(lens.rawValue)|\(resolution.rawValue)|\(fps)|\(hdr)|\(stabilization.rawValue)|\(formatOverride ?? "-")"
    }

    static let storageKey = "captureConfig.v1"

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
    let resolution: OutputResolution
    let codec: VideoCodecChoice
    let quality: BitrateQuality
    let fps: Double
    let hdr: Bool
    /// Angle (degrees) that makes the unrotated sensor buffer upright for the way the phone is held.
    let rotationDegrees: Double
    let folder: URL
    let baseName: String
}

struct TakeResult {
    let folder: URL?
    let urls: [URL]
    let droppedFrames: Int
    let error: String?
}
