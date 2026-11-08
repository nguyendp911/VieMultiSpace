import SwiftUI
import Security
import CryptoKit
import WebKit
import UIKit
import UniformTypeIdentifiers

// MARK: - Models

struct SpaceLogin: Codable {
    var user: String
    var password: String
    var totp: String
    var machineId: String = ""
    var deviceId: String? = nil
    var adid: String? = nil
    var simSerial: String? = nil
    var pendingFirstFactor: String? = nil
    var pendingUid: String? = nil
}

struct FacebookCookieItem: Codable, Hashable, Identifiable {
    var id: String { "\(name)@\(domain ?? ".facebook.com")" }
    var name: String
    var value: String
    var domain: String?
    var path: String?
}

struct ConvertedTokenRecord: Codable, Hashable, Identifiable {
    var id: String { appKey }
    var appKey: String
    var appName: String
    var appId: String
    var tokenPrefix: String
    var accessToken: String
    var cookieString: String
    var cookies: [FacebookCookieItem]
}

struct SpaceTokenVault: Codable {
    var uid: String
    var originalPrefix: String
    var originalToken: String
    var cookieString: String
    var cookies: [FacebookCookieItem]
    var convertedTokens: [String: ConvertedTokenRecord]
    var updatedAt: Date
}

struct SpaceVaultSummary: Codable {
    var hasCredentials: Bool = false
    var hasToken: Bool = false
    var tokenPrefix: String = ""
    var convertedCount: Int = 0
    var hasCookies: Bool = false
    var updatedAt: Date?
}

enum SpaceLoginError: LocalizedError {
    case invalid
    case missing
    case missingToken
    case invalidSeed
    case encryptionFailed(String)
    case apiError(String)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalid: return "Nhập email / UID và mật khẩu."
        case .missing: return "Chưa lưu thông tin đăng nhập cho không gian này."
        case .missingToken: return "Chưa lưu Access Token hoặc Cookie cho không gian này."
        case .invalidSeed: return "Khóa TOTP Base32 hoặc mã 6 số không hợp lệ."
        case .encryptionFailed(let msg): return "Lỗi mã hóa mật khẩu: \(msg)"
        case .apiError(let msg): return msg
        case .keychain(let code): return "Keychain báo lỗi \(code)."
        }
    }
}

// MARK: - TOTP Generator

enum SwiftTOTP {
    static func decode(_ raw: String) -> Data? {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        let input = raw.uppercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "=" }
        guard !input.isEmpty else { return nil }
        var value: UInt64 = 0
        var bits = 0
        var bytes: [UInt8] = []
        for c in input {
            guard let n = chars.firstIndex(of: c) else { return nil }
            value = (value << 5) | UInt64(n)
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((value >> bits) & 255))
                value &= (1 << bits) - 1
            }
        }
        return bytes.isEmpty ? nil : Data(bytes)
    }

    static func code(_ seedOrCode: String, at date: Date = Date()) -> String? {
        let trimmed = seedOrCode.filter { !$0.isWhitespace }
        if trimmed.count == 6, trimmed.allSatisfy(\.isNumber) {
            return trimmed
        }
        guard let data = decode(trimmed) else { return nil }
        var counter = UInt64(date.timeIntervalSince1970 / 30).bigEndian
        let message = withUnsafeBytes(of: &counter) { Data($0) }
        let mac = Array(HMAC<Insecure.SHA1>.authenticationCode(
            for: message, using: SymmetricKey(data: data)))
        let i = Int(mac[19] & 15)
        let x = (UInt32(mac[i] & 127) << 24) |
                (UInt32(mac[i+1]) << 16) |
                (UInt32(mac[i+2]) << 8) | UInt32(mac[i+3])
        return String(format: "%06d", x % 1000000)
    }
}

// MARK: - Keychain Stores (Credentials & Tokens)

enum VaultMetadataIndex {
    private static let metaKey = "vie.multispace.vault.meta.v1"

    static func get(_ id: UUID) -> SpaceVaultSummary {
        guard let data = UserDefaults.standard.data(forKey: metaKey),
              let map = try? JSONDecoder().decode([String: SpaceVaultSummary].self, from: data),
              let item = map[id.uuidString] else {
            return SpaceVaultSummary()
        }
        return item
    }

    static func update(_ id: UUID, mutate: (inout SpaceVaultSummary) -> Void) {
        var map: [String: SpaceVaultSummary] = [:]
        if let data = UserDefaults.standard.data(forKey: metaKey),
           let decoded = try? JSONDecoder().decode([String: SpaceVaultSummary].self, from: data) {
            map = decoded
        }
        var current = map[id.uuidString] ?? SpaceVaultSummary()
        mutate(&current)
        map[id.uuidString] = current
        if let encoded = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(encoded, forKey: metaKey)
        }
    }

    static func remove(_ id: UUID) {
        guard let data = UserDefaults.standard.data(forKey: metaKey),
              var map = try? JSONDecoder().decode([String: SpaceVaultSummary].self, from: data) else { return }
        map.removeValue(forKey: id.uuidString)
        if let encoded = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(encoded, forKey: metaKey)
        }
    }
}

enum SecureLoginStore {
    private static let service = "vn.vie.multispace.credentials"
    private static let tokenService = "vn.vie.multispace.tokens"

    private static func key(_ id: UUID, service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrAccount as String: id.uuidString,
         kSecAttrService as String: service]
    }

    static func save(_ record: SpaceLogin, for id: UUID) throws {
        let cleanUser = record.user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUser.isEmpty, !record.password.isEmpty else { throw SpaceLoginError.invalid }
        let cleanTotp = record.totp.filter { !$0.isWhitespace }
        if !cleanTotp.isEmpty && SwiftTOTP.code(cleanTotp) == nil {
            throw SpaceLoginError.invalidSeed
        }
        let existing = try? read(id)
        var normalized = record
        normalized.user = cleanUser
        normalized.totp = cleanTotp
        if normalized.machineId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized.machineId = existing?.machineId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? existing!.machineId
                : FacebookAPILoginClient.generateMachineId()
        }
        if normalized.deviceId?.isEmpty != false {
            normalized.deviceId = (existing?.deviceId?.isEmpty == false) ? existing!.deviceId : UUID().uuidString.lowercased()
        }
        if normalized.adid?.isEmpty != false {
            normalized.adid = (existing?.adid?.isEmpty == false) ? existing!.adid : UUID().uuidString.lowercased()
        }
        if normalized.simSerial?.isEmpty != false {
            normalized.simSerial = (existing?.simSerial?.isEmpty == false) ? existing!.simSerial : FacebookAPILoginClient.generateSimSerial()
        }
        if normalized.pendingFirstFactor == nil {
            normalized.pendingFirstFactor = existing?.pendingFirstFactor
        }
        if normalized.pendingUid == nil {
            normalized.pendingUid = existing?.pendingUid
        }
        var q = key(id, service: service)
        q[kSecValueData as String] = try JSONEncoder().encode(normalized)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemDelete(key(id, service: service) as CFDictionary)
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw SpaceLoginError.keychain(status) }

        VaultMetadataIndex.update(id) { meta in
            meta.hasCredentials = true
        }
    }

    static func read(_ id: UUID) throws -> SpaceLogin {
        var q = key(id, service: service)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var raw: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &raw)
        if status == errSecItemNotFound { throw SpaceLoginError.missing }
        guard status == errSecSuccess else { throw SpaceLoginError.keychain(status) }
        guard let data = raw as? Data else { throw SpaceLoginError.keychain(errSecDecode) }
        return try JSONDecoder().decode(SpaceLogin.self, from: data)
    }

    static func saveTokenVault(_ vault: SpaceTokenVault, for id: UUID) throws {
        var q = key(id, service: tokenService)
        q[kSecValueData as String] = try JSONEncoder().encode(vault)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemDelete(key(id, service: tokenService) as CFDictionary)
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw SpaceLoginError.keychain(status) }

        VaultMetadataIndex.update(id) { meta in
            meta.hasToken = !vault.originalToken.isEmpty || !vault.convertedTokens.isEmpty
            meta.tokenPrefix = vault.originalPrefix
            meta.convertedCount = vault.convertedTokens.count
            meta.hasCookies = !vault.cookieString.isEmpty || !vault.cookies.isEmpty
            meta.updatedAt = vault.updatedAt
        }
    }

    static func readTokenVault(_ id: UUID) throws -> SpaceTokenVault {
        var q = key(id, service: tokenService)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var raw: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &raw)
        if status == errSecItemNotFound { throw SpaceLoginError.missingToken }
        guard status == errSecSuccess else { throw SpaceLoginError.keychain(status) }
        guard let data = raw as? Data else { throw SpaceLoginError.keychain(errSecDecode) }
        return try JSONDecoder().decode(SpaceTokenVault.self, from: data)
    }

    static func removeTokenVault(_ id: UUID) {
        SecItemDelete(key(id, service: tokenService) as CFDictionary)
        VaultMetadataIndex.update(id) { meta in
            meta.hasToken = false
            meta.tokenPrefix = ""
            meta.convertedCount = 0
            meta.hasCookies = false
            meta.updatedAt = nil
        }
    }

    static func remove(_ id: UUID) {
        SecItemDelete(key(id, service: service) as CFDictionary)
        SecItemDelete(key(id, service: tokenService) as CFDictionary)
        VaultMetadataIndex.remove(id)
    }
}

// MARK: - Facebook App Token Definitions

enum FacebookAppTokens {
    struct AppInfo: Identifiable {
        let key: String
        let name: String
        let appId: String
        var id: String { key }
    }

    static let allApps: [AppInfo] = [
        AppInfo(key: "FB_ANDROID", name: "Facebook For Android", appId: "350685531728"),
        AppInfo(key: "MESSENGER_ANDROID", name: "Facebook Messenger For Android", appId: "256002347743983"),
        AppInfo(key: "FB_LITE", name: "Facebook For Lite", appId: "275254692598279"),
        AppInfo(key: "MESSENGER_LITE", name: "Facebook Messenger For Lite", appId: "200424423651082"),
        AppInfo(key: "ADS_MANAGER_ANDROID", name: "Ads Manager App For Android", appId: "438142079694454"),
        AppInfo(key: "PAGES_MANAGER_ANDROID", name: "Pages Manager For Android", appId: "121876164619130")
    ]

