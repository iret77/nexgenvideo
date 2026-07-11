import Foundation

/// User-facing labels for pipeline phase ids. Internal ids are snake_case (`project_init`) and must
/// never reach the UI as raw debug text. Core phases have curated, localizable labels; unknown ids
/// (e.g. future pack phases) fall back to a generic underscores→spaces title-case transform.
///
/// This is the single source of truth for phase display names — the title bar, the pipeline panel,
/// and any other surface route through here so wording (and, later, translations) stay consistent.
enum PhaseDisplay {
    static func label(_ id: String) -> String {
        switch id {
        case "project_init": String(localized: "phase.project_init", defaultValue: "Project Init", comment: "Pipeline phase")
        case "brief": String(localized: "phase.brief", defaultValue: "Brief", comment: "Pipeline phase")
        case "analysis": String(localized: "phase.analysis", defaultValue: "Audio Analysis", comment: "Pipeline phase")
        case "production_design": String(localized: "phase.production_design", defaultValue: "Production Design", comment: "Pipeline phase")
        case "treatment": String(localized: "phase.treatment", defaultValue: "Treatment", comment: "Pipeline phase")
        case "storyboard": String(localized: "phase.storyboard", defaultValue: "Storyboard", comment: "Pipeline phase")
        case "bible": String(localized: "phase.bible", defaultValue: "Bible", comment: "Pipeline phase")
        case "shotlist": String(localized: "phase.shotlist", defaultValue: "Shot List", comment: "Pipeline phase")
        case "sanity": String(localized: "phase.sanity", defaultValue: "Sanity Check", comment: "Pipeline phase")
        case "cover": String(localized: "phase.cover", defaultValue: "Cover", comment: "Pipeline phase")
        case "frames": String(localized: "phase.frames", defaultValue: "Frames", comment: "Pipeline phase")
        case "render": String(localized: "phase.render", defaultValue: "Render", comment: "Pipeline phase")
        default: id.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
