import Foundation

struct ProjectPackageRevision: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        enum Kind: String, Sendable {
            case directory
            case file
            case symbolicLink
        }

        let path: String
        let kind: Kind
        let size: UInt64?
        let modificationDate: Date?
        let symbolicLinkDestination: String?
    }

    let packageModificationDate: Date
    let entries: [Entry]

    static func capture(
        at packageURL: URL,
        fileManager: FileManager = .default
    ) throws -> Self {
        let root = packageURL.standardizedFileURL
        let before = try packageModificationDate(at: root, fileManager: fileManager)
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ],
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var entries: [Entry] = []
        while let item = enumerator.nextObject() as? URL {
            guard item.path.hasPrefix(rootPath) else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            let relativePath = String(item.path.dropFirst(rootPath.count))
            if isIncidentalFilesystemMetadata(relativePath) {
                let values = try item.resourceValues(forKeys: [.isDirectoryKey])
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            let values = try item.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ])
            if values.isSymbolicLink == true {
                entries.append(Entry(
                    path: relativePath,
                    kind: .symbolicLink,
                    size: nil,
                    modificationDate: nil,
                    symbolicLinkDestination: try fileManager.destinationOfSymbolicLink(
                        atPath: item.path
                    )
                ))
                enumerator.skipDescendants()
            } else if values.isDirectory == true {
                entries.append(Entry(
                    path: relativePath,
                    kind: .directory,
                    size: nil,
                    modificationDate: nil,
                    symbolicLinkDestination: nil
                ))
            } else if values.isRegularFile == true {
                entries.append(Entry(
                    path: relativePath,
                    kind: .file,
                    size: values.fileSize.map { UInt64($0) },
                    modificationDate: values.contentModificationDate,
                    symbolicLinkDestination: nil
                ))
            } else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
        }
        if let enumerationError { throw enumerationError }

        let after = try packageModificationDate(at: root, fileManager: fileManager)
        guard before == after else {
            throw CocoaError(.fileReadUnknown)
        }
        return Self(
            packageModificationDate: after,
            entries: entries.sorted { $0.path < $1.path }
        )
    }

    func changedPaths(comparedTo other: Self) -> [String] {
        let lhs = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        let rhs = Dictionary(uniqueKeysWithValues: other.entries.map { ($0.path, $0) })
        return Set(lhs.keys).union(rhs.keys).filter { lhs[$0] != rhs[$0] }.sorted()
    }

    private static func packageModificationDate(
        at url: URL,
        fileManager: FileManager
    ) throws -> Date {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let date = attributes[.modificationDate] as? Date else {
            throw CocoaError(.fileReadUnknown)
        }
        return date
    }

    private static func isIncidentalFilesystemMetadata(_ relativePath: String) -> Bool {
        relativePath.split(separator: "/").contains { component in
            component == ".DS_Store" || component.hasPrefix("._")
        }
    }
}