    static func extractTokenPrefix(_ token: String) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        for (idx, ch) in trimmed.enumerated() {
            if ch.isLowercase {
                let endIdx = trimmed.index(trimmed.startIndex, offsetBy: idx)
                return String(trimmed[..<endIdx])
            }
        }
        return String(trimmed.prefix(8))
    }

    static func parseCookieString(_ raw: String) -> [FacebookCookieItem] {
        var items: [FacebookCookieItem] = []
        for part in raw.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let eqIndex = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[..<eqIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(trimmed[trimmed.index(after: eqIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            items.append(FacebookCookieItem(name: name, value: value, domain: ".facebook.com", path: "/"))
        }
        return items
    }

    static func formatCookieString(_ cookies: [FacebookCookieItem]) -> String {
        cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}

// MARK: - Facebook Password Encryptor (#PWD_FB4A:2)

enum FacebookPasswordEncryptor {
    struct PublicKeyBundle {
        let publicKey: String
        let keyId: String
        let serverTimestamp: Int
    }

    private static func parseHTTPDate(_ header: String?) -> Int? {
        guard let header, !header.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: header) {
            return Int(date.timeIntervalSince1970)
        }
        return nil
    }

    static func getPublicKey() async throws -> PublicKeyBundle {
        let tokens = [
            "438142079694454|fc0a7caa49b192f64f6f5a6d9643bb28",
            "350685531728|62f8ce9f74b12f84c123cc23437a4a32"
        ]
        var lastError: Error?

        for token in tokens {
            do {
                var components = URLComponents(string: "https://b-graph.facebook.com/pwd_key_fetch")!
                components.queryItems = [
                    URLQueryItem(name: "version", value: "2"),
                    URLQueryItem(name: "flow", value: "CONTROLLER_INITIALIZATION"),
                    URLQueryItem(name: "method", value: "GET"),
                    URLQueryItem(name: "fb_api_req_friendly_name", value: "pwdKeyFetch"),
                    URLQueryItem(name: "fb_api_caller_class", value: "com.facebook.auth.login.AuthOperations"),
                    URLQueryItem(name: "access_token", value: token)
                ]
                guard let url = components.url else { continue }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.timeoutInterval = 15
                FacebookAPILoginClient.applyFullHeaders(to: &request, url: url)
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let pubKey = json["public_key"] as? String, !pubKey.isEmpty else {
                    continue
                }
                let keyId: String
                if let idInt = json["key_id"] as? Int {
                    keyId = String(idInt)
                } else if let idStr = json["key_id"] as? String {
                    keyId = idStr
                } else {
                    keyId = "25"
                }
                let httpResp = response as? HTTPURLResponse
                let serverTime = parseHTTPDate(httpResp?.value(forHTTPHeaderField: "Date")) ?? Int(Date().timeIntervalSince1970)
                return PublicKeyBundle(publicKey: pubKey, keyId: keyId, serverTimestamp: serverTime)
            } catch {
                lastError = error
            }
        }
        throw SpaceLoginError.encryptionFailed(lastError?.localizedDescription ?? "Không lấy được public_key từ Facebook")
    }

    static func encrypt(password: String, publicKey: String? = nil, keyId: String = "25", timestamp: Int? = nil) async throws -> (encrypted: String, serverTimestamp: Int) {
        if password.hasPrefix("#PWD_FB4A") {
            return (password, timestamp ?? Int(Date().timeIntervalSince1970))
        }
        let resolvedKey: String
        let resolvedKeyId: String
        let currentTime: Int
        if let publicKey, !publicKey.isEmpty {
            resolvedKey = publicKey
            resolvedKeyId = keyId
            currentTime = timestamp ?? Int(Date().timeIntervalSince1970)
        } else {
            let fetched = try await getPublicKey()
            resolvedKey = fetched.publicKey
            resolvedKeyId = fetched.keyId
            currentTime = timestamp ?? fetched.serverTimestamp
        }

        let pemBody = resolvedKey
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()

        guard let derData = Data(base64Encoded: pemBody) else {
            throw SpaceLoginError.encryptionFailed("Public key PEM không hợp lệ")
        }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 2048
        ]
        var secError: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(derData as CFData, attributes as CFDictionary, &secError) else {
            let errDesc = secError?.takeRetainedValue().localizedDescription ?? "SecKeyCreateWithData thất bại"
            throw SpaceLoginError.encryptionFailed(errDesc)
        }

        var randKeyBytes = [UInt8](repeating: 0, count: 32)
        var ivBytes = [UInt8](repeating: 0, count: 12)
        _ = SecRandomCopyBytes(kSecRandomDefault, randKeyBytes.count, &randKeyBytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, ivBytes.count, &ivBytes)
        let randKeyData = Data(randKeyBytes)
        let ivData = Data(ivBytes)

        guard let encryptedRandKey = SecKeyCreateEncryptedData(
            secKey,
            .rsaEncryptionPKCS1,
            randKeyData as CFData,
            &secError
        ) as Data? else {
            let errDesc = secError?.takeRetainedValue().localizedDescription ?? "RSA PKCS1 encrypt thất bại"
            throw SpaceLoginError.encryptionFailed(errDesc)
        }

        let aadData = Data(String(currentTime).utf8)
        let nonce = try AES.GCM.Nonce(data: ivData)
        let symmetricKey = SymmetricKey(data: randKeyData)
        let sealedBox = try AES.GCM.seal(
            Data(password.utf8),
            using: symmetricKey,
            nonce: nonce,
            authenticating: aadData
        )

        var buffer = Data()
        let keyIdByte = UInt8((Int(resolvedKeyId) ?? 25) & 0xFF)
        buffer.append(contentsOf: [1, keyIdByte])
        buffer.append(ivData)
        var rsaLengthLE = Int16(encryptedRandKey.count).littleEndian
        withUnsafeBytes(of: &rsaLengthLE) { buffer.append(contentsOf: $0) }
        buffer.append(encryptedRandKey)
        buffer.append(sealedBox.tag)
        buffer.append(sealedBox.ciphertext)

        let encoded = buffer.base64EncodedString()
        return ("#PWD_FB4A:2:\(currentTime):\(encoded)", currentTime)
    }
}

// MARK: - Facebook Login + 2FA + Token Converter Service

enum FacebookAPILoginClient {
    private static let apiURL = URL(string: "https://b-graph.facebook.com/auth/login")!
    private static let legacyApiURL = URL(string: "https://b-api.facebook.com/method/auth.login")!
    private static let convertURL = URL(string: "https://api.facebook.com/method/auth.getSessionforApp")!
    private static let accessToken = "350685531728|62f8ce9f74b12f84c123cc23437a4a32"
    private static let apiKey = "882a8490361da98702bf97a021ddc14d"
    private static let apiSecret = "62f8ce9f74b12f84c123cc23437a4a32"
    private static let sig = "214049b9f17c38bd767de53752b53946"

    static let userAgent = "Dalvik/2.1.0 (Linux; U; Android 9; 23113RKC6C Build/PQ3A.190705.08211809) [FBAN/FB4A;FBAV/417.0.0.33.65;FBPN/com.facebook.katana;FBLC/vi_VN;FBBV/480086274;FBCR/MobiFone;FBMF/Redmi;FBBD/Redmi;FBDV/23113RKC6C;FBSV/9;FBCA/x86:armeabi-v7a;FBDM/{density=1.5,width=1280,height=720};FB_FW/1;FBRV/0;]"

    /// Toàn bộ 17 header CHUẨN ĐÚNG TỪNG KÝ TỰ theo 1767528775-Login2FaConvertToken.py
    static let baseHeaders: [String: String] = [
        "content-type": "application/x-www-form-urlencoded",
        "x-fb-net-hni": "45201",
        "zero-rated": "0",
        "x-fb-sim-hni": "45201",
        "x-fb-connection-quality": "EXCELLENT",
        "x-fb-friendly-name": "authenticate",
        "x-fb-connection-bandwidth": "78032897",
        "x-tigon-is-retry": "False",
        "authorization": "OAuth null",
        "x-fb-connection-type": "WIFI",
        "x-fb-device-group": "3342",
        "priority": "u=3,i",
        "x-fb-http-engine": "Liger",
        "x-fb-client-ip": "True",
        "x-fb-server-cluster": "True",
        "x-fb-request-analytics-tags": "{\"network_tags\":{\"product\":\"350685531728\",\"retry_attempt\":\"0\"},\"application_tags\":\"unknown\"}",
        "user-agent": "Dalvik/2.1.0 (Linux; U; Android 9; 23113RKC6C Build/PQ3A.190705.08211809) [FBAN/FB4A;FBAV/417.0.0.33.65;FBPN/com.facebook.katana;FBLC/vi_VN;FBBV/480086274;FBCR/MobiFone;FBMF/Redmi;FBBD/Redmi;FBDV/23113RKC6C;FBSV/9;FBCA/x86:armeabi-v7a;FBDM/{density=1.5,width=1280,height=720};FB_FW/1;FBRV/0;]"
    ]

    static func applyFullHeaders(
        to request: inout URLRequest,
        url: URL,
        bodyLength: Int? = nil,
        cookieString: String? = nil,
        extraHeaders: [String: String] = [:]
    ) {
        // 1. Toàn bộ 17 header chữ thường y hệt 1767528775-Login2FaConvertToken.py
        for (k, v) in baseHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }

        // 2. Bổ sung các header HTTP tiêu chuẩn (Title-Case) như requests.Session() của Python
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("OAuth null", forHTTPHeaderField: "Authorization")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("keep-alive", forHTTPHeaderField: "Connection")

        if let host = url.host {
            request.setValue(host, forHTTPHeaderField: "Host")
        }

        if let len = bodyLength {
            request.setValue("\(len)", forHTTPHeaderField: "Content-Length")
        }

        // 3. Header Cookie phiên (tự động mang datr, fr và cookie từ request 1 sang 2FA)
        if let cookieStr = cookieString, !cookieStr.isEmpty {
            request.setValue(cookieStr, forHTTPHeaderField: "Cookie")
            request.setValue(cookieStr, forHTTPHeaderField: "cookie")
        }

        // 4. Header bổ sung nếu có
        for (k, v) in extraHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }
    }

    /// Bộ điều khiển HTTP Session tương đương `requests.Session()` trong 1767528775-Login2FaConvertToken.py:
    /// - Lưu trữ toàn bộ cookie xuyên suốt giữa request đăng nhập lần 1 và request 2FA.
    /// - Thu thập cookie từ response headers (kể cả khi Facebook trả mã lỗi HTTP 400 Bad Request / 401 Unauthorized khi yêu cầu 2FA).
    /// - Tự động đính kèm đầy đủ 100% header vào TẤT CẢ các request (đặc biệt là 2FA).
    final class SessionClient {
        let session: URLSession
        var cookies: [String: String] = [:]

        init(initialDatr: String? = nil) {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 60
            config.httpAdditionalHeaders = [
                "User-Agent": FacebookAPILoginClient.userAgent,
                "Accept": "*/*",
                "Accept-Encoding": "gzip, deflate",
                "Connection": "keep-alive"
            ]
            self.session = URLSession(configuration: config)
            if let datr = initialDatr, !datr.isEmpty {
                self.cookies["datr"] = datr
            }
        }

        func cookieHeaderString() -> String {
            cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        }

        func post(
            url: URL,
            params: [String: String],
            extraHeaders: [String: String] = [:]
        ) async throws -> [String: Any] {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 30

            let bodyData = FacebookAPILoginClient.formEncode(params)
            request.httpBody = bodyData

            FacebookAPILoginClient.applyFullHeaders(
                to: &request,
                url: url,
                bodyLength: bodyData.count,
                cookieString: cookieHeaderString(),
                extraHeaders: extraHeaders
            )

            let (respData, rawResponse) = try await session.data(for: request)

            // Trích xuất Set-Cookie từ response headers kể cả khi Facebook trả về lỗi 400/401 (cực kỳ quan trọng cho 2FA)
            if let http = rawResponse as? HTTPURLResponse {
                var headerMap: [String: String] = [:]
                for (k, v) in http.allHeaderFields {
                    if let ks = k as? String, let vs = v as? String {
                        headerMap[ks] = vs
                    }
                }
                if let targetURL = http.url {
                    let parsed = HTTPCookie.cookies(withResponseHeaderFields: headerMap, for: targetURL)
                    for c in parsed {
                        self.cookies[c.name] = c.value
                    }
                }
                if let setCookieHeader = headerMap["Set-Cookie"] ?? headerMap["set-cookie"] {
                    extractCookiesFromRawHeader(setCookieHeader)
                }
            }

            guard let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any] else {
                let text = String(data: respData, encoding: .utf8) ?? ""
                let code = (rawResponse as? HTTPURLResponse)?.statusCode ?? 0
                throw SpaceLoginError.apiError("Phản hồi máy chủ (HTTP \(code)) không phải JSON hợp lệ: \(text.prefix(200))")
            }

            // Thu thập thêm session_cookies nếu phản hồi JSON chứa sẵn
            if let rawCookies = json["session_cookies"] as? [[String: Any]] {
                for c in rawCookies {
                    if let name = c["name"] as? String, let val = c["value"] as? String {
                        self.cookies[name] = val
                    }
                }
            }

            return json
        }

        private func extractCookiesFromRawHeader(_ header: String) {
            let parts = header.components(separatedBy: ",")
            for part in parts {
                let pairs = part.components(separatedBy: ";")
                if let first = pairs.first {
                    let kv = first.split(separator: "=", maxSplits: 1).map(String.init)
                    if kv.count == 2 {
                        let k = kv[0].trimmingCharacters(in: .whitespacesAndNewlines)
                        let v = kv[1].trimmingCharacters(in: .whitespacesAndNewlines)
                        let lower = k.lowercased()
                        if !k.isEmpty && !v.isEmpty && lower != "path" && lower != "domain" && lower != "expires" && lower != "max-age" && lower != "samesite" {
                            self.cookies[k] = v
                        }
                    }
                }
            }
        }
    }

    static func generateMachineId() -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<24).compactMap { _ in chars.randomElement() })
    }

    static func generateSimSerial() -> String {
        randomDigits(20)
    }

    private static func randomDigits(_ count: Int) -> String {
        let digits = Array("0123456789")
        return String((0..<count).compactMap { _ in digits.randomElement() })
    }

    private static func md5Hex(_ string: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func signedParams(_ params: [String: String], secret: String = apiSecret) -> [String: String] {
        var result = params
        result.removeValue(forKey: "sig")
        let joined = result.keys.sorted().map { "\($0)=\(result[$0] ?? "")" }.joined()
        result["sig"] = md5Hex(joined + secret)
        return result
    }

    private static func formEncode(_ params: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._* ")
        let pairs = params.keys.sorted().map { key -> String in
            let value = params[key] ?? ""
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed)?.replacingOccurrences(of: " ", with: "+") ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed)?.replacingOccurrences(of: " ", with: "+") ?? value
            return "\(k)=\(v)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }

    private static func sanitizeInput(
        uidPhoneMail: String,
        password: String,
        totpSecretOrCode: String
    ) -> (user: String, pass: String, totp: String) {
        let invisibleChars = CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{FEFF}\r\n")
        var rawUser = uidPhoneMail.trimmingCharacters(in: .whitespacesAndNewlines.union(invisibleChars))
        var rawPass = password.trimmingCharacters(in: CharacterSet.newlines.union(invisibleChars))
        var rawTotp = totpSecretOrCode.trimmingCharacters(in: .whitespacesAndNewlines.union(invisibleChars))

        // Nếu người dùng dán nhầm chuỗi "uid|pass|2fa" vào ô tài khoản
        if rawUser.contains("|") {
            let parts = rawUser.components(separatedBy: "|").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines.union(invisibleChars))
            }
            if parts.count >= 2 {
                rawUser = parts[0]
                if rawPass.isEmpty { rawPass = parts[1] }
                if rawTotp.isEmpty, parts.count >= 3 { rawTotp = parts[2] }
            }
        }
        return (rawUser, rawPass, rawTotp)
    }

    private static func extractCookies(from json: [String: Any]) -> (items: [FacebookCookieItem], cookieString: String) {
        var items: [FacebookCookieItem] = []
        if let rawCookies = json["session_cookies"] as? [[String: Any]] {
            for c in rawCookies {
                guard let name = c["name"] as? String,
                      let value = c["value"] as? String else { continue }
                let domain = (c["domain"] as? String) ?? ".facebook.com"
                let path = (c["path"] as? String) ?? "/"
                items.append(FacebookCookieItem(name: name, value: value, domain: domain, path: path))
            }
        }
        return (items, FacebookAppTokens.formatCookieString(items))
    }

    static func convertToken(
        _ accessToken: String,
        app: FacebookAppTokens.AppInfo,
        client: SessionClient? = nil
    ) async -> ConvertedTokenRecord? {
        let endpoints = [
            "https://api.facebook.com/method/auth.getSessionforApp",
            "https://b-api.facebook.com/method/auth.getSessionforApp"
        ]
        let bodyParams = [
            "access_token": accessToken,
            "format": "json",
            "new_app_id": app.appId,
            "generate_session_cookies": "1"
        ]

        let sessionClient = client ?? SessionClient()

        for ep in endpoints {
            guard let url = URL(string: ep) else { continue }
            do {
                let json = try await sessionClient.post(url: url, params: bodyParams)
                guard let token = json["access_token"] as? String, !token.isEmpty else {
                    continue
                }
                let prefix = FacebookAppTokens.extractTokenPrefix(token)
                let parsedCookies = extractCookies(from: json)
                return ConvertedTokenRecord(
                    appKey: app.key,
                    appName: app.name,
                    appId: app.appId,
                    tokenPrefix: prefix,
                    accessToken: token,
                    cookieString: parsedCookies.cookieString,
                    cookies: parsedCookies.items
                )
            } catch {
                continue
            }
        }
        return nil
    }

    static func convertAllTokens(
        from originalToken: String,
        client: SessionClient? = nil
    ) async -> [String: ConvertedTokenRecord] {
        var converted: [String: ConvertedTokenRecord] = [:]
        for app in FacebookAppTokens.allApps {
            if let record = await convertToken(originalToken, app: app, client: client) {
                converted[app.key] = record
            }
        }
        return converted
    }

    final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    /// Trích xuất CSRF Token (fb_dtsg) từ HTML của trang Facebook
    static func extractDtsg(from html: String) -> String? {
        let patterns = [
            #"\"DTSGInitialData\",\s*\[\],\s*\{\"token\":\"([^\"]+)\""#,
            #"\"DTSGInitData\",\s*\[\],\s*\{\"token\":\"([^\"]+)\""#,
            #"\"token\":\"(NA[A-Za-z0-9_\-:]+|AQ[A-Za-z0-9_\-:]+)\""#,
            #"name=\"fb_dtsg\"\s+value=\"([^\"]+)\""#,
            #"value=\"([^\"]+)\"\s+name=\"fb_dtsg\""#,
            #"\"dtsg\":\{\"token\":\"([^\"]+)\""#,
            #"\"async_get_token\":\"([^\"]+)\""#
        ]
        for p in patterns {
            if let m = FacebookTargetPostResolver.firstMatch(pattern: p, in: html) {
                return m
            }
        }
        return nil
    }

    /// Trích xuất Access Token qua endpoint /v1.0/dialog/oauth/confirm khi có fb_dtsg và cookie
    static func extractTokenUsingDtsg(_ dtsg: String, cookieString: String) async -> String? {
        guard !dtsg.isEmpty, !cookieString.isEmpty else { return nil }

        let appIds = [
            "165907476854626", // Pages Manager / Graph API Explorer (EAAB)
            "350685531728",    // Facebook for Android (EAAAAU)
            "124024574287414", // Instagram OAuth (EAA...)
            "438142079694454"  // Ads Manager App (EAA...)
        ]

        let endpoints = [
            "https://www.facebook.com/dialog/oauth/confirm",
            "https://m.facebook.com/dialog/oauth/confirm",
            "https://www.facebook.com/v1.0/dialog/oauth/confirm",
            "https://m.facebook.com/v1.0/dialog/oauth/confirm"
        ]

        let noRedirectSession = URLSession(configuration: .default, delegate: NoRedirectDelegate(), delegateQueue: nil)

        for ep in endpoints {
            guard let url = URL(string: ep) else { continue }
            for appId in appIds {
                var req = URLRequest(url: url, timeoutInterval: 12)
                req.httpMethod = "POST"
                req.setValue(cookieString, forHTTPHeaderField: "Cookie")
                req.setValue(cookieString, forHTTPHeaderField: "cookie")
                req.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
                req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                req.setValue("https://www.facebook.com/", forHTTPHeaderField: "Referer")
                req.setValue("https://www.facebook.com", forHTTPHeaderField: "Origin")

                let params: [String: String] = [
                    "fb_dtsg": dtsg,
                    "app_id": appId,
                    "redirect_uri": "fbconnect://success",
                    "display": "popup",
                    "return_format": "access_token",
                    "from_post": "1",
                    "__CONFIRM__": "1"
                ]
                req.httpBody = formEncode(params)

                if let (data, resp) = try? await noRedirectSession.data(for: req),
                   let http = resp as? HTTPURLResponse {
                    // 1. Kiểm tra 302 Location header
                    if let loc = http.value(forHTTPHeaderField: "Location") {
                        if let tok = FacebookTargetPostResolver.firstMatch(pattern: #"access_token=([A-Za-z0-9_\-\|=]+)"#, in: loc) {
                            let validation = await SmartPostAPIClient.validateAccessToken(tok)
                            if validation.isValid {
                                return tok
                            }
                        }
                    }
                    // 2. Kiểm tra body nếu status 200
                    if let bodyStr = String(data: data, encoding: .utf8) {
                        if let tok = FacebookTargetPostResolver.firstMatch(pattern: #"access_token=([A-Za-z0-9_\-\|=]{20,500})"#, in: bodyStr)
                            ?? FacebookTargetPostResolver.firstMatch(pattern: #"\"accessToken\":\"(EAA[A-Za-z0-9_\-\|=]{20,500})\""#, in: bodyStr) {
                            let validation = await SmartPostAPIClient.validateAccessToken(tok)
                            if validation.isValid {
                                return tok
                            }
                        }
                    }
                }
            }
        }
        return nil
    }

    /// Trích xuất Access Token (EAAB / EAAG / EAAA) từ Cookie phiên đã đăng nhập
    static func extractTokenFromCookieString(_ cookieString: String) async -> String? {
        let trimmed = cookieString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("c_user="), trimmed.contains("xs=") else { return nil }

        // 1. Kiểm tra trực tiếp xem trong chuỗi cookie có token EAA không
        if let directMatch = FacebookTargetPostResolver.firstMatch(pattern: #"(EAA[A-Za-z0-9_\-\|=]{20,500})"#, in: trimmed) {
            let validation = await SmartPostAPIClient.validateAccessToken(directMatch)
            if validation.isValid {
                return directMatch
            }
        }

        // Tạo cấu hình Session có sẵn cookie storage cho toàn bộ domain .facebook.com (giữ cookie khi redirect giữa các domain)
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        let cookieStore = HTTPCookieStorage()
        for cookie in FacebookAppTokens.parseCookieString(trimmed) {
            if let httpCookie = HTTPCookie(properties: [
                .domain: ".facebook.com",
                .path: "/",
                .name: cookie.name,
                .value: cookie.value,
                .secure: "TRUE"
            ]) {
                cookieStore.setCookie(httpCookie)
            }
        }
        cfg.httpCookieStorage = cookieStore
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        let session = URLSession(configuration: cfg)

        // 2. Tải HTML trang web Facebook để lấy fb_dtsg
        var dtsg: String? = nil
        let checkPages = [
            "https://m.facebook.com/me",
            "https://www.facebook.com/",
            "https://m.facebook.com/"
        ]
        for pageUrl in checkPages {
            guard let url = URL(string: pageUrl) else { continue }
            var req = URLRequest(url: url, timeoutInterval: 10)
            req.httpMethod = "GET"
            req.setValue(trimmed, forHTTPHeaderField: "Cookie")
            req.setValue(trimmed, forHTTPHeaderField: "cookie")
            req.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
            req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
            if let (htmlData, _) = try? await session.data(for: req),
               let html = String(data: htmlData, encoding: .utf8) {
                if let found = extractDtsg(from: html) {
                    dtsg = found
                    break
                }
            }
        }

        // 3. Nếu tìm thấy fb_dtsg, thực hiện xác thực OAuth Confirm
        if let dtsg, !dtsg.isEmpty {
            if let tok = await extractTokenUsingDtsg(dtsg, cookieString: trimmed) {
                return tok
            }
        }

        // 4. Thử Ads Manager & Business Manager endpoints (với session tự động lưu và gửi cookie qua redirects)
        let adsUrls = [
            "https://www.facebook.com/adsmanager/manage/",
            "https://adsmanager.facebook.com/adsmanager/manage/campaigns",
            "https://business.facebook.com/content_management"
        ]
        for adsUrlStr in adsUrls {
            guard let url = URL(string: adsUrlStr) else { continue }
            var req = URLRequest(url: url, timeoutInterval: 12)
            req.httpMethod = "GET"
            req.setValue(trimmed, forHTTPHeaderField: "Cookie")
            req.setValue(trimmed, forHTTPHeaderField: "cookie")
            req.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
            req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

            if let (data, resp) = try? await session.data(for: req),
               let http = resp as? HTTPURLResponse, http.statusCode == 200,
               let bodyStr = String(data: data, encoding: .utf8) {
                if let tok = FacebookTargetPostResolver.firstMatch(pattern: #"\"accessToken\":\"(EAA[A-Za-z0-9_\-\|=]{20,500})\""#, in: bodyStr)
                    ?? FacebookTargetPostResolver.firstMatch(pattern: #"accessToken:\"(EAA[A-Za-z0-9_\-\|=]{20,500})\""#, in: bodyStr)
                    ?? FacebookTargetPostResolver.firstMatch(pattern: #"access_token=([A-Za-z0-9_\-\|=]{20,500})"#, in: bodyStr) {
                    let validation = await SmartPostAPIClient.validateAccessToken(tok)
                    if validation.isValid {
                        return tok
                    }
                }
            }
        }

        return nil
    }

    private static func sendAuthRequest(
        url: URL,
        params: [String: String],
        extraHeaders: [String: String] = [:],
        session: URLSession = .shared
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        for (k, v) in baseHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }
        for (k, v) in extraHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.httpBody = formEncode(params)
        let (respData, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any] else {
            throw SpaceLoginError.apiError("Phản hồi từ máy chủ không phải JSON hợp lệ.")
        }
        return json
    }

    private static func extractErrorInfo(from json: [String: Any]) -> (code: Int, subcode: Int, message: String, errorObj: [String: Any])? {
        if let errorObj = json["error"] as? [String: Any] {
            let code = (errorObj["code"] as? Int) ?? (errorObj["error_code"] as? Int) ?? 0
            let subcode = (errorObj["error_subcode"] as? Int) ?? 0
            let msg = (errorObj["error_user_msg"] as? String)
                ?? (errorObj["message"] as? String)
                ?? (errorObj["error_msg"] as? String)
                ?? "Đăng nhập thất bại"
            return (code, subcode, msg, errorObj)
        }
        if let errCode = json["error_code"] as? Int {
            let subcode = (json["error_subcode"] as? Int) ?? 0
            var errorDataDict: [String: Any] = [:]
            if let rawErrData = json["error_data"] as? [String: Any] {
                errorDataDict = rawErrData
            } else if let rawErrStr = json["error_data"] as? String,
                      let data = rawErrStr.data(using: .utf8),
                      let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                errorDataDict = parsed
            }
            let msg = (errorDataDict["error_user_msg"] as? String)
                ?? (json["error_msg"] as? String)
                ?? "Đăng nhập thất bại (Mã \(errCode))"
            var synth: [String: Any] = [
                "code": errCode,
                "error_subcode": subcode,
                "message": msg,
                "error_data": errorDataDict
            ]
            if let userMsg = errorDataDict["error_user_msg"] as? String {
                synth["error_user_msg"] = userMsg
            }
            return (errCode, subcode, msg, synth)
        }
        return nil
    }

    /// Lưu cập nhật định danh thiết bị & mã phiên chờ duyệt (machine_id, first_factor, uid) vào Keychain
    private static func persistLoginDeviceState(
        spaceId: UUID?,
        cleanUser: String,
        cleanPass: String,
        cleanTotp: String,
        machineId: String,
        deviceId: String,
        adid: String,
        simSerial: String,
        pendingFirstFactor: String?,
        pendingUid: String?
    ) {
        guard let spaceId else { return }
        let record = SpaceLogin(
            user: cleanUser,
            password: cleanPass,
            totp: cleanTotp,
            machineId: machineId,
            deviceId: deviceId,
            adid: adid,
            simSerial: simSerial,
            pendingFirstFactor: pendingFirstFactor,
            pendingUid: pendingUid
        )
        try? SecureLoginStore.save(record, for: spaceId)
    }

    static func login(
        uidPhoneMail: String,
        password: String,
        totpSecretOrCode: String,
        machineId: String? = nil,
        spaceId: UUID? = nil,
        convertAll: Bool = true,
        onStatusUpdate: (@Sendable (String) -> Void)? = nil
    ) async throws -> SpaceTokenVault {
        let cleaned = sanitizeInput(uidPhoneMail: uidPhoneMail, password: password, totpSecretOrCode: totpSecretOrCode)
        let cleanUser = cleaned.user
        let cleanPass = cleaned.pass
        let cleanTotp = cleaned.totp

        guard !cleanUser.isEmpty, !cleanPass.isEmpty else {
            throw SpaceLoginError.invalid
        }

        // 1. Tạo session riêng biệt lưu cookie và mang đầy đủ 100% header (chuẩn requests.Session() của 1767528775-Login2FaConvertToken.py)
        let resolvedMachineId: String
        let savedRecord = spaceId.flatMap { try? SecureLoginStore.read($0) }
        let trimmedInputMachine = machineId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSavedMachine = savedRecord?.machineId.trimmingCharacters(in: .whitespacesAndNewlines)

        if let m = trimmedInputMachine, m.count >= 20, m != trimmedSavedMachine {
            // Người dùng chủ động nhập/dán một Machine ID cụ thể
            resolvedMachineId = m
        } else if let spaceId,
                  let webCookies = await WebCookieBridge.extractFacebookCookies(from: spaceId) as [FacebookCookieItem]?,
                  let datrCookie = webCookies.first(where: { $0.name == "datr" })?.value,
                  datrCookie.count >= 20 {
            // Ưu tiên cao nhất là lấy cookie datr thực tế đang hoạt động của trình duyệt Không gian này
            resolvedMachineId = datrCookie
        } else if let m = trimmedInputMachine, m.count >= 20 {
            resolvedMachineId = m
        } else if let sm = trimmedSavedMachine, sm.count >= 20 {
            resolvedMachineId = sm
        } else {
            resolvedMachineId = generateMachineId()
        }

        let client = SessionClient(initialDatr: resolvedMachineId.count >= 20 ? resolvedMachineId : nil)

        // 2. Chuẩn bị định danh thiết bị
        let deviceId = (savedRecord?.deviceId?.isEmpty == false) ? savedRecord!.deviceId! : UUID().uuidString.lowercased()
        let adid = (savedRecord?.adid?.isEmpty == false) ? savedRecord!.adid! : UUID().uuidString.lowercased()
        let secureFamilyDeviceId = UUID().uuidString.lowercased()
        let simSerial = (savedRecord?.simSerial?.isEmpty == false) ? savedRecord!.simSerial! : generateSimSerial()
        let jazoest = randomDigits(5)

        // 3. Mã hóa mật khẩu chuẩn #PWD_FB4A:2 theo 1767528775-Login2FaConvertToken.py
        let encryptedPassword: String
        if cleanPass.hasPrefix("#PWD_FB4A") {
            encryptedPassword = cleanPass
        } else {
            onStatusUpdate?("Đang lấy public key & mã hóa mật khẩu...")
            let enc = try await FacebookPasswordEncryptor.encrypt(password: cleanPass)
            encryptedPassword = enc.encrypted
        }

        // 4. Payload đăng nhập chuẩn Facebook App FB4A (350685531728) theo 1767528775-Login2FaConvertToken.py
        let loginParams: [String: String] = [
            "format": "json",
            "email": cleanUser,
            "password": encryptedPassword,
            "credentials_type": "password",
            "generate_session_cookies": "1",
            "locale": "vi_VN",
            "client_country_code": "VN",
            "api_key": apiKey,
            "access_token": accessToken,
            "adid": adid,
            "device_id": deviceId,
            "generate_analytics_claim": "1",
            "community_id": "",
            "linked_guest_account_userid": "",
            "cpl": "true",
            "try_num": "1",
            "family_device_id": deviceId,
            "secure_family_device_id": secureFamilyDeviceId,
            "sim_serials": "[\"\(simSerial)\"]",
            "openid_flow": "android_login",
            "openid_provider": "google",
            "openid_tokens": "[]",
            "account_switcher_uids": "[\"\(cleanUser)\"]",
            "fb4a_shared_phone_cpl_experiment": "fb4a_shared_phone_nonce_cpl_at_risk_v3",
            "fb4a_shared_phone_cpl_group": "enable_v3_at_risk",
            "enroll_misauth": "false",
            "error_detail_type": "button_with_disabled",
            "source": "login",
            "machine_id": resolvedMachineId,
            "jazoest": jazoest,
            "meta_inf_fbmeta": "V2_UNTAGGED",
            "advertiser_id": adid,
            "encrypted_msisdn": "",
            "currently_logged_in_userid": "0",
            "fb_api_req_friendly_name": "authenticate",
            "fb_api_caller_class": "Fb4aAuthHandler",
            "sig": sig
        ]

        onStatusUpdate?("Đang gửi yêu cầu đăng nhập...")
        let responseJson = try await client.post(url: apiURL, params: loginParams)

        // 5. Nếu đăng nhập thành công ngay (không có 2FA)
        if let token = responseJson["access_token"] as? String, !token.isEmpty {
            let returnedMachine = (responseJson["machine_id"] as? String) ?? resolvedMachineId
            persistLoginDeviceState(
                spaceId: spaceId,
                cleanUser: cleanUser,
                cleanPass: cleanPass,
                cleanTotp: cleanTotp,
                machineId: returnedMachine,
                deviceId: deviceId,
                adid: adid,
                simSerial: simSerial,
                pendingFirstFactor: "",
                pendingUid: cleanUser
            )
            onStatusUpdate?("Đăng nhập thành công! Đang convert sang 6 App Token...")
            return await buildVault(uid: cleanUser, responseJson: responseJson, convertAll: convertAll, client: client)
        }

        // 6. Xử lý phản hồi lỗi hoặc yêu cầu 2FA
        if let errInfo = extractErrorInfo(from: responseJson) {
            var errorData: [String: Any] = [:]
            let errorObj = errInfo.errorObj

            if let rawErrData = errorObj["error_data"] {
                if let dict = rawErrData as? [String: Any] {
                    errorData = dict
                } else if let str = rawErrData as? String,
                          let data = str.data(using: .utf8),
                          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    errorData = dict
                }
            }
            if errorData.isEmpty, let rawRootErrData = responseJson["error_data"] {
                if let dict = rawRootErrData as? [String: Any] {
                    errorData = dict
                } else if let str = rawRootErrData as? String,
                          let data = str.data(using: .utf8),
                          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    errorData = dict
                }
            }

            let firstFactor: String = {
                if let f = errorData["login_first_factor"] as? String, !f.isEmpty { return f }
                if let f = errorData["first_factor"] as? String, !f.isEmpty { return f }
                if let f = responseJson["login_first_factor"] as? String, !f.isEmpty { return f }
                if let f = responseJson["first_factor"] as? String, !f.isEmpty { return f }
                if let f = errorObj["login_first_factor"] as? String, !f.isEmpty { return f }
                if let f = errorObj["first_factor"] as? String, !f.isEmpty { return f }
                return ""
            }()

            let uidValue: String = {
                if let u = errorData["uid"] as? String, !u.isEmpty { return u }
                if let u = errorData["uid"] as? NSNumber { return u.stringValue }
                if let u = responseJson["uid"] as? String, !u.isEmpty { return u }
                if let u = responseJson["uid"] as? NSNumber { return u.stringValue }
                if let u = errorObj["uid"] as? String, !u.isEmpty { return u }
                if let u = errorObj["uid"] as? NSNumber { return u.stringValue }
                return cleanUser
            }()

            // CHỈ gửi request 2FA khi firstFactor thực sự có giá trị từ Facebook (chuẩn _handle_2fa trong Python)
            if !firstFactor.isEmpty {
                guard !cleanTotp.isEmpty else {
                    throw SpaceLoginError.apiError("Facebook yêu cầu 2FA nhưng chưa nhập mã hoặc khóa 2FA.")
                }

                guard let otpCode = SwiftTOTP.code(cleanTotp) else {
                    throw SpaceLoginError.apiError("Khóa 2FA Base32 hoặc mã 6 số không hợp lệ: '\(cleanTotp)'.")
                }

                onStatusUpdate?("Đang xác thực 2FA (\(otpCode)) với cấu hình thiết bị Android...")

                // 1. Payload 2FA đầy đủ GIẢ LẬP THIẾT BỊ ANDROID (FB4A) 100% đồng bộ với Request 1
                let fullData2FA: [String: String] = [
                    "format": "json",
                    "locale": "vi_VN",
                    "client_country_code": "VN",
                    "email": cleanUser,
                    "password": encryptedPassword,
                    "credentials_type": "two_factor",
                    "twofactor_code": otpCode,
                    "first_factor": firstFactor,
                    "userid": uidValue,
                    "machine_id": firstFactor,
                    "access_token": accessToken,
                    "api_key": apiKey,
                    "generate_session_cookies": "1",
                    "generate_machine_id": "1",
                    "error_detail_type": "button_with_disabled",
                    "source": "login",
                    "cpl": "true",
                    "try_num": "1",
                    "device_id": deviceId,
                    "family_device_id": deviceId,
                    "secure_family_device_id": secureFamilyDeviceId,
                    "adid": adid,
                    "advertiser_id": adid,
                    "sim_serials": "[\"\(simSerial)\"]",
                    "jazoest": jazoest,
                    "meta_inf_fbmeta": "V2_UNTAGGED",
                    "currently_logged_in_userid": "0",
                    "fb_api_req_friendly_name": "authenticate",
                    "fb_api_caller_class": "Fb4aAuthHandler",
                    "sig": sig
                ]

                var response2FA = try? await client.post(url: apiURL, params: fullData2FA)

                // 2. Dự phòng: nếu payload đầy đủ bị từ chối tham số, fallback về payload rút gọn (chuẩn Python script)
                if response2FA == nil || (response2FA?["access_token"] as? String)?.isEmpty != false {
                    let minimalData2FA: [String: String] = [
                        "locale": "vi_VN",
                        "format": "json",
                        "email": cleanUser,
                        "device_id": deviceId,
                        "access_token": accessToken,
                        "generate_session_cookies": "true",
                        "generate_machine_id": "1",
                        "twofactor_code": otpCode,
                        "credentials_type": "two_factor",
                        "error_detail_type": "button_with_disabled",
                        "first_factor": firstFactor,
                        "password": encryptedPassword,
                        "userid": uidValue,
                        "machine_id": firstFactor
                    ]
                    if let retryResp = try? await client.post(url: apiURL, params: minimalData2FA),
                       (retryResp["access_token"] as? String)?.isEmpty == false {
                        response2FA = retryResp
                    }
                }

                if let resp2FA = response2FA, let token2FA = resp2FA["access_token"] as? String, !token2FA.isEmpty {
                    let finalMachine = (resp2FA["machine_id"] as? String) ?? firstFactor
                    persistLoginDeviceState(
                        spaceId: spaceId,
                        cleanUser: cleanUser,
                        cleanPass: cleanPass,
                        cleanTotp: cleanTotp,
                        machineId: finalMachine,
                        deviceId: deviceId,
                        adid: adid,
                        simSerial: simSerial,
                        pendingFirstFactor: "",
                        pendingUid: uidValue
                    )
                    onStatusUpdate?("Xác thực 2FA thành công! Đang convert sang 6 App Token...")
                    return await buildVault(uid: uidValue, responseJson: resp2FA, convertAll: convertAll, client: client)
                }

                if let resp2FA = response2FA, let err2FA = extractErrorInfo(from: resp2FA) {
                    throw SpaceLoginError.apiError("Xác thực 2FA thất bại: \(err2FA.message)")
                } else {
                    throw SpaceLoginError.apiError("Xác thực 2FA không trả về Access Token.")
                }
            }

            // Trường hợp Facebook báo yêu cầu phê duyệt thiết bị (Login Approvals 406/405) nhưng không cấp first_factor
            if errInfo.code == 406 || errInfo.code == 405 {
                let approvalParams: [String: String] = [
                    "locale": "vi_VN",
                    "client_country_code": "VN",
                    "format": "json",
                    "email": cleanUser,
                    "userid": uidValue,
                    "password": encryptedPassword,
                    "device_id": deviceId,
                    "family_device_id": deviceId,
                    "adid": adid,
                    "access_token": accessToken,
                    "api_key": apiKey,
                    "generate_session_cookies": "1",
                    "generate_machine_id": "1",
                    "credentials_type": "check_approved_machine",
                    "source": "login",
                    "error_detail_type": "button_with_disabled",
                    "machine_id": resolvedMachineId,
                    "fb_api_req_friendly_name": "authenticate",
                    "fb_api_caller_class": "com.facebook.account.login.protocol.Fb4aAuthHandler"
                ]
                if let jsonApp = try? await client.post(url: apiURL, params: approvalParams),
                   let tok = jsonApp["access_token"] as? String, !tok.isEmpty {
                    persistLoginDeviceState(
                        spaceId: spaceId,
                        cleanUser: cleanUser,
                        cleanPass: cleanPass,
                        cleanTotp: cleanTotp,
                        machineId: (jsonApp["machine_id"] as? String) ?? resolvedMachineId,
                        deviceId: deviceId,
                        adid: adid,
                        simSerial: simSerial,
                        pendingFirstFactor: "",
                        pendingUid: uidValue
                    )
                    return await buildVault(uid: uidValue, responseJson: jsonApp, convertAll: convertAll, client: client)
                }

                throw SpaceLoginError.apiError("Facebook yêu cầu phê duyệt trên ứng dụng đã đăng nhập trước đó (Login Approvals).\n• Hãy mở app Facebook trên điện thoại hoặc trình duyệt để bấm 'Phê duyệt'.\n• Sau đó bấm 'Đăng nhập API' lại.")
            }

            var extraTip = ""
            if errInfo.code == 400 || errInfo.subcode == 1348092 {
                extraTip = "\n• Mẹo: Nếu mật khẩu chính xác nhưng FB báo sai, hãy lấy giá trị cookie 'datr' của tài khoản dán vào ô 'Machine ID / datr' (như gợi ý trong file script Python)."
            } else if errInfo.code == 401 || errInfo.subcode == 1348131 {
                extraTip = "\n• Lưu ý: Trên ứng dụng Facebook Android, FB thường chặn đăng nhập bằng dãy số UID. Hãy thử dùng Email hoặc Số điện thoại đăng ký tài khoản này để đăng nhập, hoặc đăng nhập trên Web Không gian rồi bấm 'Trích xuất Token'."
            }
            let userMsg = (errorData["error_user_msg"] as? String)
                ?? (responseJson["error_user_msg"] as? String)
                ?? (errorObj["error_user_msg"] as? String)
                ?? errInfo.message
            throw SpaceLoginError.apiError("\(userMsg) (Mã: \(errInfo.code)\(errInfo.subcode > 0 ? "/\(errInfo.subcode)" : ""))\(extraTip)")
        }

        throw SpaceLoginError.apiError("Không nhận diện được phản hồi từ Facebook.")
    }

    private static func buildVault(
        uid: String,
        responseJson: [String: Any],
        convertAll: Bool,
        client: SessionClient? = nil
    ) async -> SpaceTokenVault {
        let originalToken = (responseJson["access_token"] as? String) ?? ""
        let originalPrefix = FacebookAppTokens.extractTokenPrefix(originalToken)
        var parsedCookies = extractCookies(from: responseJson)

        if parsedCookies.items.isEmpty, let clientCookies = client?.cookies, !clientCookies.isEmpty {
            var items: [FacebookCookieItem] = []
            for (name, val) in clientCookies {
                items.append(FacebookCookieItem(name: name, value: val, domain: ".facebook.com", path: "/"))
            }
            parsedCookies = (items, FacebookAppTokens.formatCookieString(items))
        }

        let converted = convertAll ? await convertAllTokens(from: originalToken, client: client) : [:]

        var resolvedUID = uid
        if let cUser = parsedCookies.items.first(where: { $0.name == "c_user" })?.value, !cUser.isEmpty {
            resolvedUID = cUser
        }

        return SpaceTokenVault(
            uid: resolvedUID,
            originalPrefix: originalPrefix,
            originalToken: originalToken,
            cookieString: parsedCookies.cookieString,
            cookies: parsedCookies.items,
            convertedTokens: converted,
            updatedAt: Date()
        )
    }
}

