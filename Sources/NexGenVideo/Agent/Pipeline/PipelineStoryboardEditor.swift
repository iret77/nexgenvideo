import AppKit
import Foundation
import NexGenEngine

@MainActor
enum PipelineStoryboardEditor {
    enum Command: Sendable {
        case reorder(shotIDs: [String])
        case duplicate(shotID: String, startTicks: Int64)
        case split(shotID: String, offsetTicks: Int64)
        case delete(shotID: String)
        case setTiming(shotID: String, startTicks: Int64, durationTicks: Int64)
        case setDuration(shotID: String, durationTicks: Int64)
        case setFraming(shotID: String, framing: StoryboardTimingV1.FramingIntent)
        case setShotSteps(shotID: String, primaryStepID: String, additionalStepIDs: [String])
        case replaceStep(StoryboardV2.StoryStep, binding: StoryboardCausalityV2.Binding)
        case insertMoment(shotID: String, offsetTicks: Int64, intent: String)
        case deleteMoment(shotID: String, momentID: String)
        case reorderMoments(shotID: String, momentIDs: [String])
        case setMomentOffset(shotID: String, momentID: String, offsetTicks: Int64)
        case setMomentIntent(shotID: String, momentID: String, intent: String)
        case setMoment(shotID: String, momentID: String, offsetTicks: Int64, intent: String)
        case assignExistingSketch(shotID: String, momentID: String, asset: StoryboardTimingV1.SketchAsset)
        case removeSketch(shotID: String, momentID: String)
    }

    struct EditError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct State: Sendable, Equatable {
        var summary: String
        var steps: [StoryboardV2.StoryStep]
        var bindings: [StoryboardCausalityV2.Binding]
        var timing: StoryboardTimingV1

        nonisolated init(summary: String, steps: [StoryboardV2.StoryStep], bindings: [StoryboardCausalityV2.Binding], timing: StoryboardTimingV1) {
            self.summary = summary
            self.steps = steps
            self.bindings = bindings
            self.timing = timing
        }

        nonisolated init(_ snapshot: StoryboardBundleSnapshot) {
            self.init(summary: snapshot.storyboard.summary, steps: snapshot.storyboard.steps,
                      bindings: snapshot.causality.bindings, timing: snapshot.timing)
        }
    }

    struct Assignment: Sendable {
        let shotID: String
        let momentID: String
        let original: StoryboardTimingV1.SketchAsset
    }

    struct Plan: Sendable {
        let state: State
        let identities: [PipelineStoryboardBundleWriter.NativeShotIdentity]
        let assignments: [Assignment]
    }

    @MainActor private final class Session {
        weak var editor: EditorViewModel?
        let home: URL?
        let key: String?
        let manager = UndoManager()
        var fingerprint: String?
        lazy var history = PipelineNativeRevisionHistory<StoryboardBundleSnapshot>(manager: manager, equivalent: historyEquivalent,
            restore: { [weak self] desired, expected in
                guard let self, let editor = self.editor, editor.workingRoot == self.home,
                      editor.openWorkingCopyKey == self.key else { throw changed() }
                let (_, after) = try await withCurrent(editor: editor, expectedFingerprint: expected.fingerprint) { current, access in
                    try publish(restoration(restorableState(desired), identity: current.identity), current: current, access: access)
                }
                self.fingerprint = after.fingerprint
                return after
            }, failure: { [weak self] error in
                self?.editor?.mediaPanelToast = MediaPanelToast(message: error.localizedDescription)
            })

        init(editor: EditorViewModel) {
            self.editor = editor
            home = editor.workingRoot; key = editor.openWorkingCopyKey
            manager.groupsByEvent = false
        }
    }

    private static var sessions: [ObjectIdentifier: Session] = [:]

    static func undoManager(editor: EditorViewModel) -> UndoManager { session(editor).manager }
    static func canUndo(editor: EditorViewModel) -> Bool { let value = session(editor); return !value.history.isBusy && value.manager.canUndo }
    static func canRedo(editor: EditorViewModel) -> Bool { let value = session(editor); return !value.history.isBusy && value.manager.canRedo }

