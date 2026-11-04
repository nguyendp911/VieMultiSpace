import SwiftUI
import Security
import CryptoKit
import WebKit
import UIKit

// MARK: - Models

struct SpaceLogin: Codable {
    var user: String
    var password: String
    var totp: String
    var machineId: String = ""
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
        var normalized = record
        normalized.user = cleanUser
        normalized.totp = cleanTotp
        if normalized.machineId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized.machineId = FacebookAPILoginClient.generateMachineId()
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
    static func getPublicKey() async throws -> (publicKey: String, keyId: String) {
        var components = URLComponents(string: "https://b-graph.facebook.com/pwd_key_fetch")!
        components.queryItems = [
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "flow", value: "CONTROLLER_INITIALIZATION"),
            URLQueryItem(name: "method", value: "GET"),
            URLQueryItem(name: "fb_api_req_friendly_name", value: "pwdKeyFetch"),
            URLQueryItem(name: "fb_api_caller_class", value: "com.facebook.auth.login.AuthOperations"),
            URLQueryItem(name: "access_token", value: "438142079694454|fc0a7caa49b192f64f6f5a6d9643bb28")
        ]
        guard let url = components.url else {
            throw SpaceLoginError.encryptionFailed("URL pwd_key_fetch không hợp lệ")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pubKey = json["public_key"] as? String else {
            throw SpaceLoginError.encryptionFailed("Không lấy được public_key từ Facebook")
        }
        let keyId: String
        if let idInt = json["key_id"] as? Int {
            keyId = String(idInt)
        } else if let idStr = json["key_id"] as? String {
            keyId = idStr
        } else {
            keyId = "25"
        }
        return (pubKey, keyId)
    }

    static func encrypt(password: String, publicKey: String? = nil, keyId: String = "25") async throws -> String {
        if password.hasPrefix("#PWD_FB4A") {
            return password
        }
        let resolvedKey: String
        let resolvedKeyId: String
        if let publicKey, !publicKey.isEmpty {
            resolvedKey = publicKey
            resolvedKeyId = keyId
        } else {
            let fetched = try await getPublicKey()
            resolvedKey = fetched.publicKey
            resolvedKeyId = fetched.keyId
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

        let currentTime = Int(Date().timeIntervalSince1970)
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
        return "#PWD_FB4A:2:\(currentTime):\(encoded)"
    }
}

// MARK: - Facebook Login + 2FA + Token Converter Service

enum FacebookAPILoginClient {
    private static let apiURL = URL(string: "https://b-graph.facebook.com/auth/login")!
    private static let convertURL = URL(string: "https://api.facebook.com/method/auth.getSessionforApp")!
    private static let accessToken = "350685531728|62f8ce9f74b12f84c123cc23437a4a32"
    private static let apiKey = "882a8490361da98702bf97a021ddc14d"
    private static let sig = "214049b9f17c38bd767de53752b53946"

