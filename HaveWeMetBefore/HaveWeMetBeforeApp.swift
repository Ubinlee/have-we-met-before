import FirebaseAnalytics
import FirebaseCore
import SwiftUI

@main
struct HaveWeMetBeforeApp: App {
    @StateObject private var firebaseSession: FirebaseSession

    init() {
        FirebaseApp.configure()
        Analytics.setAnalyticsCollectionEnabled(true)
#if DEBUG
        Analytics.logEvent("analytics_connection_check", parameters: [
            "source": "xcode_debug"
        ])
#endif
        _firebaseSession = StateObject(wrappedValue: FirebaseSession())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(firebaseSession)
                .preferredColorScheme(.light)
                .task {
                    await firebaseSession.signInIfNeeded()
                }
        }
    }
}