    static func apply(_ command: Command, expectedFingerprint: String,
                      editor: EditorViewModel) async throws -> StoryboardBundleSnapshot {
        let session = session(editor)
        guard !session.history.isBusy else { throw EditError(message: "Wait for the native revision to finish restoring.") }
        let (before, after) = try await withCurrent(editor: editor, expectedFingerprint: expectedFingerprint) { current, access in
            let plan = try preview(command, state: State(current))
            guard plan.state != State(current) || !plan.assignments.isEmpty else { return current }
            return try publish(plan, current: current, access: access)
        }
        if before.fingerprint != after.fingerprint {
            recordNativeAssignment(before: before, after: after, editor: editor, name: actionName(command))
        }
        return after
    }

    static func undo(expectedFingerprint: String, editor: EditorViewModel) async throws -> StoryboardBundleSnapshot {
        try await replay(expectedFingerprint: expectedFingerprint, editor: editor, redo: false)
    }

    static func redo(expectedFingerprint: String, editor: EditorViewModel) async throws -> StoryboardBundleSnapshot {
        try await replay(expectedFingerprint: expectedFingerprint, editor: editor, redo: true)
    }

    static func attachImage(from url: URL, shotID: String, momentID: String,
                            expectedFingerprint: String, editor: EditorViewModel) async throws -> StoryboardBundleSnapshot {
        try requireAvailable(editor: editor)
        let root = try dataRoot(editor)
        let before = try await Task.detached(priority: .userInitiated) {
            try PlanningWriterIO.storyboard(dataRoot: root, requireVisuals: false)
        }.value
        guard before.fingerprint == expectedFingerprint else { throw changed() }
        let after = try await PipelineStoryboardBundleWriter.attachImage(from: url, shotID: shotID, momentID: momentID,
            expectedFingerprint: expectedFingerprint, editor: editor)
        recordNativeAssignment(before: before, after: after, editor: editor)
        editor.onPipelineChanged?()
        await editor.refreshEngineState()
        return after
    }

    static func resetHistory(editor: EditorViewModel) {
        sessions.removeValue(forKey: ObjectIdentifier(editor))?.history.clear()
    }

    static func requireAvailable(editor: EditorViewModel) throws {
        guard !session(editor).history.isBusy else { throw EditError(message: "Wait for the native revision to finish restoring.") }
    }

    static func recordNativeAssignment(before: StoryboardBundleSnapshot, after: StoryboardBundleSnapshot, editor: EditorViewModel,
                                       name: String = "Assign Sketch") {
        let session = session(editor)
        if session.fingerprint != before.fingerprint { session.history.clear() }
        session.fingerprint = after.fingerprint
        session.history.record(before: before, after: after, name: name)
    }

