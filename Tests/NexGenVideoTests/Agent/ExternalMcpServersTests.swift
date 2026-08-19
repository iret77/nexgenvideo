import Foundation
import Testing
@testable import NexGenVideo

@MainActor
@Suite("External MCP server settings", .serialized)
struct ExternalMcpServersTests {
    @Test("Parser accepts every single-server input and never truncates a multi-server config")
    func parserAndMultiServerDetection() throws {
        let url = try parsed("https://mcp.example.com/mcp")
        #expect(url.entries.count == 1)

        let command = try parsed(#"ace-mcp --stdio "Project One""#)
        let commandJSON = try dictionary(command.entries[0].entryJSON)
        #expect(commandJSON["command"] as? String == "ace-mcp")
        #expect(commandJSON["args"] as? [String] == ["--stdio", "Project One"])

        let entry = try parsed(#"{"command":"tool","args":["serve"],"future":{"mode":2}}"#)
        #expect(try dictionary(entry.entries[0].entryJSON)["future"] != nil)

        let multiInput = #"{"mcpServers":{"zulu":{"url":"https://z.example/mcp"},"ace":{"command":"ace-mcp"}}}"#
        let multi = try parsed(multiInput)
        #expect(multi.entries.map(\.suggestedName) == ["ace", "zulu"])
        #expect(ExternalMcpServers.entryJSON(fromUserInput: multiInput) == nil)
        #expect(ExternalMcpServers.nameHint(fromUserInput: multiInput) == nil)
    }

    @Test("HTTP is limited to robust loopback hosts while remote HTTPS remains valid")
    func loopbackPolicy() throws {
        let accepted = [
            "http://localhost:21572/mcp",
            "http://localhost./mcp",
            "http://ace.localhost/mcp",
            "http://127.0.0.1/mcp",
            "http://127.42.9.3/mcp",
            "http://[::1]/mcp",
            "http://[0:0:0:0:0:0:0:1]/mcp",
            "https://mcp.example.com/mcp",
        ]
        for value in accepted {
            #expect(try parsed(value).entries.count == 1)
            #expect(try parsed(#"{"type":"http","url":"\#(value)"}"#).entries.count == 1)
        }

        let rejected = [
            "http://mcp.example.com/mcp",
            "http://127.0.0.1.example.com/mcp",
            "http://10.0.0.1/mcp",
        ]
        for value in rejected {
            guard case .failure(.insecureRemoteHTTP(_)) = ExternalMcpServers.parseUserInput(value) else {
                Issue.record("Expected remote HTTP rejection for \(value)")
                continue
            }
            guard case .failure(.insecureRemoteHTTP(_)) = ExternalMcpServers.parseUserInput(
                #"{"url":"\#(value)"}"#
            ) else {
                Issue.record("Expected JSON remote HTTP rejection for \(value)")
                continue
            }
        }
    }

    @Test("Legacy remote HTTP entries are quarantined during migration")
    func legacyRemoteHTTPIsFailClosed() {
        let harness = makeHarness()
        harness.defaults.set(
            ["remote": #"{"url":"http://mcp.example.com/private?token=legacy-secret"}"#],
            forKey: ExternalMcpServers.defaultsKey
        )

        let settings = ExternalMcpServers.settingsEntries(dependencies: harness.dependencies)

        #expect(settings.first?.status == .needsRepair)
        #expect(!ExternalMcpServers.rawEntries(dependencies: harness.dependencies).values.joined().contains("legacy-secret"))
        #expect(ExternalMcpServers.runtimeEntries(dependencies: harness.dependencies).isEmpty)
    }

    @Test("Multi-server import is atomic and stores complete entries only in the secret vault")
    func transactionalMultiImport() throws {
        let harness = makeHarness()
        let input = #"{"mcpServers":{"hosted":{"url":"https://user:password@mcp.example.com/private/token-path?api_key=url-secret","headers":{"Authorization":"Bearer header-secret"}},"local":{"command":"ace-mcp","args":["--token=arg-secret","Project One"],"env":{"API_TOKEN":"env-secret"}}}}"#
        let operation = try operation(input: input, existingNames: [])
        let trust = try #require(ExternalMcpServers.trustRequest(for: operation, dependencies: harness.dependencies))
        #expect(trust.commands.map(\.executable) == ["ace-mcp"])

        #expect(throws: ExternalMcpServers.ValidationError.trustRequired) {
            try ExternalMcpServers.apply(
                operation,
                trustingStdio: false,
                dependencies: harness.dependencies
            )
        }
        #expect(ExternalMcpServers.rawEntries(dependencies: harness.dependencies).isEmpty)
        #expect(harness.vault.values.isEmpty)

        try ExternalMcpServers.apply(
            operation,
            trustingStdio: true,
            dependencies: harness.dependencies
        )

        let stored = ExternalMcpServers.rawEntries(dependencies: harness.dependencies)
        #expect(stored.keys.sorted() == ["hosted", "local"])
        let defaultsText = stored.values.joined()
        for secret in ["password", "url-secret", "header-secret", "arg-secret", "env-secret"] {
            #expect(!defaultsText.contains(secret))
        }
        for descriptor in stored.values {
            let keys = Set(try dictionary(descriptor).keys)
            #expect(keys.isSubset(of: Set(["account", "payloadKind", "storage", "stdioTrusted"])))
            #expect(!keys.contains("trustedStdioDigest"))
        }
        #expect(harness.vault.values.values.contains { $0.contains("header-secret") })
        #expect(harness.vault.values.values.contains { $0.contains("env-secret") })
        #expect(ExternalMcpServers.runtimeEntries(dependencies: harness.dependencies).keys.sorted() == ["hosted", "local"])

        let settings = ExternalMcpServers.settingsEntries(dependencies: harness.dependencies)
        let previews = settings.map(\.preview).joined(separator: " ")
        for secret in ["password", "token-path", "url-secret", "header-secret", "arg-secret", "env-secret", "Project One"] {
            #expect(!previews.contains(secret))
        }
        #expect(previews.contains("https://mcp.example.com/••••"))
        #expect(previews.contains("ace-mcp --token=•••• ••••"))
    }

    @Test("Batch validation rejects conflicts and reserved names before any mutation")
    func batchNameValidation() throws {
        let harness = makeHarness()
        let existing = try operation(input: "https://existing.example/mcp", name: "existing")
        try ExternalMcpServers.apply(existing, trustingStdio: false, dependencies: harness.dependencies)
        let before = ExternalMcpServers.rawEntries(dependencies: harness.dependencies)
        let vaultBefore = harness.vault.values

        let conflictInput = #"{"mcpServers":{"new":{"url":"https://new.example/mcp"},"Existing":{"url":"https://other.example/mcp"}}}"#
        guard case .failure(.duplicateName("Existing")) = ExternalMcpServers.makeOperation(
            input: conflictInput,
            manualName: "",
            existingNames: Set(before.keys),
            editingOriginalName: nil,
            canPreserveOriginal: false
        ) else {
            Issue.record("Expected case-insensitive name conflict")
            return
        }

        let reservedInput = #"{"mcpServers":{"nexgen":{"url":"https://new.example/mcp"},"safe":{"url":"https://safe.example/mcp"}}}"#
        guard case .failure(.reservedName("nexgen")) = ExternalMcpServers.makeOperation(
            input: reservedInput,
            manualName: "",
            existingNames: Set(before.keys),
            editingOriginalName: nil,
            canPreserveOriginal: false
        ) else {
            Issue.record("Expected reserved-name rejection")
            return
        }

        #expect(ExternalMcpServers.rawEntries(dependencies: harness.dependencies) == before)
        #expect(harness.vault.values == vaultBefore)
    }

    @Test("A failed secret write rolls back the entire batch")
    func secretFailureRollsBackBatch() throws {
        let harness = makeHarness()
        harness.vault.writeThenFailOnSaveNumber = 2
        let operation = try operation(
            input: #"{"mcpServers":{"first":{"url":"https://first.example/mcp"},"second":{"url":"https://second.example/mcp"}}}"#
        )

        #expect(throws: ExternalMcpServers.ValidationError.secureStorageUnavailable) {
            try ExternalMcpServers.apply(
                operation,
                trustingStdio: false,
                dependencies: harness.dependencies
            )
        }
        #expect(ExternalMcpServers.rawEntries(dependencies: harness.dependencies).isEmpty)
        #expect(harness.vault.values.isEmpty)
        #expect(harness.vault.deletedAccounts == ["external-mcp.test-account-1", "external-mcp.test-account-2"])
    }

    @Test("Legacy migration verifies every vault write before replacing UserDefaults")
    func legacyMigrationAndRedaction() {
        let harness = makeHarness()
        let validHTTP = #" { "url" : "https://user:pass@mcp.example.com/private?token=legacy-secret" } "#
        let validStdio = #"{"command":"legacy-mcp","args":["--token=stdio-secret"],"env":{"TOKEN":"env-secret"},"future":{"kept":true}}"#
        let invalid = "  {\n  \"futureSecret\": \"unknown-secret\"\n}  "
        harness.defaults.set(
            ["hosted": validHTTP, "local": validStdio, "future": invalid],
            forKey: ExternalMcpServers.defaultsKey
        )

        let settings = ExternalMcpServers.settingsEntries(dependencies: harness.dependencies)
        let stored = ExternalMcpServers.rawEntries(dependencies: harness.dependencies)
        let defaultsText = stored.values.joined()
        for secret in ["legacy-secret", "stdio-secret", "env-secret", "unknown-secret"] {
            #expect(!defaultsText.contains(secret))
        }
        #expect(Set(harness.vault.values.values) == Set([validHTTP, validStdio, invalid]))
        #expect(settings.first { $0.name == "hosted" }?.status == .ready)
        #expect(settings.first { $0.name == "local" }?.status == .trustRequired)
        #expect(settings.first { $0.name == "future" }?.status == .needsRepair)
        #expect(ExternalMcpServers.runtimeEntries(dependencies: harness.dependencies).keys.sorted() == ["hosted"])
    }

    @Test("Migration failure leaves every legacy byte in place and removes staged secrets")
    func migrationFailureIsTransactional() {
        let harness = makeHarness()
        harness.vault.writeThenFailOnSaveNumber = 2
        let legacy = [
            "one": #"{"url":"https://one.example/mcp?token=one"}"#,
            "two": #"{"future":"two"}"#,
        ]
        harness.defaults.set(legacy, forKey: ExternalMcpServers.defaultsKey)

        _ = ExternalMcpServers.settingsEntries(dependencies: harness.dependencies)

        #expect(ExternalMcpServers.rawEntries(dependencies: harness.dependencies) == legacy)
        #expect(harness.vault.values.isEmpty)
        #expect(harness.vault.deletedAccounts == ["external-mcp.test-account-1", "external-mcp.test-account-2"])
        #expect(ExternalMcpServers.runtimeEntries(dependencies: harness.dependencies).isEmpty)
    }

    @Test("Conflicting transport fields cannot bypass stdio trust")
    func conflictingTransportIsRejected() {
        let conflicting = #"{"type":"http","url":"https://safe.example/mcp","command":"untrusted-tool","args":["--stdio"]}"#
        guard case .failure(.invalidEntry(_)) = ExternalMcpServers.parseUserInput(conflicting) else {
            Issue.record("Expected conflicting transport rejection")
            return
        }

        let harness = makeHarness()
        harness.defaults.set(["conflicting": conflicting], forKey: ExternalMcpServers.defaultsKey)

        let settings = ExternalMcpServers.settingsEntries(dependencies: harness.dependencies)

        #expect(settings.first?.status == .needsRepair)
        #expect(ExternalMcpServers.runtimeEntries(dependencies: harness.dependencies).isEmpty)
        #expect(harness.vault.values.values.contains(conflicting))
    }

    @Test("Descriptor lookalikes with extra fields are migrated as opaque secret-bearing legacy data")
    func descriptorLookalikeIsNotTrusted() {
        let harness = makeHarness()
        let lookalike = #"{"account":"external-mcp.fake","headers":{"Authorization":"Bearer descriptor-secret"},"storage":"nexgen-keychain-v1"}"#
        harness.defaults.set(
            ["lookalike": lookalike],
            forKey: ExternalMcpServers.defaultsKey
        )

        let settings = ExternalMcpServers.settingsEntries(dependencies: harness.dependencies)
        let stored = ExternalMcpServers.rawEntries(dependencies: harness.dependencies)

        #expect(!stored.values.joined().contains("descriptor-secret"))
        #expect(harness.vault.values.values.contains(lookalike))
        #expect(settings.first?.status == .needsRepair)
        #expect(ExternalMcpServers.runtimeEntries(dependencies: harness.dependencies).isEmpty)
    }

    @Test("Descriptors cannot address or delete another Keychain namespace")
    func descriptorAccountNamespaceIsIsolated() {
        let harness = makeHarness()
        let providerAccount = "provider.fal.api-key"
        harness.vault.values[providerAccount] = "provider-secret"
        harness.defaults.set(
            ["lookalike": #"{"account":"provider.fal.api-key","storage":"nexgen-keychain-v1"}"#],
            forKey: ExternalMcpServers.defaultsKey
        )

        let settings = ExternalMcpServers.settingsEntries(dependencies: harness.dependencies)
        ExternalMcpServers.remove(name: "lookalike", dependencies: harness.dependencies)

        #expect(settings.first?.status == .needsRepair)
        #expect(harness.vault.values[providerAccount] == "provider-secret")
        #expect(!harness.vault.deletedAccounts.contains(providerAccount))
    }

    @Test("Unrelated invalid and future entries survive add, replace, and remove operations")
    func rawPreservingReadModifyWrite() throws {
        let harness = makeHarness()
        let future = "  {\"future\":{\"secret\":\"opaque\"}}  "
        let legacy = [
            "future": future,
            "broken": #"{"args":["unknown"]}"#,
            "valid": #"{"url":"https://valid.example/mcp","futureField":{"v":1}}"#,
        ]
        harness.defaults.set(legacy, forKey: ExternalMcpServers.defaultsKey)
        _ = ExternalMcpServers.settingsEntries(dependencies: harness.dependencies)
        let migrated = ExternalMcpServers.rawEntries(dependencies: harness.dependencies)
        let futureDescriptor = try #require(migrated["future"])
        let brokenDescriptor = try #require(migrated["broken"])
        #expect(harness.vault.values.values.contains(future))

        let add = try operation(input: "https://added.example/mcp", name: "added", existingNames: Set(migrated.keys))
        try ExternalMcpServers.apply(add, trustingStdio: false, dependencies: harness.dependencies)
        var current = ExternalMcpServers.rawEntries(dependencies: harness.dependencies)
        #expect(current["future"] == futureDescriptor)
        #expect(current["broken"] == brokenDescriptor)

        let replace = try operation(
            input: "https://replacement.example/mcp",
            name: "renamed",
            existingNames: Set(current.keys),
            editingOriginal: "valid",
            canPreserve: true
        )
        try ExternalMcpServers.apply(replace, trustingStdio: false, dependencies: harness.dependencies)
        current = ExternalMcpServers.rawEntries(dependencies: harness.dependencies)
        #expect(current["future"] == futureDescriptor)
        #expect(current["broken"] == brokenDescriptor)

        ExternalMcpServers.remove(name: "added", dependencies: harness.dependencies)
        current = ExternalMcpServers.rawEntries(dependencies: harness.dependencies)
        #expect(current["future"] == futureDescriptor)
        #expect(current["broken"] == brokenDescriptor)
        #expect(harness.vault.values.values.contains(future))
    }

    @Test("Unknown property-list entries move losslessly to the vault and survive mutation")
    func unknownStoredValuesArePreserved() throws {
        let harness = makeHarness()
        let legacy = #"{"url":"https://legacy.example/mcp?token=legacy-secret"}"#
        let future: [String: Any] = [
            "headers": ["Authorization": "Bearer future-secret"],
            "data": Data([0, 1, 2, 255]),
        ]
        harness.defaults.set(
            ["legacy": legacy, "future": future] as [String: Any],
            forKey: ExternalMcpServers.defaultsKey
        )

        let settings = ExternalMcpServers.settingsEntries(dependencies: harness.dependencies)
        let stored = try #require(harness.defaults.dictionary(forKey: ExternalMcpServers.defaultsKey))
        let futureDescriptor = try #require(stored["future"] as? String)
        let opaquePayload = try #require(
            harness.vault.values.values.first { $0.hasPrefix("nexgen-property-list-v1:") }
        )
        let encoded = String(opaquePayload.dropFirst("nexgen-property-list-v1:".count))
        let data = try #require(Data(base64Encoded: encoded))
        let propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let archive = try #require(propertyList as? [String: Any])
        let restored = try #require(archive["value"] as? [String: Any])
        let restoredHeaders = try #require(restored["headers"] as? [String: String])

        #expect(!futureDescriptor.contains("future-secret"))
        #expect((stored["legacy"] as? String)?.contains("legacy-secret") == false)
        #expect(harness.vault.values.values.contains(legacy))
        #expect(restoredHeaders["Authorization"] == "Bearer future-secret")
        #expect(restored["data"] as? Data == Data([0, 1, 2, 255]))
        #expect(settings.first { $0.name == "future" }?.status == .needsRepair)

        let add = try operation(
            input: "https://added.example/mcp",
            name: "added",
            existingNames: Set(settings.map(\.name))
        )
        try ExternalMcpServers.apply(add, trustingStdio: false, dependencies: harness.dependencies)

        let afterAdd = try #require(harness.defaults.dictionary(forKey: ExternalMcpServers.defaultsKey))
        #expect(afterAdd["future"] as? String == futureDescriptor)

        let replace = try operation(
            input: "https://replacement.example/mcp",
            name: "legacy",
            existingNames: ["added", "future", "legacy"],
            editingOriginal: "legacy",
            canPreserve: true
        )
        try ExternalMcpServers.apply(replace, trustingStdio: false, dependencies: harness.dependencies)
        ExternalMcpServers.remove(name: "added", dependencies: harness.dependencies)

        let afterMutations = try #require(harness.defaults.dictionary(forKey: ExternalMcpServers.defaultsKey))
        #expect(afterMutations["future"] as? String == futureDescriptor)
        #expect(harness.vault.values.values.contains(opaquePayload))
        #expect(ExternalMcpServers.runtimeEntries(dependencies: harness.dependencies).keys.sorted() == ["legacy"])
    }

    @Test("Rename, replacement, and deletion manage Keychain references correctly")
    func keychainLifecycle() throws {
        let harness = makeHarness()
        let add = try operation(input: "https://one.example/mcp", name: "one")
        try ExternalMcpServers.apply(add, trustingStdio: false, dependencies: harness.dependencies)
        let originalDescriptor = try #require(
            ExternalMcpServers.rawEntries(dependencies: harness.dependencies)["one"]
        )
        #expect(harness.vault.values.keys.sorted() == ["external-mcp.test-account-1"])

        let rename = try operation(
            input: "",
            name: "renamed",
            existingNames: ["one"],
            editingOriginal: "one",
            canPreserve: true
        )
        try ExternalMcpServers.apply(rename, trustingStdio: false, dependencies: harness.dependencies)
        #expect(ExternalMcpServers.rawEntries(dependencies: harness.dependencies)["renamed"] == originalDescriptor)
        #expect(harness.vault.deletedAccounts.isEmpty)

        let replace = try operation(
            input: "https://two.example/mcp",
            name: "renamed",
            existingNames: ["renamed"],
            editingOriginal: "renamed",
            canPreserve: true
        )
        try ExternalMcpServers.apply(replace, trustingStdio: false, dependencies: harness.dependencies)
        #expect(harness.vault.deletedAccounts == ["external-mcp.test-account-1"])
        #expect(harness.vault.values.keys.sorted() == ["external-mcp.test-account-2"])

        ExternalMcpServers.remove(name: "renamed", dependencies: harness.dependencies)
        #expect(harness.vault.values.isEmpty)
        #expect(harness.vault.deletedAccounts == ["external-mcp.test-account-1", "external-mcp.test-account-2"])
    }

