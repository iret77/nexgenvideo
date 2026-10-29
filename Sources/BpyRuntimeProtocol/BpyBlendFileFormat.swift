import Foundation

public enum BpyBlendFileFormat {
    public static func accepts(_ prefix: Data) -> Bool {
        prefix.starts(with: Data("BLENDER".utf8)) || prefix.starts(with: Data([0x28, 0xb5, 0x2f, 0xfd]))
    }
}
