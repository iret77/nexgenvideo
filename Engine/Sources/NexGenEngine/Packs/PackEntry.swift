import Foundation

/// Boxes `any Pack` so it can cross the ObjC/NSBundle plugin-entry boundary as a
/// concrete engine class. The `Pack` existential itself can't be an `@objc`
/// return type, so the host receives this box and unwraps `.pack`.
public final class PackBox: NSObject {
    public let pack: any Pack
    public init(_ pack: any Pack) { self.pack = pack }
}

/// The entry point of a loadable `.ngvpack`. Each pack ships an `@objc` subclass
/// of this and names it in its bundle's `Info.plist` under `NSPrincipalClass`;
/// after the load gate passes and `Bundle.load()` succeeds, the host reads
/// `bundle.principalClass`, instantiates it, and calls `makePack()`.
///
/// Host and plugin link the SAME `NexGenEngine` dynamic library (dyld dedups it
/// by the shared install name `@rpath/libNexGenEngine.dylib`), so this type's
/// metadata is identical on both sides and the cross-bundle
/// `principalClass as? PackEntry.Type` cast is sound. The ObjC runtime name is
/// pinned with `@objc(NGVPackEntry)` so subclasses and `NSPrincipalClass` values
/// are stable regardless of Swift module mangling.
@objc(NGVPackEntry)
open class PackEntry: NSObject {
    /// Required so the host can construct the principal class from its metatype.
    public required override init() { super.init() }

    /// Produce the pack this bundle provides. Subclasses MUST override.
    open func makePack() -> PackBox {
        fatalError("PackEntry subclass must override makePack()")
    }
}
