import AppKit
import ImageIO
import SwiftUI

struct GenerationReferencePreviewStrip: View {
    let package: GenerationPackageV1
    let projectHome: URL?

    private var imageIndices: [Int] { package.payload.references.indices.filter { package.payload.references[$0].type == "image" } }

    var body: some View {
        if !imageIndices.isEmpty {
            ViewThatFits(in: .horizontal) {
                strip(limit: 3)
                strip(limit: 2)
                strip(limit: 1)
            }
            .padding(.vertical, AppTheme.Spacing.xs)
        }
    }

    private func strip(limit: Int) -> some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            ForEach(Array(imageIndices.prefix(limit)), id: \.self) { index in
                GenerationReferenceThumbnail(package: package, referenceIndex: index, projectHome: projectHome)
            }
            if imageIndices.count > limit {
                Text("+\(imageIndices.count - limit)")
                    .font(.system(size: AppTheme.FontSize.xxs)).foregroundStyle(AppTheme.Text.secondaryColor)
                    .help("Expand Details to review every reference")
            }
        }
        .fixedSize()
    }
}

struct GenerationReferenceThumbnail: View {
    let package: GenerationPackageV1
    let referenceIndex: Int
    let projectHome: URL?
    @State private var thumbnail: CGImage?

    private var label: String { package.payload.references[referenceIndex].displayName ?? String(localized: "Image reference") }

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: NSImage(cgImage: thumbnail, size: .zero)).resizable().scaledToFit()
            } else {
                VStack(spacing: AppTheme.Spacing.xxs) {
                    Image(systemName: "photo").font(.system(size: AppTheme.FontSize.sm))
                    Text("No preview").font(.system(size: AppTheme.FontSize.xxs))
                }
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        }
        .frame(width: AppTheme.ComponentSize.generationReferenceWidth, height: AppTheme.ComponentSize.generationReferenceHeight)
        .background(AppTheme.Background.surfaceColor)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
        .help(label)
        .accessibilityLabel(label)
        .task(id: "\(package.id)|\(referenceIndex)|\(projectHome?.path ?? "")") {
            thumbnail = nil
            guard let projectHome else { return }
            let package = self.package
            let referenceIndex = self.referenceIndex
            let maximumPixels = AppTheme.ComponentSize.generationReferenceThumbnailPixels
            let loading = Task.detached(priority: .utility) {
                guard !Task.isCancelled,
                      let bytes = try? GenerationPackageInputs.previewData(package: package, referenceIndex: referenceIndex, home: projectHome),
                      let source = CGImageSourceCreateWithData(bytes as CFData, nil) else { return nil as CGImage? }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
                ]
                return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            }
            let image = await withTaskCancellationHandler(operation: { await loading.value }, onCancel: { loading.cancel() })
            guard !Task.isCancelled else { return }
            thumbnail = image
        }
    }
}
