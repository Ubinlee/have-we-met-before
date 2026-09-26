import MapKit
import SwiftUI

struct ResultView: View {
    let result: DestinyScoreResult
    let firstMetDate: Date

    private var matches: [TrajectoryIntersection] { result.rankedIntersections }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                hero
                if let first = matches.first {
                    firstPlace(first)
                    otherPlaces
                } else {
                    ContentUnavailableView(
                        "교차 기록 없음",
                        systemImage: "map",
                        description: Text("같은 날 가까운 지역에 있었던 흔적을 찾지 못했어요.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                }
                privacyNote
                ShareLink(item: shareText) {
                    Label("결과 공유하기", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("거의 만날 뻔한 사이")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("분석 정보")
                .font(.headline)
            Text("처음 알게 된 날 · \(Self.dateFormatter.string(from: firstMetDate))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(headline)
                .font(.title2.bold())
                .padding(.top, 10)
            HStack(alignment: .firstTextBaseline) {
                Text("운명 점수").foregroundStyle(.secondary)
                Spacer()
                Text("\(result.score)")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(.tint)
                Text("점").font(.headline)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
    }

    private var headline: String {
        guard let match = matches.first else { return "가까운 흔적을 찾지 못했어요." }
        return switch match.strength {
        case .strong: "두 사람은 만나기 전, 같은 시간대 같은 지역에 있었어요."
        case .close: "두 사람은 만나기 전, 아주 가까운 곳을 지나갔어요."
        case .loose: "두 사람은 만나기 전, 같은 날 가까운 동네에 있었어요."
        }
    }

    private func firstPlace(_ match: TrajectoryIntersection) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("가장 가까웠던 순간", systemImage: "sparkles")
                .font(.title3.bold())
            approximateMap(match)
            Text(Self.dateFormatter.string(from: match.occurredAt))
                .font(.title2.bold())
            Text(ApproximatePlaceResolver.name(
                latitude: match.approximateLatitude,
                longitude: match.approximateLongitude
            ))
            .font(.headline)
            .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                metric("시간 차이", timeText(match.timeDifference))
                metric("두 사람 거리", distanceText(match.distanceMeters))
            }
        }
    }

    private func approximateMap(_ match: TrajectoryIntersection) -> some View {
        let coordinate = CLLocationCoordinate2D(
            latitude: match.approximateLatitude,
            longitude: match.approximateLongitude
        )
        let region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: 3_200,
            longitudinalMeters: 3_200
        )
        return Map(initialPosition: .region(region), interactionModes: []) {
            MapCircle(center: coordinate, radius: 700)
                .foregroundStyle(.tint.opacity(0.2))
                .stroke(.tint.opacity(0.8), lineWidth: 2)
            Marker("대략적인 위치", coordinate: coordinate)
                .tint(Color.accentColor)
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .frame(height: 260)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(alignment: .bottomLeading) {
            Label("정확한 좌표가 아닌 약 1km 범위예요", systemImage: "eye.slash")
                .font(.caption.weight(.medium))
                .padding(10)
                .background(.regularMaterial, in: Capsule())
                .padding(12)
        }
    }

    @ViewBuilder
    private var otherPlaces: some View {
        if matches.count > 1 {
            VStack(spacing: 0) {
                ForEach(Array(matches.dropFirst().enumerated()), id: \.element.id) { index, match in
                    if index > 0 { Divider() }
                    HStack(alignment: .top, spacing: 14) {
                        Text("\(index + 2)")
                            .font(.title2.bold())
                            .foregroundStyle(.tint)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(Self.dateFormatter.string(from: match.occurredAt)).font(.headline)
                            Text(ApproximatePlaceResolver.name(
                                latitude: match.approximateLatitude,
                                longitude: match.approximateLongitude
                            ))
                            .font(.subheadline.weight(.semibold))
                            Text("시간 차이 \(timeText(match.timeDifference)) · 거리 \(distanceText(match.distanceMeters))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 16)
                }
            }
            .padding(.horizontal, 18)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
    }

    private var privacyNote: some View {
        Label {
            Text("사진 원본과 정확한 좌표는 공유하지 않아요. 지도와 장소명도 약 1km 범위의 흐린 위치를 사용해요.")
        } icon: { Image(systemName: "lock.shield") }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var shareText: String {
        matches.isEmpty
            ? "처음 만나기 전 우리의 기록을 비교해 봤어요. #본적있나"
            : "처음 만나기 전, 우리는 \(result.totalIntersectionDayCount)일이나 스칠 뻔했대요. 운명 점수 \(result.score)점! #본적있나"
    }

    private func timeText(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3_600
        let minutes = (Int(seconds) % 3_600) / 60
        if hours == 0 { return minutes == 0 ? "같은 시간대" : "약 \(minutes)분" }
        if minutes == 0 { return "약 \(hours)시간" }
        return "약 \(hours)시간 \(minutes)분"
    }

    private func distanceText(_ meters: Double) -> String {
        meters < 1_000
            ? "약 \(Int((meters / 10).rounded()) * 10)m"
            : String(format: "약 %.1fkm", meters / 1_000)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "yyyy년 M월 d일"
        return formatter
    }()
}
