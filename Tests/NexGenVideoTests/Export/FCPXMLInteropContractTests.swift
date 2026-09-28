import CoreMedia
import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@Suite("FCPXML interoperability contract", .serialized)
struct FCPXMLInteropContractTests {
    private struct MediaSpec {
        let id: String
        let storageName: String
        var originalFilename: String? = nil
        var type: ClipType = .video
        var duration: Double = 10
        var sourceFPS: Double? = nil
        var hasAudio: Bool? = false
        var sourceWidth: Int? = nil
        var sourceHeight: Int? = nil
    }

    private struct MediaFixture {
        let root: URL
        let project: URL?
        let resolver: MediaResolver
    }

    private struct Oracle: Decodable {
        struct Assertion: Decodable {
            let xpath: String
            let values: [String]
        }
        let assertions: [Assertion]
    }

    private func makeFixture(
        _ specs: [MediaSpec],
        projectOwned: Bool = false
    ) throws -> MediaFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fcpxml-contract-\(UUID().uuidString)", isDirectory: true)
        let project = projectOwned
            ? root.appendingPathComponent("Source.ngv", isDirectory: true)
            : nil
        let storage = projectOwned
            ? project!.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
            : root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)

        var manifest = MediaManifest()
        for spec in specs {
            let file = storage.appendingPathComponent(spec.storageName)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: file.path) {
                try Data("fixture:\(spec.storageName)".utf8).write(to: file)
            }
            var entry = MediaManifestEntry(
                id: spec.id,
                name: spec.id,
                type: spec.type,
                source: projectOwned
                    ? .project(relativePath: "\(Project.mediaDirectoryName)/\(spec.storageName)")
                    : .external(absolutePath: file.path),
                duration: spec.duration
            )
            entry.originalFilename = spec.originalFilename
            entry.sourceFPS = spec.sourceFPS
            entry.hasAudio = spec.hasAudio
            entry.sourceWidth = spec.sourceWidth
            entry.sourceHeight = spec.sourceHeight
            manifest.entries.append(entry)
        }
        let snapshot = manifest
        return MediaFixture(
            root: root,
            project: project,
            resolver: MediaResolver(manifest: { snapshot }, projectURL: { project })
        )
    }

    private func document(_ data: Data) throws -> XMLDocument {
        try XMLDocument(data: data, options: [.nodePreserveAll])
    }

    private func values(_ xpath: String, in document: XMLDocument) throws -> [String] {
        try document.nodes(forXPath: xpath).compactMap(\.stringValue)
    }

    private var structuralOracleURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/FCPXML/structural-oracle.json")
    }

    @Test func everyVersionAndTargetValidatesAgainstItsOfficialAppleDTD() throws {
        let fixture = try makeFixture([
            .init(id: "video", storageName: "Matrix.mov"),
            .init(id: "audio", storageName: "Matrix.wav", type: .audio, hasAudio: true),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        var video = Fixtures.clip(id: "video-clip", mediaRef: "video", start: 0, duration: 60)
        video.transform.rotation = 7
        video.effects = [.make("matrix-effect", ["amount": 0.5])]
        let audio = Fixtures.clip(
            id: "audio-clip", mediaRef: "audio", mediaType: .audio,
            start: 0, duration: 60, volume: 0.5
        )
        var caption = Fixtures.clip(
            id: "caption", mediaRef: "", mediaType: .text,
            start: 30, duration: 30
        )
        caption.textContent = "Version matrix caption"
        caption.captionGroupId = "matrix-captions"
        let timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [video, caption]),
            Fixtures.audioTrack(clips: [audio]),
        ])

        for version in FCPXMLVersion.allCases {
            for target in FCPXMLTarget.allCases {
                let rendered = try FCPXMLExporter.render(
                    timeline: timeline,
                    resolver: fixture.resolver,
                    projectName: "Version matrix",
                    version: version,
                    target: target
                )
                let xml = try document(rendered.data)
                let assets = try xml.nodes(forXPath: "/fcpxml/resources/asset")
                let transforms = try xml.nodes(forXPath: "//asset-clip/adjust-transform")
                #expect(try values("/fcpxml/@version", in: xml) == [version.rawValue])
                #expect(rendered.validation.version == version)
                #expect(rendered.validation.schemaProfile ==
                        "apple/fcpxml-dtd/\(version.rawValue)")
                #expect(rendered.validation.assetCount == 2)
                #expect(assets.count == 2)
                #expect(transforms.count == 1)
                #expect(try values("//title/text/text-style", in: xml) == ["Version matrix caption"])
                #expect(Set(rendered.warnings.map(\.code)).isSuperset(of: [
                    "audio_channel_layout_not_exported",
                    "caption_exported_as_title",
                    "color_metadata_not_exported",
                    "effects_not_exported",
                ]))
            }
        }
    }

    @Test func featureMatrixIsExplicitForEveryVersion() {
        let expected: [String: FCPXMLFeatureDisposition] = [
            "video": .exported,
            "audio": .exportedWithWarning,
            "captions": .exportedWithWarning,
            "transform-keyframes": .exportedWithWarning,
            "source-timecode": .exported,
            "effects": .warningOnly,
            "color-metadata": .warningOnly,
            "lottie": .warningOnly,
        ]
        for version in FCPXMLVersion.allCases {
            let rows = FCPXMLFeatureMatrix.rows(for: version)
            #expect(Dictionary(uniqueKeysWithValues: rows.map { ($0.feature, $0.disposition) }) == expected)
            #expect(rows.allSatisfy { $0.versions == FCPXMLVersion.allCases })
        }
    }

    @Test func targetsUseExplicitTransformDialects() throws {
        let fixture = try makeFixture([
            .init(
                id: "portrait", storageName: "Portrait.mov",
                sourceWidth: 1_080, sourceHeight: 1_920
            ),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var clip = Fixtures.clip(id: "clip", mediaRef: "portrait", start: 0, duration: 30)
        clip.transform.centerX = 0.6
        clip.transform.centerY = 0.4
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])
        let finalCut = try document(FCPXMLExporter.render(
            timeline: timeline,
            resolver: fixture.resolver,
            target: .finalCutPro
        ).data)
        let resolve = try document(FCPXMLExporter.render(
            timeline: timeline,
            resolver: fixture.resolver,
            target: .resolve
        ).data)
        let finalCutPosition = try values("//adjust-transform/@position", in: finalCut)
        let resolvePosition = try values("//adjust-transform/@position", in: resolve)
        #expect(finalCutPosition.count == 1)
        #expect(resolvePosition.count == 1)
        #expect(finalCutPosition != resolvePosition)
    }

    @Test func exactNTSCFrameDurationsRemainRational() throws {
        let fixture = try makeFixture([
            .init(id: "p23976", storageName: "23.976.mov", sourceFPS: 24_000.0 / 1_001.0),
            .init(id: "p2997", storageName: "29.97.mov", sourceFPS: 30_000.0 / 1_001.0),
            .init(id: "p5994", storageName: "59.94.mov", sourceFPS: 60_000.0 / 1_001.0),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let clips = [
            Fixtures.clip(id: "c24", mediaRef: "p23976", start: 0, duration: 24),
            Fixtures.clip(id: "c30", mediaRef: "p2997", start: 30, duration: 30),
            Fixtures.clip(id: "c60", mediaRef: "p5994", start: 60, duration: 60),
        ]
        let rendered = try FCPXMLExporter.render(
            timeline: Fixtures.timeline(fps: 30, tracks: [Fixtures.videoTrack(clips: clips)]),
            resolver: fixture.resolver
        )
        let xml = try document(rendered.data)
        let durations = try values(
            "/fcpxml/resources/format[starts-with(@id,'format-')]/@frameDuration",
            in: xml
        ).sorted()
        #expect(durations == ["1001/24000s", "1001/30000s", "1001/60000s"])
    }

    @Test func containerSampleOffsetsUseExactRationalArithmetic() {
        #expect(SourceTimingReader.sampleFrameOffset(
            presentationTime: CMTime(value: 180_180, timescale: 60_000),
            frameDuration: CMTime(value: 1_001, timescale: 30_000)
        ) == 90)
        #expect(SourceTimingReader.sampleFrameOffset(
            presentationTime: CMTime(value: -1_001, timescale: 60_000),
            frameDuration: CMTime(value: 1_001, timescale: 30_000)
        ) == -1)
    }

    @Test func sourceDurationKeepsItsContainerRationalInsteadOfTimelineFrames() throws {
        let fixture = try makeFixture([
            .init(id: "video", storageName: "Duration.mov", duration: 3.33),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let clip = Fixtures.clip(
            id: "retimed", mediaRef: "video", start: 0, duration: 30, speed: 2
        )
        let rendered = try FCPXMLExporter.render(
            timeline: Fixtures.timeline(fps: 30, tracks: [Fixtures.videoTrack(clips: [clip])]),
            resolver: fixture.resolver,
            sourceDurations: [
                "video": try #require(RationalSeconds(numerator: 1_001, denominator: 300)),
            ]
        )
        let xml = try document(rendered.data)
        #expect(try values("/fcpxml/resources/asset/@duration", in: xml) == ["1001/300s"])
        #expect(try values("//asset-clip/timeMap/timept[2]/@time", in: xml) == ["1001/600s"])
        #expect(try values("//asset-clip/timeMap/timept[2]/@value", in: xml) == ["1001/300s"])
    }

    @Test func unusualFractionalRatesAreNotCoercedToNTSC() throws {
        let fixture = try makeFixture([
            .init(id: "p235", storageName: "23.5.mov", sourceFPS: 23.5),
            .init(id: "p295", storageName: "29.5.mov", sourceFPS: 29.5),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "c235", mediaRef: "p235", start: 0, duration: 30),
            Fixtures.clip(id: "c295", mediaRef: "p295", start: 30, duration: 30),
        ])])
        let rendered = try FCPXMLExporter.render(timeline: timeline, resolver: fixture.resolver)
        let xml = try document(rendered.data)
        let durations = try values(
            "/fcpxml/resources/format[starts-with(@id,'format-')]/@frameDuration",
            in: xml
        ).sorted()
        #expect(durations == ["2/47s", "2/59s"])
        #expect(!durations.contains("1001/24000s"))
        #expect(!durations.contains("1001/30000s"))
        #expect(Set(rendered.warnings.map(\.code)) == ["color_metadata_not_exported", "nonstandard_source_rate"])
        #expect(try values(
            "/fcpxml/resources/format[starts-with(@id,'format-')]/@name",
            in: xml
        ) == ["FFVideoFormatRateUndefined", "FFVideoFormatRateUndefined"])
    }

    @Test func sourceOriginsTrimsAndDropModesRemainExact() throws {
        let fixture = try makeFixture([
            .init(id: "df", storageName: "DF.mov", originalFilename: "DF.mov"),
            .init(id: "ndf", storageName: "NDF.mov", originalFilename: "NDF.mov"),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let clips = [
            Fixtures.clip(id: "df-clip", mediaRef: "df", start: 0, duration: 30, trimStart: 15),
            Fixtures.clip(id: "ndf-clip", mediaRef: "ndf", start: 30, duration: 30, trimStart: 24),
        ]
        let rendered = try FCPXMLExporter.render(
            timeline: Fixtures.timeline(fps: 30, tracks: [Fixtures.videoTrack(clips: clips)]),
            resolver: fixture.resolver,
            sourceTimecodes: [
                "df": .init(
                    frame: 17_982,
                    quanta: 30,
                    dropFrame: true,
                    tick: .init(numerator: 1_001, denominator: 30_000)
                ),
                "ndf": .init(
                    frame: 2_400,
                    quanta: 24,
                    dropFrame: false,
                    tick: .init(numerator: 1_001, denominator: 24_000)
                ),
            ]
        )
        let xml = try document(rendered.data)
        #expect(try values("/fcpxml/resources/asset[@name='DF.mov']/@start", in: xml) == ["2999997/5000s"])
        #expect(try values("/fcpxml/resources/asset[@name='NDF.mov']/@start", in: xml) == ["1001/10s"])
        #expect(try values("//asset-clip[@name='DF.mov']/@start", in: xml) == ["3002497/5000s"])
        #expect(try values("//asset-clip[@name='NDF.mov']/@start", in: xml) == ["1009/10s"])
        #expect(try values("//asset-clip[@name='DF.mov']/@tcFormat", in: xml) == ["DF"])
        #expect(try values("//asset-clip[@name='NDF.mov']/@tcFormat", in: xml) == ["NDF"])
        #expect(try values("//asset-clip[@name='DF.mov']/@duration", in: xml) == ["1s"])
    }

    @Test func compoundStaysZeroBasedWhileInnerClipUsesSourceOrigin() throws {
        let fixture = try makeFixture([
            .init(id: "av", storageName: "Interview.mov", originalFilename: "Interview.mov", hasAudio: true),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let clip = Fixtures.clip(id: "video-only", mediaRef: "av", start: 60, duration: 30, trimStart: 10)
        let rendered = try FCPXMLExporter.render(
            timeline: Fixtures.timeline(fps: 30, tracks: [Fixtures.videoTrack(clips: [clip])]),
            resolver: fixture.resolver,
            sourceTimecodes: [
                "av": .init(
                    frame: 36_000,
                    quanta: 30,
                    dropFrame: true,
                    tick: .init(numerator: 1_001, denominator: 30_000)
                ),
            ]
        )
        let xml = try document(rendered.data)
        #expect(try values("/fcpxml/resources/media/sequence/@tcStart", in: xml) == ["0s"])
        #expect(try values("/fcpxml/resources/media/sequence/spine/asset-clip/@offset", in: xml) == ["0s"])
        #expect(try values("/fcpxml/resources/media/sequence/spine/asset-clip/@start", in: xml) == ["6006/5s"])
        #expect(try values("//gap/ref-clip/@start", in: xml) == ["1/3s"])
    }

    @Test func retimedSourceRangeCarriesExactOriginInTimeMap() throws {
        let fixture = try makeFixture([
            .init(id: "retimed", storageName: "Retime.mov", originalFilename: "Retime.mov"),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let clip = Fixtures.clip(
            id: "retimed-clip", mediaRef: "retimed",
            start: 0, duration: 30, trimStart: 30, speed: 2
        )
        let rendered = try FCPXMLExporter.render(
            timeline: Fixtures.timeline(fps: 30, tracks: [Fixtures.videoTrack(clips: [clip])]),
            resolver: fixture.resolver,
            sourceTimecodes: [
                "retimed": .init(
                    frame: 2_400,
                    quanta: 24,
                    dropFrame: false,
                    tick: .init(numerator: 1_001, denominator: 24_000)
                ),
            ]
        )
        let xml = try document(rendered.data)
        #expect(try values("//asset-clip[@name='Retime.mov']/@start", in: xml) == ["1/2s"])
        #expect(try values("//asset-clip[@name='Retime.mov']/@duration", in: xml) == ["1s"])
        #expect(try values("//asset-clip[@name='Retime.mov']/timeMap/timept[1]/@time", in: xml) == ["0s"])
        #expect(try values("//asset-clip[@name='Retime.mov']/timeMap/timept[1]/@value", in: xml) == ["1001/10s"])
        #expect(try values("//asset-clip[@name='Retime.mov']/timeMap/timept[2]/@time", in: xml) == ["5s"])
        #expect(try values("//asset-clip[@name='Retime.mov']/timeMap/timept[2]/@value", in: xml) == ["1101/10s"])
    }

    @Test func keyframesUseEachOwningClipsLocalTimeline() throws {
        let fixture = try makeFixture([
            .init(id: "direct", storageName: "Direct.mov", originalFilename: "Direct.mov"),
            .init(id: "still", storageName: "Still.png", originalFilename: "Still.png", type: .image),
            .init(id: "compound", storageName: "Compound.mov", originalFilename: "Compound.mov", hasAudio: true),
            .init(id: "retimed", storageName: "Retimed.mov", originalFilename: "Retimed.mov"),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        var direct = Fixtures.clip(
            id: "direct-clip", mediaRef: "direct", start: 30, duration: 60, trimStart: 10
        )
        direct.positionTrack = KeyframeTrack(keyframes: [
            .init(frame: 0, value: .init(a: 0, b: 0)),
            .init(frame: 15, value: .init(a: 0.1, b: 0.1)),
        ])
        var still = Fixtures.clip(
            id: "still-clip", mediaRef: "still", mediaType: .image,
            start: 120, duration: 60, trimStart: 5
        )
        still.positionTrack = KeyframeTrack(keyframes: [
            .init(frame: 0, value: .init(a: 0, b: 0)),
            .init(frame: 15, value: .init(a: 0.1, b: 0.1)),
        ])
        var compound = Fixtures.clip(
            id: "compound-clip", mediaRef: "compound", start: 210, duration: 60, trimStart: 12
        )
        compound.positionTrack = KeyframeTrack(keyframes: [
            .init(frame: 0, value: .init(a: 0, b: 0)),
            .init(frame: 15, value: .init(a: 0.1, b: 0.1)),
        ])
        var retimed = Fixtures.clip(
            id: "retimed-clip", mediaRef: "retimed",
            start: 300, duration: 60, trimStart: 20, speed: 2
        )
        retimed.positionTrack = KeyframeTrack(keyframes: [
            .init(frame: 0, value: .init(a: 0, b: 0)),
            .init(frame: 15, value: .init(a: 0.1, b: 0.1)),
        ])
        var title = Fixtures.clip(
            id: "title-clip", mediaRef: "", mediaType: .text,
            start: 390, duration: 60, trimStart: 17, speed: 2
        )
        title.textContent = "Local title"
        title.opacityTrack = KeyframeTrack(keyframes: [
            .init(frame: 0, value: 1),
            .init(frame: 15, value: 0.5),
        ])

        let rendered = try FCPXMLExporter.render(
            timeline: Fixtures.timeline(fps: 30, tracks: [
                Fixtures.videoTrack(clips: [direct, still, compound, retimed, title]),
            ]),
            resolver: fixture.resolver,
            sourceTimecodes: [
                "direct": .init(
                    frame: 36_000,
                    quanta: 30,
                    dropFrame: true,
                    tick: .init(numerator: 1_001, denominator: 30_000)
                ),
                "still": .init(
                    frame: 300,
                    quanta: 30,
                    dropFrame: false,
                    tick: .init(numerator: 1, denominator: 30)
                ),
                "compound": .init(
                    frame: 36_000,
                    quanta: 30,
                    dropFrame: true,
                    tick: .init(numerator: 1_001, denominator: 30_000)
                ),
                "retimed": .init(
                    frame: 2_400,
                    quanta: 24,
                    dropFrame: false,
                    tick: .init(numerator: 1_001, denominator: 24_000)
                ),
            ]
        )
        let xml = try document(rendered.data)

        #expect(try values("//asset-clip[@name='Direct.mov']/@start", in: xml) == ["18023/15s"])
        #expect(try values(
            "//asset-clip[@name='Direct.mov']/adjust-transform/param[@name='position']//keyframe/@time",
            in: xml
        ) == ["18023/15s", "36061/30s"])
        #expect(try values("//video[@name='Still.png']/@start", in: xml) == ["61/6s"])
        #expect(try values(
            "//video[@name='Still.png']/adjust-transform/param[@name='position']//keyframe/@time",
            in: xml
        ) == ["61/6s", "32/3s"])
        #expect(try values("//ref-clip[@name='Compound.mov']/@start", in: xml) == ["2/5s"])
        #expect(try values(
            "//ref-clip[@name='Compound.mov']/adjust-transform/param[@name='position']//keyframe/@time",
            in: xml
        ) == ["2/5s", "9/10s"])
        #expect(try values("//asset-clip[@name='Retimed.mov']/@start", in: xml) == ["1/3s"])
        #expect(try values(
            "//asset-clip[@name='Retimed.mov']/adjust-transform/param[@name='position']//keyframe/@time",
            in: xml
        ) == ["1/3s", "5/6s"])
        #expect(try values("//title[@name='Local title']/@start", in: xml) == ["0s"])
        #expect(try values(
            "//title[@name='Local title']/adjust-blend/param[@name='amount']//keyframe/@time",
            in: xml
        ) == ["0s", "1/2s"])
    }

    @Test func projectAliasesRelinkOnceWithStableReadableIdentity() async throws {
        let fixture = try makeFixture([
            .init(id: "canonical", storageName: "Camera.mov", originalFilename: "Camera Original.mov"),
        ], projectOwned: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let projectURL = try #require(fixture.project)
        let alias = projectURL
            .appendingPathComponent(Project.mediaDirectoryName)
            .appendingPathComponent("Alias.mov")
        try FileManager.default.createSymbolicLink(
            at: alias,
            withDestinationURL: alias.deletingLastPathComponent().appendingPathComponent("Camera.mov")
        )
        var manifest = MediaManifest()
        manifest.entries = [
            MediaManifestEntry(
                id: "canonical", name: "Camera", type: .video,
                source: .project(relativePath: "\(Project.mediaDirectoryName)/Camera.mov"), duration: 10
            ),
            MediaManifestEntry(
                id: "alias", name: "Alias", type: .video,
                source: .project(relativePath: "\(Project.mediaDirectoryName)/Alias.mov"), duration: 10
            ),
        ]
        manifest.entries[0].originalFilename = "Camera Original.mov"
        manifest.entries[1].originalFilename = "Camera Original.mov"
        let project = fixture.project
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { project })
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "one", mediaRef: "canonical", start: 0, duration: 30),
            Fixtures.clip(id: "two", mediaRef: "alias", start: 30, duration: 30),
        ])])
        let output = fixture.root.appendingPathComponent("Editorial.fcpxml")
        let canonicalOnly = try FCPXMLExporter.render(
            timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "canonical-only", mediaRef: "canonical", start: 0, duration: 30),
            ])]),
            resolver: fixture.resolver
        )

        let first = try await FCPXMLExporter.export(
            timeline: timeline,
            resolver: resolver,
            projectName: "Editorial",
            version: .v1_14,
            target: .resolve,
            outputURL: output
        )
        let firstBytes = try Data(contentsOf: output)
        let firstBinding = try #require(first.mediaBindings.first)
        let stagedURL = try #require(URL(string: firstBinding.sourceURL))
        let sourceURL = projectURL
            .appendingPathComponent(Project.mediaDirectoryName)
            .appendingPathComponent("Camera.mov")
        let sourceBytes = try Data(contentsOf: sourceURL)
        let staleBytes = Data(sourceBytes.map { $0 ^ 0xFF })
        #expect(staleBytes.count == sourceBytes.count)
        try staleBytes.write(to: stagedURL)
        #expect(try FileDigest.sha256(of: stagedURL) != FileDigest.sha256(of: sourceURL))

        let second = try await FCPXMLExporter.export(
            timeline: timeline,
            resolver: resolver,
            projectName: "Editorial",
            version: .v1_14,
            target: .resolve,
            outputURL: output
        )
        let sidecar = fixture.root.appendingPathComponent("Editorial Media", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: sidecar,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        let secondBinding = try #require(second.mediaBindings.first)
        let stagedValues = try stagedURL.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        let secondBytes = try Data(contentsOf: output)

        #expect(first.mediaBindings.count == 1)
        #expect(first.mediaBindings[0].mediaRefs == ["alias", "canonical"])
        #expect(first.mediaBindings[0].filename == "Camera Original.mov")
        #expect(stagedURL.lastPathComponent.hasPrefix("Camera Original--"))
        #expect(stagedURL.lastPathComponent.hasSuffix(".mov"))
        #expect(files.count == 1)
        #expect(stagedValues.isRegularFile == true)
        #expect(stagedValues.isSymbolicLink == false)
        #expect(stagedValues.fileSize == sourceBytes.count)
        #expect(try Data(contentsOf: stagedURL) == sourceBytes)
        #expect(secondBinding.mediaSHA256 == FileDigest.sha256(of: sourceBytes))
        #expect(secondBinding.mediaByteCount == Int64(sourceBytes.count))
        #expect(secondBinding.stagedProjectMedia)
        #expect(second.mediaByteCount == Int64(sourceBytes.count))
        #expect(second.stagedProjectMediaCount == 1)
        #expect(canonicalOnly.mediaBindings[0].assetID == firstBinding.assetID)
        #expect(firstBinding.assetID == secondBinding.assetID)
        #expect(first.outputSHA256 == second.outputSHA256)
        #expect(firstBytes == secondBytes)

        let movedProject = fixture.root.appendingPathComponent("Source-moved.ngv", isDirectory: true)
        try FileManager.default.moveItem(at: projectURL, to: movedProject)
        #expect(try Data(contentsOf: stagedURL) == sourceBytes)
    }

    @Test func duplicateExternalFilenamesWarnWithoutClaimingSidecarSuffixes() throws {
        let fixture = try makeFixture([
            .init(id: "one", storageName: "one/Camera.mov", originalFilename: "Camera.mov"),
            .init(id: "two", storageName: "two/Camera.mov", originalFilename: "Camera.mov"),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let rendered = try FCPXMLExporter.render(
            timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "one-clip", mediaRef: "one", start: 0, duration: 30),
                Fixtures.clip(id: "two-clip", mediaRef: "two", start: 30, duration: 30),
            ])]),
            resolver: fixture.resolver
        )
        let warning = try #require(rendered.warnings.first(where: {
            $0.code == "duplicate_external_filename"
        }))
        #expect(warning.message.contains("full source URLs remain distinct"))
        #expect(!warning.message.contains("deterministic suffixes"))
        #expect(rendered.mediaBindings.map(\.filename) == ["Camera.mov", "Camera.mov"])
    }

    @Test func stagingAndEvidenceContainExactlyEmittedMedia() async throws {
        let fixture = try makeFixture([
            .init(id: "valid", storageName: "valid-storage.mov", originalFilename: "Valid.mov"),
            .init(id: "lottie", storageName: "lottie-storage.json", type: .lottie),
            .init(id: "document", storageName: "document-storage.md", type: .document),
            .init(id: "zero", storageName: "zero-storage.mov"),
            .init(id: "unsupported-track", storageName: "unsupported-track.mov"),
            .init(id: "offline", storageName: "offline-storage.mov"),
        ], projectOwned: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let project = try #require(fixture.project)
        let mediaDirectory = project.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
        for name in [
            "lottie-storage.json", "document-storage.md", "zero-storage.mov", "unsupported-track.mov",
        ] {
            let url = mediaDirectory.appendingPathComponent(name)
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try FileManager.default.removeItem(at: mediaDirectory.appendingPathComponent("offline-storage.mov"))

        let timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "valid-clip", mediaRef: "valid", start: 0, duration: 30),
                Fixtures.clip(
                    id: "lottie-clip", mediaRef: "lottie", mediaType: .lottie,
                    start: 30, duration: 30
                ),
                Fixtures.clip(
                    id: "document-clip", mediaRef: "document", mediaType: .document,
                    start: 60, duration: 30
                ),
                Fixtures.clip(id: "zero-clip", mediaRef: "zero", start: 90, duration: 0),
                Fixtures.clip(id: "offline-clip", mediaRef: "offline", start: 90, duration: 30),
            ]),
            Track(type: .document, clips: [
                Fixtures.clip(
                    id: "unsupported-track-clip", mediaRef: "unsupported-track",
                    start: 0, duration: 30
                ),
            ]),
        ])
        let output = fixture.root.appendingPathComponent("Selection.fcpxml")
        let report = try await FCPXMLExporter.export(
            timeline: timeline,
            resolver: fixture.resolver,
            projectName: "Selection",
            outputURL: output
        )
        let sidecar = fixture.root.appendingPathComponent("Selection Media", isDirectory: true)
        let sidecarFiles = try FileManager.default.contentsOfDirectory(
            at: sidecar,
            includingPropertiesForKeys: [.isRegularFileKey]
        ).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        let binding = try #require(report.mediaBindings.first)
        let bindingURL = try #require(URL(string: binding.sourceURL))

        #expect(Set(report.warnings.map(\.code)) == [
            "color_metadata_not_exported",
            "document_not_timeline_media",
            "lottie_requires_render",
            "offline_media",
        ])
        #expect(report.warnings.first(where: {
            $0.code == "lottie_requires_render"
        })?.clipID == "lottie-clip")
        #expect(report.warnings.first(where: {
            $0.code == "document_not_timeline_media"
        })?.clipID == "document-clip")
        #expect(report.warnings.first(where: {
            $0.code == "offline_media"
        })?.clipID == "offline-clip")
        #expect(report.validation.assetCount == 1)
        #expect(report.mediaBindings.count == 1)
        #expect(binding.mediaRefs == ["valid"])
        #expect(report.stagedProjectMediaCount == 1)
        #expect(sidecarFiles == [bindingURL])
        #expect(binding.mediaSHA256 == (try FileDigest.sha256(of: bindingURL)))
        #expect(binding.mediaByteCount == Int64((try Data(contentsOf: bindingURL)).count))
        #expect(report.mediaByteCount == binding.mediaByteCount)
    }

    @Test func emittedMediaStillFailsOnARealReadError() async throws {
        let fixture = try makeFixture([
            .init(id: "invalid", storageName: "invalid-storage.mov", originalFilename: "Invalid.mov"),
        ], projectOwned: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let project = try #require(fixture.project)
        let invalidSource = project
            .appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
            .appendingPathComponent("invalid-storage.mov")
        try FileManager.default.removeItem(at: invalidSource)
        try FileManager.default.createDirectory(at: invalidSource, withIntermediateDirectories: true)
        let output = fixture.root.appendingPathComponent("Invalid.fcpxml")

        do {
            _ = try await FCPXMLExporter.export(
                timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [
                    Fixtures.clip(id: "invalid-clip", mediaRef: "invalid", start: 0, duration: 30),
                ])]),
                resolver: fixture.resolver,
                projectName: "Invalid",
                outputURL: output
            )
            Issue.record("Non-regular emitted media unexpectedly exported")
        } catch ExportError.xmlMediaReadFailed(let source, let reason) {
            #expect(source == invalidSource.resolvingSymlinksInPath())
            #expect(reason.contains("regular file"))
        } catch {
            Issue.record("Unexpected emitted-media error: \(error)")
        }

        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent("Invalid Media", isDirectory: true).path
        ))
    }

    @Test func videoAudioCaptionsTransformsAndEffectsExportOrWarn() throws {
        let fixture = try makeFixture([
            .init(id: "video", storageName: "video.mov"),
            .init(id: "audio", storageName: "audio.wav", type: .audio, hasAudio: true),
            .init(id: "lottie", storageName: "graphic.json", type: .lottie),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        var video = Fixtures.clip(id: "video-clip", mediaRef: "video", start: 0, duration: 60)
        video.opacity = 0.75
        video.transform = Transform(centerX: 0.6, centerY: 0.4, width: 0.8, height: 0.9, rotation: 12)
        video.crop = Crop(left: 0.1, top: 0.2, right: 0.05, bottom: 0)
        video.cropTrack = KeyframeTrack(keyframes: [.init(frame: 0, value: video.crop)])
        video.positionTrack = KeyframeTrack(keyframes: [
            .init(frame: 0, value: AnimPair(a: 0.1, b: 0.1), interpolationOut: .smooth),
        ])
        video.effects = [.make("denoise", ["amount": 0.5])]
        video.fadeInFrames = 5

        var audio = Fixtures.clip(
            id: "audio-clip", mediaRef: "audio", mediaType: .audio,
            start: 0, duration: 60, volume: 0.5
        )
        audio.volumeTrack = KeyframeTrack(keyframes: [.init(frame: 0, value: -6)])

        var caption = Fixtures.clip(id: "caption", mediaRef: "", mediaType: .text, start: 0, duration: 30)
        caption.textContent = "Caption"
        caption.captionGroupId = "captions"
        caption.transform.rotation = 5
        var style = TextStyle()
        style.background.enabled = true
        style.border.enabled = true
        caption.textStyle = style

        let lottie = Fixtures.clip(
            id: "lottie-clip", mediaRef: "lottie", mediaType: .lottie,
            start: 0, duration: 30
        )
        let timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [video, caption, lottie]),
            Fixtures.audioTrack(clips: [audio]),
        ])
        let rendered = try FCPXMLExporter.render(timeline: timeline, resolver: fixture.resolver)
        let xml = try document(rendered.data)
        let codes = Set(rendered.warnings.map(\.code))

        #expect(try values("//asset-clip[@name='video.mov']/adjust-crop/@mode", in: xml) == ["trim"])
        #expect(try values("//asset-clip[@name='video.mov']/adjust-transform/@rotation", in: xml) == ["-12"])
        #expect(try values("//asset-clip[@name='video.mov']/adjust-blend/@amount", in: xml) == ["0.75"])
        #expect(try values("//asset-clip[@name='audio.wav']/adjust-volume/@amount", in: xml) == ["-6.0206dB"])
        #expect(try values("//title/text/text-style", in: xml) == ["Caption"])
        #expect(codes == [
            "audio_channel_layout_not_exported",
            "caption_exported_as_title",
            "color_metadata_not_exported",
            "crop_animation_not_exported",
            "effects_not_exported",
            "fades_not_exported",
            "keyframe_easing_approximated",
            "lottie_requires_render",
            "title_background_not_exported",
            "title_border_not_exported",
            "title_shadow_not_exported",
            "title_transform_partial",
            "volume_animation_not_exported",
        ])
    }

    @Test func persistedQCReportMatchesExactBytesAndDoesNotMutate() async throws {
        let fixture = try makeFixture([
            .init(id: "video", storageName: "QC.mov", originalFilename: "QC.mov"),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "clip", mediaRef: "video", start: 0, duration: 30),
        ])])
        let output = fixture.root.appendingPathComponent("QC.fcpxml")
        let report = try await FCPXMLExporter.export(
            timeline: timeline,
            resolver: fixture.resolver,
            projectName: "QC",
            version: .v1_13,
            target: .finalCutPro,
            outputURL: output
        )
        let persisted = try Data(contentsOf: output)
        let recordedHash = report.outputSHA256
        let recordedBytes = report.outputByteCount
        let recordedValidation = report.validation

        #expect(recordedHash == FileDigest.sha256(of: persisted))
        #expect(recordedBytes == Int64(persisted.count))
        #expect(recordedValidation.version == .v1_13)
        #expect(recordedValidation.assetCount == 1)
        let mediaBinding = try #require(report.mediaBindings.first)
        let sourceMedia = fixture.root.appendingPathComponent("external/QC.mov")
        #expect(mediaBinding.mediaSHA256 == (try FileDigest.sha256(of: sourceMedia)))
        #expect(mediaBinding.mediaByteCount == Int64((try Data(contentsOf: sourceMedia)).count))
        try Data("changed-after-export".utf8).write(to: output)
        #expect(report.outputSHA256 == recordedHash)
        #expect(report.outputByteCount == recordedBytes)
        #expect(report.validation == recordedValidation)
    }

    @Test func writeCancellationValidationAndTimingFailuresPropagate() async throws {
        let fixture = try makeFixture([
            .init(id: "video", storageName: "failure.mov", sourceFPS: .leastNonzeroMagnitude),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "clip", mediaRef: "video", start: 0, duration: 30),
        ])])

        do {
            _ = try FCPXMLExporter.render(timeline: timeline, resolver: fixture.resolver)
            Issue.record("Unrepresentable timing unexpectedly rendered")
        } catch ExportError.xmlTimingInvalid {
        } catch {
            Issue.record("Unexpected timing error: \(error)")
        }

        let invalid = Data("""
            <?xml version="1.0"?><fcpxml version="1.14"><resources/><library unexpected="1"/></fcpxml>
            """.utf8)
        do {
            _ = try FCPXMLSchemaValidator.validate(invalid, version: .v1_14)
            Issue.record("Invalid schema document unexpectedly validated")
        } catch ExportError.xmlValidationFailed {
        } catch {
            Issue.record("Unexpected validation error: \(error)")
        }

        let directoryDestination = fixture.root.appendingPathComponent("directory.fcpxml", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryDestination, withIntermediateDirectories: true)
        do {
            _ = try await FCPXMLExporter.export(
                timeline: timeline,
                resolver: fixture.resolver,
                projectName: "Failure",
                outputURL: directoryDestination
            )
            Issue.record("Directory destination unexpectedly succeeded")
        } catch ExportError.xmlWriteFailed {
        } catch {
            Issue.record("Unexpected write error: \(error)")
        }

        do {
            _ = try await FCPXMLExporter.export(
                timeline: Fixtures.timeline(),
                resolver: fixture.resolver,
                projectName: "Cancelled",
                outputURL: fixture.root.appendingPathComponent("cancelled.fcpxml"),
                isCancelled: { true }
            )
            Issue.record("Cancelled export unexpectedly succeeded")
        } catch is CancellationError {
        } catch {
            Issue.record("Unexpected cancellation error: \(error)")
        }
    }

    @Test func invalidXMLControlCharacterNamesTheClipAndRemedy() throws {
        var title = Fixtures.clip(
            id: "bad-title", mediaRef: "", mediaType: .text, start: 0, duration: 30
        )
        title.textContent = "Before\u{000B}After"
        do {
            _ = try FCPXMLExporter.render(
                timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [title])]),
                resolver: MediaResolver(manifest: { MediaManifest() }, projectURL: { nil })
            )
            Issue.record("Invalid XML control character unexpectedly rendered")
        } catch ExportError.xmlInvalidCharacter(let context, let codePoint) {
            #expect(context == "Text clip \"bad-title\" content")
            #expect(codePoint == "U+000B")
            #expect(ExportError.xmlInvalidCharacter(
                context: context,
                codePoint: codePoint
            ).localizedDescription.contains("Remove it and export again"))
        } catch {
            Issue.record("Unexpected invalid-character error: \(error)")
        }
    }

    @Test func postWriteValidationFailurePreservesExistingOutput() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fcpxml-transaction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("Protected.fcpxml")
        let original = Data("existing validated handoff".utf8)
        try original.write(to: output)
        let invalid = Data("""
            <?xml version="1.0"?><fcpxml version="1.14"><resources/><library unexpected="1"/></fcpxml>
            """.utf8)

        do {
            _ = try await FCPXMLExporter.writeValidated(
                invalid,
                version: .v1_14,
                outputURL: output
            )
            Issue.record("Invalid staged XML unexpectedly replaced the destination")
        } catch ExportError.xmlValidationFailed {
        } catch {
            Issue.record("Unexpected transactional validation error: \(error)")
        }

        #expect(try Data(contentsOf: output) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["Protected.fcpxml"])
    }

    @Test @MainActor func hashingReportsProgressAndObservesCancellation() async throws {
        let fixture = try makeFixture([
            .init(id: "large", storageName: "Large.mov", originalFilename: "Large.mov"),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("external/Large.mov")
        try Data(repeating: 0xA5, count: 3 * 1_048_576).write(to: source)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "large-clip", mediaRef: "large", start: 0, duration: 30),
        ])])
        var cancelRequested = false
        var observedProgress: [Double] = []

        do {
            _ = try await FCPXMLExporter.export(
                timeline: timeline,
                resolver: fixture.resolver,
                projectName: "Cancelled hash",
                outputURL: fixture.root.appendingPathComponent("Cancelled.fcpxml"),
                isCancelled: { cancelRequested },
                progress: { value in
                    observedProgress.append(value)
                    if value > 0.5 { cancelRequested = true }
                }
            )
            Issue.record("Hashing cancellation unexpectedly succeeded")
        } catch is CancellationError {
        } catch {
            Issue.record("Unexpected hashing cancellation error: \(error)")
        }

        #expect(observedProgress.contains(where: { $0 > 0.5 && $0 < 1 }))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent("Cancelled.fcpxml").path
        ))
    }

    @Test func sourceTimecodeRationalOverflowPropagates() throws {
        let fixture = try makeFixture([
            .init(id: "video", storageName: "Overflow.mov"),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "clip", mediaRef: "video", start: 0, duration: 30),
        ])])
        let overflow = SourceTimecode(
            frame: Int.max,
            quanta: 30,
            dropFrame: false,
            tick: .init(numerator: Int64.max, denominator: 30)
        )
        #expect(overflow.rationalSeconds == nil)
        do {
            _ = try FCPXMLExporter.render(
                timeline: timeline,
                resolver: fixture.resolver,
                sourceTimecodes: ["video": overflow]
            )
            Issue.record("Overflowing source origin unexpectedly rendered")
        } catch ExportError.xmlTimingInvalid {
        } catch {
            Issue.record("Unexpected overflow error: \(error)")
        }
    }

    @Test func failedWriteCleansOnlySidecarsCreatedByThatAttempt() async throws {
        let fixture = try makeFixture([
            .init(id: "video", storageName: "Cleanup.mov", originalFilename: "Cleanup.mov"),
        ], projectOwned: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "clip", mediaRef: "video", start: 0, duration: 30),
        ])])
        let output = fixture.root.appendingPathComponent("Bad.fcpxml")
        let sidecar = fixture.root.appendingPathComponent("Bad Media", isDirectory: true)
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: true)
        let sentinel = sidecar.appendingPathComponent("keep.txt")
        try Data("pre-existing".utf8).write(to: sentinel)

        do {
            _ = try await FCPXMLExporter.export(
                timeline: timeline,
                resolver: fixture.resolver,
                projectName: "Cleanup\u{000B}",
                outputURL: output
            )
            Issue.record("Invalid project name unexpectedly succeeded")
        } catch ExportError.xmlInvalidCharacter {
        } catch {
            Issue.record("Unexpected cleanup error: \(error)")
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: sidecar.path) == ["keep.txt"])
        #expect(try Data(contentsOf: sentinel) == Data("pre-existing".utf8))
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func independentXPathFixtureChecksStructuralRoundtrip() throws {
        let fixture = try makeFixture([
            .init(
                id: "camera",
                storageName: "opaque-storage.mov",
                originalFilename: "Camera A.mov",
                sourceFPS: 30_000.0 / 1_001.0
            ),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var camera = Fixtures.clip(
            id: "camera-clip", mediaRef: "camera", start: 30, duration: 60, trimStart: 10
        )
        camera.transform.rotation = 12
        var title = Fixtures.clip(
            id: "title", mediaRef: "", mediaType: .text, start: 90, duration: 30
        )
        title.textContent = "Picture lock"
        let timeline = Fixtures.timeline(fps: 30, tracks: [Fixtures.videoTrack(clips: [camera, title])])
        let rendered = try FCPXMLExporter.render(
            timeline: timeline,
            resolver: fixture.resolver,
            projectName: "Independent oracle",
            version: .v1_14,
            target: .finalCutPro,
            sourceTimecodes: [
                "camera": .init(
                    frame: 36_000,
                    quanta: 30,
                    dropFrame: true,
                    tick: .init(numerator: 1_001, denominator: 30_000)
                ),
            ]
        )
        let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: structuralOracleURL))
        let xml = try document(rendered.data)

        for assertion in oracle.assertions {
            #expect(try values(assertion.xpath, in: xml) == assertion.values, "XPath: \(assertion.xpath)")
        }
    }
}
