import Accelerate
import Foundation

enum AudioSyncCorrelator {
    enum Failure: String, Sendable, Equatable {
        case insufficientOverlap
        case silence
        case weakCorrelation
        case noConsensus
        case ambiguous
        case excessiveDrift
    }

    struct Result: Sendable, Equatable {
        let lagHops: Int
        let confidence: Double
        let driftPPM: Double
        let matchedAnchors: Int
        let evaluatedAnchors: Int
        let meanCorrelation: Double
        let isAmbiguous: Bool
    }

    struct Assessment: Sendable, Equatable {
        let result: Result?
        let failure: Failure?

        var isAccepted: Bool { result != nil && failure == nil }
    }

    static let minOverlap = 16
    static let defaultMaxAnchors = 7
    static let defaultMaxDriftPPM = 250.0

    private struct AnchorWindow {
        let start: Int
        let length: Int
        let activity: Double
    }

    private struct Peak: Hashable {
        let anchorIndex: Int
        let anchorStart: Int
        let lag: Int
        let score: Double

        static func == (lhs: Peak, rhs: Peak) -> Bool {
            lhs.anchorIndex == rhs.anchorIndex && lhs.lag == rhs.lag
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(anchorIndex)
            hasher.combine(lag)
        }
    }

    private struct Model {
        let intercept: Double
        let slope: Double
        let selected: [Peak?]
        let support: Int
        let meanCorrelation: Double
        let residualRMS: Double
        let quality: Double
    }

    static func match(
        reference: [Float],
        target: [Float],
        maxLagHops: Int,
        centerLagHops: Int = 0,
        minOverlapHops: Int = minOverlap,
        maxAnchors: Int = defaultMaxAnchors,
        maxDriftPPM: Double = defaultMaxDriftPPM
    ) -> Assessment {
        if target.count > reference.count {
            let swappedCenter = centerLagHops == Int.min ? Int.max : -centerLagHops
            let swapped = matchDirect(
                reference: target,
                target: reference,
                maxLagHops: maxLagHops,
                centerLagHops: swappedCenter,
                minOverlapHops: minOverlapHops,
                maxAnchors: maxAnchors,
                maxDriftPPM: maxDriftPPM
            )
            guard let result = swapped.result else { return swapped }
            let swappedSlope = result.driftPPM / 1_000_000
            let denominator = 1 + swappedSlope
            guard denominator.isFinite, denominator > 0 else {
                return Assessment(result: result, failure: .excessiveDrift)
            }
            let lag = -Double(result.lagHops) / denominator
            guard lag.isFinite, lag >= Double(Int.min), lag < Double(Int.max) else {
                return Assessment(result: nil, failure: .insufficientOverlap)
            }
            let inverted = Result(
                lagHops: Int(lag.rounded()),
                confidence: result.confidence,
                driftPPM: -swappedSlope / denominator * 1_000_000,
                matchedAnchors: result.matchedAnchors,
                evaluatedAnchors: result.evaluatedAnchors,
                meanCorrelation: result.meanCorrelation,
                isAmbiguous: result.isAmbiguous
            )
            return Assessment(result: inverted, failure: swapped.failure)
        }
        return matchDirect(
            reference: reference,
            target: target,
            maxLagHops: maxLagHops,
            centerLagHops: centerLagHops,
            minOverlapHops: minOverlapHops,
            maxAnchors: maxAnchors,
            maxDriftPPM: maxDriftPPM
        )
    }

