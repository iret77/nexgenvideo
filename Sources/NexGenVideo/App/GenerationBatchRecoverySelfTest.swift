import Foundation

@MainActor
enum GenerationBatchRecoverySelfTest {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["NGV_SELFTEST_GENERATION_BATCH_RECOVERY"] == "1" else {
            return
        }
        do {
            let input = GenerationPricingInput(
                modelId: "runway/gemini_image3_pro",
                modality: .image,
                durationSeconds: nil,
                outputCount: 1,
                resolution: nil,
                quality: nil,
                promptCharacterCount: 1,
                generateAudio: nil,
                referenceCount: 0
            )
            let credits = try require(
                LiveGenerationPricing.runwayCredits(
                    endpoint: "runway/gemini_image3_pro",
                    input: input
                ),
                "Runway Gemini pricing is unavailable"
            )
            try check(credits == 20, "Runway Gemini must cost 20 credits per supported image")

            let recoverable = GenerationBatchReviewControls(
                hasVerifiedTotal: false,
                hasRetryablePricingFailure: true,
                isBusy: false
            )
            try check(recoverable.canEdit && recoverable.canRetryPricing && !recoverable.canApprove,
                      "An unpriced batch must remain editable and retryable but not approvable")
            let verified = GenerationBatchReviewControls(
                hasVerifiedTotal: true,
                hasRetryablePricingFailure: false,
                isBusy: false
            )
            try check(verified.canEdit && !verified.canRetryPricing && verified.canApprove,
                      "A fully priced batch must expose one approval")
            let unsupported = GenerationPricingFailure(
                reason: .unsupportedCombination,
                provider: .runway,
                endpoint: "runway/gemini_image3.1_flash",
                detail: "fixture unsupported options"
            )
            let providerOutage = GenerationPricingFailure(
                reason: .priceQueryUnavailable,
                provider: .runway,
                endpoint: "runway/gemini_image3_pro",
                detail: "fixture pricing outage"
            )
            let exchangeOutage = GenerationPricingFailure(
                reason: .exchangeRateUnavailable,
                provider: nil,
                endpoint: "fixture://ecb",
                detail: "fixture exchange outage"
            )
            try check(!unsupported.isRetryable && providerOutage.isRetryable && exchangeOutage.isRetryable,
                      "Pricing causes do not expose the required recovery actions")
            FileHandle.standardOutput.write(Data("SELFTEST_GENERATION_BATCH_RECOVERY_OK\n".utf8))
            exit(0)
        } catch {
            FileHandle.standardError.write(
                Data("SELFTEST_GENERATION_BATCH_RECOVERY_FAIL \(error.localizedDescription)\n".utf8)
            )
            exit(1)
        }
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw Failure(message: message) }
        return value
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
    }

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
