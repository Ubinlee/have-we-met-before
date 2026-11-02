import Foundation

enum InviteLink {
    private static let webBaseURL = URL(string: "https://have-we-met-before-dev.web.app/invite")!
    private static let appScheme = "havewemetbefore"

    static func shareURL(code: String) -> URL {
        var components = URLComponents(url: webBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "code", value: code)]
        return components.url!
    }

    static func inviteCode(from url: URL) -> String? {
        let isAppLink = url.scheme?.lowercased() == appScheme
            && url.host?.lowercased() == "invite"
        let isWebLink = ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            && url.host?.lowercased() == webBaseURL.host?.lowercased()
            && url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "invite"

        guard isAppLink || isWebLink,
              let rawCode = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "code" })?
                .value else {
            return nil
        }

        let normalized = rawCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .filter { $0.isLetter || $0.isNumber }
        return normalized.count == 6 ? normalized : nil
    }
}
