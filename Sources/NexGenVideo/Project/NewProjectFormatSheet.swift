import AppKit
import SwiftUI

/// Format chosen when a project is created (Generic or an installed pack). The format shapes the whole
/// production workflow and can't be switched once production starts, so it belongs here at the start.
/// `onCreate` gets the chosen pack id (nil = generic).
struct NewProjectFormatSheet: View {
    let onCreate: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: String? = nil   // nil = generic

    private let packs = InstalledPack.all

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text("Choose a format")
                    .font(.system(size: AppTheme.FontSize.lg, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text("The format shapes your production workflow. It's set when you create the project — you can't switch it once production has started.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(spacing: AppTheme.Spacing.sm) {
                    optionCard(id: nil, title: "Generic",
                               subtitle: "Free-form AI editing — no fixed pipeline.", badge: nil)
                    ForEach(packs) { pack in
                        optionCard(id: pack.name, title: pack.displayName,
                                   subtitle: pack.benefit ?? pack.tagline ?? "", badge: pack.headerImage())
                    }
                }
            }
            .frame(maxHeight: 320)

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.capsule(.secondary, size: .regular))
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") { onCreate(selected); dismiss() }
                    .buttonStyle(.capsule(.prominent, size: .regular))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(width: 460)
    }

    private func optionCard(id: String?, title: String, subtitle: String, badge: NSImage?) -> some View {
        let isSelected = selected == id
        return Button { selected = id } label: {
            HStack(spacing: AppTheme.Spacing.md) {
                Group {
                    if let badge {
                        // Pack badges are wide banners (~3.77:1) — fit the whole thing, never crop the
                        // sides. The frame matches that aspect so a banner fills it with no letterbox.
                        Image(nsImage: badge).resizable().scaledToFit()
                    } else {
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            .fill(Color.white.opacity(AppTheme.Opacity.subtle))
                            .overlay(Image(systemName: "wand.and.stars").foregroundStyle(AppTheme.Text.tertiaryColor))
                    }
                }
                .frame(width: 132, height: 35)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: AppTheme.FontSize.smMd, weight: .semibold))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: AppTheme.Spacing.sm)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(isSelected ? AppTheme.Accent.primary : AppTheme.Text.mutedColor)
            }
            .padding(AppTheme.Spacing.smMd)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .fill(isSelected ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.faint)
                                     : Color.white.opacity(AppTheme.Opacity.subtle))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .strokeBorder(isSelected ? AppTheme.Accent.primary : AppTheme.Border.subtleColor,
                                  lineWidth: AppTheme.BorderWidth.hairline)
            )
            .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        }
        .buttonStyle(.plain)
    }
}