    @Test("Stdio trust is required once for new or changed commands, never for HTTP")
    func trustLifecycle() throws {
        let harness = makeHarness()
        let add = try operation(input: #"{"command":"ace-mcp","args":["--stdio","Project One"]}"#, name: "ace")
        let request = try #require(ExternalMcpServers.trustRequest(for: add, dependencies: harness.dependencies))
        #expect(request.message.contains("Executable: ace-mcp"))
        #expect(request.message.contains("Arguments: --stdio ••••"))
        #expect(request.message.contains("without approval for each call"))

        try ExternalMcpServers.apply(add, trustingStdio: true, dependencies: harness.dependencies)
        #expect(ExternalMcpServers.runtimeEntries(dependencies: harness.dependencies).keys.sorted() == ["ace"])

        let unchanged = try operation(
            input: "",
            name: "ace",
            existingNames: ["ace"],
            editingOriginal: "ace",
            canPreserve: true
        )
        #expect(ExternalMcpServers.trustRequest(for: unchanged, dependencies: harness.dependencies) == nil)
        try ExternalMcpServers.apply(unchanged, trustingStdio: false, dependencies: harness.dependencies)

        let changed = try operation(
            input: #"{"command":"ace-mcp","args":["--stdio","Project Two"]}"#,
            name: "ace",
            existingNames: ["ace"],
            editingOriginal: "ace",
            canPreserve: true
        )
        #expect(ExternalMcpServers.trustRequest(for: changed, dependencies: harness.dependencies) != nil)

        let http = try operation(input: "https://mcp.example.com/mcp", name: "http", existingNames: ["ace"])
        #expect(ExternalMcpServers.trustRequest(for: http, dependencies: harness.dependencies) == nil)
    }

    @Test("Migrated stdio stays blocked until explicitly trusted, then is not asked again")
    func migratedStdioTrust() throws {
        let harness = makeHarness()
        harness.defaults.set(
            ["legacy": #"{"command":"legacy-mcp","args":["--stdio"]}"#],
            forKey: ExternalMcpServers.defaultsKey
        )
        let settings = ExternalMcpServers.settingsEntries(dependencies: harness.dependencies)
        let entry = try #require(settings.first)
        #expect(entry.status == .trustRequired)
        #expect(ExternalMcpServers.runtimeEntries(dependencies: harness.dependencies).isEmpty)

        var editor = ExternalMcpServerEditorState()
        editor.beginEditing(entry)
        let operation = try editor.operation(existingNames: ["legacy"]).get()
        #expect(ExternalMcpServers.trustRequest(for: operation, dependencies: harness.dependencies) != nil)
        try ExternalMcpServers.apply(operation, trustingStdio: true, dependencies: harness.dependencies)
        #expect(ExternalMcpServers.runtimeEntries(dependencies: harness.dependencies).keys.sorted() == ["legacy"])
        #expect(ExternalMcpServers.trustRequest(for: operation, dependencies: harness.dependencies) == nil)
    }

    @Test("Migrated reserved names never reach runtime and require repair")
    func migratedReservedNamesAreFailClosed() {
        for reservedName in ["nexgen", "NeXGen"] {
            let harness = makeHarness()
            harness.defaults.set(
                [reservedName: #"{"url":"https://shadow.example/mcp"}"#],
                forKey: ExternalMcpServers.defaultsKey
            )

            let settings = ExternalMcpServers.settingsEntries(dependencies: harness.dependencies)

            #expect(settings == [ExternalMcpServers.SettingsEntry(
                name: reservedName,
                preview: "https://shadow.example",
                status: .needsRepair,
                canPreserveConfiguration: true
            )])
            #expect(ExternalMcpServers.runtimeEntries(dependencies: harness.dependencies).isEmpty)
        }
    }

