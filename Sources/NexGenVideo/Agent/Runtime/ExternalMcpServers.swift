import Foundation

@MainActor
enum ExternalMcpServers {
    static let defaultsKey = "externalMcpServers"

    struct SecretVault {
        let save: (_ value: String, _ account: String) -> Bool
        let load: (_ account: String) -> String?
        let delete: (_ account: String) -> Void

        static var keychain: SecretVault {
            SecretVault(
                save: { value, account in
                    let encoded = Data(value.utf8).base64EncodedString()
                    KeychainStore.save(encoded, account: account)
                    guard let stored = KeychainStore.load(account: account),
                          let data = Data(base64Encoded: stored),
                          String(data: data, encoding: .utf8) == value
                    else { return false }
                    return true
                },
                load: { account in
                    guard let encoded = KeychainStore.load(account: account),
                          let data = Data(base64Encoded: encoded)
                    else { return nil }
                    return String(data: data, encoding: .utf8)
                },
                delete: { KeychainStore.delete(account: $0) }
            )
        }
    }

    struct Dependencies {
        let defaults: UserDefaults
        let vault: SecretVault
        let makeAccount: () -> String

        static var live: Dependencies {
            Dependencies(
                defaults: .standard,
                vault: .keychain,
                makeAccount: { "external-mcp.\(UUID().uuidString.lowercased())" }
            )
        }
    }

    enum EntryStatus: Equatable {
        case ready
        case trustRequired
        case needsRepair
    }

    struct SettingsEntry: Identifiable, Equatable {
        let name: String
        let preview: String
        let status: EntryStatus
        let canPreserveConfiguration: Bool

        init(
            name: String,
            preview: String,
            status: EntryStatus,
            canPreserveConfiguration: Bool? = nil
        ) {
            self.name = name
            self.preview = preview
            self.status = status
            self.canPreserveConfiguration = canPreserveConfiguration ?? (status != .needsRepair)
        }

        var id: String { name }
    }

    struct ParsedEntry: Equatable {
        let suggestedName: String?
        let entryJSON: String
    }

    struct ParsedInput: Equatable {
        let entries: [ParsedEntry]
        let usesEmbeddedNames: Bool
    }

    struct NamedEntry: Equatable {
        let name: String
        let entryJSON: String
    }

    enum SaveOperation: Equatable {
        case add([NamedEntry])
        case replace(originalName: String, entry: NamedEntry)
        case rename(originalName: String, newName: String)
    }

    struct StdioCommand: Equatable {
        let executable: String
        let redactedArguments: String
    }

    struct TrustRequest: Equatable {
        let commands: [StdioCommand]

        var message: String {
            let details = commands.map { command in
                "Executable: \(command.executable)\nArguments: \(command.redactedArguments)"
            }.joined(separator: "\n\n")
            return "\(details)\n\nNexGenVideo will run this local software in new Claude Code sessions. Its MCP tools can be used without approval for each call."
        }
    }

    enum ValidationError: Error, Equatable, LocalizedError {
        case missingName
        case invalidName(String)
        case reservedName(String)
        case duplicateName(String)
        case missingConnection
        case invalidJSON
        case invalidEntry(String?)
        case insecureRemoteHTTP(String)
        case multipleServersDuringEdit
        case secureStorageUnavailable
        case originalMissing(String)
        case trustRequired

        var errorDescription: String? {
            switch self {
            case .missingName:
                return "Enter a server name."
            case .invalidName:
                return "Use letters, numbers, periods, hyphens, or underscores for the name."
            case .reservedName(let name):
                return "The name “\(name)” is reserved for NexGenVideo."
            case .duplicateName(let name):
                return "A server named “\(name)” already exists."
            case .missingConnection:
                return "Enter a server URL, command, or JSON configuration."
            case .invalidJSON:
                return "Enter valid MCP JSON."
            case .invalidEntry(let name):
                if let name { return "The configuration for “\(name)” is incomplete or invalid." }
                return "Enter a valid HTTP URL, command, MCP entry, or mcpServers JSON configuration."
            case .insecureRemoteHTTP(let host):
                return "Use HTTPS for the remote server “\(host)”. HTTP is allowed only for loopback servers."
            case .multipleServersDuringEdit:
                return "Edit one server at a time. Add the configuration separately to import multiple servers."
            case .secureStorageUnavailable:
                return "The configuration could not be stored securely in the macOS Keychain."
            case .originalMissing(let name):
                return "The stored server “\(name)” is no longer available."
            case .trustRequired:
                return "Confirm trust before saving this local MCP command."
            }
        }
    }