    nonisolated static func preview(_ command: Command, state: State) throws -> Plan {
        guard Set(state.timing.shots.map(\.id)).count == state.timing.shots.count,
              state.timing.shots.allSatisfy({ Set($0.moments.map(\.id)).count == $0.moments.count }) else { throw changed() }
        var state = state
        var shots = state.timing.shots
        var identities: [PipelineStoryboardBundleWriter.NativeShotIdentity] = []
        var assignments: [Assignment] = []
        func index(_ id: String) throws -> Int {
            guard let index = shots.firstIndex(where: { $0.id == id }) else { throw EditError(message: "Select a current Storyboard shot.") }
            return index
        }
        func allocate() -> String {
            let identity = PipelineStoryboardBundleWriter.allocateNativeShotIdentity()
            identities.append(identity)
            return identity.shotID
        }
        switch command {
        case .reorder(let ids):
            try exactOrder(ids, expected: shots.map(\.id), item: "shots")
            let byID = Dictionary(uniqueKeysWithValues: shots.map { ($0.id, $0) })
            let starts = shots.map(\.startTicks)
            shots = try ids.enumerated().map { offset, id in
                guard let shot = byID[id] else { throw changed() }
                return copy(shot, start: state.timing.mode == .multicam ? shot.startTicks : starts[offset])
            }
        case .duplicate(let id, let start):
            let source = shots[try index(id)]
            guard state.timing.mode != .multicam else { throw EditError(message: "Add a distinct camera source instead of duplicating a full-song camera.") }
            let duplicate = StoryboardTimingV1.PlannedShot(id: allocate(), primaryStepID: source.primaryStepID,
                additionalStepIDs: source.additionalStepIDs, startTicks: start, durationTicks: source.durationTicks,
                framing: source.framing, moments: source.moments.map { newMoment($0, offset: $0.offsetTicks) })
            shots.insert(duplicate, at: try index(id) + 1)
            shots = chronological(shots)
        case .split(let id, let offset):
            let position = try index(id), source = shots[position]
            guard state.timing.mode != .multicam, offset > 0, offset < source.durationTicks else {
                throw EditError(message: "Split inside a linear shot. Full-song cameras cannot be split here.")
            }
            try frameBoundary(offset, timebase: state.timing.timebase)
            let tail = source.moments.filter { $0.offsetTicks >= offset }
            let active = source.moments.last { $0.offsetTicks <= offset }
            guard let active else { throw EditError(message: "The shot needs a starting sketch moment before it can be split.") }
            var moments = tail.map { newMoment($0, offset: $0.offsetTicks - offset) }
            if moments.first?.offsetTicks != 0 { moments.insert(newMoment(active, offset: 0), at: 0) }
            let second = StoryboardTimingV1.PlannedShot(id: allocate(), primaryStepID: source.primaryStepID,
                additionalStepIDs: source.additionalStepIDs, startTicks: try sum(source.startTicks, offset),
                durationTicks: source.durationTicks - offset, framing: source.framing, moments: moments)
            shots[position] = copy(source, duration: offset, moments: source.moments.filter { $0.offsetTicks < offset })
            shots.insert(second, at: position + 1)
        case .delete(let id):
            shots.remove(at: try index(id))
        case .setTiming(let id, let start, let duration):
            let position = try index(id)
            shots[position] = copy(shots[position], start: start, duration: duration)
            if state.timing.mode != .multicam { shots = chronological(shots) }
        case .setDuration(let id, let duration):
            let position = try index(id)
            shots[position] = copy(shots[position], duration: duration)
        case .setFraming(let id, let framing):
            let position = try index(id), source = shots[position]
            if framing != source.framing {
                shots[position] = copy(source, framing: framing, moments: source.moments.map { withoutImage($0) })
            }
        case .setShotSteps(let id, let primary, let additional):
            let position = try index(id), source = shots[position]
            guard source.primaryStepID != primary || source.additionalStepIDs != additional else { break }
            let changesIdentity = source.primaryStepID != primary
            shots[position] = .init(id: changesIdentity ? allocate() : source.id, primaryStepID: primary,
                additionalStepIDs: additional, startTicks: source.startTicks, durationTicks: source.durationTicks,
                cameraID: source.cameraID, framing: source.framing, moments: source.moments.map {
                    changesIdentity ? newMoment($0, offset: $0.offsetTicks) : withoutImage($0)
                })
        case .replaceStep(let replacement, let binding):
            guard let position = state.steps.firstIndex(where: { $0.id == replacement.id }), binding.stepID == replacement.id,
                  let causalPosition = state.bindings.firstIndex(where: { $0.stepID == replacement.id }) else {
                throw EditError(message: "Edit an existing story step and its matching Script adaptation.")
            }
            if state.steps[position] != replacement || state.bindings[causalPosition] != binding {
                state.steps[position] = replacement
                state.bindings[causalPosition] = binding
                shots = shots.map { shot in
                    guard shot.stepIDs.contains(replacement.id) else { return shot }
                    let changesIdentity = shot.primaryStepID == replacement.id
                    return .init(id: changesIdentity ? allocate() : shot.id, primaryStepID: shot.primaryStepID,
                        additionalStepIDs: shot.additionalStepIDs, startTicks: shot.startTicks, durationTicks: shot.durationTicks,
                        cameraID: shot.cameraID, framing: shot.framing, moments: shot.moments.map {
                            changesIdentity ? newMoment($0, offset: $0.offsetTicks) : withoutImage($0)
                        })
                }
            }
        case .insertMoment(let id, let offset, let intent):
            let position = try index(id), shot = shots[position]
            let moment = StoryboardTimingV1.Moment(id: momentID(), offsetTicks: offset, intent: intent)
            shots[position] = copy(shot, moments: (shot.moments + [moment]).sorted { $0.offsetTicks < $1.offsetTicks })
        case .deleteMoment(let id, let momentID):
            let position = try index(id), shot = shots[position]
            guard shot.moments.contains(where: { $0.id == momentID }), shot.moments.count > 1 else {
                throw EditError(message: "Keep one starting sketch moment for every shot. Remove its image or delete the shot instead.")
            }
            var moments = shot.moments.filter { $0.id != momentID }
            if moments[0].offsetTicks != 0 {
                moments[0] = .init(id: moments[0].id, offsetTicks: 0, intent: moments[0].intent, asset: moments[0].asset)
            }
            shots[position] = copy(shot, moments: moments)
        case .reorderMoments(let id, let ids):
            let position = try index(id), shot = shots[position]
            try exactOrder(ids, expected: shot.moments.map(\.id), item: "sketch moments")
            let byID = Dictionary(uniqueKeysWithValues: shot.moments.map { ($0.id, $0) })
            let offsets = shot.moments.map(\.offsetTicks)
            let moments = try ids.enumerated().map { offset, id -> StoryboardTimingV1.Moment in
                guard let source = byID[id] else { throw changed() }
                return .init(id: source.id, offsetTicks: offsets[offset], intent: source.intent, asset: source.asset)
            }
            shots[position] = copy(shot, moments: moments)
        case .setMomentOffset(let id, let momentID, let offset):
            let position = try index(id), shot = shots[position]
            guard let moment = shot.moments.first(where: { $0.id == momentID }) else { throw changed() }
            let moments = shot.moments.map { $0.id == momentID
                ? StoryboardTimingV1.Moment(id: moment.id, offsetTicks: offset, intent: moment.intent, asset: moment.asset) : $0 }
            shots[position] = copy(shot, moments: moments.sorted { $0.offsetTicks < $1.offsetTicks })
        case .setMomentIntent(let id, let momentID, let intent):
            let position = try index(id), shot = shots[position]
            guard shot.moments.contains(where: { $0.id == momentID }) else { throw changed() }
            shots[position] = copy(shot, moments: shot.moments.map {
                $0.id == momentID && $0.intent != intent ? .init(id: $0.id, offsetTicks: $0.offsetTicks, intent: intent) : $0
            })
        case .setMoment(let id, let momentID, let offset, let intent):
            let position = try index(id), shot = shots[position]
            guard let moment = shot.moments.first(where: { $0.id == momentID }) else { throw changed() }
            let moments = shot.moments.map { $0.id == momentID
                ? StoryboardTimingV1.Moment(id: moment.id, offsetTicks: offset, intent: intent,
                    asset: moment.intent == intent ? moment.asset : nil) : $0 }
            shots[position] = copy(shot, moments: moments.sorted { $0.offsetTicks < $1.offsetTicks })
        case .assignExistingSketch(let id, let momentID, let asset):
            let position = try index(id), shot = shots[position]
            guard shot.moments.contains(where: { $0.id == momentID }) else { throw changed() }
            shots[position] = copy(shot, moments: shot.moments.map { $0.id == momentID ? withoutImage($0) : $0 })
            assignments.append(.init(shotID: id, momentID: momentID, original: asset))
        case .removeSketch(let id, let momentID):
            let position = try index(id), shot = shots[position]
            guard shot.moments.contains(where: { $0.id == momentID }) else { throw changed() }
            shots[position] = copy(shot, moments: shot.moments.map { $0.id == momentID ? withoutImage($0) : $0 })
        }
        state.timing = timing(state.timing, shots: shots)
        try validateEdits(state)
        return Plan(state: state, identities: identities, assignments: assignments)
    }

