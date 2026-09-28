import Photos
import SwiftUI
import UIKit

struct ContentView: View {
    @AppStorage("didFinishOnboarding") private var didFinishOnboarding = false
    @StateObject private var analyzer = PhotoLibraryAnalyzer()
    @StateObject private var pairing = PairingStore()
    @EnvironmentObject private var firebaseSession: FirebaseSession
    @State private var onboardingStep: OnboardingStep = .start
    @State private var activeSheet: HomeSheet?
    @State private var showLatestResult = false
    @State private var lastPreparedKey = ""

    var body: some View {
        Group {
            if didFinishOnboarding {
                home
            } else {
                OnboardingFlowView(
                    step: $onboardingStep,
                    analyzer: analyzer,
                    pairing: pairing,
                    firebaseSession: firebaseSession,
                    onFinished: { didFinishOnboarding = true }
                )
            }
        }
        .tint(AppTheme.primary)
        .preferredColorScheme(.light)
    }

    private var home: some View {
        NavigationStack {
            Group {
                switch firebaseSession.state {
                case .idle, .signingIn:
                    ProgressView("계정을 준비하고 있어요")
                case .failed(let message):
                    FlowErrorView(
                        title: "계정을 준비하지 못했어요",
                        message: message,
                        primaryTitle: "다시 시도하기"
                    ) {
                        Task { await firebaseSession.signInIfNeeded() }
                    }
                case .authenticated(let userID):
                    HomeView(
                        analyzer: analyzer,
                        pairing: pairing,
                        userID: userID,
                        onInvite: { activeSheet = .invite },
                        onJoin: { activeSheet = .join },
                        onPairStatus: { activeSheet = .pair },
                        onSettings: { activeSheet = .settings },
                        onManage: { activeSheet = .manage }
                    )
                    .task(id: userID) {
                        if analyzer.canReadPhotos, analyzer.scanState == .idle {
                            await analyzer.scan()
                        }
                        await pairing.loadLatestPair(userID: userID)
                        if pairing.currentPairID != nil,
                           pairing.activePairID != nil,
                           pairing.comparisonResult == nil {
                            activeSheet = .pair
                        }
                    }
                    .task(id: "\(pairing.firstMetStatus ?? "none")-\(analyzer.scanState)-\(pairing.activePairID ?? "none")") {
                        await prepareAndCompareIfNeeded(userID: userID)
                    }
                    .onChange(of: pairing.firstMetStatus) { _, _ in
                        guard pairing.activePairID != nil else { return }
                        activeSheet = .pair
                    }
                    .onChange(of: pairing.completedAnalysisCount) { _, count in
                        if count > 0 {
                            activeSheet = nil
                            showLatestResult = true
                        }
                    }
                    .sheet(item: $activeSheet) { sheet in
                        sheetContent(sheet, userID: userID)
                    }
                    .fullScreenCover(isPresented: $showLatestResult) {
                        if let result = pairing.comparisonResult {
                            NavigationStack {
                                ResultView(
                                    result: result,
                                    firstMetDate: pairing.savedFirstMetDate ?? pairing.firstMetDate,
                                    firstNickname: pairing.nickname,
                                    secondNickname: pairing.connectedFriendNickname
                                )
                                .toolbar {
                                    ToolbarItem(placement: .topBarLeading) {
                                        Button("닫기") { showLatestResult = false }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: HomeSheet, userID: String) -> some View {
        switch sheet {
        case .invite:
            InviteCreateView(pairing: pairing, userID: userID)
        case .join:
            InviteJoinFlowView(pairing: pairing, userID: userID)
        case .pair:
            PairStatusFlowView(
                pairing: pairing,
                userID: userID
            )
        case .settings:
            SettingsView(
                nickname: pairing.nickname,
                onResetOnboarding: {
                    didFinishOnboarding = false
                    onboardingStep = .start
                    activeSheet = nil
                }
            )
        case .manage:
            FriendManagementView(pairing: pairing, userID: userID)
        }
    }

    private func prepareAndCompareIfNeeded(userID: String) async {
        guard pairing.isFirstMetDateConfirmed,
              analyzer.scanState == .finished,
              let pairID = pairing.activePairID,
              let cutoff = pairing.savedFirstMetDate,
              pairing.comparisonResult == nil else { return }

        let key = "\(pairID)-\(cutoff.timeIntervalSince1970)"
        guard lastPreparedKey != key else { return }
        lastPreparedKey = key
        await pairing.prepareVisits(userID: userID, events: analyzer.summary.visitEvents)
        await pairing.startAnalysis(userID: userID)
    }
}

private enum OnboardingStep {
    case start
    case privacy
    case nickname
    case photoAccess
    case scanning
    case denied
    case limited
    case noLocation
    case insufficient
    case summary
    case failed(String)
}

private enum HomeSheet: String, Identifiable {
    case invite, join, pair, settings, manage
    var id: String { rawValue }
}

private struct OnboardingFlowView: View {
    @Binding var step: OnboardingStep
    @ObservedObject var analyzer: PhotoLibraryAnalyzer
    @ObservedObject var pairing: PairingStore
    @ObservedObject var firebaseSession: FirebaseSession
    let onFinished: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch step {
        case .start:
            FlowScreen {
                Spacer()
                OrbitMark()
                    .frame(maxWidth: .infinity)
                Text("우리는 만나기 전에도\n가까이 있었을까?")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(AppTheme.text)
                    .padding(.top, 36)
                Text("사진에 남은 시간과 장소를 따라 두 사람의 지난 흔적을 찾아봐요.")
                    .font(.system(size: 13))
                    .foregroundStyle(AppTheme.secondaryText)
                    .padding(.top, 8)
                Spacer()
                Button("다음") { step = .privacy }
                    .buttonStyle(PrimaryActionButtonStyle())
            }

        case .privacy:
            FlowScreen(
                title: "사진의 날짜와 위치 정보만 살펴봐요",
                message: "사진은 올리지 않아요. 촬영 날짜와 대략적인 위치만 확인해요.",
                backAction: { step = .start }
            ) {
                InfoCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("안심하고 시작해도 좋아요")
                            .font(.system(size: 13, weight: .bold))
                        Text("✓ 사진은 어디에도 올리지 않아요\n✓ 정확한 위치는 친구에게 보여주지 않아요\n✓ 분석 결과는 언제든 지울 수 있어요")
                            .font(.system(size: 12))
                            .foregroundStyle(AppTheme.secondaryText)
                            .lineSpacing(5)
                    }
                }
                .padding(.top, 32)
                Spacer()
                Button("우리의 흔적 찾아보기") { step = .nickname }
                    .buttonStyle(PrimaryActionButtonStyle())
            }

        case .nickname:
            nicknameScreen

        case .photoAccess:
            photoAccessScreen

        case .scanning:
            FlowScreen(title: "사진 분석", backAction: nil) {
                Spacer()
                ProgressView()
                    .controlSize(.large)
                    .tint(AppTheme.primary)
                    .frame(maxWidth: .infinity)
                Text("사진 기록을 살펴보고 있어요")
                    .font(.system(size: 16, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 28)
                Text("사진에 남은 시간과 위치 정보를 확인하고 있어요.\n앱을 닫아도 분석은 계속돼요.")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                Spacer()
            }

        case .denied:
            FlowErrorView(
                title: "사진을 분석하려면 권한이 필요해요",
                message: "사진의 날짜와 위치를 확인할 수 있도록 설정에서 사진 접근을 허용해 주세요.",
                primaryTitle: "설정 열기",
                secondaryTitle: "다음에 할게요",
                infoTitle: "사진 접근이 왜 필요한가요?",
                infoMessage: "두 사람이 스친 적이 있는지 찾기 위해 날짜와 위치만 기기에서 확인해요. 사진은 저장하거나 전송하지 않아요."
            ) {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            } secondaryAction: {
                step = .photoAccess
            }

        case .limited:
            FlowErrorView(
                title: "선택한 사진만 살펴볼게요",
                message: "선택한 사진만 비교하면 운명지수가 실제보다 낮게 나올 수 있어요.",
                primaryTitle: "이대로 분석하기",
                secondaryTitle: "사진 더 고르기",
                infoTitle: "현재 분석 범위",
                infoMessage: "선택한 사진 \(analyzer.summary.totalPhotos.formatted())장"
            ) {
                finishPhotoAnalysis()
            } secondaryAction: {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }

        case .noLocation:
            FlowErrorView(
                title: "위치 정보가 있는 사진이 부족해요",
                message: "촬영 위치가 저장된 사진이 있어야 친구와 얼마나 가까이 있었는지 비교할 수 있어요.",
                primaryTitle: "사진 설정 열기",
                secondaryTitle: "분석 그만하기",
                infoTitle: "이 설정을 확인해 주세요",
                infoMessage: "카메라 위치 서비스와 사진 위치 접근이 켜져 있는지 확인해 주세요."
            ) {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            } secondaryAction: {
                step = .photoAccess
            }

        case .insufficient:
            FlowErrorView(
                title: "비교하기엔 사진 기록이 부족해요",
                message: "위치 기록이 3개보다 적으면 결과가 정확하지 않을 수 있어요.",
                primaryTitle: "그래도 계속하기",
                secondaryTitle: "나중에 다시 분석",
                infoTitle: "현재 기록",
                infoMessage: "방문 기록 \(analyzer.summary.visitEvents.count)개 · 5개 이상이면 더 정확해요"
            ) {
                step = .summary
            } secondaryAction: {
                step = .photoAccess
            }

        case .summary:
            analysisSummary

        case .failed(let message):
            FlowErrorView(
                title: "분석을 마치지 못했어요",
                message: message,
                primaryTitle: "다시 시도하기",
                secondaryTitle: "처음으로",
                infoTitle: "먼저 확인해 주세요",
                infoMessage: "인터넷 연결과 기기 저장 공간을 확인해 주세요."
            ) {
                startPhotoAnalysis()
            } secondaryAction: {
                step = .start
            }
        }
    }

    private var nicknameScreen: some View {
        FlowScreen(
            title: "어떻게 불러드릴까요?",
            message: "친구에게 보이는 이름이에요. 언제든 바꿀 수 있어요.",
            backAction: { step = .privacy }
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("닉네임")
                    .font(.system(size: 12, weight: .medium))
                TextField("예: 김체리", text: $pairing.nickname)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .frame(height: 48)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8).stroke(AppTheme.divider)
                    }
                if !pairing.nickname.isEmpty && !(1...12).contains(pairing.nickname.count) {
                    Text("닉네임은 1~12자로 입력해 주세요.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.top, 32)
            Spacer()
            Button("완료") {
                guard case .authenticated(let userID) = firebaseSession.state else { return }
                Task {
                    if await pairing.saveProfile(userID: userID) {
                        step = .photoAccess
                    }
                }
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .disabled(!(1...12).contains(pairing.nickname.trimmingCharacters(in: .whitespacesAndNewlines).count) || pairing.isWorking)
            .opacity((1...12).contains(pairing.nickname.trimmingCharacters(in: .whitespacesAndNewlines).count) ? 1 : 0.35)
        }
    }

    private var photoAccessScreen: some View {
        FlowScreen(
            title: "\(pairing.nickname.isEmpty ? "회원" : pairing.nickname)님의 사진 기록을\n살펴볼게요",
            message: "사진은 전송하지 않아요.\n촬영 날짜와 위치 정보만 확인해요.",
            backAction: { step = .nickname }
        ) {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("분석하는 정보").font(.system(size: 13, weight: .bold)).foregroundStyle(AppTheme.primary)
                    Text("촬영 날짜\n촬영 위치").font(.system(size: 14)).lineSpacing(7)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("분석하지 않는 정보").font(.system(size: 13, weight: .bold)).foregroundStyle(AppTheme.secondaryText)
                    Text("사진 속 인물\n사진 내용\n앨범 이름").font(.system(size: 14)).lineSpacing(7)
                }
            }
            .padding(.top, 32)
            Spacer()
            Button("사진 접근 허용하기") { startPhotoAnalysis() }
                .buttonStyle(PrimaryActionButtonStyle())
        }
    }

    private var analysisSummary: some View {
        FlowScreen(
            title: "\(pairing.nickname)님의 사진 기록을\n모두 살펴봤어요",
            backAction: nil
        ) {
            VStack(spacing: 0) {
                SummaryRow(title: "확인한 사진", value: "\(analyzer.summary.totalPhotos.formatted())장")
                Divider()
                SummaryRow(title: "위치 정보가 있는 사진", value: "\(analyzer.summary.validRecords.count.formatted())장")
                Divider()
                SummaryRow(title: "받거나 가져온 사진 제외", value: "\(analyzer.summary.excludedImportedCount.formatted())장")
                Divider()
                SummaryRow(title: "유효한 방문 기록", value: "\(analyzer.summary.visitEvents.count.formatted())개")
                Divider()
                SummaryRow(title: "분석 기간", value: analysisPeriod)
            }
            .padding(.top, 28)
            Spacer()
            Button("친구와 비교해 보기", action: onFinished)
                .buttonStyle(PrimaryActionButtonStyle())
        }
    }

    private var analysisPeriod: String {
        guard let first = analyzer.summary.validRecords.first?.capturedAt,
              let last = analyzer.summary.validRecords.last?.capturedAt else { return "기록 없음" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM"
        return "\(formatter.string(from: first))–\(formatter.string(from: last))"
    }

    private func startPhotoAnalysis() {
        step = .scanning
        Task {
            if analyzer.canReadPhotos {
                await analyzer.scan()
            } else {
                await analyzer.requestAccessAndScan()
            }
            switch analyzer.authorizationStatus {
            case .denied, .restricted:
                step = .denied
            case .limited:
                step = .limited
            case .authorized:
                finishPhotoAnalysis()
            default:
                step = .photoAccess
            }
        }
    }

    private func finishPhotoAnalysis() {
        switch analyzer.scanState {
        case .failed(let message): step = .failed(message)
        case .finished:
            if analyzer.summary.validRecords.isEmpty { step = .noLocation }
            else if analyzer.summary.visitEvents.count < 3 { step = .insufficient }
            else { step = .summary }
        default: step = .scanning
        }
    }
}

private struct HomeView: View {
    @ObservedObject var analyzer: PhotoLibraryAnalyzer
    @ObservedObject var pairing: PairingStore
    let userID: String
    let onInvite: () -> Void
    let onJoin: () -> Void
    let onPairStatus: () -> Void
    let onSettings: () -> Void
    let onManage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(pairing.nickname.isEmpty ? "나" : pairing.nickname)님의 인연순위")
                        .font(.system(size: 22, weight: .bold))
                    Text("친구 \(pairing.friendSummaries.count)명과 비교했어요")
                        .font(.system(size: 13))
                        .foregroundStyle(AppTheme.secondaryText)
                }
                Spacer()
                Button(action: onSettings) { Image(systemName: "gearshape") }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.secondaryText)
            }

            HStack {
                Spacer()
                Button("친구 관리", action: onManage)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(AppTheme.primary)
            .padding(.top, -20)

            if pairing.activePairID != nil,
               !pairing.isFirstMetDateConfirmed,
               pairing.comparisonResult == nil {
                Button(action: onPairStatus) {
                    HStack {
                        Image(systemName: pairing.isFirstMetDateConfirmed ? "sparkles" : "calendar.badge.clock")
                        Text(connectionStatusTitle)
                            .font(.system(size: 13, weight: .bold))
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .padding(16)
                    .background(AppTheme.primarySoft)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
            }

            if pairing.friendSummaries.isEmpty {
                InfoCard {
                    VStack(spacing: 12) {
                        OrbitMark().scaleEffect(0.72)
                        Text("아직 연결된 친구가 없어요")
                            .font(.system(size: 15, weight: .bold))
                        Text("친구를 초대하거나 받은 코드를 입력해 보세요.")
                            .font(.system(size: 12))
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(pairing.friendSummaries.enumerated()), id: \.element.id) { index, friend in
                        let isAnalyzing = pairing.activePairID == friend.id
                            && pairing.isFirstMetDateConfirmed
                            && pairing.comparisonResult == nil
                        NavigationLink {
                            if isAnalyzing {
                                AnalysisProgressView(pairing: pairing)
                            } else {
                                FriendResultLoaderView(
                                    pairing: pairing,
                                    friend: friend,
                                    userID: userID
                                )
                            }
                        } label: {
                            FriendRankingRow(
                                rank: index + 1,
                                friend: friend,
                                isAnalyzing: isAnalyzing
                            )
                        }
                        .buttonStyle(.plain)
                        if friend.id != pairing.friendSummaries.last?.id { Divider() }
                    }
                }
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay { RoundedRectangle(cornerRadius: 9).stroke(AppTheme.divider) }
            }

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("친구를 초대해 비교해 보세요")
                        .font(.system(size: 14, weight: .bold))
                    Button("받은 초대 코드 입력하기 ›", action: onJoin)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.primary)
                }
                Spacer()
                Button("초대하기", action: onInvite)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(AppTheme.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(16)
            .background(AppTheme.primarySoft)
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppTheme.background.ignoresSafeArea())
        .navigationBarHidden(true)
    }

    private var connectionStatusTitle: String {
        if pairing.isFirstMetDateConfirmed { return "결과를 분석중이에요" }
        let nickname = pairing.connectedFriendNickname
        guard let scalar = nickname.unicodeScalars.last else { return "친구와 연결됐어요" }
        let hangulIndex = Int(scalar.value) - 0xAC00
        let particle = (0...11_171).contains(hangulIndex) && hangulIndex % 28 != 0 ? "과" : "와"
        return "\(nickname)\(particle) 연결됐어요"
    }

}

private struct InviteCreateView: View {
    @ObservedObject var pairing: PairingStore
    let userID: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            FlowScreen(
                title: pairing.inviteID.isEmpty ? "친구에게 보낼 초대를 만들까요?" : "초대 링크가 복사되었어요!\n친구에게 전달해 주세요",
                message: pairing.inviteID.isEmpty ? "초대 코드는 한 명의 친구와 연결할 때 사용해요." : "초대 코드는 24시간 동안 사용할 수 있어요.",
                backAction: { dismiss() }
            ) {
                if !pairing.inviteID.isEmpty {
                    InfoCard {
                        HStack {
                            Text(pairing.inviteID)
                                .font(.system(size: 22, weight: .bold, design: .monospaced))
                                .tracking(6)
                                .textSelection(.enabled)
                            Spacer()
                            Button {
                                UIPasteboard.general.string = pairing.inviteID
                            } label: { Image(systemName: "doc.on.doc") }
                        }
                    }
                    .padding(.top, 32)
                }
                Spacer()
                if pairing.inviteID.isEmpty {
                    Button("초대 코드 만들기") { Task { await pairing.createPair(userID: userID) } }
                        .buttonStyle(PrimaryActionButtonStyle())
                } else {
                    ShareLink(item: "본 적 있나? 초대 코드: \(pairing.inviteID)") {
                        Text("초대 메시지 공유")
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                }
            }
        }
    }
}

private struct InviteJoinFlowView: View {
    enum Stage { case code, consent, date }
    @ObservedObject var pairing: PairingStore
    let userID: String
    @Environment(\.dismiss) private var dismiss
    @State private var stage: Stage = .code

    var body: some View {
        NavigationStack {
            switch stage {
            case .code: codeScreen
            case .consent: consentScreen
            case .date: dateScreen
            }
        }
    }

    private var codeScreen: some View {
        FlowScreen(
            title: "받은 초대 코드를\n입력해 주세요",
            message: "친구에게 받은 6자리 코드를 입력하면 바로 연결 단계로 넘어가요.",
            backAction: { dismiss() }
        ) {
            TextField("GR8DCD", text: $pairing.joinInviteID)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .tracking(8)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .frame(height: 58)
                .background(.white)
                .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.primary).frame(height: 2) }
                .padding(.top, 32)
                .onChange(of: pairing.joinInviteID) { _, value in
                    let normalized = String(value.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(6))
                    if normalized != value { pairing.joinInviteID = normalized }
                }
            operationMessage
            Spacer()
            Button("확인") {
                Task {
                    if await pairing.previewInvite(userID: userID) { stage = .consent }
                }
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .disabled(pairing.joinInviteID.count != 6 || pairing.isWorking)
        }
    }

    private var consentScreen: some View {
        FlowScreen(
            title: "\(pairing.inviteCreatorNickname)님과 연결할까요?",
            message: "서로 동의한 뒤에만 두 사람의 흐린 방문 기록을 비교해요.",
            backAction: { stage = .code }
        ) {
            InfoCard {
                VStack(alignment: .leading, spacing: 8) {
                    Label("사진 원본은 공유하지 않아요", systemImage: "photo.badge.checkmark")
                    Label("정확한 좌표는 서로 볼 수 없어요", systemImage: "location.slash")
                    Label("연결은 언제든 끊을 수 있어요", systemImage: "person.crop.circle.badge.xmark")
                }
                .font(.system(size: 13))
            }
            .padding(.top, 32)
            Spacer()
            Button("연결하기") {
                Task {
                    if await pairing.acceptPair(userID: userID) { stage = .date }
                }
            }
            .buttonStyle(PrimaryActionButtonStyle())
            Button("연결하지 않기") { dismiss() }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppTheme.secondaryText)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        }
    }

