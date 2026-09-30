import CryptoKit
import Foundation

struct SharedVisitRecord: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let timeBucketIndex: Int
    let latitudeCell: Int
    let longitudeCell: Int
    let schemaVersion: Int
}

struct SharedVisitPrivacySettings: Sendable {
    let coordinateStep: Double
    let timeBucketDuration: TimeInterval

    static let mvp = SharedVisitPrivacySettings(
        // 정확한 좌표 대신 약 200m 단위의 격자 번호만 공유합니다.
        // 기존 약 1.1km 격자는 서로 다른 동네를 같은 지점으로 오판할 수 있었습니다.
        coordinateStep: 0.002,
        timeBucketDuration: 3 * 60 * 60
    )
}

enum SharedVisitRecordBuilder {
    static func build(
        from events: [VisitEvent],
        settings: SharedVisitPrivacySettings = .mvp
    ) -> [SharedVisitRecord] {
        let records = events.map { event in
            makeRecord(from: event, settings: settings)
        }

        return Array(Set(records)).sorted {
            if $0.timeBucketIndex != $1.timeBucketIndex {
                return $0.timeBucketIndex < $1.timeBucketIndex
            }
            if $0.latitudeCell != $1.latitudeCell {
                return $0.latitudeCell < $1.latitudeCell
            }
            return $0.longitudeCell < $1.longitudeCell
        }
    }

    private static func makeRecord(
        from event: VisitEvent,
        settings: SharedVisitPrivacySettings
    ) -> SharedVisitRecord {
        let timeBucketIndex = Int(
            floor(event.capturedAt.timeIntervalSince1970 / settings.timeBucketDuration)
        )
        let latitudeCell = Int(floor(event.latitude / settings.coordinateStep))
        let longitudeCell = Int(floor(event.longitude / settings.coordinateStep))
        let source = "v3:\(timeBucketIndex):\(latitudeCell):\(longitudeCell)"
        let digest = SHA256.hash(data: Data(source.utf8))
        let id = digest.map { String(format: "%02x", $0) }.joined()

        return SharedVisitRecord(
            id: id,
            timeBucketIndex: timeBucketIndex,
            latitudeCell: latitudeCell,
            longitudeCell: longitudeCell,
            schemaVersion: 3
        )
    }
}
