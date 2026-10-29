import Foundation
import Testing
@testable import NexGenVideo

@Suite("LUTLoader")
struct LUTLoaderTests {

    private func cubeText(size n: Int, entries: Int? = nil) -> String {
        var lines = ["LUT_3D_SIZE \(n)"]
        let count = entries ?? n * n * n
        for index in 0..<count {
            let r = index % n
            let g = (index / n) % n
            let b = index / (n * n)
            lines.append("\(Double(r) / Double(n - 1)) \(Double(g) / Double(n - 1)) \(Double(b) / Double(n - 1))")
        }
        return lines.joined(separator: "\n")
    }

    @Test("accepts complete 64-point LUTs")
    func parses64PointCube() {
        let lut = LUTLoader.parse(cubeText(size: 64))
        #expect(lut?.dimension == 64)
        #expect(lut?.data.count == 64 * 64 * 64 * 4 * MemoryLayout<Float>.size)
    }

    @Test("accepts complete 65-point LUTs")
    func parses65PointCube() {
        let lut = LUTLoader.parse(cubeText(size: 65))
        #expect(lut?.dimension == 65)
        #expect(lut?.data.count == 65 * 65 * 65 * 4 * MemoryLayout<Float>.size)
    }

    @Test("rejects incomplete LUT data")
    func rejectsIncompleteCube() {
        #expect(LUTLoader.parse(cubeText(size: 65, entries: 65 * 65 * 65 - 1)) == nil)
    }

    @Test("rejects LUT data beyond the declared cube size")
    func rejectsExtraCubeData() {
        #expect(LUTLoader.parse(cubeText(size: 2) + "\n0 0 0") == nil)
    }

    @Test("rejects dimensions beyond the bounded LUT allocation")
    func rejectsOversizedCube() {
        #expect(LUTLoader.parse("LUT_3D_SIZE 66\n") == nil)
    }

    @Test("rejects non-finite component and invalid domain values")
    func rejectsInvalidNumericValues() {
        #expect(LUTLoader.parse("LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 nan 0\n1 1 1\n0 0 1\n1 0 1\n0 1 1\n1 1 1") == nil)
        #expect(LUTLoader.parse("LUT_3D_SIZE 2\nDOMAIN_MIN 1 0 0\nDOMAIN_MAX 0 1 1\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1") == nil)
    }
    @Test("Cube domains locate inputs without rescaling or clipping output samples")
    func preservesDomainAndExtendedOutputSamples() throws {
        let text = "DOMAIN_MIN -1 0.2 0.3\nDOMAIN_MAX 2 0.8 0.7\nLUT_3D_SIZE 2\n"
            + Array(repeating: "-0.25 1.5 2", count: 8).joined(separator: "\n")
        let lut = try #require(LUTLoader.parse(text))
        #expect(lut.domainMin == SIMD3<Float>(-1, 0.2, 0.3))
        #expect(lut.domainMax == SIMD3<Float>(2, 0.8, 0.7))
        let samples = lut.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        #expect(samples == Array(repeating: [Float(-0.25), 1.5, 2, 1], count: 8).flatMap { $0 })
    }

}
