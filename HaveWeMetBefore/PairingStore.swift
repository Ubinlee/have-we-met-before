import FirebaseFirestore
import Foundation

struct FriendConnectionSummary: Identifiable, Sendable {
    let id: String
    let nickname: String
    let score: Int?
    let intersectionDayCount: Int
    let closestStrength: IntersectionStrength?
    let firstMetDate: Date?
    let firstMetStatus: String?
    let hasStoredResult: Bool
    let isReady: Bool
}

@MainActor
final class PairingStore: ObservableObject {
    private static let recordSchemaVersion = 2

    enum OperationState: Equatable {
        case idle
        case working
        case succeeded(message: String)
        case failed(message: String)
    }

    @Published var nickname = ""
    @Published var inviteID = ""
    @Published var joinInviteID = ""
    @Published var firstMetDate = Calendar.current.startOfDay(for: Date())
    @Published private(set) var activePairID: String?
    @Published private(set) var pairStatus: String?
    @Published private(set) var savedFirstMetDate: Date?
    @Published private(set) var firstMetProposedBy: String?
    @Published private(set) var firstMetStatus: String?
    @Published private(set) var uploadedRecordCount = 0
    @Published private(set) var comparisonResult: DestinyScoreResult?
    @Published private(set) var analysisProgress = 0.0
    @Published private(set) var isWaitingForRecords = false
    @Published private(set) var analysisMessage = "사진에 남은 시간과 위치 정보를 확인하고 있어요."
    @Published private(set) var completedAnalysisCount = 0
    @Published private(set) var friendSummaries: [FriendConnectionSummary] = []
    @Published private(set) var state: OperationState = .idle
    @Published private(set) var creatorID: String?
    @Published private(set) var connectedFriendNickname = "친구"
    @Published private(set) var inviteCreatorNickname = "친구"
    @Published private(set) var isCreatingInvite = false
    @Published private(set) var isPreviewingInvite = false
    @Published private(set) var isAcceptingInvite = false

    private let database = Firestore.firestore()
    private var pairListener: ListenerRegistration?
    private var membersListener: ListenerRegistration?
    private var currentUserID: String?
    private var analysisInFlight = false
    private var resultCache: [String: DestinyScoreResult] = [:]

    var isWorking: Bool { state == .working }

    var canPreviewInvite: Bool {
        isValidInviteCode(normalizedInviteID(joinInviteID)) && !isPreviewingInvite
    }

    var currentPairID: String? {
        activePairID ?? (inviteID.isEmpty ? nil : inviteID)
    }

    var hasSavedFirstMetDate: Bool { savedFirstMetDate != nil }
    var isFirstMetDateConfirmed: Bool { firstMetStatus == "confirmed" }

    func isCreator(userID: String) -> Bool { creatorID == userID }

    func needsFirstMetDateConfirmation(userID: String) -> Bool {
        firstMetStatus == "pending"
            && firstMetProposedBy != nil
            && firstMetProposedBy != userID
    }

