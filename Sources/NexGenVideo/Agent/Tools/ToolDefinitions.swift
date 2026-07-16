import Foundation
import MCP
import NexGenEngine

enum ToolName: String, CaseIterable, Sendable {
    case getTimeline = "get_timeline"
    case getMedia = "get_media"
    case addClips = "add_clips"
    case insertClips = "insert_clips"
    case removeClips = "remove_clips"
    case removeTracks = "remove_tracks"
    case moveClips = "move_clips"
    case setClipProperties = "set_clip_properties"
    case setKeyframes = "set_keyframes"
    case splitClip = "split_clip"
    case rippleDeleteRanges = "ripple_delete_ranges"
    case removeWords = "remove_words"
    case syncAudio = "sync_audio"
    case undo = "undo"
    case addTexts = "add_texts"
    case addCaptions = "add_captions"
    case exportProject = "export_project"
    case showDialog = "show_dialog"
    case showBlocks = "show_blocks"
    case compilePrompt = "compile_prompt"
    case generateVideo = "generate_video"
    case generateImage = "generate_image"
    case generateAudio = "generate_audio"
    case upscaleMedia = "upscale_media"
    case importMedia = "import_media"
    case listModels = "list_models"
    case inspectMedia = "inspect_media"
    case getTranscript = "get_transcript"
    case inspectTimeline = "inspect_timeline"
    case searchMedia = "search_media"
    case applyColor = "apply_color"
    case applyEffect = "apply_effect"
    case inspectColor = "inspect_color"
    case listFolders = "list_folders"
    case createFolder = "create_folder"
    case moveToFolder = "move_to_folder"
    case renameMedia = "rename_media"
    case renameFolder = "rename_folder"
    case deleteMedia = "delete_media"
    case deleteFolder = "delete_folder"
    case sendFeedback = "send_feedback"
    // Production-pipeline (engine) tools — native as of M7, formerly the Python `engine` MCP.
    case getProjectState = "get_project_state"
    case listPhases = "list_phases"
    case getBible = "get_bible"
    case runSanity = "run_sanity"
    case initProject = "init_project"
    case approveGate = "approve_gate"
    case rewind = "rewind"
    case estimateCost = "estimate_cost"
    case showArtifact = "show_artifact"
    case runPhase = "run_phase"
    case suggestPatterns = "suggest_patterns"
    case recordAffect = "record_affect"
    case getPattern = "get_pattern"
    case attachSong = "attach_song"
    case nextRenderShot = "next_render_shot"
    case recordRender = "record_render"
    case getRenderManifest = "get_render_manifest"
    case saveFrameAudit = "save_frame_audit"
    case getFrameAudit = "get_frame_audit"
    case cropToAspect = "crop_to_aspect"
    case extractScene3dPovs = "extract_scene3d_povs"
    case assembleTimeline = "assemble_timeline"
    case getLedger = "get_ledger"
    case setLedgerAttribute = "set_ledger_attribute"
    case lockLedgerAttribute = "lock_ledger_attribute"
    case removeLedgerAttribute = "remove_ledger_attribute"
    case resolveModel = "resolve_model"
    case getUIContract = "get_ui_contract"
    case setGateState = "set_gate_state"
    case runProviderTool = "run_provider_tool"
    case listProjectFiles = "list_project_files"
    case copyProjectFile = "copy_project_file"

    /// Tools that write the pipeline data root (not the timeline, which is undo-tracked and already
    /// marks the document edited). After one of these the working copy diverges from the saved package,
    /// so the document must be marked edited to prompt a save.
    var isPipelineWrite: Bool {
        switch self {
        case .initProject, .approveGate, .rewind, .runPhase, .recordRender, .recordAffect, .saveFrameAudit,
             .setLedgerAttribute, .lockLedgerAttribute, .removeLedgerAttribute, .setGateState,
             .attachSong, .copyProjectFile, .extractScene3dPovs:
            return true
        default:
            return false
        }
    }
}

struct AgentTool: @unchecked Sendable {
    let name: ToolName
    let description: String
    let inputSchema: [String: Any]
}

