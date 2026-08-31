import Foundation

public enum ProjectLocalFileError: Error, Sendable, Equatable {
    case invalidPath(String)
    case missingOrNonRegularFile(String)
    case escapedProject(String)
    case symbolicLink(String)
    case hashMismatch(path: String, expected: String, actual: String)
}

public enum ProjectLocalFile {
    public static func resolve(_ relativePath: String, dataRoot: URL) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !trimmed.isEmpty,
              trimmed == relativePath,
              !NSString(string: trimmed).isAbsolutePath,
              !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ProjectLocalFileError.invalidPath(relativePath)
        }

        let projectRoot = FrameInventory.projectHome(of: dataRoot)
            .standardizedFileURL
        let normalizedDataRoot = dataRoot.standardizedFileURL
        if isSymbolicLink(projectRoot) || isSymbolicLink(normalizedDataRoot) {
            throw ProjectLocalFileError.symbolicLink(relativePath)
        }
        guard contains(normalizedDataRoot, in: projectRoot) else {
            throw ProjectLocalFileError.escapedProject(relativePath)
        }
        var seenPaths = Set<String>()
        let candidates = [normalizedDataRoot, projectRoot].compactMap { root -> URL? in
            let candidate = root.appendingPathComponent(trimmed).standardizedFileURL
            return seenPaths.insert(candidate.path).inserted ? candidate : nil
        }
        var sawContainedCandidate = false
        for candidate in candidates {
            guard contains(candidate, in: projectRoot) else {
                continue
            }
            sawContainedCandidate = true
            switch try inspect(candidate, from: projectRoot) {
            case .regularFile:
                return candidate
            case .symbolicLink:
                throw ProjectLocalFileError.symbolicLink(relativePath)
            case .missingOrNonRegular:
                continue
            }
        }

        guard sawContainedCandidate else {
            throw ProjectLocalFileError.escapedProject(relativePath)
        }
        throw ProjectLocalFileError.missingOrNonRegularFile(relativePath)
    }

    public static func requireHash(
        _ expectedSHA256: String,
        at relativePath: String,
        dataRoot: URL
    ) throws -> URL {
        let url = try resolve(relativePath, dataRoot: dataRoot)
        let actual = try FileDigest.sha256(of: url)
        guard actual == expectedSHA256 else {
            throw ProjectLocalFileError.hashMismatch(
                path: relativePath,
                expected: expectedSHA256,
                actual: actual
            )
        }
        return url
    }

    private enum Inspection {
        case regularFile
        case symbolicLink
        case missingOrNonRegular
    }

    private static func inspect(_ candidate: URL, from projectRoot: URL) throws -> Inspection {
        let suffix = candidate.path.dropFirst(projectRoot.path.count)
        let components = suffix.split(separator: "/").map(String.init)
        var current = projectRoot
        for (index, component) in components.enumerated() {
            current.appendPathComponent(component)
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) != nil {
                return .symbolicLink
            }
            guard FileManager.default.fileExists(atPath: current.path) else {
                return .missingOrNonRegular
            }
            let values = try current.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            if values.isSymbolicLink == true {
                return .symbolicLink
            }
            let isLast = index == components.count - 1
            if isLast {
                return values.isRegularFile == true ? .regularFile : .missingOrNonRegular
            }
            guard values.isDirectory == true else {
                return .missingOrNonRegular
            }
        }
        return .missingOrNonRegular
    }

    private static func contains(_ candidate: URL, in projectRoot: URL) -> Bool {
        candidate.path == projectRoot.path
            || candidate.path.hasPrefix(projectRoot.path + "/")
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}