    private static let baseHeaders: [String: String] = [
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

    static func generateMachineId() -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<24).compactMap { _ in chars.randomElement() })
    }

    private static func randomDigits(_ count: Int) -> String {
        let digits = Array("0123456789")
        return String((0..<count).compactMap { _ in digits.randomElement() })
    }

    private static func formEncode(_ params: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._* ")
        let pairs = params.map { key, value -> String in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed)?.replacingOccurrences(of: " ", with: "+") ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed)?.replacingOccurrences(of: " ", with: "+") ?? value
            return "\(k)=\(v)"
        }
        return Data(pairs.joined(separator: "&").utf8)
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

    static func convertToken(_ accessToken: String, app: FacebookAppTokens.AppInfo) async -> ConvertedTokenRecord? {
        var request = URLRequest(url: convertURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        let bodyParams = [
            "access_token": accessToken,
            "format": "json",
            "new_app_id": app.appId,
            "generate_session_cookies": "1"
        ]
        request.httpBody = formEncode(bodyParams)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["access_token"] as? String, !token.isEmpty else {
                return nil
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
            return nil
        }
    }

    static func convertAllTokens(from originalToken: String) async -> [String: ConvertedTokenRecord] {
        var converted: [String: ConvertedTokenRecord] = [:]
        for app in FacebookAppTokens.allApps {
            if let record = await convertToken(originalToken, app: app) {
                converted[app.key] = record
            }
        }
        return converted
    }

    static func login(
        uidPhoneMail: String,
        password: String,
        totpSecretOrCode: String,
        machineId: String? = nil,
        convertAll: Bool = true
    ) async throws -> SpaceTokenVault {
        let encryptedPassword = try await FacebookPasswordEncryptor.encrypt(password: password)
        let deviceId = UUID().uuidString.lowercased()
        let adid = UUID().uuidString.lowercased()
        let secureFamilyDeviceId = UUID().uuidString.lowercased()
        let resolvedMachineId = (machineId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? machineId!.trimmingCharacters(in: .whitespacesAndNewlines)
            : generateMachineId()
        let jazoest = randomDigits(5)
        let simSerial = randomDigits(20)

        let dataParams: [String: String] = [
            "format": "json",
            "email": uidPhoneMail,
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
            "account_switcher_uids": "[\"\(uidPhoneMail)\"]",
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

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        for (k, v) in baseHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.httpBody = formEncode(dataParams)

        let (respData, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any] else {
            throw SpaceLoginError.apiError("Phản hồi từ máy chủ không phải JSON hợp lệ.")
        }

        if let token = json["access_token"] as? String, !token.isEmpty {
            return await buildVault(uid: uidPhoneMail, responseJson: json, convertAll: convertAll)
        }

        if let errorObj = json["error"] as? [String: Any] {
            let errorData = errorObj["error_data"] as? [String: Any] ?? [:]
            if let firstFactor = errorData["login_first_factor"] as? String {
                let uidValue: String
                if let uidStr = errorData["uid"] as? String {
                    uidValue = uidStr
                } else if let uidNum = errorData["uid"] as? NSNumber {
                    uidValue = uidNum.stringValue
                } else {
                    uidValue = uidPhoneMail
                }

                guard !totpSecretOrCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw SpaceLoginError.apiError("Tài khoản yêu cầu 2FA nhưng chưa nhập khóa 2FA.")
                }
                guard let twofactorCode = SwiftTOTP.code(totpSecretOrCode) else {
                    throw SpaceLoginError.invalidSeed
                }

                let data2FA: [String: String] = [
                    "locale": "vi_VN",
                    "format": "json",
                    "email": uidPhoneMail,
                    "device_id": deviceId,
                    "access_token": accessToken,
                    "generate_session_cookies": "true",
                    "generate_machine_id": "1",
                    "twofactor_code": twofactorCode,
                    "credentials_type": "two_factor",
                    "error_detail_type": "button_with_disabled",
                    "first_factor": firstFactor,
                    "password": encryptedPassword,
                    "userid": uidValue,
                    "machine_id": firstFactor
                ]

                var req2FA = URLRequest(url: apiURL)
                req2FA.httpMethod = "POST"
                for (k, v) in baseHeaders {
                    req2FA.setValue(v, forHTTPHeaderField: k)
                }
                req2FA.httpBody = formEncode(data2FA)

                let (data2FAResp, _) = try await URLSession.shared.data(for: req2FA)
                guard let json2FA = try JSONSerialization.jsonObject(with: data2FAResp) as? [String: Any] else {
                    throw SpaceLoginError.apiError("Phản hồi 2FA không hợp lệ.")
                }

                if let token2FA = json2FA["access_token"] as? String, !token2FA.isEmpty {
                    return await buildVault(uid: uidValue, responseJson: json2FA, convertAll: convertAll)
                }

                if let err2FA = json2FA["error"] as? [String: Any] {
                    let userMsg = (err2FA["error_user_msg"] as? String) ?? (err2FA["message"] as? String) ?? "Lỗi xác thực 2FA"
                    throw SpaceLoginError.apiError(userMsg)
                }
            }

            let userMsg = (errorObj["error_user_msg"] as? String) ?? (errorObj["message"] as? String) ?? "Đăng nhập thất bại"
            throw SpaceLoginError.apiError(userMsg)
        }

        throw SpaceLoginError.apiError("Không nhận diện được phản hồi đăng nhập.")
    }

    private static func buildVault(uid: String, responseJson: [String: Any], convertAll: Bool) async -> SpaceTokenVault {
        let originalToken = (responseJson["access_token"] as? String) ?? ""
        let originalPrefix = FacebookAppTokens.extractTokenPrefix(originalToken)
        let parsedCookies = extractCookies(from: responseJson)
        let converted = convertAll ? await convertAllTokens(from: originalToken) : [:]

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

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [.plainText], asCopy: true)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        var onPicked: (String) -> Void
        init(onPicked: @escaping (String) -> Void) { self.onPicked = onPicked }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            onPicked(text)
        }
    }
}

