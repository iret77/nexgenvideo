import AppKit
import NexGenEngine

/// App-facing view of a native format pack — the successor to the former disk-discovered
/// plugin model. The gallery, title-bar chip, and agent launcher read packs from here (via
/// `PackCatalog`, NexGenEngine) instead of scanning disk. Activation is unchanged: exactly one
/// active per project, persisted in `ngv.json`.
struct InstalledPack: Identifiable, Equatable {
    /// The pack's `name` — the `activePlugin` string persisted per project.
    let name: String
    let displayName: String
    let tagline: String?
    /// Bundled app-resource base name for the gallery header (nil → gradient fallback).
    let headerImageName: String?

    var id: String { name }

    init(_ pack: Pack) {
        self.name = pack.name
        self.displayName = pack.manifest.displayName
        self.tagline = pack.manifest.tagline.isEmpty ? nil : pack.manifest.tagline
        self.headerImageName = pack.manifest.headerImageName
    }

    /// Every first-party pack, gallery order.
    static var all: [InstalledPack] { PackCatalog.all.map(InstalledPack.init) }

    /// The pack whose `name` matches, or nil (generic workflow).
    static func named(_ name: String?) -> InstalledPack? {
        guard let name else { return nil }
        return all.first { $0.name == name }
    }

    /// The gallery header image, loaded from the app bundle's `Images/` — checks
    /// both the flat assembled-.app layout and the SwiftPM resource-bundle layout
    /// (same idiom as the welcome splash). nil → the gallery paints a gradient.
    func headerImage() -> NSImage? {
        guard let base = headerImageName, let root = Bundle.main.resourceURL else { return nil }
        let candidates = [
            root.appendingPathComponent("Images/\(base).png"),
            root.appendingPathComponent("NexGenVideo_NexGenVideo.bundle/Images/\(base).png"),
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            return NSImage(contentsOf: url)
        }
        return nil
    }
}
