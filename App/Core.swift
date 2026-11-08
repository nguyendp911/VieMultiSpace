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
    var id: UUID
    var name: String
    var platform: SpacePlatform
    var url: String
    var proxy: SpaceProxy?
    var fingerprint: SpaceFingerprint?

    init(
        id: UUID = UUID(),
        name: String,
        platform: SpacePlatform,
        url: String,
        proxy: SpaceProxy? = nil,
        fingerprint: SpaceFingerprint? = nil
    ) {
        self.id = id
        self.name = name
        self.platform = platform
        self.url = url
        self.proxy = proxy
        self.fingerprint = fingerprint ?? SpaceFingerprint.defaultFor(spaceId: id)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, platform, url, proxy, fingerprint
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedId = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        id = decodedId
        name = try container.decode(String.self, forKey: .name)
        platform = try container.decode(SpacePlatform.self, forKey: .platform)
        url = try container.decode(String.self, forKey: .url)
        proxy = try container.decodeIfPresent(SpaceProxy.self, forKey: .proxy)
        fingerprint = try container.decodeIfPresent(SpaceFingerprint.self, forKey: .fingerprint)
            ?? SpaceFingerprint.defaultFor(spaceId: decodedId)
    }
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
            // Tự động gán Dấu vân tay riêng cho bất kỳ không gian nào chưa có
            var updated = false
            self.spaces = profiles.map { sp in
                var mod = sp
                if mod.fingerprint == nil {
                    mod.fingerprint = SpaceFingerprint.defaultFor(spaceId: sp.id)
                    updated = true
                }
                return mod
            }
            if updated {
                persist()
            }
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

    func delete(_ space: Space) async {
        // 1. Xóa toàn bộ dữ liệu web (Cookie, Cache, Storage, IndexedDB...) an toàn, không bị crash unhandled NSException
        let store = WKWebsiteDataStore(forIdentifier: space.id)
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)

        // 2. Loại bỏ khỏi danh sách không gian
        spaces.removeAll { $0.id == space.id }

        // 3. Xóa dữ liệu xác thực Keychain và Token Cache
        SecureLoginStore.remove(space.id)
        WebSessionTokenCache.clear(for: space.id)

        // 4. Xóa URL trang gần nhất
        var stored = UserDefaults.standard.dictionary(forKey: launchKey) as? [String: String] ?? [:]
        stored.removeValue(forKey: space.id.uuidString)
        UserDefaults.standard.set(stored, forKey: launchKey)

        // 5. Lưu lại danh sách không gian
        persist()
    }

    func clearData(_ space: Space) async {
        let store = WKWebsiteDataStore(forIdentifier: space.id)
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                               modifiedSince: .distantPast)
        WebSessionTokenCache.clear(for: space.id)
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

    // MARK: - Proxy & Fingerprint Management

    func updateSpaceProxy(_ spaceId: UUID, proxy: SpaceProxy?) {
        guard let index = spaces.firstIndex(where: { $0.id == spaceId }) else { return }
        spaces[index].proxy = proxy
        persist()
    }

    func updateSpaceFingerprint(_ spaceId: UUID, fingerprint: SpaceFingerprint) {
        guard let index = spaces.firstIndex(where: { $0.id == spaceId }) else { return }
        spaces[index].fingerprint = fingerprint
        persist()
    }

    func batchApplyProxies(assignments: [(spaceId: UUID, proxy: SpaceProxy?)]) {
        var didChange = false
        for (sid, pxy) in assignments {
            if let index = spaces.firstIndex(where: { $0.id == sid }) {
                spaces[index].proxy = pxy
                didChange = true
            }
        }
        if didChange {
            persist()
        }
    }

    func batchClearProxies(for spaceIds: Set<UUID>) {
        var didChange = false
        for sid in spaceIds {
            if let index = spaces.firstIndex(where: { $0.id == sid }) {
                spaces[index].proxy = nil
                didChange = true
            }
        }
        if didChange {
            persist()
        }
    }

    func batchRegenerateFingerprints(for spaceIds: Set<UUID>, preset: DeviceModelPreset? = nil) {
        var didChange = false
        for sid in spaceIds {
            if let index = spaces.firstIndex(where: { $0.id == sid }) {
                spaces[index].fingerprint = SpaceFingerprint.generateRandom(preset: preset)
                didChange = true
            }
        }
        if didChange {
            persist()
        }
    }

    func move(from source: IndexSet, to destination: Int) {
        spaces.move(fromOffsets: source, toOffset: destination)
        persist()
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