    @Test("Editor exposes multi-import, inline failures, repair, and secret-preserving edit state")
    func editorState() throws {
        var editor = ExternalMcpServerEditorState()
        editor.beginAdding()
        editor.connection = #"{"mcpServers":{"one":{"url":"https://one.example/mcp"},"two":{"url":"https://two.example/mcp"}}}"#
        #expect(editor.importsMultipleServers)
        #expect(editor.importCount == 2)
        guard case .success(.add(let entries)) = editor.operation(existingNames: []) else {
            Issue.record("Expected multi-server add operation")
            return
        }
        #expect(entries.map(\.name) == ["one", "two"])

        editor.connection = "http://remote.example/mcp"
        #expect(editor.validationMessage(existingNames: [])?.contains("Use HTTPS") == true)

        let ready = ExternalMcpServers.SettingsEntry(
            name: "ready",
            preview: "https://example.com",
            status: .ready
        )
        editor.beginEditing(ready)
        #expect(editor.connection.isEmpty)
        #expect(editor.validationMessage(existingNames: ["ready"]) == nil)

        let broken = ExternalMcpServers.SettingsEntry(
            name: "broken",
            preview: "Configuration needs repair.",
            status: .needsRepair
        )
        editor.beginEditing(broken)
        #expect(editor.validationMessage(existingNames: ["broken"]) == "Enter a server URL, command, or JSON configuration.")
    }

