import MapKit
import SwiftUI

struct ResultView: View {
    let result: DestinyScoreResult
    let firstMetDate: Date
    var firstNickname: String = "나"
    var secondNickname: String = "친구"
    @State private var placeNames: [String: String] = [:]

    private var matches: [TrajectoryIntersection] { result.rankedIntersections }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                hero
                VStack(alignment: .leading, spacing: 24) {
                    if let first = matches.first {
                        closestMoment(first)
                        Divider()
                        otherMoments
                    } else {
                        emptyResult
                    }
                    ShareLink(item: shareText) {
                        Text("공유하기")
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                    Text("홈으로")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AppTheme.secondaryText)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 28)
            }
        }
        .background(AppTheme.background)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: matches.map(\.id)) { await resolvePlaceNames() }
    }

    private var hero: some View {
        VStack(spacing: 18) {
            Text("\(firstNickname)님과 \(secondNickname)님")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
            Text(result.relationshipLabel)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
            ZStack {
                Circle().stroke(.white.opacity(0.25), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: CGFloat(result.score) / 100)
                    .stroke(.white, style: StrokeStyle(lineWidth: 10, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text("\(result.score)")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                    Text("운명지수").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.white)
            }
            .frame(width: 168, height: 168)
            Text(heroMessage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 30)
        .padding(.bottom, 32)
        .background(
            LinearGradient(
                colors: [AppTheme.primary, Color(red: 155 / 255, green: 134 / 255, blue: 240 / 255)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private func closestMoment(_ match: TrajectoryIntersection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("가장 가까웠던 날")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppTheme.primary)
            Text(Self.dateFormatter.string(from: match.occurredAt))
                .font(.system(size: 20, weight: .bold))
            Text(placeNames[match.id] ?? "위치 이름을 확인하는 중…")
                .font(.system(size: 14))
                .foregroundStyle(AppTheme.secondaryText)
            approximateMap(match)
            Text("정확한 위치 대신 대략적인 범위만 보여 줘요")
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.secondaryText)
            HStack(spacing: 20) {
                metric("시간 차이", timeText(match.timeDifference))
                Divider().frame(height: 32)
                metric("거리 차이", distanceText(match.distanceMeters))
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
            latitudinalMeters: 1_200,
            longitudinalMeters: 1_200
        )
        return Map(initialPosition: .region(region), interactionModes: []) {
            MapCircle(center: coordinate, radius: 500)
                .foregroundStyle(AppTheme.primary.opacity(0.17))
                .stroke(AppTheme.primary.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [4]))
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .frame(height: 169)
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder
    private var otherMoments: some View {
        if matches.count > 1 {
            VStack(alignment: .leading, spacing: 14) {
                Text("다른 순간들")
                    .font(.system(size: 14, weight: .bold))
                ForEach(Array(matches.dropFirst().enumerated()), id: \.element.id) { _, match in
                    HStack(alignment: .top, spacing: 14) {
                        Circle()
                            .fill(AppTheme.background)
                            .stroke(AppTheme.primary, lineWidth: 2)
                            .frame(width: 10, height: 10)
                            .padding(.top, 4)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(Self.dateFormatter.string(from: match.occurredAt)) · \(placeNames[match.id] ?? "위치 확인 중")")
                                .font(.system(size: 13, weight: .bold))
                            Text("시간 차이 \(timeText(match.timeDifference)) · 거리 \(distanceText(match.distanceMeters))")
                                .font(.system(size: 12))
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                    }
                }
            }
        }
    }

    private var emptyResult: some View {
        VStack(spacing: 14) {
            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(AppTheme.primary)
            Text("아직 접점 못 찾은 사이")
                .font(.system(size: 20, weight: .bold))
            Text("기준에 맞는 교차 기록은 없었어요. 사진 위치 정보가 더 쌓이면 다시 발견될 수도 있어요.")
                .font(.system(size: 13))
                .foregroundStyle(AppTheme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
            Text(value).font(.system(size: 16, weight: .bold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heroMessage: String {
        switch result.closestIntersection?.strength {
        case .strong: "같은 3시간 구간, 약 1km 안에 있었어요"
        case .close: "비슷한 시간에 가까운 길을 지났어요"
        case .loose: "같은 날 가까운 지역에 있었어요"
        case nil: "아직 조건에 맞는 기록을 찾지 못했어요"
        }
    }

    private func resolvePlaceNames() async {
        for match in matches where placeNames[match.id] == nil {
            let name = await ApproximatePlaceResolver.name(
                latitude: match.approximateLatitude,
                longitude: match.approximateLongitude
            )
            guard !Task.isCancelled else { return }
            placeNames[match.id] = name
        }
    }

    private var shareText: String {
        "\(firstNickname)와 \(secondNickname)는 \(result.relationshipLabel)! 운명지수 \(result.score)점 #본적있나"
    }

    private func timeText(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3_600
        let minutes = (Int(seconds) % 3_600) / 60
        if hours == 0 { return minutes == 0 ? "같은 3시간 구간" : "약 \(minutes)분" }
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
