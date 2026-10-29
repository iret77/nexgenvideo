import Foundation

extension MusicvideoProductionValidationErrorV1: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidField(let field): "Music Video field \(field) is missing or invalid."
        case .duplicateID(let id): "Music Video ID \(id) appears more than once."
        case .unknownReference(let id): "Music Video reference \(id) could not be found."
        case .sourceMismatch(let id): "Music Video source \(id) does not match the selected plan."
        case .mouthOwnershipMismatch(let id): "Music Video segment \(id) has inconsistent performer and voice ownership."
        case .coverageMissing(let id): "Music Video coverage \(id) is missing a required role."
        }
    }
}
