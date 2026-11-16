import Foundation
import SwiftUI
import UserNotifications
import BackgroundTasks

// MARK: - Hạn mức an toàn mỗi ngày + tự tạm dừng khi gặp lỗi bất thường

enum ExchangeSafety {
    private static let capKey = "vie.exchange.dailyCap"
    private static let countsKey = "vie.exchange.dailyCounts.v1"
    private static let pausedKey = "vie.exchange.pausedUntil"
    private static let streakKey = "vie.exchange.failStreak"
    private static let lastActionKey = "vie.exchange.lastActionAt"
    private static let lock = NSLock()

    /// Số reaction tối đa mỗi tài khoản Facebook được thả trong 1 ngày (mặc định 30).
    static var dailyCap: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: capKey)
            return v == 0 ? 30 : min(max(v, 5), 200)
        }
        set { UserDefaults.standard.set(min(max(newValue, 5), 200), forKey: capKey) }
    }

    private static func dayString(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    private static func counts() -> [String: Int] {
        (UserDefaults.standard.dictionary(forKey: countsKey) as? [String: Int]) ?? [:]
    }

    /// Số reaction đã thả hôm nay (theo từng tài khoản, hoặc tổng nếu spaceId = nil).
    static func doneToday(space spaceId: UUID? = nil) -> Int {
        lock.lock(); defer { lock.unlock() }
        let today = dayString()
        return counts().filter { key, _ in
            guard key.hasPrefix(today + "|") else { return false }
            guard let spaceId else { return true }
            return key.hasSuffix(spaceId.uuidString)
        }.values.reduce(0, +)
    }

    static func recordSuccess(space spaceId: UUID) {
        lock.lock(); defer { lock.unlock() }
        var dict = counts()
        let today = dayString()
        dict["\(today)|\(spaceId.uuidString)", default: 0] += 1
        // Giữ lại 7 ngày gần nhất
        let cutoff = dayString(Date().addingTimeInterval(-7 * 86_400))
        dict = dict.filter { String($0.key.prefix(10)) >= cutoff }
        UserDefaults.standard.set(dict, forKey: countsKey)
        UserDefaults.standard.set(0, forKey: streakKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastActionKey)
    }

    /// Ghi nhận lỗi. Lỗi giống bị chặn/checkpoint -> dừng 6 giờ; lỗi thường 3 lần liên tiếp -> dừng 1 giờ.
    static func recordFailure(message: String) {
        lock.lock(); defer { lock.unlock() }
        let lower = message.lowercased()
        let hard = ["checkpoint", "blocked", "temporarily", "spam", "rate limit", "limit", "restricted",
                    "login", "cookie", "token", "190", "368", "expired", "hết hạn", "bị chặn"]
        let streak = UserDefaults.standard.integer(forKey: streakKey) + 1
        UserDefaults.standard.set(streak, forKey: streakKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastActionKey)
        if hard.contains(where: { lower.contains($0) }) {
            pause(hours: 6)
        } else if streak >= 3 {
            pause(hours: 1)
        }
    }

    private static func pause(hours: Double) {
        UserDefaults.standard.set(Date().addingTimeInterval(hours * 3600).timeIntervalSince1970, forKey: pausedKey)
        UserDefaults.standard.set(0, forKey: streakKey)
    }

    static var pausedUntil: Date? {
        let t = UserDefaults.standard.double(forKey: pausedKey)
        guard t > 0 else { return nil }
        let d = Date(timeIntervalSince1970: t)
        return d > Date() ? d : nil
    }

    static func clearPause() {
        UserDefaults.standard.removeObject(forKey: pausedKey)
        UserDefaults.standard.set(0, forKey: streakKey)
    }

    /// Có được thả thêm 1 reaction bằng tài khoản này lúc này không?
    static func canReact(space spaceId: UUID) -> (ok: Bool, reason: String?) {
        if let until = pausedUntil {
            let f = DateFormatter()
            f.dateStyle = .none
            f.timeStyle = .short
            return (false, "Tạm dừng an toàn đến \(f.string(from: until))")
        }
        let used = doneToday(space: spaceId)
        if used >= dailyCap {
            return (false, "Đã đạt hạn mức hôm nay (\(used)/\(dailyCap))")
        }
        return (true, nil)
    }

    /// Khoảng nghỉ tối thiểu giữa hai lần thả (giây), cộng thêm ngẫu nhiên.
    static func requiredDelay() -> Double {
        let last = UserDefaults.standard.double(forKey: lastActionKey)
        let sinceLast = last > 0 ? Date().timeIntervalSince1970 - last : 999
        let base = Double.random(in: 8...25)
        return sinceLast >= base ? Double.random(in: 3...8) : base - sinceLast + Double.random(in: 1...4)
    }
}

// MARK: - Thông báo cục bộ + huy hiệu số lệnh chờ

enum ExchangeNotifier {
    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional { return true }
        if settings.authorizationStatus == .denied { return false }
        return (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
    }

    static func notify(title: String, body: String, id: String = UUID().uuidString) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: id,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        UNUserNotificationCenter.current().add(req)
    }

    private static let reminderId = "vie.exchange.pending.reminder"

    /// Cập nhật huy hiệu và đặt nhắc việc nếu còn lệnh chưa thả.
    static func updatePendingReminder(count: Int) {
        let center = UNUserNotificationCenter.current()
        center.setBadgeCount(count)
        center.removePendingNotificationRequests(withIdentifiers: [reminderId])
        guard count > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = "Trao đổi reaction"
        content.body = "Bạn còn \(count) reaction cần thả. Mở app để hoàn tất."
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: reminderId,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2 * 3600, repeats: false)
        )
        center.add(req)
    }
}