    nonisolated private static func publish(_ plan: Plan, current: StoryboardBundleSnapshot,
                                access: PipelinePlanningWriteAccess) throws -> StoryboardBundleSnapshot {
        var state = plan.state
        var prepared: [PipelineStoryboardImageReassignment.Prepared] = []
        var shots = state.timing.shots
        for assignment in plan.assignments {
            guard let position = shots.firstIndex(where: { $0.id == assignment.shotID }),
                  let moment = shots[position].moments.first(where: { $0.id == assignment.momentID }) else { throw changed() }
            let result = try PipelineStoryboardImageReassignment.prepare(originalAsset: assignment.original,
                targetShotID: assignment.shotID, targetMoment: moment, framing: shots[position].framing,
                projectID: current.storyboard.header.projectID, expectedFingerprint: current.fingerprint, dataRoot: access.dataRoot)
            prepared.append(result)
            shots[position] = copy(shots[position], moments: shots[position].moments.map {
                $0.id == moment.id ? .init(id: $0.id, offsetTicks: $0.offsetTicks, intent: $0.intent, asset: result.asset) : $0
            })
        }
        state.timing = timing(state.timing, shots: shots)
        let proposal = PipelineStoryboardBundleWriter.Proposal(summary: state.summary, steps: state.steps, bindings: state.bindings,
            timebase: state.timing.timebase, mode: state.timing.mode, rangeStartTicks: state.timing.rangeStartTicks,
            rangeDurationTicks: state.timing.rangeDurationTicks, audio: state.timing.audio, shots: shots.map {
                .init(id: $0.id, primaryStepID: $0.primaryStepID, additionalStepIDs: $0.additionalStepIDs,
                      startTicks: $0.startTicks, durationTicks: $0.durationTicks, cameraID: $0.cameraID, framing: $0.framing, moments: $0.moments)
            })
        return try PipelineStoryboardBundleWriter.write(proposal, origin: .userRevision, access: access,
            nativeIdentities: plan.identities, nativeReassignments: prepared)
    }

