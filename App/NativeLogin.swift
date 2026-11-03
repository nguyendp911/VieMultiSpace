import SwiftUI
import Security
import CryptoKit
import WebKit

// Swift port of local TOTP and account storage. No private Facebook login API.
struct SpaceLogin: Codable {
    var user: String
    var password: String
    var totp: String
}

enum SpaceLoginError: LocalizedError {
    case invalid, missing, invalidSeed, keychain(OSStatus)
    var errorDescription: String? {
        switch self {
        case .invalid: return "Nhập email / UID và mật khẩu."
        case .missing: return "Chưa lưu đăng nhập cho không gian này."
        case .invalidSeed: return "Khóa TOTP Base32 không hợp lệ."
        case .keychain(let code): return "Keychain báo lỗi \(code)."
        }
    }
}

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

    static func code(_ seed: String, at date: Date = Date()) -> String? {
        guard let data = decode(seed) else { return nil }
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

enum SecureLoginStore {
    private static let service = "vn.vie.multispace.credentials"
    private static func key(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrAccount as String: id.uuidString,
         kSecAttrService as String: service]
    }

    static func save(_ record: SpaceLogin, for id: UUID) throws {
        guard !record.user.trimmingCharacters(in: .whitespaces).isEmpty,
              !record.password.isEmpty else { throw SpaceLoginError.invalid }
        if !record.totp.isEmpty && SwiftTOTP.decode(record.totp) == nil {
            throw SpaceLoginError.invalidSeed
        }
        guard let control = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence, nil) else { throw SpaceLoginError.keychain(errSecParam) }
        var q = key(id)
        q[kSecValueData as String] = try JSONEncoder().encode(record)
        q[kSecAttrAccessControl as String] = control
        SecItemDelete(key(id) as CFDictionary)
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw SpaceLoginError.keychain(status) }
    }

    static func read(_ id: UUID) throws -> SpaceLogin {
        var q = key(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecUseOperationPrompt as String] = "Xác thực để mở đăng nhập đã lưu"
        var raw: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &raw)
        if status == errSecItemNotFound { throw SpaceLoginError.missing }
        guard status == errSecSuccess else { throw SpaceLoginError.keychain(status) }
        guard let data = raw as? Data else { throw SpaceLoginError.keychain(errSecDecode) }
        return try JSONDecoder().decode(SpaceLogin.self, from: data)
    }

    static func remove(_ id: UUID) {
        SecItemDelete(key(id) as CFDictionary)
    }
}

struct LoginEditorSheet: View {
    let space: Space
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var seed = ""
    @State private var showDelete = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(space.name) {
                    TextField("Email / Số điện thoại / UID", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Mật khẩu", text: $password)
                    SecureField("Khóa 2FA Base32 (không bắt buộc)", text: $seed)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }
                Section {
                    Text("Lưu riêng cho không gian này trên iPhone. Mỗi lần đọc, hệ thống yêu cầu Face ID / Touch ID / mã máy.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Xóa thông tin đăng nhập đã lưu", role: .destructive) {
                        showDelete = true
                    }
                }
            }
            .navigationTitle("Thông tin đăng nhập")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Hủy") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Lưu") {
                        do {
                            try SecureLoginStore.save(
                                SpaceLogin(user: username, password: password, totp: seed),
                                for: space.id)
                            dismiss()
                        } catch { message = error.localizedDescription }
                    }
                }
            }
            .confirmationDialog("Xóa mật khẩu và mã 2FA đã lưu?", isPresented: $showDelete) {
                Button("Xóa", role: .destructive) {
                    SecureLoginStore.remove(space.id)
                    dismiss()
                }
            }
            .alert("Thông báo", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button("OK") { message = nil }
            } message: { Text(message ?? "") }
        }
    }
}

// Explicit tap-only autofill; refuses non-Facebook URLs and never submits.
struct SecureLoginControls: View {
    let space: Space
    let webView: WKWebView?
    @State private var notice: String?

    var body: some View {
        HStack(spacing: 12) {
            Button { autofill() } label: {
                Label("Điền đăng nhập", systemImage: "key.fill")
            }
            Button { showTOTP() } label: {
                Label("Mã 2FA", systemImage: "lock.shield")
            }
        }
        .font(.caption)
        .buttonStyle(.bordered)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
            let remain = 30 - (Int(Date().timeIntervalSince1970) % 30)
            notice = "Mã 2FA: \(code) — còn khoảng \(remain) giây."
        } catch { notice = error.localizedDescription }
    }
}
