import FirebaseAuth
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
    private static let recordSchemaVersion = 3
    private static let resultSchemaVersion = 4

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
    @Published private(set) var analysisRunRevision = 0
    @Published private(set) var analysisNeedsRestart = false
    @Published private(set) var analysisRestartMessage = "이 기기에서 사진 기록 준비를 다시 시작해 주세요."
    /// 저장된 결과 조회가 끝난 페어. 조회가 끝나기 전에는 자동 분석을 시작하지 않습니다.
    @Published private(set) var resultLookupCompletedPairIDs: Set<String> = []

    private let database = Firestore.firestore()
    private var pairListener: ListenerRegistration?
    private var membersListener: ListenerRegistration?
    private var currentUserID: String?
    /// 서버(users/{uid})에 마지막으로 저장된 닉네임. 닉네임이 바뀌었는지 판단할 때 사용합니다.
    private var savedProfileNickname: String?
    private var resultCache: [String: DestinyScoreResult] = [:]
    private var cancelledAnalysisPairIDs: Set<String> = []
    /// 페어별 분석 실행 세대. 취소·재시작·새 준비가 시작되면 올라가고,
    /// 이전 세대의 작업은 await 이후 상태를 바꾸지 않고 조용히 끝납니다.
    private var analysisGenerations: [String: Int] = [:]
    /// 페어별 비교 작업. 리스너와 자동 분석이 동시에 비교를 시작하지 않게 합니다.
    private var comparisonTasks: [String: Task<Void, Never>] = [:]
    /// 마지막으로 연 상세 화면의 페어. 늦게 끝난 openPair가 다른 친구 화면을 덮어쓰지 않게 합니다.
    private var openingPairID: String?

    var isWorking: Bool { state == .working }

    var canPreviewInvite: Bool {
        hasValidNickname
            && isValidInviteCode(normalizedInviteID(joinInviteID))
            && !isPreviewingInvite
    }

    var hasValidNickname: Bool {
        (1...12).contains(nickname.trimmingCharacters(in: .whitespacesAndNewlines).count)
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

    func clearOperationError() {
        if case .failed = state { state = .idle }
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
                savedProfileNickname = savedNickname
            }

            let snapshot = try await database
                .collection("pairs")
                .whereField("memberIds", arrayContains: userID)
                .getDocuments()

            friendSummaries = await loadFriendSummaries(
                userID: userID,
                pairs: snapshot.documents
            )

            // 만료됐거나 내가 만들지 않은 대기 초대는 다시 불러오지 않습니다.
            // (예전에는 만료된 옛 코드가 계속 화면에 남아 친구가 입력해도 연결되지 않았습니다.)
            let availablePairs = snapshot.documents.filter { pair in
                let data = pair.data()
                switch data["status"] as? String {
                case "active":
                    return true
                case "waiting":
                    return isValidInviteCode(pair.documentID)
                        && data["creatorId"] as? String == userID
                        && !isExpired(data)
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

            restorePersistedCancellation(pairID: pair.documentID, userID: userID)
            resultLookupCompletedPairIDs.remove(pair.documentID)
            applyPair(documentID: pair.documentID, data: pair.data())
            listenToPair(documentID: pair.documentID)
            _ = await loadStoredResult(pairID: pair.documentID)
        } catch {
            state = .failed(message: userFacingMessage(for: error))
        }
    }

    func openPair(pairID: String, userID: String) async {
        currentUserID = userID
        openingPairID = pairID
        restorePersistedCancellation(pairID: pairID, userID: userID)
        analysisNeedsRestart = isAnalysisCancelled(pairID)
        resultLookupCompletedPairIDs.remove(pairID)
        comparisonResult = nil
        resetAnalysisProgress()
        connectedFriendNickname = friendSummaries.first(where: { $0.id == pairID })?.nickname ?? "친구"
        state = .working
        do {
            let snapshot = try await database.collection("pairs").document(pairID).getDocument()
            // 그 사이 다른 친구 화면을 열었다면 이 결과로 화면 상태를 덮어쓰지 않습니다.
            guard openingPairID == pairID else { return }
            guard let data = snapshot.data() else {
                state = .failed(message: "연결 정보를 찾을 수 없어요.")
                return
            }
            applyPair(documentID: snapshot.documentID, data: data)
            listenToPair(documentID: snapshot.documentID)
            if await loadStoredResult(pairID: snapshot.documentID) { return }
            guard openingPairID == pairID else { return }
            if isFirstMetDateConfirmed {
                analysisMessage = "두 사람의 기록 상태를 확인하고 있어요."
            }
        } catch {
            guard openingPairID == pairID else { return }
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

        do {
            try await saveProfileSilently(userID: userID, nickname: trimmedNickname)
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
        currentUserID = userID
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

        let previousInviteID = isValidInviteCode(inviteID) ? inviteID : nil

        do {
            // 닉네임을 먼저 저장합니다. 닉네임이 바뀌었다면 옛 닉네임이 적힌 초대가 여기서 정리되고,
            // 아래에서 새 닉네임으로 초대를 만듭니다.
            try? await saveProfileSilently(userID: userID, nickname: trimmedNickname)

            let pairID: String
            do {
                pairID = try await createPairDocument(userID: userID, nickname: trimmedNickname)
            } catch {
                guard isPermissionDenied(error), await refreshAuthenticationToken() else { throw error }
                pairID = try await createPairDocument(userID: userID, nickname: trimmedNickname)
            }

            inviteID = pairID
            activePairID = nil
            creatorID = userID
            pairStatus = "친구의 수락을 기다리고 있어요."
            state = .succeeded(message: "새 초대 코드를 만들었어요.")
            listenToPair(documentID: pairID)

            // 예전 초대 정리와 내 멤버 문서 준비는 새 코드 표시를 막지 않도록 뒤에서 처리합니다.
            Task { [weak self] in
                guard let self else { return }
                if let previousInviteID, previousInviteID != pairID {
                    await self.endInviteIfStillWaiting(pairID: previousInviteID, userID: userID)
                }
                try? await self.saveMember(
                    pairID: pairID,
                    userID: userID,
                    nickname: trimmedNickname,
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
        currentUserID = userID
        let pairID = normalizedInviteID(joinInviteID)
        guard isValidInviteCode(pairID) else {
            state = .failed(message: "6자리 초대 코드를 입력해 주세요.")
            return false
        }
        isPreviewingInvite = true
        defer { isPreviewingInvite = false }
        state = .working
        do {
            let snapshot = try await database.collection("pairs").document(pairID)
                .getDocument(source: .server)
            guard let data = snapshot.data() else {
                state = .failed(message: "없는 초대 코드예요. 코드를 다시 확인해 주세요.")
                return false
            }
            if isExpired(data) {
                state = .failed(message: "만료된 초대 코드예요. 새 코드를 받아 주세요.")
                return false
            }
            guard data["status"] as? String == "waiting",
                  let creator = data["creatorId"] as? String,
                  creator != userID else {
                state = .failed(message: creatorErrorMessage(data: data, userID: userID))
                return false
            }
            guard try await !hasExistingActivePair(userID: userID, friendID: creator) else {
                state = .failed(message: "이미 연결된 친구예요. 기존 친구 목록에서 결과를 확인해 주세요.")
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
        currentUserID = userID
        let pairID = normalizedInviteID(joinInviteID)
        guard isValidInviteCode(pairID) else {
            state = .failed(message: "6자리 초대 코드를 입력해 주세요.")
            return false
        }
        isAcceptingInvite = true
        defer { isAcceptingInvite = false }
        state = .working

        let pairReference = database.collection("pairs").document(pairID)

        do {
            let inviteSnapshot = try await pairReference.getDocument(source: .server)
            guard let inviteData = inviteSnapshot.data(),
                  let inviteCreatorID = inviteData["creatorId"] as? String else {
                state = .failed(message: "없는 초대 코드예요. 코드를 다시 확인해 주세요.")
                return false
            }
            guard try await !hasExistingActivePair(userID: userID, friendID: inviteCreatorID) else {
                state = .failed(message: "이미 연결된 친구예요. 같은 친구와 다시 연결할 수 없어요.")
                return false
            }

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

                    guard let creatorID = data["creatorId"] as? String else {
                        errorPointer?.pointee = NSError(
                            domain: "PairingStore",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "유효한 대기 중 초대가 아니에요."]
                        )
                        return nil
                    }

                    // 두 사람마다 하나뿐인 잠금 문서로 활성 연결이 둘 생기지 않게 합니다.
                    // 같은 잠금 문서를 동시에 쓰는 트랜잭션은 하나만 성공하고, 나머지는 다시 시도하며
                    // 여기서 기존 연결을 발견해 거절됩니다.
                    let linkReference = self.pairLinkReference(userID, creatorID)
                    let linkSnapshot = try transaction.getDocument(linkReference)
                    if let linkedPairID = linkSnapshot.data()?["pairId"] as? String,
                       linkedPairID != pairID {
                        let linkedPair = try transaction.getDocument(
                            self.database.collection("pairs").document(linkedPairID)
                        )
                        if linkedPair.data()?["status"] as? String == "active" {
                            errorPointer?.pointee = NSError(
                                domain: "PairingStore",
                                code: 3,
                                userInfo: [NSLocalizedDescriptionKey: "이미 연결된 친구예요. 같은 친구와 다시 연결할 수 없어요."]
                            )
                            return nil
                        }
                    }

                    transaction.updateData([
                        "memberIds": FieldValue.arrayUnion([userID]),
                        "status": "active",
                        "updatedAt": FieldValue.serverTimestamp()
                    ], forDocument: pairReference)
                    transaction.setData(
                        self.pairLinkData(pairID: pairID, userID, creatorID),
                        forDocument: linkReference
                    )

                    return creatorID
                } catch {
                    errorPointer?.pointee = error as NSError
                    return nil
                }
            }

            joinInviteID = ""
            activePairID = pairID
            self.creatorID = creatorID as? String
            connectedFriendNickname = inviteCreatorNickname
            savedFirstMetDate = nil
            firstMetStatus = nil
            firstMetProposedBy = nil
            comparisonResult = nil
            pairStatus = "친구와 연결됐어요."
            state = .succeeded(message: "친구와 연결됐어요.")
            listenToPair(documentID: pairID)
            let myNickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
            Task { [weak self] in
                guard let self else { return }
                try? await self.saveMember(
                    pairID: pairID,
                    userID: userID,
                    nickname: myNickname,
                    analysisStatus: "notStarted",
                    recordCount: 0
                )
                try? await self.saveProfileSilently(userID: userID, nickname: myNickname)
                await self.reloadFriendSummaries(userID: userID)
            }
            return true
        } catch {
            state = .failed(message: inviteAcceptanceMessage(for: error))
            return false
        }
    }

    /// 기준일을 제안합니다. 어느 연결에 대한 제안인지 pairID로 직접 받아서,
    /// 다른 화면의 상태 때문에 엉뚱한 연결을 보거나 실패하지 않게 합니다.
    @discardableResult
    func proposeFirstMetDate(pairID: String, userID: String) async -> Bool {
        currentUserID = userID
        let normalizedDate = Calendar.current.startOfDay(for: firstMetDate)
        guard normalizedDate <= Calendar.current.startOfDay(for: Date()) else {
            state = .failed(message: "처음 알게 된 날은 오늘 이후로 정할 수 없어요.")
            return false
        }
        state = .working
        // 기준일이 바뀌면 이전 기준일로 진행 중이던 비교와 저장 결과는 더 이상 유효하지 않습니다.
        beginAnalysisGeneration(pairID: pairID)

        do {
            let pairReference = database.collection("pairs").document(pairID)
            let batch = database.batch()
            batch.updateData([
                "firstMetAt": Timestamp(date: normalizedDate),
                "firstMetStatus": "pending",
                "firstMetProposedBy": userID,
                "firstMetConfirmedBy": [userID],
                "updatedAt": FieldValue.serverTimestamp()
            ], forDocument: pairReference)
            // 새 기준일에 예전 결과가 다시 열리지 않도록 기준일 제안과 함께 원자적으로 지웁니다.
            batch.deleteDocument(pairReference.collection("results").document("current"))
            try await batch.commit()

            activePairID = pairID
            firstMetDate = normalizedDate
            savedFirstMetDate = normalizedDate
            firstMetStatus = "pending"
            firstMetProposedBy = userID
            uploadedRecordCount = 0
            comparisonResult = nil
            resultCache[pairID] = nil
            analysisProgress = 0
            state = .succeeded(message: "기준일을 제안했어요. 친구의 확인을 기다리고 있어요.")
            return true
        } catch {
            state = .failed(message: userFacingMessage(for: error))
            return false
        }
    }

    @discardableResult
    func confirmFirstMetDate(pairID: String, userID: String) async -> Bool {
        currentUserID = userID
        guard savedFirstMetDate != nil, firstMetStatus == "pending" else {
            state = .failed(message: "확인할 기준일이 없어요.")
            return false
        }

        state = .working
        analysisProgress = max(analysisProgress, 0.08)
        do {
            try await database.collection("pairs").document(pairID).updateData([
                "firstMetStatus": "confirmed",
                "firstMetConfirmedBy": FieldValue.arrayUnion([userID]),
                "updatedAt": FieldValue.serverTimestamp()
            ])
            activePairID = pairID
            firstMetStatus = "confirmed"
            state = .succeeded(message: "두 사람이 기준일을 확인했어요. 기록을 자동으로 준비할게요.")
            return true
        } catch {
            state = .failed(message: userFacingMessage(for: error))
            return false
        }
    }

    @discardableResult
    func prepareVisits(userID: String, events: [VisitEvent]) async -> Bool {
        guard let pairID = currentPairID else {
            state = .failed(message: "먼저 친구 초대를 만들거나 수락해 주세요.")
            return false
        }

        guard !isAnalysisCancelled(pairID) else { return false }

        guard let cutoffDate = savedFirstMetDate, isFirstMetDateConfirmed else {
            state = .failed(message: "친구와 기준일을 먼저 확인해 주세요.")
            return false
        }

        // 같은 페어의 이전 준비 작업은 이 시점부터 낡은 작업이 되어 상태를 바꾸지 않습니다.
        let generation = beginAnalysisGeneration(pairID: pairID)
        let records = SharedVisitRecordBuilder.build(
            from: events.filter { $0.capturedAt < cutoffDate }
        )
        state = .working
        analysisProgress = max(analysisProgress, 0.18)
        isWaitingForRecords = true
        analysisMessage = "두 사람의 사진 기록을 준비하고 있어요."

        do {
            try await saveMember(
                pairID: pairID,
                userID: userID,
                nickname: nickname,
                analysisStatus: "analyzing",
                recordCount: records.count
            )
            guard await continueAnalysis(pairID: pairID, userID: userID, generation: generation) else { return false }

            try await replaceVisits(
                pairID: pairID,
                userID: userID,
                records: records,
                generation: generation
            )
            guard await continueAnalysis(pairID: pairID, userID: userID, generation: generation) else { return false }
            if isDisplaying(pairID) {
                analysisProgress = max(analysisProgress, 0.48)
            }

            try await saveMember(
                pairID: pairID,
                userID: userID,
                nickname: nickname,
                analysisStatus: "ready",
                recordCount: records.count
            )
            guard await continueAnalysis(pairID: pairID, userID: userID, generation: generation) else { return false }

            guard isDisplaying(pairID) else { return false }
            uploadedRecordCount = records.count
            analysisProgress = max(analysisProgress, 0.68)
            analysisMessage = "두 사람의 사진 기록을 준비하고 있어요."
            state = .succeeded(message: "분석 준비가 완료됐어요. 흐린 방문 기록 \(records.count)개를 준비했어요.")
            return true
        } catch is CancellationError {
            // 더 새로운 실행이 있으면 그 실행이 멤버 상태를 관리하므로 건드리지 않습니다.
            if isCurrentGeneration(generation, pairID: pairID) {
                await markMemberAnalysisCancelled(pairID: pairID, userID: userID)
            }
            return false
        } catch {
            guard isCurrentGeneration(generation, pairID: pairID), isDisplaying(pairID) else { return false }
            state = .failed(message: userFacingMessage(for: error))
            return false
        }
    }

    func startAnalysis(userID: String) async {
        guard isFirstMetDateConfirmed else {
            state = .failed(message: "친구와 기준일을 먼저 확인해 주세요.")
            return
        }
        guard let pairID = currentPairID,
              !isAnalysisCancelled(pairID),
              resultCache[pairID] == nil else { return }
        analysisProgress = max(analysisProgress, 0.72)
        analysisMessage = "두 사람의 기록 상태를 확인하고 있어요."
        await compareWithFriend(pairID: pairID, userID: userID)
    }

    /// 페어마다 비교 작업을 하나만 실행합니다. 이미 실행 중이면 그 작업이 끝나기를 기다립니다.
    private func compareWithFriend(pairID: String, userID: String) async {
        if let running = comparisonTasks[pairID] {
            await running.value
            return
        }

        let task = Task<Void, Never> { [weak self] in
            await self?.performComparison(pairID: pairID, userID: userID)
        }
        comparisonTasks[pairID] = task
        await task.value
        if comparisonTasks[pairID] == task {
            comparisonTasks[pairID] = nil
        }
    }

    private func performComparison(pairID: String, userID: String) async {
        let generation = analysisGenerations[pairID, default: 0]
        guard isCurrentRun(generation, pairID: pairID),
              resultCache[pairID] == nil else { return }

        if isDisplaying(pairID) {
            state = .working
            isWaitingForRecords = false
            analysisMessage = "두 사람의 기록 상태를 확인하고 있어요."
        }

        do {
            let pairSnapshot = try await database
                .collection("pairs")
                .document(pairID)
                .getDocument()
            guard isCurrentRun(generation, pairID: pairID) else { return }

            guard let data = pairSnapshot.data(),
                  data["status"] as? String == "active",
                  let memberIDs = data["memberIds"] as? [String],
                  let friendID = memberIDs.first(where: { $0 != userID }) else {
                if isDisplaying(pairID) {
                    pairStatus = "친구의 수락을 기다리고 있어요."
                    state = .succeeded(message: "아직 친구가 초대를 수락하지 않았어요.")
                }
                return
            }

            guard let firstMetTimestamp = data["firstMetAt"] as? Timestamp,
                  (data["firstMetStatus"] as? String == "confirmed"
                    || data["firstMetStatus"] == nil) else {
                if isDisplaying(pairID) {
                    savedFirstMetDate = nil
                    state = .failed(message: "친구와 기준일을 먼저 확인해 주세요.")
                }
                return
            }
            let cutoffDate = firstMetTimestamp.dateValue()
            if isDisplaying(pairID) {
                pairStatus = "친구와 연결됐어요."
                firstMetDate = cutoffDate
                savedFirstMetDate = cutoffDate
            }

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
            guard isCurrentRun(generation, pairID: pairID) else { return }

            guard memberIsReady(
                ownMemberSnapshot.data()
            ) else {
                if isDisplaying(pairID) {
                    isWaitingForRecords = true
                    analysisMessage = "내 사진 기록을 준비하고 있어요."
                    state = .succeeded(message: "내 기록을 자동으로 준비하고 있어요. 잠시 후 다시 시도해 주세요.")
                }
                return
            }

            guard memberIsReady(
                friendMemberSnapshot.data()
            ) else {
                if isDisplaying(pairID) {
                    isWaitingForRecords = true
                    analysisMessage = "\(connectedFriendNickname)님의 기록 준비를 기다리고 있어요."
                    state = .succeeded(message: "친구의 기록 준비가 아직 끝나지 않았어요.")
                }
                return
            }

            if isDisplaying(pairID) {
                isWaitingForRecords = false
                analysisProgress = max(analysisProgress, 0.82)
                analysisMessage = "두 사람의 시간과 위치 기록을 비교하고 있어요."
            }
            async let ownSnapshot = visitsCollection(pairID: pairID, userID: userID)
                .getDocuments()
            async let friendSnapshot = visitsCollection(pairID: pairID, userID: friendID)
                .getDocuments()
            let (ownDocuments, friendDocuments) = try await (ownSnapshot, friendSnapshot)
            guard isCurrentRun(generation, pairID: pairID) else { return }
            if isDisplaying(pairID) {
                analysisProgress = max(analysisProgress, 0.9)
            }

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
            guard isCurrentRun(generation, pairID: pairID) else { return }

            try await saveComparisonResult(
                result,
                pairID: pairID,
                userID: userID,
                ownRecords: ownRecords
            )
            // 저장 도중 취소됐다면 이 기기 화면에는 결과를 반영하지 않습니다.
            // 서버에 남은 결과는 다음에 상세 화면을 열 때 저장 결과로 불러옵니다.
            guard isCurrentRun(generation, pairID: pairID) else { return }

            resultCache[pairID] = result
            clearLocalAnalysisCancellation(pairID: pairID)
            updateFriendSummary(pairID: pairID, result: result, firstMetDate: cutoffDate)
            completedAnalysisCount += 1

            guard isDisplaying(pairID) else { return }
            comparisonResult = result
            analysisProgress = 1
            analysisMessage = "분석이 완료됐어요."
            state = .succeeded(
                message: intersections.isEmpty
                    ? "겹치는 기록을 찾지 못했어요."
                    : "두 사람의 흐린 기록 비교를 완료했어요."
            )
        } catch {
            guard isCurrentRun(generation, pairID: pairID), isDisplaying(pairID) else { return }
            state = .failed(message: userFacingMessage(for: error))
        }
    }

    func cancelAnalysis(pairID: String, userID: String) async {
        beginAnalysisGeneration(pairID: pairID)
        cancelledAnalysisPairIDs.insert(pairID)
        setAnalysisCancelledLocally(true, pairID: pairID, userID: userID)
        analysisNeedsRestart = true
        analysisRestartMessage = "이 기기에서 사진 기록 준비를 다시 시작해 주세요."
        analysisProgress = 0
        isWaitingForRecords = false
        analysisMessage = "분석을 취소했어요."
        state = .succeeded(message: "분석을 취소했어요.")
        await markMemberAnalysisCancelled(pairID: pairID, userID: userID)
    }

    func restartAnalysis(pairID: String) {
        beginAnalysisGeneration(pairID: pairID)
        cancelledAnalysisPairIDs.remove(pairID)
        clearLocalAnalysisCancellation(pairID: pairID)
        analysisNeedsRestart = false
        analysisProgress = 0.08
        isWaitingForRecords = false
        analysisMessage = "사진에 남은 시간과 위치 정보를 다시 확인하고 있어요."
        state = .working
        analysisRunRevision += 1
    }

    /// 사진을 읽을 수 없어 기록 준비를 시작하지 못할 때 다시 시작 화면으로 돌려보냅니다.
    func reportAnalysisUnavailable(pairID: String, message: String) {
        guard isDisplaying(pairID), comparisonResult == nil else { return }
        analysisNeedsRestart = true
        analysisRestartMessage = message
        analysisProgress = 0
        isWaitingForRecords = false
        state = .idle
    }

    /// 저장된 결과 조회가 끝났고, 결과도 취소 기록도 없어서 자동 분석을 시작해도 되는지 알려 줍니다.
    func canStartAutomaticAnalysis(pairID: String) -> Bool {
        resultLookupCompletedPairIDs.contains(pairID)
            && resultCache[pairID] == nil
            && !isAnalysisCancelled(pairID)
    }

    private func continueAnalysis(pairID: String, userID: String, generation: Int) async -> Bool {
        // 취소·재시작으로 세대가 바뀌었으면 새 실행이 멤버 상태를 관리합니다.
        guard isCurrentGeneration(generation, pairID: pairID) else { return false }
        guard !isAnalysisCancelled(pairID), !Task.isCancelled else {
            await markMemberAnalysisCancelled(pairID: pairID, userID: userID)
            return false
        }
        return true
    }

    private func markMemberAnalysisCancelled(pairID: String, userID: String) async {
        try? await saveMember(
            pairID: pairID,
            userID: userID,
            nickname: nickname,
            analysisStatus: "notStarted",
            recordCount: 0
        )
    }

    /// 방문 기록 ID는 내용의 해시라서, 바뀐 문서만 지우고 새 문서만 올립니다.
    private func replaceVisits(
        pairID: String,
        userID: String,
        records: [SharedVisitRecord],
        generation: Int
    ) async throws {
        let collection = visitsCollection(pairID: pairID, userID: userID)
        let existing = try await collection.getDocuments()

        let newIDs = Set(records.map(\.id))
        let reusableIDs = Set(
            existing.documents
                .filter { integer(from: $0.data()["schemaVersion"]) == Self.recordSchemaVersion }
                .map(\.documentID)
        )
        let staleDocuments = existing.documents.filter { !newIDs.contains($0.documentID) }
        let missingRecords = records.filter { !reusableIDs.contains($0.id) }

        for chunk in staleDocuments.chunked(maximumCount: 400) {
            guard isCurrentRun(generation, pairID: pairID), !Task.isCancelled else {
                throw CancellationError()
            }
            let batch = database.batch()
            chunk.forEach { batch.deleteDocument($0.reference) }
            try await batch.commit()
        }

        for chunk in missingRecords.chunked(maximumCount: 400) {
            guard isCurrentRun(generation, pairID: pairID), !Task.isCancelled else {
                throw CancellationError()
            }
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
            "schemaVersion": Self.resultSchemaVersion
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
        defer { resultLookupCompletedPairIDs.insert(pairID) }

        if let cached = resultCache[pairID] {
            guard isDisplaying(pairID) else { return true }
            comparisonResult = cached
            clearLocalAnalysisCancellation(pairID: pairID)
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
                  integer(from: data["schemaVersion"]) == Self.resultSchemaVersion,
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
            clearLocalAnalysisCancellation(pairID: pairID)
            // 조회하는 동안 다른 친구 화면으로 옮겼다면 캐시에만 넣어 둡니다.
            guard isDisplaying(pairID) else { return true }
            comparisonResult = result
            analysisProgress = 1
            isWaitingForRecords = false
            analysisMessage = "분석이 완료됐어요."
            state = .succeeded(message: "저장된 분석 결과를 열었어요.")
            return true
        } catch {
            if isDisplaying(pairID) {
                state = .failed(message: userFacingMessage(for: error))
            }
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

    private func saveProfileSilently(userID: String, nickname: String) async throws {
        let reference = database.collection("users").document(userID)
        let snapshot = try await reference.getDocument()
        var data: [String: Any] = [
            "nickname": nickname,
            "updatedAt": FieldValue.serverTimestamp()
        ]
        if !snapshot.exists {
            data["createdAt"] = FieldValue.serverTimestamp()
        }
        try await reference.setData(data, merge: true)

        let previousNickname = savedProfileNickname ?? snapshot.data()?["nickname"] as? String
        savedProfileNickname = nickname
        if let previousNickname, previousNickname != nickname {
            await propagateNicknameChange(userID: userID, nickname: nickname)
        }
    }

    /// 닉네임을 바꾸면 친구에게 보이는 곳(각 연결의 members 문서)도 같이 바꿉니다.
    /// 옛 닉네임이 적힌 대기 중 초대는 닫아서, 다음 초대에는 새 닉네임이 들어가게 합니다.
    private func propagateNicknameChange(userID: String, nickname: String) async {
        guard let pairs = try? await database
            .collection("pairs")
            .whereField("memberIds", arrayContains: userID)
            .getDocuments() else { return }

        for pair in pairs.documents {
            let data = pair.data()
            switch data["status"] as? String {
            case "active":
                try? await pair.reference.collection("members").document(userID).updateData([
                    "nickname": nickname,
                    "updatedAt": FieldValue.serverTimestamp()
                ])
            case "waiting" where data["creatorId"] as? String == userID:
                await endInviteIfStillWaiting(pairID: pair.documentID, userID: userID)
            default:
                continue
            }
        }
    }

    /// 홈의 친구 목록을 서버에서 다시 불러옵니다.
    func reloadFriendSummaries(userID: String) async {
        guard let snapshot = try? await database
            .collection("pairs")
            .whereField("memberIds", arrayContains: userID)
            .getDocuments() else { return }
        friendSummaries = await loadFriendSummaries(userID: userID, pairs: snapshot.documents)
    }

    private func loadFriendSummaries(
        userID: String,
        pairs: [QueryDocumentSnapshot]
    ) async -> [FriendConnectionSummary] {
        // 친구마다 멤버·결과 문서를 순서대로 기다리지 않고 한꺼번에 조회합니다.
        let summaries = await withTaskGroup(of: FriendConnectionSummary?.self) { group in
            for pair in pairs {
                group.addTask { [weak self] in
                    await self?.loadFriendSummary(pair: pair, userID: userID)
                }
            }
            var loaded: [FriendConnectionSummary] = []
            for await summary in group {
                if let summary { loaded.append(summary) }
            }
            return loaded
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

    private func loadFriendSummary(
        pair: QueryDocumentSnapshot,
        userID: String
    ) async -> FriendConnectionSummary? {
        let data = pair.data()
        guard data["status"] as? String == "active",
              let memberIDs = data["memberIds"] as? [String],
              let friendID = memberIDs.first(where: { $0 != userID }) else {
            return nil
        }

        do {
            async let member = database.collection("pairs").document(pair.documentID)
                .collection("members").document(friendID).getDocument()
            async let result = database.collection("pairs").document(pair.documentID)
                .collection("results").document("current").getDocument()
            let (memberSnapshot, resultSnapshot) = try await (member, result)
            let memberData = memberSnapshot.data()
            let resultData = resultSnapshot.data()
            let hasStoredResult = integer(from: resultData?["schemaVersion"]) == Self.resultSchemaVersion
            let rawStrength = hasStoredResult ? integer(from: resultData?["closestLevel"]) : nil

            // 목록 표시를 늦추지 않도록 잠금 문서 확인은 뒤에서 처리합니다.
            let pairID = pair.documentID
            Task { [weak self] in
                await self?.ensurePairLink(pairID: pairID, userID: userID, friendID: friendID)
            }

            return FriendConnectionSummary(
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
        } catch {
            return nil
        }
    }

    /// 두 사용자 사이의 잠금 문서. 문서 ID는 두 uid를 정렬해 이어 붙여 누가 만들어도 같습니다.
    nonisolated private func pairLinkReference(_ firstUserID: String, _ secondUserID: String) -> DocumentReference {
        let sorted = [firstUserID, secondUserID].sorted()
        return Firestore.firestore().collection("pairLinks").document("\(sorted[0])_\(sorted[1])")
    }

    nonisolated private func pairLinkData(
        pairID: String,
        _ firstUserID: String,
        _ secondUserID: String
    ) -> [String: Any] {
        [
            "memberIds": [firstUserID, secondUserID].sorted(),
            "pairId": pairID,
            "updatedAt": FieldValue.serverTimestamp()
        ]
    }

    /// 잠금 문서가 생기기 전에 만들어진 활성 연결에 잠금 문서를 채워 넣습니다.
    /// 이미 다른 활성 연결을 가리키고 있으면 규칙에서 거절되며, 그대로 둡니다.
    private func ensurePairLink(pairID: String, userID: String, friendID: String) async {
        let reference = pairLinkReference(userID, friendID)
        guard let snapshot = try? await reference.getDocument(),
              snapshot.data()?["pairId"] as? String != pairID else { return }
        try? await reference.setData(pairLinkData(pairID: pairID, userID, friendID))
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
        let status = data["status"] as? String
        let previousFirstMetDate = savedFirstMetDate
        let previousFirstMetStatus = firstMetStatus

        // 친구 초대를 수락한 직후에는 캐시에 남은 '대기 중' 스냅샷이 먼저 도착할 수 있습니다.
        // 내가 만든 초대가 아니면 이 스냅샷은 무시해야, 친구의 코드가 내 초대 코드로 바뀌거나
        // 방금 연결한 상태가 풀리지 않습니다.
        if status == "waiting", data["creatorId"] as? String != currentUserID { return }

        creatorID = data["creatorId"] as? String

        switch status {
        case "active":
            let isNewConnection = activePairID != documentID
            activePairID = documentID
            inviteID = ""
            joinInviteID = ""
            pairStatus = "친구와 연결됐어요."
            if isNewConnection {
                connectedFriendNickname = friendSummaries.first(where: { $0.id == documentID })?.nickname ?? "친구"
            }
            if let userID = currentUserID {
                listenToMemberReadiness(pairID: documentID, userID: userID)
                Task {
                    await refreshConnectedFriendNickname(pairID: documentID, userID: userID)
                    // 내가 만든 초대를 친구가 수락한 경우, 홈 목록에 새 친구가 바로 보이게 합니다.
                    if !friendSummaries.contains(where: { $0.id == documentID }) {
                        await reloadFriendSummaries(userID: userID)
                    }
                }
            }
        case "waiting":
            activePairID = nil
            inviteID = isValidInviteCode(documentID) && !isExpired(data) ? documentID : ""
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
            let nextFirstMetStatus = data["firstMetStatus"] as? String ?? "confirmed"
            let dateChanged = previousFirstMetDate.map { $0 != date } ?? false
            let returnedToPending = previousFirstMetStatus == "confirmed"
                && nextFirstMetStatus == "pending"
            if dateChanged || returnedToPending {
                // 다른 기기에서 기준일을 수정해도 이전 기준일로 돌던 비교가 결과를 저장하지 않게 합니다.
                beginAnalysisGeneration(pairID: documentID)
                resultCache[documentID] = nil
                if isDisplaying(documentID) {
                    comparisonResult = nil
                    resetAnalysisProgress()
                }
            }
            firstMetDate = date
            savedFirstMetDate = date
            firstMetStatus = nextFirstMetStatus
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
                .collection("members").document(friendID).getDocument(source: .server)
            guard let latestNickname = member.data()?["nickname"] as? String else { return }
            applyFriendNickname(latestNickname, pairID: pairID)
        } catch {
            // The connection remains usable even if the display name cannot be refreshed yet.
        }
    }

    private func applyFriendNickname(_ latestNickname: String, pairID: String) {
        if activePairID == pairID { connectedFriendNickname = latestNickname }
        guard let index = friendSummaries.firstIndex(where: { $0.id == pairID }),
              friendSummaries[index].nickname != latestNickname else { return }
        let previous = friendSummaries[index]
        friendSummaries[index] = FriendConnectionSummary(
            id: previous.id,
            nickname: latestNickname,
            score: previous.score,
            intersectionDayCount: previous.intersectionDayCount,
            closestStrength: previous.closestStrength,
            firstMetDate: previous.firstMetDate,
            firstMetStatus: previous.firstMetStatus,
            hasStoredResult: previous.hasStoredResult,
            isReady: previous.isReady
        )
    }

    private func listenToPair(documentID: String) {
        pairListener?.remove()
        pairListener = database.collection("pairs").document(documentID)
            .addSnapshotListener { [weak self] snapshot, error in
                guard error == nil, let data = snapshot?.data() else { return }
                Task { @MainActor [weak self] in
                    guard let self,
                          self.activePairID == documentID
                            || self.inviteID == documentID
                            || self.openingPairID == documentID else { return }
                    self.applyPair(documentID: documentID, data: data)
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
                    guard let self else { return }

                    self.updateAnalysisProgressFromMembers(
                        documents.map { $0.data() },
                        pairID: pairID
                    )

                    // 멤버 문서에는 상대방에게 보여 줄 최신 닉네임도 들어 있습니다.
                    // 서버를 다시 읽지 않고 받은 스냅숏에서 바로 반영합니다.
                    if let friendNickname = documents
                        .first(where: { $0.documentID != userID })?
                        .data()["nickname"] as? String {
                        self.applyFriendNickname(friendNickname, pairID: pairID)
                    }

                    // 판단과 시작 사이에 await가 없어야 다른 스냅숏과 겹쳐 실행되지 않습니다.
                    guard self.activePairID == pairID,
                          self.canStartAutomaticAnalysis(pairID: pairID),
                          documents.allSatisfy({ self.memberIsReady($0.data()) }),
                          self.isFirstMetDateConfirmed,
                          self.comparisonResult == nil else { return }
                    await self.compareWithFriend(pairID: pairID, userID: userID)
                }
            }
    }

    private func updateAnalysisProgressFromMembers(
        _ members: [[String: Any]],
        pairID: String
    ) {
        guard activePairID == pairID,
              comparisonResult == nil,
              !isAnalysisCancelled(pairID) else { return }

        let statuses = members.compactMap { $0["analysisStatus"] as? String }
        let readyCount = members.filter(memberIsReady).count

        if readyCount == 2 {
            analysisProgress = max(analysisProgress, 0.76)
            isWaitingForRecords = false
            analysisMessage = "두 사람의 기록 비교를 준비하고 있어요."
        } else if readyCount == 1 {
            // 상대가 취소해 준비 완료 인원이 줄면 진행률도 함께 낮춥니다.
            analysisProgress = min(max(analysisProgress, 0.58), 0.7)
            isWaitingForRecords = true
            analysisMessage = "한 사람의 기록 준비가 끝났어요. 나머지 기록을 기다리고 있어요."
        } else if statuses.contains("analyzing") {
            analysisProgress = min(max(analysisProgress, 0.25), 0.7)
            isWaitingForRecords = false
            analysisMessage = "두 사람의 사진 기록을 준비하고 있어요."
        }
    }

    private func hasExistingActivePair(userID: String, friendID: String) async throws -> Bool {
        let snapshot = try await database.collection("pairs")
            .whereField("memberIds", arrayContains: userID)
            .getDocuments(source: .server)

        return snapshot.documents.contains { document in
            let data = document.data()
            guard data["status"] as? String == "active",
                  let memberIDs = data["memberIds"] as? [String] else { return false }
            return memberIDs.contains(friendID)
        }
    }

    private func cancellationDefaultsKey(userID: String) -> String {
        "cancelledAnalysisPairIDs.\(userID)"
    }

    private func isAnalysisCancelledLocally(pairID: String, userID: String) -> Bool {
        let stored = UserDefaults.standard.stringArray(
            forKey: cancellationDefaultsKey(userID: userID)
        ) ?? []
        return stored.contains(pairID)
    }

    private func setAnalysisCancelledLocally(
        _ cancelled: Bool,
        pairID: String,
        userID: String
    ) {
        let key = cancellationDefaultsKey(userID: userID)
        var stored = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        if cancelled { stored.insert(pairID) } else { stored.remove(pairID) }
        UserDefaults.standard.set(Array(stored), forKey: key)
    }

    private func clearLocalAnalysisCancellation(pairID: String) {
        cancelledAnalysisPairIDs.remove(pairID)
        if let userID = currentUserID {
            setAnalysisCancelledLocally(false, pairID: pairID, userID: userID)
        }
        if isDisplaying(pairID) { analysisNeedsRestart = false }
    }

    /// 앱을 다시 실행해도 취소 상태가 유지되도록 저장된 값을 메모리로 불러옵니다.
    private func restorePersistedCancellation(pairID: String, userID: String) {
        if isAnalysisCancelledLocally(pairID: pairID, userID: userID) {
            cancelledAnalysisPairIDs.insert(pairID)
        }
    }

    private func isAnalysisCancelled(_ pairID: String) -> Bool {
        if cancelledAnalysisPairIDs.contains(pairID) { return true }
        guard let userID = currentUserID else { return false }
        return isAnalysisCancelledLocally(pairID: pairID, userID: userID)
    }

    private func isDisplaying(_ pairID: String) -> Bool {
        activePairID == pairID
    }

    @discardableResult
    private func beginAnalysisGeneration(pairID: String) -> Int {
        // 새 준비·취소·재시작은 이전 비교 작업을 대체합니다. 이전 작업을 맵에 남겨 두면
        // 재시작 직후 들어온 비교 요청이 그 작업을 기다린 뒤 그대로 종료되어,
        // 두 사람의 기록이 준비됐는데도 다음 스냅숏이 올 때까지 멈출 수 있습니다.
        comparisonTasks[pairID]?.cancel()
        comparisonTasks[pairID] = nil
        let next = analysisGenerations[pairID, default: 0] + 1
        analysisGenerations[pairID] = next
        return next
    }

    private func isCurrentGeneration(_ generation: Int, pairID: String) -> Bool {
        analysisGenerations[pairID, default: 0] == generation
    }

    private func isCurrentRun(_ generation: Int, pairID: String) -> Bool {
        isCurrentGeneration(generation, pairID: pairID) && !isAnalysisCancelled(pairID)
    }

    private func resetAnalysisProgress() {
        analysisProgress = 0
        isWaitingForRecords = false
        analysisMessage = "사진에 남은 시간과 위치 정보를 확인하고 있어요."
    }

    func isValidInviteCodeFormat(_ value: String) -> Bool {
        isValidInviteCode(normalizedInviteID(value))
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
            do {
                let snapshot = try await database.collection("pairs").document(candidate)
                    .getDocument(source: .server)
                if !snapshot.exists { return candidate }
            } catch let error where isPermissionDenied(error) {
                // 규칙상 읽을 수 없는 문서는 이미 쓰이는 코드입니다. 다른 코드로 다시 시도합니다.
                continue
            }
        }
        throw NSError(
            domain: "InviteCode",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "새 초대 코드를 만들지 못했어요. 잠시 후 다시 시도해 주세요."]
        )
    }

    private func createPairDocument(userID: String, nickname: String) async throws -> String {
        let pairID = try await makeUniqueInviteCode()
        try await database.collection("pairs").document(pairID).setData([
            "creatorId": userID,
            "creatorNickname": nickname,
            "memberIds": [userID],
            "status": "waiting",
            "expiresAt": Timestamp(date: Date().addingTimeInterval(24 * 60 * 60)),
            "createdAt": FieldValue.serverTimestamp(),
            "updatedAt": FieldValue.serverTimestamp()
        ])
        return pairID
    }

    /// 새 코드를 만든 뒤 예전 코드를 닫습니다. 상태 확인과 종료를 한 트랜잭션으로 묶어,
    /// 그사이 친구가 예전 코드를 수락했다면 활성 연결을 건드리지 않습니다.
    private func endInviteIfStillWaiting(pairID: String, userID: String) async {
        let reference = database.collection("pairs").document(pairID)
        let result = try? await database.runTransaction { transaction, errorPointer -> Any? in
            do {
                let snapshot = try transaction.getDocument(reference)
                guard let data = snapshot.data(),
                      data["status"] as? String == "waiting",
                      data["creatorId"] as? String == userID else {
                    return false
                }

                transaction.updateData([
                    "status": "ended",
                    "updatedAt": FieldValue.serverTimestamp()
                ], forDocument: reference)
                return true
            } catch {
                errorPointer?.pointee = error as NSError
                return nil
            }
        }

        if result as? Bool == true, inviteID == pairID {
            inviteID = ""
        }
    }

    private func isExpired(_ data: [String: Any]) -> Bool {
        guard let expiresAt = data["expiresAt"] as? Timestamp else { return false }
        return expiresAt.dateValue() < Date()
    }

    private func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == FirestoreErrorDomain
            && nsError.code == FirestoreErrorCode.permissionDenied.rawValue
    }

    private func refreshAuthenticationToken() async -> Bool {
        guard let user = Auth.auth().currentUser else { return false }
        do {
            _ = try await user.getIDTokenResult(forcingRefresh: true)
            return true
        } catch {
            return false
        }
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
