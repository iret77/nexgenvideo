import Foundation

public func productionRenderabilityCheck(_ ctx: AuditContext) throws -> [Finding] {
    guard ctx.productionProfileIDs.contains(.generativeFilm) else { return [] }
    var findings: [Finding] = []

    for shot in ctx.shotlist.shots {
        guard ProductionDiscipline.requiresProductionPlan(shot) else { continue }
        guard let plan = shot.productionPlan else {
            findings.append(Finding(
                level: .warn,
                code: "PRODUCTION_PLAN_MISSING",
                shotId: shot.id,
                message: "Legacy shot has no structured production plan; add one before revising or rendering it."
            ))
            continue
        }

        if ProductionDiscipline.hasTooManyVisibleCharacters(shot) {
            findings.append(Finding(
                level: .error,
                code: "TOO_MANY_VISIBLE_CHARACTERS",
                shotId: shot.id,
                message: "Generated shots may contain at most two visible characters; split this beat into simpler shots."
            ))
        }

        if ProductionDiscipline.hasUndeclaredLongTake(shot) {
            findings.append(Finding(
                level: .error,
                code: "LONG_TAKE_RISK_UNDECLARED",
                shotId: shot.id,
                message: "Generated shots over 12 seconds must declare long_take and provide a rescue cut."
            ))
        }

        if ProductionDiscipline.hasUnanchoredCharacterBlocking(shot) {
            findings.append(Finding(
                level: .error,
                code: "BLOCKING_ANCHOR_MISSING",
                shotId: shot.id,
                message: "Generated character blocking must name set_anchor separately from relation_to_set."
            ))
        }

        let usesContinuityAssets = !shot.characterRefs.isEmpty
            || shot.locationRef != nil
            || !shot.propRefs.isEmpty
        if usesContinuityAssets && plan.continuityLocks.isEmpty {
            findings.append(Finding(
                level: .warn,
                code: "CONTINUITY_LOCKS_MISSING",
                shotId: shot.id,
                message: "Shot uses named production assets but records no continuity locks."
            ))
        }
    }

    return findings
}

public func narrativeStructureCheck(_ ctx: AuditContext) throws -> [Finding] {
    guard ctx.productionProfileIDs.contains(.narrativeStorytelling) else { return [] }
    var findings: [Finding] = []

    for shot in ctx.shotlist.shots
    where shot.productionPlan != nil && shot.productionPlan?.narrativeBeat == nil {
        findings.append(Finding(
            level: .error,
            code: "NARRATIVE_BEAT_MISSING",
            shotId: shot.id,
            message: "Narrative and hybrid projects require a narrative beat for every shot."
        ))
    }

    let grouped = Dictionary(grouping: ctx.shotlist.shots) { $0.section ?? "__unsectioned__" }
    for section in grouped.keys.sorted() {
        let plannedShots = (grouped[section] ?? []).filter {
            $0.productionPlan != nil
        }
        guard plannedShots.count >= 3 else { continue }
        let beats = plannedShots.sorted {
            $0.timeStart == $1.timeStart
                ? $0.id < $1.id
                : $0.timeStart < $1.timeStart
        }
            .compactMap { $0.productionPlan?.narrativeBeat }
        if !beats.isEmpty,
           beats.allSatisfy({ $0 == .performance || $0 == .atmosphere }) {
            continue
        }
        let actionIndex = beats.firstIndex(of: .action)
        let hasContextBeforeAction = actionIndex.map { index in
            beats[..<index].contains {
                $0 == .establish || $0 == .atmosphere
            }
        } ?? false
        let hasConsequenceAfterAction = actionIndex.map { index in
            beats[beats.index(after: index)...].contains {
                $0 == .reaction || $0 == .detail || $0 == .transition
            }
        } ?? false
        if actionIndex == nil {
            findings.append(Finding(
                level: .warn,
                code: "NARRATIVE_ACTION_MISSING",
                message: "Section \(section) has no observable action beat."
            ))
        }
        if !hasContextBeforeAction {
            findings.append(Finding(
                level: .warn,
                code: "NARRATIVE_CONTEXT_MISSING",
                message: "Section \(section) has no establish or atmosphere beat before its action."
            ))
        }
        if !hasConsequenceAfterAction {
            findings.append(Finding(
                level: .warn,
                code: "NARRATIVE_CONSEQUENCE_MISSING",
                message: "Section \(section) has no reaction, detail, or transition beat after its action."
            ))
        }
    }

    return findings
}
