import AppKit
import SwiftUI

struct NativeChoicePicker: NSViewRepresentable {
    struct Option: Equatable {
        let id: String
        let title: String
        var help: String? = nil
    }

    let label: String
    let options: [Option]
    @Binding var selection: String
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.interfaceScale) private var interfaceScale

    func makeNSView(context: Context) -> ChoicePopUpButton {
        let button = ChoicePopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.choose(_:))
        return button
    }

    func updateNSView(_ button: ChoicePopUpButton, context: Context) {
        context.coordinator.selection = $selection
        button.configure(
            label: label, options: options, selection: selection,
            enabled: isEnabled, scale: interfaceScale
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ChoicePopUpButton, context: Context) -> CGSize? {
        nsView.proposedSize(proposal)
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<String>

        init(selection: Binding<String>) { self.selection = selection }

        @objc func choose(_ sender: ChoicePopUpButton) {
            guard sender.isEnabled,
                  let id = sender.selectedItem?.representedObject as? String else { return }
            selection.wrappedValue = id
        }
    }
}

final class ChoicePopUpButton: NSPopUpButton {
    private var options: [NativeChoicePicker.Option] = []
    private var scale: Double = 1

    override var intrinsicContentSize: NSSize {
        // Menu titles must not feed native fitting constraints back into the enclosing scroll layout.
        NSSize(
            width: AppTheme.ComponentSize.choicePickerIdealWidth * scale,
            height: AppTheme.ComponentSize.choicePickerHeight * scale
        )
    }

    func proposedSize(_ proposal: ProposedViewSize) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil }
            ?? intrinsicContentSize.width
        return CGSize(width: width, height: intrinsicContentSize.height)
    }

    func configure(
        label: String, options: [NativeChoicePicker.Option], selection: String,
        enabled: Bool, scale: Double
    ) {
        if self.scale != scale {
            self.scale = scale
            invalidateIntrinsicContentSize()
        }
        font = .systemFont(ofSize: AppTheme.Typography.ui * scale)
        lineBreakMode = .byTruncatingTail
        setAccessibilityLabel(label)
        isEnabled = enabled
        if self.options != options {
            self.options = options
            let menu = NSMenu()
            menu.autoenablesItems = false
            for option in options {
                let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
                item.representedObject = option.id
                item.toolTip = option.help ?? option.title
                menu.addItem(item)
            }
            self.menu = menu
        }
        let index = options.firstIndex { $0.id == selection }
        if indexOfSelectedItem != (index ?? -1) {
            selectItem(at: index ?? -1)
        }
        toolTip = index.map { options[$0].help ?? options[$0].title }
    }
}
