import Foundation
import Network

// MARK: - Supported Proxy Protocols

enum ProxyProtocol: String, Codable, CaseIterable, Identifiable {
    case http = "HTTP"
    case https = "HTTPS"
    case socks5 = "SOCKS5"

    var id: String { rawValue }

    var defaultPort: UInt16 {
        switch self {
        case .http: return 8080
        case .https: return 8443
        case .socks5: return 1080
        }
    }

    var schemePrefix: String {
        switch self {
        case .http: return "http://"
        case .https: return "https://"
        case .socks5: return "socks5://"
        }
    }
}

// MARK: - Space Proxy Model

struct SpaceProxy: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var isEnabled: Bool = true
    var scheme: ProxyProtocol = .http
    var host: String
    var port: UInt16
    var username: String?
    var password: String?

    // Kết quả kiểm tra gần nhất
    var lastTestedIP: String?
    var lastTestedCountry: String?
    var lastTestedLatencyMs: Int?
    var lastTestedAt: Date?
    var lastTestError: String?

    var hasAuth: Bool {
        if let u = username, !u.isEmpty { return true }
        if let p = password, !p.isEmpty { return true }
        return false
    }

    /// Định dạng ngắn gọn hiển thị trên UI: [SOCKS5] 103.152.112.5:1080
    var displaySummary: String {
        let authHint = hasAuth ? " 🔒" : ""
        return "[\(scheme.rawValue)] \(host):\(port)\(authHint)"
    }

    /// Định dạng chi tiết để copy/export: socks5://user:***@host:port
    func displayURI(hidePassword: Bool = true) -> String {
        let auth: String
        if let u = username, !u.isEmpty {
            let p = hidePassword ? "***" : (password ?? "")
            auth = "\(u):\(p)@"
        } else {
            auth = ""
        }
        return "\(scheme.schemePrefix)\(auth)\(host):\(port)"
    }

    /// Chuyển đổi sang `ProxyConfiguration` của Network framework (iOS 17+)
    func toNetworkProxyConfiguration() -> ProxyConfiguration {
        let portEndpoint = NWEndpoint.Port(rawValue: port) ?? .http
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: portEndpoint)
        let config: ProxyConfiguration

        switch scheme {
        case .socks5:
            config = ProxyConfiguration(socksv5Proxy: endpoint)
        case .https:
            config = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: NWProtocolTLS.Options())
        case .http:
            config = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: nil)
        }

        if let user = username, !user.isEmpty, let pass = password, !pass.isEmpty {
            config.applyCredential(username: user, password: pass)
        }
        return config
    }
}

// MARK: - Multi-format Proxy Parser

enum ProxyParser {
    /// Phân tích 1 chuỗi proxy ở bất kỳ định dạng nào:
    /// - `host:port`
    /// - `host:port:user:pass`
    /// - `user:pass@host:port`
    /// - `socks5://host:port`
    /// - `socks5://user:pass@host:port`
    /// - `socks5://host:port:user:pass`
    /// - `http://...`, `https://...`, `socks5h://...`
    static func parse(_ rawInput: String, defaultScheme: ProxyProtocol = .http) -> SpaceProxy? {
        var clean = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }

        // Bỏ dấu nháy kép / nháy đơn nếu người dùng copy từ file JSON/CSV
        if clean.hasPrefix("\"") && clean.hasSuffix("\"") && clean.count >= 2 {
            clean = String(clean.dropFirst().dropLast())
        }
        if clean.hasPrefix("'") && clean.hasSuffix("'") && clean.count >= 2 {
            clean = String(clean.dropFirst().dropLast())
        }

        // Tách nhãn ghi chú nếu có (ví dụ: "1.2.3.4:8080:u:p | Vietnam Proxy")
        if let pipeIdx = clean.firstIndex(of: "|") {
            clean = String(clean[..<pipeIdx]).trimmingCharacters(in: .whitespaces)
        }
        if let hashIdx = clean.firstIndex(of: "#") {
            clean = String(clean[..<hashIdx]).trimmingCharacters(in: .whitespaces)
        }

        var scheme = defaultScheme
        let lower = clean.lowercased()

        if lower.hasPrefix("socks5://") || lower.hasPrefix("socks5h://") || lower.hasPrefix("socks://") {
            scheme = .socks5
            if let idx = clean.range(of: "://")?.upperBound {
                clean = String(clean[idx...])
            }
        } else if lower.hasPrefix("https://") {
            scheme = .https
            if let idx = clean.range(of: "://")?.upperBound {
                clean = String(clean[idx...])
            }
        } else if lower.hasPrefix("http://") {
            scheme = .http
            if let idx = clean.range(of: "://")?.upperBound {
                clean = String(clean[idx...])
            }
        }

        var host = ""
        var port: UInt16 = 0
        var username: String? = nil
        var password: String? = nil

