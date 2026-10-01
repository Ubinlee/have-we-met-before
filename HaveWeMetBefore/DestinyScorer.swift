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
        // 가장 가까운 순간은 거리 40점 + 시간(3시간 구간 차이) 40점으로 계산합니다.
        // 반복 교차는 추가로 겹친 날짜마다 4점, 최대 20점을 더합니다.
        let repeatedIntersectionScore = min(5, additionalDayCount) * 4
        let score = min(
            100,
            distanceScore(for: closestIntersection.distanceMeters)
                + timeScore(for: closestIntersection.timeDifference)
                + repeatedIntersectionScore
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

    private static func distanceScore(for meters: Double) -> Int {
        switch meters {
        case ...100: 40
        case ...300: interpolatedScore(meters, from: 100, score: 40, to: 300, score: 36)
        case ...500: interpolatedScore(meters, from: 300, score: 36, to: 500, score: 32)
        case ...1_000: interpolatedScore(meters, from: 500, score: 32, to: 1_000, score: 25)
        case ...3_000: interpolatedScore(meters, from: 1_000, score: 25, to: 3_000, score: 15)
        case ...5_000: interpolatedScore(meters, from: 3_000, score: 15, to: 5_000, score: 8)
        default: 0
        }
    }

    private static func interpolatedScore(
        _ value: Double,
        from lowerValue: Double,
        score lowerScore: Double,
        to upperValue: Double,
        score upperScore: Double
    ) -> Int {
        let progress = (value - lowerValue) / (upperValue - lowerValue)
        return Int((lowerScore + (upperScore - lowerScore) * progress).rounded())
    }

    /// 서버에 공유되는 시간은 3시간 구간이라 시간 차이도 구간 차이로만 계산합니다.
    /// 0구간(같은 3시간 구간) 40점, 1구간 24점, 2구간 14점, 그 이상 7점입니다.
    private static func timeScore(for interval: TimeInterval) -> Int {
        let bucketDuration = SharedVisitPrivacySettings.mvp.timeBucketDuration
        let bucketDifference = Int((max(0, interval) / bucketDuration).rounded())
        switch bucketDifference {
        case 0: return 40
        case 1: return 24
        case 2: return 14
        default: return 7
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
