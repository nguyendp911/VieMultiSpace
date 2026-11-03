import SwiftUI
import WebKit
import LocalAuthentication

enum SpacePlatform: String, Codable, CaseIterable, Identifiable {
    case facebook = "Facebook"
    case instagram = "Instagram"
    case tiktok = "TikTok"
    case x = "X"
    case website = "Website"

    var id: String { rawValue }

    var home: String {
        switch self {
        case .facebook: return "https://www.facebook.com/"
        case .instagram: return "https://www.instagram.com/"
        case .tiktok: return "https://www.tiktok.com/"
        case .x: return "https://x.com/"
        case .website: return "https://"
        }
    }

    var icon: String {
        switch self {
        case .facebook: return "person.2.fill"
        case .instagram: return "camera.fill"
        case .tiktok: return "play.rectangle.fill"
        case .x: return "bubble.left.fill"
        case .website: return "globe"
        }
    }

    var color: Color {
        switch self {
        case .facebook: return .blue
        case .instagram: return .pink
        case .tiktok: return .cyan
        case .x: return .gray
        case .website: return .indigo
        }
    }
}

struct Space: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var platform: SpacePlatform
    var url: String
}

enum SpaceError: LocalizedError {
    case invalidName
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .invalidName: return "Bạn cần nhập tên cho không gian."
        case .invalidURL: return "Chỉ chấp nhận địa chỉ HTTPS hợp lệ."
        }
    }
}

@MainActor
final class SpaceLibrary: ObservableObject {
    @Published private(set) var spaces: [Space] = []
    private let saveKey = "vie.multispace.profiles.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: saveKey),
           let profiles = try? JSONDecoder().decode([Space].self, from: data) {
            spaces = profiles
        }
    }

    func add(name: String, platform: SpacePlatform, url: String) throws {
        let safeName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeName.isEmpty else { throw SpaceError.invalidName }
        guard let validated = Self.safeURL(url) else { throw SpaceError.invalidURL }
        let space = Space(name: safeName, platform: platform, url: validated.absoluteString)
        _ = WKWebsiteDataStore(forIdentifier: space.id)
        spaces.append(space)
        persist()
    }

    func rename(_ space: Space, to value: String) {
        let safeName = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeName.isEmpty,
              let index = spaces.firstIndex(where: { $0.id == space.id }) else { return }
        spaces[index].name = safeName
        persist()
    }

    func delete(_ space: Space) async throws {
        // Do not keep this profile's WKWebView open while removing its store.
        try await WKWebsiteDataStore.remove(forIdentifier: space.id)
        spaces.removeAll { $0.id == space.id }
        SecureLoginStore.remove(space.id)
        var stored = UserDefaults.standard.dictionary(forKey: launchKey) as? [String: String] ?? [:]
        stored.removeValue(forKey: space.id.uuidString)
        UserDefaults.standard.set(stored, forKey: launchKey)
        persist()
    }

    func clearData(_ space: Space) async {
        let store = WKWebsiteDataStore(forIdentifier: space.id)
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                               modifiedSince: .distantPast)
    }

    static func safeURL(_ input: String) -> URL? {
        guard let components = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url else { return nil }
        return url
    }

    // Shared navigation targets are local to this phone and do not store logins.
    private let launchKey = "vie.multispace.lastURL.v1"

    func lastPage(for space: Space) -> URL? {
        let stored = UserDefaults.standard.dictionary(forKey: launchKey) as? [String: String] ?? [:]
        return stored[space.id.uuidString].flatMap(Self.safeURL)
    }

    func remember(_ url: URL, for space: Space) {
        guard Self.safeURL(url.absoluteString) != nil else { return }
        var stored = UserDefaults.standard.dictionary(forKey: launchKey) as? [String: String] ?? [:]
        stored[space.id.uuidString] = url.absoluteString
        UserDefaults.standard.set(stored, forKey: launchKey)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(spaces) {
            UserDefaults.standard.set(data, forKey: saveKey)
        }
    }
}

@main
struct VieMultiSpaceApp: App {
    @StateObject private var library = SpaceLibrary()

    var body: some Scene {
        WindowGroup {
            SpaceDashboard()
                .environmentObject(library)
        }
    }
}