enum ToolDefinitions {
    static let all: [AgentTool] = [
        AgentTool(
            name: .getTimeline,
            description: "Always call at the start of a session. Returns project settings (fps, resolution, totalFrames), track list with types and order, and all clips with their frames and properties. The clipId/trackId values here are what every other tool accepts.\n\nClip and track fields equal to their defaults are omitted: mediaType 'video', sourceClipType = mediaType, speed 1, volume 1, opacity 1, trims/fades 0, identity transform/crop, default textStyle, track muted/hidden false. Text clips never report trims (no source media).\n\nCaption clips (sharing a captionGroupId) come back per track as captionGroups instead of clips entries: properties common to the group are hoisted into 'shared' and each clip is a [clipId, startFrame, durationFrames, text] row (caption box width/height are auto-fit per text and omitted). Rows are capped at 200 per group — when clipCount exceeds the rows shown, page with startFrame/endFrame. Caption clips whose properties deviate from the group appear individually in clips.",
            inputSchema: objectSchema(
                properties: [
                    "startFrame": ["type": "integer", "description": "Optional. Window start (inclusive); only clips intersecting [startFrame, endFrame) are returned. Tracks report totalClips when the window hides some."],
                    "endFrame": ["type": "integer", "description": "Optional. Window end (exclusive)."],
                ]
            )
        ),
        AgentTool(
            name: .showDialog,
            description: "Present a native structured dialog in the chat composer so the user shapes a step with clicks instead of prose — USE THIS instead of asking multi-option questions in text whenever a step has enumerable choices (styles, sections, modes, candidates). It renders as a self-contained FORM docked above the input (never a modal, never in the transcript); while it is open the chat composer is LOCKED, so the card is the one input surface. Keep each dialog a FOCUSED decision \u{2014} at most 3 sections; split a bigger decision into separate dialogs. For a choice set that isn't exhaustive, set the section's 'allowsCustom' so the user gets an 'Other\u{2026}' field instead of being boxed in. Declare a 'textField' when you need a free-text answer (multiline for lyrics/notes). When the step needs a LOCAL file FROM THE USER (a song, footage, a still), pass 'fileIntake' instead \u{2014} the card then shows a drop zone + a native file picker (no path typing), and the answer carries the chosen file as an @mentioned media asset you attach by id. After calling: STOP. The user's structured answer arrives as the next user message (\u{201C}Dialog \u{2026}\u{201D}); do not proceed with the step until then. Give every option a fitting SF Symbol; include costHint when the confirmed step will spend money.\n\nPROJECTION (when the choices ARE visual objects, show them where they live instead of describing them in prose): pass 'projection'. For choices that are TIMELINE RANGES (a section to trim, a moment to cut, a candidate span), put the spans in projection.timelineRanges (project frames, from get_timeline) and reference each from a choices option via 'rangeRef' \u{2014} the card stays compact and the ranges highlight on the timeline as labeled, clickable candidates; the user's click selects that choice. For choices about a SHOT's generated frames, set projection.reviewShot to the shot id \u{2014} the Review gallery opens focused on that shot. Only project real objects the user can see; keep prose options for abstract choices.",
            inputSchema: objectSchema(
                properties: [
                    "title": ["type": "string", "description": "Short imperative title, e.g. 'Shape the B-roll'."],
                    "symbol": ["type": "string", "description": "SF Symbol for the dialog, e.g. 'film'."],
                    "intro": ["type": "string", "description": "One short sentence of context (optional)."],
                    "costHint": ["type": "string", "description": "Approximate cost of the confirmed step, e.g. '\u{2248} \u{20AC}0.80'."],
                    "confirmLabel": ["type": "string", "description": "Confirm button label (default 'Continue')."],
                    "textField": [
                        "type": "object",
                        "description": "The dialog's single free-text field (optional). Declare it only when you need typed input beyond the choices \u{2014} e.g. lyrics to paste, or free notes. It renders inside the card (the composer is locked while the card is open).",
                        "properties": [
                            "placeholder": ["type": "string", "description": "Placeholder / label, e.g. 'Paste the lyrics here (optional)'."],
                            "multiline": ["type": "boolean", "description": "Tall multi-line field for longer text like lyrics. Default false (single line)."],
                        ],
                    ],
                    "fileIntake": [
                        "type": "object",
                        "description": "Turn this dialog into a FILE INTAKE: the card shows a drop zone + a native file picker instead of the free-text field, so the user drops or chooses the file(s) and never types a path. Each chosen file is imported as a media asset and returned to you as an @mentioned asset in the answer message \u{2014} attach it by id (e.g. attach_song media:<id>). Use whenever a step needs a LOCAL file FROM THE USER (a song, footage, a still). A dialog may carry ONLY a fileIntake (no sections), or combine it with sections (e.g. a cut-mode choice alongside the track). Optional.",
                        "properties": [
                            "accept": ["type": "array", "items": ["type": "string"], "description": "Accepted kinds ('audio', 'video', 'image', 'text') or bare file extensions ('mp3', 'wav', 'txt'). Empty \u{21D2} any file."],
                            "prompt": ["type": "string", "description": "Short line shown in the drop well, e.g. 'Drop your track or choose a file (.wav / .mp3 / .m4a / .aiff / .flac / .aac)'."],
                            "multiple": ["type": "boolean", "description": "Allow more than one file. Default false."],
                            "attachAs": ["type": "string", "description": "Where the file goes. Omit \u{21D2} the media library, returned as an @mention. 'song' \u{21D2} host places the audio straight into audio/ under the one-song contract (accept ['audio']) \u{2014} no separate attach_song step. 'lyrics' \u{21D2} host writes lyrics/lyrics.txt and replies with the parsed [Section] markers. 'script' \u{21D2} host writes import/script.md for a brownfield project (accept ['text'] for both). 'character'/'location' \u{2192} host copies the images into import/characters|locations/<slug>/ as a bible anchor (accept ['image'], set namePrompt, usually multiple:true). 'style' \u{2192} host copies loose mood/style reference images into import/ for the production-design agent (accept ['image'], multiple:true, no namePrompt)."],
                            "namePrompt": ["type": "string", "description": "For attachAs 'character'/'location': the label of a REQUIRED identity-name field the well shows (e.g. 'Character name'). The typed name becomes the destination folder; confirm stays disabled until it's filled."],
                            "required": ["type": "boolean", "description": "Whether a file/text is required to confirm. Default true; 'lyrics'/'script' default false (the user can confirm with nothing, an explicit skip the host reports to you). Set false to make any intake skippable via Confirm rather than only by dismissing."],
                        ],
                    ],
                    "sections": [
                        "type": "array",
                        "description": "At most 3 focused sections (more is rejected \u{2014} split into separate dialogs).",
                        "items": [
                            "type": "object",
                            "properties": [
                                "id": ["type": "string"],
                                "label": ["type": "string"],
                                "type": ["type": "string", "enum": ["choices", "toggle"]],
                                "multiSelect": ["type": "boolean"],
                                "allowsCustom": ["type": "boolean", "description": "choices sections only: also show an 'Other\u{2026}' free-text so the user isn't limited to the preset options. Set this whenever the option set isn't exhaustive."],
                                "defaultOn": ["type": "boolean", "description": "toggle sections only"],
                                "options": [
                                    "type": "array",
                                    "items": [
                                        "type": "object",
                                        "properties": [
                                            "id": ["type": "string"],
                                            "label": ["type": "string"],
                                            "symbol": ["type": "string", "description": "SF Symbol per option"],
                                            "rangeRef": ["type": "string", "description": "Id of a projection.timelineRanges entry this option represents. The option is then picked by clicking its highlighted range on the timeline; keep the label short (it becomes the range's chip)."],
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ],
                    "projection": [
                        "type": "object",
                        "description": "Canvas projection for choices that are visual objects (A3). Optional.",
                        "properties": [
                            "timelineRanges": [
                                "type": "array",
                                "description": "Candidate spans highlighted on the timeline; reference each from a choices option via rangeRef.",
                                "items": [
                                    "type": "object",
                                    "properties": [
                                        "id": ["type": "string", "description": "Stable id; a choices option points at it via rangeRef."],
                                        "label": ["type": "string", "description": "Short label drawn as a chip at the range start."],
                                        "startFrame": ["type": "integer", "description": "Range start (project frames, inclusive)."],
                                        "endFrame": ["type": "integer", "description": "Range end (project frames, exclusive; must be > startFrame)."],
                                    ],
                                    "required": ["startFrame", "endFrame"],
                                ],
                            ],
                            "reviewShot": ["type": "string", "description": "Shot id (e.g. 's012') to open in the Review gallery while this dialog is pending."],
                        ],
                    ],
                ],
                required: ["title"]
            )
        ),
        AgentTool(
            name: .showBlocks,
            description: "Present status, reports, and summaries as NATIVE UI in the transcript — headlines, badge rows, key-value boxes, callouts — instead of markdown walls. USE THIS whenever you report state (project status, brief fields, cost, phase results); plain chat text is for genuine conversation only and never gets rich rendering. Interaction stays with show_dialog — show_blocks displays, it never asks. Strictly validated: unknown block types, unknown keys, or empty required fields are rejected with the exact violation; fix and re-call.",
            inputSchema: objectSchema(
                properties: [
                    "blocks": [
                        "type": "array",
                        "minItems": 1,
                        "maxItems": AgentBlocks.maxBlocks,
                        "description": "1–\(AgentBlocks.maxBlocks) blocks, rendered top to bottom.",
                        "items": [
                            "type": "object",
                            "description": "Exactly one of: {type:'headline', text, symbol?} — section header, optional SF Symbol. {type:'text', body} — short prose/caption (markdown ok). {type:'status', badges:[{label, value, symbol?}]} — 1–\(AgentBlocks.maxBadges) compact badges (Mode, Budget, …). {type:'keyvalue', title?, rows:[[label, value], …]} — 1–\(AgentBlocks.maxRows) labeled rows in a box (brief fields etc.). {type:'callout', tone:'info'|'warn'|'success', text} — one emphasized note. No other keys.",
                        ],
                    ],
                ],
                required: ["blocks"]
            )
        ),
        AgentTool(
            name: .compilePrompt,
            description: "MANDATORY before any generate_* call: compiles user/agent intent into the final model prompt. NGV never sends raw prompts to content models — several cheap LLM turns are cheaper than one failed render. YOUR part of the contract before calling: translate the intent to English, resolve contradictions, and if essential information is missing (subject, style, format), ASK THE USER FIRST — never guess and spend money. The tool merges the project's locked ledger directives, enforces the model's prompt limits, and returns { compiledPrompt, compileToken, notes }. Pass compiledPrompt AND compileToken to the generate tool unchanged. shotId is REQUIRED and has no default: pass the shotlist shot id when compiling a shot (from next_render_shot), or the literal \"none\" when this prompt genuinely belongs to no shot (a cover, a bible sheet, a free request). A real shot id projects the shot's declared camera and framing into the prompt from the spec and runs the compliance drift check; \"none\" compiles free intent with neither. Choose deliberately — passing \"none\" for a shot silently throws away its camera projection and its drift check.",
            inputSchema: objectSchema(
                properties: [
                    "intent": ["type": "string", "description": "The prepared, English, contradiction-free generation intent."],
                    "model": ["type": "string", "description": "Target model id from list_models — limits and dialect are model-specific."],
                    "shotId": ["type": "string", "description": "REQUIRED. The shotlist shot being rendered (e.g. 's003'), or \"none\" when this prompt belongs to no shot. A shot id projects the shot's structured camera + framing into the prompt from the spec and runs the compliance drift linter; \"none\" does neither."],
                ],
                required: ["intent", "model", "shotId"]
            )
        ),
        AgentTool(
            name: .getMedia,
            description: "Call before referencing any asset. Every mediaRef/reference ID in other tools comes from the IDs returned here. Also exposes generationStatus (generating | downloading | rendering | failed | none) for async-generated and -imported assets — a failed entry additionally carries an 'error' message. An asset is only usable in add_clips once its generationStatus is 'none'; if it is 'failed', report the error to the user instead of retrying blindly.",
            inputSchema: objectSchema()
        ),
        AgentTool(
            name: .inspectMedia,
            description: "Look at a media asset before referencing or editing it. Images: the image plus dimensions and EXIF. Video: sample frames plus a transcription of the audio track. Audio: transcription. Lottie: frames sampled evenly across the animation (over gray), plus framerate and duration — use this to verify a Lottie you wrote looks and moves right. Transcription is sentence-level segments — [text, start, end] tuples, capped at 400 — in source seconds, or project frames when clipId is set. When capped, pass the returned nextStartSeconds as startSeconds for the next page.\n\nLong media: pass overview=true for a one-image storyboard, read the segments, then re-call with startSeconds/endSeconds to zoom — windowed calls only transcribe that span, so they are fast.",
            inputSchema: objectSchema(
                properties: [
                    "mediaRef": ["type": "string", "description": "Asset ID from get_media."],
                    "clipId": ["type": "string", "description": "Optional. A clip referencing this mediaRef; transcript times come back as project frames for that clip (out-of-range entries dropped)."],
                    "maxFrames": ["type": "integer", "description": "Video and Lottie. Sample frame count (default 6, max 12)."],
                    "startSeconds": ["type": "number", "description": "Video/audio. Source-time window start; scopes frames and transcription."],
                    "endSeconds": ["type": "number", "description": "Video/audio. Window end (default: asset duration)."],
                    "wordTimestamps": ["type": "boolean", "description": "Video/audio. Add word-level [text, start, end] tuples (capped at 10000 — most clips return all words at once; narrow with startSeconds/endSeconds only for very long media). Use for word-boundary edits like filler-word removal."],
                    "overview": ["type": "boolean", "description": "Video only. One storyboard grid of visually distinct, timestamped moments instead of frames — far more coverage per token; few tiles means static footage. maxFrames ignored."],
                ],
                required: ["mediaRef"]
            )
        ),
        AgentTool(
            name: .getTranscript,
            description: "Returns the spoken transcript of the CURRENT timeline in project frames — the post-edit caption track in one call. Unlike inspect_media (which transcribes one source asset in isolation, in source seconds), this walks every audio/video clip on the timeline, maps each word through that clip's trim/speed/position, and concatenates in timeline order. Deleted ranges are gone by construction, so after cuts this always reflects what's actually audible — no stale results, no per-clip frame math.\n\nReturns clips in timeline order, each with its words nested as compact [index, text, startFrame, endFrame] rows (the field order is given once in wordFormat) — clipId and trackIndex are stated once per clip, not repeated per word. The index is a stable, global, 0-based position in timeline order; pass it straight to remove_words to cut that word (the intuitive path for text-based editing). Words are monotonic and non-overlapping; each is attributed to one clip, so a word split across a clip seam is emitted once. Indices stay global even when scoped with clipId or paged with a window. Capped at 10000 words total; page with startFrame/endFrame using nextStartFrame. Pass clipId to scope to a single clip (\"what does this clip say?\"). Transcription runs on-device.\n\nUse for transcript-driven edits (filler-word / dead-air removal, locating a quote, take selection) and to verify what remains after cutting. To cut, prefer remove_words (give it the indices); drop to ripple_delete_ranges only for non-word-aligned spans.",
            inputSchema: objectSchema(
                properties: [
                    "startFrame": ["type": "integer", "description": "Optional. Only return words ending after this project frame. Use with the returned nextStartFrame to page a long timeline."],
                    "endFrame": ["type": "integer", "description": "Optional. Only return words starting before this project frame."],
                    "clipId": ["type": "string", "description": "Scope the transcript to a single clip — returns only what that clip says, in project frames. Answers \"what's in clip X?\" without scanning the whole timeline."],
                ]
            )
        ),
        AgentTool(
            name: .inspectTimeline,
            description: "See the composited timeline — what the user actually sees in the preview at a given frame: all video tracks stacked with their transforms, opacity, crop, and keyframes applied, plus text and caption overlays baked in. Use this to verify your edits landed (a PIP's position, a title's placement, layer order) — inspect_media shows the raw source asset, not the cut.\n\nFrames are project frames (from get_timeline). Pass a single startFrame for one composited frame; add endFrame to sample maxFrames evenly across [startFrame, endFrame) for a transition or sequence. Frames past content render black. Returns frames downscaled for token efficiency, with the frameNumbers sampled.",
            inputSchema: objectSchema(
                properties: [
                    "startFrame": ["type": "integer", "description": "Project frame to render (default 0). With no endFrame, a single frame is returned."],
                    "endFrame": ["type": "integer", "description": "Optional. Sample maxFrames evenly across [startFrame, endFrame) instead of one frame."],
                    "maxFrames": ["type": "integer", "description": "Frames to sample when endFrame is set (default 6, max 12)."],
                ]
            )
        ),
        AgentTool(
            name: .searchMedia,
            description: "Search the media library by content: what's on screen (visual) and what's said (spoken). Visual matching is semantic and on-device — phrase the query like an image caption ('a wide shot of a harbor at sunset'), not keywords; covers videos and stills. Spoken matching layers exact keywords over on-device semantic matching of transcript segments — quote the words said, or paraphrase them; transcripts are created automatically while indexing (and by inspect_media and add_captions), so coverage grows as indexing completes. The two groups rank independently and are never blended. Scores are uncalibrated — use them for ordering only.\n\nHits are source-second ranges. To place exactly that moment, multiply by fps and pass as trimStartFrame/trimEndFrame with a matching durationFrames to add_clips or set_clip_properties. Image hits have no time range.\n\nstatus reports the visual index: ready | indexing | modelNotInstalled | downloadingModel | preparing | disabled | failed. When not ready, moments may be empty or incomplete (compare indexedAssets to indexableAssets) — report that instead of concluding the footage doesn't exist, and don't poll in a loop. Spoken results work regardless of status.",
            inputSchema: objectSchema(
                properties: [
                    "query": ["type": "string", "description": "What to find. Visual: a caption-style scene description. Spoken: the words to match."],
                    "scope": ["type": "string", "enum": ["visual", "spoken", "both"], "description": "Optional. Default both."],
                    "mediaRef": ["type": "string", "description": "Optional. Restrict the search to one asset from get_media."],
                    "limit": ["type": "integer", "description": "Optional. Max hits per group (default 10, max 50)."],
                ],
                required: ["query"]
            )
        ),
        AgentTool(
            name: .addClips,
            description: "Places one or more media assets on the timeline as a single undoable action. Each entry's asset type must be compatible with its target track (video/image are interchangeable across video/image tracks; audio requires an audio track). When a video asset with audio is placed on a video track, a linked audio clip is automatically created on an audio track (an existing one if available, otherwise a new one). The whole batch is one undo step.\n\ntrackIndex is optional. Omit it on all entries and the tool auto-creates the needed tracks — one shared video track for visual entries and one shared audio track for audio entries (matches the captioning pattern in add_texts). To target existing tracks, set trackIndex on every entry. Mixing (some entries specify, others omit) is rejected — split into two calls.\n\nTracks work as layers: clips on the SAME track are sequential — if a new clip's range overlaps an existing clip on that track, the existing clip is trimmed/split/removed to make room, matching the UI's drag-onto-track overwrite behavior.",
            inputSchema: objectSchema(
                properties: [
                    "entries": [
                        "type": "array",
                        "description": "Clips to add. Each entry is validated up front; one bad entry rejects the whole call with no partial state.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "mediaRef": ["type": "string", "description": "ID of the media asset from get_media"],
                                "trackIndex": ["type": "integer", "description": "Optional. Track index (0-based). Omit on every entry to auto-create one shared track per asset zone (video/audio)."],
                                "startFrame": ["type": "integer", "description": "Timeline frame position to place the clip (project frames)."],
                                "durationFrames": ["type": "integer", "description": "Clip length on the timeline, in project frames."],
                                "trimStartFrame": ["type": "integer", "description": "Optional. Frames skipped from the START of the source media before the clip begins — a SOURCE offset, NOT a timeline position, but measured in PROJECT frames (the timeline's fps, same units as startFrame/durationFrames — never the source's own fps). 0 (default) starts at the source's first frame. Set this to trim on placement instead of a follow-up set_clip_properties call; semantics are identical to set_clip_properties."],
                                "trimEndFrame": ["type": "integer", "description": "Optional. Frames trimmed off the END of the source media, in PROJECT frames — same units as trimStartFrame. 0 (default) trims nothing off the end."],
                            ],
                            "required": ["mediaRef", "startFrame", "durationFrames"],
                        ],
                    ],
                ],
                required: ["entries"]
            )
        ),
        AgentTool(
            name: .insertClips,
            description: "Inserts one or more media assets at a single point and RIPPLES: every clip at or after atFrame is pushed right to open a gap, so nothing is overwritten. This is the non-destructive counterpart to add_clips (which clears the landing region, trimming/splitting/removing whatever's there). Use insert_clips to splice footage in without losing existing clips; use add_clips to fill empty space or deliberately overwrite.\n\nEntries are laid end-to-end starting at atFrame on the target track (entry[0] at atFrame, entry[1] immediately after, ...). The push equals the sum of the entries' durations and is applied to the target track, every sync-locked track, AND the audio track any auto-created linked audio lands on — so a clip and its linked audio stay aligned. As in add_clips, a video asset with audio spawns a linked audio clip. One undoable action; one bad entry rejects the whole call with no partial state.\n\ntrackIndex is required — ripple needs an existing track to push. For placement into empty space, use add_clips.",
            inputSchema: objectSchema(
                properties: [
                    "trackIndex": ["type": "integer", "description": "Track index (0-based, from get_timeline) to insert into and ripple."],
                    "atFrame": ["type": "integer", "description": "Timeline frame (project frames) where insertion begins. Every clip at or after this frame on rippled tracks shifts right by the total inserted duration."],
                    "entries": [
                        "type": "array",
                        "description": "Clips to insert, placed sequentially from atFrame. Validated up front; one bad entry rejects the whole call.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "mediaRef": ["type": "string", "description": "ID of the media asset from get_media."],
                                "durationFrames": ["type": "integer", "description": "Optional. Timeline length in project frames. Omit to use the asset's full source duration."],
                                "trimStartFrame": ["type": "integer", "description": "Optional. Frames skipped from the START of the source media — a SOURCE offset in PROJECT frames (same units as atFrame/durationFrames, never the source's own fps). 0 (default) starts at the source's first frame."],
                                "trimEndFrame": ["type": "integer", "description": "Optional. Frames trimmed off the END of the source media, in PROJECT frames. 0 (default) trims nothing."],
                            ],
                            "required": ["mediaRef"],
                        ],
                    ],
                ],
                required: ["trackIndex", "atFrame", "entries"]
            )
        ),
        AgentTool(
            name: .removeClips,
            description: "Removes one or more clips by ID as a single undoable action. Any clip that belongs to a link group (e.g. a video with its paired audio) takes its whole group with it, matching the UI's linked-delete behavior.",
            inputSchema: objectSchema(
                properties: [
                    "clipIds": [
                        "type": "array",
                        "description": "Clip IDs to remove.",
                        "items": ["type": "string"],
                    ],
                ],
                required: ["clipIds"]
            )
        ),
        AgentTool(
            name: .removeTracks,
            description: "Removes whole tracks and every clip on them in one undoable action. Linked partners on OTHER tracks are not removed. Remaining track indexes shift down after removal.",
            inputSchema: objectSchema(
                properties: [
                    "trackIndexes": [
                        "type": "array",
                        "items": ["type": "integer"],
                        "description": "Track indexes (0-based, from get_timeline) to remove.",
                    ],
                ],
                required: ["trackIndexes"]
            )
        ),
        AgentTool(
            name: .moveClips,
            description: "Moves one or more clips to a new track and/or frame position. Single undoable action. Each move specifies the clip ID and at least one of toTrack (must be compatible with the clip's media type) and toFrame. Overlap on the destination is resolved as in add_clips (existing clips on the destination track are trimmed/split/removed). Linked partners follow the named clip: startFrame propagates as a delta to preserve l-cut / j-cut offsets; tracks stay with the named clip.",
            inputSchema: objectSchema(
                properties: [
                    "moves": [
                        "type": "array",
                        "description": "Per-clip move requests. At least one of toTrack or toFrame is required per entry.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "clipId": ["type": "string", "description": "The clip ID to move."],
                                "toTrack": ["type": "integer", "description": "Destination track index (0-based). Omit to keep the clip on its current track."],
                                "toFrame": ["type": "integer", "description": "Destination start frame. Omit to keep the clip at its current start."],
                            ],
                            "required": ["clipId"],
                        ],
                    ],
                ],
                required: ["moves"]
            )
        ),
        AgentTool(
            name: .setClipProperties,
            description: "Apply the same property values to one or more clips in a single undoable action. Pass any combination of durationFrames, trimStartFrame, trimEndFrame, speed, volume, opacity, transform, or — for text clips only — content, fontName, fontSize, color, alignment. All values are applied to every clip in clipIds; for per-clip differences, make separate calls. trimStartFrame/trimEndFrame are offsets from the source media, not the timeline. speed 1.0 is normal, <1.0 slows (clip gets longer on the timeline), >1.0 speeds up. volume and opacity are 0.0–1.0. transform uses 0–1 normalized canvas coords, partial merge (pass only centerY to reposition vertically); flipHorizontal/flipVertical mirror the clip across the corresponding axis (no effect on text clips). When a text clip's content or font changes without an explicit transform, the bounding box auto-refits. Text-only fields with any non-text clip in clipIds are rejected.\n\nFor moves and start-frame changes, use move_clips. For animated values (keyframes), use set_keyframes — setting volume or opacity here clears any existing keyframe track on that property.\n\nTiming changes (durationFrames, trimStartFrame, trimEndFrame, speed) on a linked clip carry over to its linked partner so audio/video stay in sync — same as the timeline UI. Per-clip fields (volume, opacity, transform, text*) don't propagate. trim and speed are skipped for text partners.",
            inputSchema: objectSchema(
                properties: [
                    "clipIds": [
                        "type": "array",
                        "description": "Clip IDs to update. The property values below apply to every clip in this list.",
                        "items": ["type": "string"],
                    ],
                    "durationFrames": ["type": "integer", "description": "New duration in frames."],
                    "trimStartFrame": ["type": "integer", "description": "SOURCE-media offset, NOT a timeline frame: frames trimmed off the start of the source — measured in PROJECT frames (the timeline's fps, same units as startFrame/durationFrames; never the source's own fps). To turn a get_transcript project frame P into this clip's source offset, use trimStartFrame + (P − startFrame) × speed; setting trimStartFrame to that value makes the clip begin at P's source content."],
                    "trimEndFrame": ["type": "integer", "description": "SOURCE-media offset, NOT a timeline frame: frames trimmed off the end of the source, in PROJECT frames. Maps the same way as trimStartFrame via startFrame/speed."],
                    "speed": ["type": "number", "description": "Playback speed multiplier (default 1.0). >1 speeds up, <1 slows down. The clip's timeline length is rescaled to keep the same source content (2x speed → half the frames), unless you also pass durationFrames to set the length explicitly."],
                    "volume": ["type": "number", "description": "Volume 0.0-1.0. Clears any existing volume keyframes."],
                    "opacity": ["type": "number", "description": "Opacity 0.0-1.0. Clears any existing opacity keyframes."],
                    "transform": [
                        "type": "object",
                        "description": "Partial transform. Any combination of centerX, centerY, width, height, flipHorizontal, flipVertical; omitted fields keep their current value.",
                        "properties": [
                            "centerX": ["type": "number"],
                            "centerY": ["type": "number"],
                            "width": ["type": "number"],
                            "height": ["type": "number"],
                            "flipHorizontal": ["type": "boolean", "description": "Mirror across the vertical axis."],
                            "flipVertical": ["type": "boolean", "description": "Mirror across the horizontal axis."],
                        ],
                    ],
                    "content": ["type": "string", "description": "Text clips only. New text content."],
                    "fontName": ["type": "string", "description": "Text clips only. Font PostScript or family name."],
                    "fontSize": ["type": "number", "description": "Text clips only. Font size in canvas points."],
                    "color": ["type": "string", "description": "Text clips only. Hex '#RRGGBB' or '#RRGGBBAA'."],
                    "alignment": ["type": "string", "enum": ["left", "center", "right"], "description": "Text clips only."],
                ],
                required: ["clipIds"]
            )
        ),
        AgentTool(
            name: .setKeyframes,
            description: "Set animated keyframes on one property of one clip. Replaces the existing keyframe track for that property (pass an empty array to clear). Frames are CLIP-RELATIVE offsets (0 = first frame of the clip), so keyframes follow the clip when it moves. Rows are sorted by frame internally and the LAST row for any duplicate frame wins. Values must be finite numbers. Each row is `[frame, ...values, interp?]` where interp ∈ {linear, hold, smooth} (default smooth).\n\nProperties and their value layouts:\n  • volume `[frame, value]` — value 0.0–1.0\n  • opacity `[frame, value]` — value 0.0–1.0\n  • rotation `[frame, degrees]` — clockwise degrees\n  • position `[frame, topLeftX, topLeftY]` — TOP-LEFT corner in 0–1 normalized canvas coords. NOT the center. (Default static transform centers a full-canvas clip, so top-left of the static is (0, 0); a centered half-size clip has top-left (0.25, 0.25).)\n  • scale `[frame, width, height]` — clip's normalized width and height in 0–1 canvas coords (1.0 = fills the canvas axis). NOT a scale factor.\n  • crop `[frame, top, right, bottom, left]` — side insets in 0–1 of the source media.\n\nMotion keyframes (position/scale/rotation) override the static `transform` value when active.",
            inputSchema: objectSchema(
                properties: [
                    "clipId": ["type": "string", "description": "The clip ID."],
                    "property": [
                        "type": "string",
                        "enum": ["volume", "opacity", "rotation", "position", "scale", "crop"],
                        "description": "Which property's keyframe track to set.",
                    ],
                    "keyframes": [
                        "type": "array",
                        "description": "Replacement keyframe rows. Empty array clears the track. Row shape depends on property — see tool description.",
                        "items": ["type": "array"],
                    ],
                ],
                required: ["clipId", "property", "keyframes"]
            )
        ),
        AgentTool(
            name: .splitClip,
            description: "Splits a clip into two at atFrame. The frame must be strictly between the clip's start and end — use get_timeline to confirm the range.",
            inputSchema: objectSchema(
                properties: [
                    "clipId": ["type": "string", "description": "The clip ID to split"],
                    "atFrame": ["type": "integer", "description": "Frame position to split at (must be between clip start and end)"],
                ],
                required: ["clipId", "atFrame"]
            )
        ),
        AgentTool(
            name: .rippleDeleteRanges,
            description: "Cuts one or more ranges out and closes the gaps in one undoable action — the fast path for filler-word/dead-air removal. Replaces hand-cranked split_clip → split_clip → remove_clips → move_clips loops: pass every range at once.\n\nTwo modes — pass exactly one of clipId or trackIndex:\n• trackIndex (preferred for transcript-driven cuts): ranges are PROJECT frames and may span any number of clips on that track. get_transcript returns a clips array with nested words in project frames — collect every cut across the whole timeline and pass them in ONE call, no per-clip splitting and no re-reading the timeline between cuts. units must be 'frames'.\n• clipId: ranges are cut within that single clip only, clamped to its visible span. Allows units 'seconds' (source-media seconds, e.g. inspect_media WITHOUT a clipId or search_media hits); 'frames' = project frames. Use when you already have one clip's per-word timestamps.\n\nOverlapping ranges merge. Linked audio/video partners of every touched clip are cut on the same span so A/V stays in sync. Remaining clips shift left to close every gap; sync-locked tracks shift along to preserve alignment (their content isn't cut). Refuses without changing anything if a sync-locked track can't absorb the shift (e.g. it would move past frame 0). Returns the anchor track's post-cut layout (clip ids/frames) so you don't need to re-read.",
            inputSchema: objectSchema(
                properties: [
                    "trackIndex": ["type": "integer", "description": "Cut project-frame ranges spanning every clip they cross on this track, in one call. From get_transcript's clips array. Mutually exclusive with clipId; requires units 'frames'."],
                    "clipId": ["type": "string", "description": "Cut ranges within this single clip only, clamped to its visible span. Mutually exclusive with trackIndex."],
                    "ranges": [
                        "type": "array",
                        "description": "Ranges to remove, each a [start, end] pair (end > start). In the unit given by 'units'.",
                        "items": ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2],
                    ],
                    "units": ["type": "string", "enum": ["seconds", "frames"], "description": "Interpretation of range values. 'frames' (default) = project/timeline frames, matching get_transcript and inspect_media-with-clipId. 'seconds' = source-media seconds (clipId mode only)."],
                ],
                required: ["ranges"]
            )
        ),
        AgentTool(
            name: .removeWords,
            description: "Cut speech by the word, Descript-style — the primary tool for text-based editing (filler words, flubbed sentences, dropped retakes, tightening a ramble). You name WHICH words to remove by their get_transcript index; this resolves them to frames, removes the surrounding pause so survivors don't end up double-spaced, merges adjacent removals, cuts linked A/V partners, and closes the gaps. You never deal in frame numbers — that's the whole point versus ripple_delete_ranges.\n\nWorkflow: call get_transcript, read it as prose, then pass the indices of the words to drop. Words across multiple clips on ONE track are handled in a single undoable action, and any linked A/V partner (e.g. the video paired with this audio) is cut automatically. Edit one track at a time: if your indices span multiple unlinked tracks (e.g. two separate mics), the call is refused — cut each track in its own call, or link the tracks into one unit first. After it runs, indices have shifted — re-read get_transcript before another remove_words.\n\nWhen to use which: remove_words for anything you can point at in the transcript; ripple_delete_ranges only for spans that aren't word-aligned (e.g. a visual-only dead-air gap). Verify reworded retakes and sub-frame seam fragments against the word list, not a summary.",
            inputSchema: objectSchema(
                properties: [
                    "words": [
                        "type": "array",
                        "description": "Words to remove, by their get_transcript index. Each element is either a single index (e.g. 42) or an inclusive [startIndex, endIndex] span (e.g. [12, 18] removes words 12 through 18). Mix freely: [3, [12, 18], 40]. Indices come from the current get_transcript; re-read after any edit.",
                        "items": ["type": ["integer", "array"]],
                    ],
                    "cutAggressiveness": [
                        "type": "string",
                        "enum": ["tight", "balanced", "loose"],
                        "description": "How much silence to leave between the words on either side of a cut. 'tight' butts them close (snappy, can feel clipped), 'balanced' (default) keeps a natural beat, 'loose' leaves more breathing room. The removed words' own frames always go regardless.",
                    ],
                ],
                required: ["words"]
            )
        ),
        AgentTool(
            name: .syncAudio,
            description: "Align one or more clips to a reference clip by cross-correlating audio and shifting targets on the timeline. referenceClipId stays put — use for dual-system sound (camera + external audio) or multicam. Returns offsetFrames and confidence (0–1) per target; refuses weak matches.",
            inputSchema: objectSchema(
                properties: [
                    "referenceClipId": ["type": "string", "description": "Clip the others align to. Stays put."],
                    "targetClipId": ["type": "string", "description": "Single clip to align. Use targetClipIds for several."],
                    "targetClipIds": ["type": "array", "items": ["type": "string"], "description": "Clips to align with the reference."],
                    "searchWindowSeconds": ["type": "number", "description": "Max ± offset to search in seconds (default 30)."],
                    "minConfidence": ["type": "number", "description": "Minimum correlation confidence 0–1 (default 0.5)."],
                ],
                required: ["referenceClipId"]
            )
        ),
        AgentTool(
            name: .undo,
            description: "Reverts the assistant's most recent timeline edit (a cut, move, trim, split, or clip/text/caption add) as one step. The recovery path when an edit went too far — e.g. a ripple_delete_ranges removed more than intended. Verify a cut first (get_transcript reflects the post-cut audio), then undo if it overshot, then retry with corrected ranges.\n\nUndoes only edits the assistant made this session, most-recent-first — it never touches the user's own manual edits, and refuses if the latest change wasn't the assistant's. After undoing, the timeline is restored to its state before that edit; the ids/frames the edit returned are no longer valid, so re-read with get_timeline or get_transcript if you'll edit again. Takes no arguments.",
            inputSchema: objectSchema()
        ),
        AgentTool(
            name: .addTexts,
            description: "Adds one or more text clips (titles, captions, lower-thirds) in a single undoable action. Text renders as an overlay on top of visual media. Transform uses 0–1 normalized canvas coords: (0.5,0.5) is center, (0.5,0.1) top-center, (0.5,0.9) bottom-center. Omit transform to center + auto-fit. Pass only centerX/centerY to reposition with auto-fit size (common for lower-thirds). Pass all four fields to override the box entirely. Colors are hex '#RRGGBB' or '#RRGGBBAA'.\n\ntrackIndex is optional. Omit it on all entries and the tool auto-creates one new video track at the top and places all text clips there — the common case for captions. To target existing tracks, set trackIndex on every entry (audio tracks rejected). Mixing (some entries specify, others omit) is rejected — split into two calls.\n\nTracks work as layers: clips on the SAME track are sequential — if a new clip's range overlaps an existing (or earlier-batch) clip on that track, the existing clip is trimmed/split/removed to make room, matching the UI's drag-onto-track overwrite behavior. To show multiple text clips at the same time (stacked titles, simultaneous labels), put each on a DIFFERENT trackIndex so they layer instead of trimming each other.\n\nFor captioning spoken audio, prefer add_captions — it transcribes and places styled caption clips in one call. Use add_texts only for bespoke text (titles, lower-thirds) or captioning a custom range by hand. Unknown fields are rejected.",
            inputSchema: objectSchema(
                properties: [
                    "entries": [
                        "type": "array",
                        "description": "Text clips to add. Each entry is independent.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "trackIndex": ["type": "integer", "description": "Optional. Track index (0-based) for an existing non-audio track. Omit on every entry to auto-create one new track for the batch."],
                                "startFrame": ["type": "integer", "description": "Frame position to place the clip"],
                                "durationFrames": ["type": "integer", "description": "Duration in frames (>= 1)"],
                                "content": ["type": "string", "description": "Text to display. Supports \\n for line breaks."],
                                "transform": [
                                    "type": "object",
                                    "description": "Optional position/size. Omit for center + auto-fit. Pass centerX+centerY only for a specific position with auto-fit size. Pass all four for full override.",
                                    "properties": [
                                        "centerX": ["type": "number", "description": "Horizontal center 0–1 (0=left edge, 1=right edge)"],
                                        "centerY": ["type": "number", "description": "Vertical center 0–1 (0=top, 1=bottom)"],
                                        "width": ["type": "number", "description": "Width 0–1 (optional; omit for auto-fit)"],
                                        "height": ["type": "number", "description": "Height 0–1 (optional; omit for auto-fit)"],
                                    ],
                                ],
                                "fontName": ["type": "string", "description": "Font PostScript or family name, e.g. 'Helvetica-Bold', 'Georgia-Bold'. Default 'Helvetica-Bold'. Falls back to bold system font if not found."],
                                "fontSize": ["type": "number", "description": "Font size in canvas points (default 96). On a 1080p canvas ~50 is a caption, ~120 is a title."],
                                "color": ["type": "string", "description": "Hex '#RRGGBB' or '#RRGGBBAA' (default '#FFFFFF')"],
                                "alignment": ["type": "string", "enum": ["left", "center", "right"], "description": "Text alignment (default 'center')"],
                            ],
                            "required": ["startFrame", "durationFrames", "content"],
                        ],
                    ],
                ],
                required: ["entries"]
            )
        ),
        AgentTool(
            name: .addCaptions,
            description: "Auto-caption spoken audio: transcribes on-device and places styled caption clips on a new track — the same pipeline as the editor's Captions tab. This is the reliable path for 'caption this'; prefer it over hand-placing add_texts from a transcript. Omit clipIds to auto-pick the track with the most speech; pass clipIds to caption specific clips (e.g. only the interview).",
            inputSchema: objectSchema(
                properties: [
                    "clipIds": ["type": "array", "items": ["type": "string"], "description": "Optional. Audio/video clips to caption. Omit to auto-detect the primary spoken track."],
                    "language": ["type": "string", "description": "Optional BCP-47 language of the speech (e.g. 'es', 'ja', 'en-GB'). Defaults to the system language — set this when the footage is in another language, or transcription will be garbage."],
                    "fontName": ["type": "string", "description": "Optional font PostScript or family name (default 'Helvetica-Bold'). Falls back to bold system font if not found."],
                    "fontSize": ["type": "number", "description": "Optional font size in canvas points (default 48)."],
                    "color": ["type": "string", "description": "Optional hex '#RRGGBB' or '#RRGGBBAA' (default white)."],
                    "centerX": ["type": "number", "description": "Optional horizontal center 0–1 (default 0.5)."],
                    "centerY": ["type": "number", "description": "Optional vertical center 0–1 (default 0.9, near the bottom)."],
                    "textCase": ["type": "string", "enum": ["auto", "upper", "lower"], "description": "Optional letter case (default auto)."],
                    "censorProfanity": ["type": "boolean", "description": "Optional. Mask profanity (default false)."],
                ]
            )
        ),
        AgentTool(
            name: .exportProject,
            description: "Exports from the current project using the same modes as the Export dialog. mode defaults to video. video renders H.264, H.265, or ProRes; xml writes timeline XML; nexgen writes a self-contained .nexgen project package. Omit outputPath to write a unique file to ~/Downloads. Existing direct outputPath files are overwritten by default to match the UI save flow; pass overwrite=false to refuse. video renders in the background and returns status=started with the destination path; the app posts a system notification on completion or failure, so do not expect a final result inline. xml and nexgen finish before returning and report their result inline.",
            inputSchema: objectSchema(
                properties: [
                    "mode": ["type": "string", "enum": ["video", "xml", "nexgen"], "description": "Optional. Default video."],
                    "codec": ["type": "string", "enum": ["H.264", "H.265", "ProRes"], "description": "Video mode only. Optional. Default H.264."],
                    "resolution": ["type": "string", "enum": ["720p", "1080p", "2K", "4K", "Match Timeline"], "description": "Video mode only. Optional. Default Match Timeline."],
                    "outputPath": ["type": "string", "description": "Optional. Absolute destination path. If omitted, a unique project-named file is written to ~/Downloads. If no extension is provided, the mode's extension is appended."],
                    "overwrite": ["type": "boolean", "description": "Optional. Default true, matching the UI save flow. false refuses when outputPath already exists."],
                ]
            )
        ),
        AgentTool(
            name: .generateVideo,
            description: "Starts an async AI video generation. Returns a placeholder asset ID immediately; generation runs in the background and the asset becomes usable in add_clips once ready. Costs real money and is not undoable. PROMPT GATE: 'prompt' must be the compiledPrompt returned by compile_prompt, passed together with its compileToken — never your own phrasing. Raw prompts (rawPrompt=true) work only when the user enabled the pro setting.",
            inputSchema: objectSchema(
                properties: [
                    "compileToken": ["type": "string", "description": "Token from compile_prompt proving 'prompt' is the compiled prompt. Required unless rawPrompt=true."],
                    "rawPrompt": ["type": "boolean", "description": "Pro escape hatch: send the prompt uncompiled. Only works when the user enabled Raw prompts in Settings."],
                    "prompt": ["type": "string", "description": "Text description of the video to generate"],
                    "name": ["type": "string", "description": "Display name for the asset in the media library. Defaults to first 30 chars of prompt."],
                    "model": ["type": "string", "description": "Model ID (e.g. 'veo3.1-fast'). Use list_models to see options. Defaults to first available model."],
                    "duration": ["type": "integer", "description": "Duration in seconds. Valid values depend on model."],
                    "aspectRatio": ["type": "string", "description": "Aspect ratio (e.g. '16:9', '9:16', '1:1')"],
                    "resolution": ["type": "string", "description": "Resolution (e.g. '720p', '1080p', '4k')"],
                    "startFrameMediaRef": ["type": "string", "description": "Media asset ID to use as the first frame (image-to-video)"],
                    "endFrameMediaRef": ["type": "string", "description": "Media asset ID to use as the last frame (supported by some models)"],
                    "sourceVideoMediaRef": ["type": "string", "description": "Media asset ID of a source video (required by video-to-video edit models; ignores duration/aspectRatio/resolution)"],
                    "sourceClipId": ["type": "string", "description": "Optional. Clip id (from get_timeline) referencing sourceVideoMediaRef. When set and the clip is trimmed, only the clip's visible range is sent to the model, not the full source — matches the UI's 'Use trimmed portion only'."],
                    "referenceImageMediaRefs": ["type": "array", "items": ["type": "string"], "description": "Media asset IDs of image references. Covers both reference-to-video generation (Seedance, Kling V3/O3 elements, Grok — refer as @Image1/@Element1 in prompt) and the single-image ref used by video-to-video edit models (Kling V3 Motion Control). See list_models maxReferenceImages for per-model cap."],
                    "referenceVideoMediaRefs": ["type": "array", "items": ["type": "string"], "description": "Media asset IDs of video references (Seedance only). Refer to them as @Video1, @Video2. See maxReferenceVideos and maxCombinedVideoRefSeconds."],
                    "referenceAudioMediaRefs": ["type": "array", "items": ["type": "string"], "description": "Media asset IDs of audio references (Seedance only). Refer to them as @Audio1, @Audio2. See maxReferenceAudios and maxCombinedAudioRefSeconds."],
                    "folderId": ["type": "string", "description": "Optional. Folder id (from list_folders or create_folder) to place the result in. Omit for the project root."],
                ],
                required: ["prompt"]
            )
        ),
        AgentTool(
            name: .generateImage,
            description: "Starts an async AI image generation. Returns a placeholder asset ID immediately; generation runs in the background. Costs real money and is not undoable.",
            inputSchema: objectSchema(
                properties: [
                    "compileToken": ["type": "string", "description": "Token from compile_prompt proving 'prompt' is the compiled prompt. Required unless rawPrompt=true."],
                    "rawPrompt": ["type": "boolean", "description": "Pro escape hatch: send the prompt uncompiled. Only works when the user enabled Raw prompts in Settings."],
                    "prompt": ["type": "string", "description": "Text description of the image to generate"],
                    "name": ["type": "string", "description": "Display name for the asset in the media library. Defaults to first 30 chars of prompt."],
                    "model": ["type": "string", "description": "Model ID (e.g. 'nano-banana-pro'). Use list_models to see options. Defaults to first available model."],
                    "aspectRatio": ["type": "string", "description": "Aspect ratio (e.g. '16:9', '9:16')"],
                    "resolution": ["type": "string", "description": "Resolution (e.g. '2K', '4K')"],
                    "quality": ["type": "string", "description": "Image quality (e.g. 'low', 'medium', 'high'). Only supported by some models — see list_models."],
                    "referenceMediaRefs": ["type": "array", "items": ["type": "string"], "description": "Media asset IDs to use as reference images"],
                    "folderId": ["type": "string", "description": "Optional. Folder id (from list_folders or create_folder) to place the result in. Omit for the project root."],
                ],
                required: ["prompt"]
            )
        ),
        AgentTool(
            name: .generateAudio,
            description: "Starts an async AI audio generation: text-to-speech, text-to-music, or video-to-music (scoring a video). Returns a placeholder asset ID immediately; the asset appears in get_media and becomes usable in add_clips once ready. TTS models (elevenlabs-tts-v3, gemini-3.1-flash-tts) convert the prompt into speech and accept a 'voice'. Music models (lyria3-pro, minimax-music-v2.6, elevenlabs-music, sonilo-v1.1-video-to-music) generate tracks from a prompt; include lyrics/tempo/vocal style in the prompt for Lyria 3 Pro, pass 'lyrics' for MiniMax vocals, or set 'instrumental' true when the selected model supports it. Video-to-audio models (inputs include 'video' — see list_models, e.g. sonilo-v1.1-video-to-music, mirelo-sfx-v1.5-video-to-audio) generate audio that matches a VIDEO: provide a timeline span via videoSourceStartFrame+videoSourceEndFrame (e.g. to score the timeline), or a video asset via videoSourceMediaRef; the prompt is then an optional style guide. PLACEMENT: when you pass a timeline span, the result is placed on the timeline automatically at that span (no add_clips needed); for a media-asset source or a plain text-to-speech/music result, the asset lands in the library and you place it with add_clips. Use list_models with type='audio' to see each model's 'inputs', category, and voices. Costs real money and is not undoable.",
            inputSchema: objectSchema(
                properties: [
                    "compileToken": ["type": "string", "description": "Token from compile_prompt proving 'prompt' is the compiled prompt. Required unless rawPrompt=true."],
                    "rawPrompt": ["type": "boolean", "description": "Pro escape hatch: send the prompt uncompiled. Only works when the user enabled Raw prompts in Settings."],
                    "prompt": ["type": "string", "description": "Required for TTS (the text to speak) and text-to-music (style/mood/genre; MiniMax needs ≥10 chars). For Lyria 3 Pro, include lyrics, tempo, language, and vocal style directly in the prompt. Optional style guide for video-to-music models."],
                    "name": ["type": "string", "description": "Display name for the asset in the media library. Defaults to first 30 chars of prompt."],
                    "model": ["type": "string", "description": "Model ID. Use list_models with type='audio' to see options and their 'inputs'. Defaults to the first model."],
                    "voice": ["type": "string", "description": "TTS only. Voice preset name. list_models shows voicesSample (first 3) + voiceCount; any voice supported by the model is accepted. Defaults to the model's defaultVoice. Ignored by music models."],
                    "lyrics": ["type": "string", "description": "MiniMax Music only. Lyrics with optional [Verse]/[Chorus] section tags. If omitted and instrumental=false, MiniMax auto-writes lyrics from the prompt."],
                    "styleInstructions": ["type": "string", "description": "Gemini TTS only. Optional delivery instructions (e.g. 'warm and slow', 'British accent')."],
                    "instrumental": ["type": "boolean", "description": "Music models only. true = no vocals when the selected model supports it. Defaults to false."],
                    "duration": ["type": "integer", "description": "Length in seconds. ElevenLabs Music: 3–600. Sonilo text-to-music: up to 600. For a video source, defaults to the span/clip length. Ignored by TTS, MiniMax, and Lyria 3 Pro."],
                    "videoSourceStartFrame": ["type": "integer", "description": "Video-to-audio models only. Start frame (timeline) of a span to render and score — pair with videoSourceEndFrame. Use get_timeline for frame numbers; for the whole timeline use 0 to the timeline's end frame."],
                    "videoSourceEndFrame": ["type": "integer", "description": "Video-to-audio models only. End frame (exclusive) of the span to score. Must be > videoSourceStartFrame."],
                    "videoSourceMediaRef": ["type": "string", "description": "Video-to-audio models only. Score this existing video asset instead of a timeline span. Mutually exclusive with the videoSource frames."],
                    "folderId": ["type": "string", "description": "Optional. Folder id (from list_folders or create_folder) to place the result in. Omit for the project root."],
                ],
                required: []
            )
        ),
        AgentTool(
            name: .upscaleMedia,
            description: "Upscales an existing video or image asset to higher resolution using an AI upscaler. Returns a placeholder asset ID immediately; the upscaled asset appears in get_media once ready. Use list_models with type='upscale' to pick a model that supports the asset's type. Costs real money and is not undoable.",
            inputSchema: objectSchema(
                properties: [
                    "mediaRef": ["type": "string", "description": "ID of the video or image asset to upscale"],
                    "model": ["type": "string", "description": "Upscaler model ID (e.g. 'bytedance-upscaler', 'seedvr-image-upscaler'). Defaults to the first model that supports the asset's type."],
                    "sourceClipId": ["type": "string", "description": "Optional. Video clip id (from get_timeline) referencing mediaRef. When set and the clip is trimmed, only the clip's visible range is upscaled, not the full source."],
                ],
                required: ["mediaRef"]
            )
        ),
        AgentTool(
            name: .importMedia,
            description: "Imports external media into the project's library — the bridge for assets coming from other MCP servers (stock libraries, music services, web search) or local files the user already has. The 'source' object must set exactly one of: url (HTTPS only — downloaded in the background, the dominant case; max 1 GB), path (absolute local file path — referenced in place; may also be a directory, which is imported recursively, mirroring its subfolder structure as media folders), or bytes (base64-encoded inline data — max ~15 MB of base64 ≈ 11 MB binary; use url/path for anything larger). For url, type is inferred from the URL path's file extension unless source.mimeType is set as an override (needed for signed URLs whose path has no usable extension). For bytes, source.mimeType is required.\n\nSupported types and extensions: video (mov, mp4, m4v), audio (mp3, wav, aac, m4a, aiff, aifc, flac), image (png, jpg, jpeg, tiff, heic). Anything else is rejected — the caller must transcode externally.\n\nReturns a placeholder asset id immediately; URL imports run in the background and the asset becomes usable in add_clips once ready (same async pattern as generate_*). Path and bytes imports finalize synchronously. Costs nothing.",
            inputSchema: objectSchema(
                properties: [
                    "source": [
                        "type": "object",
                        "description": "Exactly one of url, path, or bytes must be set. mimeType is required when bytes is set; for url it acts as a type-inference override.",
                        "properties": [
                            "url": ["type": "string", "description": "HTTPS URL. Pre-signed URLs are fine but must not expire mid-download."],
                            "path": ["type": "string", "description": "Absolute local file or directory path, readable by the NexGenVideo process. A directory is imported recursively — every openable file is pulled in and the folder structure is replicated as media folders."],
                            "bytes": ["type": "string", "description": "Base64-encoded media data. Prefer url or path for anything over ~10MB."],
                            "mimeType": ["type": "string", "description": "Required when bytes is set. Optional override for url when its path has no usable extension (e.g. signed URLs). Accepted: video/mp4, video/quicktime, audio/mpeg, audio/wav, audio/aac, audio/mp4, image/png, image/jpeg, image/tiff, image/heic."],
                        ],
                    ],
                    "name": ["type": "string", "description": "Display name in the library. Defaults to the filename derived from url/path, or 'Imported asset' for bytes."],
                    "folderId": ["type": "string", "description": "Optional. Folder id (from list_folders or create_folder) to place the result in. Omit for the project root."],
                ],
                required: ["source"]
            )
        ),
        AgentTool(
            name: .listFolders,
            description: "Lists every folder in the media panel as {id, name, parentFolderId}. Folders are nested (parentFolderId is nil for top-level). Use to find an existing folder by name before generating new media.",
            inputSchema: objectSchema()
        ),
        AgentTool(
            name: .createFolder,
            description: "Creates folders in the media panel. Pass either name/parentFolderId for one folder or entries for multiple folders, not both. Direct form returns one folder; entries returns { folders }. Undoable. Use to organize related generations (e.g. 'Hero shot variations'). Don't create folders for unrelated concepts.",
            inputSchema: objectSchema(
                properties: [
                    "name": ["type": "string", "description": "Folder name."],
                    "parentFolderId": ["type": "string", "description": "Optional parent folder id; omit for top level."],
                    "entries": [
                        "type": "array",
                        "description": "Folders to create in one undoable action.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "name": ["type": "string", "description": "Folder name."],
                                "parentFolderId": ["type": "string", "description": "Optional parent folder id; omit for top level."],
                            ],
                            "required": ["name"],
                        ],
                    ],
                ]
            )
        ),
        AgentTool(
            name: .moveToFolder,
            description: "Moves media assets to folders. Pass either assetIds/folderId for one destination or entries for multiple destinations, not both. Omit folderId to move to root. Undoable.",
            inputSchema: objectSchema(
                properties: [
                    "assetIds": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Media asset ids to move.",
                    ],
                    "folderId": ["type": "string", "description": "Destination folder id. Omit to move to the project root."],
                    "entries": [
                        "type": "array",
                        "description": "Move operations to apply in one undoable action. Each entry can target a different folder.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "assetIds": [
                                    "type": "array",
                                    "items": ["type": "string"],
                                    "description": "Media asset ids to move.",
                                ],
                                "folderId": ["type": "string", "description": "Destination folder id. Omit to move to the project root."],
                            ],
                            "required": ["assetIds"],
                        ],
                    ],
                ]
            )
        ),
        AgentTool(
            name: .renameMedia,
            description: "Renames media assets in the library. Pass either mediaRef/name for one asset or entries for multiple assets, not both. Undoable.",
            inputSchema: objectSchema(
                properties: [
                    "mediaRef": ["type": "string", "description": "Media asset id from get_media."],
                    "name": ["type": "string", "description": "New display name."],
                    "entries": [
                        "type": "array",
                        "description": "Media assets to rename in one undoable action.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "mediaRef": ["type": "string", "description": "Media asset id from get_media."],
                                "name": ["type": "string", "description": "New display name."],
                            ],
                            "required": ["mediaRef", "name"],
                        ],
                    ],
                ]
            )
        ),
        AgentTool(
            name: .renameFolder,
            description: "Renames folders in the media panel. Pass either folderId/name for one folder or entries for multiple folders, not both. Undoable.",
            inputSchema: objectSchema(
                properties: [
                    "folderId": ["type": "string", "description": "Folder id from list_folders."],
                    "name": ["type": "string", "description": "New folder name."],
                    "entries": [
                        "type": "array",
                        "description": "Folders to rename in one undoable action.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "folderId": ["type": "string", "description": "Folder id from list_folders."],
                                "name": ["type": "string", "description": "New folder name."],
                            ],
                            "required": ["folderId", "name"],
                        ],
                    ],
                ]
            )
        ),
        AgentTool(
            name: .deleteMedia,
            description: "Deletes media assets from the library. Any clips referencing them are removed from the timeline in the same undoable action.",
            inputSchema: objectSchema(
                properties: [
                    "assetIds": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Media asset ids to delete.",
                    ],
                ],
                required: ["assetIds"]
            )
        ),
        AgentTool(
            name: .deleteFolder,
            description: "Deletes folders and everything inside them (subfolders and assets). Clips referencing any deleted asset are removed from the timeline in the same undoable action.",
            inputSchema: objectSchema(
                properties: [
                    "folderIds": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Folder ids to delete.",
                    ],
                ],
                required: ["folderIds"]
            )
        ),
        AgentTool(
            name: .listModels,
            description: "Lists the AI models you can actually run right now, with their capabilities (durations, aspect ratios, resolutions, first/last frame support, reference support, voices/category for audio, upscaler speed). Always call before generate_video, generate_image, generate_audio, or upscale_media so the model you pick supports the constraints you need. The list is already filtered to USABLE models — an activated provider services each one and the user hasn't disabled it — so every returned model is runnable; pick from these only. Returns { models, loaded } and, when models is empty, a 'note': that means no provider is activated yet (or all are disabled) — recommend the user activate one in Settings → Providers rather than guessing a model. NGV, not you, chooses which provider runs the model.",
            inputSchema: objectSchema(
                properties: [
                    "type": ["type": "string", "enum": ["video", "image", "audio", "upscale"], "description": "Filter by type. Omit to list all models."],
                ]
            )
        ),
        AgentTool(
            name: .applyEffect,
            description: """
            Apply non-color effects (blur, sharpen, stylize, detail, key) to video/image clips as a live, \
            editable effect stack — the looks/FX path, distinct from apply_color (grading). MERGES: each effect \
            you pass is added or updated by type; effects you don't mention are left in place. Pass enabled:false \
            to bypass one without removing it, or list its type in `remove` to delete it. Out-of-range params are \
            clamped; params you omit keep their current (or default) value. Effects render in a fixed canonical \
            order regardless of the order you pass them. Undoable. Verify with inspect_timeline.

            Available effects — type: param (range, default):
            \(Self.effectCatalog())
            """,
            inputSchema: objectSchema(
                properties: [
                    "clipIds": ["type": "array", "items": ["type": "string"], "description": "Clip ids from get_timeline."],
                    "effects": [
                        "type": "array",
                        "description": "Effects to add or update on the clips.",
                        "items": objectSchema(
                            properties: [
                                "type": ["type": "string", "description": "Effect type id, e.g. stylize.glow (see list above)."],
                                "params": ["type": "object", "description": "Param values keyed by name. Out-of-range values are clamped; omitted params keep their current/default value."],
                                "enabled": ["type": "boolean", "description": "Default true. false bypasses the effect without removing it."],
                            ],
                            required: ["type"]
                        ),
                    ],
                    "remove": ["type": "array", "items": ["type": "string"], "description": "Effect type ids to remove from the clips."],
                ],
                required: ["clipIds"]
            )
        ),
        AgentTool(
            name: .applyColor,
            description: "Author/refine a color grade on video/image clips with named controls — the colorist path, distinct from apply_effect (looks/FX). MERGES with the clip's current grade: only the params you pass change, the rest are preserved, so you can nudge one knob at a time (pass reset:true to start from neutral). Applies as live, editable color.* effects; non-color effects untouched. Iterate: apply_color → inspect_color(clipId, reference) → read the gap → adjust → repeat. Undoable. All knobs optional. Color WHEELS use HUE (0–360°, standard) + AMOUNT per tonal zone — to push shadows teal, set shadowsHue 180 and shadowsAmount ~0.15. CURVES (master + per-channel R/G/B) give precise tone shaping — per-channel curves are tone-selective (e.g. pull the blue curve down in the highlights to tame a bright sky). HUE CURVES do secondary/qualified correction — target a source hue and shift its hue/saturation/lightness (e.g. desaturate greens, warm the skin) without a mask; pair with inspect_color's hueHistogram to find which hues are present. LUT applies a .cube film-look pack on top of the grade.",
            inputSchema: objectSchema(
                properties: [
                    "clipIds": ["type": "array", "items": ["type": "string"], "description": "Clip ids from get_timeline."],
                    "reset": ["type": "boolean", "description": "Start from neutral instead of merging onto the clip's current grade. Default false."],
                    "exposure": ["type": "number", "description": "-3…3 EV. Overall brightness in linear light."],
                    "contrast": ["type": "number", "description": "0.5…1.5 (1 = neutral)."],
                    "saturation": ["type": "number", "description": "0…2 (1 = neutral; <1 mutes)."],
                    "vibrance": ["type": "number", "description": "-1…1 (protects skin tones)."],
                    "temperature": ["type": "number", "description": "2000…11000 K. HIGHER = WARMER, lower = cooler/bluer (6500 = neutral)."],
                    "tint": ["type": "number", "description": "-100…100. Positive = green, negative = magenta."],
                    "highlights": ["type": "number", "description": "-1…1. Recover (<0) or lift (>0) highlights."],
                    "shadows": ["type": "number", "description": "-1…1. Lift (>0) or deepen (<0) shadows."],
                    "blacks": ["type": "number", "description": "-1…1. Black point. Negative deepens, positive lifts (faded look)."],
                    "whites": ["type": "number", "description": "-1…1. White point."],
                    "shadowsHue": ["type": "number", "description": "Shadow color-push hue 0–360° (0 red, 30 orange, 60 yellow, 120 green, 180 cyan, 240 blue, 300 magenta). Use with shadowsAmount."],
                    "shadowsAmount": ["type": "number", "description": "0…1 strength of the shadow color push (0 = neutral)."],
                    "shadowsLum": ["type": "number", "description": "-0.5…0.5 shadow lift (brightness)."],
                    "midsHue": ["type": "number", "description": "Midtone color-push hue 0–360° (see shadowsHue). Use with midsAmount."],
                    "midsAmount": ["type": "number", "description": "0…1 strength of the midtone color push."],
                    "midsGamma": ["type": "number", "description": "0.5…2 midtone brightness (gamma; 1 = neutral)."],
                    "highsHue": ["type": "number", "description": "Highlight color-push hue 0–360° (see shadowsHue). Use with highsAmount."],
                    "highsAmount": ["type": "number", "description": "0…1 strength of the highlight color push."],
                    "highsGain": ["type": "number", "description": "0.5…1.5 highlight brightness (gain; 1 = neutral)."],
                    "masterCurve": ["type": "array", "items": ["type": "array", "items": ["type": "number"]],
                                    "description": "Luma tone curve as [x,y] control points in 0–1 (input→output), preserves chroma. E.g. [[0,0.06],[1,0.95]] = lifted/faded film toe."],
                    "redCurve": ["type": "array", "items": ["type": "array", "items": ["type": "number"]],
                                 "description": "Red-channel tone curve, [x,y] points 0–1."],
                    "greenCurve": ["type": "array", "items": ["type": "array", "items": ["type": "number"]],
                                   "description": "Green-channel tone curve, [x,y] points 0–1."],
                    "blueCurve": ["type": "array", "items": ["type": "array", "items": ["type": "number"]],
                                  "description": "Blue-channel tone curve, [x,y] points 0–1. Tone-selective: e.g. [[0,0],[0.7,0.7],[1,0.85]] pulls blue only in the highlights (tames a sky) and leaves shadows."],
                    "hueCurves": [
                        "type": "object",
                        "description": "Secondary/qualified correction (Resolve-style Hue-vs-Hue/Sat/Lum). Targets replace any existing hue curve. Selectivity is ~±22° around each target hue.",
                        "properties": [
                            "targets": [
                                "type": "array",
                                "description": "One or more source-hue regions to adjust (e.g. skin at 30, sky at 210).",
                                "items": objectSchema(
                                    properties: [
                                        "targetHue": ["type": "number", "description": "Source hue to act on, 0–360° (0 red, 30 orange/skin, 60 yellow, 120 green, 180 cyan, 210 sky-blue, 240 blue, 300 magenta)."],
                                        "hueShift": ["type": "number", "description": "Rotate that hue by -30…30°."],
                                        "satScale": ["type": "number", "description": "Saturation multiplier for that hue, 0–2 (1 = neutral; 1.3 pops it, 0.6 mutes it, 0 fully desaturates)."],
                                        "lumShift": ["type": "number", "description": "Lightness shift for that hue, -0.5…0.5."],
                                    ],
                                    required: ["targetHue"]
                                ),
                            ],
                        ],
                    ],
                    "lut": [
                        "type": "object",
                        "description": "Apply a .cube 3D LUT (e.g. a film-look pack) on top of the primary grade; replaces any prior LUT. The agent does not author LUT data — pass a real file path.",
                        "properties": [
                            "path": ["type": "string", "description": "Absolute path to a .cube file (~ is expanded). Copied into project storage so it survives saves."],
                            "strength": ["type": "number", "description": "0–1 blend intensity. Default 1. Pass strength alone (no path) to re-blend the existing LUT."],
                        ],
                    ],
                ],
                required: ["clipIds"]
            )
        ),
        AgentTool(
            name: .inspectColor,
            description: "Measure color scopes of a timeline clip's current graded look (clipId) OR a raw media asset (mediaRef) — black/white points, % clipping, mean & per-channel levels, shadow/mid/highlight color tilt, saturation, warm-cool / green-magenta balance, and a saturation-weighted hueHistogram (12 bins of 30° from 0°/red — shows which hues are present, e.g. an orange cluster = skin, a cyan/blue cluster = sky) — and return the rendered frame too. Use this to grade by the numbers instead of eyeballing, to find hues to target with apply_color's hueCurves, or to measure footage/references before grading. clipId applies the clip's effects (graded look); mediaRef measures the raw asset. Pass a reference image/video id to also measure it and get the subject−reference GAP plus hints that map onto apply_color knobs. The loop: apply_color → inspect_color(clipId, reference) → read the gap → adjust → repeat until the gap is small.",
            inputSchema: objectSchema(
                properties: [
                    "clipId": ["type": "string", "description": "Timeline clip to measure — returns its current GRADED look (effects applied). Provide this or mediaRef."],
                    "mediaRef": ["type": "string", "description": "Media asset id from get_media to measure RAW (no grade). Provide this or clipId."],
                    "atFrame": ["type": "integer", "description": "Optional project frame to sample a clip. Defaults to the clip's midpoint. Ignored for mediaRef."],
                    "reference": ["type": "string", "description": "Optional image/video asset id from get_media to compare against; returns its scopes + the subject−reference gap."],
                ]
            )
        ),
        AgentTool(
            name: .sendFeedback,
            description: "Record an agent limitation or bug in the local diagnostics log so it can be reviewed later. Use when you can't do what the user asked because a capability or tool is missing or behaves wrong, the result is clearly off, or the user is plainly hitting a rough edge. This is recorded without a confirmation step — so PARAPHRASE in your own words: never include verbatim user messages, prompts, file paths, media, transcript text, or any project content. App/OS version and your recent tool names are attached automatically. Use sparingly: at most once per distinct issue.",
            inputSchema: objectSchema(
                properties: [
                    "category": ["type": "string", "enum": ["missing_capability", "wrong_result", "confusing_ux", "failure", "suggestion"], "description": "What kind of problem this is."],
                    "summary": ["type": "string", "description": "One-line paraphrased summary of the issue. Becomes the report's subject."],
                    "details": ["type": "string", "description": "Optional. Paraphrased explanation of what the user was trying to do and what went wrong or was missing. No verbatim content."],
                    "severity": ["type": "string", "enum": ["low", "medium", "high"], "description": "Optional. How much this blocked the user."],
                ],
                required: ["category", "summary"]
            )
        ),

        // MARK: - Production pipeline (engine) tools
        // Native as of M7. `project_dir` is the project's `pipeline/` data root; omit it and the tool
        // uses the open project. Arg names + return shapes match the former Python `engine` MCP.

        AgentTool(
            name: .getProjectState,
            description: "Where a project stands: meta, gate/phase status, next open phase. Read-only. `project_dir` is the project's data root (the `pipeline/` folder); omit to use the open project.",
            inputSchema: projectDirSchema()
        ),
        AgentTool(
            name: .listPhases,
            description: "The production pipeline phases, in order (engine core + active pack). `project_dir` is the `pipeline/` data root; omit to use the open project (its pack phases fold in when known).",
            inputSchema: projectDirSchema()
        ),
        AgentTool(
            name: .getBible,
            description: "The asset-graph Bible (characters, ensembles, props, locations, look) — the consistency reference for generation — or null if none yet. `project_dir` is the `pipeline/` data root; omit to use the open project.",
            inputSchema: projectDirSchema()
        ),
        AgentTool(
            name: .runSanity,
            description: "Run the full consistency audit for the project and return its findings.\n\nLoads the latest shotlist plus any brief/bible, runs every engine-core check AND every active-pack check, and returns `{project, findings:[{level, code, shot_id, message}]}`. If the project has no shotlist yet, returns `{\"error\": \"no shotlist\", ...}` instead of raising. Read-only. `project_dir` is the `pipeline/` data root; omit to use the open project.",
            inputSchema: projectDirSchema()
        ),
        AgentTool(
            name: .suggestPatterns,
            description: "Rank the pack's director/style patterns against the project using the frozen Pattern-fit contract (packs that ship a pattern library, e.g. musicvideo). The pack assembles a project profile from the persisted Brief — you only supply the song's perceived_bpm and, optionally, a match_mode and pattern ids to exclude. Returns a `PatternRecommendationSet`: each result carries a Compatibility Index (0–100, NOT a probability of success), its band, confidence, coverage, per-axis strengths/conflicts and triggered adaptations, plus best_overall/production_efficient/creative_stretch slots and up to three high-impact follow-up questions. If the library is not yet fully authored the tool returns `{available:false, …}` (a fail-closed gate, never a partial ranking). Use at the brief phase to pick a pattern, then set the chosen id as brief.director_pattern so PATTERN_DRIFT holds the shotlist to it. Read-only. Errors if the active pack ships no patterns.",
            inputSchema: objectSchema(
                properties: [
                    "perceived_bpm": ["type": "number", "description": "The song's perceived BPM (from analysis). Only 3% of total fit — omit if unknown."],
                    "match_mode": ["type": "string", "enum": ["conservative", "balanced", "experimental"], "description": "Conflict appetite (default balanced): conservative caps conflicted patterns hard, experimental lifts the cap."],
                    "excluded_pattern_ids": ["type": "array", "items": ["type": "string"], "description": "Pattern ids the user has ruled out — hard-excluded from the ranking."],
                    "top": ["type": "integer", "description": "How many results to return (default 5)."],
                    "project_dir": ["type": "string", "description": "Optional pipeline data root; omit to use the open project."],
                ]
            )
        ),
        AgentTool(
            name: .recordAffect,
            description: "Record the track's emotional register (affect) that YOU read from the audio analysis (BPM, key/mode, energy curve, section dynamics — already computed) plus the lyrics. This answers the pattern-fit `affect_energy` axis from the signal and the text, NOT from a keyword table — so do the reading yourself, don't match trigger words. `detected` is your automatic read; pass `override` ONLY to record a deliberate user correction, including a purposely contrary mood (a happy song cut dark) — a legitimate directing choice the detection can't anticipate. When you set an override, show the user 'detected X → set Y' so the choice stays legible. Call this once affect is knowable (after analysis, with lyrics if present) and before suggest_patterns, which consumes it. WRITES.",
            inputSchema: objectSchema(
                properties: [
                    "detected": [
                        "type": "array",
                        "minItems": 1,
                        "description": "Weighted affect tags you inferred from audio + lyrics. Weights need not sum to 1; they are relative.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "tag": ["type": "string", "enum": AffectTagVocabulary.all,
                                        "description": "One affect from the fixed vocabulary."],
                                "weight": ["type": "number", "description": "Relative strength of this affect (default 1)."],
                            ],
                            "required": ["tag"],
                        ],
                    ],
                    "override": [
                        "type": "array",
                        "description": "The user's deliberate override, same shape as detected. Omit unless the user corrected or deliberately contradicted the detection.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "tag": ["type": "string", "enum": AffectTagVocabulary.all],
                                "weight": ["type": "number"],
                            ],
                            "required": ["tag"],
                        ],
                    ],
                    "rationale": ["type": "string", "description": "One line on the audio + lyric evidence behind the read (kept for later legibility)."],
                    "basis": ["type": "string", "enum": ["measured", "documented", "inferred"], "description": "measured when the read leans on the DSP analysis, inferred when on lyrics/context (default inferred)."],
                    "project_dir": ["type": "string", "description": "Optional pipeline data root; omit to use the open project."],
                ],
                required: ["detected"]
            )
        ),
        AgentTool(
            name: .getPattern,
            description: "Load one director pattern by id (an id from suggest_patterns): its framing_mix, asl_range, camera vocabulary, lighting signature, section arc, references and (when authored) its fit_profile. Consume these directives when writing the storyboard/shotlist/bible so the plan follows the pattern. Read-only.",
            inputSchema: objectSchema(
                properties: [
                    "id": ["type": "string", "description": "Pattern id from suggest_patterns (e.g. anime-shinkai-emotional-landscape)."],
                    "project_dir": ["type": "string", "description": "Optional pipeline data root; omit to use the open project."],
                ],
                required: ["id"]
            )
        ),
        AgentTool(
            name: .initProject,
            description: "Scaffold a fresh project and return `{data_root, project, created}`. WRITES.\n\nCreates the `pipeline/` data root with the engine's format-neutral core subdirs PLUS the active pack's own subdirs (e.g. musicvideo adds audio/lyrics/analysis), and writes `project.yaml` (mode, budget) and `gates.yaml`. `mode` is one of beat/phrase/section/multicam. Omit `home_dir` to scaffold the open project (recommended); pass it only for out-of-band scaffolding. Fails if the target already holds a project.",
            inputSchema: objectSchema(
                properties: [
                    "home_dir": ["type": "string", "description": "Optional. Directory to scaffold under; omit to use the open project."],
                    "name": ["type": "string", "description": "Project name."],
                    "mode": ["type": "string", "description": "Cut mode: beat/phrase/section/multicam (default beat)."],
                    "budget_eur": ["type": "number", "description": "Project budget in EUR (default 50)."],
                ],
                required: ["name"]
            )
        ),
        AgentTool(
            name: .approveGate,
            description: "Approve a production gate so the next phase may run. WRITES.\n\nStamps `phase`'s gate approved (with optional `notes`) and returns the updated `{project, phase, approved, approved_at, approved_by, notes}`. `project_dir` is the `pipeline/` data root; omit to use the open project.",
            inputSchema: objectSchema(
                properties: [
                    "project_dir": projectDirProperty,
                    "phase": ["type": "string", "description": "The phase whose gate to approve."],
                    "notes": ["type": "string", "description": "Optional approval notes."],
                ],
                required: ["phase"]
            )
        ),
        AgentTool(
            name: .rewind,
            description: "Rewind the pipeline to `target_phase`. WRITES.\n\nResets `target_phase` and every following phase (in the merged core+pack phase order, so pack phases like `analysis` sit in the right place) to unapproved; artifacts are kept. Returns `{target, reset_phases}`. `project_dir` is the `pipeline/` data root; omit to use the open project.",
            inputSchema: objectSchema(
                properties: [
                    "project_dir": projectDirProperty,
                    "target_phase": ["type": "string", "description": "The phase to rewind to; it and all following phases reset."],
                ],
                required: ["target_phase"]
            )
        ),
        AgentTool(
            name: .estimateCost,
            description: "The project's budget picture. Read-only.\n\nSums EUR already spent across the render ledger and compares against the project budget, returning `{project, budget_eur, spent_eur, remaining_eur, over_budget, next_phase}`. This is the spent/remaining view (not a forward per-shot estimate). `project_dir` is the `pipeline/` data root; omit to use the open project.",
            inputSchema: projectDirSchema()
        ),
        AgentTool(
            name: .showArtifact,
            description: "The Markdown for a gate's artifact, for user review before approval. Read-only.\n\nDispatches `gate` (brief/production_design/treatment/storyboard/bible/shotlist/analysis/render) to its formatter and returns `{gate, markdown}`. A gate with no formatter, or one whose artifact isn't written yet, yields a clear \"nothing yet\" string instead of raising. `project_dir` is the `pipeline/` data root; omit to use the open project.",
            inputSchema: objectSchema(
                properties: [
                    "project_dir": projectDirProperty,
                    "gate": ["type": "string", "description": "Gate name to render (brief/production_design/treatment/storyboard/bible/shotlist/analysis/render)."],
                ],
                required: ["gate"]
            )
        ),
        AgentTool(
            name: .listProjectFiles,
            description: "List files under a project subdirectory. Read-only. Use this instead of a shell/Glob to see what the user brought in — e.g. `subdir: \"import\"` for style references, `subdir: \"import/characters/mouse\"` for a character's refs. Returns `{subdir, files}` (paths relative to the data root, recursive, sorted). `project_dir` is the `pipeline/` data root; omit to use the open project.",
            inputSchema: objectSchema(
                properties: [
                    "project_dir": projectDirProperty,
                    "subdir": ["type": "string", "description": "Data-root-relative directory to list, e.g. 'import' or 'import/characters/<id>'."],
                ],
                required: ["subdir"]
            )
        ),
        AgentTool(
            name: .copyProjectFile,
            description: "Copy a file from one project-relative path to another WITHIN the project (copy, never move). WRITES. Use this instead of a shell `cp` to stage references — e.g. from `import/characters/<id>/face.png` to `bible/refs/<id>/face.png`. Creates the destination directory. Both paths are data-root-relative and must stay inside the project. Returns `{from, to}`.",
            inputSchema: objectSchema(
                properties: [
                    "project_dir": projectDirProperty,
                    "from": ["type": "string", "description": "Source path, data-root-relative (e.g. 'import/characters/mouse/face.png')."],
                    "to": ["type": "string", "description": "Destination path, data-root-relative (e.g. 'bible/refs/mouse/face.png')."],
                ],
                required: ["from", "to"]
            )
        ),
        AgentTool(
            name: .runPhase,
            description: "Run a registered pipeline phase for the project. WRITES.\n\nDispatches to whatever phase runner the active pack registered under `phase` and runs it. For the musicvideo pack, `analysis` decodes the single song in the project's audio/ folder and runs the native audio analysis (beats, downbeats, tempo, structure), writing `analysis/<song>.json` — this takes a few seconds. The planning phases (brief/treatment/storyboard/…) are agent-driven and have no code runner; for those this returns `{phase, runner: null, note: ...}` rather than raising. A failure (no song, several songs, or a decode error) returns `{phase, error: \"phase_failed\", detail}` with an actionable message. On success returns `{phase, ok: true, result}` — for analysis, `result` summarizes bpm, duration_s, beats, downbeats, sections, and the artifact path. `project_dir` is the `pipeline/` data root; omit to use the open project.",
            inputSchema: objectSchema(
                properties: [
                    "project_dir": projectDirProperty,
                    "phase": ["type": "string", "description": "The phase to run."],
                ],
                required: ["phase"]
            )
        ),
        AgentTool(
            name: .attachSong,
            description: "Place the song into the project's audio/ folder so run_phase(\"analysis\") can decode it. WRITES.\n\nThe musicvideo pipeline keeps exactly ONE song in audio/, and the analysis runner reads it from there — import_media only reaches the media library, not audio/, so use this to bring the song in. Pass exactly one of `media` (a media-library asset id from get_media/search_media) or `path` (an absolute file path). The source must be an audio type the analysis runner accepts (.wav/.mp3/.m4a/.aiff/.flac/.aac); it's copied (the original is untouched). If a DIFFERENT audio file is already in audio/, this errors and names it — pass `replace: true` to first remove the existing audio and honor the one-song contract. Returns `{filename, audio_dir}`. Run run_phase(\"analysis\") next.",
            inputSchema: objectSchema(
                properties: [
                    "project_dir": projectDirProperty,
                    "media": ["type": "string", "description": "A media-library asset id (from get_media/search_media) whose file is copied into audio/. Mutually exclusive with `path`."],
                    "path": ["type": "string", "description": "An absolute path to the audio file to copy into audio/. Mutually exclusive with `media`."],
                    "replace": ["type": "boolean", "description": "Remove any existing audio in audio/ first (the one-song contract). Default false — a different existing song is an error otherwise."],
                ]
            )
        ),
        AgentTool(
            name: .nextRenderShot,
            description: "The next shot to render for `phase`, in shotlist order. Read-only.\n\nLoads the latest shotlist (for ordered shot IDs) and the phase's render manifest, then returns the first shot whose entry is missing or not yet `rendered`, with its `visual_prompt` and `framing` so the agent can drive nexgen's own generate_image/generate_video. Returns `{phase, shot_id: null, done: true}` once every shot is rendered (or when there's no shotlist). `project_dir` is the `pipeline/` data root; omit to use the open project.",
            inputSchema: objectSchema(
                properties: [
                    "project_dir": projectDirProperty,
                    "phase": ["type": "string", "description": "The render phase (e.g. preview/final)."],
                ],
                required: ["phase"]
            )
        ),
        AgentTool(
            name: .recordRender,
            description: "Record a shot's render result into the phase manifest. WRITES.\n\nUpserts `shot_id`'s entry (status, `output` path-or-URL, `cost_eur`) into `renders/manifest-<phase>.json`, stamps `updated_at`, and returns the saved entry plus the manifest's running `spent_eur`. `status` is one of rendered/pending/failed. `project_dir` is the `pipeline/` data root; omit to use the open project.",
            inputSchema: objectSchema(
                properties: [
                    "project_dir": projectDirProperty,
                    "phase": ["type": "string", "description": "The render phase."],
                    "shot_id": ["type": "string", "description": "The shot id to record."],
                    "output": ["type": "string", "description": "Path or URL of the rendered artifact (null if not done)."],
                    "cost_eur": ["type": "number", "description": "EUR spent on this render (default 0)."],
                    "status": ["type": "string", "description": "rendered/pending/failed (default rendered)."],
                ],
                required: ["phase", "shot_id"]
            )
        ),
        AgentTool(
            name: .getRenderManifest,
            description: "The phase's render manifest and its progress summary. Read-only.\n\nReturns `{project, phase, entries, summary}` where `entries` maps shot_id → its render record and `summary` is `{total, rendered, pending, failed, spent_eur}` (`total` from the latest shotlist's shot count). `project_dir` is the `pipeline/` data root; omit to use the open project.",
            inputSchema: objectSchema(
                properties: [
                    "project_dir": projectDirProperty,
                    "phase": ["type": "string", "description": "The render phase."],
                ],
                required: ["phase"]
            )
        ),
        AgentTool(
            name: .saveFrameAudit,
            description: "Record a vision-audit verdict for a rendered keyframe and get the routing decision. WRITES.\n\nCall this AFTER record_render for a keyframe and BEFORE surfacing it to the user: inspect the rendered image against the shot spec (framing, character count, gaze, blocking at t=0, forbidden elements, visible zones, proportion anchor) and report one status per audit point. The result's `verdict` routes deterministically — APPROVE (clean) → surface for approval; RERENDER (blocking, budget left) → apply `auto_rerender_patch` to a fresh compile+render, then re-audit; USER_DECIDES (minor, or blocking with budget spent) → surface the findings and let the user decide. Never exceed 2 auto re-renders per shot+role.\n\nYou judge; the machine measures. Supply only `status`/`observed`/`note` per check plus `overall`, `auditor`, and (when blocking) `auto_rerender_patch`. The executor fills `render_sha256`, `generated`, each `expected` (from the shot spec), and the `auto_rerender_attempt` counter — values you pass for those are ignored. All 10 standard check keys are required; extra keys are allowed. Strictly validated: `overall` must match the worst check status (a blocking check with a non-blocking overall is rejected), `pending` is never a valid end state — fix and re-call on any violation. `project_dir` is the `pipeline/` data root; omit to use the open project.",
            inputSchema: objectSchema(
                properties: [
                    "project_dir": projectDirProperty,
                    "shot_id": ["type": "string", "description": "The audited shot id."],
                    "role": ["type": "string", "enum": ["start", "end"], "description": "Keyframe role (default \"start\")."],
                    "auditor": ["type": "string", "description": "Who produced the audit, e.g. \"orchestrator-claude-opus-4.8\" or \"google-gemini-3-pro\"."],
                    "overall": [
                        "type": "string", "enum": ["clean", "minor", "blocking"],
                        "description": "Aggregate verdict — must match the worst check status.",
                    ],
                    "auto_rerender_patch": ["type": "string", "description": "STRICT/MUST/NOT correction instructions for the next re-render; set when overall=blocking."],
                    "path": ["type": "string", "description": "Explicit image path (project-home-relative or absolute) to audit — only needed when the frame isn't in the frames manifest yet."],
                    "checks": frameAuditChecksSchema,
                ],
                required: ["shot_id", "auditor", "overall", "checks"]
            )
        ),
        AgentTool(
            name: .getFrameAudit,
            description: "The stored vision-audit for a keyframe and its routing verdict. Read-only.\n\nReturns `{exists, shot_id, role, overall, verdict, has_blocking, has_minor, auto_rerender_attempt, attempts_left, auditor, render_sha256, render_path, auto_rerender_patch, checks}` — or `{exists:false}` when no audit was saved for that shot+role. Read the verdict here rather than recomputing routing policy. `project_dir` is the `pipeline/` data root; omit to use the open project.",
            inputSchema: objectSchema(
                properties: [
                    "project_dir": projectDirProperty,
                    "shot_id": ["type": "string", "description": "The shot id."],
                    "role": ["type": "string", "enum": ["start", "end"], "description": "Keyframe role (default \"start\")."],
                ],
                required: ["shot_id"]
            )
        ),
        AgentTool(
            name: .cropToAspect,
            description: "Deterministically crop a rendered/master frame to a target aspect (render-larger-then-crop). WRITES.\n\nComputes the largest box of the requested aspect that fits inside the source image and crops to it — exact, reproducible geometry (no model, no eyeballing), so an establishing frame the Bible master shows in full wide can be cut to the shot's delivery aspect without drift. Resolves the source from an explicit `path` (project-home-relative or absolute) or a `shot_id` (+`role`) recorded in the frames manifest. Writes the cropped PNG into the project's media library and imports it as a usable asset. Returns `{asset_id, output, aspect, anchor, target_size, box}`. `project_dir` is the `pipeline/` data root; omit to use the open project.",
            inputSchema: objectSchema(
                properties: [
                    "project_dir": projectDirProperty,
                    "aspect": ["type": "string", "description": "Target aspect as \"W:H\", e.g. \"16:9\" or \"9:16\"."],
                    "anchor": ["type": "string", "enum": ["center", "left", "right", "top", "bottom"], "description": "Which side to keep when cropping (default center)."],
                    "path": ["type": "string", "description": "Source image path (home-relative or absolute). Use this or shot_id."],
                    "shot_id": ["type": "string", "description": "Shot whose recorded frame to crop (resolved via the frames manifest). Use this or path."],
                    "role": ["type": "string", "enum": ["start", "end"], "description": "Keyframe role when using shot_id (default \"start\")."],
                ],
                required: ["aspect"]
            )
        ),
        AgentTool(
            name: .extractScene3dPovs,
            description: "Cut geometrically consistent camera views out of a location's 360\u{00B0} panorama. WRITES. Deterministic, local, free \u{2014} no model, no provider, no cost.\n\nThis is the spatial anchor for a location. Image models have no 3D understanding of a space: across shots they drift the layout, and they cannot honor the basic rule that what was on the left is on the right in the reverse shot. Every view cut here comes from the SAME equirectangular panorama, so the views are consistent with each other by construction \u{2014} opposite walls really are the same wall, and doors/furniture stay put across angles.\n\nUsage: first obtain a panorama for the location (generate with a `marble/` model from a style-neutral clay wide, so the 3D provider supplies GEOMETRY while the bible image model stays the style master). Then call this to cut the views. The output is style-neutral clay: restyle each view into the project's look with an image-edit model (preserve perspective, composition and exact positions 1:1 \u{2014} change only surfaces, lighting and color) before entering it as a Bible sheet.\n\nEach POV `name` becomes the `Location.sheets` key a shot's `locationView` then names. Default set: the four cardinal walls (wide_front / wide_right / wide_back / wide_left), 75\u{00B0} lens tilted 5\u{00B0} down, 1280\u{00D7}720. The panorama MUST be equirectangular (2:1); anything else is refused rather than silently skewed. Returns `{location_id, panorama, povs: {name: path}, size}`. `project_dir` is the `pipeline/` data root; omit to use the open project.",
            inputSchema: objectSchema(
                properties: [
                    "project_dir": projectDirProperty,
                    "location_id": ["type": "string", "description": "Bible location id the views belong to."],
                    "panorama": ["type": "string", "description": "Equirectangular panorama (home-relative or absolute). Omit to use the location's recorded scene3d.panorama."],
                    "povs": [
                        "type": "array",
                        "description": "Custom camera set. Omit for the four cardinal walls.",
                        "items": objectSchema(
                            properties: [
                                "name": ["type": "string", "description": "Sheet key, e.g. \"wide_chalkboard\"."],
                                "yaw": ["type": "number", "description": "Degrees; 0 = panorama centre, positive turns right."],
                                "pitch": ["type": "number", "description": "Degrees; negative looks down (default -5)."],
                                "fov_h": ["type": "number", "description": "Horizontal field of view in degrees (default 75)."],
                            ],
                            required: ["name", "yaw"]
                        ),
                    ],
                    "width": ["type": "integer", "description": "POV width in px (default 1280)."],
                    "height": ["type": "integer", "description": "POV height in px (default 720)."],
                ],
                required: ["location_id"]
            )
        ),
        AgentTool(
            name: .assembleTimeline,
            description: "Lay the rendered shots onto the timeline cut to the beat. WRITES.\n\nBuilds the final cut for the render `phase`: reads the analysis (beats, downbeats, sections), the shotlist (ordered shots + planned spans), and the render manifest (each shot's rendered file), then places every rendered shot in shotlist order on a dedicated assembly video track, each cut snapped to a beat: a downbeat at a section boundary, a regular beat otherwise. The song is laid on an audio track at frame 0 as the sync anchor if it isn't already there. Frame-exact at the project fps. Re-runnable: a second call rebuilds the assembly track in place rather than duplicating clips. Shots with no rendered output yet are skipped and named, not fatal; a shot's source_mode (generated / imported / ai_enhanced) doesn't matter, only that its output is recorded. Needs analysis (run_phase \"analysis\") and at least one recorded render first, or it returns an actionable error. Returns `{shots_placed, total_frames, video_track_index, song_track, placements, skipped}`. `project_dir` is the `pipeline/` data root; omit to use the open project.",
            inputSchema: objectSchema(
                properties: [
                    "project_dir": projectDirProperty,
                    "phase": ["type": "string", "description": "The render phase to assemble (default \"final\")."],
                ]
            )
        ),
        AgentTool(
            name: .getLedger,
            description: "The Intent Ledger: the director's durable creative decisions per object. Read-only.\n\nReturns `{schema, objects}` where `objects` maps `<kind>:<id>` (or the `look`/`film` singletons) to named attributes `{tag, directive, source, locked, updated}`. Locked attributes are hard facts generation MUST honor. `project_dir` is the `pipeline/` data root; omit to use the open project.",
            inputSchema: projectDirSchema()
        ),
        AgentTool(
            name: .setLedgerAttribute,
            description: "Create or update ONE ledger attribute (reconcile — update the existing key rather than inventing near-duplicate keys). WRITES.\n\n`kind` is one of character/ensemble/prop/location/shot (needs `object_id` = the Bible/shot id) or look/film (singletons, no `object_id`). `tag` is the short visible handle (\"Wardrobe: faded red canvas jacket\"); `directive` the model-ready phrasing (defaults to the tag); `source` the user's original words. An existing lock survives unless `locked` is passed explicitly. `project_dir` is the `pipeline/` data root; omit to use the open project.",
            inputSchema: objectSchema(
                properties: [
                    "project_dir": projectDirProperty,
                    "kind": ["type": "string", "description": "character/ensemble/prop/location/shot (needs object_id) or look/film (singletons)."],
                    "key": ["type": "string", "description": "Attribute name (e.g. 'wardrobe')."],
                    "tag": ["type": "string", "description": "Short visible handle."],
                    "object_id": ["type": "string", "description": "Bible/shot id — required for non-singleton kinds."],
                    "directive": ["type": "string", "description": "Model-ready phrasing (defaults to the tag)."],
                    "source": ["type": "string", "description": "The user's original words."],
                    "locked": ["type": "boolean", "description": "Lock state; omit to preserve an existing lock."],
                ],
                required: ["kind", "key", "tag"]
            )
        ),
        AgentTool(
            name: .lockLedgerAttribute,
            description: "Lock (or unlock) an existing ledger attribute. WRITES. A locked attribute is a promise: the prompt generator must include it and reviews check it; it cannot be removed while locked. `project_dir` is the `pipeline/` data root; omit to use the open project.",
            inputSchema: objectSchema(
                properties: [
                    "project_dir": projectDirProperty,
                    "kind": ["type": "string", "description": "The object kind."],
                    "key": ["type": "string", "description": "Attribute name."],
                    "object_id": ["type": "string", "description": "Bible/shot id — required for non-singleton kinds."],
                    "locked": ["type": "boolean", "description": "true to lock (default), false to unlock."],
                ],
                required: ["kind", "key"]
            )
        ),
        AgentTool(
            name: .removeLedgerAttribute,
            description: "Remove an UNLOCKED ledger attribute (locked ones must be unlocked first). WRITES. `project_dir` is the `pipeline/` data root; omit to use the open project.",
            inputSchema: objectSchema(
                properties: [
                    "project_dir": projectDirProperty,
                    "kind": ["type": "string", "description": "The object kind."],
                    "key": ["type": "string", "description": "Attribute name."],
                    "object_id": ["type": "string", "description": "Bible/shot id — required for non-singleton kinds."],
                ],
                required: ["kind", "key"]
            )
        ),
        AgentTool(
            name: .resolveModel,
            description: "Which model + effort a task gets. Read-only.\n\n`task_class` is one of distill/classification/assembly/review/planning/interpretation. Returns `{task_class, tier, model, effort, escalated}` — the fixed floor, or with `escalate=true` exactly ONE tier up (use only after a concrete gate failure: lint error, schema violation, user reject; never speculatively). Optional `project_dir` (the `pipeline/` data root) applies the project's models.yaml manifest override; omit to use the open project.",
            inputSchema: objectSchema(
                properties: [
                    "task_class": ["type": "string", "description": "distill/classification/assembly/review/planning/interpretation."],
                    "escalate": ["type": "boolean", "description": "Bump exactly one tier up (default false)."],
                    "project_dir": projectDirProperty,
                ],
                required: ["task_class"]
            )
        ),
        AgentTool(
            name: .getUIContract,
            description: "Per-phase UI contract: the default interaction surface (choice/prose/review) and router task class for every phase (engine core + installed packs). Read-only.",
            inputSchema: objectSchema()
        ),
        AgentTool(
            name: .setGateState,
            description: "Record the multi-state gate verdict. WRITES.\n\n`state` is one of approved / approved_with_notes / needs_revision / pending. Only the two approve states unblock the pipeline; `needs_revision` keeps the phase blocked and carries the reviewer's notes. `project_dir` is the `pipeline/` data root; omit to use the open project.",
            inputSchema: objectSchema(
                properties: [
                    "project_dir": projectDirProperty,
                    "phase": ["type": "string", "description": "The phase whose gate verdict to record."],
                    "state": ["type": "string", "description": "approved / approved_with_notes / needs_revision / pending."],
                    "notes": ["type": "string", "description": "Optional reviewer notes."],
                ],
                required: ["phase", "state"]
            )
        ),
        AgentTool(
            name: .runProviderTool,
            description: "Run a NON-generative WORKFLOW tool exposed by an activated provider's MCP (e.g. background removal, reframe, roto, reference upload, a character lookup). NGV resolves which activated provider offers the named tool (cheapest first) and drives its MCP as the client on the user's subscription — you never call the provider directly. The user confirms the call before it runs (spend approval), same as a paid render.\n\nNOT for content generation: to make a video/image/audio, use generate_video / generate_image / generate_audio (they enforce the prompt engine and the compile gate) and upscale_media for upscaling — those paths are refused here. If a tool returns media URLs, import them with import_media. Only works when the user has configured a provider MCP in Settings → Providers.",
            inputSchema: objectSchema(
                properties: [
                    "tool": ["type": "string", "description": "Exact tool name to run (as the provider's MCP exposes it). If unsure, the error lists the tools offered by the configured provider MCPs."],
                    "arguments": [
                        "type": "object",
                        "description": "Arguments for the tool, as string values (the provider's MCP defines the schema). E.g. { \"image_url\": \"https://…\" }.",
                    ],
                ],
                required: ["tool"]
            )
        ),
    ]

    /// `save_frame_audit`'s `checks` schema: an object requiring all 10 standard audit keys, each a
    /// `{status, observed, note}` object with `status` enum-constrained. `expected` is machine-filled
    /// so it's deliberately absent from the input schema. Extra free keys stay allowed.
    private static var frameAuditChecksSchema: [String: Any] {
        let checkSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "status": [
                    "type": "string", "enum": ["clean", "minor", "blocking", "n/a"],
                    "description": "Verdict for this audit point (\"n/a\" when the spec doesn't constrain it).",
                ],
                "observed": ["type": "string", "description": "What the image shows."],
                "note": ["type": "string", "description": "Short finding for the user / re-render patch."],
            ],
            "required": ["status"],
        ]
        var properties: [String: Any] = [:]
        for key in standardAuditCheckKeys { properties[key] = checkSchema }
        return [
            "type": "object",
            "description": "One verdict per audit point. All 10 standard keys are required (\(standardAuditCheckKeys.joined(separator: ", "))); extra keys are allowed. Supply status/observed/note only — expected is filled from the shot spec.",
            "properties": properties,
            "required": standardAuditCheckKeys,
        ]
    }

    /// Shared `project_dir` property schema for the pipeline tools (optional — defaults to the open
    /// project's pipeline dir when omitted).
    private static var projectDirProperty: [String: Any] { [
        "type": "string",
        "description": "The project's `pipeline/` data root. Omit to use the open project.",
    ] }

    /// An object schema whose only (optional) property is `project_dir`.
    private static func projectDirSchema() -> [String: Any] {
        objectSchema(properties: ["project_dir": projectDirProperty])
    }

    /// One line per non-color effect for apply_effect's description, generated from the registry.
    private static func effectCatalog() -> String {
        func n(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%g", v) }
        return EffectRegistry.all
            .filter { !$0.id.hasPrefix("color.") }
            .map { d in
                let params = d.params.map { p in
                    "\(p.key) (\(n(p.range.lowerBound))…\(n(p.range.upperBound))\(p.unit), default \(n(p.defaultValue)))"
                }.joined(separator: ", ")
                return "• \(d.id) — \(d.displayName): \(params.isEmpty ? "no params" : params)"
            }
            .joined(separator: "\n")
    }

    private static func objectSchema(
        properties: [String: [String: Any]] = [:],
        required: [String] = []
    ) -> [String: Any] {
        var dict: [String: Any] = ["type": "object"]
        if !properties.isEmpty {
            dict["properties"] = properties
        }
        if !required.isEmpty {
            dict["required"] = required
        }
        return dict
    }
}