    private var dateScreen: some View {
        FirstMetDateEntryView(pairing: pairing, userID: userID) { dismiss() }
    }

    @ViewBuilder private var operationMessage: some View {
        if case .failed(let message) = pairing.state {
            Text(message).font(.caption).foregroundStyle(.red).padding(.top, 10)
        }
    }
}

private struct PairStatusFlowView: View {
    @ObservedObject var pairing: PairingStore
    let userID: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if pairing.activePairID == nil {
                    StatusMessageView(
                        title: "친구의 수락을 기다리고 있어요",
                        message: "친구가 초대 코드를 입력하면 다음 단계로 넘어가요.",
                        symbol: "person.2.badge.plus",
                        buttonTitle: "확인",
                        action: { dismiss() }
                    )
                } else if pairing.firstMetStatus == nil {
                    FirstMetDateEntryView(pairing: pairing, userID: userID) { dismiss() }
                } else if pairing.firstMetStatus == "pending" {
                    if pairing.needsFirstMetDateConfirmation(userID: userID) {
                        FirstMetDateConfirmationView(pairing: pairing, userID: userID)
                    } else {
                        StatusMessageView(
                            title: "기준일 확인을\n기다리고 있어요",
                            message: "\(pairing.connectedFriendNickname)님이 날짜를 확인하면 바로 분석을 시작해요.",
                            symbol: "clock.badge.checkmark",
                            buttonTitle: "확인",
                            action: { dismiss() }
                        )
                    }
                } else {
                    if pairing.comparisonResult == nil {
                        AnalysisProgressView(pairing: pairing, onBack: { dismiss() })
                    } else {
                        StatusMessageView(
                            title: "분석 결과가 도착했어요",
                            message: "홈의 친구 카드에서 결과를 확인할 수 있어요.",
                            symbol: "checkmark.circle.fill",
                            buttonTitle: "확인",
                            action: { dismiss() }
                        )
                    }
                }
            }
        }
    }
}

