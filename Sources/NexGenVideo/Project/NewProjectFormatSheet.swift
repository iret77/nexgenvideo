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
                VStack(spacing: AppTheme.Spacing.mdLg) {
                    optionCard(id: nil, title: "Generic",
                               subtitle: "Free-form AI editing — no fixed pipeline.", badge: nil)
                    ForEach(packs) { pack in
                        optionCard(id: pack.name, title: pack.displayName,
                                   subtitle: pack.benefit ?? pack.tagline ?? "", badge: pack.headerImage())
                    }
                }
                .padding(.vertical, AppTheme.Spacing.xxs)
            }
            .frame(maxHeight: 460)

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
        .frame(width: 500)
    }

    /// Native banner aspect (728×193) — the hero frame matches it so a badge fills the full
    /// card width with no letterbox and no side crop.
    private static let bannerAspect: CGFloat = 728.0 / 193.0

    private func optionCard(id: String?, title: String, subtitle: String, badge: NSImage?) -> some View {
        let isSelected = selected == id
        return Button { selected = id } label: {
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if let badge {
                        Image(nsImage: badge).resizable().scaledToFill()
                    } else {
                        Color.white.opacity(AppTheme.Opacity.subtle)
                            .overlay(
                                Image(systemName: "wand.and.stars")
                                    .font(.system(size: AppTheme.IconSize.lg))
                                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                            )
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(Self.bannerAspect, contentMode: .fit)
                .clipped()

                HStack(spacing: AppTheme.Spacing.md) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                        Text(title)
                            .font(.system(size: AppTheme.FontSize.md, weight: .semibold))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: AppTheme.FontSize.sm))
                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    Spacer(minLength: AppTheme.Spacing.sm)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: AppTheme.FontSize.xl))
                        .foregroundStyle(isSelected ? AppTheme.Accent.primary : AppTheme.Text.mutedColor)
                }
                .padding(AppTheme.Spacing.mdLg)
            }
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .fill(isSelected ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.faint)
                                     : Color.white.opacity(AppTheme.Opacity.subtle))
            )
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .strokeBorder(isSelected ? AppTheme.Accent.primary : AppTheme.Border.subtleColor,
                                  lineWidth: isSelected ? AppTheme.BorderWidth.thin : AppTheme.BorderWidth.hairline)
            )
            .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        }
        .buttonStyle(.plain)
    }
}
