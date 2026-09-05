import Foundation
import Testing
@testable import NexGenVideo

@Suite("Spend approval selection preferences")
struct SpendSelectionPreferencesTests {
    @Test func exactImageProviderAndModelAreRestored() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let runway = option(modelID: "image-model", provider: .runway)
        let fal = option(modelID: "image-model", provider: .fal)
        let approval = SpendApproval(
            id: "first",
            recommendedOptionId: runway.id,
            options: [runway, fal],
            actionLabel: "Generate image",
            selectionScope: .image
        )

        SpendSelectionPreferences.record(fal, for: approval, defaults: defaults)
        let next = SpendSelectionPreferences.applyingStoredSelection(
            to: SpendApproval(
                id: "next",
                recommendedOptionId: runway.id,
                options: [runway, fal],
                actionLabel: "Generate image",
                selectionScope: .image
            ),
            defaults: defaults
        )

        #expect(next.recommendedOptionId == fal.id)
        #expect(next.options.first == fal)
    }

    @Test func preferredProviderSurvivesWhenThePreviousModelIsUnavailable() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let previousFal = option(modelID: "old-model", provider: .fal)
        let previous = SpendApproval(
            id: "previous",
            recommendedOptionId: previousFal.id,
            options: [previousFal],
            actionLabel: "Generate image",
            selectionScope: .image
        )
        SpendSelectionPreferences.record(previousFal, for: previous, defaults: defaults)
        let runway = option(modelID: "new-model", provider: .runway)
        let fal = option(modelID: "fal-fallback", provider: .fal)

        let next = SpendSelectionPreferences.applyingStoredSelection(
            to: SpendApproval(
                id: "next",
                recommendedOptionId: runway.id,
                options: [runway, fal],
                actionLabel: "Generate image",
                selectionScope: .image
            ),
            defaults: defaults
        )

        #expect(next.recommendedOptionId == fal.id)
    }

    @Test func imagePreferenceDoesNotChangeVideoApproval() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let falImage = option(modelID: "image-model", provider: .fal)
        SpendSelectionPreferences.record(
            falImage,
            for: SpendApproval(
                id: "image",
                recommendedOptionId: falImage.id,
                options: [falImage],
                actionLabel: "Generate image",
                selectionScope: .image
            ),
            defaults: defaults
        )
        let runwayVideo = option(modelID: "video-model", provider: .runway)
        let falVideo = option(modelID: "video-model", provider: .fal)

        let video = SpendSelectionPreferences.applyingStoredSelection(
            to: SpendApproval(
                id: "video",
                recommendedOptionId: runwayVideo.id,
                options: [runwayVideo, falVideo],
                actionLabel: "Generate video",
                selectionScope: .video
            ),
            defaults: defaults
        )

        #expect(video.recommendedOptionId == runwayVideo.id)
        #expect(video.options.first == runwayVideo)
    }

    @Test func unavailablePreferredProviderFallsBackToTheCurrentRecommendation() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let fal = option(modelID: "old-model", provider: .fal)
        SpendSelectionPreferences.record(
            fal,
            for: SpendApproval(
                id: "previous",
                recommendedOptionId: fal.id,
                options: [fal],
                actionLabel: "Generate image",
                selectionScope: .image
            ),
            defaults: defaults
        )
        let runway = option(modelID: "current-model", provider: .runway)
        let current = SpendApproval(
            id: "current",
            recommendedOptionId: runway.id,
            options: [runway],
            actionLabel: "Generate image",
            selectionScope: .image
        )

        let restored = SpendSelectionPreferences.applyingStoredSelection(
            to: current,
            defaults: defaults
        )

        #expect(restored == current)
    }

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suite = "SpendSelectionPreferencesTests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    private func option(
        modelID: String,
        provider: GenerationProvider
    ) -> SpendOption {
        let binding = ProviderBinding(
            provider: provider,
            transport: .api,
            kind: .generation,
            providerRef: modelID,
            billing: .perCall
        )
        return SpendOption(
            modelId: modelID,
            modelName: modelID,
            target: ResolvedGenerationTarget(
                modelId: modelID,
                provider: provider,
                endpoint: modelID,
                binding: binding
            ),
            credits: 1,
            requiresCatalogAvailability: false
        )
    }
}