private struct FirstMetDateEntryView: View {
    @ObservedObject var pairing: PairingStore
    let userID: String
    let onSaved: () -> Void

    var body: some View {
        FlowScreen(
            title: "처음 알게 된 날을\n입력해 주세요",
            message: "이 날짜 이전의 기록만 비교해요. 상대방이 확인하면 분석이 시작돼요.",
            backAction: onSaved
        ) {
            DatePicker(
                "처음 알게 된 날",
                selection: $pairing.firstMetDate,
                in: ...Date(),
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .tint(AppTheme.primary)
            .padding(.top, 20)
            Spacer()
            Button("확인 요청 보내기") {
                Task {
                    await pairing.proposeFirstMetDate(userID: userID)
                    onSaved()
                }
            }
            .buttonStyle(PrimaryActionButtonStyle())
        }
    }
}

private struct FirstMetDateConfirmationView: View {
    @ObservedObject var pairing: PairingStore
    let userID: String
    @State private var editing = false

    var body: some View {
        if editing {
            FirstMetDateEntryView(pairing: pairing, userID: userID) { editing = false }
        } else {
            FlowScreen(
                title: "\(pairing.connectedFriendNickname)님이 처음 알게 된\n날을 입력했어요",
                message: "날짜가 맞으면 동의해 주세요. 동의하면 바로 분석을 시작해요.",
                backAction: nil
            ) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("친구가 입력한 기준일")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.secondaryText)
                    Text(pairing.savedFirstMetDate ?? pairing.firstMetDate, format: .dateTime.year().month().day())
                        .font(.system(size: 20, weight: .bold))
                }
                .padding(.top, 32)
                Text("날짜가 다르면 수정해서 다시 확인을 요청할 수 있어요. 결과가 나온 뒤에는 기준일을 바꿀 수 없어요.")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.secondaryText)
                    .padding(.top, 24)
                Spacer()
                Button("동의하기") {
                    Task {
                        await pairing.confirmFirstMetDate(userID: userID)
                    }
                }
                .buttonStyle(PrimaryActionButtonStyle())
                Button("날짜 수정하기") { editing = true }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppTheme.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
            }
        }
    }
}