    @Test("Previews redact URL, header, environment, and argument secrets")
    func previewRedaction() {
        let http = ExternalMcpServers.commandPreview(
            entryJSON: #"{"url":"https://user:password@example.com/private/token?api_key=query-secret","headers":{"Authorization":"Bearer header-secret"}}"#
        )
        #expect(http == "https://example.com/••••")

        let stdio = ExternalMcpServers.commandPreview(
            entryJSON: #"{"command":"tool","args":["--token=arg-secret","positional-secret","--stdio","-pcompact-secret","--token:colon-secret","-y"],"env":{"TOKEN":"env-secret"}}"#
        )
        #expect(stdio == "tool --token=•••• •••• --stdio •••• •••• -y")
        for secret in ["password", "query-secret", "header-secret", "arg-secret", "positional-secret", "compact-secret", "colon-secret", "env-secret"] {
            #expect(!http.contains(secret))
            #expect(!stdio.contains(secret))
        }
    }

    private func parsed(_ input: String) throws -> ExternalMcpServers.ParsedInput {
        try ExternalMcpServers.parseUserInput(input).get()
    }

    private func operation(
        input: String,
        name: String = "",
        existingNames: Set<String> = [],
        editingOriginal: String? = nil,
        canPreserve: Bool = false
    ) throws -> ExternalMcpServers.SaveOperation {
        try ExternalMcpServers.makeOperation(
            input: input,
            manualName: name,
            existingNames: existingNames,
            editingOriginalName: editingOriginal,
            canPreserveOriginal: canPreserve
        ).get()
    }

