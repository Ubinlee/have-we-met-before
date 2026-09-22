import SwiftUI

struct ResultView: View {
    let result: DestinyScoreResult
    let firstMetDate: Date

    private var hasIntersection: Bool {
        result.closestIntersection != nil
    }

    private var baseScore: Int {
        guard let strength = result.closestIntersection?.strength else { return 0 }
        switch strength {
        case .strong: return 70
        case .close: return 50
        case .loose: return 30
        }
    }

    private var repeatedScore: Int {
        max(0, result.score - baseScore)
    }

    private var shareText: String {
        if hasIntersection {
            "처음 만나기 전, 우리는 이미 (result.totalIntersectionDayCount)일이나 스칠 뻔했대요. 운명 점수 (result.score)점! #본적있나"
        } else {
            "처음 만나기 전 우리의 사진 기록을 비교해 봤어요. 이번에는 스친 흔적을 찾지 못했어요. #본적있나"
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                hero
                closestMomentCard
                scoreBreakdownCard
                privacyNote

                ShareLink(item: shareText) {
                    Label("결과 공유하기", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("우리의 교차 기록")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var hero: some View {
        VStack(spacing: 16) {
            Text(hasIntersection ? "우리는 이미 스치고 있었어요" : "아직 스친 흔적은 없어요")
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            ZStack {
                Circle()
                    .stroke(.tint.opacity(0.12), lineWidth: 14)

                Circle()
                    .trim(from: 0, to: Double(result.score) / 100)
                    .stroke(
                        .tint,
                        style: StrokeStyle(lineWidth: 14, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 2) {
                    Text("운명 점수")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(result.score)")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                    Text("점")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 180, height: 180)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("운명 점수 \(result.score)점")

            Text("처음 알게 된 날인 \(Self.localDateFormatter.string(from: firstMetDate))보다 이전 사진만 비교했어요.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var closestMomentCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("가장 가까웠던 순간", systemImage: "sparkles")
                .font(.headline)

            if let closest = result.closestIntersection {
                Text(Self.utcDateFormatter.string(from: closest.occurredAt))
                    .font(.title3.bold())

                Text(momentMessage(for: closest.strength))
                    .font(.body)

                HStack(spacing: 8) {
                    Image(systemName: strengthSymbol(for: closest.strength))
                    Text(strengthLabel(for: closest.strength))
                        .fontWeight(.semibold)
                }
                .font(.subheadline)
                .foregroundStyle(.tint)
            } else {
                Text("두 사람의 기록에서 같은 날 가까운 지역에 있었던 흔적을 찾지 못했어요.")
                    .foregroundStyle(.secondary)
            }
        }
        .resultCardStyle()
    }

    private var scoreBreakdownCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("점수는 이렇게 나왔어요", systemImage: "chart.bar.xaxis")
                .font(.headline)

            ScoreRow(
                title: "가장 강한 교차",
                detail: result.closestIntersection.map { strengthLabel(for: $0.strength) } ?? "발견되지 않음",
                score: baseScore
            )

            Divider()

            ScoreRow(
                title: "반복해서 스친 날",
                detail: result.additionalIntersectionDayCount > 0
                    ? "첫날 외 \(result.additionalIntersectionDayCount)일"
                    : "추가로 겹친 날 없음",
                score: repeatedScore
            )

            Divider()

            HStack {
                Text("총 \(result.totalIntersectionDayCount)일의 교차 기록")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(result.score)점")
                    .font(.headline)
                    .foregroundStyle(.tint)
            }
        }
        .resultCardStyle()
    }

    private var privacyNote: some View {
        Label {
            Text("사진 원본과 정확한 좌표는 공유하지 않았어요. 약 1km 지역과 3시간 구간으로 흐린 기록을 비교한 재미 요소예요.")
        } icon: {
            Image(systemName: "lock.shield")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    private func strengthLabel(for strength: IntersectionStrength) -> String {
        switch strength {
        case .strong: "같은 시간대 · 같은 지역"
        case .close: "가까운 시간대 · 인접 지역"
        case .loose: "같은 날 · 가까운 지역"
        }
    }

    private func strengthSymbol(for strength: IntersectionStrength) -> String {
        switch strength {
        case .strong: "bolt.heart.fill"
        case .close: "point.3.connected.trianglepath.dotted"
        case .loose: "location.fill"
        }
    }

    private func momentMessage(for strength: IntersectionStrength) -> String {
        switch strength {
        case .strong:
            "두 사람 모두 같은 시간대에 같은 지역에 있었을 가능성이 있어요."
        case .close:
            "서로 가까운 시간대에 인접한 지역을 지나갔을 가능성이 있어요."
        case .loose:
            "같은 날, 가까운 지역에 각자의 흔적을 남겼어요."
        }
    }

    private static let localDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()

    private static let utcDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()
}

private struct ScoreRow: View {
    let title: String
    let detail: String
    let score: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("+\(score)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(score > 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
    }
}

private extension View {
    func resultCardStyle() -> some View {
        padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }
}
