import CoreLocation
import Foundation

@MainActor
enum ApproximatePlaceResolver {
    private static var cache: [String: String] = [:]

    static func name(latitude: Double, longitude: Double) async -> String {
        let key = String(format: "%.2f,%.2f", latitude, longitude)
        if let cached = cache[key] { return cached }

        let location = CLLocation(latitude: latitude, longitude: longitude)
        do {
            let placemarks = try await CLGeocoder().reverseGeocodeLocation(
                location,
                preferredLocale: Locale(identifier: "ko_KR")
            )
            let resolved = placemarks.first.map(displayName) ?? "위치 이름 확인 불가"
            cache[key] = resolved
            return resolved
        } catch {
            return "위치 이름을 불러오지 못했어요"
        }
    }

    private static func displayName(_ place: CLPlacemark) -> String {
        if let landmark = place.areasOfInterest?.first,
           !landmark.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(landmark) 부근"
        }

        if let neighborhood = place.subLocality,
           !neighborhood.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(neighborhood) 부근"
        }

        if let district = place.locality,
           !district.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(district) 부근"
        }

        if let region = place.administrativeArea,
           !region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(region) 부근"
        }

        return "위치 이름 확인 불가"
    }
}
