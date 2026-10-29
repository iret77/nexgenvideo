import Foundation
import NexGenEngine

enum ExportDataRoot {
    static func resolve(in home: URL) throws -> URL {
        let declaration = try ProjectPackGate.captureMutationDeclaration(projectURL: home)
        if let root = DataRootResolver.dataRoot(of: home) { return root }
        guard declaration.packName == nil, declaration.binding == nil, declaration.productionContract == nil,
              ProjectIdentity.existingUUID(for: home) != nil else { throw unavailable() }
        let fm = FileManager.default
        for base in [home, home.appendingPathComponent(DataRootResolver.legacyPipelineDirname),
                     home.appendingPathComponent(DataRootResolver.pipelineDirname)] {
            for name in [PipelineLayout.projectFile, PipelineLayout.gatesFile, PipelineLayout.briefFile,
                         ScriptV1.currentPath, StoryboardV2.currentPath, ShotPlanningDraftV1.currentPath] {
                let path = base.appendingPathComponent(name)
                if fm.fileExists(atPath: path.path) || (try? fm.destinationOfSymbolicLink(atPath: path.path)) != nil {
                    throw unavailable()
                }
            }
        }
        let root = home.appendingPathComponent(DataRootResolver.pipelineDirname, isDirectory: true)
        if fm.fileExists(atPath: root.path) || (try? fm.destinationOfSymbolicLink(atPath: root.path)) != nil {
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw unavailable() }
            let names = try fm.contentsOfDirectory(atPath: root.path).filter { !$0.hasPrefix(".") }
            guard names.allSatisfy({ $0 == "delivery" }) else { throw unavailable() }
        }
        return root
    }

    static func metadata(in root: URL) throws -> ProjectMeta {
        let home = [DataRootResolver.pipelineDirname, DataRootResolver.legacyPipelineDirname].contains(root.lastPathComponent)
            ? root.deletingLastPathComponent() : root
        guard try resolve(in: home).standardizedFileURL == root.standardizedFileURL else { throw unavailable() }
        if DataRootResolver.dataRoot(of: home) != nil {
            return try YAMLArtifactStore(dataRoot: root).load(ProjectMeta.self, at: PipelineLayout.projectFile)
        }
        guard let id = ProjectIdentity.existingUUID(for: home) else { throw unavailable() }
        return ProjectMeta(project: id, mode: .generic)
    }

    private static func unavailable() -> ToolError {
        ToolError("The project's production data is missing or unreadable. Restore it before exporting.")
    }
}
