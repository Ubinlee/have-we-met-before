import Foundation

enum ApproximatePlaceResolver {
    private struct Place {
        let name: String
        let latitude: Double
        let longitude: Double
    }

    // 외부 역지오코딩 없이 앱 안에서만 비교하는 MVP용 주요 지점 목록입니다.
    private static let places = [
        Place(name: "이화여대", latitude: 37.5618, longitude: 126.9469),
        Place(name: "홍대입구역", latitude: 37.5572, longitude: 126.9254),
        Place(name: "신촌역", latitude: 37.5551, longitude: 126.9369),
        Place(name: "광화문", latitude: 37.5759, longitude: 126.9768),
        Place(name: "서울역", latitude: 37.5547, longitude: 126.9707),
        Place(name: "서울숲", latitude: 37.5444, longitude: 127.0374),
        Place(name: "성수역", latitude: 37.5446, longitude: 127.0559),
        Place(name: "도산공원", latitude: 37.5244, longitude: 127.0351),
        Place(name: "강남역", latitude: 37.4979, longitude: 127.0276),
        Place(name: "잠실역", latitude: 37.5133, longitude: 127.1002),
        Place(name: "여의도", latitude: 37.5219, longitude: 126.9245),
        Place(name: "용산역", latitude: 37.5299, longitude: 126.9648),
        Place(name: "건대입구역", latitude: 37.5404, longitude: 127.0692),
        Place(name: "혜화역", latitude: 37.5821, longitude: 127.0019),
        Place(name: "연남동", latitude: 37.5660, longitude: 126.9228),
        Place(name: "망원역", latitude: 37.5560, longitude: 126.9101),
        Place(name: "합정역", latitude: 37.5495, longitude: 126.9137),
        Place(name: "고속터미널", latitude: 37.5048, longitude: 127.0049),
        Place(name: "수원역", latitude: 37.2662, longitude: 127.0001),
        Place(name: "인천시청", latitude: 37.4563, longitude: 126.7052),
        Place(name: "대성리역", latitude: 37.6840, longitude: 127.3794),
        Place(name: "부산역", latitude: 35.1151, longitude: 129.0414),
        Place(name: "대전역", latitude: 36.3323, longitude: 127.4344),
        Place(name: "대구역", latitude: 35.8759, longitude: 128.5962),
        Place(name: "광주역", latitude: 35.1652, longitude: 126.9093),
        Place(name: "제주시", latitude: 33.4996, longitude: 126.5312)
    ]

    static func name(latitude: Double, longitude: Double) -> String {
        guard let nearest = places.min(by: {
            GeoDistance.meters(
                latitude1: latitude,
                longitude1: longitude,
                latitude2: $0.latitude,
                longitude2: $0.longitude
            ) < GeoDistance.meters(
                latitude1: latitude,
                longitude1: longitude,
                latitude2: $1.latitude,
                longitude2: $1.longitude
            )
        }) else {
            return "이 지역 부근"
        }

        let distance = GeoDistance.meters(
            latitude1: latitude,
            longitude1: longitude,
            latitude2: nearest.latitude,
            longitude2: nearest.longitude
        )
        return distance <= 8_000 ? "\(nearest.name) 부근" : broadRegion(latitude, longitude)
    }

    private static func broadRegion(_ latitude: Double, _ longitude: Double) -> String {
        if (37.40...37.72).contains(latitude), (126.75...127.20).contains(longitude) {
            return "서울 일대"
        }
        if (37.10...37.90).contains(latitude), (126.55...127.70).contains(longitude) {
            return "수도권 일대"
        }
        return "이 지역 부근"
    }
}
