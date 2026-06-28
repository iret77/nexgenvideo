import Foundation

extension Notification.Name {
    static let providerKeysChanged = Notification.Name("providerKeysChanged")
}

enum GenerationProvider: String, CaseIterable, Identifiable {
    case fal
    case runway
    case openart
    case higgsfield
    case elevenlabs

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fal: return "fal.ai"
        case .runway: return "Runway"
        case .openart: return "OpenArt"
        case .higgsfield: return "Higgsfield"
        case .elevenlabs: return "ElevenLabs"
        }
    }

    var modalities: String {
        switch self {
        case .fal: return "Video · Image · Audio"
        case .runway: return "Video"
        case .openart: return "Image"
        case .higgsfield: return "Video"
        case .elevenlabs: return "Voice · SFX · Music"
        }
    }

    var keysURL: URL {
        switch self {
        case .fal: return URL(string: "https://fal.ai/dashboard/keys")!
        case .runway: return URL(string: "https://dev.runwayml.com")!
        case .openart: return URL(string: "https://openart.ai/api")!
        case .higgsfield: return URL(string: "https://higgsfield.ai")!
        case .elevenlabs: return URL(string: "https://elevenlabs.io/app/settings/api-keys")!
        }
    }

    var keychainAccount: String { "provider.\(rawValue).api-key" }
}

enum ProviderKeychain {
    static func save(_ key: String, for provider: GenerationProvider) {
        KeychainStore.save(key, account: provider.keychainAccount)
        NotificationCenter.default.post(name: .providerKeysChanged, object: nil)
    }

    static func load(_ provider: GenerationProvider) -> String? {
        KeychainStore.load(account: provider.keychainAccount)
    }

    static func delete(_ provider: GenerationProvider) {
        KeychainStore.delete(account: provider.keychainAccount)
        NotificationCenter.default.post(name: .providerKeysChanged, object: nil)
    }
}