private struct FriendRankingRow: View {
    let rank: Int
    let friend: FriendConnectionSummary
    var isAnalyzing = false

    var body: some View {
        HStack(spacing: 12) {
            Text(isAnalyzing || friend.score == nil ? "–" : "\(rank)")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(AppTheme.primary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(friend.nickname).font(.system(size: 14, weight: .bold))
                Text(
                    isAnalyzing
                        ? "결과를 분석중이에요"
                        : friend.closestStrength?.relationshipLabel
                            ?? (friend.isReady ? "아직 접점 못 찾은 사이" : "분석을 기다리는 중")
                )
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.secondaryText)
            }
            Spacer()
            Text(isAnalyzing ? "–" : friend.score.map(String.init) ?? "–")
                .font(.system(size: 15, weight: .bold))
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(AppTheme.secondaryText)
        }
        .padding(.horizontal, 16)
        .frame(height: 61)
    }
}

private struct AnalysisProgressView: View {
    @ObservedObject var pairing: PairingStore
    var onBack: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    private var progress: Double {
        min(max(pairing.analysisProgress, 0.08), 0.99)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("사진 분석")
                    .font(.system(size: 15, weight: .bold))

                HStack {
                    Button(action: goBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 28, height: 28, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }
            .frame(height: 44)

            Spacer(minLength: 90)

            ZStack {
                Circle()
                    .stroke(AppTheme.divider, lineWidth: 6)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        AppTheme.primary,
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.35), value: progress)
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.system(size: 36, weight: .regular))
                    .monospacedDigit()
            }
            .frame(width: 154, height: 154)

            VStack(spacing: 8) {
                Text("사진 기록을 살펴보고 있어요")
                    .font(.system(size: 18, weight: .bold))
                Text("사진에 남은 시간과 위치 정보를 확인하고 있어요.")
                    .font(.system(size: 13))
                    .foregroundStyle(AppTheme.secondaryText)
                Text("앱을 닫아도 분석은 계속돼요.")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.primary)
            }
            .multilineTextAlignment(.center)
            .padding(.top, 32)

            Spacer()

            Text("분석 취소")
                .font(.system(size: 13))
                .foregroundStyle(AppTheme.secondaryText)
                .padding(.bottom, 22)
        }
        .padding(.horizontal, 19)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(AppTheme.text)
        .background(AppTheme.background.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
    }

    private func goBack() {
        if let onBack { onBack() } else { dismiss() }
    }
}