// MARK: - WebKit Cookie Injector & Extractor

enum WebCookieBridge {
    @MainActor
    static func extractTokenFromLiveWebView(_ webView: WKWebView?) async -> String? {
        guard let webView else { return nil }

        // 1. Kiểm tra trực tiếp các thuộc tính JS hoặc thẻ script trong DOM
        let directScript = """
        (function() {
            if (window.__accessToken && typeof window.__accessToken === 'string' && window.__accessToken.startsWith('EAA')) {
                return window.__accessToken;
            }
            const scripts = document.querySelectorAll('script');
            for (let s of scripts) {
                const text = s.textContent || '';
                const m = text.match(/"accessToken"\\s*:\\s*"(EAA[A-Za-z0-9_=-]{20,500})"/);
                if (m && m[1]) return m[1];
            }
            return null;
        })();
        """
        if let token = try? await webView.evaluateJavaScript(directScript) as? String,
           token.hasPrefix("EAA"), token.count >= 25 {
            let validation = await SmartPostAPIClient.validateAccessToken(token)
            if validation.isValid {
                return token
            }
        }

        // 2. Trích xuất fb_dtsg trực tiếp từ môi trường JavaScript của WebView
        let dtsgScript = """
        (function() {
            let dtsg = '';
            try {
                if (window.require) {
                    dtsg = window.require('DTSGInitialData')?.token || window.require('DTSGInitData')?.token || '';
                }
            } catch(e) {}
            if (!dtsg) {
                const input = document.querySelector('input[name="fb_dtsg"]');
                if (input && input.value) dtsg = input.value;
            }
            if (!dtsg) {
                const m = document.documentElement.innerHTML.match(/"DTSGInitialData",\\s*\\[\\],\\s*\\{"token":"([^"]+)"/);
                if (m && m[1]) dtsg = m[1];
            }
            if (!dtsg) {
                const m = document.documentElement.innerHTML.match(/"token":"(NA[A-Za-z0-9_\\-:]+|AQ[A-Za-z0-9_\\-:]+)"/);
                if (m && m[1]) dtsg = m[1];
            }
            return dtsg;
        })();
        """
        let extractedDtsg = (try? await webView.evaluateJavaScript(dtsgScript) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        // 3. Lấy cookies từ DataStore của WebView
        let allCookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let fbCookies = allCookies.filter { $0.domain.lowercased().contains("facebook.com") }
        let cookieItems = fbCookies.map {
            FacebookCookieItem(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path)
        }
        let cookieString = FacebookAppTokens.formatCookieString(cookieItems)

        // 4. Nếu có fb_dtsg và cookieString, gọi dialog/oauth/confirm bằng URLSession
        if let dtsg = extractedDtsg, !dtsg.isEmpty, !cookieString.isEmpty {
            if let tok = await FacebookAPILoginClient.extractTokenUsingDtsg(dtsg, cookieString: cookieString) {
                return tok
            }
        }

        // 4b. Thực hiện fetch Ads Manager / Business Manager trực tiếp từ ngữ cảnh JS của WebView (mang đầy đủ cookie bảo mật phiên)
        let liveFetchScript = """
        (async function() {
            const targets = [
                'https://www.facebook.com/adsmanager/manage/',
                'https://adsmanager.facebook.com/adsmanager/manage/campaigns',
                'https://business.facebook.com/content_management'
            ];
            for (let url of targets) {
                try {
                    const r = await fetch(url, { credentials: 'include' });
                    const text = await r.text();
                    const m = text.match(/"accessToken"\\s*:\\s*"(EAA[A-Za-z0-9_=-]{20,500})"/)
                           || text.match(/accessToken:\\s*"(EAA[A-Za-z0-9_=-]{20,500})"/)
                           || text.match(/access_token=(EAA[A-Za-z0-9_=-]{20,500})/);
                    if (m && m[1]) return m[1];
                } catch(e) {}
            }
            return null;
        })();
        """
        if let liveFetchTok = try? await webView.evaluateJavaScript(liveFetchScript) as? String,
           liveFetchTok.hasPrefix("EAA"), liveFetchTok.count >= 25 {
            let validation = await SmartPostAPIClient.validateAccessToken(liveFetchTok)
            if validation.isValid {
                return liveFetchTok
            }
        }

        // 5. Thử toàn bộ pipeline cookieString (DTSG regex + Dialog OAuth + Ads Manager + Business Manager)
        if !cookieString.isEmpty {
            if let tok = await FacebookAPILoginClient.extractTokenFromCookieString(cookieString) {
                return tok
            }
        }

        return nil
    }

    /// Trích xuất toàn diện Cookie + Token từ WebView của một Space và tự động lưu vào Keychain
    @MainActor
    static func extractTokenAndSave(for space: Space, webView: WKWebView?) async -> (success: Bool, message: String) {
        let cookies = await extractFacebookCookies(from: space.id)
        guard !cookies.isEmpty else {
            return (false, "Chưa tìm thấy cookie Facebook trong trình duyệt của không gian này. Hãy mở web Facebook và đăng nhập trước.")
        }
        let cookieString = FacebookAppTokens.formatCookieString(cookies)
        let cUser = cookies.first(where: { $0.name == "c_user" })?.value ?? ""

        guard !cUser.isEmpty else {
            return (false, "Chưa phát hiện phiên đăng nhập (thiếu cookie c_user). Vui lòng đăng nhập trên Facebook trước.")
        }

        let existingVault = try? SecureLoginStore.readTokenVault(space.id)
        var resolvedToken: String? = nil

        // 1. Trích xuất Token từ live webView hoặc cookieString
        if let liveTok = await extractTokenFromLiveWebView(webView), !liveTok.isEmpty {
            resolvedToken = liveTok
        } else if let cookieTok = await FacebookAPILoginClient.extractTokenFromCookieString(cookieString), !cookieTok.isEmpty {
            resolvedToken = cookieTok
        } else if let saved = existingVault?.originalToken, !saved.isEmpty {
            let val = await SmartPostAPIClient.validateAccessToken(saved)
            if val.isValid {
                resolvedToken = saved
            }
        }

        // 2. Nếu tìm thấy Token, convert sang 6 App Token
        var converted: [String: ConvertedTokenRecord] = existingVault?.convertedTokens ?? [:]
        if let token = resolvedToken, !token.isEmpty {
            let newConverted = await FacebookAPILoginClient.convertAllTokens(from: token)
            if !newConverted.isEmpty {
                converted = newConverted
            }
        }

        let origToken = resolvedToken ?? ""
        let origPrefix = FacebookAppTokens.extractTokenPrefix(origToken)

        let vault = SpaceTokenVault(
            uid: cUser,
            originalPrefix: origPrefix,
            originalToken: origToken,
            cookieString: cookieString,
            cookies: cookies,
            convertedTokens: converted,
            updatedAt: Date()
        )

        do {
            try SecureLoginStore.saveTokenVault(vault, for: space.id)
            if !origToken.isEmpty {
                let countStr = converted.count > 0 ? " • \(converted.count) App Tokens" : ""
                return (true, "Đã trích xuất Cookie VÀ lấy thành công Token (\(origPrefix)\(countStr)) cho UID \(cUser)!")
            } else {
                return (true, "Đã lưu \(cookies.count) Cookie cho UID \(cUser). (Chưa lấy được Access Token, bạn có thể bấm 'Đăng nhập API' bằng mật khẩu & 2FA để lấy trọn bộ 6 App Token).")
            }
        } catch {
            return (false, error.localizedDescription)
        }
    }

    @MainActor
    static func injectCookies(from vault: SpaceTokenVault, into spaceId: UUID) async -> Int {
        let items: [FacebookCookieItem]
        if !vault.cookies.isEmpty {
            items = vault.cookies
        } else {
            items = FacebookAppTokens.parseCookieString(vault.cookieString)
        }
        guard !items.isEmpty else { return 0 }

        let store = WKWebsiteDataStore(forIdentifier: spaceId).httpCookieStore
        let expires = Date().addingTimeInterval(365 * 24 * 3600)
        var injectedCount = 0

        for item in items {
            let domain = (item.domain?.isEmpty == false) ? item.domain! : ".facebook.com"
            let path = (item.path?.isEmpty == false) ? item.path! : "/"
            let props: [HTTPCookiePropertyKey: Any] = [
                .name: item.name,
                .value: item.value,
                .domain: domain,
                .path: path,
                .secure: "TRUE",
                .expires: expires
            ]
            if let httpCookie = HTTPCookie(properties: props) {
                await store.setCookie(httpCookie)
                injectedCount += 1
            }
        }
        return injectedCount
    }

    @MainActor
    static func extractFacebookCookies(from spaceId: UUID) async -> [FacebookCookieItem] {
        let store = WKWebsiteDataStore(forIdentifier: spaceId).httpCookieStore
        let allCookies = await store.allCookies()
        let fbCookies = allCookies.filter { $0.domain.lowercased().contains("facebook.com") }
        return fbCookies.map {
            FacebookCookieItem(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path)
        }
    }
}

// MARK: - UI: Login & Token Vault Sheet

// MARK: - TXT Account Loader

struct TxtAccount: Identifiable {
    let id = UUID()
    let uid: String
    let password: String
    let twoFA: String
    var display: String {
        let u = uid.trimmingCharacters(in: .whitespaces)
        return u.isEmpty ? String(password.prefix(10)) + "..." : u
    }
}

struct TxtDocumentPicker: UIViewControllerRepresentable {
    var onPicked: (String) -> Void
    var onDismiss: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked, onDismiss: onDismiss) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = [.plainText, .text, .utf8PlainText, .commaSeparatedText, .data]
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        vc.delegate = context.coordinator
        vc.allowsMultipleSelection = false
        return vc
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        var onPicked: (String) -> Void
        var onDismiss: (() -> Void)?

