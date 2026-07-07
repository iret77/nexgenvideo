import Foundation

/// Human copy for tool runs in the transcript. Raw tool names
/// (`mcp__nexgen__get_project_state`) are IT-speak — the row says what the agent
/// is DOING; the raw name stays available in the expanded detail. Unknown tools
/// fall back to the de-prefixed, de-snaked name.
enum ToolRunPresentation {

    static func label(for rawName: String) -> String {
        let name = stripped(rawName)
        if let known = labels[name] { return known }
        return name.replacingOccurrences(of: "_", with: " ").capitalizedFirst
    }

    /// The tool's base name regardless of transport (`mcp__nexgen__show_blocks` and
    /// `show_blocks` are the same tool to the transcript).
    static func baseName(for rawName: String) -> String {
        stripped(rawName)
    }

    /// `mcp__<server>__<tool>` → `<tool>`
    private static func stripped(_ raw: String) -> String {
        guard raw.hasPrefix("mcp__") else { return raw }
        let rest = raw.dropFirst("mcp__".count)
        guard let sep = rest.range(of: "__") else { return String(rest) }
        return String(rest[sep.upperBound...])
    }

    private static let labels: [String: String] = [
        // Timeline & editing
        "get_timeline": "Reading the timeline",
        "inspect_timeline": "Inspecting the timeline",
        "add_clips": "Placing clips on the timeline",
        "insert_clips": "Inserting clips",
        "remove_clips": "Removing clips",
        "remove_tracks": "Removing tracks",
        "move_clips": "Moving clips",
        "set_clip_properties": "Adjusting clip properties",
        "set_keyframes": "Setting keyframes",
        "split_clip": "Splitting a clip",
        "ripple_delete_ranges": "Closing gaps in the cut",
        "remove_words": "Cutting words from speech",
        "sync_audio": "Syncing audio",
        "undo": "Undoing the last edit",
        "add_texts": "Adding titles",
        "add_captions": "Adding captions",
        "export_project": "Exporting the project",
        "apply_color": "Grading color",
        "inspect_color": "Inspecting color",
        "apply_effect": "Applying an effect",
        // Media library
        "get_media": "Reading the media library",
        "inspect_media": "Inspecting media",
        "search_media": "Searching media",
        "import_media": "Importing media",
        "get_transcript": "Reading the transcript",
        "list_folders": "Listing folders",
        "create_folder": "Creating a folder",
        "move_to_folder": "Organizing media",
        "rename_media": "Renaming media",
        "rename_folder": "Renaming a folder",
        "delete_media": "Deleting media",
        "delete_folder": "Deleting a folder",
        // Dialog & generation
        "show_dialog": "Asking for your direction",
        "show_blocks": "Preparing a report",
        "compile_prompt": "Compiling the prompt",
        "generate_video": "Generating video",
        "generate_image": "Generating an image",
        "generate_audio": "Generating audio",
        "upscale_media": "Upscaling media",
        "list_models": "Listing generation models",
        "resolve_model": "Choosing the right model",
        // Production pipeline
        "init_project": "Setting up the production pipeline",
        "get_project_state": "Checking the production state",
        "list_phases": "Reading the phase plan",
        "get_ui_contract": "Reading the phase's interaction plan",
        "run_phase": "Running a pipeline phase",
        "approve_gate": "Approving the phase gate",
        "set_gate_state": "Updating the phase gate",
        "rewind": "Rewinding the pipeline",
        "get_bible": "Reading the Bible",
        "run_sanity": "Running consistency checks",
        "estimate_cost": "Estimating cost",
        "show_artifact": "Preparing an artifact view",
        "next_render_shot": "Picking the next shot to render",
        "record_render": "Recording a render",
        "get_render_manifest": "Reading the render manifest",
        "get_ledger": "Reading the intent ledger",
        "set_ledger_attribute": "Recording creative intent",
        "lock_ledger_attribute": "Locking creative intent",
        "remove_ledger_attribute": "Removing a ledger entry",
        "send_feedback": "Sending feedback",
        // Claude Code runtime built-ins
        "ToolSearch": "Loading tools",
        "Task": "Delegating a subtask",
        "Bash": "Running a command",
        "Read": "Reading a file",
        "Write": "Writing a file",
        "Edit": "Editing a file",
        "Glob": "Finding files",
        "Grep": "Searching files",
        "WebSearch": "Searching the web",
        "WebFetch": "Fetching a page",
        "TodoWrite": "Planning steps",
    ]
}

private extension String {
    var capitalizedFirst: String {
        guard let first = first else { return self }
        return first.uppercased() + dropFirst()
    }
}
