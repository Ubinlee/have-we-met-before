import FirebaseFirestore
import Foundation

@MainActor
final class PairingStore: ObservableObject {
    enum OperationState: Equatable {
        case idle
        case working
        case succeeded(message: String)
        case failed(message: String)
    }

    @Published var nickname = ""
    @Published var inviteID = ""
    @Published var joinInviteID = ""
    @Published private(set) var state: OperationState = .idle

    private let database = Firestore.firestore()

    var isWorking: Bool {
        state == .working
    }

    func saveProfile(userID: String) async -> Bool {
        let trimmedNickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNickname.isEmpty else {
            state = .failed(message: "닉네임을 입력해 주세요.")
            return false
        }

        guard trimmedNickname.count <= 20 else {
            state = .failed(message: "닉네임은 20자 이하로 입력해 주세요.")
            return false
        }

        state = .working
        let reference = database.collection("users").document(userID)

        do {
            let snapshot = try await reference.getDocument()
            var data: [String: Any] = [
                "nickname": trimmedNickname,
                "updatedAt": FieldValue.serverTimestamp()
            ]

            if !snapshot.exists {
                data["createdAt"] = FieldValue.serverTimestamp()
            }

            try await reference.setData(data, merge: true)
            nickname = trimmedNickname
            state = .succeeded(message: "프로필을 저장했어요.")
            return true
        } catch {
            state = .failed(message: userFacingMessage(for: error))
            return false
        }
    }

    func createPair(userID: String) async {
        guard await saveProfile(userID: userID) else { return }

        state = .working
        let pairID = UUID().uuidString.lowercased()
        let pairReference = database.collection("pairs").document(pairID)

        do {
            try await pairReference.setData([
                "creatorId": userID,
                "memberIds": [userID],
                "status": "waiting",
                "createdAt": FieldValue.serverTimestamp(),
                "updatedAt": FieldValue.serverTimestamp()
            ])

            try await saveMember(
                pairID: pairID,
                userID: userID,
                nickname: nickname
            )

            inviteID = pairID
            state = .succeeded(message: "초대 ID를 만들었어요.")
        } catch {
            state = .failed(message: userFacingMessage(for: error))
        }
    }

    func acceptPair(userID: String) async {
        let pairID = normalizedInviteID(joinInviteID)
        guard !pairID.isEmpty else {
            state = .failed(message: "초대 ID를 입력해 주세요.")
            return
        }

        guard await saveProfile(userID: userID) else { return }
        state = .working

        let pairReference = database.collection("pairs").document(pairID)

        do {
            let snapshot = try await pairReference.getDocument()
            guard snapshot.exists,
                  let data = snapshot.data(),
                  data["status"] as? String == "waiting",
                  let memberIDs = data["memberIds"] as? [String],
                  memberIDs.count == 1,
                  !memberIDs.contains(userID) else {
                state = .failed(message: "유효한 대기 중 초대가 아니에요.")
                return
            }

            try await pairReference.updateData([
                "memberIds": FieldValue.arrayUnion([userID]),
                "status": "active",
                "updatedAt": FieldValue.serverTimestamp()
            ])

            try await saveMember(
                pairID: pairID,
                userID: userID,
                nickname: nickname
            )

            inviteID = pairID
            joinInviteID = pairID
            state = .succeeded(message: "친구와 연결됐어요.")
        } catch {
            state = .failed(message: userFacingMessage(for: error))
        }
    }

    private func saveMember(
        pairID: String,
        userID: String,
        nickname: String
    ) async throws {
        try await database
            .collection("pairs")
            .document(pairID)
            .collection("members")
            .document(userID)
            .setData([
                "nickname": nickname,
                "analysisStatus": "notStarted",
                "recordCount": 0,
                "updatedAt": FieldValue.serverTimestamp()
            ])
    }

    private func normalizedInviteID(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func userFacingMessage(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == FirestoreErrorDomain,
           nsError.code == FirestoreErrorCode.permissionDenied.rawValue {
            return "Firebase 접근 권한을 확인해 주세요."
        }
        return error.localizedDescription
    }
}
