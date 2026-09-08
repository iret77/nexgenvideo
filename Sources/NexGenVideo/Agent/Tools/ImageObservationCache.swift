import Foundation
import NexGenEngine

@MainActor
final class ImageObservationCache {
    struct Entry {
        let receipt: FrameObservationReceiptV1
        let project: URL
        let bytes: Data
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private let maximumBytes: Int

    init(maximumBytes: Int = 32 * 1024 * 1024) { self.maximumBytes = maximumBytes }

    func observe(project: URL, sourceSHA256: String, image: Data, mediaID: String) throws -> FrameObservationReceiptV1 {
        guard !image.isEmpty, image.count <= maximumBytes else { throw ToolError("The inspected image exceeds the observation cache limit.") }
        let project = project.standardizedFileURL.resolvingSymlinksInPath()
        let receipt = FrameObservationReceiptV1.make(sourceSHA256: sourceSHA256, transmittedImage: image, mediaID: mediaID)
        entries[receipt.id] = Entry(receipt: receipt, project: project, bytes: image)
        order.removeAll { $0 == receipt.id }
        order.append(receipt.id)
        while entries.count > 128 || entries.values.reduce(0, { $0 + $1.bytes.count }) > maximumBytes, let oldest = order.first {
            order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
        return receipt
    }

    func require(_ id: String, project: URL, sourceSHA256: String) throws -> Entry {
        guard let entry = entries[id], entry.project == project.standardizedFileURL.resolvingSymlinksInPath(),
              entry.receipt.sourceSHA256 == sourceSHA256 else {
            throw ToolError("Inspect this project's current image again before saving its audit; the observation is no longer available.")
        }
        return entry
    }
}