        init(onPicked: @escaping (String) -> Void, onDismiss: (() -> Void)?) {
            self.onPicked = onPicked
            self.onDismiss = onDismiss
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                onDismiss?()
                return
            }

            let canAccess = url.startAccessingSecurityScopedResource()
            defer {
                if canAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            var loadedData: Data? = try? Data(contentsOf: url)
            if loadedData == nil {
                var coordinatorError: NSError?
                let coordinator = NSFileCoordinator()
                coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinatorError) { readURL in
                    loadedData = try? Data(contentsOf: readURL)
                }
            }

            guard let data = loadedData, !data.isEmpty else {
                onDismiss?()
                return
            }

            let decodedText: String? = {
                if let s = String(data: data, encoding: .utf8) { return s }
                if let s = String(data: data, encoding: .utf16) { return s }
                if let s = String(data: data, encoding: .unicode) { return s }
                if let s = String(data: data, encoding: .windowsCP1252) { return s }
                if let s = String(data: data, encoding: .isoLatin1) { return s }
                if let s = String(data: data, encoding: .ascii) { return s }
                return nil
            }()

            if let text = decodedText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                onPicked(text)
            } else {
                onDismiss?()
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onDismiss?()
        }
    }
}

struct TxtAccountPickerSheet: View {
    let accounts: [TxtAccount]
    var onSelect: (TxtAccount) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedId: UUID? = nil
    @State private var searchText = ""

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    private var filteredAccounts: [TxtAccount] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return accounts }
        return accounts.filter {
            $0.uid.localizedCaseInsensitiveContains(trimmed) ||
            $0.display.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if filteredAccounts.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                        Text(accounts.isEmpty ? "Danh sách tài khoản trống" : "Không tìm thấy tài khoản phù hợp")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(filteredAccounts) { acc in
                                let isSelected = selectedId == acc.id
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(isSelected ? Color.blue : Color.secondary)
                                        Spacer()
                                        if !acc.twoFA.isEmpty {
                                            Image(systemName: "lock.shield")
                                                .font(.caption2)
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                    Text(acc.display)
                                        .font(.caption.bold())
                                        .lineLimit(1)
                                    if !acc.uid.isEmpty {
                                        Text("UID: " + acc.uid)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Text(String(acc.password.prefix(8)) + "••••")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(isSelected ? Color.blue.opacity(0.12) : Color(uiColor: .secondarySystemGroupedBackground))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 1.5)
                                        )
                                )
                                .contentShape(Rectangle())
                                .onTapGesture { selectedId = acc.id }
                            }
                        }
                        .padding()
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Tìm theo UID...")
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Chọn tài khoản (\(accounts.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Hủy") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Dùng tài khoản này") {
                        if let acc = accounts.first(where: { $0.id == selectedId }) {
                            onSelect(acc)
                        }
                        dismiss()
                    }
                    .disabled(selectedId == nil)
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

struct LoginEditorSheet: View {
    let space: Space
    var webView: WKWebView? = nil
    var onReloadWebView: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var seed = ""
    @State private var machineId = ""

    @State private var vault: SpaceTokenVault?
    @State private var manualToken = ""
    @State private var manualCookie = ""

    @State private var isBusy = false
    @State private var busyLabel = ""
    @State private var showDeleteConfirm = false
    @State private var message: String?
    @State private var showFilePicker = false
    @State private var parsedTxtAccounts: [TxtAccount] = []
    @State private var showTxtAccountPicker = false
    @State private var showPassword = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: space.platform.icon)
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(space.platform.color, in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(space.name).font(.headline)
                            if let vault {
                                Text("Đã lưu Token (\(vault.originalPrefix.isEmpty ? "Cookie" : vault.originalPrefix)) • \(vault.convertedTokens.count) App Tokens")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            } else {
                                Text("Chưa có Token lưu trữ")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if isBusy {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(busyLabel).font(.subheadline)
                        }
                    }
                }

                Section("1. Tài khoản & Đăng nhập lấy Token") {
                    TextField("Email / Số điện thoại / UID (hoặc dán uid|pass|2fa)", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: username) { newValue in
                            if newValue.contains("|") {
                                applyPipeFormatString(newValue)
                            }
                        }

                    HStack(spacing: 8) {
                        Group {
                            if showPassword {
                                TextField("Mật khẩu hoặc #PWD_FB4A...", text: $password)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            } else {
                                SecureField("Mật khẩu hoặc #PWD_FB4A...", text: $password)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                        }
                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash.fill" : "eye.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    TextField("Khóa 2FA Base32 (hoặc mã 6 số)", text: $seed)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    HStack {
                        TextField("Machine ID / datr (tùy chọn)", text: $machineId)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.caption.monospaced())
                        if !machineId.isEmpty {
                            Button {
                                machineId = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    HStack(spacing: 10) {
                        Button {
                            if let clip = UIPasteboard.general.string, !clip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                applyPipeFormatString(clip)
                            } else {
                                message = "Bộ nhớ tạm (Clipboard) đang trống."
                            }
                        } label: {
                            Label("Dán UID|Pass|2FA", systemImage: "doc.on.clipboard")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .disabled(isBusy)

                        Button {
                            showFilePicker = true
                        } label: {
                            Label("Nạp file TXT", systemImage: "doc.text.below.ecg")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                        .disabled(isBusy)
                    }

                    Button {
                        saveCredentialsOnly()
                    } label: {
                        Label("Lưu thông tin đăng nhập vào Keychain", systemImage: "key.fill")
                    }
                    .disabled(isBusy)

                    Button {
                        Task { await runAPILoginAndSaveToken() }
                    } label: {
                        Label("Đăng nhập API • Lấy Token + Convert 6 App + Nạp Cookie", systemImage: "bolt.shield.fill")
                            .fontWeight(.semibold)
                    }
                    .disabled(isBusy)
                }

                if let vault {
                    Section("2. Kho Token đã lưu (Keychain)") {
                        if !vault.originalToken.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("TOKEN GỐC (\(vault.originalPrefix))")
                                        .font(.caption.bold())
                                        .foregroundStyle(.blue)
                                    Spacer()
                                    Button("Sao chép") {
                                        UIPasteboard.general.string = vault.originalToken
                                        message = "Đã sao chép Access Token gốc (\(vault.originalPrefix))."
                                    }
                                    .font(.caption.bold())
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.mini)
                                }
                                Text(vault.originalToken)
                                    .font(.caption2.monospaced())
                                    .lineLimit(2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)

                            Button {
                                Task { await reconvertSavedToken() }
                            } label: {
                                Label("Convert lại sang tất cả 6 App Token", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .disabled(isBusy)
                        }

                        if !vault.cookieString.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("COOKIE PHIÊN (\(vault.cookies.count) mục)")
                                        .font(.caption.bold())
                                        .foregroundStyle(.orange)
                                    Spacer()
                                    Button("Copy Cookie") {
                                        UIPasteboard.general.string = vault.cookieString
                                        message = "Đã sao chép Cookie vào bộ nhớ tạm."
                                    }
                                    .font(.caption.bold())
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                }
                                Text(vault.cookieString)
                                    .font(.caption2.monospaced())
                                    .lineLimit(2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)

                            Button {
                                Task { await injectSavedCookiesToWebView() }
                            } label: {
                                Label("Nạp Cookie vào Trình duyệt không gian này", systemImage: "globe.badge.chevron.backward")
                                    .foregroundStyle(.green)
                            }
                            .disabled(isBusy)
                        }

                        Button {
                            copyFullMMOFormat(vault: vault)
                        } label: {
                            Label("Copy định dạng UID|Pass|2FA|Cookie|Token", systemImage: "doc.on.doc.fill")
                        }
                    }

                    if !vault.convertedTokens.isEmpty {
                        Section("3. Converted Tokens (\(vault.convertedTokens.count) App)") {
                            ForEach(FacebookAppTokens.allApps) { app in
                                if let item = vault.convertedTokens[app.key] {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(item.appName)
                                                    .font(.subheadline.bold())
                                                Text("\(item.tokenPrefix) • App ID: \(item.appId)")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            Button("Copy Token") {
                                                UIPasteboard.general.string = item.accessToken
                                                message = "Đã copy token \(item.tokenPrefix) (\(item.appName))."
                                            }
                                            .font(.caption)
                                            .buttonStyle(.borderedProminent)
                                            .controlSize(.mini)

                                            if !item.cookieString.isEmpty {
                                                Button("Cookie") {
                                                    UIPasteboard.general.string = item.cookieString
                                                    message = "Đã copy cookie của \(item.appName)."
                                                }
                                                .font(.caption)
                                                .buttonStyle(.bordered)
                                                .controlSize(.mini)
                                            }
                                        }
                                        Text(item.accessToken)
                                            .font(.caption2.monospaced())
                                            .lineLimit(1)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 3)
                                }
                            }
                        }
                    }
                }

                Section("Nhập / Lưu Token & Cookie thủ công") {
                    TextField("Dán Access Token (EAAA...)", text: $manualToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.caption.monospaced())
                    TextField("Dán Cookie (c_user=...; xs=...)", text: $manualCookie)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.caption.monospaced())

                    Button {
                        Task { await saveManualTokenAndConvert() }
                    } label: {
                        Label("Lưu Token/Cookie thủ công & Convert 6 App", systemImage: "square.and.arrow.down.fill")
                    }
                    .disabled(isBusy || (manualToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                                         manualCookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))

                    Button {
                        Task { await extractCookiesFromWebViewAndSave() }
                    } label: {
                        Label("Trích xuất Cookie & Lấy Token API từ WebView hiện tại", systemImage: "arrow.down.doc.fill")
                    }
                    .disabled(isBusy)
                }

                Section {
                    Button("Xóa toàn bộ Đăng nhập & Token đã lưu", role: .destructive) {
                        showDeleteConfirm = true
                    }
                    .disabled(isBusy)
                }
            }
            .navigationTitle("Đăng nhập & Token")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Đóng") { dismiss() }
                }
            }
            .onAppear {
                loadExistingFromKeychain()
            }
            .confirmationDialog("Xóa mật khẩu, 2FA và toàn bộ Token đã lưu?", isPresented: $showDeleteConfirm) {
                Button("Xóa tất cả", role: .destructive) {
                    SecureLoginStore.remove(space.id)
                    vault = nil
                    username = ""
                    password = ""
                    seed = ""
                    machineId = ""
                    message = "Đã xóa thông tin đăng nhập và kho Token của không gian này."
                }
            }
            .alert("Thông báo", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button("OK") { message = nil }
            } message: { Text(message ?? "") }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.plainText, .text, .utf8PlainText, .commaSeparatedText, .data],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let url):
                    let canAccess = url.startAccessingSecurityScopedResource()
                    defer {
                        if canAccess {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }

                    var loadedData: Data? = try? Data(contentsOf: url)
                    if loadedData == nil {
                        var coordinatorError: NSError?
                        let coordinator = NSFileCoordinator()
                        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinatorError) { readURL in
                            loadedData = try? Data(contentsOf: readURL)
                        }
                    }

                    guard let data = loadedData, !data.isEmpty else {
                        message = "⚠️ Không thể đọc nội dung file (file trống hoặc chưa được tải về)."
                        return
                    }

                    let decodedText: String? = {
                        if let s = String(data: data, encoding: .utf8) { return s }
                        if let s = String(data: data, encoding: .utf16) { return s }
                        if let s = String(data: data, encoding: .unicode) { return s }
                        if let s = String(data: data, encoding: .windowsCP1252) { return s }
                        if let s = String(data: data, encoding: .isoLatin1) { return s }
                        if let s = String(data: data, encoding: .ascii) { return s }
                        return nil
                    }()

                    guard let rawText = decodedText, !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        message = "⚠️ Không thể giải mã bảng mã của file văn bản."
                        return
                    }

                    let accounts = parseTxtAccounts(rawText)
                    if accounts.isEmpty {
                        message = "Không tìm thấy dòng tài khoản hợp lệ trong file.\nĐịnh dạng hỗ trợ: UID|Pass|2FA (hoặc phân tách bằng :, tab, ;)."
                    } else if accounts.count == 1, let single = accounts.first {
                        username = single.uid
                        password = single.password
                        seed = single.twoFA
                        message = "✅ Đã nạp tài khoản: \(single.uid)"
                    } else {
                        parsedTxtAccounts = accounts
                        showTxtAccountPicker = true
                    }

                case .failure(let err):
                    message = "Lỗi khi chọn file: \(err.localizedDescription)"
                }
            }
            .sheet(isPresented: $showTxtAccountPicker) {
                TxtAccountPickerSheet(accounts: parsedTxtAccounts) { acc in
                    username = acc.uid
                    password = acc.password
                    seed = acc.twoFA
                    message = "✅ Đã nạp tài khoản: \(acc.uid)"
                }
                .presentationDetents([.medium, .large])
            }
        }
    }

    private func loadExistingFromKeychain() {
        if let savedLogin = try? SecureLoginStore.read(space.id) {
            username = savedLogin.user
            password = savedLogin.password
            seed = savedLogin.totp
            let trimmedM = savedLogin.machineId.trimmingCharacters(in: .whitespacesAndNewlines)
            machineId = trimmedM.count >= 20 ? trimmedM : ""
        }
        if let savedVault = try? SecureLoginStore.readTokenVault(space.id) {
            vault = savedVault
        }
    }


    private func applyPipeFormatString(_ raw: String) {
        let firstLine = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("//") }) ?? raw
        
        let delimiter: Character = firstLine.contains("|") ? "|" :
                                  (firstLine.contains("\t") ? "\t" :
                                  (firstLine.contains(";") ? ";" : ":"))
        let parts = firstLine.split(separator: delimiter, omittingEmptySubsequences: false).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard parts.count >= 2 else { return }
        username = parts[0]
        if !parts[1].isEmpty {
            password = parts[1]
        }
        if parts.count >= 3, !parts[2].isEmpty {
            seed = parts[2]
        }
        if parts.count >= 4, parts[3].contains("c_user=") {
            manualCookie = parts[3]
        }
        if parts.count >= 5, parts[4].hasPrefix("EAA") {
            manualToken = parts[4]
        }
    }

    private func parseTxtAccounts(_ text: String) -> [TxtAccount] {
        let invisibleChars = CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{FEFF}")
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        return lines.compactMap { line -> TxtAccount? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines.union(invisibleChars))
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("//") else { return nil }

            let delimiter: Character? = {
                if trimmed.contains("|") { return "|" }
                if trimmed.contains("\t") { return "\t" }
                if trimmed.contains(";") { return ";" }
                if trimmed.contains(":") { return ":" }
                return nil
            }()

            let parts: [String]
            if let delim = delimiter {
                parts = trimmed.split(separator: delim, omittingEmptySubsequences: false)
                    .map { String($0).trimmingCharacters(in: .whitespaces.union(invisibleChars)) }
            } else {
                let spaceParts = trimmed.components(separatedBy: .whitespaces)
                    .map { $0.trimmingCharacters(in: .whitespaces.union(invisibleChars)) }
                    .filter { !$0.isEmpty }
                if spaceParts.count >= 2 {
                    parts = spaceParts
                } else {
                    return nil
                }
            }

            guard parts.count >= 2 else { return nil }

            let uid = parts[0]
            let pass = parts[1]
            var fa = ""

            if parts.count >= 3 {
                for i in 2..<parts.count {
                    let candidate = parts[i].replacingOccurrences(of: " ", with: "")
                    let clean = candidate.uppercased()
                    let isBase32 = clean.count >= 16 && clean.count <= 64 && clean.allSatisfy { "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".contains($0) }
                    if isBase32 && fa.isEmpty {
                        fa = clean
                        break
                    }
                }
                if fa.isEmpty {
                    fa = parts[2]
                }
            }

            guard !uid.isEmpty, !pass.isEmpty else { return nil }
            return TxtAccount(uid: uid, password: pass, twoFA: fa)
        }
    }

    private func saveCredentialsOnly() {
        do {
            if username.contains("|") {
                applyPipeFormatString(username)
            }
            let cleanUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanPass = password.trimmingCharacters(in: .newlines)
            let cleanSeed = seed.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedM = machineId.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedMachine = trimmedM.count >= 20
                ? trimmedM
                : FacebookAPILoginClient.generateMachineId()
            machineId = resolvedMachine
            username = cleanUser
            password = cleanPass
            seed = cleanSeed
            try SecureLoginStore.save(
                SpaceLogin(user: cleanUser, password: cleanPass, totp: cleanSeed, machineId: resolvedMachine),
                for: space.id
            )
            message = "Đã lưu thông tin đăng nhập vào Keychain."
        } catch {
            message = error.localizedDescription
        }
    }

    @MainActor
    private func runAPILoginAndSaveToken() async {
        if username.contains("|") {
            applyPipeFormatString(username)
        }
        let cleanUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPass = password.trimmingCharacters(in: .newlines)
        let cleanSeed = seed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUser.isEmpty, !cleanPass.isEmpty else {
            message = SpaceLoginError.invalid.localizedDescription
            return
        }
        username = cleanUser
        password = cleanPass
        seed = cleanSeed

        isBusy = true
        busyLabel = "Đang mã hóa mật khẩu, xác thực 2FA & convert 6 App Token..."
        defer { isBusy = false }

        do {
            let trimmedM = machineId.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedMachine = trimmedM.count >= 20
                ? trimmedM
                : FacebookAPILoginClient.generateMachineId()
            machineId = resolvedMachine

            try SecureLoginStore.save(
                SpaceLogin(user: cleanUser, password: cleanPass, totp: cleanSeed, machineId: resolvedMachine),
                for: space.id
            )

            let newVault = try await FacebookAPILoginClient.login(
                uidPhoneMail: cleanUser,
                password: cleanPass,
                totpSecretOrCode: cleanSeed,
                machineId: resolvedMachine,
                spaceId: space.id,
                convertAll: true,
                onStatusUpdate: { status in
                    Task { @MainActor in
                        self.busyLabel = status
                    }
                }
            )

            if let updatedLogin = try? SecureLoginStore.read(space.id), !updatedLogin.machineId.isEmpty {
                machineId = updatedLogin.machineId
            }

            try SecureLoginStore.saveTokenVault(newVault, for: space.id)
            vault = newVault

            let injected = await WebCookieBridge.injectCookies(from: newVault, into: space.id)
            onReloadWebView?()
            message = "Đăng nhập thành công! Đã lưu Token (\(newVault.originalPrefix)), convert \(newVault.convertedTokens.count) App Token và nạp \(injected) cookie vào trình duyệt."
        } catch {
            if let updatedLogin = try? SecureLoginStore.read(space.id), !updatedLogin.machineId.isEmpty {
                machineId = updatedLogin.machineId
            }
            message = error.localizedDescription
        }
    }

    @MainActor
    private func reconvertSavedToken() async {
        guard let currentVault = vault, !currentVault.originalToken.isEmpty else { return }
        isBusy = true
        busyLabel = "Đang convert sang 6 App Token..."
        defer { isBusy = false }

        let converted = await FacebookAPILoginClient.convertAllTokens(from: currentVault.originalToken)
        var updated = currentVault
        updated.convertedTokens = converted
        updated.updatedAt = Date()
        do {
            try SecureLoginStore.saveTokenVault(updated, for: space.id)
            vault = updated
            message = "Đã cập nhật và lưu \(converted.count) Converted Tokens vào Keychain."
        } catch {
            message = error.localizedDescription
        }
    }

    @MainActor
    private func saveManualTokenAndConvert() async {
        var tokenTrimmed = manualToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let cookieTrimmed = manualCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        isBusy = true
        busyLabel = "Đang lưu, trích xuất và convert Token..."
        defer { isBusy = false }

        var converted: [String: ConvertedTokenRecord] = vault?.convertedTokens ?? [:]
        var cookies = FacebookAppTokens.parseCookieString(cookieTrimmed)
        var finalCookieString = cookieTrimmed

        // Nếu chỉ dán Cookie mà chưa có Token, tự động quét lấy Access Token từ Cookie
        if tokenTrimmed.isEmpty && !cookieTrimmed.isEmpty {
            busyLabel = "Đang trích xuất Access Token từ Cookie..."
            if let extractedTok = await FacebookAPILoginClient.extractTokenFromCookieString(cookieTrimmed), !extractedTok.isEmpty {
                tokenTrimmed = extractedTok
            }
        }

        if !tokenTrimmed.isEmpty {
            busyLabel = "Đang convert sang 6 App Token..."
            converted = await FacebookAPILoginClient.convertAllTokens(from: tokenTrimmed)
            if cookies.isEmpty, let fbAndroid = converted["FB_ANDROID"], !fbAndroid.cookies.isEmpty {
                cookies = fbAndroid.cookies
                finalCookieString = fbAndroid.cookieString
            }
        }

        let resolvedToken = tokenTrimmed.isEmpty ? (vault?.originalToken ?? "") : tokenTrimmed
        let resolvedPrefix = FacebookAppTokens.extractTokenPrefix(resolvedToken)
        let resolvedCookieStr = finalCookieString.isEmpty ? (vault?.cookieString ?? "") : finalCookieString
        let resolvedCookies = cookies.isEmpty ? (vault?.cookies ?? []) : cookies
        let cUser = resolvedCookies.first(where: { $0.name == "c_user" })?.value ?? username

        let newVault = SpaceTokenVault(
            uid: cUser,
            originalPrefix: resolvedPrefix,
            originalToken: resolvedToken,
            cookieString: resolvedCookieStr,
            cookies: resolvedCookies,
            convertedTokens: converted,
            updatedAt: Date()
        )

        do {
            try SecureLoginStore.saveTokenVault(newVault, for: space.id)
            vault = newVault
            manualToken = ""
            manualCookie = ""
            let count = await WebCookieBridge.injectCookies(from: newVault, into: space.id)
            onReloadWebView?()
            message = "Đã lưu Token (\(resolvedPrefix.isEmpty ? "Cookie" : resolvedPrefix)) vào Keychain (\(converted.count) App Tokens) và nạp \(count) cookie."
        } catch {
            message = error.localizedDescription
        }
    }

    @MainActor
    private func injectSavedCookiesToWebView() async {
        guard let vault else { return }
        let count = await WebCookieBridge.injectCookies(from: vault, into: space.id)
        onReloadWebView?()
        message = count > 0
            ? "Đã nạp \(count) cookie vào phiên WebView của \(space.name)."
            : "Không tìm thấy cookie hợp lệ để nạp."
    }

    @MainActor
    private func extractCookiesFromWebViewAndSave() async {
        isBusy = true
        busyLabel = "Đang trích xuất Cookie & lấy Access Token từ trình duyệt..."
        defer { isBusy = false }

        let res = await WebCookieBridge.extractTokenAndSave(for: space, webView: webView)
        if let savedVault = try? SecureLoginStore.readTokenVault(space.id) {
            vault = savedVault
        }
        message = res.message
    }

    private func copyFullMMOFormat(vault: SpaceTokenVault) {
        let uidPart = !vault.uid.isEmpty ? vault.uid : username
        let line = "\(uidPart)|\(password)|\(seed)|\(vault.cookieString)|\(vault.originalToken)"
        UIPasteboard.general.string = line
        message = "Đã sao chép định dạng UID|Pass|2FA|Cookie|Token."
    }
}