    nonisolated static func restoration(_ desired: State, identity: StoryboardIdentityV1) throws -> Plan {
        var desired = desired
        let active = Dictionary(uniqueKeysWithValues: identity.entries.filter { $0.retiredRevision == nil }.map { ($0.shotID, $0) })
        let steps = Dictionary(uniqueKeysWithValues: desired.steps.map { ($0.id, $0) })
        var identities: [PipelineStoryboardBundleWriter.NativeShotIdentity] = []
        var assignments: [Assignment] = []
        let shots = try desired.timing.shots.map { old -> StoryboardTimingV1.PlannedShot in
            guard let step = steps[old.primaryStepID] else { throw changed() }
            let canRetain = active[old.id]?.primaryStepID == old.primaryStepID
                && active[old.id]?.actionSHA256 == FileDigest.sha256(of: Data(step.action.utf8))
            let id: String
            if canRetain { id = old.id }
            else {
                let token = PipelineStoryboardBundleWriter.allocateNativeShotIdentity()
                identities.append(token)
                id = token.shotID
            }
            let moments = old.moments.map { moment -> StoryboardTimingV1.Moment in
                let target = StoryboardTimingV1.Moment(id: canRetain ? moment.id : momentID(), offsetTicks: moment.offsetTicks, intent: moment.intent)
                if let asset = moment.asset { assignments.append(.init(shotID: id, momentID: target.id, original: asset)) }
                return target
            }
            return .init(id: id, primaryStepID: old.primaryStepID, additionalStepIDs: old.additionalStepIDs,
                startTicks: old.startTicks, durationTicks: old.durationTicks, cameraID: old.cameraID, framing: old.framing, moments: moments)
        }
        desired.timing = timing(desired.timing, shots: shots)
        try validateEdits(desired)
        return Plan(state: desired, identities: identities, assignments: assignments)
    }