    private static func matchDirect(
        reference: [Float],
        target: [Float],
        maxLagHops: Int,
        centerLagHops: Int,
        minOverlapHops: Int,
        maxAnchors: Int,
        maxDriftPPM: Double
    ) -> Assessment {
        guard !reference.isEmpty, !target.isEmpty, maxLagHops >= 0 else {
            return Assessment(result: nil, failure: .insufficientOverlap)
        }
        let overlapFloor = max(minOverlap, minOverlapHops)
        guard min(reference.count, target.count) >= overlapFloor else {
            return Assessment(result: nil, failure: .insufficientOverlap)
        }

        let windowLength = min(max(overlapFloor, 128), 600, reference.count, target.count)
        let anchors = anchorWindows(in: target, length: windowLength, limit: max(1, maxAnchors))
        guard !anchors.isEmpty else { return Assessment(result: nil, failure: .silence) }
        let searchableAnchors = anchors.filter {
            hasSearchOverlap(
                anchor: $0,
                referenceCount: reference.count,
                centerLagHops: centerLagHops,
                maxLagHops: maxLagHops
            )
        }
        guard !searchableAnchors.isEmpty else {
            return Assessment(result: nil, failure: .weakCorrelation)
        }

        let ref = reference.map(Double.init)
        let tgt = target.map(Double.init)
        let refPrefix = prefixSums(ref)
        let refSquarePrefix = prefixSums(ref.map { $0 * $0 })
        let peakSeparation = max(3, overlapFloor / 10)
        var peaksByAnchor: [[Peak]] = []
        peaksByAnchor.reserveCapacity(searchableAnchors.count)

        ref.withUnsafeBufferPointer { refBuffer in
            tgt.withUnsafeBufferPointer { targetBuffer in
                for (anchorIndex, anchor) in searchableAnchors.enumerated() {
                    let peaks = peaks(
                        anchorIndex: anchorIndex,
                        anchor: anchor,
                        reference: refBuffer,
                        target: targetBuffer,
                        referencePrefix: refPrefix,
                        referenceSquarePrefix: refSquarePrefix,
                        centerLagHops: centerLagHops,
                        maxLagHops: maxLagHops,
                        peakSeparation: peakSeparation
                    )
                    peaksByAnchor.append(peaks)
                }
            }
        }

        let anchorsWithPeaks = peaksByAnchor.count(where: { !$0.isEmpty })
        guard anchorsWithPeaks > 0 else {
            return Assessment(result: nil, failure: .weakCorrelation)
        }

        let residualTolerance = max(3.0, Double(overlapFloor) * 0.04)
        let safeMaxDriftPPM = maxDriftPPM.isFinite && maxDriftPPM >= 0
            ? maxDriftPPM
            : defaultMaxDriftPPM
        let hypothesisDriftLimit = max(safeMaxDriftPPM, 20_000) / 1_000_000
        var hypotheses: [(intercept: Double, slope: Double)] = []
        for peaks in peaksByAnchor {
            for peak in peaks {
                hypotheses.append((Double(peak.lag), 0))
            }
        }
        if peaksByAnchor.count > 1 {
            for firstIndex in 0..<(peaksByAnchor.count - 1) {
                for secondIndex in (firstIndex + 1)..<peaksByAnchor.count {
                    for first in peaksByAnchor[firstIndex] {
                        for second in peaksByAnchor[secondIndex] {
                            let distance = Double(second.anchorStart - first.anchorStart)
                            guard distance > 0 else { continue }
                            let slope = Double(second.lag - first.lag) / distance
                            guard abs(slope) <= hypothesisDriftLimit else { continue }
                            hypotheses.append((Double(first.lag) - slope * Double(first.anchorStart), slope))
                        }
                    }
                }
            }
        }

        let minimumSupport = peaksByAnchor.count == 1
            ? 1
            : max(2, Int((Double(peaksByAnchor.count) * 0.6).rounded(.up)))
        var modelsBySelection: [[Int]: Model] = [:]
        for hypothesis in hypotheses {
            guard let model = evaluate(
                hypothesis: hypothesis,
                peaksByAnchor: peaksByAnchor,
                anchorCount: peaksByAnchor.count,
                residualTolerance: residualTolerance,
                minimumSupport: minimumSupport
            ) else { continue }
            let key = model.selected.map { $0?.lag ?? Int.min }
            if model.quality > (modelsBySelection[key]?.quality ?? -Double.infinity) {
                modelsBySelection[key] = model
            }
        }

        let models = modelsBySelection.values.sorted {
            if $0.quality != $1.quality { return $0.quality > $1.quality }
            return $0.support > $1.support
        }
        guard let best = models.first else {
            return Assessment(result: nil, failure: anchorsWithPeaks > 1 ? .noConsensus : .weakCorrelation)
        }

        let modelSeparation = max(25.0, Double(overlapFloor) * 0.25)
        let lastTargetHop = Double(max(0, target.count - 1))
        let alternate = models.dropFirst().first { model in
            let startDifference = abs(model.intercept - best.intercept)
            let endDifference = abs(
                (model.intercept + model.slope * lastTargetHop)
                    - (best.intercept + best.slope * lastTargetHop)
            )
            return max(startDifference, endDifference) >= modelSeparation
        }
        let qualityGap = alternate.map { best.quality - $0.quality }
        let ambiguous = qualityGap.map { $0 < 0.08 } ?? false
        let uniqueness = qualityGap.map { min(1, max(0, $0) / 0.18) } ?? 1
        let correlationQuality = min(1, max(0, (best.meanCorrelation - 0.35) / 0.65))
        let supportQuality = Double(best.support) / Double(peaksByAnchor.count)
        let residualQuality = 1 - min(1, best.residualRMS / residualTolerance)
        var confidence = 0.5 * correlationQuality
            + 0.22 * supportQuality
            + 0.10 * residualQuality
            + 0.18 * uniqueness
        if ambiguous { confidence = min(confidence, 0.49) }
        confidence = min(1, max(0, confidence))

        let driftPPM = best.slope * 1_000_000
        let result = Result(
            lagHops: Int(best.intercept.rounded()),
            confidence: confidence,
            driftPPM: driftPPM,
            matchedAnchors: best.support,
            evaluatedAnchors: peaksByAnchor.count,
            meanCorrelation: best.meanCorrelation,
            isAmbiguous: ambiguous
        )
        if ambiguous { return Assessment(result: result, failure: .ambiguous) }
        if abs(driftPPM) > safeMaxDriftPPM {
            return Assessment(result: result, failure: .excessiveDrift)
        }
        if best.meanCorrelation < 0.5 || confidence < 0.5 {
            return Assessment(result: result, failure: .weakCorrelation)
        }
        return Assessment(result: result, failure: nil)
    }

