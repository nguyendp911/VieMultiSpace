import Foundation
import Security

// MARK: - Cấu hình Supabase (URL + anon key là thông tin công khai theo thiết kế của Supabase)

enum ExchangeConfig {
    private static let urlKey = "vie.exchange.supabase.url"
    private static let anonKeyKey = "vie.exchange.supabase.anonKey"
    private static let nameKey = "vie.exchange.displayName"
    private static let spaceKey = "vie.exchange.actingSpaceId"

    static var supabaseURL: String {
        get { UserDefaults.standard.string(forKey: urlKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: urlKey) }
    }

    static var anonKey: String {
        get { UserDefaults.standard.string(forKey: anonKeyKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: anonKeyKey) }
    }

    static var displayName: String {
        get { UserDefaults.standard.string(forKey: nameKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: nameKey) }
    }

    static var defaultSpaceId: UUID? {
        get { UserDefaults.standard.string(forKey: spaceKey).flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: spaceKey) }
    }

    static var isConfigured: Bool {
        guard let u = URL(string: supabaseURL), u.scheme == "https", u.host != nil else { return false }
        return !anonKey.isEmpty
    }
}

// MARK: - Lỗi

enum ExchangeError: LocalizedError {
    case notConfigured
    case auth(String)
    case server(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Chưa cấu hình máy chủ Supabase."
        case .auth(let m): return "Đăng nhập máy chủ thất bại: \(m)"
        case .server(let code): return Self.friendly(code)
        case .network(let m): return "Lỗi mạng: \(m)"
        }
    }

    private static func friendly(_ raw: String) -> String {
        let map: [(String, String)] = [
            ("ALREADY_WAITING", "Bạn đang có một yêu cầu chờ. Hãy hủy hoặc chờ có người nhận trước khi tạo yêu cầu mới."),
            ("DAILY_LIMIT", "Bạn đã dùng hết hạn mức yêu cầu trong 24 giờ qua."),
            ("TOO_MANY_ACTIVE", "Bạn đang có quá nhiều yêu cầu chưa hoàn tất."),
            ("ALREADY_TAKEN", "Yêu cầu này vừa có người khác nhận."),
            ("EXPIRED", "Yêu cầu này đã hết hạn."),
            ("OWN_REQUEST", "Không thể tự nhận yêu cầu của chính mình."),
            ("SAME_POST", "Hai bên đang dùng cùng một bài viết. Hãy dán bài viết của riêng bạn."),
            ("NOT_FOUND", "Không tìm thấy yêu cầu."),
            ("exchange_post_id_format", "ID bài viết không hợp lệ."),
            ("exchange_post_url_format", "Link phải là link Facebook (https://...).")
        ]
        for (key, text) in map where raw.contains(key) { return text }
        return raw
    }
}

// MARK: - Mô hình dữ liệu trả về từ RPC

struct WaitingExchange: Codable, Identifiable, Hashable {
    let id: UUID
    let displayName: String
    let postUrl: String
    let reaction: String
    let createdAt: Date
}

struct MyExchange: Codable, Identifiable, Hashable {
    let id: UUID
    let status: String
    let postUrl: String
    let postId: String
    let reaction: String
    let displayName: String
    let createdAt: Date
    let expiresAt: Date
    let taskStatus: String
    let taskMessage: String?
    let partnerDisplayName: String?
    let partnerPostUrl: String?
    let partnerPostId: String?
    let partnerReaction: String?
    let partnerTaskStatus: String?
}

// MARK: - Lưu phiên đăng nhập trong Keychain

private enum ExchangeSessionStore {
    private static let service = "vn.vie.multispace.exchange"
    private static let account = "supabase_session"

    struct Stored: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        var baseURL: String
    }

    static func save(_ s: Stored) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load() -> Stored? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var raw: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &raw) == errSecSuccess,
              let data = raw as? Data else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Client Supabase (REST thuần, không cần SDK)

