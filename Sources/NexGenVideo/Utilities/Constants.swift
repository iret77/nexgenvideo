import Foundation

enum LayoutPreset: String, CaseIterable {
    case `default`
    case media
    case vertical

    var label: String {
        switch self {
        case .default: "Default"
        case .media: "Media"
        case .vertical: "Vertical"
        }
    }

    var icon: String {
        switch self {
        case .default: "rectangle.split.3x1"
        case .media: "sidebar.left"
        case .vertical: "sidebar.right"
        }
    }
}

enum Defaults {
    static let pixelsPerFrame: Double = 4.0
    static let imageDurationSeconds: Double = 5.0
    static let audioTTSDurationSeconds: Double = 10.0
    static let audioMusicDurationSeconds: Double = 60.0
    static let textDurationSeconds: Double = 3.0
    static let aspectTolerance: Double = 0.02
}

enum Snap {
    static let thresholdPixels: Double = 8.0
    static let stickyMultiplier: Double = 1.5
    static let playheadMultiplier: Double = 1.5
}

enum Zoom {
    static let min: Double = 0.05
    static let floor: Double = 0.0001
    static let max: Double = 40.0
    static let toolbarStepFactor: Double = 1.25
    static let scrollSensitivity: Double = 0.04
    static let magnifySensitivity: Double = 1.5 
    static let panSpeed: Double = 5.0
    static let fitAllBuffer: Double = 3.0
}

enum TimelineAutoScroll {
    static let edgeZoneWidth: CGFloat = 56
    static let maxZoneFraction: CGFloat = 0.5
    static let minStep: CGFloat = 4
    static let maxStep: CGFloat = 28
    static let interval: TimeInterval = 1.0 / 60.0
}

enum Project {
    static let fileExtension = "ngv"
    static let registryFilename = "project-registry.json"
    static let typeIdentifier = "de.h5ventures.nexgenvideo.project"
    static let defaultProjectName = "Untitled Project"
    static let timelineFilename = "project.json"
    static let manifestFilename = "media.json"
    static let generationLogFilename = "generation-log.json"
    static let thumbnailFilename = "thumbnail.jpg"
    static let mediaDirectoryName = "media"

    /// UserDefaults key backing the user-chosen projects folder (Settings → Storage).
    static let projectsFolderKey = "projectsFolder"

    /// Where new projects are created. User-configurable in Settings → Storage; the
    /// ~/Documents/NexGenVideo path is only the fallback until the user picks their own location.
    static var storageDirectory: URL {
        if let custom = UserDefaults.standard.string(forKey: projectsFolderKey), !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/NexGenVideo", isDirectory: true)
    }

    nonisolated static func ensureStorageDirectory() {
        let url = storageDirectory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

func gcd(_ a: Int, _ b: Int) -> Int {
    b == 0 ? a : gcd(b, a % b)
}
