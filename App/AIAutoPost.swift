import SwiftUI
import Foundation
import UIKit

// MARK: - Mô hình dữ liệu kế hoạch AI đăng bài

/// Khung giờ đăng. weekdays dùng quy ước Calendar: 1 = Chủ nhật ... 7 = Thứ bảy.
struct AIPostSlot: Codable, Hashable, Identifiable {
    var id = UUID()
    var hour: Int
    var minute: Int
    var weekdays: Set<Int> = [1, 2, 3, 4, 5, 6, 7]

    var label: String { String(format: "%02d:%02d", hour, minute) }

    /// Khung giờ vàng phổ biến của người dùng Việt Nam (sáng, trưa, tối)
    static let defaultGolden: [AIPostSlot] = [
        AIPostSlot(hour: 7, minute: 30),
        AIPostSlot(hour: 11, minute: 45),
        AIPostSlot(hour: 19, minute: 30),
        AIPostSlot(hour: 21, minute: 15)
    ]
}

enum AITopicMode: String, Codable, CaseIterable, Identifiable {
    case userList = "Theo danh sách chủ đề của tôi"
    case aiSuggest = "AI tự nghĩ chủ đề theo lĩnh vực"
    var id: String { rawValue }
}

enum AIImageMode: String, Codable, CaseIterable, Identifiable {
    case none = "Không dùng ảnh"
    case ai = "AI tạo ảnh minh họa"
    var id: String { rawValue }
}

enum AIPostLength: String, Codable, CaseIterable, Identifiable {
    case short = "Ngắn (2-3 câu)"
    case medium = "Vừa (4-6 câu)"
    case long = "Dài (bài chia sẻ chi tiết)"
    var id: String { rawValue }

    var instruction: String {
        switch self {
        case .short: return "2 đến 3 câu ngắn gọn, súc tích"
        case .medium: return "4 đến 6 câu, có mở bài và ý chính rõ ràng"
        case .long: return "một bài chia sẻ chi tiết 8 đến 12 câu, chia đoạn dễ đọc"
        }
    }
}

struct AIPlanTarget: Codable, Hashable, Identifiable {
    var spaceId: UUID
    var spaceName: String
    var kind: SmartPostDestinationType
    var destination: FacebookDestinationItem?   // nil = trang cá nhân của tài khoản đó

    var id: String { "\(kind.rawValue)|\(spaceId.uuidString)|\(destination?.id ?? "me")" }
}

struct AIAutoPlan: Codable, Identifiable {
    var id = UUID()
    var name: String = "Kế hoạch mới"
    var isEnabled: Bool = true
    var targets: [AIPlanTarget] = []

    // Nội dung
    var niche: String = ""
    var topicMode: AITopicMode = .aiSuggest
    var topics: [String] = []
    var topicCursor: Int = 0
    var styleNotes: String = ""
    var useBrandProfile: Bool = true
    var length: AIPostLength = .medium
    var hashtagCount: Int = 3
    var includeEmoji: Bool = true
    var includeCTA: Bool = false

    // Ảnh
    var imageMode: AIImageMode = .ai
    var imageStyle: String = "ảnh minh họa chất lượng cao, màu sắc tươi sáng, bố cục gọn, không có chữ trong ảnh"
    var textOnlyIfImageFails: Bool = true
    var appendAIDisclosure: Bool = true

    // Lịch
    var slots: [AIPostSlot] = AIPostSlot.defaultGolden
    var jitterMinutes: Int = 10
    var daysAhead: Int = 2
    var leadHours: Int = 12
    var maxPostsPerDayPerKind: Int = 2
    var minGapHours: Int = 3
    var lateToleranceMinutes: Int = 45
    var requireApproval: Bool = false
    var useNativePageSchedule: Bool = true
    var privacy: SmartPostPrivacy = .everyone

    // Trạng thái chạy
    var generatedSlotKeys: [String] = []
    var recentCaptions: [String] = []
    var recentTopics: [String] = []
    var createdAt: Date = Date()
}

struct GeneratedPost {
    var topic: String
    var caption: String
    var hashtags: [String]
    var imagePrompt: String
    var image: UIImage?
}

// MARK: - Gemini: sinh nội dung và ảnh