    private struct SecureReference: Codable, Equatable {
        let storage: String
        let account: String
        let payloadKind: PayloadKind?
        var stdioTrusted: Bool?

        init(
            account: String,
            payloadKind: PayloadKind? = nil,
            stdioTrusted: Bool? = nil
        ) {
            storage = "nexgen-keychain-v1"
            self.account = account
            self.payloadKind = payloadKind
            self.stdioTrusted = stdioTrusted
        }

        var isSupported: Bool {
            storage == "nexgen-keychain-v1"
                && account.hasPrefix("external-mcp.")
                && account.count > "external-mcp.".count
        }

        var containsEntryJSON: Bool { payloadKind == nil || payloadKind == .entryJSON }
    }

    private enum PayloadKind: String, Codable {
        case entryJSON = "entry-json"
        case opaquePropertyList = "opaque-property-list-v1"
    }

    static func all(dependencies: Dependencies = .live) -> [String: String] {
        runtimeEntries(dependencies: dependencies)
    }

    static func runtimeEntries(dependencies: Dependencies = .live) -> [String: String] {
        _ = migrateLegacyEntries(dependencies: dependencies)
        var result: [String: String] = [:]
        for (name, value) in storedEntries(dependencies: dependencies) {
            guard isValidName(name),
                  !isReservedName(name),
                  let storedValue = value as? String,
                  let reference = secureReference(from: storedValue),
                  reference.containsEntryJSON,
                  let entryJSON = dependencies.vault.load(reference.account),
                  validatedStoredEntry(entryJSON) != nil
            else { continue }
            if stdioCommand(entryJSON: entryJSON) != nil {
                guard reference.stdioTrusted == true else { continue }
            }
            result[name] = entryJSON
        }
        return result
    }

