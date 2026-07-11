import Foundation
import NexGenEngine

/// Deterministic hard-gate preconditions for the musicvideo pack. These run (non-LLM) before a gate
/// can be approved, so the agent can never advance a phase whose real artifact is missing — the port
/// of the predecessor's analysis→render `require()` chain.
enum MusicvideoGateChecks {
    /// The `analysis` gate is approvable only when a real analysis artifact exists with genuine
    /// rhythm data — a non-empty `beats` AND `downbeats` list and a positive duration. This is what
    /// stops the agent from "hearing" a structure it never measured: no artifact, or an empty/degenerate
    /// one, blocks approval with an actionable message pointing at `run_phase("analysis")`.
    static func requireRealAnalysis(dataRoot: URL) throws {
        guard let url = AudioProjectLayout.expectedAnalysisArtifactURL(dataRoot: dataRoot) else {
            throw GateBlocked(
                "Can't approve \"analysis\": there isn't exactly one song in audio/ to analyse. "
                    + "Attach the track first, then run run_phase(\"analysis\").")
        }
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw GateBlocked(
                "Can't approve \"analysis\": no analysis artifact yet. Run run_phase(\"analysis\") — it "
                    + "decodes the song and writes real beats/downbeats. Never describe the song's "
                    + "structure from listening; it must be measured.")
        }
        let beats = (obj["beats"] as? [Any])?.count ?? 0
        let downbeats = (obj["downbeats"] as? [Any])?.count ?? 0
        let duration = (obj["duration_s"] as? Double) ?? 0
        guard beats > 0, downbeats > 0, duration > 0 else {
            throw GateBlocked(
                "Can't approve \"analysis\": the analysis artifact has no real rhythm data "
                    + "(beats=\(beats), downbeats=\(downbeats), duration=\(duration)s). Re-run "
                    + "run_phase(\"analysis\") on a decodable song.")
        }
    }
}
