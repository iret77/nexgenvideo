import AppKit
import ImageIO
import NexGenEngine
import Vision

@MainActor
enum ProductionCoverOwnerEvidence {
    static func fixture(format: ProductionV2CoverAcceptance.Format, artist: String?, title: String?) throws -> Data {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: format.width, pixelsHigh: format.height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw invalid("Could not allocate the isolated cover response.") }
        // These fixed fixture pixels are a simulated provider response, never a product typography renderer.
        let pixels = context.cgContext
        pixels.setFillColor(CGColor(red: 0.94, green: 0.92, blue: 0.86, alpha: 1))
        pixels.fill(CGRect(x: 0, y: 0, width: format.width, height: format.height))
        pixels.setFillColor(CGColor(red: 0.1, green: 0.45, blue: 0.65, alpha: 1))
        pixels.fill(CGRect(x: format.width / 2, y: format.height / 3, width: format.width / 3, height: format.height / 3))
        if let artist, let title {
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            defer { NSGraphicsContext.restoreGraphicsState() }
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: AppTheme.FontSize.display,
                weight: AppTheme.AppKitFontWeight.bold), .foregroundColor: AppTheme.Background.overlay]
            NSAttributedString(string: artist, attributes: attributes).draw(at: CGPoint(x: 24, y: CGFloat(format.height - 65)))
            NSAttributedString(string: title, attributes: attributes).draw(at: CGPoint(x: 24, y: 30))
        }
        guard let bytes = bitmap.representation(using: .png, properties: [:]) else { throw invalid("Could not encode the isolated cover response.") }
        return bytes
    }

    static func pipeline(root: URL, output: URL, label: String) async throws -> [String: String] {
        try await Task.detached {
            let directory = output.appendingPathComponent("cover-evidence/" + label)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var names = [PipelineLayout.projectFile, PipelineLayout.briefFile, PipelineLayout.gatesFile, PipelineLayout.lineageFile]
            func collect(_ relative: String) throws {
                let url = root.appendingPathComponent(relative)
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw invalid("A protected pipeline artifact is a symbolic link.") }
                if values.isDirectory == true {
                    for child in try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() {
                        try collect(relative + "/" + child)
                    }
                } else if values.isRegularFile == true { names.append(relative) }
                else { throw invalid("A protected pipeline artifact is not a regular file.") }
            }
            for relative in ["analysis", "production_design", "treatment", "storyboard", "bible", "shotlist", "frames", "renders",
                "script", "planning", "execution", "reviews", "sanity"] {
                if FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path) { try collect(relative) }
            }
            var hashes: [String: String] = [:]
            for name in names.sorted() {
                let bytes = try Data(contentsOf: ProjectLocalFile.resolve(name, dataRoot: root))
                let target = directory.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: target, options: .atomic)
                hashes[name] = FileDigest.sha256(of: bytes)
            }
            return hashes
        }.value
    }

    static func turn(_ message: AgentMessage, output: URL) async throws -> [String: String] {
        let data = try PlanningWriterIO.json(message), name = "turn-" + message.id.uuidString + ".json"
        return try await Task.detached {
            let target = output.appendingPathComponent("cover-evidence/" + name)
            try data.write(to: target, options: .atomic)
            return ["turnFile": name, "turnSHA256": FileDigest.sha256(of: data)]
        }.value
    }

    static func retain(asset: MediaAsset, reference: MediaAsset?, format: ProductionV2CoverAcceptance.Format, key: String,
        expected: Data, artist: String?, title: String?, batch: GenerationBatchStore.Snapshot, package: GenerationPackageV1,
        home: URL, output: URL) async throws -> [String: Any] {
        let id = asset.id, url = asset.url, referenceURL = reference?.url, referenceID = reference?.id
        let assetBytes = try PlanningWriterIO.json(asset.toManifestEntry(projectURL: home))
        let batchBytes = try PlanningWriterIO.json(batch)
        let requests = MusicvideoGenerationHTTP.requests
        let requestBytes = try JSONSerialization.data(withJSONObject: requests.map {
            ["method": $0.method, "url": $0.url, "bodyBase64": $0.body.base64EncodedString()]
        }, options: [.sortedKeys])
        let result = try await Task.detached { () throws -> (files: [String: String], recognized: [String], sha: String, reference: String?) in
            let bytes = try Data(contentsOf: url)
            guard bytes == expected, let imageSource = CGImageSourceCreateWithData(bytes as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil), image.width == format.width, image.height == format.height else {
                throw invalid("The actual downloaded cover has different bytes or aspect dimensions.")
            }
            let receipt = try GenerationOutputReceipt.load(assetID: id, home: home)
            guard receipt.package.id == package.id, receipt.output.sha256 == FileDigest.sha256(of: bytes),
                  receipt.input.aspectRatio == format.aspect else { throw invalid("The actual cover receipt lost its approved package or dimensions.") }
            let recognized: [String]
            if let artist, let title {
                let recognition = VNRecognizeTextRequest()
                recognition.recognitionLevel = .accurate; recognition.usesLanguageCorrection = false
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([recognition])
                recognized = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                guard recognized.contains(artist), recognized.contains(title) else { throw invalid("The downloaded isolated text response does not visibly contain the exact native wording.") }
            } else { recognized = [] }
            var files = [key + ".png": bytes, key + "-asset.json": assetBytes, key + "-batch.json": batchBytes,
                key + "-http.json": requestBytes, key + "-ocr.json": try PlanningWriterIO.json(recognized),
                key + "-receipt.json": try Data(contentsOf: ProjectLocalFile.resolve(GenerationOutputReceipt.path(assetID: id), dataRoot: home)),
                key + "-package.json": try Data(contentsOf: ProjectLocalFile.requireHash(receipt.package.sha256, at: receipt.package.path, dataRoot: home))]
            let referenceSHA: String?
            if let referenceURL, let referenceID {
                let original = try Data(contentsOf: referenceURL)
                referenceSHA = FileDigest.sha256(of: original)
                let uploads = requests.filter { $0.method == "PUT" }
                guard uploads.count == 1, uploads[0].body == original,
                      package.payload.references.count == 1, package.payload.references[0].assetID == referenceID,
                      package.payload.references[0].sourceSHA256 == referenceSHA,
                      package.payload.references[0].submittedSHA256 == referenceSHA else {
                    throw invalid("Typography did not upload the exact retained clean cover.")
                }
                files[key + "-reference.png"] = original
            } else {
                referenceSHA = nil
                guard package.payload.references.isEmpty, requests.allSatisfy({ $0.method != "PUT" }) else { throw invalid("The clean cover unexpectedly acquired a reference.") }
            }
            let directory = output.appendingPathComponent("cover-evidence")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var hashes: [String: String] = [:]
            for (name, data) in files {
                try data.write(to: directory.appendingPathComponent(name), options: .atomic)
                hashes[name] = FileDigest.sha256(of: data)
            }
            return (hashes, recognized, FileDigest.sha256(of: bytes), referenceSHA)
        }.value
        return ["key": key, "format": format.id, "aspect": format.aspect, "width": format.width, "height": format.height,
            "assetID": id, "name": asset.libraryDisplayName, "sha256": result.sha, "packageSHA256": package.id,
            "files": result.files, "artist": artist as Any? ?? NSNull(), "title": title as Any? ?? NSNull(),
            "referenceAssetID": referenceID as Any? ?? NSNull(), "referenceSHA256": result.reference as Any? ?? NSNull(),
            "recognizedText": result.recognized, "liveProvider": false]
    }

    static func requireReopened(_ cover: [String: Any], editor: EditorViewModel, output: URL) async throws {
        guard let kept = cover["kept"] as? [[String: Any]], kept.count == 4 else { throw invalid("The cover result omitted a kept format or typography variant.") }
        for value in kept {
            guard let id = value["assetID"] as? String, let hash = value["sha256"] as? String,
                  let name = value["name"] as? String, let key = value["key"] as? String,
                  let asset = editor.mediaAssets.first(where: { $0.id == id }), asset.libraryDisplayName == name else { throw invalid("A kept cover is missing after save and reopen.") }
            let url = asset.url, manifest = try PlanningWriterIO.json(asset.toManifestEntry(projectURL: editor.workingRoot))
            try await Task.detached {
                let bytes = try Data(contentsOf: url)
                guard FileDigest.sha256(of: bytes) == hash else { throw invalid("A kept cover changed during save and reopen.") }
                try bytes.write(to: output.appendingPathComponent("cover-evidence/" + key + "-reopened.png"), options: .atomic)
                try manifest.write(to: output.appendingPathComponent("cover-evidence/" + key + "-reopened.json"), options: .atomic)
            }.value
        }
    }

    nonisolated private static func invalid(_ detail: String) -> GateBlocked { GateBlocked("Native cover evidence: " + detail) }
}
