import Foundation

// =============================================================================
// Scoreboard — points, streak, badges, end-of-shift report (PRD §2.6).
// The SAVE table is law; see SimEngine+Tick.swift for when each path fires.
// =============================================================================

struct Scoreboard {
    private(set) var score: Int = 0
    private(set) var streakMultiplier: Int = 1
    private(set) var bestStreak: Int = 1
    private(set) var cleanRun: Int = 0            // consecutive clean movements
    private(set) var badges: [BadgeAward] = []

    // Shift tally
    var landings = 0
    var departures = 0
    var totalMovements = 0
    var cleanMovements = 0
    var savesEarned = 0
    var saveOpportunities = 0
    var pilotForcedGoArounds = 0
    var nags = 0
    var sustainedReds = 0
    var bestMomentPoints = 0
    var bestMomentText = "A quiet, tidy shift"

    /// Positive award, multiplied by the current streak. Returns points banked.
    @discardableResult
    mutating func award(base: Int) -> Int {
        let pts = base * streakMultiplier
        score += pts
        return pts
    }

    /// Raw penalty (never multiplied).
    mutating func penalize(_ points: Int) {
        score -= points
    }

    /// Raw, unmultiplied credit (precautionary go-around, clean-shift bonus).
    mutating func awardRaw(_ points: Int) {
        score += points
    }

    @discardableResult
    mutating func awardBadge(_ badge: Badge, aircraft: AircraftID, basePoints: Int? = nil) -> BadgeAward {
        let pts = (basePoints ?? badge.points) * streakMultiplier
        score += pts
        let a = BadgeAward(badge: badge, aircraft: aircraft, points: pts)
        badges.append(a)
        return a
    }

    /// A movement finished; clean movements build the streak (2 per step).
    /// Returns the new multiplier if it changed.
    mutating func registerMovement(clean: Bool) -> Int? {
        totalMovements += 1
        guard clean else { return nil }
        cleanMovements += 1
        cleanRun += 1
        if cleanRun.isMultiple(of: 2) && streakMultiplier < 8 {
            streakMultiplier += 1
            bestStreak = max(bestStreak, streakMultiplier)
            return streakMultiplier
        }
        return nil
    }

    /// Sustained red: hard reset. Returns new multiplier if changed.
    mutating func resetStreak() -> Int? {
        cleanRun = 0
        guard streakMultiplier != 1 else { return nil }
        streakMultiplier = 1
        return 1
    }

    /// SAVE: streak steps DOWN two, never resets (PRD law).
    mutating func stepDownStreak() -> Int? {
        cleanRun = 0
        let new = max(1, streakMultiplier - 2)
        guard new != streakMultiplier else { return nil }
        streakMultiplier = new
        return new
    }

    /// End-of-shift ×1.1 bonus when no red ever sustained. Returns the award.
    mutating func grantCleanShift() -> BadgeAward? {
        guard sustainedReds == 0, totalMovements > 0, score > 0 else { return nil }
        let bonus = score / 10
        score += bonus
        let a = BadgeAward(badge: .cleanShift, aircraft: AircraftID(0), points: bonus)
        badges.append(a)
        return a
    }

    mutating func noteMoment(points: Int, text: String) {
        if points > bestMomentPoints {
            bestMomentPoints = points
            bestMomentText = text
        }
    }

    // MARK: Report

    func makeReport(script: ShiftScript, averageDelay: Double) -> ShiftReport {
        let par = max(1, script.parScore)
        let flow = min(100, Int((Double(totalMovements) / Double(max(1, script.parMovements))) * 100))
        let precision = totalMovements == 0 ? 100
            : Int((Double(cleanMovements) / Double(totalMovements)) * 100)
        let cool = saveOpportunities == 0 ? 70
            : min(100, Int((Double(savesEarned) / Double(saveOpportunities)) * 100))
        let frequency = max(0, 100 - 12 * pilotForcedGoArounds - 4 * nags)
        let ratio = Double(score) / Double(par)
        let grade: ShiftGrade = ratio >= 1.35 ? .s : ratio >= 1.0 ? .a
            : ratio >= 0.7 ? .b : ratio >= 0.45 ? .c : .d
        return ShiftReport(totalScore: score, grade: grade, flow: flow,
                           precision: precision, cool: cool, frequency: frequency,
                           landings: landings, departures: departures, badges: badges,
                           bestStreak: bestStreak, averageDelaySeconds: averageDelay,
                           bestMoment: bestMomentText)
    }
}
