import BpyRuntimeProtocol
import Foundation
import Testing
@testable import NexGenVideo

struct BpyHostConfigurationTests {
    private let owner = UUID(), generation = UUID(), transport = UUID(), job = UUID()

    @Test func frozenConfigurationBindsHostSourceAndIgnoresLaterServiceMutation() throws {
        let context = context()
        var service = configuration(context)
        let original = try JSONSerialization.data(withJSONObject: service)
        let frozen = try BpyHostConfiguration.freeze(original, context: context)
        service["sourcePath"] = "/foreign/source.py"
        let value = try #require(JSONSerialization.jsonObject(with: frozen) as? [String: Any])
        #expect(value["hostSourceSHA256"] as? String == context.sourceSHA256)
        #expect(value["sourcePath"] as? String != service["sourcePath"] as? String)
        #expect(throws: (any Error).self) {
            _ = try BpyHostConfiguration.freeze(JSONSerialization.data(withJSONObject: service), context: context)
        }
    }

    @Test func rejectsCrossRolePathsRaisedLimitsAndServiceSuppliedSourceAuthority() throws {
        let context = context()
        let changes: [[String: Any]] = [
            ["sitePackages": "/foreign/site-packages"], ["inputDirectory": "/foreign/inputs"],
            ["outputDirectory": context.dataMount + "/outputs"], ["workerRoot": context.dataMount],
            ["jobID": UUID().uuidString], ["cpuSeconds": 121], ["outputBytes": context.limits.outputBytes + 1],
            ["memoryPolicy": "uncontrolled"], ["hostSourceSHA256": context.sourceSHA256!],
            ["confirmedScene": context.dataMount + "/another-job/confirmed.blend"],
        ]
        for change in changes {
            let service = configuration(context).merging(change) { _, new in new }
            #expect(throws: (any Error).self) {
                _ = try BpyHostConfiguration.freeze(JSONSerialization.data(withJSONObject: service), context: context)
            }
        }
    }

    @Test func verifierRequiresTheHostFingerprintReadGrantAndGeometryContract() throws {
        let context = context(mode: .verify)
        let scene = context.workerMount + "/" + transport.uuidString + "/jobs/" + job.uuidString + "/worker/outputs/scene.blend"
        var service: [String: Any] = [
            "sitePackages": context.sitePackages, "memoryPolicy": "system-pressure-v1",
            "outputBytes": context.limits.outputBytes, "cpuSeconds": 31,
            "jobID": job.uuidString, "fingerprint": context.fingerprint!,
            "sessionRoot": context.dataMount + "/" + transport.uuidString,
            "scenePath": scene, "manifest": context.root + "/manifest.json", "diagnosticDeniedPaths": [],
            "limits": geometry(context.limits),
        ]
        _ = try BpyHostConfiguration.freeze(JSONSerialization.data(withJSONObject: service), context: context)
        service["fingerprint"] = String(repeating: "b", count: 64)
        #expect(throws: (any Error).self) {
            _ = try BpyHostConfiguration.freeze(JSONSerialization.data(withJSONObject: service), context: context)
        }
        service["fingerprint"] = context.fingerprint
        service["scenePath"] = context.dataMount + "/retained/scene.blend"
        #expect(throws: (any Error).self) {
            _ = try BpyHostConfiguration.freeze(JSONSerialization.data(withJSONObject: service), context: context)
        }
    }

    private func context(mode: BpyLaunchMode = .job) -> BpyHostConfiguration.Context {
        let root = "/worker/" + transport.uuidString + "/jobs/" + job.uuidString
        let scene = root + "/worker/outputs/scene.blend"
        return .init(mode: mode, identity: .init(id: UUID(), owner: owner, generation: generation,
            transport: transport, job: job, kind: .job, insertedAt: 1, admissionDeadline: 31, timeout: 30, diagnosticAutoexec: false),
            limits: .init(), workerMount: "/worker", dataMount: "/data",
            root: root + (mode == .job ? "/worker" : "/verification"), sitePackages: "/runtime/site-packages",
            readPaths: [scene, "/data/" + transport.uuidString + "/jobs/" + job.uuidString + "/inputs"], sourceSHA256: String(repeating: "a", count: 64),
            fingerprint: String(repeating: "c", count: 64), diagnosticDeniedPaths: [])
    }

    private func configuration(_ context: BpyHostConfiguration.Context) -> [String: Any] {
        let session = context.dataMount + "/" + transport.uuidString
        return ["sitePackages": context.sitePackages, "memoryPolicy": "system-pressure-v1",
            "outputBytes": context.limits.outputBytes, "cpuSeconds": 31, "jobID": job.uuidString,
            "sessionRoot": session, "workerRoot": context.workerMount + "/" + transport.uuidString,
            "sourcePath": session + "/jobs/" + job.uuidString + "/source.py",
            "inputDirectory": session + "/jobs/" + job.uuidString + "/inputs", "outputDirectory": context.root + "/outputs",
            "limits": geometry(context.limits)]
    }

    private func geometry(_ limits: BpyRuntimeLimits) -> [String: Int] {
        ["objects": limits.objects, "vertices": limits.vertices, "polygons": limits.polygons,
            "renderWidth": limits.renderWidth, "renderHeight": limits.renderHeight, "renderPixels": limits.renderPixels]
    }

    @Test func nativeLibraryIdentityIsFixedAndPreservesTheEnvironmentAllowlist() {
        for root in ["/worker/job-one", "/worker/job-two"] {
            let environment = BpyHostLauncher.workerEnvironment(rootPath: root)
            #expect(Set(environment.keys) == Set(["USER", "HOME", "TMPDIR", "LANG", "BLENDER_USER_CONFIG",
                "BLENDER_USER_SCRIPTS", "BLENDER_USER_DATAFILES", "PYTHONDONTWRITEBYTECODE", "CYCLES_METAL_ASYNC_PSO_CREATION"]))
            #expect(environment["USER"] == "nexgenvideo")
            #expect(environment["CYCLES_METAL_ASYNC_PSO_CREATION"] == "0")
            #expect(environment["LANG"] == "en_US.UTF-8")
            #expect(environment["PYTHONDONTWRITEBYTECODE"] == "1")
            for key in ["HOME", "TMPDIR", "BLENDER_USER_CONFIG", "BLENDER_USER_SCRIPTS", "BLENDER_USER_DATAFILES"] {
                #expect(environment[key]?.hasPrefix(root + "/") == true)
            }
        }
    }

    @Test func jobRequiresItsExactHostValidatedInputDirectoryReadGrant() throws {
        let context = context()
        let service = configuration(context)
        let bytes = try JSONSerialization.data(withJSONObject: service)
        _ = try BpyHostConfiguration.freeze(bytes, context: context)
        let directory = try #require(service["inputDirectory"] as? String)
        for substitute in [directory + "/fixture.json", directory + "/..", "/foreign/inputs"] {
            let missingDirectory = BpyHostConfiguration.Context(mode: context.mode, identity: context.identity,
                limits: context.limits, workerMount: context.workerMount, dataMount: context.dataMount,
                root: context.root, sitePackages: context.sitePackages,
                readPaths: context.readPaths.subtracting([directory]).union([substitute]),
                sourceSHA256: context.sourceSHA256, fingerprint: context.fingerprint,
                diagnosticDeniedPaths: context.diagnosticDeniedPaths)
            #expect(throws: (any Error).self) {
                _ = try BpyHostConfiguration.freeze(bytes, context: missingDirectory)
            }
        }
    }
}