private struct FriendResultLoaderView: View {
    @ObservedObject var pairing: PairingStore
    let friend: FriendConnectionSummary
    let userID: String

    var body: some View {
        Group {
            if let result = pairing.comparisonResult, pairing.activePairID == friend.id {
                ResultView(
                    result: result,
                    firstMetDate: pairing.savedFirstMetDate ?? friend.firstMetDate ?? Date(),
                    firstNickname: pairing.nickname,
                    secondNickname: friend.nickname
                )
            } else if case .failed(let message) = pairing.state {
                FlowErrorView(title: "결과를 열 수 없어요", message: message, primaryTitle: "다시 시도하기") {
                    Task { await pairing.openPair(pairID: friend.id, userID: userID) }
                }
            } else {
                ProgressView()
            }
        }
        .task(id: friend.id) {
            await pairing.openPair(pairID: friend.id, userID: userID)
        }
    }
}

private struct FriendManagementView: View {
    @ObservedObject var pairing: PairingStore
    let userID: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            FlowScreen(title: "친구 관리", message: "연결된 친구와 결과 상태를 확인할 수 있어요.", backAction: { dismiss() }) {
                VStack(spacing: 0) {
                    ForEach(pairing.friendSummaries) { friend in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(friend.nickname).font(.headline)
                                Text(friend.isReady ? "분석 완료" : "분석 대기")
                                    .font(.caption).foregroundStyle(AppTheme.secondaryText)
                            }
                            Spacer()
                            Button("연결 해제", role: .destructive) {
                                Task { await pairing.disconnectPair(pairID: friend.id, userID: userID) }
                            }
                            .font(.caption.weight(.semibold))
                        }
                        .padding(.vertical, 16)
                        Divider()
                    }
                }
                .padding(.top, 24)
            }
        }
    }
}

