import Foundation

enum SharedTrajectoryMatcher {
    static func compare(
        first: [SharedVisitRecord],
        second: [SharedVisitRecord]
    ) -> [TrajectoryIntersection] {
        let secondByBucket = Dictionary(grouping: second, by: \.timeBucketIndex)
        var intersections: [TrajectoryIntersection] = []

        for firstRecord in first {
            let candidateBuckets = (firstRecord.timeBucketIndex - 8)...(firstRecord.timeBucketIndex + 8)
            for bucket in candidateBuckets {
                for secondRecord in secondByBucket[bucket, default: []] {
                let bucketDifference = abs(
                    firstRecord.timeBucketIndex - secondRecord.timeBucketIndex
                )

                let distance = GeoDistance.meters(
                    latitude1: firstRecord.approximateLatitude,
                    longitude1: firstRecord.approximateLongitude,
                    latitude2: secondRecord.approximateLatitude,
                    longitude2: secondRecord.approximateLongitude
                )

                guard let strength = strength(
                    first: firstRecord,
                    second: secondRecord,
                    bucketDifference: bucketDifference,
                    distanceMeters: distance
                ) else {
                    continue
                }

                intersections.append(
                    TrajectoryIntersection(
                        id: "\(firstRecord.id):\(secondRecord.id)",
                        firstRecordID: firstRecord.id,
                        secondRecordID: secondRecord.id,
                        firstCapturedAt: firstRecord.approximateDate,
                        secondCapturedAt: secondRecord.approximateDate,
                        strength: strength,
                        distanceMeters: distance,
                        timeDifference: Double(bucketDifference)
                            * SharedVisitPrivacySettings.mvp.timeBucketDuration
                    )
                )
                }
            }
        }

        return intersections.sorted(by: isBetterIntersection)
    }

    private static func strength(
        first: SharedVisitRecord,
        second: SharedVisitRecord,
        bucketDifference: Int,
        distanceMeters: Double
    ) -> IntersectionStrength? {
        if bucketDifference == 0,
           first.latitudeCell == second.latitudeCell,
           first.longitudeCell == second.longitudeCell {
            return .strong
        }

        if bucketDifference <= 1, distanceMeters <= 2_000 {
            return .close
        }

        if utcDayIndex(first.timeBucketIndex) == utcDayIndex(second.timeBucketIndex),
           distanceMeters <= 5_000 {
            return .loose
        }

        return nil
    }

    private static func utcDayIndex(_ timeBucketIndex: Int) -> Int {
        timeBucketIndex / 8
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

extension SharedVisitRecord {
    var approximateDate: Date {
        let duration = SharedVisitPrivacySettings.mvp.timeBucketDuration
        return Date(
            timeIntervalSince1970: Double(timeBucketIndex) * duration + duration / 2
        )
    }

    var approximateLatitude: Double {
        (Double(latitudeCell) + 0.5) * SharedVisitPrivacySettings.mvp.coordinateStep
    }

    var approximateLongitude: Double {
        (Double(longitudeCell) + 0.5) * SharedVisitPrivacySettings.mvp.coordinateStep
    }
}
