import SwiftUI

enum AppTheme {
    static let background = Color(red: 249 / 255, green: 248 / 255, blue: 252 / 255)
    static let primary = Color(red: 110 / 255, green: 82 / 255, blue: 217 / 255)
    static let primarySoft = Color(red: 239 / 255, green: 235 / 255, blue: 251 / 255)
    static let text = Color(red: 19 / 255, green: 16 / 255, blue: 28 / 255)
    static let secondaryText = Color(red: 102 / 255, green: 97 / 255, blue: 117 / 255)
    static let divider = Color(red: 227 / 255, green: 222 / 255, blue: 237 / 255)
}

struct FlowScreen<Content: View>: View {
    let title: String?
    let message: String?
    let backAction: (() -> Void)?
    let content: Content

    init(
        title: String? = nil,
        message: String? = nil,
        backAction: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.message = message
        self.backAction = backAction
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let backAction {
                Button(action: backAction) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 28, height: 28, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.text)
                .padding(.bottom, 20)
            }

            if let title {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(AppTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let message {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineSpacing(4)
                    .padding(.top, 8)
            }

            content
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppTheme.background.ignoresSafeArea())
    }
}

struct PrimaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(AppTheme.primary.opacity(configuration.isPressed ? 0.78 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct SecondaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(AppTheme.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(AppTheme.primarySoft.opacity(configuration.isPressed ? 0.7 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct BottomActions<Primary: View, Secondary: View>: View {
    let primary: Primary
    let secondary: Secondary

    var body: some View {
        VStack(spacing: 8) {
            primary
            secondary
        }
        .frame(maxWidth: .infinity)
    }
}

struct InfoCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(AppTheme.divider, lineWidth: 1)
            }
    }
}

extension IntersectionStrength {
    var relationshipLabel: String {
        switch self {
        case .strong: "마주쳤을지도 모르는 사이"
        case .close: "발길이 겹쳤던 사이"
        case .loose: "근처에 있었던 사이"
        }
    }
}

extension DestinyScoreResult {
    var relationshipLabel: String {
        closestIntersection?.strength.relationshipLabel ?? "아직 접점 못 찾은 사이"
    }
}
