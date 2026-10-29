import Foundation
import ImageIO

enum AgentReviewChildContextBudget {
    static func estimateRequest(_ bytes: Data) throws -> Int {
        var imageTokens = 0
        var images = 0
        func sanitized(_ value: Any) throws -> Any {
            if var object = value as? [String: Any] {
                if object["type"] as? String == "image" {
                    if var source = object["source"] as? [String: Any], source["type"] as? String == "base64",
                       let base64 = source["data"] as? String {
                        imageTokens = try adding(imageTokens, imageEstimate(base64))
                        images += 1; source["data"] = ""; object["source"] = source
                    } else if let base64 = object["data"] as? String {
                        imageTokens = try adding(imageTokens, imageEstimate(base64))
                        images += 1; object["data"] = ""
                    } else { throw ToolError("The review image has no verifiable encoded source.") }
                }
                return try object.mapValues { try sanitized($0) }
            }
            if let array = value as? [Any] { return try array.map { try sanitized($0) } }
            return value
        }
        let object = try sanitized(JSONSerialization.jsonObject(with: bytes))
        guard images <= 100 else { throw ToolError("The review request exceeds the provider image count.") }
        let textBytes = try JSONSerialization.data(withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]).count
        return try adding(textBytes, imageTokens)
    }

    static func initialCLI(_ request: AgentReviewChildRequest) throws -> Int {
        let object: [String: Any] = ["system": request.hostContext.systemInstructions,
            "tools": request.hostContext.toolSchemas.map { ["name": $0.name, "description": $0.description,
                "input_schema": $0.inputSchema] as [String: Any] }, "bootstrap": request.bootstrap]
        let text = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]).count
        return try adding(text, 4096)
    }

    static func adding(_ a: Int, _ b: Int) throws -> Int {
        let (sum, overflow) = a.addingReportingOverflow(b)
        guard !overflow else { throw ToolError("The review context bound overflowed.") }
        return sum
    }

    private static func imageEstimate(_ base64: String) throws -> Int {
        guard let bytes = Data(base64Encoded: base64),
              let source = CGImageSourceCreateWithData(bytes as CFData, nil), CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { throw ToolError("The review image dimensions could not be verified.") }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= Int.max - 749 else { throw ToolError("The review image dimensions overflowed.") }
        return try adding((pixels + 749) / 750, 256)
    }
}
