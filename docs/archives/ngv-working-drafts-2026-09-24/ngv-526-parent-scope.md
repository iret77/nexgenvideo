# #526 preparation, no worktree or leaf

Issue live read at 2026-09-24 05:31 UTC, OPEN, no handoff. #520 dependency exists in PR #591 at d39dbeba0aea870b7f545262df1dd6b1b705e153; last inspected Actions 35631461835 green build/source/diagnostic, UI skipped. UI base #507 local reviewed76a6 on506; no new CI. Reverify heads at actual start. Need explicit local merge of520 by implementing leaf; no main merge.

Primary internal code:
- marker mutations in EditorViewModel+TimelineMarkers.swift: private replaceTimelineMarkers validates whole collection, withTimelineSwap for undo and durable update. Expose/reuse one safe atomic batch entry rather than loop individually mutating markers then pretending atomic.
- ToolExecutor+Markers.swift manage_markers is direct canonical create/update/delete, keep behavior. New review proposals must be proposal-only until explicit application; not just call direct manage_markers during review. Schemas closed/required/enums and actual ToolExecutor gate/origin path.
- TranscriptCache returns source-time segment/word values, full transcript cache is noncanonical derivative. cachedOnDisk is readonly. Do not secretly start transcription on search/index/refresh or invent uncached segments.
- Timeline projection must respect clip source in, trims, speed/time mapping, repeat instances, lane overlap, caption current canonical content. Use existing mapping helpers and media identity; sourceURL position is not timeline position.
- Long timeline index/search should operate cancellable from immutable snapshots, results tied to project/timeline/clip revision; no stale actions applied after edit/switch; target current exact frame.
- Review proposal binds exact viewed index/source/timeline identity, origin and reason. Accept/reject/undo clear atomic semantics, no pipeline artifact/lineage mutation. Hidden host kickoff via AgentService.send hidden true; both supported agent paths.
- UI normative standalone HTML docs/ui before implementation, narrow/wide/search/selection/review states, in-flow native inspector/sidebar integrated with507. Build native actual search/seek/proposal/apply/reject/undo and text-focus interaction evidence in Actions; zero local render/build/test/App.

Upstream reference access BLOCKED: automatic approval review rejected reading <upstream repository> commits e7545552 /01c2006f/24077927 for cross-project authorization. Question13 pending; no retry through gh/web/clone/raw URLs until explicit grant. Continue implementation from NexGenVideo canonical sources if needed, state upstream not read. No spawn failure.