extension AgentTool {
    var mcpSchemaValue: Value {
        Self.valueFromJSON(inputSchema)
    }

    private static func valueFromJSON(_ any: Any) -> Value {
        switch any {
        case let v as Value: return v
        case let s as String: return .string(s)
        case let b as Bool: return .bool(b)
        case let i as Int: return .int(i)
        case let d as Double: return .double(d)
        case let arr as [Any]: return .array(arr.map(valueFromJSON))
        case let dict as [String: Any]:
            var out: [String: Value] = [:]
            out.reserveCapacity(dict.count)
            for (k, v) in dict { out[k] = valueFromJSON(v) }
            return .object(out)
        default: return .null
        }
    }
}

enum ToolArgsBridge {
    static func argsFromMCP(_ args: [String: Value]) -> [String: Any] {
        var out: [String: Any] = [:]
        out.reserveCapacity(args.count)
        for (k, v) in args { out[k] = anyFromValue(v) }
        return out
    }

    static func anyFromValue(_ v: Value) -> Any {
        switch v {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .data(_, let d): return d
        case .array(let arr): return arr.map(anyFromValue)
        case .object(let obj):
            var out: [String: Any] = [:]
            out.reserveCapacity(obj.count)
            for (k, v) in obj { out[k] = anyFromValue(v) }
            return out
        }
    }
}
