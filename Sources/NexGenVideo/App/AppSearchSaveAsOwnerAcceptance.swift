import AppKit
import NexGenEngine

@MainActor
enum AppSearchSaveAsOwnerAcceptance {
    @MainActor private final class Observation {
        var started: [UUID: (String, URL?, UUID?)] = [:]
        var completed: [UUID] = []
    }

    static func run(directory: URL, incoming: URL, parent: NSWindow, spec: VisualEmbedder.Spec,
                    driver: ProductionVisualSourcesDriver) async throws -> [String: Any] {
        let package = directory.appendingPathComponent("Search original.ngv", isDirectory: true)
        let copy = directory.appendingPathComponent("Search copy.ngv", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        var timeline = Timeline(); timeline.width = 320; timeline.height = 180; timeline.fps = 30; timeline.settingsConfigured = true
        let a = MediaAsset(id: "external-a", url: incoming.appendingPathComponent("A.mov"), type: .video,
            name: "A", duration: 4, originalFilename: "A.mov")
        let b = MediaAsset(id: "external-b", url: incoming.appendingPathComponent("B.mov"), type: .video,
            name: "B", duration: 3, originalFilename: "B.mov")
        a.hasAudio = false; b.hasAudio = false
        var manifest = MediaManifest(); manifest.entries = [a, b].map { $0.toManifestEntry(projectURL: package) }
        try JSONEncoder().encode(timeline).write(to: package.appendingPathComponent(Project.timelineFilename))
        try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent(Project.manifestFilename))
        try JSONEncoder().encode(GenerationLog()).write(to: package.appendingPathComponent(Project.generationLogFilename))
        let originalID = try ProjectIdentity.uuid(for: package)
        for (asset, vector) in [(a, [Float(1), 0]), (b, [Float(-1), 0])] {
            guard let key = EmbeddingStore.key(for: asset.url) else { throw GateBlocked("The external search source has no identity.") }
            try EmbeddingStore.save(header: .init(model: spec.model, modelVersion: spec.version,
                samplerVersion: FrameSampler.samplerVersion, dim: 2, count: 1),
                rows: [.init(time: 1.5, shotStart: 1, shotEnd: 2)], vectors: vector, key: key)
        }
        let originalHashes = try packageHashes(package)
        let externalHashes = try [a.id: FileDigest.sha256(of: a.url), b.id: FileDigest.sha256(of: b.url)]
        let document = try await VideoProject.load(from: package, agentService: AgentService(refreshBackendStatusOnInit: false))
        NSDocumentController.shared.addDocument(document); document.makeWindowControllers(); document.showWindows()
        guard let window = document.windowControllers.first?.window else { throw GateBlocked("The external search project has no window.") }
        window.setContentSize(NSSize(width: 960, height: 640)); window.makeKeyAndOrderFront(nil)
        let editor = document.editorViewModel, gate = QueryGate(), observation = Observation()
        var reopened: VideoProject?
        defer {
            gate.releaseAll()
            editor.searchIndex.momentQueryPublicationBarrier = nil
            editor.searchIndex.momentQueryTaskObserver = nil
            reopened?.close(); document.close(); parent.makeKeyAndOrderFront(nil)
        }
        editor.searchIndex.queryEncoderOverride = .init(spec: spec, encode: { $0 == "old-cut" ? [-1, 0] : [1, 0] })
        editor.searchIndex.momentQueryPublicationBarrier = { taskID, query, _, generation, result in
            await gate.hold(taskID, query: query, generation: generation, ready: result.status == .ready, hitIDs: result.hits.map(\.assetID))
        }
        editor.searchIndex.momentQueryTaskObserver = { taskID, query, root, generation, finished in
            if finished { observation.completed.append(taskID) }
            else { observation.started[taskID] = (query, root, generation) }
        }
        try await NativeEditingOwnerAcceptance.workspace(.edit, editor: editor, window: window, driver: driver)
        guard let oldRoot = editor.workingRoot, let oldGeneration = editor.openWorkingCopyGeneration else {
            throw GateBlocked("The external search project has no working-copy identity.")
        }
        try await driver.fill("media.search", value: "old-cut", in: window)
        try await driver.wait("old query has distinct real results pending publication") {
            gate.hasHeldResult(query: "old-cut", generation: oldGeneration, hitIDs: [b.id])
        }
        guard driver.text("media.search.results", in: window) == "searching" else { throw GateBlocked("The old query is not visibly searching.") }
        try driver.capture("search-before-save-as", target: window)
        try await AppNativeMenuAcceptance.choose(["File", "Save As…"], in: window, driver: driver)
        try await driver.saveFile(copy, in: window)
        try await driver.wait("search Save As changes project and generation", seconds: 30) {
            same(document.fileURL, copy) && editor.workingRoot != oldRoot && editor.openWorkingCopyGeneration != oldGeneration
        }
        guard let newGeneration = editor.openWorkingCopyGeneration, let copyID = ProjectIdentity.existingUUID(for: copy),
              copyID != originalID else { throw GateBlocked("Search Save As did not fork identity.") }
        try await driver.fill("media.search", value: "harbor", in: window)
        try await driver.wait("replacement query has distinct real results pending publication") {
            gate.hasHeldResult(query: "harbor", generation: newGeneration, hitIDs: [a.id])
        }
        let oldTaskIDs = Set(observation.started.compactMap { id, value in
            value.0 == "old-cut" && value.1 == oldRoot && value.2 == oldGeneration ? id : nil
        })
        try await driver.wait("every old task is completed before publication or held") {
            oldTaskIDs.isSubset(of: Set(observation.completed).union(gate.pendingIDs))
        }
        let heldOldTaskIDs = oldTaskIDs.intersection(gate.pendingIDs)
        guard !heldOldTaskIDs.isEmpty,
              gate.hasHeldResult(query: "old-cut", generation: oldGeneration, hitIDs: [b.id]) else {
            throw GateBlocked("No old-generation task with real B results is held.")
        }
        let completionCountBeforeRelease = observation.completed.count
        gate.release(heldOldTaskIDs)
        try await driver.wait("exact held old UI tasks have actually finished after release") {
            heldOldTaskIDs.isSubset(of: Set(observation.completed.dropFirst(completionCountBeforeRelease)))
        }
        guard driver.text("media.search.results", in: window) == "searching",
              WorkspaceUIAcceptance.probeFrame(identifier: "media.moment." + b.id + ".1.0", in: window) == nil else {
            throw GateBlocked("An old-project search published results or ended the current search.")
        }
        try driver.capture("search-copy-old-complete-current-busy", target: window)
        let heldCurrentTaskIDs = gate.pendingIDs.filter { id in
            observation.started[id]?.0 == "harbor" && observation.started[id]?.2 == newGeneration
        }
        guard !heldCurrentTaskIDs.isEmpty else { throw GateBlocked("No current query is held for release.") }
        let completionCountBeforeCurrentRelease = observation.completed.count
        gate.release("harbor")
        try await driver.wait("only current-generation search results settle") {
            heldCurrentTaskIDs.isSubset(of: Set(observation.completed.dropFirst(completionCountBeforeCurrentRelease)))
                && driver.text("media.search.results", in: window) == "settled"
                && driver.text("media.moment." + a.id + ".1.0", in: window) == "1.0...2.0"
        }
        guard WorkspaceUIAcceptance.probeFrame(identifier: "media.moment." + b.id + ".1.0", in: window) == nil,
              try packageHashes(package) == originalHashes, try mediaHashes(editor) == externalHashes,
              try readTimeline(copy) == timeline else { throw GateBlocked("Search Save As changed media, the original, or the saved timeline.") }
        try requireExternal(manifest: JSONDecoder().decode(MediaManifest.self,
            from: Data(contentsOf: copy.appendingPathComponent(Project.manifestFilename))), incoming: incoming)
        try driver.capture("search-copy-current-results", target: window)
        try await AppNativeMenuAcceptance.close(window, driver: driver)
        parent.makeKeyAndOrderFront(nil)
        try await AppNativeMenuAcceptance.choose(["File", "Open…"], in: parent, driver: driver)
        try await driver.chooseFile(copy, in: parent, trigger: nil, returnsToParent: false)
        try await driver.wait("native reopen of search copy", seconds: 30) { same(AppState.shared.activeProject?.fileURL, copy) }
        reopened = AppState.shared.activeProject
        guard let opened = reopened, let openedWindow = opened.windowControllers.first?.window,
              opened !== document, opened.editorViewModel.timeline == timeline,
              ProjectIdentity.existingUUID(for: copy) == copyID,
              try mediaHashes(opened.editorViewModel) == externalHashes,
              try packageHashes(package) == originalHashes else { throw GateBlocked("The reopened search copy lost external sources or identity.") }
        try driver.capture("search-copy-reopened", target: openedWindow)
        let result: [String: Any] = ["originalID": originalID, "copyID": copyID,
            "oldGeneration": oldGeneration.uuidString, "newGeneration": newGeneration.uuidString,
            "originalHashes": originalHashes, "externalHashes": externalHashes,
            "preparedResults": gate.results,
            "startedQueries": observation.started.map { id, value in
                ["taskID": id.uuidString, "query": value.0, "generation": value.2?.uuidString ?? ""]
            },
            "completedTaskIDs": observation.completed.map(\.uuidString),
            "releasedOldTaskIDs": heldOldTaskIDs.map(\.uuidString).sorted(),
            "completionCountBeforeRelease": completionCountBeforeRelease,
            "releasedCurrentTaskIDs": heldCurrentTaskIDs.map(\.uuidString).sorted(),
            "completionCountBeforeCurrentRelease": completionCountBeforeCurrentRelease,
            "oldQueryCompletedWhileCurrentHeld": true, "currentOnlySettled": true,
            "original": package.lastPathComponent, "copy": copy.lastPathComponent,
            "isolatedQueryEncoder": true, "liveSearchModel": false]
        try driver.record("search Save As external overlap", fields: result)
        return result
    }