enum GeminiContentClient {
    private static let fallbackTextModels = ["gemini-flash-latest", "gemini-2.5-flash", "gemini-2.5-flash-lite"]
    private static let fallbackImageModels = [
        "gemini-2.5-flash-image", "gemini-2.5-flash-image-preview", "gemini-3-pro-image-preview"
    ]

    private static func textModels(apiKey: String) async -> [String] {
        let preferred = UserDefaults.standard.string(forKey: "vie.auto.geminiModelV2") ?? "auto"
        if preferred != "auto" && !preferred.isEmpty { return [preferred] + fallbackTextModels }
        let discovered = await GeminiCommentService.discoverAvailableModels(apiKey: apiKey)
            .filter { !$0.lowercased().contains("image") }
        return Array((discovered.prefix(3) + fallbackTextModels).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        })
    }

    private static func post(model: String, apiKey: String, body: [String: Any]) async throws -> (Int, Data) {
        let clean = model.replacingOccurrences(of: "models/", with: "")
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(clean):generateContent?key=\(apiKey)") else {
            throw SpaceLoginError.apiError("URL model không hợp lệ")
        }
        var req = URLRequest(url: url, timeoutInterval: 90)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    /// Sinh nội dung dạng JSON. Thử lần lượt các model khả dụng.
    static func generateJSON(prompt: String, apiKey: String, temperature: Double = 0.95) async throws -> [String: Any] {
        var lastError = "Không có model khả dụng."
        for model in await textModels(apiKey: apiKey) {
            let body: [String: Any] = [
                "contents": [["parts": [["text": prompt]]]],
                "generationConfig": [
                    "temperature": temperature,
                    "maxOutputTokens": 2400,
                    "responseMimeType": "application/json"
                ]
            ]
            guard let (status, data) = try? await post(model: model, apiKey: apiKey, body: body) else { continue }
            if status == 401 || status == 403 {
                throw SpaceLoginError.apiError("Gemini API Key không hợp lệ hoặc bị từ chối (\(status)).")
            }
            guard status == 200,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let parts = ((root["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]] else {
                lastError = "Model \(model) lỗi (\(status))"
                continue
            }
            var text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            text = text.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
            if let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b {
                text = String(text[a...b])
            }
            if let d = text.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                return obj
            }
            lastError = "Model \(model) trả về JSON không hợp lệ"
        }
        throw SpaceLoginError.apiError(lastError)
    }

    private static func imageModels(apiKey: String) async -> [String] {
        var found: [String] = []
        if let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(apiKey)"),
           let (data, resp) = try? await URLSession.shared.data(from: url),
           (resp as? HTTPURLResponse)?.statusCode == 200,
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let models = root["models"] as? [[String: Any]] {
            for m in models {
                guard let raw = m["name"] as? String else { continue }
                let methods = m["supportedGenerationMethods"] as? [String] ?? []
                let name = raw.replacingOccurrences(of: "models/", with: "")
                let lower = name.lowercased()
                if methods.contains("generateContent"), lower.hasPrefix("gemini"), lower.contains("image") {
                    found.append(name)
                }
            }
        }
        found.sort { ($0.contains("flash") ? 0 : 1) < ($1.contains("flash") ? 0 : 1) }
        return found + fallbackImageModels.filter { !found.contains($0) }
    }

    /// Tạo ảnh minh họa. Trả về nil nếu không model nào tạo được (ví dụ gói miễn phí không hỗ trợ).
    static func generateImage(prompt: String, apiKey: String) async -> UIImage? {
        for model in await imageModels(apiKey: apiKey).prefix(4) {
            let body: [String: Any] = [
                "contents": [["parts": [["text": prompt]]]],
                "generationConfig": ["responseModalities": ["IMAGE", "TEXT"]]
            ]
            guard let (status, data) = try? await post(model: model, apiKey: apiKey, body: body), status == 200,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let parts = ((root["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]] else {
                continue
            }
            for part in parts {
                let inline = (part["inlineData"] as? [String: Any]) ?? (part["inline_data"] as? [String: Any])
                if let b64 = inline?["data"] as? String,
                   let imgData = Data(base64Encoded: b64),
                   let img = UIImage(data: imgData) {
                    return downscale(img, maxDimension: 1600)
                }
            }
        }
        return nil
    }

    private static func downscale(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        return UIGraphicsImageRenderer(size: newSize).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

// MARK: - Hẹn giờ gốc của Facebook cho Fanpage (đăng được cả khi tắt app)

extension SmartPostAPIClient {
    /// Hẹn giờ đăng bài lên Fanpage ngay trên máy chủ Facebook (published=false + scheduled_publish_time).
    /// Thời điểm hẹn phải cách hiện tại từ 10 phút đến 30 ngày. Không bao giờ đăng ngay: lỗi thì ném ra.
    static func schedulePagePost(
        pageId: String,
        caption: String,
        imageData: Data?,
        userToken: String,
        pageToken: String?,
        publishAt: Date
    ) async throws -> String {
        let unix = Int(publishAt.timeIntervalSince1970)
        guard publishAt.timeIntervalSinceNow >= 10 * 60, publishAt.timeIntervalSinceNow <= 29 * 86_400 else {
            throw NSError(domain: "AIAutoPost", code: -2, userInfo: [NSLocalizedDescriptionKey: "Thời điểm hẹn phải cách hiện tại 10 phút đến 30 ngày."])
        }

        var token = pageToken ?? ""
        if token.isEmpty, let u = URL(string: "https://graph.facebook.com/\(pageId)?fields=access_token") {
            var req = URLRequest(url: u, timeoutInterval: 15)
            req.setValue("OAuth \(userToken)", forHTTPHeaderField: "authorization")
            if let (d, _) = try? await URLSession.shared.data(for: req),
               let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let t = j["access_token"] as? String, !t.isEmpty {
                token = t
            }
        }
        guard !token.isEmpty else {
            throw NSError(domain: "AIAutoPost", code: -3, userInfo: [NSLocalizedDescriptionKey: "Không lấy được Page Access Token (cần quyền quản lý Page)."])
        }

        var params: [String: String] = [
            "message": caption,
            "published": "false",
            "scheduled_publish_time": "\(unix)",
            "unpublished_content_type": "SCHEDULED",
            "access_token": token
        ]
        if let imageData {
            let photoId = try await uploadPhoto(imageData: imageData, accessToken: token, targetId: pageId)
            params["attached_media[0]"] = "{\"media_fbid\":\"\(photoId)\"}"
        }

        guard let url = URL(string: "https://graph.facebook.com/\(pageId)/feed") else {
            throw NSError(domain: "AIAutoPost", code: -1, userInfo: [NSLocalizedDescriptionKey: "Page ID không hợp lệ"])
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        request.httpBody = params.map { k, v in
            let ek = k.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? k
            let ev = v.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? v
            return "\(ek)=\(ev)"
        }.joined(separator: "&").data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: request)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = json["id"] as? String, !id.isEmpty {
            return id
        }
        let errText = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
        throw NSError(domain: "AIAutoPost", code: status, userInfo: [NSLocalizedDescriptionKey: "Hẹn giờ Page lỗi: \(formatFacebookAPIError(errText))"])
    }
}

// MARK: - Engine: giữ lịch đăng luôn đầy, sinh nội dung đúng khung giờ vàng

@MainActor
final class AIAutoPostEngine: ObservableObject {
    static let shared = AIAutoPostEngine()

    @Published var plans: [AIAutoPlan] = []
    @Published var isWorking = false
    @Published var logLines: [String] = []

    private let storeKey = "vie.aiautopost.plans.v1"
    private var timer: Timer?

    init() {
        load()
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
    }

    // MARK: Lưu trữ

    private func load() {
        if let data = UserDefaults.standard.data(forKey: storeKey),
           let decoded = try? JSONDecoder().decode([AIAutoPlan].self, from: data) {
            plans = decoded
        }
        syncEnabledFlag()
    }

    func save() {
        if let data = try? JSONEncoder().encode(plans) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
        syncEnabledFlag()
    }

    private func syncEnabledFlag() {
        UserDefaults.standard.set(plans.contains { $0.isEnabled }, forKey: "vie.aiautopost.hasEnabled")
    }

    static var hasEnabledPlansFlag: Bool {
        UserDefaults.standard.bool(forKey: "vie.aiautopost.hasEnabled")
    }

    func upsert(_ plan: AIAutoPlan) {
        if let i = plans.firstIndex(where: { $0.id == plan.id }) { plans[i] = plan } else { plans.append(plan) }
        save()
    }

    func delete(_ plan: AIAutoPlan) {
        plans.removeAll { $0.id == plan.id }
        save()
    }

    private func log(_ line: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        logLines.insert("[\(f.string(from: Date()))] \(line)", at: 0)
        if logLines.count > 60 { logLines.removeLast(logLines.count - 60) }
    }

    // MARK: Khung giờ vàng gợi ý từ dữ liệu của chính người dùng

    /// Phân tích giờ đăng các bài đã theo dõi để tìm giờ có tương tác trung bình cao nhất.
    /// Cần ít nhất 8 bài; nếu không đủ trả về khung giờ phổ biến mặc định.
    func suggestGoldenSlots() -> (slots: [AIPostSlot], basedOnData: Bool) {
        let posts = TrackedPostManager.shared.posts.filter { $0.reactionCount + $0.commentCount + $0.shareCount > 0 }
        guard posts.count >= 8 else { return (AIPostSlot.defaultGolden, false) }
        var buckets: [Int: (sum: Double, n: Int)] = [:]
        let cal = Calendar.current
        for p in posts {
            let h = cal.component(.hour, from: p.createdAt)
            let score = Double(p.reactionCount + 2 * p.commentCount + 3 * p.shareCount)
            let cur = buckets[h] ?? (0, 0)
            buckets[h] = (cur.sum + score, cur.n + 1)
        }
        let ranked = buckets.filter { $0.value.n >= 2 }
            .map { (hour: $0.key, avg: $0.value.sum / Double($0.value.n)) }
            .sorted { $0.avg > $1.avg }
            .prefix(3)
            .map { AIPostSlot(hour: $0.hour, minute: 0) }
            .sorted { $0.hour < $1.hour }
        return ranked.isEmpty ? (AIPostSlot.defaultGolden, false) : (Array(ranked), true)
    }

    // MARK: Sinh một bài

    private func prompt(plan: AIAutoPlan, kind: SmartPostDestinationType, fire: Date, forcedTopic: String?) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "vi_VN")
        df.dateFormat = "EEEE, dd/MM, HH:mm"

        let placeText: String
        switch kind {
        case .personalProfile: placeText = "Trang cá nhân (giọng chia sẻ cá nhân, gần gũi, chân thật)"
        case .group: placeText = "Nhóm cộng đồng (giọng thân thiện, đặt một câu hỏi mở để gợi thảo luận, KHÔNG quảng cáo lộ liễu, không chèn link)"
        case .fanpage: placeText = "Fanpage thương hiệu (giọng chuyên nghiệp, thân thiện, có định hướng thương hiệu)"
        }

        var topicLine: String
        if let forced = forcedTopic, !forced.isEmpty {
            topicLine = "Chủ đề bắt buộc: \(forced)"
        } else {
            topicLine = "Hãy tự chọn 1 chủ đề MỚI, hấp dẫn, phù hợp lĩnh vực và thời điểm đăng (\(df.string(from: fire)))."
            if !plan.recentTopics.isEmpty {
                topicLine += " Tránh các chủ đề đã dùng gần đây: " + plan.recentTopics.suffix(10).joined(separator: "; ") + "."
            }
        }

        var sections: [String] = []
        sections.append("""
        Bạn là chuyên gia nội dung mạng xã hội Facebook tại Việt Nam. Hãy tạo MỘT bài đăng hoàn chỉnh.

        # Bối cảnh
        - Nơi đăng: \(placeText)
        - Lĩnh vực / chủ đề chung: \(plan.niche.isEmpty ? "đời sống, chia sẻ hữu ích" : plan.niche)
        - \(topicLine)
        - Độ dài: \(plan.length.instruction)
        - Emoji: \(plan.includeEmoji ? "dùng vừa phải, tự nhiên" : "không dùng emoji")
        - Số hashtag: \(plan.hashtagCount)
        - Kêu gọi hành động: \(plan.includeCTA ? "có 1 câu kêu gọi nhẹ nhàng ở cuối" : "không cần")
        """)

        if !plan.styleNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("- Phong cách bổ sung: \(plan.styleNotes)")
        }

        var banned = ""
        if plan.useBrandProfile {
            let p = AITrainingStore.shared.profile
            sections.append("""
            # Thương hiệu (chỉ dùng thông tin này, không bịa thêm)
            - Tên: \(p.brandName)
            - Giọng điệu: \(p.toneVoice)
            - Sản phẩm / dịch vụ: \(p.productCatalog)
            """)
            banned = p.bannedWords
        }

        if !plan.recentCaptions.isEmpty {
            let list = plan.recentCaptions.suffix(5).map { "- \"\(String($0.prefix(90)))\"" }.joined(separator: "\n")
            sections.append("# Không lặp lại ý và cách mở bài của các bài gần đây\n\(list)")
        }

        sections.append("""
        # Quy tắc bắt buộc
        - Tiếng Việt tự nhiên như người thật viết, không văn mẫu, không nhắc mình là AI.
        - Không bịa số liệu, không cam kết y tế / tài chính, không nội dung chính trị, nhạy cảm, đả kích hay gây hiểu lầm.
        \(banned.isEmpty ? "" : "- Tuyệt đối không dùng các từ: \(banned)")

        # Đầu ra: CHỈ một JSON hợp lệ
        {"topic": "chủ đề ngắn gọn", "caption": "nội dung bài đăng (không gồm hashtag)", "hashtags": ["#a", "#b"], "image_prompt": "mô tả ảnh minh họa bằng TIẾNG ANH, \(plan.imageStyle)"}
        """)

        return sections.joined(separator: "\n\n")
    }

    private func similarity(_ a: String, _ b: String) -> Double {
        let wa = Set(a.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        let wb = Set(b.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        guard !wa.isEmpty, !wb.isEmpty else { return 0 }
        return Double(wa.intersection(wb).count) / Double(wa.union(wb).count)
    }

    private func bannedHit(_ text: String, plan: AIAutoPlan) -> Bool {
        guard plan.useBrandProfile else { return false }
        let words = AITrainingStore.shared.profile.bannedWords
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        let lower = text.lowercased()
        return words.contains { lower.contains($0) }
    }

    /// Sinh một bài (nội dung + chủ đề + ảnh). Tự thử lại nếu trùng bài cũ hoặc dính từ cấm.
    func generatePost(plan: AIAutoPlan, kind: SmartPostDestinationType, fire: Date, withImage: Bool = true) async throws -> GeneratedPost {
        let apiKey = SecureGeminiStore.readKey()
        guard !apiKey.isEmpty else { throw SpaceLoginError.apiError("Chưa nhập Gemini API Key.") }

        var forcedTopic: String? = nil
        if plan.topicMode == .userList {
            let list = plan.topics.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if !list.isEmpty { forcedTopic = list[plan.topicCursor % list.count] }
        }

        var result: [String: Any] = [:]
        var caption = ""
        for attempt in 0..<3 {
            result = try await GeminiContentClient.generateJSON(
                prompt: prompt(plan: plan, kind: kind, fire: fire, forcedTopic: forcedTopic),
                apiKey: apiKey,
                temperature: min(1.2, 0.9 + Double(attempt) * 0.15)
            )
            caption = ((result["caption"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if caption.isEmpty { continue }
            if bannedHit(caption, plan: plan) { caption = ""; continue }
            if plan.recentCaptions.contains(where: { similarity($0, caption) > 0.6 }) { caption = ""; continue }
            break
        }
        guard !caption.isEmpty else {
            throw SpaceLoginError.apiError("AI không tạo được nội dung phù hợp (trùng bài cũ hoặc dính từ cấm).")
        }

        let topic = ((result["topic"] as? String) ?? forcedTopic ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = (result["hashtags"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0.hasPrefix("#") ? $0 : "#" + $0.replacingOccurrences(of: " ", with: "") }
            .prefix(plan.hashtagCount)
        let imagePrompt = ((result["image_prompt"] as? String) ?? "\(topic), \(plan.imageStyle)")

        var image: UIImage? = nil
        if withImage && plan.imageMode == .ai {
            image = await GeminiContentClient.generateImage(
                prompt: "Create an image for a Facebook post. \(imagePrompt). \(plan.imageStyle). No text, no watermark, no logos.",
                apiKey: apiKey
            )
        }

        return GeneratedPost(topic: topic, caption: caption, hashtags: Array(tags), imagePrompt: imagePrompt, image: image)
    }

    /// Ghép nội dung cuối cùng: caption + hashtag + dòng công khai ảnh AI.
    func finalCaption(_ post: GeneratedPost, plan: AIAutoPlan) -> String {
        var text = post.caption
        if !post.hashtags.isEmpty { text += "\n\n" + post.hashtags.joined(separator: " ") }
        if post.image != nil && plan.appendAIDisclosure { text += "\n\n(Ảnh minh họa do AI tạo)" }
        return text
    }

    // MARK: Chạy kế hoạch

    func tick(spaces: [Space]? = nil, forceHorizonHours: Int? = nil) async {
        guard !isWorking else { return }
        let spaceList = spaces ?? SpaceLibrary.shared?.spaces ?? []
        for plan in plans where plan.isEnabled {
            await fill(planId: plan.id, spaces: spaceList, horizonHours: forceHorizonHours)
        }
        ScheduledPostManager.shared.saveTasks()
    }

    private func dayString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: d)
    }

    /// Sinh bài cho các khung giờ sắp tới của một kế hoạch. Trả về số bài đã tạo.
    @discardableResult
    func fill(planId: UUID, spaces: [Space], horizonHours: Int? = nil) async -> Int {
        guard let initial = plans.first(where: { $0.id == planId }), initial.isEnabled || horizonHours != nil else { return 0 }
        guard !SecureGeminiStore.readKey().isEmpty else {
            log("⚠️ \(initial.name): chưa có Gemini API Key.")
            return 0
        }
        guard !initial.targets.isEmpty else {
            log("⚠️ \(initial.name): chưa chọn nơi đăng.")
            return 0
        }
        isWorking = true
        defer { isWorking = false }

        let cal = Calendar.current
        let now = Date()
        let horizon = TimeInterval(horizonHours ?? initial.leadHours) * 3600
        var created = 0

        let kinds: [SmartPostDestinationType] = [.personalProfile, .group, .fanpage]

        for dayOffset in 0...max(1, initial.daysAhead) {
            guard let day = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: now)) else { continue }
            let weekday = cal.component(.weekday, from: day)

            for slot in initial.slots where slot.weekdays.contains(weekday) {
                guard let base = cal.date(bySettingHour: slot.hour, minute: slot.minute, second: 0, of: day) else { continue }

                for kind in kinds {
                    guard var plan = plans.first(where: { $0.id == planId }) else { return created }
                    let targets = plan.targets.filter { $0.kind == kind }
                    guard !targets.isEmpty else { continue }

                    let key = "\(dayString(base))|\(slot.label)|\(kind.rawValue)"
                    guard !plan.generatedSlotKeys.contains(key) else { continue }

                    // Độ lệch ngẫu nhiên để không đăng đúng từng phút một cách máy móc
                    let jitter = plan.jitterMinutes > 0 ? Int.random(in: -plan.jitterMinutes...plan.jitterMinutes) : 0
                    let fire = base.addingTimeInterval(TimeInterval(jitter * 60))
                    guard fire.timeIntervalSince(now) >= 12 * 60, fire.timeIntervalSince(now) <= horizon else { continue }

                    // Hạn mức và giãn cách theo từng loại nơi đăng
                    let existing = ScheduledPostManager.shared.tasks.filter {
                        $0.aiPlanId == plan.id && ($0.destinationType ?? .personalProfile) == kind && $0.status != .failed
                    }
                    let sameDay = existing.filter { cal.isDate($0.scheduledDate, inSameDayAs: fire) }.count
                    if sameDay >= plan.maxPostsPerDayPerKind { continue }
                    if existing.contains(where: { abs($0.scheduledDate.timeIntervalSince(fire)) < Double(plan.minGapHours) * 3600 }) { continue }

                    // Đánh dấu trước để không sinh lặp nếu lỗi giữa chừng
                    plan.generatedSlotKeys.append(key)
                    if plan.generatedSlotKeys.count > 400 { plan.generatedSlotKeys.removeFirst(100) }
                    upsert(plan)

                    do {
                        let generated = try await generatePost(plan: plan, kind: kind, fire: fire)
                        if plan.imageMode == .ai, generated.image == nil, !plan.textOnlyIfImageFails {
                            log("⚠️ \(plan.name): không tạo được ảnh, bỏ qua bài lúc \(slot.label).")
                            continue
                        }
                        let caption = finalCaption(generated, plan: plan)
                        let ok = await enqueue(plan: plan, kind: kind, targets: targets, caption: caption,
                                               image: generated.image, fire: fire, spaces: spaces)
                        if ok {
                            created += 1
                            if var p = plans.first(where: { $0.id == planId }) {
                                p.recentCaptions.append(generated.caption)
                                if p.recentCaptions.count > 14 { p.recentCaptions.removeFirst(p.recentCaptions.count - 14) }
                                if !generated.topic.isEmpty {
                                    p.recentTopics.append(generated.topic)
                                    if p.recentTopics.count > 20 { p.recentTopics.removeFirst(p.recentTopics.count - 20) }
                                }
                                if p.topicMode == .userList { p.topicCursor += 1 }
                                upsert(p)
                            }
                        }
                    } catch {
                        log("❌ \(plan.name) [\(kind.shortLabel) \(slot.label)]: \(error.localizedDescription)")
                    }
                }
            }
        }
        if created > 0 { log("✅ \(initial.name): đã tạo \(created) bài mới cho các khung giờ vàng sắp tới.") }
        return created
    }

    // MARK: Đưa bài vào lịch

    private func enqueue(
        plan: AIAutoPlan, kind: SmartPostDestinationType, targets: [AIPlanTarget],
        caption: String, image: UIImage?, fire: Date, spaces: [Space]
    ) async -> Bool {
        let manager = ScheduledPostManager.shared
        let df = DateFormatter()
        df.dateFormat = "dd/MM HH:mm"

        // Fanpage: hẹn giờ gốc trên Facebook để vẫn đăng đúng giờ khi tắt app
        if kind == .fanpage, plan.useNativePageSchedule, !plan.requireApproval {
            var okCount = 0
            var logs: [String] = []
            let jpeg = image?.jpegData(compressionQuality: 0.85)
            for t in targets {
                guard let dest = t.destination else { continue }
                let creds = await TrackedPostManager.resolveCookieAndToken(forId: t.spaceId, fallbackSpace: nil)
                guard !creds.token.isEmpty else {
                    logs.append("❌ [\(dest.name)] chưa có Access Token")
                    continue
                }
                do {
                    let id = try await SmartPostAPIClient.schedulePagePost(
                        pageId: dest.id, caption: caption, imageData: jpeg,
                        userToken: creds.token, pageToken: dest.pageAccessToken, publishAt: fire
                    )
                    okCount += 1
                    logs.append("✅ [\(dest.name)] đã hẹn giờ trên Facebook (ID \(id))")
                } catch {
                    logs.append("❌ [\(dest.name)] \(error.localizedDescription)")
                }
            }
            var record = ScheduledPostTask(
                title: "[Fanpage·FB hẹn giờ] \(String(caption.prefix(36)))",
                caption: caption,
                targetSpaceIds: Array(Set(targets.map { $0.spaceId })),
                privacy: plan.privacy,
                destinationType: .fanpage,
                targetDestinations: targets.compactMap { $0.destination },
                scheduledDate: fire,
                status: okCount == targets.count ? .completed : (okCount > 0 ? .partial : .failed),
                imageFileNames: []
            )
            record.executionLog = "Hẹn giờ đăng lúc \(df.string(from: fire)) bởi Facebook.\n" + logs.joined(separator: "\n")
            record.aiPlanId = plan.id
            manager.tasks.append(record)
            manager.saveTasks()
            return okCount > 0
        }

        // Trang cá nhân / Nhóm (và Page khi cần duyệt): lưu lịch nội bộ, app đăng khi đến giờ
        let spaceIds = Array(Set(targets.map { $0.spaceId }))
        manager.addTask(
            caption: caption,
            spaceIds: spaceIds,
            privacy: plan.privacy,
            destinationType: kind,
            targetDestinations: targets.compactMap { $0.destination },
            scheduledDate: fire,
            images: image.map { [$0] } ?? [],
            videoData: nil
        )
        if let idx = manager.tasks.indices.last {
            manager.tasks[idx].aiPlanId = plan.id
            manager.tasks[idx].expiresAt = plan.lateToleranceMinutes > 0
                ? fire.addingTimeInterval(TimeInterval(plan.lateToleranceMinutes * 60)) : nil
            if plan.requireApproval { manager.tasks[idx].status = .draft }
            manager.saveTasks()
        }
        return true
    }

    /// Duyệt một bản nháp để nó được đăng đúng giờ.
    func approve(taskId: UUID) {
        let manager = ScheduledPostManager.shared
        guard let i = manager.tasks.firstIndex(where: { $0.id == taskId }), manager.tasks[i].status == .draft else { return }
        manager.tasks[i].status = .pending
        manager.saveTasks()
    }
}
