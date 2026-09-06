import AppKit
import SwiftUI
import Testing
@testable import NexGenVideo

@Suite("Native choice picker", .serialized)
@MainActor
struct NativeChoicePickerTests {
    @Test func hostedScrollLayoutSettlesAcrossWidthAndMenuChanges() {
        let host = NSHostingView(rootView: layoutFixture(width: 320, expanded: false))
        for width: CGFloat in [320, 480, 240, 640, 320] {
            for expanded in [false, true, false] {
                host.rootView = layoutFixture(width: width, expanded: expanded)
                host.setFrameSize(NSSize(width: width, height: 700))
                host.layoutSubtreeIfNeeded()
                let first = host.fittingSize
                host.layoutSubtreeIfNeeded()
                #expect(host.fittingSize == first)
                #expect(first.width.isFinite && first.height.isFinite)
            }
        }
    }

    private func layoutFixture(width: CGFloat, expanded: Bool) -> some View {
        VStack {
            ScrollView {
                LazyVStack {
                    ForEach(0..<20) { index in Text("Transcript message \(index)") }
                    if expanded { Rectangle().frame(height: 220) }
                }
            }
            VStack {
                Text("Approve spend")
                ScrollView {
                    HStack {
                        NativeChoicePicker(
                            label: "Provider",
                            options: [.init(id: "provider", title: "fal.ai")],
                            selection: .constant("provider")
                        )
                        NativeChoicePicker(
                            label: "Model",
                            options: [.init(id: "model", title: expanded
                                ? String(repeating: "Long model name ", count: 40)
                                : "Nano Banana Pro (edit)")],
                            selection: .constant("model")
                        )
                    }
                }
                Button("Generate image") {}
            }
            .frame(maxHeight: 318)
        }
        .frame(width: width, height: 700)
    }

    @Test func menuContentDoesNotChangeLayoutOrRebuildOnSelection() {
        let button = ChoicePopUpButton(frame: .zero, pullsDown: false)
        let options: [NativeChoicePicker.Option] = [
            .init(id: "short", title: "fal.ai"),
            .init(id: "long", title: String(repeating: "Long model name ", count: 100)),
        ]
        button.configure(label: "Model", options: options, selection: "short", enabled: true, scale: 1)
        let menu = button.menu
        let size = button.intrinsicContentSize
        for id in ["long", "short", "missing", "long"] {
            button.configure(label: "Model", options: options, selection: id, enabled: true, scale: 1)
            #expect(button.menu === menu)
            #expect(button.intrinsicContentSize == size)
        }
        #expect(button.selectedItem?.representedObject as? String == "long")
        #expect(button.toolTip == options[1].title)
        for width: CGFloat? in [nil, 0, 120, 320, .infinity, .nan] {
            let fitted = button.proposedSize(.init(width: width, height: .infinity))
            #expect(fitted.width.isFinite && fitted.width >= 0)
            #expect(fitted.height == size.height)
        }
        #expect(button.proposedSize(.init(width: 120, height: nil)).width == 120)
    }

    @Test func selectionAndDisabledActionsUseCurrentBinding() {
        var selected = "first"
        let coordinator = NativeChoicePicker.Coordinator(selection: Binding(
            get: { selected }, set: { selected = $0 }
        ))
        let button = ChoicePopUpButton(frame: .zero, pullsDown: false)
        let options: [NativeChoicePicker.Option] = [
            .init(id: "first", title: "Same title"),
            .init(id: "second", title: "Same title"),
        ]
        button.configure(label: "Model", options: options, selection: selected, enabled: true, scale: 1)
        button.selectItem(at: 1)
        coordinator.choose(button)
        #expect(selected == "second")
        button.configure(label: "Model", options: options, selection: "first", enabled: false, scale: 1)
        coordinator.choose(button)
        #expect(selected == "second")
        button.configure(label: "Model", options: [], selection: selected, enabled: true, scale: 1)
        coordinator.choose(button)
        #expect(selected == "second")
        #expect(button.selectedItem == nil)
    }

    @Test func scaleChangesGeometryWithoutDependingOnNativeFitting() {
        let button = ChoicePopUpButton(frame: .zero, pullsDown: false)
        button.configure(label: "Model", options: [], selection: "", enabled: false, scale: 1.5)
        #expect(button.intrinsicContentSize.height == AppTheme.ComponentSize.choicePickerHeight * 1.5)
        #expect(button.font?.pointSize == AppTheme.Typography.ui * 1.5)
    }
}
