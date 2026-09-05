import NexGenEngine
import SwiftUI

enum ProjectCardControl {
    case primary
    case removal
}

enum ProjectCardAction: Equatable {
    case open
    case confirmDeletion
    case removeFromRecents
    case none
}

struct ProjectCardInteractionPolicy {
    static func action(for control: ProjectCardControl, isAccessible: Bool) -> ProjectCardAction {
        switch (control, isAccessible) {
        case (.primary, true): .open
        case (.primary, false): .none
        case (.removal, true): .confirmDeletion
        case (.removal, false): .removeFromRecents
        }
    }
}

struct ProjectCard: View {
    let entry: ProjectEntry
    let onOpen: (URL) -> Void
    let onRemove: (URL) -> Void

    @State private var isHovered = false
    @State private var thumbnail: NSImage?
    @State private var packLabel: String?
    @State private var packPalette = ProjectPalette.neutral
    @State private var showDeleteConfirmation = false

    private let cardRadius: CGFloat = AppTheme.Radius.mdLg

    private var showsActiveHover: Bool {
        entry.isAccessible && isHovered
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            openButton
            if isHovered {
                removeButton
            }
        }
        .opacity(entry.isAccessible ? AppTheme.Opacity.opaque : AppTheme.Opacity.disabled)
        .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                .strokeBorder(
                    AppTheme.Text.primaryColor.opacity(showsActiveHover ? AppTheme.Opacity.muted : AppTheme.Opacity.hint),
                    lineWidth: AppTheme.BorderWidth.hairline
                )
        )
        .shadow(showsActiveHover ? AppTheme.Shadow.cardHover : AppTheme.Shadow.cardRest)
        .scaleEffect(showsActiveHover ? 1.03 : 1.0)
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
        .task(id: entry.lastOpenedDate) {
            await loadThumbnail(for: entry.url)
            await loadPackIdentity()
        }
        .onReceive(NotificationCenter.default.publisher(for: .projectPackBindingChanged)) { _ in
            Task { await loadPackIdentity() }
        }
    }

    private func loadPackIdentity() async {
        let url = entry.url
        let resolution = await Task.detached(priority: .utility) {
            ProjectPluginSettings.bindingResolution(projectURL: url)
        }.value
        guard !Task.isCancelled else { return }
        packLabel = nil
        packPalette = .neutral
        if case .bound(let binding) = resolution {
            packLabel = binding.id
            if let pack = PackCatalog.pack(named: binding.id), pack.version == binding.version {
                packLabel = pack.manifest.displayName
                packPalette = .resolve(hex: pack.manifest.accentHex)
            }
        }
    }

    private var openButton: some View {
        Button {
            perform(.primary)
        } label: {
            cardContent
        }
        .buttonStyle(.plain)
        .disabled(!entry.isAccessible)
        .accessibilityLabel(entry.isAccessible ? "Open \(entry.name)" : "\(entry.name), unavailable")
    }

    private var cardContent: some View {
        ZStack(alignment: .bottomLeading) {
            AppTheme.Background.placeholderColor
                .aspectRatio(5.0/4.0, contentMode: .fit)
                .overlay {
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "film")
                            .interfaceFont(size: AppTheme.Typography.display, weight: AppTheme.FontWeight.light)
                            .foregroundStyle(AppTheme.Text.mutedColor)
                    }
                }
                .overlay {
                    if !entry.isAccessible {
                        AppTheme.Background.overlayColor.opacity(AppTheme.Opacity.elevated)

                        VStack(spacing: AppTheme.Spacing.xxs) {
                            Image(systemName: "questionmark.folder")
                                .interfaceFont(size: AppTheme.Typography.display, weight: AppTheme.FontWeight.light)
                            Text("Unavailable")
                                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                            Text("Moved or deleted")
                                .interfaceFont(size: AppTheme.Typography.metadata)
                                .foregroundStyle(AppTheme.Text.mutedColor)
                        }
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }
                }
                .clipped()

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
                    .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.regular)
                    .foregroundStyle(entry.isAccessible ? AppTheme.Text.primaryColor : AppTheme.Text.mutedColor)
                    .lineLimit(1)

                if let packLabel {
                    Label(packLabel, systemImage: "puzzlepiece.extension.fill")
                        .interfaceFont(size: AppTheme.Typography.metadata)
                        .foregroundStyle(packPalette.accent)
                        .lineLimit(1)
                        .help(packLabel)
                }
                Text(Self.relativeString(for: entry.createdDate))
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.primaryColor.opacity(AppTheme.Opacity.medium))
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.bottom, AppTheme.Spacing.smMd)
        }
    }

    private var removeButton: some View {
        Button {
            perform(.removal)
        } label: {
            Image(systemName: entry.isAccessible ? "trash.fill" : "xmark")
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                .foregroundStyle(
                    entry.isAccessible ? AppTheme.Status.errorColor : AppTheme.Text.primaryColor
                )
                .frame(width: AppTheme.IconSize.lgXl, height: AppTheme.IconSize.lgXl)
                .glassEffect(.regular, in: .circle)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(entry.isAccessible ? "Delete project" : "Remove from Recents")
        .accessibilityLabel(
            entry.isAccessible
                ? "Delete \(entry.name)"
                : "Remove \(entry.name) from Recents"
        )
        .padding(AppTheme.Spacing.smMd)
        .transition(.opacity.combined(with: .scale))
    }

    private func perform(_ control: ProjectCardControl) {
        switch ProjectCardInteractionPolicy.action(for: control, isAccessible: entry.isAccessible) {
        case .open:
            onOpen(entry.url)
        case .confirmDeletion:
            showDeleteConfirmation = true
        case .removeFromRecents:
            onRemove(entry.url)
        case .none:
            break
        }
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
