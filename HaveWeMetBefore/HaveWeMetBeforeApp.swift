import FirebaseCore
import SwiftUI

@main
struct HaveWeMetBeforeApp: App {
    @StateObject private var firebaseSession: FirebaseSession

    init() {
        #if DEBUG
        let configurationFile = "GoogleService-Info.plist"
        #else
        let configurationFile = "GoogleService-Info-TestFlight.plist"
        #endif

        guard let configurationPath = Bundle.main.path(forResource: configurationFile, ofType: nil),
              let options = FirebaseOptions(contentsOfFile: configurationPath) else {
            fatalError("Firebase configuration file is missing or invalid.")
        }

        FirebaseApp.configure(options: options)
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
