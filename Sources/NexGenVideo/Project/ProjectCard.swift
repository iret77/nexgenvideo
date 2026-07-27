import SwiftUI

struct ProjectCard: View {
    let entry: ProjectEntry
    let onOpen: (URL) -> Void
    let onRemove: (URL) -> Void

    @State private var isHovered = false
    @State private var thumbnail: NSImage?
    @State private var showDeleteConfirmation = false

    private let cardRadius: CGFloat = AppTheme.Radius.mdLg

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Thumbnail
            AppTheme.Background.placeholderColor
                .aspectRatio(5.0/4.0, contentMode: .fit)
                .overlay {
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "film")
                            .font(.system(size: AppTheme.FontSize.title2, weight: AppTheme.FontWeight.light))
                            .foregroundStyle(AppTheme.Text.mutedColor)
                    }
                }
                .overlay {
                    if !entry.isAccessible {
                        AppTheme.Background.overlayColor.opacity(AppTheme.Opacity.elevated)

                        VStack(spacing: AppTheme.Spacing.xxs) {
                            Image(systemName: "questionmark.folder")
                                .font(.system(size: AppTheme.FontSize.title2, weight: AppTheme.FontWeight.light))
                            Text("Unavailable")
                                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                            Text("Moved or deleted")
                                .font(.system(size: AppTheme.FontSize.xxs))
                                .foregroundStyle(AppTheme.Text.mutedColor)
                        }
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }
                }
                .clipped()
                .onTapGesture {
                    if entry.isAccessible { onOpen(entry.url) }
                }

            // Bottom gradient + label overlay
            LinearGradient(
                stops: [
                    .init(color: AppTheme.Background.clearColor, location: 0),
                    .init(color: AppTheme.Background.overlayColor.opacity(AppTheme.Opacity.scrim), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: AppTheme.ComponentSize.homeCardOverlayHeight)
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(entry.name)
                    .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.regular))
                    .foregroundStyle(entry.isAccessible ? AppTheme.Text.primaryColor : AppTheme.Text.mutedColor)
                    .lineLimit(1)

                Text(Self.relativeString(for: entry.createdDate))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.primaryColor.opacity(AppTheme.Opacity.medium))
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.bottom, AppTheme.Spacing.smMd)
        }
        .opacity(entry.isAccessible ? AppTheme.Opacity.opaque : AppTheme.Opacity.disabled)
        .overlay(alignment: .topTrailing) {
            if isHovered {
                // A present file → delete to Trash; a missing one → just drop it from Recents (there's
                // nothing to Trash), so a gone project is one click to clear instead of a dead tile.
                Button {
                    if entry.isAccessible { showDeleteConfirmation = true } else { onRemove(entry.url) }
                } label: {
                    Image(systemName: entry.isAccessible ? "trash.fill" : "xmark")
                        .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.semibold))
                        .foregroundStyle(
                            entry.isAccessible ? AppTheme.Status.errorColor : AppTheme.Text.primaryColor
                        )
                        .frame(width: AppTheme.IconSize.lgXl, height: AppTheme.IconSize.lgXl)
                        .glassEffect(.regular, in: .circle)
                }
                .buttonStyle(.plain)
                .help(entry.isAccessible ? "Delete project" : "Remove from Recents")
                .padding(AppTheme.Spacing.smMd)
                .transition(.opacity.combined(with: .scale))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                .strokeBorder(
                    AppTheme.Text.primaryColor.opacity(isHovered ? AppTheme.Opacity.muted : AppTheme.Opacity.hint),
                    lineWidth: AppTheme.BorderWidth.hairline
                )
        )
        .shadow(isHovered ? AppTheme.Shadow.cardHover : AppTheme.Shadow.cardRest)
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .padding(AppTheme.Spacing.xs)
        .animation(.spring(response: AppTheme.Anim.cardSpringResponse, dampingFraction: AppTheme.Anim.cardSpringDamping), value: isHovered)
        .onHover { isHovered = $0 }
        .contextMenu {
            if entry.isAccessible {
                Button("Open") { onOpen(entry.url) }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(entry.url.path, inFileViewerRootedAtPath: entry.url.deletingLastPathComponent().path)
                }
                Divider() // app-theme: native-menu-divider
            }
            Button("Remove from Recents") { onRemove(entry.url) }
            Button("Delete Project", role: .destructive) { showDeleteConfirmation = true }
        }
        .alert("Delete \"\(entry.name)\"?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                ProjectRegistry.shared.delete(entry.url)
            }
        } message: {
            Text("The project will be moved to the Trash.")
        }
        .task(id: entry.lastOpenedDate) { await loadThumbnail(for: entry.url) }
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private static func relativeString(for date: Date) -> String {
        relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func loadThumbnail(for projectURL: URL) async {
        thumbnail = nil
        let image = await Task.detached(priority: .utility) {
            let thumbURL = projectURL.appendingPathComponent(Project.thumbnailFilename, isDirectory: false)
            return ImageEncoder.thumbnail(url: thumbURL, maxPixelSize: 640)
        }.value
        guard let image, !Task.isCancelled else { return }
        thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
