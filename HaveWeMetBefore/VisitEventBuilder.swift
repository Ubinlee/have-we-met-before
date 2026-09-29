import Foundation

struct VisitEvent: Identifiable, Sendable, TrajectoryRecord {
    let id: String
    let startedAt: Date
    let endedAt: Date
    let latitude: Double
    let longitude: Double
    let photoCount: Int

    var capturedAt: Date {
        startedAt.addingTimeInterval(endedAt.timeIntervalSince(startedAt) / 2)
    }
}

struct VisitMergeThresholds: Sendable {
    let maximumDistanceMeters: Double
    let maximumTimeGap: TimeInterval

    static let mvp = VisitMergeThresholds(
        maximumDistanceMeters: 300,
        maximumTimeGap: 30 * 60
    )
}

enum VisitEventBuilder {
    static func build(
        from records: [PhotoVisitRecord],
        thresholds: VisitMergeThresholds = .mvp
    ) -> [VisitEvent] {
        let sortedRecords = records.sorted { $0.capturedAt < $1.capturedAt }
        guard let firstRecord = sortedRecords.first else { return [] }

        var events: [VisitEvent] = []
        var current = Accumulator(record: firstRecord)

        for record in sortedRecords.dropFirst() {
            if current.canMerge(record, thresholds: thresholds) {
                current.merge(record)
            } else {
                events.append(current.event)
                current = Accumulator(record: record)
            }
        }

        events.append(current.event)
        return events
    }

    private struct Accumulator {
        let id: String
        let startedAt: Date
        var endedAt: Date
        var latitudeTotal: Double
        var longitudeTotal: Double
        var photoCount: Int

        init(record: PhotoVisitRecord) {
            id = record.id
            startedAt = record.capturedAt
            endedAt = record.capturedAt
            latitudeTotal = record.latitude
            longitudeTotal = record.longitude
            photoCount = 1
        }

        var latitude: Double {
            latitudeTotal / Double(photoCount)
        }

        var longitude: Double {
            longitudeTotal / Double(photoCount)
        }

        var event: VisitEvent {
            VisitEvent(
                id: id,
                startedAt: startedAt,
                endedAt: endedAt,
                latitude: latitude,
                longitude: longitude,
                photoCount: photoCount
            )
        }

        func canMerge(
            _ record: PhotoVisitRecord,
            thresholds: VisitMergeThresholds
        ) -> Bool {
            let timeGap = record.capturedAt.timeIntervalSince(endedAt)
            guard timeGap >= 0, timeGap <= thresholds.maximumTimeGap else {
                return false
            }

            return GeoDistance.meters(
                latitude1: latitude,
                longitude1: longitude,
                latitude2: record.latitude,
                longitude2: record.longitude
            ) <= thresholds.maximumDistanceMeters
        }

        mutating func merge(_ record: PhotoVisitRecord) {
            endedAt = record.capturedAt
            latitudeTotal += record.latitude
            longitudeTotal += record.longitude
            photoCount += 1
        }
    }
}

enum GeoDistance {
    static func meters(
        latitude1: Double,
        longitude1: Double,
        latitude2: Double,
        longitude2: Double
    ) -> Double {
        let earthRadius = 6_371_000.0
        let firstLatitude = latitude1 * .pi / 180
        let secondLatitude = latitude2 * .pi / 180
        let latitudeDelta = (latitude2 - latitude1) * .pi / 180
        let longitudeDelta = (longitude2 - longitude1) * .pi / 180

        let a = sin(latitudeDelta / 2) * sin(latitudeDelta / 2)
            + cos(firstLatitude) * cos(secondLatitude)
            * sin(longitudeDelta / 2) * sin(longitudeDelta / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return earthRadius * c
    }
}
