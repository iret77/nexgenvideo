import AppKit
import SwiftUI
import Testing
@testable import NexGenVideo

@Suite("Agent transcript layout", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct AgentTranscriptLayoutTests {
    @Test func proposalsStayFiniteWithoutTruncatingLongTurns() {
        for proposed: CGFloat? in [nil, .infinity, .nan, -1, 0, 240, 640, 1000] {
            let width = AgentTranscriptLayout.width(proposed)
            #expect(width.isFinite && width >= 0)
            #expect(width <= AppTheme.Layout.chatColumnMax)
        }
        #expect(AgentTranscriptLayout.width(240) == 240)
        #expect(AgentTranscriptLayout.height(50_000) == 50_000)
        #expect(AgentTranscriptLayout.height(.nan) == 0)
        #expect(AgentTranscriptLayout.height(.infinity) == 0)
    }

    @Test func blockHeightsAndSpacingArePreserved() {
        let host = NSHostingView(rootView: AgentTranscriptLayout(spacing: 12) {
            Rectangle().frame(height: 100)
            Rectangle().frame(height: 220)
            Rectangle().frame(height: 40)
        }.frame(width: 320))
        host.layoutSubtreeIfNeeded()
        #expect(abs(host.fittingSize.height - 384) < 1)
        #expect(abs(host.fittingSize.width - 320) < 1)
    }

    @Test func realTranscriptMessagesSettleDuringStreamingAndResizing() {
        let turnID = UUID()
        var message = AgentMessage(role: .assistant, blocks: [.text("Waiting on your verdict.")])
        let host = NSHostingView(rootView: fixture(turnID: turnID, message: message, width: 320, imageVisible: false))
        for width: CGFloat in [320, 240, 480, 640, 320] {
            for step in 0..<12 {
                message.blocks = [.text(String(repeating: "Two deviations from the approved front. ", count: step + 1))]
                host.rootView = fixture(turnID: turnID, message: message, width: width, imageVisible: step > 0)
                host.setFrameSize(.init(width: width, height: 700))
                host.layoutSubtreeIfNeeded()
                let first = host.fittingSize
                host.layoutSubtreeIfNeeded()
                #expect(first.width.isFinite && first.height.isFinite)
                #expect(host.fittingSize == first)
            }
        }
    }

    private func fixture(turnID: UUID, message: AgentMessage, width: CGFloat, imageVisible: Bool) -> some View {
        VStack {
            Text("New chat")
            ScrollView {
                LazyVStack(alignment: .leading) {
                    AgentTranscriptTurnView(turn: .init(id: turnID, items: [.assistantResult(message)]), toolResults: [:])
                    AgentTranscriptLayout {
                        if imageVisible {
                            Image(nsImage: NSImage(size: .init(width: 400, height: 600)))
                                .resizable().scaledToFit().frame(height: 220)
                        }
                        MarkdownText(text: "Waiting on your verdict.\n\n| Sheet | Status |\n|---|---|\n| Side | Keep |")
                    }
                }
            }
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            Text("Agent is working")
            TextField("Ask", text: .constant(""))
        }
        .frame(width: width, height: 700)
    }
}
