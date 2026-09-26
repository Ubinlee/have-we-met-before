import Photos
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var analyzer = PhotoLibraryAnalyzer()
    @StateObject private var pairing = PairingStore()
    @EnvironmentObject private var firebaseSession: FirebaseSession
    @Environment(\.openURL) private var openURL
    @State private var showDateConfirmationAlert = false
    @State private var showLatestResult = false
    @State private var waitingForAnalysisResult = false
    @State private var lastAutoPreparedKey = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    friendRanking
                    accountCard
                    content
                }
                .frame(maxWidth: .infinity)
                .padding(24)
            }
            .navigationTitle("지나간 기록")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                if analyzer.canReadPhotos, analyzer.scanState == .idle {
                    await analyzer.scan()
                }
            }
            .navigationDestination(isPresented: $showLatestResult) {
                if let result = pairing.comparisonResult {
                    ResultView(
                        result: result,
                        firstMetDate: pairing.savedFirstMetDate ?? pairing.firstMetDate
                    )
                }
            }
            .alert("기준일 확인이 필요해요", isPresented: $showDateConfirmationAlert) {
                Button("확인하러 가기", role: .cancel) {}
            } message: {
                Text("친구가 처음 알게 된 날을 제안했어요. 날짜를 확인하거나 수정해 주세요.")
            }
            .onChange(of: pairing.comparisonResult?.score) { _, newValue in
                guard waitingForAnalysisResult, newValue != nil else { return }
                waitingForAnalysisResult = false
                showLatestResult = true
            }
        }
        .tint(Color(red: 0.45, green: 0.36, blue: 0.78))
    }

    @ViewBuilder
    private var friendRanking: some View {
        if case .authenticated(let userID) = firebaseSession.state {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("나의 친구 순위")
                            .font(.title2.bold())
                        Text("카드를 누르면 상세 결과를 볼 수 있어요.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "person.2.fill")
                        .foregroundStyle(.tint)
                }

                if pairing.friendSummaries.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.largeTitle)
                            .foregroundStyle(.tint)
                        Text("아직 연결된 친구가 없어요")
                            .font(.headline)
                        Text("아래에서 초대를 만들거나 받은 초대를 수락해 보세요.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                } else {
                    ForEach(Array(pairing.friendSummaries.enumerated()), id: \.element.id) { index, friend in
                        NavigationLink {
                            FriendResultLoaderView(
                                pairing: pairing,
                                friend: friend,
                                userID: userID
                            )
                        } label: {
                            FriendRankingCard(rank: index + 1, friend: friend)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text("우리가 전에 스친 적 있을까?")
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text("사진 원본은 업로드하지 않고, 시간과 위치를 흐린 기록만 친구와 비교해요.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("친구와 연결하기", systemImage: "person.2")
                .font(.headline)

            switch firebaseSession.state {
            case .idle, .signingIn:
                ProgressView("익명 계정을 준비하고 있어요")
                    .frame(maxWidth: .infinity, alignment: .leading)

            case .failed(let message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)

                Button("다시 연결하기") {
                    Task { await firebaseSession.signInIfNeeded() }
                }
                .buttonStyle(.bordered)

            case .authenticated(let userID):
                pairingControls(userID: userID)
            }
        }
        .cardStyle()
    }

    private func pairingControls(userID: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("닉네임", text: $pairing.nickname)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("프로필 저장") {
                    Task { _ = await pairing.saveProfile(userID: userID) }
                }
                .buttonStyle(.bordered)

                Button("초대 만들기") {
                    Task { await pairing.createPair(userID: userID) }
                }
                .buttonStyle(.borderedProminent)
            }
            .disabled(pairing.isWorking)

            if !pairing.inviteID.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("초대 ID")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(pairing.inviteID)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)

                    ShareLink(item: pairing.inviteID) {
                        Label("초대 ID 공유", systemImage: "square.and.arrow.up")
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }

            Divider()

            TextField("받은 초대 ID", text: $pairing.joinInviteID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)

            Button("초대 수락하기") {
                Task { await pairing.acceptPair(userID: userID) }
            }
            .buttonStyle(.bordered)
            .disabled(pairing.isWorking)

            if pairing.currentPairID != nil {
                Divider()

                if let pairStatus = pairing.pairStatus {
                    Label(pairStatus, systemImage: pairing.activePairID == nil ? "clock" : "person.2.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if pairing.activePairID != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("처음 알게 된 날", systemImage: "calendar")
                            .font(.subheadline.weight(.semibold))

                        DatePicker(
                            "처음 알게 된 날",
                            selection: $pairing.firstMetDate,
                            in: ...Date(),
                            displayedComponents: .date
                        )
                        .labelsHidden()

                        Text("이 날짜 당일과 이후 기록은 제외하고, 이전 기록만 비교해요.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        firstMetDateActions(userID: userID)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }

                Button("분석 시작") {
                    waitingForAnalysisResult = true
                    Task { await pairing.startAnalysis(userID: userID) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(
                    pairing.isWorking
                        || pairing.activePairID == nil
                        || !pairing.isFirstMetDateConfirmed
                        || analyzer.scanState != .finished
                )

                if pairing.uploadedRecordCount > 0 {
                    Label(
                        "내 분석 준비 완료 · 흐린 기록 \(pairing.uploadedRecordCount)개",
                        systemImage: "checkmark.circle.fill"
                    )
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                if let result = pairing.comparisonResult {
                    NavigationLink {
                        ResultView(
                            result: result,
                            firstMetDate: pairing.savedFirstMetDate ?? pairing.firstMetDate
                        )
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "sparkles")
                                .font(.title2)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("운명 점수 \(result.score)점")
                                    .font(.headline)
                                Text("우리의 교차 기록 보기")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(14)
                        .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
            }

            pairingStatus
        }
        .task(id: "\(userID)-\(analyzer.scanState)") {
            await pairing.loadLatestPair(userID: userID)
            await autoPrepareVisitsIfNeeded(userID: userID)
        }
        .onChange(of: pairing.firstMetStatus) { _, _ in
            if pairing.needsFirstMetDateConfirmation(userID: userID) {
                showDateConfirmationAlert = true
            }
            Task { await autoPrepareVisitsIfNeeded(userID: userID) }
        }
        .onChange(of: pairing.firstMetProposedBy) { _, _ in
            if pairing.needsFirstMetDateConfirmation(userID: userID) {
                showDateConfirmationAlert = true
            }
        }
    }

    private func autoPrepareVisitsIfNeeded(userID: String) async {
        guard pairing.isFirstMetDateConfirmed,
              analyzer.scanState == .finished,
              let pairID = pairing.activePairID,
              let cutoff = pairing.savedFirstMetDate else { return }

        let key = "\(pairID)-\(cutoff.timeIntervalSince1970)"
        guard lastAutoPreparedKey != key else { return }
        lastAutoPreparedKey = key
        await pairing.prepareVisits(
            userID: userID,
            events: analyzer.summary.visitEvents
        )
    }

    @ViewBuilder
    private func firstMetDateActions(userID: String) -> some View {
        if pairing.firstMetStatus == "pending" {
            if pairing.needsFirstMetDateConfirmation(userID: userID) {
                Label("친구가 이 날짜를 제안했어요", systemImage: "bell.badge.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)

                Button("이 날짜가 맞아요") {
                    Task {
                        await pairing.confirmFirstMetDate(
                            userID: userID,
                            events: analyzer.summary.visitEvents
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Label("친구의 확인을 기다리고 있어요", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("다른 날짜로 수정 제안") {
                Task { await pairing.proposeFirstMetDate(userID: userID) }
            }
            .buttonStyle(.bordered)
        } else if pairing.isFirstMetDateConfirmed {
            Label("두 사람이 확인한 기준일이에요", systemImage: "checkmark.seal.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)

            Button("기준일 수정 제안") {
                Task { await pairing.proposeFirstMetDate(userID: userID) }
            }
            .buttonStyle(.bordered)
        } else {
            Button("기준일 최초 등록") {
                Task { await pairing.proposeFirstMetDate(userID: userID) }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var pairingStatus: some View {
        switch pairing.state {
        case .idle:
            EmptyView()
        case .working:
            ProgressView("Firebase에 저장하고 있어요")
        case .succeeded(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch analyzer.authorizationStatus {
        case .notDetermined:
            permissionCard
        case .denied, .restricted:
            deniedCard
        case .authorized, .limited:
            analysisCard
        @unknown default:
            deniedCard
        }
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("사진 접근이 필요해요", systemImage: "hand.raised")
                .font(.headline)

            Text("촬영 시각과 위치가 함께 저장된 사진의 개수만 확인합니다. 언제든 설정에서 권한을 변경할 수 있어요.")
                .foregroundStyle(.secondary)

            Button("사진 접근 허용하기") {
                Task { await analyzer.requestAccessAndScan() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
        }
        .cardStyle()
    }

    private var deniedCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("사진에 접근할 수 없어요", systemImage: "exclamationmark.triangle")
                .font(.headline)

            Text("설정에서 사진 접근을 허용하면 위치가 기록된 사진을 분석할 수 있어요.")
                .foregroundStyle(.secondary)

            Button("설정 열기") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .cardStyle()
    }

    private var analysisCard: some View {
        VStack(spacing: 18) {
            if analyzer.scanState == .scanning {
                ProgressView("사진 기록을 확인하고 있어요")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                summaryRows

                if analyzer.authorizationStatus == .limited {
                    Label("선택한 사진만 분석한 결과예요.", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button("다시 분석하기") {
                    Task { await analyzer.scan() }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }
        }
        .cardStyle()
    }

    private var summaryRows: some View {
        VStack(spacing: 0) {
            SummaryRow(title: "확인한 사진", value: analyzer.summary.totalPhotos, emphasized: false)
            Divider()
            SummaryRow(title: "분석 가능한 사진", value: analyzer.summary.validRecords.count, emphasized: false)
            Divider()
            SummaryRow(title: "방문 기록", value: analyzer.summary.visitEvents.count, emphasized: true)
            Divider()
            SummaryRow(title: "위치 정보 없음", value: analyzer.summary.missingLocationCount, emphasized: false)
            Divider()
            SummaryRow(title: "촬영 시각 없음", value: analyzer.summary.missingDateCount, emphasized: false)
            Divider()
            SummaryRow(title: "비정상 좌표", value: analyzer.summary.invalidCoordinateCount, emphasized: false)
            Divider()
            SummaryRow(title: "중복 제외", value: analyzer.summary.duplicateCount, emphasized: false)
        }
    }
}

private struct SummaryRow: View {
    let title: String
    let value: Int
    let emphasized: Bool

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(emphasized ? .primary : .secondary)
            Spacer()
            Text(value, format: .number)
                .font(.headline.monospacedDigit())
                .foregroundStyle(emphasized ? Color.accentColor : .primary)
        }
        .padding(.vertical, 13)
    }
}

private extension View {
    func cardStyle() -> some View {
        padding(20)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct FriendRankingCard: View {
    let rank: Int
    let friend: FriendConnectionSummary

    var body: some View {
        HStack(spacing: 16) {
            Text("\(rank)")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.tint)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 4) {
                Text(friend.nickname)
                    .font(.headline)
                Text(resultMessage)
                    .font(.subheadline.weight(.medium))
                Text(detailMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.bold())
                .foregroundStyle(.tertiary)
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color(.separator).opacity(0.35), lineWidth: 1)
        }
    }

    private var resultMessage: String {
        guard let strength = friend.closestStrength else {
            return friend.isReady ? "결과를 확인해 보세요" : "친구의 분석을 기다리는 중이에요"
        }
        return switch strength {
        case .strong: "어쩌면 진짜 마주쳤을 수도?"
        case .close: "몇 번쯤 스쳐 갔을지도?"
        case .loose: "같은 날 같은 동네를 지났어요"
        }
    }

    private var detailMessage: String {
        if let score = friend.score {
            return "교차 \(friend.intersectionDayCount)일 · 운명 점수 \(score)"
        }
        return friend.isReady ? "비교 결과를 불러오는 중" : "분석 대기"
    }
}

private struct FriendResultLoaderView: View {
    @ObservedObject var pairing: PairingStore
    let friend: FriendConnectionSummary
    let userID: String

    var body: some View {
        Group {
            if let result = pairing.comparisonResult,
               pairing.activePairID == friend.id {
                ResultView(
                    result: result,
                    firstMetDate: pairing.savedFirstMetDate ?? friend.firstMetDate ?? Date()
                )
            } else if case .failed(let message) = pairing.state {
                ContentUnavailableView(
                    "결과를 열 수 없어요",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            } else {
                ProgressView("\(friend.nickname)님과의 기록을 비교하고 있어요")
            }
        }
        .navigationTitle(friend.nickname)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: friend.id) {
            await pairing.openPair(pairID: friend.id, userID: userID)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(FirebaseSession())
}
