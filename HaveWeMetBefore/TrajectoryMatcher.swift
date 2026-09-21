import Foundation

enum IntersectionStrength: Int, Comparable, Sendable {
    case loose = 1
    case close = 2
    case strong = 3

    static func < (lhs: IntersectionStrength, rhs: IntersectionStrength) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct TrajectoryIntersection: Identifiable, Sendable {
    let id: String
    let firstRecordID: String
    let secondRecordID: String
    let firstCapturedAt: Date
    let secondCapturedAt: Date
    let strength: IntersectionStrength
    let distanceMeters: Double
    let timeDifference: TimeInterval

    var occurredAt: Date {
        min(firstCapturedAt, secondCapturedAt)
    }
}

struct IntersectionThresholds: Sendable {
    let strongDistanceMeters: Double
    let strongTimeInterval: TimeInterval
    let closeDistanceMeters: Double
    let closeTimeInterval: TimeInterval
    let looseDistanceMeters: Double

    static let mvp = IntersectionThresholds(
        strongDistanceMeters: 300,
        strongTimeInterval: 60 * 60,
        closeDistanceMeters: 1_000,
        closeTimeInterval: 3 * 60 * 60,
        looseDistanceMeters: 5_000
    )
}

enum TrajectoryMatcher {
    static func compare(
        first: [PhotoVisitRecord],
        second: [PhotoVisitRecord],
        before firstMetDate: Date,
        thresholds: IntersectionThresholds = .mvp,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [TrajectoryIntersection] {
        let firstRecords = first.filter { $0.capturedAt < firstMetDate }
        let secondRecords = second.filter { $0.capturedAt < firstMetDate }
        let secondRecordsByDay = Dictionary(grouping: secondRecords) {
            calendar.startOfDay(for: $0.capturedAt)
        }

        var intersections: [TrajectoryIntersection] = []

        for firstRecord in firstRecords {
            let firstDay = calendar.startOfDay(for: firstRecord.capturedAt)
            let candidateDays = [-1, 0, 1].compactMap {
                calendar.date(byAdding: .day, value: $0, to: firstDay)
            }

            for candidateDay in candidateDays {
                for secondRecord in secondRecordsByDay[candidateDay, default: []] {
                    let timeDifference = abs(
                        firstRecord.capturedAt.timeIntervalSince(secondRecord.capturedAt)
                    )
                    let distance = distanceMeters(from: firstRecord, to: secondRecord)

                    guard let strength = strength(
                        distanceMeters: distance,
                        timeDifference: timeDifference,
                        firstDate: firstRecord.capturedAt,
                        secondDate: secondRecord.capturedAt,
                        thresholds: thresholds,
                        calendar: calendar
                    ) else {
                        continue
                    }

                    intersections.append(
                        TrajectoryIntersection(
                            id: "\(firstRecord.id):\(secondRecord.id)",
                            firstRecordID: firstRecord.id,
                            secondRecordID: secondRecord.id,
                            firstCapturedAt: firstRecord.capturedAt,
                            secondCapturedAt: secondRecord.capturedAt,
                            strength: strength,
                            distanceMeters: distance,
                            timeDifference: timeDifference
                        )
                    )
                }
            }
        }

        return intersections.sorted(by: isBetterIntersection)
    }

    private static func strength(
        distanceMeters: Double,
        timeDifference: TimeInterval,
        firstDate: Date,
        secondDate: Date,
        thresholds: IntersectionThresholds,
        calendar: Calendar
    ) -> IntersectionStrength? {
        if distanceMeters <= thresholds.strongDistanceMeters,
           timeDifference <= thresholds.strongTimeInterval {
            return .strong
        }

        if distanceMeters <= thresholds.closeDistanceMeters,
           timeDifference <= thresholds.closeTimeInterval {
            return .close
        }

        if distanceMeters <= thresholds.looseDistanceMeters,
           calendar.isDate(firstDate, inSameDayAs: secondDate) {
            return .loose
        }

        return nil
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

    private static func distanceMeters(
        from first: PhotoVisitRecord,
        to second: PhotoVisitRecord
    ) -> Double {
        let earthRadius = 6_371_000.0
        let latitude1 = first.latitude * .pi / 180
        let latitude2 = second.latitude * .pi / 180
        let latitudeDelta = (second.latitude - first.latitude) * .pi / 180
        let longitudeDelta = (second.longitude - first.longitude) * .pi / 180

        let a = sin(latitudeDelta / 2) * sin(latitudeDelta / 2)
            + cos(latitude1) * cos(latitude2)
            * sin(longitudeDelta / 2) * sin(longitudeDelta / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return earthRadius * c
    }
}
