import FirebaseCore
import SwiftUI

@main
struct HaveWeMetBeforeApp: App {
    @StateObject private var firebaseSession: FirebaseSession

    init() {
        FirebaseApp.configure()
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
