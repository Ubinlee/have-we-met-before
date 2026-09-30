import Foundation

struct DestinyScoreResult: Sendable {
    let score: Int
    let closestIntersection: TrajectoryIntersection?
    let totalIntersectionDayCount: Int
    let additionalIntersectionDayCount: Int
    let rankedIntersections: [TrajectoryIntersection]
}

enum DestinyScorer {
    static func calculate(
        intersections: [TrajectoryIntersection],
        calendar: Calendar = .autoupdatingCurrent
    ) -> DestinyScoreResult {
        guard let closestIntersection = intersections.sorted(by: isBetterIntersection).first else {
            return DestinyScoreResult(
                score: 0,
                closestIntersection: nil,
                totalIntersectionDayCount: 0,
                additionalIntersectionDayCount: 0,
                rankedIntersections: []
            )
        }

        let intersectionDays = Set(
            intersections.map { calendar.startOfDay(for: $0.occurredAt) }
        )
        let additionalDayCount = max(0, intersectionDays.count - 1)
        // 반복 교차는 하루당 4점, 최대 20점만 더합니다.
        // 강한 교차 하나와 반복 기록만으로 점수가 쉽게 100점이 되지 않게 합니다.
        let repeatedIntersectionScore = min(5, additionalDayCount) * 4
        let score = min(
            100,
            baseScore(for: closestIntersection.strength) + repeatedIntersectionScore
        )
        let rankedIntersections = bestIntersectionPerDay(
            intersections,
            calendar: calendar
        )

        return DestinyScoreResult(
            score: score,
            closestIntersection: closestIntersection,
            totalIntersectionDayCount: intersectionDays.count,
            additionalIntersectionDayCount: additionalDayCount,
            rankedIntersections: Array(rankedIntersections.prefix(3))
        )
    }

    private static func bestIntersectionPerDay(
        _ intersections: [TrajectoryIntersection],
        calendar: Calendar
    ) -> [TrajectoryIntersection] {
        Dictionary(grouping: intersections) {
            calendar.startOfDay(for: $0.occurredAt)
        }
        .values
        .compactMap { $0.sorted(by: isBetterIntersection).first }
        .sorted(by: isBetterIntersection)
    }

    private static func baseScore(for strength: IntersectionStrength) -> Int {
        switch strength {
        case .strong:
            70
        case .close:
            50
        case .loose:
            30
        }
    }

    private static func isBetterIntersection(
        _ lhs: TrajectoryIntersection,
        _ rhs: TrajectoryIntersection
    ) -> Bool {
        if lhs.strength != rhs.strength {
            return lhs.strength > rhs.strength
        }
        if lhs.distanceMeters != rhs.distanceMeters {
            return lhs.distanceMeters < rhs.distanceMeters
        }
        return lhs.timeDifference < rhs.timeDifference
    }
}