private struct SettingsView: View {
    let nickname: String
    let onResetOnboarding: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            FlowScreen(title: "설정", backAction: { dismiss() }) {
                VStack(spacing: 0) {
                    SettingsRow(title: "닉네임", value: nickname)
                    Divider()
                    SettingsRow(title: "사진 접근", value: "iOS 설정에서 변경")
                    Divider()
                    SettingsRow(title: "개인정보", value: "원본 사진 업로드 안 함")
                }
                .padding(.top, 24)
                Spacer()
                Button("온보딩 다시 보기", action: onResetOnboarding)
                    .buttonStyle(SecondaryActionButtonStyle())
            }
        }
    }
}

private struct SettingsRow: View {
    let title: String
    let value: String
    var body: some View {
        HStack { Text(title); Spacer(); Text(value).foregroundStyle(AppTheme.secondaryText) }
            .font(.system(size: 13))
            .padding(.vertical, 16)
    }
}

private struct SummaryRow: View {
    let title: String
    let value: String
    var body: some View {
        HStack { Text(title).foregroundStyle(AppTheme.secondaryText); Spacer(); Text(value).fontWeight(.semibold) }
            .font(.system(size: 13))
            .padding(.vertical, 14)
    }
}

private struct OrbitMark: View {
    var body: some View {
        ZStack {
            Circle().stroke(AppTheme.primary, lineWidth: 2).frame(width: 92, height: 92)
            Circle().fill(AppTheme.primary).frame(width: 18, height: 18).offset(x: -8, y: 5)
            Circle().fill(AppTheme.primary.opacity(0.45)).frame(width: 14, height: 14).offset(x: 17, y: 16)
        }
        .frame(height: 100)
        .accessibilityHidden(true)
    }
}

