import Photos
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var analyzer = PhotoLibraryAnalyzer()
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    content
                }
                .frame(maxWidth: .infinity)
                .padding(24)
            }
            .navigationTitle("사진 기록 확인")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                if analyzer.canReadPhotos, analyzer.scanState == .idle {
                    await analyzer.scan()
                }
            }
        }
        .tint(Color(red: 0.45, green: 0.36, blue: 0.78))
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.stack")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text("사진 속 시간과 위치만 확인해요")
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text("사진 원본은 업로드하지 않으며, 이 단계에서는 분석 결과도 기기 밖으로 전송하지 않아요.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
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

#Preview {
    ContentView()
}