    nonisolated private static func historyEquivalent(_ first: StoryboardBundleSnapshot, _ second: StoryboardBundleSnapshot) -> Bool {
        let firstTiming = restorableState(first).timing, secondTiming = restorableState(second).timing
        guard first.storyboard.header.projectID == second.storyboard.header.projectID,
              first.storyboard.summary == second.storyboard.summary, first.storyboard.steps == second.storyboard.steps,
              first.causality.bindings == second.causality.bindings, firstTiming.timebase == secondTiming.timebase,
              firstTiming.mode == secondTiming.mode, firstTiming.audio == secondTiming.audio,
              firstTiming.rangeStartTicks == secondTiming.rangeStartTicks,
              firstTiming.rangeDurationTicks == secondTiming.rangeDurationTicks,
              firstTiming.shots.count == secondTiming.shots.count else { return false }
        return zip(firstTiming.shots, secondTiming.shots).allSatisfy { a, b in
            a.stepIDs == b.stepIDs && a.startTicks == b.startTicks && a.durationTicks == b.durationTicks
                && a.cameraID == b.cameraID && a.framing == b.framing && a.moments.count == b.moments.count
                && zip(a.moments, b.moments).allSatisfy { x, y in
                    x.offsetTicks == y.offsetTicks && x.intent == y.intent && x.asset?.image == y.asset?.image
                }
        }
    }

    static func waitForPendingRestore(editor: EditorViewModel) async throws -> StoryboardBundleSnapshot {
        try await session(editor).history.waitForRestore()
    }

    nonisolated private static func restorableState(_ snapshot: StoryboardBundleSnapshot) -> State {
        var state = State(snapshot)
        guard !snapshot.sketchProblems.isEmpty else { return state }
        state.timing = timing(state.timing, shots: state.timing.shots.map { shot in
            copy(shot, moments: shot.moments.map { snapshot.sketchProblems[$0.id] == nil ? $0 : withoutImage($0) })
        })
        return state
    }

    private static func replay(expectedFingerprint: String, editor: EditorViewModel, redo: Bool) async throws -> StoryboardBundleSnapshot {
        let session = session(editor)
        let root = try dataRoot(editor)
        let current = try await Task.detached(priority: .userInitiated) {
            try PlanningWriterIO.storyboard(dataRoot: root, requireVisuals: false)
        }.value
        guard current.fingerprint == expectedFingerprint && session.fingerprint == expectedFingerprint else { throw changed() }
        return try await session.history.replay(redo: redo)
    }

    private static func withCurrent(editor: EditorViewModel, expectedFingerprint: String,
        body: @escaping @Sendable (StoryboardBundleSnapshot, PipelinePlanningWriteAccess) throws -> StoryboardBundleSnapshot)
        async throws -> (StoryboardBundleSnapshot, StoryboardBundleSnapshot) {
        let access = try PipelineNativeEditAccess(editor: editor, label: "Edit Storyboard")
        defer { access.end(editor: editor) }
        let preparation = Task.detached(priority: .userInitiated) {
            _ = try PipelinePlanningWriteAccess(dataRoot: access.root, declaration: access.declaration, phase: "storyboard")
            let before = try PlanningWriterIO.storyboard(dataRoot: access.root, requireVisuals: false)
            guard before.fingerprint == expectedFingerprint else { throw changed() }
            let fence = try PipelineSpatialSceneAuthority.SourceFence.capture(dataRoot: access.root,
                additionalCanonicalPaths: before.references.map(\.path))
            let transaction = try ProjectWorkingCopy.preparePipelineTransaction(at: access.root) { staging in
                let writer = try PipelinePlanningWriteAccess(dataRoot: staging, declaration: access.declaration, phase: "storyboard")
                guard try PlanningWriterIO.storyboard(dataRoot: staging, requireVisuals: false).fingerprint == expectedFingerprint else { throw changed() }
                return try body(before, writer)
            }
            do { try fence.requireUnchanged(); return (transaction, before, fence) }
            catch { transaction.discard(); throw error }
        }
        let result = try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
        defer { Task.detached { result.0.discard() } }
        try Task.checkCancellation()
        if result.0.output.fingerprint == result.1.fingerprint { return (result.1, result.1) }
        let after = try result.0.commit { _ in
            try access.requireCurrent(editor: editor)
            try result.2.requireCanonicalRootsUnchanged()
            try ProjectWorkingCopy.markDirty(key: access.key)
        }
        editor.onPipelineChanged?()
        await editor.refreshEngineState()
        return (result.1, after)
    }

