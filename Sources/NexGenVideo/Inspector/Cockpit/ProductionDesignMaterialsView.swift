import ImageIO
import NexGenEngine
import SwiftUI

struct ProductionDesignMaterialsView: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var snapshot: Snapshot?
    @State private var failure: String?
    @State private var loading = false
    @State private var generation = 0
    @State private var preview: Reference?

    private struct Reference: Identifiable, Sendable {
        let id: String
        let title: String
        let note: String
        let image: CGImage
        let url: URL
        let sha256: String
    }

    private struct Snapshot: Sendable {
        let design: ProductionDesign
        let references: [Reference]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                if loading { ProgressView().controlSize(.small) }
                if let failure {
                    Text(failure).foregroundStyle(AppTheme.Status.errorColor)
                    Button("Reload Production Design") { Task { await load() } }.buttonStyle(InlineActionButtonStyle())
                } else if let snapshot {
                    Text(snapshot.design.visualMedium.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                        .interfaceFont(size: AppTheme.Typography.section, weight: AppTheme.FontWeight.semibold)
                    if !snapshot.design.visualMediumNotes.isEmpty { Text(snapshot.design.visualMediumNotes).textSelection(.enabled) }
                    ForEach(snapshot.references) { reference in
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                            Text(reference.title).fontWeight(AppTheme.FontWeight.semibold)
                            Button { preview = reference } label: {
                                Image(reference.image, scale: 1, label: Text(reference.title)).resizable().aspectRatio(contentMode: .fit)
                                    .frame(maxHeight: AppTheme.Layout.previewMinHeight)
                            }.buttonStyle(.plain).accessibilityLabel("Open \(reference.title)")
                            if !reference.note.isEmpty { Text(reference.note).textSelection(.enabled) }
                        }
                    }
                    if !snapshot.design.colorScript.isEmpty {
                        Text("Color script").fontWeight(AppTheme.FontWeight.semibold)
                        ForEach(snapshot.design.colorScript.keys.sorted(), id: \.self) { section in
                            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                                Text(section).foregroundStyle(AppTheme.Text.secondaryColor)
                                Text(snapshot.design.colorScript[section] ?? "").textSelection(.enabled)
                            }
                        }
                    }
                    if let notes = snapshot.design.notes, !notes.isEmpty { Text(notes).textSelection(.enabled) }
                    ProductionStyleReviewView()
                } else if !loading {
                    CockpitStateView.empty(icon: "paintpalette", title: "No Production Design yet",
                        message: "Review the visual references, lighting and color script here when Production Design is prepared.")
                }
            }.padding(AppTheme.Spacing.lg).frame(maxWidth: .infinity, alignment: .leading)
        }
        .interfaceFont(size: AppTheme.Typography.ui)
        .task(id: "\(editor.workingRoot?.path ?? ""):\(editor.engineStateRevision)") { await load() }
        .sheet(item: $preview) { reference in
            ProductionImageInspectionView(url: reference.url, sha256: reference.sha256, title: reference.title)
        }
    }

    private func load() async {
        generation += 1
        let token = generation, home = editor.workingRoot
        loading = true; failure = nil; snapshot = nil; preview = nil
        defer { if token == generation { loading = false } }
        guard let home, let root = DataRootResolver.dataRoot(of: home) else { return }
        do {
            _ = try ProjectPackGate.requireLiveMutation(projectURL: home, declaredPack: editor.declaredPluginName,
                declaredBinding: editor.declaredPluginBinding, declaredProductionContract: editor.declaredProductionContract)
            let value = try await Task.detached(priority: .userInitiated) {
                guard FileManager.default.fileExists(atPath: root.appendingPathComponent(PipelineLayout.productionDesignFile).path) else { return Snapshot?.none }
                let designURL = try ProjectLocalFile.resolve(PipelineLayout.productionDesignFile, dataRoot: root)
                let design = try YAMLCoding.decode(ProductionDesign.self, from: designURL)
                let files = design.refs.enumerated().map { ("Reference \($0.offset + 1)", $0.element.path, $0.element.note) }
                    + (design.lightingAnchor.isEmpty ? [] : [("Lighting anchor", design.lightingAnchor, "")])
                let references = try files.enumerated().map { index, file -> Reference in
                    let url = try ProjectLocalFile.resolve(file.1, dataRoot: root)
                    let bytes = try Data(contentsOf: url)
                    guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceShouldCacheImmediately: true,
                            kCGImageSourceThumbnailMaxPixelSize: 1280,
                          ] as CFDictionary) else { throw ToolError("A Production Design image cannot be decoded. Replace it before visual review.") }
                    return Reference(id: String(index), title: file.0, note: file.2, image: image, url: url,
                        sha256: FileDigest.sha256(of: bytes))
                }
                return Snapshot(design: design, references: references)
            }.value
            guard token == generation, editor.workingRoot == home, !Task.isCancelled else { return }
            snapshot = value
        } catch {
            guard token == generation, editor.workingRoot == home, !Task.isCancelled else { return }
            failure = error.localizedDescription
        }
    }
}

struct ProductionImageInspectionView: View {
    let url: URL?
    let sha256: String
    let title: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?
    @State private var failure: String?
    @State private var actualPixels = false

    init(url: URL, sha256: String, title: String) {
        self.url = url; self.sha256 = sha256; self.title = title
    }

    init(image: CGImage, title: String) {
        url = nil; sha256 = ""; self.title = title
        _image = State(initialValue: image)
    }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            HStack {
                Text(title).fontWeight(AppTheme.FontWeight.semibold).lineLimit(2).help(title)
                Spacer(minLength: AppTheme.Spacing.md)
                Toggle("Actual pixels", isOn: $actualPixels).toggleStyle(.button).disabled(image == nil)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                    .reviewAcceptanceProbe("production.image-inspection.close")
            }
            if let image {
                if actualPixels {
                    ScrollView([.horizontal, .vertical]) {
                        Image(image, scale: displayScale, label: Text(title)).fixedSize()
                            .reviewAcceptanceProbe("production.image-inspection.image")
                    }
                } else {
                    Image(image, scale: 1, label: Text(title)).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, minHeight: AppTheme.Spacing.none, maxHeight: .infinity)
                        .reviewAcceptanceProbe("production.image-inspection.image")
                }
            } else if let failure { Text(failure).foregroundStyle(AppTheme.Status.errorColor) }
            else { ProgressView("Loading image…") }
        }
        .padding(AppTheme.Spacing.lg)
        .interfaceFont(size: AppTheme.Typography.ui)
        .frame(width: AppTheme.Layout.productionDecisionReviewWidth, height: AppTheme.Layout.productionDecisionReviewHeight)
        .task(id: sha256) {
            guard let url else { return }
            image = nil; failure = nil
            do {
                let value = try await Task.detached(priority: .userInitiated) {
                    let bytes = try Data(contentsOf: url)
                    guard FileDigest.sha256(of: bytes) == sha256,
                          let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          let width = properties[kCGImagePropertyPixelWidth] as? Int,
                          let height = properties[kCGImagePropertyPixelHeight] as? Int,
                          let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                            kCGImageSourceShouldCacheImmediately: true,
                          ] as CFDictionary) else {
                        throw ToolError("The image changed or could not be decoded. Reload its source before inspecting it.")
                    }
                    return decoded
                }.value
                guard !Task.isCancelled else { return }
                image = value
            } catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
    }
}