actor ExchangeBackend {
    static let shared = ExchangeBackend()

    private var session: ExchangeSessionStore.Stored?
    private let urlSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        return URLSession(configuration: cfg)
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let str = try decoder.singleValueContainer().decode(String.self)
            let f1 = ISO8601DateFormatter()
            f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f1.date(from: str) { return d }
            let f2 = ISO8601DateFormatter()
            f2.formatOptions = [.withInternetDateTime]
            if let d = f2.date(from: str) { return d }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Bad date: \(str)")
            )
        }
        return d
    }()

    // MARK: Auth (đăng nhập ẩn danh theo thiết bị)

    func resetSession() {
        session = nil
        ExchangeSessionStore.clear()
    }

    private func baseURL() throws -> URL {
        guard ExchangeConfig.isConfigured, let u = URL(string: ExchangeConfig.supabaseURL) else {
            throw ExchangeError.notConfigured
        }
        return u
    }

    private func ensureSession(forceNew: Bool = false) async throws -> String {
        let base = try baseURL()
        if session == nil { session = ExchangeSessionStore.load() }

        // Đổi sang máy chủ khác thì bỏ phiên cũ
        if let s = session, s.baseURL != base.absoluteString { resetSession() }

        if !forceNew, let s = session, s.expiresAt.timeIntervalSinceNow > 60 {
            return s.accessToken
        }

        if let s = session, !s.refreshToken.isEmpty {
            if let refreshed = try? await authRequest(
                path: "/auth/v1/token?grant_type=refresh_token",
                body: ["refresh_token": s.refreshToken],
                base: base
            ) {
                session = refreshed
                ExchangeSessionStore.save(refreshed)
                return refreshed.accessToken
            }
        }

        // Đăng nhập ẩn danh mới
        let fresh = try await authRequest(path: "/auth/v1/signup", body: [:], base: base)
        session = fresh
        ExchangeSessionStore.save(fresh)
        return fresh.accessToken
    }

    private func authRequest(path: String, body: [String: String], base: URL) async throws -> ExchangeSessionStore.Stored {
        guard let url = URL(string: base.absoluteString + path) else { throw ExchangeError.notConfigured }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(ExchangeConfig.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await urlSession.data(for: req) }
        catch { throw ExchangeError.network(error.localizedDescription) }

        guard let http = resp as? HTTPURLResponse,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExchangeError.auth("Phản hồi không hợp lệ")
        }
        guard (200...299).contains(http.statusCode),
              let access = json["access_token"] as? String else {
            let msg = (json["msg"] as? String) ?? (json["error_description"] as? String)
                ?? (json["message"] as? String) ?? "HTTP \(http.statusCode)"
            throw ExchangeError.auth(msg)
        }
        let refresh = json["refresh_token"] as? String ?? ""
        let expiresIn = (json["expires_in"] as? Double) ?? 3600
        return .init(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(expiresIn),
            baseURL: base.absoluteString
        )
    }

    // MARK: RPC

    private func rpc(_ name: String, params: [String: Any] = [:], retryOnAuth: Bool = true) async throws -> Data {
        let base = try baseURL()
        let token = try await ensureSession()
        guard let url = URL(string: base.absoluteString + "/rest/v1/rpc/\(name)") else {
            throw ExchangeError.notConfigured
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(ExchangeConfig.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: params)

        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await urlSession.data(for: req) }
        catch { throw ExchangeError.network(error.localizedDescription) }

        guard let http = resp as? HTTPURLResponse else { throw ExchangeError.network("Không có phản hồi") }
        if http.statusCode == 401 && retryOnAuth {
            _ = try await ensureSession(forceNew: true)
            return try await rpc(name, params: params, retryOnAuth: false)
        }
        guard (200...299).contains(http.statusCode) else {
            var message = "HTTP \(http.statusCode)"
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                message = (json["message"] as? String) ?? (json["hint"] as? String) ?? message
            }
            throw ExchangeError.server(message)
        }
        return data
    }

    // MARK: API công khai

    func listWaiting() async throws -> [WaitingExchange] {
        let data = try await rpc("list_waiting_requests")
        return try decoder.decode([WaitingExchange].self, from: data)
    }

    func myExchanges() async throws -> [MyExchange] {
        let data = try await rpc("get_my_exchanges")
        return try decoder.decode([MyExchange].self, from: data)
    }

    func createRequest(postURL: String, postId: String, reaction: String, displayName: String) async throws {
        _ = try await rpc("create_exchange_request", params: [
            "p_post_url": postURL,
            "p_post_id": postId,
            "p_reaction": reaction,
            "p_display_name": displayName
        ])
    }

    func accept(targetId: UUID, postURL: String, postId: String, reaction: String, displayName: String) async throws {
        _ = try await rpc("accept_exchange_request", params: [
            "p_target_id": targetId.uuidString.lowercased(),
            "p_post_url": postURL,
            "p_post_id": postId,
            "p_reaction": reaction,
            "p_display_name": displayName
        ])
    }

    func cancel(requestId: UUID) async throws {
        _ = try await rpc("cancel_exchange_request", params: ["p_request_id": requestId.uuidString.lowercased()])
    }

    func reportTask(requestId: UUID, success: Bool, message: String) async throws {
        _ = try await rpc("report_exchange_task", params: [
            "p_request_id": requestId.uuidString.lowercased(),
            "p_success": success,
            "p_message": message
        ])
    }
}