    nonisolated static func validateEdits(_ state: State) throws {
        let timing = state.timing
        try timing.timebase.validate()
        let end = try sum(timing.rangeStartTicks, timing.rangeDurationTicks)
        guard timing.rangeStartTicks >= 0, timing.rangeDurationTicks > 0, !timing.shots.isEmpty else {
            throw EditError(message: "Keep at least one shot in the selected playback range.")
        }
        let requiredSteps = Set(state.steps.map(\.id))
        guard requiredSteps.count == state.steps.count,
              Set(timing.shots.map(\.id)).count == timing.shots.count,
              Set(state.bindings.map(\.stepID)) == requiredSteps,
              state.bindings.count == requiredSteps.count else {
            throw EditError(message: "Reload the current Storyboard before editing duplicate or missing identities.")
        }
        guard Set(timing.shots.flatMap(\.stepIDs)) == requiredSteps else {
            throw EditError(message: "Every approved story step needs a shot. Assign its beat to another shot before deleting this one.")
        }
        for shot in timing.shots {
            let shotEnd = try sum(shot.startTicks, shot.durationTicks)
            guard shot.startTicks >= timing.rangeStartTicks, shot.durationTicks > 0, shotEnd <= end else {
                throw EditError(message: "Keep the shot inside the selected playback range. Neighbouring cuts are not moved automatically.")
            }
            try frameBoundary(shot.startTicks, timebase: timing.timebase)
            if shotEnd != end { try frameBoundary(shotEnd, timebase: timing.timebase) }
            if timing.mode == .multicam {
                guard shot.startTicks == 0 && shotEnd == end else { throw EditError(message: "Each Multicam source must cover the full song.") }
            }
            guard !shot.framing.scale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !shot.framing.composition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !shot.framing.cameraView.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw EditError(message: "Describe the sketch scale, composition and camera view.")
            }
            guard Set(shot.moments.map(\.id)).count == shot.moments.count,
                  Set(shot.stepIDs).count == shot.stepIDs.count else { throw EditError(message: "Use each step and sketch identity once within a shot.") }
            guard shot.moments.first.map({ $0.offsetTicks == 0 }) != false else { throw EditError(message: "The first sketch moment must start at the shot's beginning.") }
            var previous: Int64 = -1
            for moment in shot.moments {
                guard moment.offsetTicks > previous, moment.offsetTicks < shot.durationTicks,
                      !moment.intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw EditError(message: "Place each sketch at a distinct time inside its shot and describe its visible moment.")
                }
                try frameBoundary(moment.offsetTicks, timebase: timing.timebase)
                previous = moment.offsetTicks
            }
        }
    }

    nonisolated private static func copy(_ shot: StoryboardTimingV1.PlannedShot, start: Int64? = nil, duration: Int64? = nil,
                             framing: StoryboardTimingV1.FramingIntent? = nil, moments: [StoryboardTimingV1.Moment]? = nil) -> StoryboardTimingV1.PlannedShot {
        .init(id: shot.id, primaryStepID: shot.primaryStepID, additionalStepIDs: shot.additionalStepIDs,
              startTicks: start ?? shot.startTicks, durationTicks: duration ?? shot.durationTicks, cameraID: shot.cameraID,
              framing: framing ?? shot.framing, moments: moments ?? shot.moments)
    }

    nonisolated private static func timing(_ source: StoryboardTimingV1, shots: [StoryboardTimingV1.PlannedShot]) -> StoryboardTimingV1 {
        .init(header: source.header, timebase: source.timebase, mode: source.mode, rangeStartTicks: source.rangeStartTicks,
              rangeDurationTicks: source.rangeDurationTicks, audio: source.audio, shots: shots)
    }

    nonisolated private static func newMoment(_ source: StoryboardTimingV1.Moment, offset: Int64) -> StoryboardTimingV1.Moment {
        .init(id: momentID(), offsetTicks: offset, intent: source.intent)
    }

    nonisolated private static func withoutImage(_ moment: StoryboardTimingV1.Moment) -> StoryboardTimingV1.Moment {
        .init(id: moment.id, offsetTicks: moment.offsetTicks, intent: moment.intent)
    }

    nonisolated private static func chronological(_ shots: [StoryboardTimingV1.PlannedShot]) -> [StoryboardTimingV1.PlannedShot] {
        shots.enumerated().sorted { $0.element.startTicks == $1.element.startTicks
            ? $0.offset < $1.offset : $0.element.startTicks < $1.element.startTicks }.map(\.element)
    }

    nonisolated private static func exactOrder(_ ids: [String], expected: [String], item: String) throws {
        guard ids.count == expected.count && Set(ids).count == ids.count && Set(ids) == Set(expected) else {
            throw EditError(message: "Reorder the current \(item), with each item appearing once.")
        }
    }

    nonisolated private static func frameBoundary(_ tick: Int64, timebase: RationalTimebaseV1) throws {
        do { _ = try ProductionPlanAssemblyV1.frameIndex(for: tick, timebase: timebase) }
        catch { throw EditError(message: "Place the cut or sketch moment on a project frame boundary.") }
    }

    nonisolated private static func sum(_ first: Int64, _ second: Int64) throws -> Int64 {
        let value = first.addingReportingOverflow(second)
        guard !value.overflow else { throw EditError(message: "The requested time is outside the supported project range.") }
        return value.partialValue
    }

    private static func dataRoot(_ editor: EditorViewModel) throws -> URL {
        guard let root = editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }) else {
            throw EditError(message: "Open a production project before editing its Storyboard.")
        }
        return root
    }

    nonisolated private static func momentID() -> String { "moment-" + UUID().uuidString.lowercased() }
    nonisolated private static func changed() -> EditError { EditError(message: "The Storyboard changed. Reload it before applying this edit.") }

    private static func session(_ editor: EditorViewModel) -> Session {
        sessions = sessions.filter { $0.value.editor != nil }
        let key = ObjectIdentifier(editor)
        if let existing = sessions[key], existing.home == editor.workingRoot,
           existing.key == editor.openWorkingCopyKey { return existing }
        sessions[key]?.history.clear()
        let value = Session(editor: editor)
        sessions[key] = value
        return value
    }

    nonisolated private static func actionName(_ command: Command) -> String {
        switch command {
        case .reorder: "Reorder Shots"
        case .duplicate: "Duplicate Shot"
        case .split: "Split Shot"
        case .delete: "Delete Shot"
        case .setTiming, .setDuration: "Change Shot Timing"
        case .setFraming: "Change Sketch Framing"
        case .setShotSteps, .replaceStep: "Edit Story Step"
        case .insertMoment: "Add Sketch Moment"
        case .deleteMoment: "Delete Sketch Moment"
        case .reorderMoments: "Reorder Sketch Moments"
        case .setMomentOffset: "Move Sketch Moment"
        case .setMomentIntent, .setMoment: "Edit Sketch Intent"
        case .assignExistingSketch: "Assign Sketch"
        case .removeSketch: "Remove Sketch"
        }
    }
}