        // Định dạng có `@`: user:pass@host:port hoặc user@host:port
        if clean.contains("@") {
            let atParts = clean.components(separatedBy: "@")
            guard atParts.count >= 2 else { return nil }
            let authPart = atParts[0]
            let hostPortPart = atParts[1]

            // Tách user:pass
            if authPart.contains(":") {
                let uParts = authPart.components(separatedBy: ":")
                username = uParts[0]
                password = uParts.dropFirst().joined(separator: ":")
            } else {
                username = authPart
            }

            // Tách host:port
            if hostPortPart.contains(":") {
                let hpParts = hostPortPart.components(separatedBy: ":")
                host = hpParts[0].trimmingCharacters(in: .whitespaces)
                if let p = UInt16(hpParts[1].trimmingCharacters(in: .whitespaces)) {
                    port = p
                }
            } else {
                host = hostPortPart.trimmingCharacters(in: .whitespaces)
                port = scheme.defaultPort
            }
        } else {
            // Định dạng tách bằng dấu `:`
            let parts = clean.components(separatedBy: ":")
            if parts.count == 2 {
                // host:port
                host = parts[0].trimmingCharacters(in: .whitespaces)
                if let p = UInt16(parts[1].trimmingCharacters(in: .whitespaces)) {
                    port = p
                }
            } else if parts.count == 4 {
                // host:port:user:pass
                host = parts[0].trimmingCharacters(in: .whitespaces)
                if let p = UInt16(parts[1].trimmingCharacters(in: .whitespaces)) {
                    port = p
                }
                username = parts[2].trimmingCharacters(in: .whitespaces)
                password = parts[3].trimmingCharacters(in: .whitespaces)
            } else if parts.count == 3 {
                // host:port:user
                host = parts[0].trimmingCharacters(in: .whitespaces)
                if let p = UInt16(parts[1].trimmingCharacters(in: .whitespaces)) {
                    port = p
                }
                username = parts[2].trimmingCharacters(in: .whitespaces)
            } else if parts.count > 4 {
                // Có thể là host:port:user:pass với pass có chứa ký tự `:`
                host = parts[0].trimmingCharacters(in: .whitespaces)
                if let p = UInt16(parts[1].trimmingCharacters(in: .whitespaces)) {
                    port = p
                }
                username = parts[2].trimmingCharacters(in: .whitespaces)
                password = parts.dropFirst(3).joined(separator: ":").trimmingCharacters(in: .whitespaces)
            }
        }

        // Bỏ dấu ngoặc vuông nếu là IPv6 (vd: [2001:db8::1])
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }

        guard !host.isEmpty, port > 0, port <= 65535 else {
            return nil
        }

        return SpaceProxy(
            isEnabled: true,
            scheme: scheme,
            host: host,
            port: port,
            username: (username?.isEmpty == false) ? username : nil,
            password: (password?.isEmpty == false) ? password : nil
        )
    }

    /// Phân tích nhiều dòng text proxy dán vào (mỗi hàng 1 proxy)
    static func parseMultipleLines(_ text: String, defaultScheme: ProxyProtocol = .http) -> [SpaceProxy] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { parse($0, defaultScheme: defaultScheme) }
    }
}

// MARK: - Proxy Connectivity Tester

enum ProxyTester {
    struct TestResult {
        var success: Bool
        var ip: String
        var country: String
        var latencyMs: Int
        var errorMessage: String?
    }

    /// Kiểm tra kết nối thực tế qua Proxy bằng cách gửi request qua URLSession proxy-routed
    static func test(proxy: SpaceProxy, timeoutSeconds: Double = 8) async -> TestResult {
        let startTime = Date()

        let config = URLSessionConfiguration.ephemeral
        config.proxyConfigurations = [proxy.toNetworkProxyConfiguration()]
        config.timeoutIntervalForRequest = timeoutSeconds
        config.timeoutIntervalForResource = timeoutSeconds + 2
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let session = URLSession(configuration: config)

        // Danh sách endpoint kiểm tra IP công khai
        let endpoints = [
            "https://api.ipify.org?format=json",
            "https://ipinfo.io/json"
        ]

        var lastError: Error?
        for endpointStr in endpoints {
            guard let url = URL(string: endpointStr) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")

            do {
                let (data, response) = try await session.data(for: request)
                let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)

                if let httpResp = response as? HTTPURLResponse, (200...299).contains(httpResp.statusCode) {
                    var detectedIP = ""
                    var detectedCountry = ""

                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if let ip = json["ip"] as? String { detectedIP = ip }
                        if let country = json["country"] as? String { detectedCountry = country }
                        if let city = json["city"] as? String, !city.isEmpty {
                            detectedCountry = detectedCountry.isEmpty ? city : "\(detectedCountry) - \(city)"
                        }
                    } else if let rawStr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !rawStr.isEmpty {
                        detectedIP = rawStr
                    }

                    if !detectedIP.isEmpty {
                        return TestResult(
                            success: true,
                            ip: detectedIP,
                            country: detectedCountry.isEmpty ? "Khả dụng" : detectedCountry,
                            latencyMs: elapsedMs,
                            errorMessage: nil
                        )
                    }
                }
            } catch {
                lastError = error
            }
        }

        let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
        let message = lastError?.localizedDescription ?? "Không thể kết nối qua Proxy (Quá thời gian chờ)."
        return TestResult(
            success: false,
            ip: "",
            country: "",
            latencyMs: elapsedMs,
            errorMessage: message
        )
    }
}