    func loadLatestPair(userID: String) async {
        currentUserID = userID
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

            friendSummaries = await loadFriendSummaries(
                userID: userID,
                pairs: snapshot.documents
            )

            let availablePairs = snapshot.documents.filter { pair in
                switch pair.data()["status"] as? String {
                case "active":
                    return true
                case "waiting":
                    return isValidInviteCode(pair.documentID)
                default:
                    return false
                }
            }

            guard let pair = availablePairs.max(by: {
                timestamp(from: $0.data()["updatedAt"])
                    < timestamp(from: $1.data()["updatedAt"])
            }) else {
                activePairID = nil
                inviteID = ""
                joinInviteID = ""
                pairStatus = nil
                pairListener?.remove()
                pairListener = nil
                membersListener?.remove()
                membersListener = nil
                return
            }

            applyPair(documentID: pair.documentID, data: pair.data())
            listenToPair(documentID: pair.documentID)
            _ = await loadStoredResult(pairID: pair.documentID)
        } catch {
            state = .failed(message: userFacingMessage(for: error))
        }
    }

    func openPair(pairID: String, userID: String) async {
        currentUserID = userID
        comparisonResult = nil
        state = .working
        do {
            let snapshot = try await database.collection("pairs").document(pairID).getDocument()
            guard let data = snapshot.data() else {
                state = .failed(message: "연결 정보를 찾을 수 없어요.")
                return
            }
            applyPair(documentID: snapshot.documentID, data: data)
            listenToPair(documentID: snapshot.documentID)
            if await loadStoredResult(pairID: snapshot.documentID) { return }
            if isFirstMetDateConfirmed {
                analysisMessage = "두 사람의 기록 상태를 확인하고 있어요."
            }
        } catch {
            state = .failed(message: userFacingMessage(for: error))
        }
    }

    func disconnectPair(pairID: String, userID: String) async {
        state = .working
        do {
            try await database.collection("pairs").document(pairID).updateData([
                "status": "ended",
                "updatedAt": FieldValue.serverTimestamp()
            ])
            friendSummaries.removeAll { $0.id == pairID }
            if activePairID == pairID {
                activePairID = nil
                inviteID = ""
                joinInviteID = ""
                comparisonResult = nil
                pairStatus = nil
            }
            state = .succeeded(message: "연결을 해제했어요.")
        } catch {
            state = .failed(message: userFacingMessage(for: error))
        }
    }

    func saveProfile(userID: String) async -> Bool {
        currentUserID = userID
        let trimmedNickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNickname.isEmpty else {
            state = .failed(message: "닉네임을 입력해 주세요.")
            return false
        }
        guard trimmedNickname.count <= 12 else {
            state = .failed(message: "닉네임은 12자 이하로 입력해 주세요.")
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
        guard !isCreatingInvite else { return }
        isCreatingInvite = true
        defer { isCreatingInvite = false }

        let trimmedNickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNickname.isEmpty else {
            state = .failed(message: "닉네임을 입력해 주세요.")
            return
        }
        guard trimmedNickname.count <= 12 else {
            state = .failed(message: "닉네임은 12자 이하로 입력해 주세요.")
            return
        }
        nickname = trimmedNickname

        state = .working

        do {
            let previousInviteID = isValidInviteCode(inviteID) ? inviteID : nil
            let pairID = try await makeUniqueInviteCode()
            let pairReference = database.collection("pairs").document(pairID)
            let batch = database.batch()

            batch.setData([
                "creatorId": userID,
                "creatorNickname": nickname,
                "memberIds": [userID],
                "status": "waiting",
                "expiresAt": Timestamp(date: Date().addingTimeInterval(24 * 60 * 60)),
                "createdAt": FieldValue.serverTimestamp(),
                "updatedAt": FieldValue.serverTimestamp()
            ], forDocument: pairReference)

            if let previousInviteID, previousInviteID != pairID {
                batch.updateData([
                    "status": "ended",
                    "updatedAt": FieldValue.serverTimestamp()
                ], forDocument: database.collection("pairs").document(previousInviteID))
            }

            try await batch.commit()

            inviteID = pairID
            activePairID = nil
            creatorID = userID
            pairStatus = "친구의 수락을 기다리고 있어요."
            state = .succeeded(message: "초대 ID를 만들었어요.")
            listenToPair(documentID: pairID)

            // The invite is ready as soon as the pair document is committed.
            // Preparing the creator's member record must not keep the button disabled.
            Task { [weak self] in
                guard let self else { return }
                try? await self.saveMember(
                    pairID: pairID,
                    userID: userID,
                    nickname: self.nickname,
                    analysisStatus: "notStarted",
                    recordCount: 0
                )
            }
        } catch {
            state = .failed(message: userFacingMessage(for: error))
        }
    }

    func previewInvite(userID: String) async -> Bool {
        guard !isPreviewingInvite else { return false }
        let pairID = normalizedInviteID(joinInviteID)
        guard isValidInviteCode(pairID) else {
            state = .failed(message: "6자리 초대 코드를 입력해 주세요.")
            return false
        }
        isPreviewingInvite = true
        defer { isPreviewingInvite = false }
        state = .working
        do {
            let snapshot = try await database.collection("pairs").document(pairID).getDocument()
            guard let data = snapshot.data() else {
                state = .failed(message: "사용할 수 없는 초대 코드예요.")
                return false
            }
            if let expiresAt = data["expiresAt"] as? Timestamp, expiresAt.dateValue() < Date() {
                state = .failed(message: "만료된 초대 코드예요. 새 코드를 받아 주세요.")
                return false
            }
            guard data["status"] as? String == "waiting",
                  let creator = data["creatorId"] as? String,
                  creator != userID else {
                state = .failed(message: creatorErrorMessage(data: data, userID: userID))
                return false
            }
            inviteCreatorNickname = data["creatorNickname"] as? String ?? "친구"
            joinInviteID = pairID
            state = .succeeded(message: "초대 코드를 확인했어요.")
            return true
        } catch {
            state = .failed(message: inviteAcceptanceMessage(for: error))
            return false
        }
    }

    func acceptPair(userID: String) async -> Bool {
        guard !isAcceptingInvite else { return false }
        let pairID = normalizedInviteID(joinInviteID)
        guard isValidInviteCode(pairID) else {
            state = .failed(message: "6자리 초대 코드를 입력해 주세요.")
            return false
        }
        isAcceptingInvite = true
        defer { isAcceptingInvite = false }
        state = .working

        let pairReference = database.collection("pairs").document(pairID)
        let memberReference = pairReference.collection("members").document(userID)

        do {
            let creatorID = try await database.runTransaction { transaction, errorPointer -> Any? in
                do {
                    let snapshot = try transaction.getDocument(pairReference)
                    guard snapshot.exists,
                          let data = snapshot.data(),
                          data["status"] as? String == "waiting",
                          let memberIDs = data["memberIds"] as? [String],
                          memberIDs.count == 1,
                          !memberIDs.contains(userID) else {
                        errorPointer?.pointee = NSError(
                            domain: "PairingStore",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "유효한 대기 중 초대가 아니에요."]
                        )
                        return nil
                    }

                    if let expiresAt = data["expiresAt"] as? Timestamp,
                       expiresAt.dateValue() < Date() {
                        errorPointer?.pointee = NSError(
                            domain: "PairingStore",
                            code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "초대 코드가 만료됐어요."]
                        )
                        return nil
                    }

                    transaction.updateData([
                        "memberIds": FieldValue.arrayUnion([userID]),
                        "status": "active",
                        "updatedAt": FieldValue.serverTimestamp()
                    ], forDocument: pairReference)
                    transaction.setData([
                        "nickname": self.nickname,
                        "analysisStatus": "notStarted",
                        "recordCount": 0,
                        "recordSchemaVersion": Self.recordSchemaVersion,
                        "updatedAt": FieldValue.serverTimestamp()
                    ], forDocument: memberReference)

                    return data["creatorId"] as? String
                } catch {
                    errorPointer?.pointee = error as NSError
                    return nil
                }
            }

            inviteID = ""
            joinInviteID = ""
            activePairID = pairID
            self.creatorID = creatorID as? String
            connectedFriendNickname = inviteCreatorNickname
            pairStatus = "친구와 연결됐어요."
            state = .succeeded(message: "친구와 연결됐어요.")
            listenToPair(documentID: pairID)
            return true
        } catch {
            state = .failed(message: inviteAcceptanceMessage(for: error))
            return false
        }
    }

    func proposeFirstMetDate(userID: String) async {
        guard let pairID = activePairID else {
            state = .failed(message: "먼저 친구와 연결해 주세요.")
            return
        }

        let normalizedDate = Calendar.current.startOfDay(for: firstMetDate)
        guard normalizedDate <= Calendar.current.startOfDay(for: Date()) else {
            state = .failed(message: "처음 알게 된 날은 오늘 이후로 정할 수 없어요.")
            return
        }
        state = .working

        do {
            try await database
                .collection("pairs")
                .document(pairID)
                .updateData([
                    "firstMetAt": Timestamp(date: normalizedDate),
                    "firstMetStatus": "pending",
                    "firstMetProposedBy": userID,
                    "firstMetConfirmedBy": [userID],
                    "updatedAt": FieldValue.serverTimestamp()
                ])

            firstMetDate = normalizedDate
            savedFirstMetDate = normalizedDate
            firstMetStatus = "pending"
            firstMetProposedBy = userID
            uploadedRecordCount = 0
            comparisonResult = nil
            analysisProgress = 0
            state = .succeeded(message: "기준일을 제안했어요. 친구의 확인을 기다리고 있어요.")
        } catch {
            state = .failed(message: userFacingMessage(for: error))
        }
    }

    func confirmFirstMetDate(userID: String) async {
        guard let pairID = activePairID,
              savedFirstMetDate != nil,
              firstMetStatus == "pending" else {
            state = .failed(message: "확인할 기준일이 없어요.")
            return
        }

        state = .working
        analysisProgress = max(analysisProgress, 0.08)
        do {
            try await database.collection("pairs").document(pairID).updateData([
                "firstMetStatus": "confirmed",
                "firstMetConfirmedBy": FieldValue.arrayUnion([userID]),
                "updatedAt": FieldValue.serverTimestamp()
            ])
            firstMetStatus = "confirmed"
            state = .succeeded(message: "두 사람이 기준일을 확인했어요. 기록을 자동으로 준비할게요.")
        } catch {
            state = .failed(message: userFacingMessage(for: error))
        }
    }

    func prepareVisits(userID: String, events: [VisitEvent]) async {
        guard let pairID = currentPairID else {
            state = .failed(message: "먼저 친구 초대를 만들거나 수락해 주세요.")
            return
        }

        guard let cutoffDate = savedFirstMetDate, isFirstMetDateConfirmed else {
            state = .failed(message: "친구와 기준일을 먼저 확인해 주세요.")
            return
        }

        let records = SharedVisitRecordBuilder.build(
            from: events.filter { $0.capturedAt < cutoffDate }
        )
        state = .working
        analysisProgress = max(analysisProgress, 0.18)
        isWaitingForRecords = false
        analysisMessage = "내 사진 기록을 분석용 데이터로 준비하고 있어요."

        do {
            try await saveMember(
                pairID: pairID,
                userID: userID,
                nickname: nickname,
                analysisStatus: "analyzing",
                recordCount: records.count
            )

            try await replaceVisits(pairID: pairID, userID: userID, records: records)
            analysisProgress = max(analysisProgress, 0.48)

            try await saveMember(
                pairID: pairID,
                userID: userID,
                nickname: nickname,
                analysisStatus: "ready",
                recordCount: records.count
            )

            uploadedRecordCount = records.count
            analysisProgress = max(analysisProgress, 0.68)
            analysisMessage = "친구의 기록 준비 상태를 확인하고 있어요."
            state = .succeeded(message: "분석 준비가 완료됐어요. 흐린 방문 기록 \(records.count)개를 준비했어요.")
        } catch {
            state = .failed(message: userFacingMessage(for: error))
        }
    }

    func startAnalysis(userID: String) async {
        guard isFirstMetDateConfirmed else {
            state = .failed(message: "친구와 기준일을 먼저 확인해 주세요.")
            return
        }
        analysisProgress = max(analysisProgress, 0.72)
        analysisMessage = "두 사람의 기록 상태를 확인하고 있어요."
        await compareWithFriend(userID: userID)
    }

    func compareWithFriend(userID: String) async {
        guard let pairID = currentPairID else {
            state = .failed(message: "연결된 친구가 없어요.")
            return
        }

        state = .working
        isWaitingForRecords = false
        analysisMessage = "두 사람의 기록 상태를 확인하고 있어요."

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

            guard let firstMetTimestamp = data["firstMetAt"] as? Timestamp,
                  (data["firstMetStatus"] as? String == "confirmed"
                    || data["firstMetStatus"] == nil) else {
                savedFirstMetDate = nil
                state = .failed(message: "친구와 기준일을 먼저 확인해 주세요.")
                return
            }
            activePairID = pairID
            pairStatus = "친구와 연결됐어요."
            let cutoffDate = firstMetTimestamp.dateValue()
            firstMetDate = cutoffDate
            savedFirstMetDate = cutoffDate

            async let ownMember = database
                .collection("pairs")
                .document(pairID)
                .collection("members")
                .document(userID)
                .getDocument()
            async let friendMember = database
                .collection("pairs")
                .document(pairID)
                .collection("members")
                .document(friendID)
                .getDocument()
            let (ownMemberSnapshot, friendMemberSnapshot) = try await (ownMember, friendMember)

            guard memberIsReady(
                ownMemberSnapshot.data()
            ) else {
                isWaitingForRecords = true
                analysisMessage = "내 사진 기록을 준비하고 있어요."
                state = .succeeded(message: "내 기록을 자동으로 준비하고 있어요. 잠시 후 다시 시도해 주세요.")
                return
            }

            guard memberIsReady(
                friendMemberSnapshot.data()
            ) else {
                isWaitingForRecords = true
                analysisMessage = "\(connectedFriendNickname)님의 기록 준비를 기다리고 있어요."
                state = .succeeded(message: "친구의 기록 준비가 아직 끝나지 않았어요.")
                return
            }

            isWaitingForRecords = false
            analysisProgress = max(analysisProgress, 0.82)
            analysisMessage = "두 사람의 시간과 위치 기록을 비교하고 있어요."
            async let ownSnapshot = visitsCollection(pairID: pairID, userID: userID)
                .getDocuments()
            async let friendSnapshot = visitsCollection(pairID: pairID, userID: friendID)
                .getDocuments()
            let (ownDocuments, friendDocuments) = try await (ownSnapshot, friendSnapshot)
            analysisProgress = max(analysisProgress, 0.9)

            let ownRecords = ownDocuments.documents
                .compactMap(sharedVisitRecord)
                .filter { $0.approximateDate < cutoffDate }
            let friendRecords = friendDocuments.documents
                .compactMap(sharedVisitRecord)
                .filter { $0.approximateDate < cutoffDate }
            let intersections = SharedTrajectoryMatcher.compare(
                first: ownRecords,
                second: friendRecords
            )

            let result = DestinyScorer.calculate(
                intersections: intersections,
                calendar: .autoupdatingCurrent
            )

            try await saveComparisonResult(
                result,
                pairID: pairID,
                userID: userID,
                ownRecords: ownRecords
            )

            comparisonResult = result
            resultCache[pairID] = result
            analysisProgress = 1
            analysisMessage = "분석이 완료됐어요."
            updateFriendSummary(pairID: pairID, result: result, firstMetDate: cutoffDate)
            completedAnalysisCount += 1
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
            "schemaVersion": Self.recordSchemaVersion
        ]

        data["rankedIntersections"] = result.rankedIntersections.map { intersection in
            [
                "id": intersection.id,
                "firstRecordID": intersection.firstRecordID,
                "secondRecordID": intersection.secondRecordID,
                "firstCapturedAt": Timestamp(date: intersection.firstCapturedAt),
                "secondCapturedAt": Timestamp(date: intersection.secondCapturedAt),
                "strength": intersection.strength.rawValue,
                "distanceMeters": intersection.distanceMeters,
                "timeDifference": intersection.timeDifference,
                "approximateLatitude": intersection.approximateLatitude,
                "approximateLongitude": intersection.approximateLongitude
            ]
        }

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

    @discardableResult
    private func loadStoredResult(pairID: String) async -> Bool {
        if let cached = resultCache[pairID] {
            comparisonResult = cached
            analysisProgress = 1
            isWaitingForRecords = false
            analysisMessage = "분석이 완료됐어요."
            state = .succeeded(message: "저장된 분석 결과를 열었어요.")
            return true
        }

        do {
            let snapshot = try await database.collection("pairs").document(pairID)
                .collection("results").document("current").getDocument()
            guard let data = snapshot.data(),
                  integer(from: data["schemaVersion"]) == Self.recordSchemaVersion,
                  let score = integer(from: data["score"]),
                  let dayCount = integer(from: data["intersectionDayCount"]) else {
                return false
            }

            let rankedData = data["rankedIntersections"] as? [[String: Any]] ?? []
            let ranked = rankedData.compactMap(storedIntersection)
            guard score == 0 || !ranked.isEmpty else { return false }

            let result = DestinyScoreResult(
                score: score,
                closestIntersection: ranked.first,
                totalIntersectionDayCount: dayCount,
                additionalIntersectionDayCount: max(0, dayCount - 1),
                rankedIntersections: ranked
            )
            resultCache[pairID] = result
            comparisonResult = result
            analysisProgress = 1
            isWaitingForRecords = false
            analysisMessage = "분석이 완료됐어요."
            state = .succeeded(message: "저장된 분석 결과를 열었어요.")
            return true
        } catch {
            state = .failed(message: userFacingMessage(for: error))
            return false
        }
    }

    private func storedIntersection(_ data: [String: Any]) -> TrajectoryIntersection? {
        guard let id = data["id"] as? String,
              let firstRecordID = data["firstRecordID"] as? String,
              let secondRecordID = data["secondRecordID"] as? String,
              let firstCapturedAt = (data["firstCapturedAt"] as? Timestamp)?.dateValue(),
              let secondCapturedAt = (data["secondCapturedAt"] as? Timestamp)?.dateValue(),
              let strengthRaw = integer(from: data["strength"]),
              let strength = IntersectionStrength(rawValue: strengthRaw),
              let distanceMeters = double(from: data["distanceMeters"]),
              let timeDifference = double(from: data["timeDifference"]),
              let latitude = double(from: data["approximateLatitude"]),
              let longitude = double(from: data["approximateLongitude"]) else { return nil }

        return TrajectoryIntersection(
            id: id,
            firstRecordID: firstRecordID,
            secondRecordID: secondRecordID,
            firstCapturedAt: firstCapturedAt,
            secondCapturedAt: secondCapturedAt,
            strength: strength,
            distanceMeters: distanceMeters,
            timeDifference: timeDifference,
            approximateLatitude: latitude,
            approximateLongitude: longitude
        )
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
                "recordSchemaVersion": Self.recordSchemaVersion,
                "updatedAt": FieldValue.serverTimestamp()
            ])
    }

    private func loadFriendSummaries(
        userID: String,
        pairs: [QueryDocumentSnapshot]
    ) async -> [FriendConnectionSummary] {
        var summaries: [FriendConnectionSummary] = []

        for pair in pairs {
            let data = pair.data()
            guard data["status"] as? String == "active",
                  let memberIDs = data["memberIds"] as? [String],
                  let friendID = memberIDs.first(where: { $0 != userID }) else {
                continue
            }

            do {
                async let member = database.collection("pairs").document(pair.documentID)
                    .collection("members").document(friendID).getDocument()
                async let result = database.collection("pairs").document(pair.documentID)
                    .collection("results").document("current").getDocument()
                let (memberSnapshot, resultSnapshot) = try await (member, result)
                let memberData = memberSnapshot.data()
                let resultData = resultSnapshot.data()
                let hasStoredResult = integer(from: resultData?["schemaVersion"]) == Self.recordSchemaVersion
                let rawStrength = hasStoredResult ? integer(from: resultData?["closestLevel"]) : nil

                summaries.append(
                    FriendConnectionSummary(
                        id: pair.documentID,
                        nickname: memberData?["nickname"] as? String ?? "친구",
                        score: hasStoredResult ? integer(from: resultData?["score"]) : nil,
                        intersectionDayCount: hasStoredResult ? integer(from: resultData?["intersectionDayCount"]) ?? 0 : 0,
                        closestStrength: rawStrength.flatMap(IntersectionStrength.init(rawValue:)),
                        firstMetDate: (data["firstMetAt"] as? Timestamp)?.dateValue(),
                        firstMetStatus: data["firstMetStatus"] as? String
                            ?? ((data["firstMetAt"] as? Timestamp) == nil ? nil : "confirmed"),
                        hasStoredResult: hasStoredResult,
                        isReady: memberIsReady(memberData)
                    )
                )
            } catch {
                continue
            }
        }

        return summaries.sorted {
            switch ($0.score, $1.score) {
            case let (left?, right?): left > right
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): $0.nickname < $1.nickname
            }
        }
    }

    private func memberIsReady(_ data: [String: Any]?) -> Bool {
        data?["analysisStatus"] as? String == "ready"
            && integer(from: data?["recordSchemaVersion"]) == Self.recordSchemaVersion
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
        creatorID = data["creatorId"] as? String
        if let friend = friendSummaries.first(where: { $0.id == documentID }) {
            connectedFriendNickname = friend.nickname
        }

        switch data["status"] as? String {
        case "active":
            activePairID = documentID
            inviteID = ""
            joinInviteID = ""
            pairStatus = "친구와 연결됐어요."
            if let userID = currentUserID {
                listenToMemberReadiness(pairID: documentID, userID: userID)
                Task { await refreshConnectedFriendNickname(pairID: documentID, userID: userID) }
            }
        case "waiting":
            activePairID = nil
            inviteID = isValidInviteCode(documentID) ? documentID : ""
            pairStatus = inviteID.isEmpty ? nil : "친구의 수락을 기다리고 있어요."
            membersListener?.remove()
            membersListener = nil
        default:
            activePairID = nil
            inviteID = ""
            joinInviteID = ""
            pairStatus = nil
            membersListener?.remove()
            membersListener = nil
        }

        if let timestamp = data["firstMetAt"] as? Timestamp {
            let date = timestamp.dateValue()
            firstMetDate = date
            savedFirstMetDate = date
            firstMetStatus = data["firstMetStatus"] as? String ?? "confirmed"
            firstMetProposedBy = data["firstMetProposedBy"] as? String
        } else {
            savedFirstMetDate = nil
            firstMetStatus = nil
            firstMetProposedBy = nil
        }
    }

    private func refreshConnectedFriendNickname(pairID: String, userID: String) async {
        do {
            let pair = try await database.collection("pairs").document(pairID).getDocument()
            guard let memberIDs = pair.data()?["memberIds"] as? [String],
                  let friendID = memberIDs.first(where: { $0 != userID }) else { return }
            let member = try await database.collection("pairs").document(pairID)
                .collection("members").document(friendID).getDocument()
            connectedFriendNickname = member.data()?["nickname"] as? String ?? "친구"
        } catch {
            // The connection remains usable even if the display name cannot be refreshed yet.
        }
    }

    private func listenToPair(documentID: String) {
        pairListener?.remove()
        pairListener = database.collection("pairs").document(documentID)
            .addSnapshotListener { [weak self] snapshot, error in
                guard error == nil, let data = snapshot?.data() else { return }
                Task { @MainActor [weak self] in
                    self?.applyPair(documentID: documentID, data: data)
                }
            }
    }

    private func listenToMemberReadiness(pairID: String, userID: String) {
        membersListener?.remove()
        membersListener = database.collection("pairs").document(pairID)
            .collection("members")
            .addSnapshotListener { [weak self] snapshot, error in
                guard error == nil,
                      let documents = snapshot?.documents,
                      documents.count == 2 else {
                    return
                }

                Task { @MainActor [weak self] in
                    guard let self,
                          documents.allSatisfy({ self.memberIsReady($0.data()) }),
                          self.isFirstMetDateConfirmed,
                          self.comparisonResult == nil,
                          !self.analysisInFlight else { return }
                    self.analysisInFlight = true
                    await self.compareWithFriend(userID: userID)
                    self.analysisInFlight = false
                }
            }
    }

    private func normalizedInviteID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private func isValidInviteCode(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return value.count == 6
            && value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private func makeInviteCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<6).compactMap { _ in alphabet.randomElement() })
    }

    private func makeUniqueInviteCode() async throws -> String {
        for _ in 0..<8 {
            let candidate = makeInviteCode()
            let snapshot = try await database.collection("pairs").document(candidate).getDocument()
            if !snapshot.exists { return candidate }
        }
        throw NSError(
            domain: "InviteCode",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "새 초대 코드를 만들지 못했어요. 잠시 후 다시 시도해 주세요."]
        )
    }

    private func updateFriendSummary(
        pairID: String,
        result: DestinyScoreResult,
        firstMetDate: Date
    ) {
        guard let index = friendSummaries.firstIndex(where: { $0.id == pairID }) else { return }
        let previous = friendSummaries[index]
        friendSummaries[index] = FriendConnectionSummary(
            id: previous.id,
            nickname: previous.nickname,
            score: result.score,
            intersectionDayCount: result.totalIntersectionDayCount,
            closestStrength: result.closestIntersection?.strength,
            firstMetDate: firstMetDate,
            firstMetStatus: "confirmed",
            hasStoredResult: true,
            isReady: true
        )
        friendSummaries.sort {
            switch ($0.score, $1.score) {
            case let (left?, right?): left > right
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): $0.nickname < $1.nickname
            }
        }
    }

    private func creatorErrorMessage(data: [String: Any], userID: String) -> String {
        if data["creatorId"] as? String == userID { return "내가 만든 초대 코드는 입력할 수 없어요." }
        return "이미 사용했거나 사용할 수 없는 초대 코드예요."
    }

    private func timestamp(from value: Any?) -> TimeInterval {
        (value as? Timestamp)?.dateValue().timeIntervalSince1970 ?? 0
    }

    private func integer(from value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        return value as? Int
    }

    private func double(from value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        return value as? Double
    }

    private func userFacingMessage(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == FirestoreErrorDomain,
           nsError.code == FirestoreErrorCode.permissionDenied.rawValue {
            return "Firebase 접근 권한을 확인해 주세요."
        }
        return error.localizedDescription
    }

    private func inviteAcceptanceMessage(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == FirestoreErrorDomain,
           nsError.code == FirestoreErrorCode.permissionDenied.rawValue {
            return "이 초대는 이미 사용됐거나 현재 계정에서 열 수 없어요. 새 초대 ID를 받아 주세요."
        }
        return userFacingMessage(for: error)
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
