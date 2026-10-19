import Foundation

// Retains the original ramp clock through edits without changing Clip's stored layout.
struct ClipAnimationEnvelope: Codable, Sendable, Equatable {
    static let effectType = "core.clip-envelope.v1"
    var start: Int
    var end: Int
    var head: Ramp
    var tail: Ramp

    struct Ramp: Codable, Sendable, Equatable {
        var anchor: Int
        var length: Int
        var interpolation: Interpolation

        func value(at frame: Int, incoming: Bool) -> Double {
            guard length > 0 else { return 1 }
            let distance = incoming ? frame - anchor : anchor - frame
            let t = min(1, max(0, Double(distance) / Double(length)))
            return interpolation == .smooth ? smoothstep(t) : t
        }
    }

    init(clip: Clip) {
        start = 0
        end = clip.durationFrames
        head = Ramp(anchor: 0, length: max(0, clip.fadeInFrames), interpolation: clip.fadeInInterpolation)
        tail = Ramp(anchor: clip.durationFrames, length: max(0, clip.fadeOutFrames), interpolation: clip.fadeOutInterpolation)
    }

    func gain(at frame: Int) -> Double {
        min(head.value(at: frame, incoming: true), tail.value(at: frame, incoming: false))
    }

    mutating func translate(by offset: Int) {
        start += offset
        end += offset
        head.anchor += offset
        tail.anchor += offset
    }

    mutating func rescale(by scale: Double) {
        start = Int((Double(start) * scale).rounded())
        end = max(start + 1, Int((Double(end) * scale).rounded()))
        head.anchor = Int((Double(head.anchor) * scale).rounded())
        tail.anchor = Int((Double(tail.anchor) * scale).rounded())
        head.length = max(0, Int((Double(head.length) * scale).rounded()))
        tail.length = max(0, Int((Double(tail.length) * scale).rounded()))
    }

    mutating func rescaleClock(by scale: Double, originalStart: Int, mappedStart: Int) {
        func mapped(_ offset: Int) -> Int {
            Int(((Double(originalStart) + Double(offset)) * scale).rounded()) - mappedStart
        }
        let headEnd = mapped(head.anchor + head.length)
        let tailStart = mapped(tail.anchor - tail.length)
        start = mapped(start)
        end = max(start + 1, mapped(end))
        head.anchor = mapped(head.anchor)
        tail.anchor = mapped(tail.anchor)
        head.length = max(0, headEnd - head.anchor)
        tail.length = max(0, tail.anchor - tailStart)
    }

    static func read(from clip: Clip) -> Self? {
        guard let text = clip.effects?.first(where: { $0.type == effectType })?.params["definition"]?.string,
              let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.end > value.start, value.head.length >= 0, value.tail.length >= 0 else { return nil }
        return value
    }
}

extension Clip {
    func animationWindow(originOffset: Int, duration: Int, extendedEdges: [FadeEdge] = []) -> Clip {
        guard duration > 0, durationFrames > 0 else { return self }
        var result = self
        result.rebaseKeyframes(by: -originOffset)
        result.setDuration(duration)
        for edge in extendedEdges { result.reanchorExtendedFade(edge, from: self) }
        return result
    }

    var animationEnvelope: ClipAnimationEnvelope {
        ClipAnimationEnvelope.read(from: self) ?? ClipAnimationEnvelope(clip: self)
    }

    var hasRetainedFade: Bool {
        guard let envelope = ClipAnimationEnvelope.read(from: self) else { return false }
        return (envelope.head.length > 0 && (envelope.head.anchor != 0 || envelope.head.length > durationFrames))
            || (envelope.tail.length > 0 && (envelope.tail.anchor != durationFrames || envelope.tail.length > durationFrames))
    }

    func fadeValue(_ edge: FadeEdge, atOffset offset: Int) -> Double {
        let envelope = animationEnvelope
        return edge == .left
            ? envelope.head.value(at: offset, incoming: true)
            : envelope.tail.value(at: offset, incoming: false)
    }

    mutating func storeAnimationEnvelope(_ envelope: ClipAnimationEnvelope) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(envelope), let text = String(data: data, encoding: .utf8) else { return }
        var updated = effects ?? []
        if let index = updated.firstIndex(where: { $0.type == ClipAnimationEnvelope.effectType }) {
            updated[index].params = ["definition": EffectParam(string: text)]
            updated[index].enabled = true
        } else {
            updated.append(Effect(type: ClipAnimationEnvelope.effectType, params: ["definition": EffectParam(string: text)]))
        }
        effects = updated
        synchronizeVisibleFades(envelope)
    }

    mutating func synchronizeVisibleFades(_ envelope: ClipAnimationEnvelope) {
        fadeInFrames = envelope.head.length > 0
            ? max(0, min(durationFrames, envelope.head.anchor + envelope.head.length)) : 0
        fadeOutFrames = envelope.tail.length > 0
            ? max(0, durationFrames - max(0, envelope.tail.anchor - envelope.tail.length)) : 0
        fadeInInterpolation = envelope.head.interpolation
        fadeOutInterpolation = envelope.tail.interpolation
    }

    mutating func reanchorExtendedFade(_ edge: FadeEdge, from basis: Clip) {
        let previous = basis.animationEnvelope
        var envelope = animationEnvelope
        switch edge {
        case .left:
            envelope.head = .init(anchor: 0, length: min(previous.head.length, max(0, durationFrames - fadeFrames(.right))),
                                  interpolation: previous.head.interpolation)
        case .right:
            envelope.tail = .init(anchor: durationFrames, length: min(previous.tail.length, max(0, durationFrames - fadeFrames(.left))),
                                  interpolation: previous.tail.interpolation)
        }
        envelope.start = min(envelope.start, 0)
        envelope.end = max(envelope.end, durationFrames)
        storeAnimationEnvelope(envelope)
    }

    mutating func resetFades() {
        var envelope = animationEnvelope
        envelope.head = .init(anchor: 0, length: 0, interpolation: .linear)
        envelope.tail = .init(anchor: durationFrames, length: 0, interpolation: .linear)
        if ClipAnimationEnvelope.read(from: self) != nil {
            storeAnimationEnvelope(envelope)
        } else {
            synchronizeVisibleFades(envelope)
        }
    }

    func requireValidAnimationEnvelope() throws {
        let carriers = effects?.filter { $0.type == ClipAnimationEnvelope.effectType } ?? []
        guard carriers.isEmpty || (carriers.count == 1 && carriers[0].enabled && ClipAnimationEnvelope.read(from: self) != nil) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid clip animation envelope."))
        }
    }
}