struct TxtAccountPickerSheet: View {
    let accounts: [TxtAccount]
    var onSelect: (TxtAccount) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedId: UUID? = nil

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(accounts) { acc in
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
                        .onTapGesture { selectedId = acc.id }
                    }
                }
                .padding()
            }
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
                    TextField("Email / Số điện thoại / UID", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Mật khẩu hoặc #PWD_FB4A...", text: $password)
                    TextField("Khóa 2FA Base32 (hoặc mã 6 số)", text: $seed)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("Machine ID / datr (tùy chọn)", text: $machineId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.caption.monospaced())

                    Button {
                        showFilePicker = true
                    } label: {
                        Label("Nạp danh sách từ file TXT (uid|pass|2fa)", systemImage: "doc.text.below.ecg")
                            .font(.subheadline)
                    }
                    .disabled(isBusy)
                    .tint(.orange)

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
                        Label("Trích xuất & Lưu Cookie từ WebView hiện tại", systemImage: "arrow.down.doc.fill")
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
            .sheet(isPresented: $showFilePicker) {
                TxtDocumentPicker { text in
                    let accounts = parseTxtAccounts(text)
                    if accounts.isEmpty {
                        message = "File không có dòng hợp lệ.\nĐịnh dạng: uid|matkhau|2fa"
                    } else {
                        parsedTxtAccounts = accounts
                        showTxtAccountPicker = true
                    }
                }
            }
            .sheet(isPresented: $showTxtAccountPicker) {
                TxtAccountPickerSheet(accounts: parsedTxtAccounts) { acc in
                    username = acc.uid
                    password = acc.password
                    seed = acc.twoFA
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
            machineId = savedLogin.machineId
        }
        if let savedVault = try? SecureLoginStore.readTokenVault(space.id) {
            vault = savedVault
        }
    }


    private func parseTxtAccounts(_ text: String) -> [TxtAccount] {
        text.components(separatedBy: .newlines)
            .compactMap { line -> TxtAccount? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
                let parts = trimmed.components(separatedBy: "|")
                guard parts.count >= 2 else { return nil }
                let uid = parts[0].trimmingCharacters(in: .whitespaces)
                let pass = parts[1].trimmingCharacters(in: .whitespaces)
                let fa = parts.count >= 3 ? parts[2].trimmingCharacters(in: .whitespaces) : ""
                guard !pass.isEmpty else { return nil }
                return TxtAccount(uid: uid, password: pass, twoFA: fa)
            }
    }
    private func saveCredentialsOnly() {
        do {
            let resolvedMachine = machineId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? FacebookAPILoginClient.generateMachineId()
                : machineId.trimmingCharacters(in: .whitespacesAndNewlines)
            machineId = resolvedMachine
            try SecureLoginStore.save(
                SpaceLogin(user: username, password: password, totp: seed, machineId: resolvedMachine),
                for: space.id
            )
            message = "Đã lưu thông tin đăng nhập vào Keychain."
        } catch {
            message = error.localizedDescription
        }
    }

    @MainActor
    private func runAPILoginAndSaveToken() async {
        let cleanUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUser.isEmpty, !password.isEmpty else {
            message = SpaceLoginError.invalid.localizedDescription
            return
        }
        isBusy = true
        busyLabel = "Đang mã hóa mật khẩu, xác thực 2FA & convert 6 App Token..."
        defer { isBusy = false }

        do {
            let resolvedMachine = machineId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? FacebookAPILoginClient.generateMachineId()
                : machineId.trimmingCharacters(in: .whitespacesAndNewlines)
            machineId = resolvedMachine

            try SecureLoginStore.save(
                SpaceLogin(user: cleanUser, password: password, totp: seed, machineId: resolvedMachine),
                for: space.id
            )

            let newVault = try await FacebookAPILoginClient.login(
                uidPhoneMail: cleanUser,
                password: password,
                totpSecretOrCode: seed,
                machineId: resolvedMachine,
                convertAll: true
            )

            try SecureLoginStore.saveTokenVault(newVault, for: space.id)
            vault = newVault

            let injected = await WebCookieBridge.injectCookies(from: newVault, into: space.id)
            onReloadWebView?()
            message = "Đăng nhập thành công! Đã lưu Token (\(newVault.originalPrefix)), convert \(newVault.convertedTokens.count) App Token và nạp \(injected) cookie vào trình duyệt."
        } catch {
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
        let tokenTrimmed = manualToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let cookieTrimmed = manualCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        isBusy = true
        busyLabel = "Đang lưu và convert Token..."
        defer { isBusy = false }

        var converted: [String: ConvertedTokenRecord] = vault?.convertedTokens ?? [:]
        var cookies = FacebookAppTokens.parseCookieString(cookieTrimmed)
        var finalCookieString = cookieTrimmed

        if !tokenTrimmed.isEmpty {
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
            message = "Đã lưu Token vào Keychain (\(converted.count) App Tokens) và nạp \(count) cookie."
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
        let extracted = await WebCookieBridge.extractFacebookCookies(from: space.id)
        guard !extracted.isEmpty else {
            message = "Chưa có cookie Facebook nào trong trình duyệt của không gian này."
            return
        }
        let cookieStr = FacebookAppTokens.formatCookieString(extracted)
        let cUser = extracted.first(where: { $0.name == "c_user" })?.value ?? username
        let updated = SpaceTokenVault(
            uid: cUser,
            originalPrefix: vault?.originalPrefix ?? "",
            originalToken: vault?.originalToken ?? "",
            cookieString: cookieStr,
            cookies: extracted,
            convertedTokens: vault?.convertedTokens ?? [:],
            updatedAt: Date()
        )
        do {
            try SecureLoginStore.saveTokenVault(updated, for: space.id)
            vault = updated
            message = "Đã trích xuất và lưu \(extracted.count) cookie từ trình duyệt vào Keychain."
        } catch {
            message = error.localizedDescription
        }
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
            LoginEditorSheet(space: space) {
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