// MARK: - Làm mới nền (BGAppRefreshTask): tranh thủ thả vài reaction khi iOS cho phép

enum ExchangeBackground {
    static let taskId = "vn.vie.multispace.exchange.refresh"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskId, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refresh)
        }
    }

    static func schedule() {
        guard ExchangeConfig.isConfigured || AIAutoPostEngine.hasEnabledPlansFlag else { return }
        let req = BGAppRefreshTaskRequest(identifier: taskId)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule()
        let work = Task { @MainActor in
            let spaces = SpaceLibrary.shared?.spaces ?? []
            // Cửa sổ nền rất ngắn: chỉ thả tối đa 2 lệnh mỗi lượt
            await ReactionExchangeManager.shared.refresh(spaces: spaces, maxTasks: 2)
            // AI đăng bài: đăng các bài đến giờ và giữ lịch luôn đầy
            await ScheduledPostManager.shared.checkAndExecuteDueTasks()
            await AIAutoPostEngine.shared.tick(spaces: spaces)
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }
}

// MARK: - Sức khỏe tài khoản (token / cookie còn sống không)

enum AccountHealthStatus: String {
    case ok, tokenExpired, cookieExpired, noCredentials, unknown

    var title: String {
        switch self {
        case .ok: return "Hoạt động tốt"
        case .tokenExpired: return "Token hết hạn"
        case .cookieExpired: return "Cookie hết phiên"
        case .noCredentials: return "Chưa có Token/Cookie"
        case .unknown: return "Chưa xác định"
        }
    }

    var isBad: Bool { self == .tokenExpired || self == .cookieExpired || self == .noCredentials }
}

struct AccountHealth: Identifiable {
    let id: UUID
    let name: String
    let status: AccountHealthStatus
    let checkedAt: Date
}

@MainActor
final class AccountHealthMonitor: ObservableObject {
    static let shared = AccountHealthMonitor()

    @Published private(set) var results: [UUID: AccountHealth] = [:]
    @Published private(set) var isChecking = false

    var badCount: Int { results.values.filter { $0.status.isBad }.count }

    private static let ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36"

    func checkAll(spaces: [Space]) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        let fb = spaces.filter { $0.platform == .facebook }
        var fresh: [UUID: AccountHealth] = [:]
        for space in fb {
            let status = await check(space)
            fresh[space.id] = AccountHealth(id: space.id, name: space.name, status: status, checkedAt: Date())

            if status.isBad, let old = results[space.id], !old.status.isBad {
                ExchangeNotifier.notify(
                    title: "Tài khoản cần đăng nhập lại",
                    body: "\(space.name): \(status.title)",
                    id: "vie.health.\(space.id.uuidString)"
                )
            }
        }
        results = fresh
    }

    private func makeSession(for space: Space) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.httpShouldSetCookies = false
        if let proxy = space.proxy, proxy.isEnabled {
            cfg.proxyConfigurations = [proxy.toNetworkProxyConfiguration()]
        }
        return URLSession(configuration: cfg)
    }

    private func check(_ space: Space) async -> AccountHealthStatus {
        let creds = await TrackedPostManager.resolveCookieAndToken(for: space)
        if creds.cookie.isEmpty && creds.token.isEmpty { return .noCredentials }
        let session = makeSession(for: space)

        // 1. Token: gọi Graph API /me
        var tokenState: Bool? = nil // true = sống, false = chết, nil = không rõ / không có
        if !creds.token.isEmpty,
           var comps = URLComponents(string: "https://graph.facebook.com/me") {
            comps.queryItems = [
                URLQueryItem(name: "fields", value: "id"),
                URLQueryItem(name: "access_token", value: creds.token)
            ]
            if let url = comps.url, let (data, resp) = try? await session.data(from: url),
               let http = resp as? HTTPURLResponse {
                if http.statusCode == 200 {
                    tokenState = true
                } else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let err = json["error"] as? [String: Any],
                          let code = err["code"] as? Int, code == 190 {
                    tokenState = false
                }
            }
        }

        // 2. Cookie: tải trang chủ và đọc USER_ID
        var cookieState: Bool? = nil
        if !creds.cookie.isEmpty, let url = URL(string: "https://www.facebook.com/") {
            var req = URLRequest(url: url)
            req.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
            req.setValue(creds.cookie, forHTTPHeaderField: "Cookie")
            req.setValue("vi,en-US;q=0.8", forHTTPHeaderField: "Accept-Language")
            if let (data, _) = try? await session.data(for: req),
               let html = String(data: data, encoding: .utf8) {
                if let uid = FacebookTargetPostResolver.firstMatch(pattern: #""USER_ID":"(\d+)""#, in: html) {
                    cookieState = (uid != "0")
                } else if html.contains("login_form") || html.contains("id=\"email\"") {
                    cookieState = false
                }
            }
        }

        if tokenState == true || cookieState == true { return .ok }
        if cookieState == false && (creds.token.isEmpty || tokenState == false) { return .cookieExpired }
        if tokenState == false && creds.cookie.isEmpty { return .tokenExpired }
        if cookieState == false { return .cookieExpired }
        if tokenState == false { return .tokenExpired }
        return .unknown
    }
}
