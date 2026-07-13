import Foundation
import NexGenEngine

/// Frame-audit bridge — surfaces what the per-frame vision audit found so nothing gets silently
/// approved past a blocking finding. Port of `sanity/checks/frame_audit_bridge.py`. Reads each
/// shot×role audit YAML via `ctx.extra["data_root"]` and degrades to no findings when the data root
/// is absent (exactly like the other manifest-gated frame checks).
///
/// Severities are deliberate: the bridge only INFORMS (`info`) or flags a corrupt file (`warn`) —
/// it never hard-blocks the sanity report. Blocking-ness is handled by the audit's own routing
/// (`save_frame_audit` returns RERENDER / USER_DECIDES); `SanityReport.is_clean` stays untouched.
extension MusicvideoChecks {
    public static let frameAuditBridgeCheck: SanityCheck = { ctx in
        guard let root = ctx.extra?["data_root"] else { return [] }
        let dataRoot = URL(fileURLWithPath: root)
        var out: [Finding] = []
        for shot in ctx.shotlist.shots {
            for role in ["start", "end"] {
                let audit: FrameAudit?
                do {
                    audit = try loadFrameAudit(dataRoot: dataRoot, shotId: shot.id, role: role)
                } catch {
                    out.append(Finding(level: .warn, code: "FRAME_AUDIT_LOAD_FAILED", shotId: shot.id,
                        message: "audit file for \(shot.id)-\(role) is corrupt or schema-invalid: "
                            + "\(type(of: error)). Re-create it via save_frame_audit."))
                    continue
                }
                guard let a = audit else { continue }
                if a.hasBlocking {
                    out.append(Finding(level: .info, code: "FRAME_AUDIT_ISSUES", shotId: shot.id,
                        message: "Frame audit (\(role)) has BLOCKING findings. Auditor=\(a.auditor), "
                            + "Attempts=\(a.autoRerenderAttempt). User-approve only if deliberate despite findings."))
                } else if a.hasMinor {
                    out.append(Finding(level: .info, code: "FRAME_AUDIT_ISSUES", shotId: shot.id,
                        message: "Frame audit (\(role)) has MINOR findings. Auditor=\(a.auditor)."))
                }
            }
        }
        return out
    }
}
