import FirebaseAnalytics
import Foundation
import Photos

enum AnalyticsTracker {
    static func log(_ name: String, parameters: [String: Any] = [:]) {
        var values = parameters
        values["app_build"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        Analytics.logEvent(name, parameters: values)
    }

    static func logPairConnectedOnce(localPairID: String, role: String) {
        let key = "analytics_pair_connected_\(localPairID)"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        log("pair_connected", parameters: ["role": role])
    }

    static func permissionStatus(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized: "full"
        case .limited: "limited"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not_determined"
        @unknown default: "unknown"
        }
    }

    static func durationBucket(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<10: "under_10s"
        case ..<30: "10_30s"
        case ..<60: "30_60s"
        default: "over_60s"
        }
    }

    static func recordCountBucket(_ count: Int) -> String {
        switch count {
        case 0: "0"
        case 1...9: "1_9"
        case 10...49: "10_49"
        case 50...199: "50_199"
        default: "200_plus"
        }
    }

    static func scoreBucket(_ score: Int) -> String {
        switch score {
        case ..<40: "0_39"
        case ..<60: "40_59"
        case ..<80: "60_79"
        case ..<90: "80_89"
        default: "90_100"
        }
    }

    static func progressBucket(_ progress: Double) -> String {
        switch progress {
        case ..<0.25: "0_24"
        case ..<0.5: "25_49"
        case ..<0.75: "50_74"
        default: "75_99"
        }
    }

    static func relationshipLabel(_ label: String) -> String {
        switch label {
        case "마주쳤을지도 모르는 사이": "might_have_met"
        case "발길이 겹쳤던 사이": "paths_crossed"
        case "근처에 있었던 사이": "nearby"
        default: "no_intersection"
        }
    }

    static func errorCode(_ error: Error) -> String {
        let nsError = error as NSError
        let message = nsError.localizedDescription.lowercased()

        if nsError.domain == "FIRFirestoreErrorDomain", nsError.code == 7 {
            return "firebase_permission_denied"
        }
        if nsError.domain == NSURLErrorDomain { return "network_unavailable" }
        if message.contains("권한") || message.contains("permission") { return "permission_denied" }
        if message.contains("만료") || message.contains("expired") { return "invite_expired" }
        if message.contains("이미 연결") { return "already_connected" }
        if message.contains("초대") || message.contains("invite") { return "invite_invalid" }
        if message.contains("기록") { return "record_preparation_failed" }
        if message.contains("결과") && message.contains("저장") { return "result_save_failed" }
        return "unknown"
    }
}
