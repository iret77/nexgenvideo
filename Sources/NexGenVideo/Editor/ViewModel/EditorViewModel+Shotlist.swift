import Foundation
import NexGenEngine

// Direct, structured writes to the shotlist artifact — the direct-manipulation default
// (docs/UI_UX_CONCEPT.md §2). A single-field change (a shot's source mode) is a trivial native
// write: load the engine Shotlist, mutate, save a new version, then re-read the engine snapshot.
// The versioned save preserves history (shotlist never overwrites in place).
extension EditorViewModel {
    /// Set one shot's source mode natively and refresh the engine snapshot. No-op (returns false)
    /// when there's no open project, no shotlist, the shot is missing, or the value is unchanged.
    @discardableResult
    func setShotSourceMode(shotId: String, to mode: SourceMode) async -> Bool {
        guard let dir = workingRoot else { return false }
        let saved: Bool = await Task.detached {
            guard var shotlist = (try? loadShotlist(dataRoot: dir)) ?? nil,
                  let index = shotlist.shots.firstIndex(where: { $0.id == shotId }),
                  shotlist.shots[index].sourceMode != mode
            else { return false }
            shotlist.shots[index].sourceMode = mode
            do {
                try saveShotlist(shotlist, to: dir)
                return true
            } catch {
                return false
            }
        }.value
        guard saved else { return false }
        await refreshEngineState()
        return true
    }
}
