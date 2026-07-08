import CoreGraphics
import Foundation

/// Pan/trucking pair planner: start + end frame from a larger master via
/// deterministic crop. Port of `engine/nexgen_engine/frames/pan_pair.py`.
///
/// Rationale: a pan/truck video model needs both a start and an end frame.
/// Generating them independently lets the world drift (start has 3
/// buildings, end has 2). Instead: generate one master frame spanning the
/// whole motion range, then crop start/end from it at a constant target
/// aspect — full world consistency, no model drift.
public enum PanDirection: String, Sendable {
    case right
    case left
    case up
    case down
}

/// Crop geometry for the frame pair. Port of `pan_pair.py::PanPairPlan`.
public struct PanPairPlan: Sendable, Equatable {
    public let masterSize: (width: Int, height: Int)
    public let targetSize: (width: Int, height: Int)
    /// (left, top, right, bottom) — matches PIL's box convention.
    public let startBox: (left: Int, top: Int, right: Int, bottom: Int)
    public let endBox: (left: Int, top: Int, right: Int, bottom: Int)
    public let direction: PanDirection
    public let travelPx: Int

    public init(
        masterSize: (width: Int, height: Int), targetSize: (width: Int, height: Int),
        startBox: (left: Int, top: Int, right: Int, bottom: Int),
        endBox: (left: Int, top: Int, right: Int, bottom: Int), direction: PanDirection, travelPx: Int
    ) {
        self.masterSize = masterSize
        self.targetSize = targetSize
        self.startBox = startBox
        self.endBox = endBox
        self.direction = direction
        self.travelPx = travelPx
    }

    public static func == (lhs: PanPairPlan, rhs: PanPairPlan) -> Bool {
        lhs.masterSize == rhs.masterSize && lhs.targetSize == rhs.targetSize
            && lhs.startBox == rhs.startBox && lhs.endBox == rhs.endBox && lhs.direction == rhs.direction
            && lhs.travelPx == rhs.travelPx
    }
}

public enum PanPairPlannerError: Swift.Error, Sendable, Equatable {
    case invalidTravelPct(Double)
    case invalidMasterSize(width: Int, height: Int)
    case masterTooNarrow(masterWidth: Int, masterHeight: Int, targetAspect: String, targetWidth: Int)
    case masterTooShort(masterWidth: Int, masterHeight: Int, targetAspect: String, targetHeight: Int)
}

/// Port of `pan_pair.py::plan_pan_pair`. Computes the two crop boxes without
/// actually cutting the image.
///
/// - Parameters:
///   - masterSize: (width, height) of the master image.
///   - targetAspect: `"W:H"` for the start/end frame (render aspect).
///   - direction: `.right`/`.left` for a horizontal pan, `.up`/`.down` for a tilt.
///   - travelPct: how much of the difference between master and target crop is
///     used. 100% = start at one edge, end at the other (maximum pan). 80%
///     (default) leaves a margin on both edges — the video model doesn't have
///     to sync to the very last pixel.
public func planPanPair(
    masterSize: (width: Int, height: Int), targetAspect: String, direction: PanDirection,
    travelPct: Double = 80.0
) throws -> PanPairPlan {
    guard travelPct > 0.0, travelPct <= 100.0 else {
        throw PanPairPlannerError.invalidTravelPct(travelPct)
    }
    let mw = masterSize.width
    let mh = masterSize.height
    guard mw > 0, mh > 0 else {
        throw PanPairPlannerError.invalidMasterSize(width: mw, height: mh)
    }
    let aspect = try parseAspect(targetAspect)

    if direction == .right || direction == .left {
        // Horizontal: target has the full master height (or below, depending
        // on aspect). The crop box moves horizontally.
        let targetH = mh
        let targetW = pythonRound(Double(targetH) * aspect)
        guard targetW <= mw else {
            throw PanPairPlannerError.masterTooNarrow(
                masterWidth: mw, masterHeight: mh, targetAspect: targetAspect, targetWidth: targetW
            )
        }
        let maxTravel = mw - targetW
        let travel = pythonRound(Double(maxTravel) * travelPct / 100.0)
        let startLeft: Int
        let endLeft: Int
        if direction == .right {
            startLeft = (maxTravel - travel) / 2
            endLeft = startLeft + travel
        } else {  // left
            endLeft = (maxTravel - travel) / 2
            startLeft = endLeft + travel
        }
        let startBox = (startLeft, 0, startLeft + targetW, targetH)
        let endBox = (endLeft, 0, endLeft + targetW, targetH)
        return PanPairPlan(
            masterSize: (mw, mh), targetSize: (targetW, targetH), startBox: startBox, endBox: endBox,
            direction: direction, travelPx: travel
        )
    }

    // Vertical: target has the full master width.
    let targetW = mw
    let targetH = pythonRound(Double(targetW) / aspect)
    guard targetH <= mh else {
        throw PanPairPlannerError.masterTooShort(
            masterWidth: mw, masterHeight: mh, targetAspect: targetAspect, targetHeight: targetH
        )
    }
    let maxTravel = mh - targetH
    let travel = pythonRound(Double(maxTravel) * travelPct / 100.0)
    let startTop: Int
    let endTop: Int
    if direction == .down {
        startTop = (maxTravel - travel) / 2
        endTop = startTop + travel
    } else {  // up
        endTop = (maxTravel - travel) / 2
        startTop = endTop + travel
    }
    let startBox = (0, startTop, targetW, startTop + targetH)
    let endBox = (0, endTop, targetW, endTop + targetH)
    return PanPairPlan(
        masterSize: (mw, mh), targetSize: (targetW, targetH), startBox: startBox, endBox: endBox,
        direction: direction, travelPx: travel
    )
}
