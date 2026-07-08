import CoreGraphics
import Foundation

/// Static single-frame crop from a Bible master. Port of
/// `engine/nexgen_engine/frames/crop_from_master.py`.
///
/// Sister of `PanPairPlanner`: there the crop box travels from the master's
/// start to its end for pan/tilt. Here it stays static — for establishing
/// shots with unchanging framing that the Bible master already shows in full
/// wide geometry.
public enum CropAnchor: String, Sendable {
    case center
    case left
    case right
    case top
    case bottom
}

/// A static crop box computed from a master image, mirroring
/// `crop_from_master.py::CropPlan`.
public struct CropPlan: Sendable, Equatable {
    public let masterSize: (width: Int, height: Int)
    public let targetSize: (width: Int, height: Int)
    /// (left, top, right, bottom) — matches PIL's box convention.
    public let box: (left: Int, top: Int, right: Int, bottom: Int)
    public let anchor: CropAnchor

    public init(
        masterSize: (width: Int, height: Int), targetSize: (width: Int, height: Int),
        box: (left: Int, top: Int, right: Int, bottom: Int), anchor: CropAnchor
    ) {
        self.masterSize = masterSize
        self.targetSize = targetSize
        self.box = box
        self.anchor = anchor
    }

    public static func == (lhs: CropPlan, rhs: CropPlan) -> Bool {
        lhs.masterSize == rhs.masterSize && lhs.targetSize == rhs.targetSize && lhs.box == rhs.box
            && lhs.anchor == rhs.anchor
    }
}

public enum CropPlannerError: Swift.Error, Sendable, Equatable {
    case invalidAspect(String)
    case invalidMasterSize(width: Int, height: Int)
}

/// Port of `crop_from_master.py::_parse_aspect`. `"W:H"` -> `W/H`.
func parseAspect(_ s: String) throws -> Double {
    guard let colonIndex = s.firstIndex(of: ":") else {
        throw CropPlannerError.invalidAspect(s)
    }
    let wStr = s[s.startIndex..<colonIndex]
    let hStr = s[s.index(after: colonIndex)...]
    guard let w = Double(wStr), let h = Double(hStr), w > 0, h > 0 else {
        throw CropPlannerError.invalidAspect(s)
    }
    return w / h
}

/// Python `//` (floor division) for non-negative integer operands, which is
/// all this module ever divides (deltas and travel are always >= 0). Plain
/// Swift `/` on Ints already truncates toward zero, matching `//` here.
private func floorDiv(_ a: Int, _ b: Int) -> Int { a / b }

/// Python `round()` on a float used as `int(round(x))`: round-half-to-even
/// (banker's rounding), NOT Swift's default round-half-away-from-zero. Every
/// `int(round(...))` call in the ported Python must go through this, not
/// `.rounded()`.
func pythonRound(_ x: Double) -> Int {
    Int(x.rounded(.toNearestOrEven))
}

/// Port of `crop_from_master.py::plan_crop`. Computes the largest box that
/// fits inside the master and has the target aspect ratio; position follows
/// `anchor`.
public func planCrop(
    masterSize: (width: Int, height: Int), targetAspect: String, anchor: CropAnchor = .center
) throws -> CropPlan {
    let mw = masterSize.width
    let mh = masterSize.height
    guard mw > 0, mh > 0 else {
        throw CropPlannerError.invalidMasterSize(width: mw, height: mh)
    }
    let aspect = try parseAspect(targetAspect)
    let masterAspect = Double(mw) / Double(mh)

    if abs(masterAspect - aspect) < 1e-3 {
        // Master already has the target aspect — full take.
        return CropPlan(
            masterSize: (mw, mh), targetSize: (mw, mh), box: (0, 0, mw, mh), anchor: anchor
        )
    }

    if masterAspect > aspect {
        // Master is wider — full height, adjust width.
        let targetH = mh
        let targetW = pythonRound(Double(targetH) * aspect)
        let delta = mw - targetW
        let left: Int
        switch anchor {
        case .left: left = 0
        case .right: left = delta
        default: left = floorDiv(delta, 2)  // center / top / bottom (top/bottom irrelevant horizontally)
        }
        return CropPlan(
            masterSize: (mw, mh), targetSize: (targetW, targetH),
            box: (left, 0, left + targetW, targetH), anchor: anchor
        )
    }

    // Master is narrower — full width, adjust height.
    let targetW = mw
    let targetH = pythonRound(Double(targetW) / aspect)
    let delta = mh - targetH
    let top: Int
    switch anchor {
    case .top: top = 0
    case .bottom: top = delta
    default: top = floorDiv(delta, 2)
    }
    return CropPlan(
        masterSize: (mw, mh), targetSize: (targetW, targetH),
        box: (0, top, targetW, top + targetH), anchor: anchor
    )
}
