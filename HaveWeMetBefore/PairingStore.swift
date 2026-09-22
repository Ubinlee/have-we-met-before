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
    @Published private(set) var activePairID: String?
    @Published private(set) var pairStatus: String?
    @Published private(set) var uploadedRecordCount = 0
    @Published private(set) var comparisonResult: DestinyScoreResult?
    @Published private(set) var state: OperationState = .idle

    private let database = Firestore.firestore()

    var isWorking: Bool { state == .working }

    var currentPairID: String? {
        activePairID ?? (inviteID.isEmpty ? nil : inviteID)
    }

    func loadLatestPair(userID: String) async {
        do {
            let profile = try await database
                .collection("users")
                .document(userID)
                .getDocument()
            if let savedNickname = profile.data()?["nickname"] as? String {
                nickname = savedNickname
            }

            let snapshot = try await database
                .collection("pairs")
                .whereField("memberIds", arrayContains: userID)
                .getDocuments()

            guard let pair = snapshot.documents.max(by: {
                timestamp(from: $0.data()["updatedAt"])
                    < timestamp(from: $1.data()["updatedAt"])
            }) else { return }

            applyPair(documentID: pair.documentID, data: pair.data())
        } catch {
            state = .failed(message: userFacingMessage(for: error))
        }
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
                nickname: nickname,
                analysisStatus: "notStarted",
                recordCount: 0
            )

            inviteID = pairID
            activePairID = nil
            pairStatus = "친구의 수락을 기다리고 있어요."
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
                nickname: nickname,
                analysisStatus: "notStarted",
                recordCount: 0
            )

            inviteID = pairID
            joinInviteID = pairID
            activePairID = pairID
            pairStatus = "친구와 연결됐어요."
            state = .succeeded(message: "친구와 연결됐어요.")
        } catch {
            state = .failed(message: userFacingMessage(for: error))
        }
    }

    func syncVisitsAndCompare(userID: String, events: [VisitEvent]) async {
        guard let pairID = currentPairID else {
            state = .failed(message: "먼저 친구 초대를 만들거나 수락해 주세요.")
            return
        }

        let records = SharedVisitRecordBuilder.build(from: events)
        state = .working

        do {
            try await saveMember(
                pairID: pairID,
                userID: userID,
                nickname: nickname,
                analysisStatus: "analyzing",
                recordCount: records.count
            )

            try await replaceVisits(pairID: pairID, userID: userID, records: records)

            try await saveMember(
                pairID: pairID,
                userID: userID,
                nickname: nickname,
                analysisStatus: "ready",
                recordCount: records.count
            )

            uploadedRecordCount = records.count
            state = .succeeded(message: "흐린 방문 기록 \(records.count)개를 준비했어요.")
            await compareWithFriend(userID: userID)
        } catch {
            state = .failed(message: userFacingMessage(for: error))
        }
    }

    func compareWithFriend(userID: String) async {
        guard let pairID = currentPairID else {
            state = .failed(message: "연결된 친구가 없어요.")
            return
        }

        state = .working

        do {
            let pairSnapshot = try await database
                .collection("pairs")
                .document(pairID)
                .getDocument()

            guard let data = pairSnapshot.data(),
                  data["status"] as? String == "active",
                  let memberIDs = data["memberIds"] as? [String],
                  let friendID = memberIDs.first(where: { $0 != userID }) else {
                pairStatus = "친구의 수락을 기다리고 있어요."
                state = .succeeded(message: "아직 친구가 초대를 수락하지 않았어요.")
                return
            }

            activePairID = pairID
            pairStatus = "친구와 연결됐어요."

            let friendMember = try await database
                .collection("pairs")
                .document(pairID)
                .collection("members")
                .document(friendID)
                .getDocument()

            guard friendMember.data()?["analysisStatus"] as? String == "ready" else {
                state = .succeeded(message: "친구의 사진 분석을 기다리고 있어요.")
                return
            }

            async let ownSnapshot = visitsCollection(pairID: pairID, userID: userID)
                .getDocuments()
            async let friendSnapshot = visitsCollection(pairID: pairID, userID: friendID)
                .getDocuments()
            let (ownDocuments, friendDocuments) = try await (ownSnapshot, friendSnapshot)

            let ownRecords = ownDocuments.documents.compactMap(sharedVisitRecord)
            let friendRecords = friendDocuments.documents.compactMap(sharedVisitRecord)
            let intersections = SharedTrajectoryMatcher.compare(
                first: ownRecords,
                second: friendRecords
            )

            var utcCalendar = Calendar(identifier: .gregorian)
            utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let result = DestinyScorer.calculate(
                intersections: intersections,
                calendar: utcCalendar
            )

            try await saveComparisonResult(
                result,
                pairID: pairID,
                userID: userID,
                ownRecords: ownRecords
            )

            comparisonResult = result
            state = .succeeded(
                message: intersections.isEmpty
                    ? "겹치는 기록을 찾지 못했어요."
                    : "두 사람의 흐린 기록 비교를 완료했어요."
            )
        } catch {
            state = .failed(message: userFacingMessage(for: error))
        }
    }

    private func replaceVisits(
        pairID: String,
        userID: String,
        records: [SharedVisitRecord]
    ) async throws {
        let collection = visitsCollection(pairID: pairID, userID: userID)
        let existing = try await collection.getDocuments()

        for chunk in existing.documents.chunked(maximumCount: 400) {
            let batch = database.batch()
            chunk.forEach { batch.deleteDocument($0.reference) }
            try await batch.commit()
        }

        for chunk in records.chunked(maximumCount: 400) {
            let batch = database.batch()
            for record in chunk {
                batch.setData([
                    "timeBucketIndex": record.timeBucketIndex,
                    "latitudeCell": record.latitudeCell,
                    "longitudeCell": record.longitudeCell,
                    "schemaVersion": record.schemaVersion
                ], forDocument: collection.document(record.id))
            }
            try await batch.commit()
        }
    }

    private func saveComparisonResult(
        _ result: DestinyScoreResult,
        pairID: String,
        userID: String,
        ownRecords: [SharedVisitRecord]
    ) async throws {
        var data: [String: Any] = [
            "score": result.score,
            "intersectionDayCount": result.totalIntersectionDayCount,
            "generatedBy": userID,
            "createdAt": FieldValue.serverTimestamp(),
            "schemaVersion": 1
        ]

        if let closest = result.closestIntersection,
           let closestRecord = ownRecords.first(where: { $0.id == closest.firstRecordID }) {
            data["closestLevel"] = closest.strength.rawValue
            data["closestTimeBucketIndex"] = closestRecord.timeBucketIndex
            data["closestLatitudeCell"] = closestRecord.latitudeCell
            data["closestLongitudeCell"] = closestRecord.longitudeCell
        }

        try await database
            .collection("pairs")
            .document(pairID)
            .collection("results")
            .document("current")
            .setData(data)
    }

    private func saveMember(
        pairID: String,
        userID: String,
        nickname: String,
        analysisStatus: String,
        recordCount: Int
    ) async throws {
        try await database
            .collection("pairs")
            .document(pairID)
            .collection("members")
            .document(userID)
            .setData([
                "nickname": nickname,
                "analysisStatus": analysisStatus,
                "recordCount": recordCount,
                "updatedAt": FieldValue.serverTimestamp()
            ])
    }

    private func visitsCollection(pairID: String, userID: String) -> CollectionReference {
        database.collection("pairs").document(pairID)
            .collection("members").document(userID)
            .collection("visits")
    }

    private func sharedVisitRecord(_ document: QueryDocumentSnapshot) -> SharedVisitRecord? {
        let data = document.data()
        guard let timeBucketIndex = integer(from: data["timeBucketIndex"]),
              let latitudeCell = integer(from: data["latitudeCell"]),
              let longitudeCell = integer(from: data["longitudeCell"]),
              let schemaVersion = integer(from: data["schemaVersion"]) else {
            return nil
        }

        return SharedVisitRecord(
            id: document.documentID,
            timeBucketIndex: timeBucketIndex,
            latitudeCell: latitudeCell,
            longitudeCell: longitudeCell,
            schemaVersion: schemaVersion
        )
    }

    private func applyPair(documentID: String, data: [String: Any]) {
        inviteID = documentID
        joinInviteID = documentID

        if data["status"] as? String == "active" {
            activePairID = documentID
            pairStatus = "친구와 연결됐어요."
        } else {
            activePairID = nil
            pairStatus = "친구의 수락을 기다리고 있어요."
        }
    }

    private func normalizedInviteID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func timestamp(from value: Any?) -> TimeInterval {
        (value as? Timestamp)?.dateValue().timeIntervalSince1970 ?? 0
    }

    private func integer(from value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        return value as? Int
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

private extension Array {
    func chunked(maximumCount: Int) -> [[Element]] {
        guard maximumCount > 0 else { return [] }
        return stride(from: 0, to: count, by: maximumCount).map { start in
            Array(self[start..<Swift.min(start + maximumCount, count)])
        }
    }
}