    static func packageHashes(_ package: URL) throws -> [String: String] {
        guard let iterator = FileManager.default.enumerator(at: package, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            throw GateBlocked("The saved package cannot be enumerated.")
        }
        var hashes: [String: String] = [:]
        for case let file as URL in iterator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw GateBlocked("The acceptance package contains a symlink.") }
            if values.isRegularFile == true {
                hashes[String(file.path.dropFirst(package.path.count + 1))] = try FileDigest.sha256(of: file)
            }
        }
        return hashes
    }

    private static func mediaHashes(_ editor: EditorViewModel) throws -> [String: String] {
        var result: [String: String] = [:]
        for asset in editor.mediaAssets { result[asset.id] = try FileDigest.sha256(of: asset.url) }
        return result
    }

    private static func requireExternal(manifest: MediaManifest, incoming: URL) throws {
        guard Set(manifest.entries.map(\.id)) == ["external-a", "external-b"] else { throw GateBlocked("The copied external manifest changed IDs.") }
        for entry in manifest.entries {
            guard case .external(let path) = entry.source,
                  path == incoming.appendingPathComponent(entry.id == "external-a" ? "A.mov" : "B.mov").standardizedFileURL.resolvingSymlinksInPath().path else {
                throw GateBlocked("Save As changed the explicit external-media binding.")
            }
        }
    }

    private static func readTimeline(_ package: URL) throws -> Timeline {
        try JSONDecoder().decode(Timeline.self, from: Data(contentsOf: package.appendingPathComponent(Project.timelineFilename)))
    }

    private static func same(_ lhs: URL?, _ rhs: URL) -> Bool {
        lhs?.standardizedFileURL.resolvingSymlinksInPath() == rhs.standardizedFileURL.resolvingSymlinksInPath()
    }

    @MainActor private final class QueryGate {
        private var releasedQueries = Set<String>()
        private var pending: [UUID: CheckedContinuation<Void, Never>] = [:]
        private var queries: [UUID: String] = [:]
        private(set) var results: [[String: Any]] = []
        var pendingIDs: Set<UUID> { Set(pending.keys) }

        func hasHeldResult(query: String, generation: UUID, hitIDs: [String]) -> Bool {
            results.contains { value in
                guard let id = value["taskID"] as? String, let taskID = UUID(uuidString: id) else { return false }
                return pending[taskID] != nil && value["query"] as? String == query
                    && value["generation"] as? String == generation.uuidString
                    && value["ready"] as? Bool == true && value["hitIDs"] as? [String] == hitIDs.sorted()
            }
        }

        func hold(_ taskID: UUID, query: String, generation: UUID?, ready: Bool, hitIDs: [String]) async {
            guard query == "old-cut" || query == "harbor" else { return }
            results.append(["taskID": taskID.uuidString, "query": query,
                "generation": generation?.uuidString ?? "", "ready": ready, "hitIDs": hitIDs.sorted()])
            queries[taskID] = query
            guard !releasedQueries.contains(query) else { return }
            await withCheckedContinuation { pending[taskID] = $0 }
        }

        func release(_ taskIDs: Set<UUID>) {
            for id in taskIDs { pending.removeValue(forKey: id)?.resume() }
        }

        func release(_ query: String) {
            releasedQueries.insert(query)
            release(Set(queries.compactMap { $0.value == query ? $0.key : nil }))
        }

        func releaseAll() {
            release(Set(pending.keys))
        }
    }
}