    private func dictionary(_ json: String) throws -> [String: Any] {
        try #require(
            (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        )
    }

    private func makeHarness() -> Harness {
        let suiteName = "ExternalMcpServersTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let vault = MemoryVault()
        let accounts = AccountFactory()
        let dependencies = ExternalMcpServers.Dependencies(
            defaults: defaults,
            vault: ExternalMcpServers.SecretVault(
                save: { vault.save($0, account: $1) },
                load: { vault.values[$0] },
                delete: { vault.delete($0) }
            ),
            makeAccount: { accounts.next() }
        )
        return Harness(
            suiteName: suiteName,
            defaults: defaults,
            vault: vault,
            dependencies: dependencies
        )
    }

    private struct Harness {
        let suiteName: String
        let defaults: UserDefaults
        let vault: MemoryVault
        let dependencies: ExternalMcpServers.Dependencies
    }

    private final class AccountFactory {
        private var counter = 0

        func next() -> String {
            counter += 1
            return "external-mcp.test-account-\(counter)"
        }
    }

    private final class MemoryVault {
        var values: [String: String] = [:]
        var deletedAccounts: [String] = []
        var failOnSaveNumber: Int?
        var writeThenFailOnSaveNumber: Int?
        private var saveCount = 0

        func save(_ value: String, account: String) -> Bool {
            saveCount += 1
            if let writeThenFailOnSaveNumber, saveCount >= writeThenFailOnSaveNumber {
                values[account] = value
                return false
            }
            if let failOnSaveNumber, saveCount >= failOnSaveNumber {
                return false
            }
            values[account] = value
            return true
        }

        func delete(_ account: String) {
            values.removeValue(forKey: account)
            deletedAccounts.append(account)
        }
    }
}
