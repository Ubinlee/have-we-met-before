import FirebaseAuth
import Foundation

@MainActor
final class FirebaseSession: ObservableObject {
    enum State: Equatable {
        case idle
        case signingIn
        case authenticated(userID: String)
        case failed(message: String)
    }

    @Published private(set) var state: State = .idle

    func signInIfNeeded() async {
        if let user = Auth.auth().currentUser {
            state = .authenticated(userID: user.uid)
            return
        }

        state = .signingIn

        do {
            let result = try await Auth.auth().signInAnonymously()
            state = .authenticated(userID: result.user.uid)
        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }
}