// MARK: - Browser Controls Bar

struct SecureLoginControls: View {
    let space: Space
    let webView: WKWebView?
    @State private var notice: String?
    @State private var showVaultSheet = false
    @State private var showAutoSheet = false
    @State private var isExtracting = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Button { autofill() } label: {
                    Label("Điền đăng nhập", systemImage: "key.fill")
                }
                Button { showTOTP() } label: {
                    Label("Mã 2FA", systemImage: "lock.shield")
                }
                Button {
                    Task { await applySavedCookieAndReload() }
                } label: {
                    Label("Nạp Cookie", systemImage: "arrow.down.circle.fill")
                }
                Button {
                    Task { await extractTokenFromLiveBrowser() }
                } label: {
                    if isExtracting {
                        ProgressView().controlSize(.mini)
                        Text("Đang lấy Token...")
                    } else {
                        Label("Lấy Token", systemImage: "key.viewfinder")
                    }
                }
                .disabled(isExtracting)
                Button { showVaultSheet = true } label: {
                    Label("Kho Token", systemImage: "person.badge.key.fill")
                }
                Button { showAutoSheet = true } label: {
                    Label("Auto AI", systemImage: "sparkles")
                }
            }
            .font(.caption)
            .buttonStyle(.bordered)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .sheet(isPresented: $showVaultSheet) {
            LoginEditorSheet(space: space, webView: webView) {
                webView?.reload()
            }
        }
        .sheet(isPresented: $showAutoSheet) {
            NavigationStack {
                AutoInteractView(preselectedSpace: space)
            }
        }
        .alert("Tài khoản", isPresented: Binding(
            get: { notice != nil },
            set: { if !$0 { notice = nil } }
        )) {
            Button("Đóng") { notice = nil }
        } message: { Text(notice ?? "") }
    }

    @MainActor
    private func extractTokenFromLiveBrowser() async {
        isExtracting = true
        defer { isExtracting = false }
        let res = await WebCookieBridge.extractTokenAndSave(for: space, webView: webView)
        notice = res.message
    }

    private func autofill() {
        guard let webView, let url = webView.url,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "facebook.com" || host.hasSuffix(".facebook.com") else {
            notice = "Chỉ hỗ trợ điền trên HTTPS của facebook.com."
            return
        }
        do {
            let data = try SecureLoginStore.read(space.id)
            let user = String(data: try JSONEncoder().encode(data.user),
                              encoding: .utf8) ?? "\"\""
            let pass = String(data: try JSONEncoder().encode(data.password),
                              encoding: .utf8) ?? "\"\""
            let js = """
            (function() {
              const u=document.querySelector('input[name="email"],input[autocomplete="username"]');
              const p=document.querySelector('input[name="pass"],input[type="password"]');
              if (!u || !p) return false;
              const setter=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;
              for (const [el,val] of [[u,\(user)],[p,\(pass)]]) {
                setter.call(el,val);
                el.dispatchEvent(new Event('input',{bubbles:true}));
                el.dispatchEvent(new Event('change',{bubbles:true}));
              }
              return true;
            })();
            """
            webView.evaluateJavaScript(js) { result, error in
                DispatchQueue.main.async {
                    notice = error == nil && (result as? Bool) == true
                      ? "Đã điền. Kiểm tra và bấm đăng nhập trên Facebook."
                      : "Không tìm thấy biểu mẫu phù hợp. Vui lòng nhập thủ công."
                }
            }
        } catch { notice = error.localizedDescription }
    }

    private func showTOTP() {
        do {
            let data = try SecureLoginStore.read(space.id)
            guard let code = SwiftTOTP.code(data.totp) else {
                notice = "Không có khóa 2FA TOTP hợp lệ."
                return
            }
            UIPasteboard.general.string = code
            let remain = 30 - (Int(Date().timeIntervalSince1970) % 30)
            notice = "Mã 2FA: \(code) (đã copy) — còn khoảng \(remain) giây."
        } catch { notice = error.localizedDescription }
    }

    @MainActor
    private func applySavedCookieAndReload() async {
        do {
            let vault = try SecureLoginStore.readTokenVault(space.id)
            let count = await WebCookieBridge.injectCookies(from: vault, into: space.id)
            if count > 0 {
                webView?.reload()
                notice = "Đã nạp \(count) cookie và tải lại trang."
            } else {
                notice = "Kho Token chưa có cookie nào để nạp."
            }
        } catch {
            notice = error.localizedDescription
        }
    }
}
