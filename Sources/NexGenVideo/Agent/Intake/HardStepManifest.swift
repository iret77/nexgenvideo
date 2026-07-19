import Foundation
import NexGenEngine

/// One piece of material a phase must have collected before the agent works on it.
///
/// Hard steps are DATA a pack ships in its bundle (`hardsteps.json`), never a `Pack` protocol
/// requirement: a pack built against an older protocol has no witness-table entry for a new method
/// and jumps to 0x0 at call time (#251). Data can't crash a host that doesn't understand it.
struct HardStep: Equatable, Sendable, Identifiable {

    /// The intake kinds `AgentService.submitDialog` already routes deterministically. A step naming
    /// anything else is dropped at decode time — a newer pack degrades, never crashes an older host.
    enum Kind: String, Sendable, CaseIterable {
        case script, character, location, style, song, lyrics
    }

    let id: String
    let phase: String
    let kind: Kind
    /// `AgentDialog.FileIntake.accept` tokens ("audio", "image", "text", or bare extensions).
    let accept: [String]
    let multiple: Bool
    /// true ⇒ the phase can't proceed without it; false ⇒ offered once, skippable.
    let required: Bool
    /// Ask again after each answer until the user says they're done — one identity per dialog.
    let repeatable: Bool
    let title: String
    let intro: String?
    let prompt: String?
    let namePrompt: String?
    let addAnotherLabel: String?
    let symbol: String
    let confirmLabel: String
    let textField: AgentDialog.DialogTextField?

    /// The `attachAs` token handed to `submitDialog`.
    var attachAs: String { kind.rawValue }
}

/// A pack's hard steps, grouped by phase and kept in declaration order.
struct HardStepManifest: Sendable, Equatable {

    /// Filename inside the pack's resource dir, alongside `phases/`.
    static let resourceName = "hardsteps.json"

    private let byPhase: [String: [HardStep]]

    init(steps: [HardStep]) {
        var grouped: [String: [HardStep]] = [:]
        for step in steps { grouped[step.phase, default: []].append(step) }
        byPhase = grouped
    }

    static let empty = HardStepManifest(steps: [])

    var isEmpty: Bool { byPhase.isEmpty }

    func steps(for phase: String) -> [HardStep] { byPhase[phase] ?? [] }

    var allSteps: [HardStep] { byPhase.values.flatMap { $0 } }

    // MARK: - Decoding

    static func decode(_ data: Data) throws -> HardStepManifest {
        let file = try JSONDecoder().decode(File.self, from: data)
        return HardStepManifest(steps: file.phases.compactMap(\.value).flatMap { phase in
            phase.steps.compactMap(\.value).compactMap { $0.step(phase: phase.phase) }
        })
    }

    /// Read the manifest out of a pack's resource dir. A pack without one, or with an unreadable or
    /// malformed one, yields nil — the pipeline then runs exactly as it did before hard steps existed.
    static func load(packResourceDir: URL) -> HardStepManifest? {
        let url = packResourceDir.appendingPathComponent(resourceName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decode(data)
    }

    /// The manifest of the pack active for this project. Located from the INSTALLED bundle the loader
    /// recorded — the host already knows where every pack lives, so nothing crosses the host↔pack
    /// binary boundary for this (a protocol member would; see #251).
    ///
    /// The badge URL is only a fallback for a pack whose bundle the loader has no record of. It used to
    /// be the sole route, which made a pack shipping without a badge lose its MANDATORY intake in
    /// silence — the exact failure class this feature exists to end.
    @MainActor
    static func load(pack: Pack) -> HardStepManifest? {
        if let bundleURL = PluginLoader.installed.first(where: { $0.id == pack.name })?.bundleURL,
           let found = load(inBundle: bundleURL) {
            return found
        }
        if let badge = pack.manifest.badgeURL,
           let found = load(packResourceDir: badge.deletingLastPathComponent()) {
            return found
        }
        Log.project.notice("pack \(pack.name) ships no hard-step manifest — intake stays agent-driven")
        return nil
    }

    /// Search a `.ngvpack` for the manifest. The pack's resources sit in a SwiftPM resource bundle
    /// nested inside `Contents/Resources`, whose name depends on the pack's target — so look one level
    /// down rather than hard-coding it.
    private static func load(inBundle bundleURL: URL) -> HardStepManifest? {
        let resources = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        if let direct = load(packResourceDir: resources) { return direct }
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: resources, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            if let found = load(packResourceDir: entry) { return found }
            // One more level: the pack's own resource dir inside the SwiftPM bundle.
            let nested = (try? fm.contentsOfDirectory(
                at: entry, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for child in nested {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                      let found = load(packResourceDir: child) else { continue }
                return found
            }
        }
        return nil
    }

    // MARK: - Wire format

    /// Decodes an element to nil instead of failing the whole array — one malformed or
    /// forward-declared step must not cost the user every other step in the phase.
    private struct Lenient<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    private struct File: Decodable {
        let phases: [Lenient<Phase>]
    }

    private struct Phase: Decodable {
        let phase: String
        let steps: [Lenient<Step>]
    }

    private struct Step: Decodable {
        let id: String
        let attachAs: String
        let title: String
        var accept: [String]?
        var multiple: Bool?
        var required: Bool?
        var repeatable: Bool?
        var intro: String?
        var prompt: String?
        var namePrompt: String?
        var addAnotherLabel: String?
        var symbol: String?
        var confirmLabel: String?
        var textField: TextField?

        struct TextField: Decodable {
            let placeholder: String
            var multiline: Bool?
        }

        func step(phase: String) -> HardStep? {
            guard let kind = HardStep.Kind(rawValue: attachAs) else { return nil }
            return HardStep(
                id: id,
                phase: phase,
                kind: kind,
                accept: accept ?? [],
                multiple: multiple ?? false,
                required: required ?? false,
                repeatable: repeatable ?? false,
                title: title,
                intro: intro,
                prompt: prompt,
                namePrompt: namePrompt,
                addAnotherLabel: addAnotherLabel,
                symbol: symbol ?? "tray.and.arrow.down",
                confirmLabel: confirmLabel ?? "Continue",
                textField: textField.map {
                    AgentDialog.DialogTextField(placeholder: $0.placeholder, multiline: $0.multiline ?? false)
                }
            )
        }
    }
}