    private static func anchorWindows(in samples: [Float], length: Int, limit: Int) -> [AnchorWindow] {
        let lastStart = samples.count - length
        guard lastStart >= 0 else { return [] }
        let peak = samples.reduce(0.0) { partial, value in
            value.isFinite ? max(partial, abs(Double(value))) : partial
        }
        guard peak > 1e-8 else { return [] }
        let energyFloor = peak * 0.01
        let stride = max(1, length / 2)
        var starts = Array(Swift.stride(from: 0, through: lastStart, by: stride))
        if starts.last != lastStart { starts.append(lastStart) }

        let candidates = starts.compactMap { start -> AnchorWindow? in
            guard let activity = activity(
                of: samples,
                start: start,
                length: length,
                energyFloor: energyFloor
            ) else { return nil }
            return AnchorWindow(start: start, length: length, activity: activity)
        }.sorted { $0.activity > $1.activity }

        var selected: [AnchorWindow] = []
        for candidate in candidates {
            guard selected.allSatisfy({ abs($0.start - candidate.start) >= length }) else {
                continue
            }
            selected.append(candidate)
            if selected.count == limit { break }
        }
        return selected.sorted { $0.start < $1.start }
    }

    private static func activity(
        of samples: [Float],
        start: Int,
        length: Int,
        energyFloor: Double
    ) -> Double? {
        var sum = 0.0
        var squareSum = 0.0
        var minimum = Double.infinity
        var maximum = -Double.infinity
        for index in start..<(start + length) {
            let value = Double(samples[index])
            guard value.isFinite else { return nil }
            sum += value
            squareSum += value * value
            minimum = min(minimum, value)
            maximum = max(maximum, value)
        }
        let count = Double(length)
        let mean = sum / count
        guard abs(mean) >= energyFloor else { return nil }
        let variance = max(0, squareSum / count - mean * mean)
        let dynamicRange = maximum - minimum
        guard dynamicRange > max(1e-8, abs(mean) * 0.002), variance > 1e-16 else { return nil }
        return variance / max(mean * mean, 1e-12)
    }

    private static func peaks(
        anchorIndex: Int,
        anchor: AnchorWindow,
        reference: UnsafeBufferPointer<Double>,
        target: UnsafeBufferPointer<Double>,
        referencePrefix: [Double],
        referenceSquarePrefix: [Double],
        centerLagHops: Int,
        maxLagHops: Int,
        peakSeparation: Int
    ) -> [Peak] {
        let lowerLag = max(addingClamped(centerLagHops, -maxLagHops), -anchor.start)
        let upperLag = min(
            addingClamped(centerLagHops, maxLagHops),
            reference.count - anchor.length - anchor.start
        )
        guard lowerLag <= upperLag,
              let referenceBase = reference.baseAddress,
              let targetBase = target.baseAddress else { return [] }

        let targetStart = targetBase + anchor.start
        let count = vDSP_Length(anchor.length)
        var targetSum = 0.0
        var targetSquareSum = 0.0
        vDSP_sveD(targetStart, 1, &targetSum, count)
        vDSP_svesqD(targetStart, 1, &targetSquareSum, count)
        let countDouble = Double(anchor.length)
        let targetVariance = targetSquareSum - targetSum * targetSum / countDouble
        guard targetVariance > 0 else { return [] }

        var scored: [(lag: Int, score: Double)] = []
        scored.reserveCapacity(upperLag - lowerLag + 1)
        for lag in lowerLag...upperLag {
            let referenceStartIndex = anchor.start + lag
            let referenceSum = referencePrefix[referenceStartIndex + anchor.length]
                - referencePrefix[referenceStartIndex]
            let referenceSquareSum = referenceSquarePrefix[referenceStartIndex + anchor.length]
                - referenceSquarePrefix[referenceStartIndex]
            let referenceVariance = referenceSquareSum
                - referenceSum * referenceSum / countDouble
            guard referenceVariance > 0 else { continue }

            var dot = 0.0
            vDSP_dotprD(
                targetStart,
                1,
                referenceBase + referenceStartIndex,
                1,
                &dot,
                count
            )
            let covariance = dot - targetSum * referenceSum / countDouble
            let denominator = (targetVariance * referenceVariance).squareRoot()
            guard denominator > 0 else { continue }
            scored.append((lag, max(0, min(1, covariance / denominator))))
        }

        scored.sort { $0.score > $1.score }
        var result: [Peak] = []
        for candidate in scored where candidate.score >= 0.35 {
            guard result.allSatisfy({ abs($0.lag - candidate.lag) >= peakSeparation }) else { continue }
            result.append(Peak(
                anchorIndex: anchorIndex,
                anchorStart: anchor.start,
                lag: candidate.lag,
                score: candidate.score
            ))
            if result.count == 8 { break }
        }
        return result
    }

