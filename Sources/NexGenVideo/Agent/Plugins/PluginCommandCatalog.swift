import Foundation
import NexGenEngine

// Read-only catalog of native format packs and their agent-panel starters, built for the launcher UI
// so a user can kick off a pack's workflow with one tap. The native successor to the disk
// `commands/*.md` scan: a pack's starters (plain-language instructions, not slash-commands) come from
// its `PackStarter` list on the Swift `Pack` (see PackCatalog / MusicvideoPack).
//
// A starter maps to a one-tap chip whose action sends the starter's `prompt` as ordinary agent text,
// so it works under either backend. Everything degrades gracefully: a pack with no starters just
// yields no commands.
enum PluginCommandCatalog {

    struct PluginInfo: Identifiable, Equatable {
        var id: String { name }
        /// The pack's `name`.
        let name: String
        /// The pack's display name.
        let description: String?
        let commands: [PluginCommand]
    }

    struct PluginCommand: Identifiable, Equatable {
        var id: String { command }
        /// The text sent to the agent when this starter is tapped (a plain instruction, not a slash
        /// command).
        let command: String
        /// Short chip label, e.g. "Start the music-video pipeline".
        let title: String
        /// Longer description, if any (unused for native starters — the title carries the meaning).
        let description: String?
        /// Native pack starters take no argument, so this is always nil.
        let argumentHint: String?

        /// A command needs user-supplied arguments before it can run.
        var requiresArgument: Bool {
            guard let hint = argumentHint?.trimmingCharacters(in: .whitespaces) else { return false }
            return !hint.isEmpty
        }
    }

    /// Every native pack with its starters, gallery order. Reuses `PackCatalog` (NexGenEngine) so the
    /// same first-party pack list drives the gallery and the launcher.
    static func discover() -> [PluginInfo] {
        PackCatalog.all.map { pack in
            PluginInfo(
                name: pack.name,
                description: pack.manifest.displayName,
                commands: pack.starters.map { starter in
                    PluginCommand(
                        command: starter.prompt,
                        title: starter.title,
                        description: nil,
                        argumentHint: nil
                    )
                }
            )
        }
    }
}
