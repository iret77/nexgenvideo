import Foundation

/// Gate → artifact-formatter dispatch. Port of `nexgen_engine/show/dispatch.py`.
/// A gate with no formatter, or one whose artifact isn't written yet, yields a
/// plain "nothing yet" string rather than throwing — safe to call at any phase.
public enum ShowArtifact {
    /// Markdown for `gate`'s artifact, or a clear "nothing yet" string. Never
    /// throws for a missing artifact or unknown gate. Port of
    /// `show.dispatch.show_gate_artifact`.
    public static func gate(_ gate: String, dataRoot: URL) -> String {
        switch gate {
        case "brief":
            return normalizingMissing(gate) { try ShowFormatters.showBrief(dataRoot) }
        case "production_design":
            return ShowFormatters.showProductionDesign(dataRoot)
        case "treatment":
            return normalizingMissing(gate) { try ShowFormatters.showTreatment(dataRoot) }
        case "storyboard":
            return ShowFormatters.showStoryboard(dataRoot)
        case "bible":
            return ShowFormatters.showBible(dataRoot)
        case "shotlist":
            return ShowFormatters.showShotlist(dataRoot)
        case "analysis":
            return ShowFormatters.showAnalysis(dataRoot)
        case "render":
            return ShowFormatters.showRenders(dataRoot)
        default:
            return "_Gate `\(gate)` has no display artifact._"
        }
    }

    /// Mirrors the dispatcher's `except FileNotFoundError`: a formatter whose
    /// backing artifact is absent is normalized to the gate's "nothing yet"
    /// note. Only brief/treatment can surface this — the others return their own
    /// placeholder strings. A *malformed* artifact (not merely missing) surfaces
    /// a distinct note instead of masquerading as "nothing yet".
    private static func normalizingMissing(_ gate: String, _ body: () throws -> String) -> String {
        do {
            return try body()
        } catch is TreatmentStore.LoadError {
            return "_Nothing for gate `\(gate)` yet._"
        } catch YAMLCoding.Error.notFound {
            return "_Nothing for gate `\(gate)` yet._"
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return "_Nothing for gate `\(gate)` yet._"
        } catch {
            return "_Gate `\(gate)` artifact could not be read: \(type(of: error))._"
        }
    }
}