    static func settingsEntries(dependencies: Dependencies = .live) -> [SettingsEntry] {
        _ = migrateLegacyEntries(dependencies: dependencies)
        return storedEntries(dependencies: dependencies).map { name, value in
            let nameNeedsRepair = !isValidName(name) || isReservedName(name)
            guard let storedValue = value as? String else {
                return SettingsEntry(
                    name: name,
                    preview: "Configuration needs repair.",
                    status: .needsRepair
                )
            }
            if let reference = secureReference(from: storedValue) {
                guard let payload = dependencies.vault.load(reference.account) else {
                    return SettingsEntry(
                        name: name,
                        preview: "Secure configuration is unavailable. Replace or remove it.",
                        status: .needsRepair
                    )
                }
                guard reference.containsEntryJSON,
                      validatedStoredEntry(payload) != nil
                else {
                    return SettingsEntry(
                        name: name,
                        preview: "Configuration needs repair.",
                        status: .needsRepair
                    )
                }
                let entryJSON = payload
                let status: EntryStatus
                if nameNeedsRepair {
                    status = .needsRepair
                } else if stdioCommand(entryJSON: entryJSON) != nil,
                   reference.stdioTrusted != true {
                    status = .trustRequired
                } else {
                    status = .ready
                }
                return SettingsEntry(
                    name: name,
                    preview: commandPreview(entryJSON: entryJSON),
                    status: status,
                    canPreserveConfiguration: true
                )
            }
            return SettingsEntry(
                name: name,
                preview: legacyPreview(storedValue),
                status: .needsRepair
            )
        }.sorted { left, right in
            left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
    }

    static func parseUserInput(_ input: String) -> Result<ParsedInput, ValidationError> {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.missingConnection) }
        do {
            let lowercased = trimmed.lowercased()
            if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") {
                try validateHTTPURL(trimmed)
                let entryJSON = try compact(["type": "http", "url": trimmed])
                return .success(ParsedInput(
                    entries: [ParsedEntry(suggestedName: nil, entryJSON: entryJSON)],
                    usesEmbeddedNames: false
                ))
            }
            if trimmed.hasPrefix("{") {
                guard let data = trimmed.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data),
                      let dictionary = object as? [String: Any]
                else { return .failure(.invalidJSON) }
                if dictionary.keys.contains("mcpServers") {
                    guard let servers = dictionary["mcpServers"] as? [String: Any], !servers.isEmpty else {
                        return .failure(.invalidEntry(nil))
                    }
                    let entries = try servers.keys.sorted().map { name -> ParsedEntry in
                        guard let entry = servers[name] as? [String: Any] else {
                            throw ValidationError.invalidEntry(name)
                        }
                        return ParsedEntry(
                            suggestedName: name,
                            entryJSON: try validatedEntryJSON(entry, name: name)
                        )
                    }
                    return .success(ParsedInput(entries: entries, usesEmbeddedNames: true))
                }
                return .success(ParsedInput(
                    entries: [ParsedEntry(
                        suggestedName: nil,
                        entryJSON: try validatedEntryJSON(dictionary, name: nil)
                    )],
                    usesEmbeddedNames: false
                ))
            }
            guard let parts = shellSplitValidated(trimmed), let command = parts.first else {
                return .failure(.invalidEntry(nil))
            }
            var entry: [String: Any] = ["command": command]
            if parts.count > 1 { entry["args"] = Array(parts.dropFirst()) }
            return .success(ParsedInput(
                entries: [ParsedEntry(suggestedName: nil, entryJSON: try compact(entry))],
                usesEmbeddedNames: false
            ))
        } catch let error as ValidationError {
            return .failure(error)
        } catch {
            return .failure(.invalidEntry(nil))
        }
    }

    static func entryJSON(fromUserInput input: String) -> String? {
        guard case .success(let parsed) = parseUserInput(input), parsed.entries.count == 1 else { return nil }
        return parsed.entries[0].entryJSON
    }

    static func nameHint(fromUserInput input: String) -> String? {
        guard case .success(let parsed) = parseUserInput(input),
              parsed.entries.count == 1,
              parsed.usesEmbeddedNames
        else { return nil }
        return parsed.entries[0].suggestedName
    }

    static func makeOperation(
        input: String,
        manualName: String,
        existingNames: Set<String>,
        editingOriginalName: String?,
        canPreserveOriginal: Bool
    ) -> Result<SaveOperation, ValidationError> {
        let normalizedName = manualName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedInput.isEmpty, let originalName = editingOriginalName, canPreserveOriginal {
            do {
                try validateNames(
                    [normalizedName],
                    existingNames: existingNames,
                    excluding: originalName
                )
                return .success(.rename(originalName: originalName, newName: normalizedName))
            } catch let error as ValidationError {
                return .failure(error)
            } catch {
                return .failure(.invalidEntry(nil))
            }
        }
        guard !normalizedInput.isEmpty else {
            return .failure(normalizedName.isEmpty ? .missingName : .missingConnection)
        }
        switch parseUserInput(normalizedInput) {
        case .failure(let error):
            return .failure(error)
        case .success(let parsed):
            if editingOriginalName != nil, parsed.entries.count != 1 {
                return .failure(.multipleServersDuringEdit)
            }
            var named: [NamedEntry] = []
            if parsed.entries.count > 1 {
                named = parsed.entries.compactMap { entry in
                    entry.suggestedName.map { NamedEntry(name: $0, entryJSON: entry.entryJSON) }
                }
                guard named.count == parsed.entries.count else { return .failure(.missingName) }
            } else if let entry = parsed.entries.first {
                let targetName = normalizedName.isEmpty ? (entry.suggestedName ?? "") : normalizedName
                named = [NamedEntry(name: targetName, entryJSON: entry.entryJSON)]
            }
            do {
                try validateNames(
                    named.map(\.name),
                    existingNames: existingNames,
                    excluding: editingOriginalName
                )
            } catch let error as ValidationError {
                return .failure(error)
            } catch {
                return .failure(.invalidEntry(nil))
            }
            if let originalName = editingOriginalName, let entry = named.first {
                return .success(.replace(originalName: originalName, entry: entry))
            }
            return .success(.add(named))
        }
    }

    static func trustRequest(
        for operation: SaveOperation,
        dependencies: Dependencies = .live
    ) -> TrustRequest? {
        _ = migrateLegacyEntries(dependencies: dependencies)
        let commands: [StdioCommand]
        switch operation {
        case .add(let entries):
            commands = entries.compactMap { stdioCommand(entryJSON: $0.entryJSON) }
        case .replace(let originalName, let entry):
            guard let command = stdioCommand(entryJSON: entry.entryJSON) else { return nil }
            if let original = resolvedEntry(named: originalName, dependencies: dependencies),
               entriesEquivalent(original.entryJSON, entry.entryJSON),
               original.reference.stdioTrusted == true {
                return nil
            }
            commands = [command]
        case .rename(let originalName, _):
            guard let original = resolvedEntry(named: originalName, dependencies: dependencies),
                  let command = stdioCommand(entryJSON: original.entryJSON),
                  original.reference.stdioTrusted != true
            else { return nil }
            commands = [command]
        }
        return commands.isEmpty ? nil : TrustRequest(commands: commands)
    }

    static func apply(
        _ operation: SaveOperation,
        trustingStdio: Bool,
        dependencies: Dependencies = .live
    ) throws {
        guard migrateLegacyEntries(dependencies: dependencies) else {
            throw ValidationError.secureStorageUnavailable
        }
        let request = trustRequest(for: operation, dependencies: dependencies)
        if request != nil, !trustingStdio { throw ValidationError.trustRequired }
        var raw = storedEntries(dependencies: dependencies)
        try validateOperation(operation, rawNames: Set(raw.keys))

        switch operation {
        case .rename(let originalName, let newName):
            guard let storedValue = raw.removeValue(forKey: originalName) else {
                throw ValidationError.originalMissing(originalName)
            }
            var replacement = storedValue
            if trustingStdio,
               let storedValue = storedValue as? String,
               var reference = secureReference(from: storedValue),
               let entryJSON = dependencies.vault.load(reference.account),
               stdioCommand(entryJSON: entryJSON) != nil {
                reference.stdioTrusted = true
                replacement = try secureReferenceJSON(reference)
            }
            raw[newName] = replacement
            dependencies.defaults.set(raw, forKey: defaultsKey)

        case .add(let entries):
            let secured = try secure(entries, markStdioTrusted: trustingStdio || request == nil, dependencies: dependencies)
            for (name, storedValue) in secured { raw[name] = storedValue }
            dependencies.defaults.set(raw, forKey: defaultsKey)

        case .replace(let originalName, let entry):
            guard let oldValue = raw.removeValue(forKey: originalName) else {
                throw ValidationError.originalMissing(originalName)
            }
            let secured = try secure(
                [entry],
                markStdioTrusted: trustingStdio || request == nil,
                dependencies: dependencies
            )
            guard let securedValue = secured[entry.name] else {
                throw ValidationError.secureStorageUnavailable
            }
            raw[entry.name] = securedValue
            dependencies.defaults.set(raw, forKey: defaultsKey)
            if let oldValue = oldValue as? String,
               let oldReference = secureReference(from: oldValue) {
                dependencies.vault.delete(oldReference.account)
            }
        }
    }

    static func remove(name: String, dependencies: Dependencies = .live) {
        var raw = storedEntries(dependencies: dependencies)
        guard let removed = raw.removeValue(forKey: name) else { return }
        dependencies.defaults.set(raw, forKey: defaultsKey)
        if let removed = removed as? String,
           let reference = secureReference(from: removed) {
            dependencies.vault.delete(reference.account)
        }
    }

    static func commandPreview(entryJSON: String) -> String {
        guard let entry = decodedDictionary(entryJSON) else { return "Configuration needs repair." }
        if let url = entry["url"] as? String { return safeURLPreview(url) }
        guard let command = entry["command"] as? String else { return "Configuration needs repair." }
        let args = (entry["args"] as? [String]) ?? []
        return ([command] + args.map(redactedArgument)).joined(separator: " ")
    }

    static func isValidName(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first.isNumber else { return false }
        return name.allSatisfy { character in
            character.isLetter || character.isNumber || character == "." || character == "-" || character == "_"
        }
    }

    static func rawEntries(dependencies: Dependencies = .live) -> [String: String] {
        storedEntries(dependencies: dependencies).reduce(into: [:]) { result, pair in
            if let value = pair.value as? String { result[pair.key] = value }
        }
    }

    private static func migrateLegacyEntries(dependencies: Dependencies) -> Bool {
        var raw = storedEntries(dependencies: dependencies)
        var candidates: [(name: String, payload: String, kind: PayloadKind?)] = []
        do {
            for name in raw.keys.sorted() {
                guard let value = raw[name] else { continue }
                if let string = value as? String {
                    guard secureReference(from: string) == nil else { continue }
                    candidates.append((name, string, nil))
                } else {
                    candidates.append((name, try opaquePropertyListPayload(value), .opaquePropertyList))
                }
            }
        } catch {
            return false
        }
        guard !candidates.isEmpty else { return true }

        var createdAccounts: [String] = []
        do {
            for candidate in candidates {
                let account = dependencies.makeAccount()
                createdAccounts.append(account)
                guard dependencies.vault.save(candidate.payload, account) else {
                    throw ValidationError.secureStorageUnavailable
                }
                raw[candidate.name] = try secureReferenceJSON(
                    SecureReference(account: account, payloadKind: candidate.kind)
                )
            }
            dependencies.defaults.set(raw, forKey: defaultsKey)
            return true
        } catch {
            createdAccounts.forEach(dependencies.vault.delete)
            return false
        }
    }

    private static func secure(
        _ entries: [NamedEntry],
        markStdioTrusted: Bool,
        dependencies: Dependencies
    ) throws -> [String: String] {
        var result: [String: String] = [:]
        var createdAccounts: [String] = []
        do {
            for entry in entries {
                let account = dependencies.makeAccount()
                createdAccounts.append(account)
                guard dependencies.vault.save(entry.entryJSON, account) else {
                    throw ValidationError.secureStorageUnavailable
                }
                let stdioTrusted = markStdioTrusted && stdioCommand(entryJSON: entry.entryJSON) != nil
                    ? true
                    : nil
                result[entry.name] = try secureReferenceJSON(
                    SecureReference(account: account, stdioTrusted: stdioTrusted)
                )
            }
            return result
        } catch {
            createdAccounts.forEach(dependencies.vault.delete)
            throw error
        }
    }

    private static func validateOperation(_ operation: SaveOperation, rawNames: Set<String>) throws {
        switch operation {
        case .add(let entries):
            try validateNames(entries.map(\.name), existingNames: rawNames, excluding: nil)
        case .replace(let originalName, let entry):
            guard rawNames.contains(originalName) else { throw ValidationError.originalMissing(originalName) }
            try validateNames([entry.name], existingNames: rawNames, excluding: originalName)
        case .rename(let originalName, let newName):
            guard rawNames.contains(originalName) else { throw ValidationError.originalMissing(originalName) }
            try validateNames([newName], existingNames: rawNames, excluding: originalName)
        }
    }

    private static func validateNames(
        _ names: [String],
        existingNames: Set<String>,
        excluding originalName: String?
    ) throws {
        var seen: Set<String> = []
        let available = existingNames.filter { existing in
            guard let originalName else { return true }
            return existing.caseInsensitiveCompare(originalName) != .orderedSame
        }
        for name in names {
            guard !name.isEmpty else { throw ValidationError.missingName }
            guard isValidName(name) else { throw ValidationError.invalidName(name) }
            guard !isReservedName(name) else {
                throw ValidationError.reservedName(name)
            }
            let folded = name.lowercased()
            guard seen.insert(folded).inserted else { throw ValidationError.duplicateName(name) }
            if available.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                throw ValidationError.duplicateName(name)
            }
        }
    }

    private static func validatedEntryJSON(_ entry: [String: Any], name: String?) throws -> String {
        if entry.keys.contains("url") {
            guard let url = entry["url"] as? String,
                  !entry.keys.contains("command"),
                  !entry.keys.contains("args"),
                  !entry.keys.contains("env")
            else { throw ValidationError.invalidEntry(name) }
            if let type = entry["type"] {
                guard let type = type as? String, type == "http" else {
                    throw ValidationError.invalidEntry(name)
                }
            }
            if let headers = entry["headers"], !(headers is [String: String]) {
                throw ValidationError.invalidEntry(name)
            }
            try validateHTTPURL(url)
            return try compact(entry)
        }
        guard let command = entry["command"] as? String,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !entry.keys.contains("headers")
        else { throw ValidationError.invalidEntry(name) }
        if let type = entry["type"] {
            guard let type = type as? String, type == "stdio" else {
                throw ValidationError.invalidEntry(name)
            }
        }
        if let args = entry["args"], !(args is [String]) {
            throw ValidationError.invalidEntry(name)
        }
        if let environment = entry["env"], !(environment is [String: String]) {
            throw ValidationError.invalidEntry(name)
        }
        return try compact(entry)
    }

    private static func validatedStoredEntry(_ entryJSON: String) -> String? {
        guard let entry = decodedDictionary(entryJSON),
              let normalized = try? validatedEntryJSON(entry, name: nil)
        else { return nil }
        return normalized
    }

    private static func validateHTTPURL(_ value: String) throws {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = components.host,
              !host.isEmpty
        else { throw ValidationError.invalidEntry(nil) }
        if scheme == "http", !isLoopbackHost(host) {
            throw ValidationError.insecureRemoteHTTP(host)
        }
    }

    private static func isLoopbackHost(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        while host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        if host == "::1" || host == "0:0:0:0:0:0:0:1" { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              let first = Int(octets[0]),
              octets.allSatisfy({ part in
                  guard !part.isEmpty, part.allSatisfy({ $0.isNumber }), let value = Int(part) else { return false }
                  return value >= 0 && value <= 255
              })
        else { return false }
        return first == 127
    }

    private static func stdioCommand(entryJSON: String) -> StdioCommand? {
        guard let entry = decodedDictionary(entryJSON),
              entry["url"] == nil,
              let command = entry["command"] as? String
        else { return nil }
        let arguments = entry["args"] as? [String] ?? []
        let redactedArguments = arguments.isEmpty
            ? "None"
            : arguments.map(redactedArgument).joined(separator: " ")
        return StdioCommand(executable: command, redactedArguments: redactedArguments)
    }

    private static func resolvedEntry(
        named name: String,
        dependencies: Dependencies
    ) -> (reference: SecureReference, entryJSON: String)? {
        guard let storedValue = storedEntries(dependencies: dependencies)[name] as? String,
              let reference = secureReference(from: storedValue),
              reference.containsEntryJSON,
              let entryJSON = dependencies.vault.load(reference.account),
              validatedStoredEntry(entryJSON) != nil
        else { return nil }
        return (reference, entryJSON)
    }

    private static func secureReference(from storedValue: String) -> SecureReference? {
        guard let data = storedValue.data(using: .utf8),
              let reference = try? JSONDecoder().decode(SecureReference.self, from: data),
              reference.isSupported,
              let canonical = try? secureReferenceJSON(reference),
              storedValue == canonical
        else { return nil }
        return reference
    }

    private static func storedEntries(dependencies: Dependencies) -> [String: Any] {
        dependencies.defaults.dictionary(forKey: defaultsKey) ?? [:]
    }

    private static func opaquePropertyListPayload(_ value: Any) throws -> String {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["value": value],
            format: .binary,
            options: 0
        )
        return "nexgen-property-list-v1:\(data.base64EncodedString())"
    }

    private static func secureReferenceJSON(_ reference: SecureReference) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(reference), as: UTF8.self)
    }

    private static func compact(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodedDictionary(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func entriesEquivalent(_ left: String, _ right: String) -> Bool {
        guard let leftObject = decodedDictionary(left),
              let rightObject = decodedDictionary(right),
              let leftData = try? JSONSerialization.data(withJSONObject: leftObject, options: [.sortedKeys]),
              let rightData = try? JSONSerialization.data(withJSONObject: rightObject, options: [.sortedKeys])
        else { return false }
        return leftData == rightData
    }

    private static func legacyPreview(_ entryJSON: String) -> String {
        guard validatedStoredEntry(entryJSON) != nil else { return "Configuration needs repair." }
        return commandPreview(entryJSON: entryJSON)
    }

    private static func isReservedName(_ name: String) -> Bool {
        name.caseInsensitiveCompare("nexgen") == .orderedSame
    }

    private static func safeURLPreview(_ value: String) -> String {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme,
              let host = components.host
        else { return "••••" }
        let displayHost = host.contains(":") ? "[\(host)]" : host
        let port = components.port.map { ":\($0)" } ?? ""
        let hasHiddenParts = components.user != nil
            || components.password != nil
            || !components.path.isEmpty && components.path != "/"
            || components.query != nil
            || components.fragment != nil
        return "\(scheme)://\(displayHost)\(port)\(hasHiddenParts ? "/••••" : "")"
    }

    private static func redactedArgument(_ argument: String) -> String {
        let lowercased = argument.lowercased()
        if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") {
            return safeURLPreview(argument)
        }
        if argument.hasPrefix("-"), let separator = argument.firstIndex(of: "=") {
            return "\(argument[..<separator])=••••"
        }
        if argument == "--stdio" || argument == "-y" { return argument }
        return "••••"
    }

    private static func shellSplitValidated(_ line: String) -> [String]? {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        for character in line {
            if let activeQuote = quote {
                if character == activeQuote { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty { parts.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        guard quote == nil else { return nil }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    static func shellSplit(_ line: String) -> [String] {
        shellSplitValidated(line) ?? []
    }
}
