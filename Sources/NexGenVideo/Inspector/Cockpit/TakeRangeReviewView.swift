import AVKit
import SwiftUI
import NexGenEngine

struct TakeRangeReviewView: View {
    @Environment(EditorViewModel.self) private var editor
    let snapshot: TakeReview.Snapshot
    let wholeTakePlayer: AVPlayer?
    let canWrite: Bool
    @State private var firstFrame = 0
    @State private var endFrame = 0
    @State private var player: AVPlayer?
    @State private var findings: [TakeReview.Finding] = []
    @State private var observation = ""
    @State private var verdict = TakeReview.Verdict.conforms
    @State private var reviewID: String?
    @State private var savedRanges: [ReviewedTakeRange.Stored] = []
    @State private var productionWorkflow = false
    @State private var selectedRangeID: String?
    @State private var includeAudio = false
    @State private var busy = false
    @State private var message: String?

    private var range: ReviewedTakeRange.Range {
        .init(startFrame: firstFrame, endFrame: endFrame, fps: editor.timeline.fps)
    }
    private var validRange: Bool { (try? range.validate(sourceDuration: snapshot.durationSeconds)) != nil }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text("Keep a usable part of this take with its own review. The original take's verdict remains separate.")
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Text("Source frames at \(editor.timeline.fps) fps; end frame excluded.")
                HStack {
                    TextField("First frame", value: $firstFrame, format: .number)
                        .reviewAcceptanceProbe("take.range.start", text: String(firstFrame))
                    TextField("End frame", value: $endFrame, format: .number)
                        .reviewAcceptanceProbe("take.range.end", text: String(endFrame))
                }.disabled(busy)
                Button("Play source range") { playRange() }
                    .buttonStyle(InlineActionButtonStyle()).disabled(busy || !validRange)
                    .reviewAcceptanceProbe("take.range.play")
                if player != nil {
                    VideoPlayer(player: player).frame(minHeight: AppTheme.Layout.previewMinHeight)
                        .reviewAcceptanceProbe("take.range.player")
                }
                if findings.count < TakeReview.Pass.allCases.count {
                    let pass = TakeReview.Pass.allCases[findings.count]
                    Text("Range review · \(findings.count + 1) of 6 · \(pass.label)")
                        .fontWeight(AppTheme.FontWeight.semibold)
                        .reviewAcceptanceProbe("take.range.pass", text: pass.rawValue)
                    Picker("Range finding", selection: $verdict) {
                        Text("Meets the approved plan").tag(TakeReview.Verdict.conforms)
                        if pass != .identity {
                            Text("Accept deviation — explain").tag(TakeReview.Verdict.acceptedDeviation)
                            Text("Not applicable — explain").tag(TakeReview.Verdict.notApplicable)
                        }
                    }.disabled(busy)
                        .reviewAcceptanceProbe("take.range.verdict", text: verdict.rawValue)
                    TextField("Describe what you observed throughout this range", text: $observation).disabled(busy)
                        .reviewAcceptanceProbe("take.range.observation", text: observation)
                    let canRecord = !busy && validRange && player != nil
                        && !observation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    Button("Accept range pass") {
                        findings.append(.init(pass: pass, verdict: verdict, observation: observation,
                            startSeconds: 0, endSeconds: range.durationSeconds))
                        observation = ""; verdict = .conforms
                    }.buttonStyle(InlineActionButtonStyle(variant: .approval))
                        .disabled(!canRecord)
                        .reviewAcceptanceProbe("take.range.record-pass", state: canRecord)
                } else if reviewID == nil {
                    Button("Save reviewed range") {
                        let selectedRange = range
                        let observations = findings
                        busy = true
                        Task {
                            do {
                                reviewID = try await ReviewedTakeRange.save(snapshot: snapshot, range: selectedRange, findings: observations, editor: editor)
                                message = "Range review saved. The complete take's verdict is unchanged."
                                await loadSaved()
                            } catch { message = error.localizedDescription }
                            busy = false
                        }
                    }.buttonStyle(InlineActionButtonStyle(variant: .approval)).disabled(busy || !validRange || !canWrite)
                        .reviewAcceptanceProbe("take.range.save")
                }
                if reviewID != nil || !savedRanges.isEmpty {
                    Toggle("Include take audio", isOn: $includeAudio).disabled(busy)
                        .reviewAcceptanceProbe("take.range.audio", state: includeAudio)
                }
                if let reviewID {
                    if productionWorkflow { useForShotButton(reviewID) }
                    Button("Add reviewed range at playhead") {
                        let withAudio = includeAudio
                        busy = true
                        Task {
                            do {
                                try await ReviewedTakeRange.addToTimeline(id: reviewID, home: snapshot.home, includeAudio: withAudio, editor: editor)
                                message = "Reviewed range added on a new track. Its original source remains intact."
                            } catch { message = error.localizedDescription }
                            busy = false
                        }
                    }.buttonStyle(InlineActionButtonStyle(variant: .approval)).disabled(busy || !canWrite)
                        .reviewAcceptanceProbe("take.range.add")
                }
                Button("Discard range review draft") { reset() }
                    .buttonStyle(InlineActionButtonStyle()).disabled(busy)
                    .reviewAcceptanceProbe("take.range.discard")
                if !savedRanges.isEmpty {
                    DisclosureGroup("Saved reviewed ranges") {
                        ForEach(savedRanges) { stored in
                            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                                Text("Frames \(stored.review.range.startFrame)–\(stored.review.range.endFrame) at \(stored.review.range.fps) fps")
                                    .fontWeight(AppTheme.FontWeight.semibold)
                                ForEach(stored.review.findings, id: \.pass) { finding in
                                    Text("\(finding.pass.label): \(finding.observation)")
                                }
                                if productionWorkflow { useForShotButton(stored.id) }
                                Button("Add this reviewed range at playhead") {
                                    let withAudio = includeAudio
                                    busy = true
                                    Task {
                                        do {
                                            try await ReviewedTakeRange.addToTimeline(id: stored.id, home: snapshot.home, includeAudio: withAudio, editor: editor)
                                            message = "Reviewed range added on a new track."
                                        } catch { message = error.localizedDescription }
                                        busy = false
                                    }
                                }.buttonStyle(InlineActionButtonStyle(variant: .approval))
                                    .disabled(busy || !canWrite || stored.review.range.fps != editor.timeline.fps)
                            }
                        }
                    }
                }
                if let message {
                    Text(message).foregroundStyle(AppTheme.Text.secondaryColor)
                        .reviewAcceptanceProbe("take.range.message", text: message)
                }
            }.padding(.vertical, AppTheme.Spacing.sm)
        } label: {
            Text("Review a source range").reviewAcceptanceProbe("take.range.open")
        }
        .onChange(of: firstFrame) { _, _ in reset() }
        .onChange(of: endFrame) { _, _ in reset() }
        .onChange(of: editor.timeline.fps) { _, _ in reset() }
        .onDisappear { player?.pause() }
        .task(id: snapshot.take.id) { await loadSaved() }
    }

    private func reset() {
        player?.pause(); player = nil; findings = []; observation = ""; verdict = .conforms; reviewID = nil; message = nil
    }

    private func loadSaved() async {
        do {
            savedRanges = try await ReviewedTakeRange.saved(takeID: snapshot.take.id, home: snapshot.home)
            guard editor.workingRoot == snapshot.home, let root = DataRootResolver.dataRoot(of: snapshot.home) else { return }
            let binding = editor.declaredPluginBinding
            let contract = editor.declaredProductionContract
            let shotID = snapshot.take.shotID
            let state = try await Task.detached(priority: .utility) {
                let production = try PhaseContractRuntime.resolveWorkflow(dataRoot: root, expectedPack: binding,
                    expectedProductionContract: contract)?.isProductionV2 == true
                let selection = production ? try? PipelineProductionRenderWriter.requireSelected(shotID: shotID, dataRoot: root) : nil
                return (production, selection?.selection.nativeRange?.id)
            }.value
            guard editor.workingRoot == snapshot.home else { return }
            productionWorkflow = state.0; selectedRangeID = state.1
        } catch { message = error.localizedDescription }
    }

    private func useForShotButton(_ id: String) -> some View {
        Button(selectedRangeID == id ? "Selected for shot" : "Use range for shot") {
            busy = true; message = nil
            Task {
                defer { busy = false }
                do {
                    try await PipelineProductionRenderWriter.selectRangeNative(reviewID: id, editor: editor)
                    selectedRangeID = id
                    message = "Range selected for this shot. Rebuild the assembly to update the cut."
                } catch { message = error.localizedDescription }
            }
        }
        .buttonStyle(InlineActionButtonStyle(variant: .approval))
        .disabled(busy || !canWrite || selectedRangeID == id)
        .reviewAcceptanceProbe("take.range.use.\(id)", state: !busy && canWrite && selectedRangeID != id)
    }

    private func playRange() {
        guard validRange else { return }
        wholeTakePlayer?.pause()
        player?.pause()
        let item = AVPlayerItem(url: snapshot.mediaURL)
        item.forwardPlaybackEndTime = CMTime(value: Int64(endFrame), timescale: Int32(range.fps))
        let value = AVPlayer(playerItem: item)
        player = value
        value.seek(to: CMTime(value: Int64(firstFrame), timescale: Int32(range.fps)), toleranceBefore: .zero, toleranceAfter: .zero)
        value.play()
    }
}