private struct StatusMessageView: View {
    let title: String
    let message: String
    let symbol: String
    let buttonTitle: String
    let action: () -> Void
    var body: some View {
        FlowScreen(title: title, message: message, backAction: action) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(AppTheme.primary)
                .frame(maxWidth: .infinity)
            Spacer()
            Button(buttonTitle, action: action).buttonStyle(PrimaryActionButtonStyle())
        }
    }
}

private struct FlowErrorView: View {
    let title: String
    let message: String
    let primaryTitle: String
    var secondaryTitle: String? = nil
    var infoTitle: String? = nil
    var infoMessage: String? = nil
    let primaryAction: () -> Void
    var secondaryAction: (() -> Void)? = nil

    var body: some View {
        FlowScreen(title: title, message: message) {
            if let infoTitle, let infoMessage {
                InfoCard {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(infoTitle).font(.system(size: 13, weight: .bold))
                        Text(infoMessage).font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
                    }
                }
                .padding(.top, 32)
            }
            Spacer()
            if let secondaryTitle, let secondaryAction {
                Button(secondaryTitle, action: secondaryAction)
                    .buttonStyle(SecondaryActionButtonStyle())
                    .padding(.bottom, 8)
            }
            Button(primaryTitle, action: primaryAction)
                .buttonStyle(PrimaryActionButtonStyle())
        }
    }
}

#Preview {
    ContentView().environmentObject(FirebaseSession())
}