    private static func hasSearchOverlap(
        anchor: AnchorWindow,
        referenceCount: Int,
        centerLagHops: Int,
        maxLagHops: Int
    ) -> Bool {
        let lowerLag = max(addingClamped(centerLagHops, -maxLagHops), -anchor.start)
        let upperLag = min(
            addingClamped(centerLagHops, maxLagHops),
            referenceCount - anchor.length - anchor.start
        )
        return lowerLag <= upperLag
    }

    private static func evaluate(
        hypothesis: (intercept: Double, slope: Double),
        peaksByAnchor: [[Peak]],
        anchorCount: Int,
        residualTolerance: Double,
        minimumSupport: Int
    ) -> Model? {
        var selected = [Peak?](repeating: nil, count: anchorCount)
        for (anchorIndex, peaks) in peaksByAnchor.enumerated() {
            let anchorStart = peaks.first.map { Double($0.anchorStart) } ?? 0
            let predicted = hypothesis.intercept + hypothesis.slope * anchorStart
            selected[anchorIndex] = peaks
                .filter { abs(Double($0.lag) - predicted) <= residualTolerance }
                .max { lhs, rhs in
                    let lhsValue = lhs.score - abs(Double(lhs.lag) - predicted) / residualTolerance * 0.05
                    let rhsValue = rhs.score - abs(Double(rhs.lag) - predicted) / residualTolerance * 0.05
                    return lhsValue < rhsValue
                }
        }
        let hits = selected.compactMap { $0 }
        guard hits.count >= minimumSupport else { return nil }

        let refined = regression(hits)
        let residuals = hits.map {
            Double($0.lag) - (refined.intercept + refined.slope * Double($0.anchorStart))
        }
        let residualRMS = (
            residuals.reduce(0) { $0 + $1 * $1 } / Double(residuals.count)
        ).squareRoot()
        guard residualRMS <= residualTolerance else { return nil }
        let meanCorrelation = hits.map(\.score).reduce(0, +) / Double(hits.count)
        let supportQuality = Double(hits.count) / Double(anchorCount)
        let quality = 0.78 * meanCorrelation
            + 0.22 * supportQuality
            - 0.08 * min(1, residualRMS / residualTolerance)
        return Model(
            intercept: refined.intercept,
            slope: refined.slope,
            selected: selected,
            support: hits.count,
            meanCorrelation: meanCorrelation,
            residualRMS: residualRMS,
            quality: quality
        )
    }

    private static func regression(_ peaks: [Peak]) -> (intercept: Double, slope: Double) {
        guard peaks.count > 1 else { return (Double(peaks[0].lag), 0) }
        let weightSum = peaks.map(\.score).reduce(0, +)
        guard weightSum > 0 else { return (Double(peaks[0].lag), 0) }
        let meanX = peaks.reduce(0) { $0 + Double($1.anchorStart) * $1.score } / weightSum
        let meanY = peaks.reduce(0) { $0 + Double($1.lag) * $1.score } / weightSum
        var numerator = 0.0
        var denominator = 0.0
        for peak in peaks {
            let x = Double(peak.anchorStart) - meanX
            numerator += peak.score * x * (Double(peak.lag) - meanY)
            denominator += peak.score * x * x
        }
        let slope = denominator > 0 ? numerator / denominator : 0
        return (meanY - slope * meanX, slope)
    }

    private static func prefixSums(_ values: [Double]) -> [Double] {
        var result = [Double](repeating: 0, count: values.count + 1)
        for index in values.indices { result[index + 1] = result[index] + values[index] }
        return result
    }

    private static func addingClamped(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard overflow else { return sum }
        return rhs >= 0 ? Int.max : Int.min
    }
}
