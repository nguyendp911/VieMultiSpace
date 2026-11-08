import SwiftUI
import Foundation
import Security

// MARK: - Facebook Reaction Enum

enum FacebookReactionType: String, CaseIterable, Identifiable, Codable {
    case like = "LIKE"
    case love = "LOVE"
    case care = "CARE"
    case haha = "HAHA"
    case wow = "WOW"
    case sad = "SAD"
    case anger = "ANGER"
    case random = "RANDOM"
    case geminiAuto = "GEMINI_AUTO"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .like: return "👍 Thích (LIKE)"
        case .love: return "❤️ Yêu thích (LOVE)"
        case .care: return "🤗 Thương thương (CARE)"
        case .haha: return "😆 Haha (HAHA)"
        case .wow: return "😮 Wow (WOW)"
        case .sad: return "😢 Buồn (SAD)"
        case .anger: return "😡 Phẫn nộ (ANGER)"
        case .random: return "🎲 Ngẫu nhiên (Random)"
        case .geminiAuto: return "✨ Gemini tự chọn theo bài viết"
        }
    }

    var graphQLId: String {
        switch self {
        case .like: return "1635855486666999"
        case .love: return "1678524932434102"
        case .care: return "613557422527858"
        case .haha: return "115940658764963"
        case .wow: return "478547315650144"
        case .sad: return "908563459236466"
        case .anger: return "444813342392137"
        case .random, .geminiAuto:
            return Self.concreteReactions.randomElement()!.graphQLId
        }
    }

    static let concreteReactions: [FacebookReactionType] = [
        .like, .love, .care, .haha, .wow, .sad, .anger
    ]

    func resolveConcrete() -> FacebookReactionType {
        switch self {
        case .random, .geminiAuto:
            return Self.concreteReactions.randomElement() ?? .like
        default:
            return self
        }
    }
}

// MARK: - Cached Web Tokens (user_id, jazoest, lsd, fb_dtsg)

struct FacebookWebSessionTokens: Codable {
    var userId: String
    var jazoest: String
    var lsdToken: String
    var dtsgToken: String
    var updatedAt: Date
}

enum WebSessionTokenCache {
    private static let cacheKey = "vie.multispace.fb_web_tokens.v1"
    private static let ttlSeconds: TimeInterval = 300 // TTL 5 phút đảm bảo dtsg/lsd luôn hợp lệ

    static func load(for spaceId: UUID) -> FacebookWebSessionTokens? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let map = try? JSONDecoder().decode([String: FacebookWebSessionTokens].self, from: data),
              let cached = map[spaceId.uuidString],
              !cached.userId.isEmpty,
              !cached.jazoest.isEmpty,
              !cached.lsdToken.isEmpty,
              !cached.dtsgToken.isEmpty else {
            return nil
        }
        if Date().timeIntervalSince(cached.updatedAt) > ttlSeconds {
            return nil
        }
        return cached
    }

    static func save(_ tokens: FacebookWebSessionTokens, for spaceId: UUID) {
        var map: [String: FacebookWebSessionTokens] = [:]
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let decoded = try? JSONDecoder().decode([String: FacebookWebSessionTokens].self, from: data) {
            map = decoded
        }
        map[spaceId.uuidString] = tokens
        if let encoded = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(encoded, forKey: cacheKey)
        }
    }

    static func clear(for spaceId: UUID) {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              var map = try? JSONDecoder().decode([String: FacebookWebSessionTokens].self, from: data) else { return }
        map.removeValue(forKey: spaceId.uuidString)
        if let encoded = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(encoded, forKey: cacheKey)
        }
    }
}

// MARK: - Gemini Keychain & AI Comment Generator

enum SecureGeminiStore {
    private static let service = "vn.vie.multispace.gemini"
    private static let account = "gemini_api_key"

    static func saveKey(_ apiKey: String) {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        guard !trimmed.isEmpty else { return }
        var addQuery = query
        addQuery[kSecValueData as String] = Data(trimmed.utf8)
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func readKey() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var raw: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &raw)
        guard status == errSecSuccess, let data = raw as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return ""
        }
        return key
    }
}

struct FeedPostItem: Identifiable, Hashable {
    var id: String { postId }
    let postId: String
    let userName: String
    let userId: String
    var postText: String
}

struct GeminiAnalysisResult {
    let comment: String
    let suggestedReaction: FacebookReactionType
    let usedModel: String
}

enum GeminiCommentService {
    static let availableModels = [
        "auto",
        "gemini-flash-latest",
        "gemini-3-flash-preview",
        "gemini-2.5-flash-lite",
        "gemini-2.5-pro",
        "gemini-2.0-flash"
    ]

    static func modelLabel(_ model: String) -> String {
        if model == "auto" {
            return "✨ Tự động dò Model khả dụng (Khuyên dùng)"
        }
        return model
    }

    private static var cachedWorkingModel: String?

    static func discoverAvailableModels(apiKey: String) async -> [String] {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty,
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(cleanKey)") else {
            return []
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = root["models"] as? [[String: Any]] else {
                return []
            }

            let excludedKeywords = [
                "embedding", "imagen", "veo", "tts", "audio", "aqa",
                "vision", "robotics", "computer-use", "learnlm", "bisheng", "thinking"
            ]

            var candidates: [String] = []
            for m in models {
                guard let rawName = m["name"] as? String else { continue }
                let methods = m["supportedGenerationMethods"] as? [String] ?? []
                guard methods.contains("generateContent") else { continue }

                let shortName = rawName.replacingOccurrences(of: "models/", with: "")
                let lower = shortName.lowercased()
                guard lower.hasPrefix("gemini") else { continue }
                if excludedKeywords.contains(where: { lower.contains($0) }) { continue }
                candidates.append(shortName)
            }

            // Ưu tiên các dòng flash mới nhất (3.x -> 2.5-flash-lite -> flash-latest -> pro)
            candidates.sort { a, b in
                func score(_ s: String) -> Int {
                    let l = s.lowercased()
                    if l.contains("3.1-flash") || l.contains("3-flash") { return 100 }
                    if l == "gemini-flash-latest" || l == "gemini-flash-lite-latest" { return 95 }
                    if l.contains("2.5-flash-lite") { return 90 }
                    if l.contains("2.5-flash") { return 85 }
                    if l.contains("flash") { return 80 }
                    if l.contains("pro") { return 60 }
                    return 40
                }
                return score(a) > score(b)
            }

            return candidates
        } catch {
            return []
        }
    }

    static func analyzeAndGenerateComment(
        post: FeedPostItem,
        apiKey: String,
        model: String,
        customStylePrompt: String
    ) async throws -> GeminiAnalysisResult {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else {
            throw SpaceLoginError.apiError("Chưa nhập Gemini API Key để phân tích bài viết và tạo comment.")
        }

        let contentContext = post.postText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "(Bài viết chia sẻ hình ảnh/khoảnh khắc của \(post.userName), không có văn bản đính kèm)"
            : post.postText

        let styleInstruction = customStylePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Tự nhiên như người thật đang trò chuyện trên Facebook, lịch sự, đúng trọng tâm nội dung bài viết, độ dài 1 đến 2 câu ngắn gọn, không dùng văn mẫu sáo rỗng."
            : customStylePrompt

        let prompt = """
        Bạn là một người dùng mạng xã hội Facebook thực thụ. Hãy phân tích bài viết dưới đây và tạo một bình luận (comment) phù hợp nhất với ngữ cảnh bài viết, đồng thời chọn 1 cảm xúc (reaction) phù hợp.

        Thông tin bài viết:
        - Người đăng: \(post.userName)
        - Nội dung bài viết:
        \"\"\"
        \(contentContext)
        \"\"\"

        Phong cách bình luận yêu cầu: \(styleInstruction)

        YÊU CẦU ĐẦU RA (QUAN TRỌNG):
        - CHỈ trả về một đối tượng JSON DUY NHẤT, bắt đầu bằng { và kết thúc bằng }
        - TUYỆT ĐỐI KHÔNG viết bất kỳ chữ nào trước hoặc sau JSON
        - KHÔNG giải thích, KHÔNG "Here is...", KHÔNG markdown, KHÔNG code block
        - Định dạng bắt buộc: {"reaction":"LIKE|LOVE|CARE|HAHA|WOW|SAD","comment":"nội dung bình luận"}
        - Trường "comment": bám sát bài viết, tự nhiên, 1-2 câu ngắn, không spam, không lặp nguyên văn
        """

        // Xây dựng danh sách model ưu tiên thử lần lượt (tự động vượt lỗi 404 deprecated model)
        var modelsToTry: [String] = []
        if let cached = cachedWorkingModel, !cached.isEmpty {
            modelsToTry.append(cached)
        }
        if !model.isEmpty && model != "auto" && !modelsToTry.contains(model) {
            modelsToTry.append(model)
        }

        let discovered = await discoverAvailableModels(apiKey: cleanKey)
        for d in discovered where !modelsToTry.contains(d) {
            modelsToTry.append(d)
        }

        let fallbackDefaults = [
            "gemini-flash-latest",
            "gemini-3-flash-preview",
            "gemini-2.5-flash-lite",
            "gemini-2.5-pro",
            "gemini-pro-latest"
        ]
        for fb in fallbackDefaults where !modelsToTry.contains(fb) {
            modelsToTry.append(fb)
        }

        var lastErrorMsg = "Không tìm thấy model Gemini khả dụng."
        var index = 0

        while index < modelsToTry.count {
            let candidateModel = modelsToTry[index]
            index += 1

            let attempt = await callGenerateContent(
                model: candidateModel,
                apiKey: cleanKey,
                prompt: prompt
            )

            switch attempt {
            case .success(let result):
                cachedWorkingModel = candidateModel
                return result

            case .suggestedRedirect(let suggestedModel, let errText):
                lastErrorMsg = errText
                if !modelsToTry.contains(suggestedModel) {
                    modelsToTry.insert(suggestedModel, at: index)
                }

            case .notFoundOrUnsupported(let errText):
                lastErrorMsg = errText
                if cachedWorkingModel == candidateModel {
                    cachedWorkingModel = nil
                }
                continue

            case .fatalError(let errText):
                throw SpaceLoginError.apiError(errText)
            }
        }

        throw SpaceLoginError.apiError(lastErrorMsg)
    }

    private enum ModelCallOutcome {
        case success(GeminiAnalysisResult)
        case suggestedRedirect(String, String)
        case notFoundOrUnsupported(String)
        case fatalError(String)
    }

    private static func callGenerateContent(
        model: String,
        apiKey: String,
        prompt: String
    ) async -> ModelCallOutcome {
        let cleanModel = model.replacingOccurrences(of: "models/", with: "")
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(cleanModel):generateContent?key=\(apiKey)") else {
            return .notFoundOrUnsupported("URL model \(cleanModel) không hợp lệ.")
        }

        let requestBody: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.85,
                "maxOutputTokens": 250,
                "responseMimeType": "application/json"
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let bodyData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            return .notFoundOrUnsupported("Lỗi đóng gói JSON.")
        }
        request.httpBody = bodyData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            if statusCode != 200 {
                let errBody = String(data: data, encoding: .utf8) ?? "HTTP \(statusCode)"
                // Nếu thông báo lỗi có gợi ý "use models/xxx" thì tự động trích xuất model được gợi ý
                if let suggested = extractSuggestedModel(from: errBody) {
                    return .suggestedRedirect(suggested, "Model \(cleanModel) đã ngừng hỗ trợ, chuyển sang \(suggested)")
                }
                if statusCode == 404 || statusCode == 400 || statusCode == 503 {
                    return .notFoundOrUnsupported("Model \(cleanModel) lỗi (\(statusCode)): \(errBody.prefix(140))")
                }
                if statusCode == 401 || statusCode == 403 {
                    return .fatalError("Gemini API Key không hợp lệ hoặc bị từ chối (\(statusCode)).")
                }
                return .notFoundOrUnsupported("Gemini API lỗi (\(statusCode)): \(errBody.prefix(140))")
            }

            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = root["candidates"] as? [[String: Any]],
                  let firstCandidate = candidates.first,
                  let content = firstCandidate["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else {
                return .notFoundOrUnsupported("Model \(cleanModel) không trả về nội dung.")
            }

            let combinedText = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            let parsed = parseGeminiOutput(combinedText, usedModel: cleanModel)
            if parsed.comment.isEmpty {
                return .notFoundOrUnsupported("Model \(cleanModel) trả về bình luận rỗng.")
            }
            return .success(parsed)
        } catch {
            return .notFoundOrUnsupported(error.localizedDescription)
        }
    }

    private static func extractSuggestedModel(from text: String) -> String? {
        guard !text.isEmpty,
              let regex = try? NSRegularExpression(pattern: #"use models/([a-zA-Z0-9._-]+)"#, options: [.caseInsensitive]) else {
            return nil
        }
        let nsText = text as NSString
        guard let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: nsText.length)),
              match.numberOfRanges > 1 else {
            return nil
        }
        let r = match.range(at: 1)
        guard r.location != NSNotFound, r.location + r.length <= nsText.length else { return nil }
        return nsText.substring(with: r).trimmingCharacters(in: CharacterSet(charactersIn: ".,\"' "))
    }

    private static func parseGeminiOutput(_ rawText: String, usedModel: String) -> GeminiAnalysisResult {
        // Làm sạch markdown/code block nếu có
        let cleaned = rawText
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        // 1. Ưu tiên Regex trực tiếp - hoạt động kể cả khi Gemini thêm text thừa trước/sau JSON
        let commentRegex = #""comment"\s*:\s*"((?:[^"\\]|\\.)*)""#
        let reactionRegex = #""reaction"\s*:\s*"([A-Za-z_]+)""#

        var extractedComment = ""
        var extractedReaction = FacebookReactionType.like

        if let m = FacebookTargetPostResolver.firstMatch(pattern: commentRegex, in: cleaned) {
            extractedComment = FacebookTargetPostResolver.decodeJSONEscapes(m).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        }
        if let r = FacebookTargetPostResolver.firstMatch(pattern: reactionRegex, in: cleaned)?.uppercased() {
            extractedReaction = FacebookReactionType(rawValue: r) ?? .like
        }

        if !extractedComment.isEmpty {
            return GeminiAnalysisResult(
                comment: extractedComment,
                suggestedReaction: extractedReaction,
                usedModel: usedModel
            )
        }

        // 2. Thử parse JSON block {} đầu tiên tìm được
        if let firstBrace = cleaned.firstIndex(of: "{"),
           let lastBrace = cleaned.lastIndex(of: "}"),
           firstBrace <= lastBrace {
            let jsonCandidate = String(cleaned[firstBrace...lastBrace])
            if let jsonData = jsonCandidate.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                let comment = (obj["comment"] as? String)?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
                let reactionRaw = (obj["reaction"] as? String)?.uppercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? "LIKE"
                let reaction = FacebookReactionType(rawValue: reactionRaw) ?? .like
                if !comment.isEmpty {
                    return GeminiAnalysisResult(comment: comment, suggestedReaction: reaction, usedModel: usedModel)
                }
            }
        }

        // 3. Parse hoàn toàn thất bại - trả rỗng để tránh đăng raw text lên Facebook
        AppLogger.shared.warning("GeminiCommentService", "parseGeminiOutput: không tách được comment", detail: "Raw[0:200]: \(rawText.prefix(200))")
        return GeminiAnalysisResult(
            comment: "",
            suggestedReaction: .like,
            usedModel: usedModel
        )
    }

        static func generateUniqueCommentForTarget(
        target: ResolvedTargetPost,
        spaceName: String,
        spaceIndex: Int,
        totalSpaces: Int,
        previousComments: [String],
        apiKey: String,
        model: String,
        customStylePrompt: String
    ) async throws -> GeminiAnalysisResult {
        var avoidSection = ""
        if !previousComments.isEmpty {
            let bulletList = previousComments.suffix(15).enumerated().map { idx, text in
                "   - Đã dùng #\(idx + 1): \"\(text)\""
            }.joined(separator: "\n")
            avoidSection = """

            DANH SÁCH CÁC BÌNH LUẬN ĐÃ ĐƯỢC CÁC TÀI KHOẢN TRƯỚC SỬ DỤNG (TUYỆT ĐỐI KHÔNG TRÙNG LẶP CÂU CHỮ, Ý TƯỞNG HOẶC CẤU TRÚC CÂU):
            \(bulletList)
            """
        }

        let angles = [
            "tập trung nhận xét trực tiếp vào điểm thú vị nhất của nội dung",
            "bày tỏ sự đồng cảm hoặc chia sẻ góc nhìn cá nhân ngắn gọn",
            "khen ngợi tự nhiên hoặc đặt một câu hỏi tương tác thân thiện",
            "nhận xét ngắn gọn đời thường như bạn bè tương tác",
            "tập trung vào chi tiết cụ thể trong bài đăng với giọng điệu hào hứng",
            "phản hồi ngắn gọn, lịch sự, mang sắc thái riêng biệt"
        ]
        let angleHint = angles[spaceIndex % angles.count]

        let enrichedStyle = """
        \(customStylePrompt)
        Đây là tài khoản thứ \(spaceIndex + 1)/\(totalSpaces) (\(spaceName)) cùng bình luận vào 1 \(target.targetKind).
        Hãy viết với góc nhìn riêng biệt (\(angleHint)), TUYỆT ĐỐI KHÁC BIỆT 100% so với các tài khoản khác.
        \(avoidSection)
        """

        let postItem = FeedPostItem(
            postId: target.postId,
            userName: target.authorName,
            userId: "",
            postText: "[\(target.targetKind)] \(target.postText)"
        )

        return try await analyzeAndGenerateComment(
            post: postItem,
            apiKey: apiKey,
            model: model,
            customStylePrompt: enrichedStyle
        )
    }
}

// MARK: - Target Post / Reel / Group / Fanpage Resolver

struct ResolvedTargetPost {
    var rawInput: String
    var targetKind: String
    var postId: String
    var feedbackId: String
    var authorName: String
    var postText: String
    var canonicalURL: URL?
}

enum FacebookTargetPostResolver {
    static func detectKind(from input: String) -> String {
        let lower = input.lowercased()
        if lower.contains("/reel/") || lower.contains("/reels/") || lower.contains("/share/r/") || lower.contains("fb.watch") || lower.contains("/watch") {
            return "Reel / Video"
        }
        if lower.contains("/groups/") {
            return "Bài viết Nhóm (Group)"
        }
        if lower.contains("/pages/") || lower.contains("fanpage") || lower.contains("/photo") || lower.contains("/videos/") {
            return "Bài viết Fanpage / Media"
        }
        return "Bài viết (Post)"
    }

    static func resolve(
        input: String,
        cookieString: String,
        accessToken: String = "",
        proxy: SpaceProxy? = nil,
        userAgent: String? = nil
    ) async throws -> ResolvedTargetPost {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SpaceLoginError.apiError("Vui lòng nhập Link hoặc ID của Bài viết, Reel, Nhóm hoặc Fanpage.")
        }

        var kind = detectKind(from: trimmed)
        AppLogger.shared.info("TargetResolver", "Bắt đầu phân tích liên kết: \(trimmed)")

        // Trường hợp người dùng nhập thẳng chuỗi ID số
        if trimmed.allSatisfy(\.isNumber) {
            let feedbackId = Data("feedback:\(trimmed)".utf8).base64EncodedString()
            var postText = ""
            if !accessToken.isEmpty {
                postText = await fetchGraphMessage(id: trimmed, accessToken: accessToken) ?? ""
            }
            AppLogger.shared.info("TargetResolver", "Nhận diện ID bài viết số trực tiếp: \(trimmed)")
            return ResolvedTargetPost(
                rawInput: trimmed,
                targetKind: kind,
                postId: trimmed,
                feedbackId: feedbackId,
                authorName: "Chủ bài đăng",
                postText: postText,
                canonicalURL: URL(string: "https://www.facebook.com/\(trimmed)")
            )
        }

        // Nếu là link share rút gọn (/share/p, /share/r, /share/g, pfbid...), ưu tiên giải mã sang URL canonical trước
        var workingInput = trimmed
        let lowerTrimmed = trimmed.lowercased()
        let isShareInput = lowerTrimmed.contains("/share/") || lowerTrimmed.contains("pfbid") || lowerTrimmed.contains("fb.me") || lowerTrimmed.contains("fb.watch")
        if isShareInput {
            if let canon = await resolveShareURLToCanonical(input: trimmed, cookieString: cookieString, proxy: proxy) {
                workingInput = canon.canonicalURL
                kind = canon.kind
            }
        }

        // Bóc tách sơ bộ ID số nếu có sẵn trên URL
        var extractedId = extractNumericIdFromURL(workingInput)

        var urlStr = workingInput
        if !urlStr.lowercased().hasPrefix("http://") && !urlStr.lowercased().hasPrefix("https://") {
            urlStr = "https://" + urlStr
        }

        guard let targetURL = URL(string: urlStr) else {
            if let id = extractedId {
                return ResolvedTargetPost(
                    rawInput: trimmed,
                    targetKind: kind,
                    postId: id,
                    feedbackId: Data("feedback:\(id)".utf8).base64EncodedString(),
                    authorName: "Chủ bài đăng",
                    postText: "",
                    canonicalURL: nil
                )
            }
            throw SpaceLoginError.apiError("Định dạng Link hoặc ID bài viết không hợp lệ.")
        }

        // Tải trang mục tiêu kèm Cookie để giải mã link rút gọn (share/p, share/r, pfbid...) và lấy feedback_id + nội dung bài viết
        var request = URLRequest(url: targetURL)
        request.httpMethod = "GET"
        let effectiveUA = (userAgent?.isEmpty == false)
            ? userAgent!
            : "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
        request.setValue(effectiveUA, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("vi,en-US;q=0.8,en;q=0.6", forHTTPHeaderField: "accept-language")
        if !cookieString.isEmpty {
            request.setValue(cookieString, forHTTPHeaderField: "Cookie")
        }

        let session: URLSession
        if let proxy, proxy.isEnabled {
            let cfg = URLSessionConfiguration.default
            cfg.proxyConfigurations = [proxy.toNetworkProxyConfiguration()]
            session = URLSession(configuration: cfg)
        } else {
            session = URLSession.shared
        }

        var finalURL: URL? = targetURL
        var html = ""
        do {
            let (data, response) = try await session.data(for: request)
            if let httpResp = response as? HTTPURLResponse, let redirected = httpResp.url {
                finalURL = redirected
                let redirectedStr = redirected.absoluteString
                kind = detectKind(from: redirectedStr)
                if extractedId == nil {
                    let decodedRedirect = redirectedStr.removingPercentEncoding ?? redirectedStr
                    extractedId = extractNumericIdFromURL(decodedRedirect)
                }
            }
            html = String(data: data, encoding: .utf8) ?? ""
        } catch {
            // Nếu lỗi mạng khi tải HTML nhưng đã có ID số trên URL thì vẫn dùng ID đó
        }

        // Bóc tách og:url và link canonical nếu có (đặc biệt hữu hiệu cho link share/p/..., share/r/...)
        let ogPatterns = [
            #"<meta\s+[^>]*property=[\"']og:url[\"'][^>]*content=[\"']([^\"']+)[\"']"#,
            #"<meta\s+[^>]*content=[\"']([^\"']+)[\"'][^>]*property=[\"']og:url[\"']"#,
            #"<link\s+[^>]*rel=[\"']canonical[\"'][^>]*href=[\"']([^\"']+)[\"']"#,
            #"<link\s+[^>]*href=[\"']([^\"']+)[\"'][^>]*rel=[\"']canonical[\"']"#
        ]
        for pat in ogPatterns {
            if let ogUrl = firstMatch(pattern: pat, in: html) {
                if let ogId = extractNumericIdFromURL(ogUrl) {
                    extractedId = ogId
                    if let u = URL(string: ogUrl) {
                        finalURL = u
                    }
                    break
                }
            }
        }

        // Bóc tách graphqlid nếu có
        if extractedId == nil,
           let alGraphId = firstMatch(pattern: #"graphqlid=([A-Za-z0-9+/=]+)"#, in: html) {
            if let decData = Data(base64Encoded: alGraphId),
               let decStr = String(data: decData, encoding: .utf8) {
                let nums = decStr.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { $0.count >= 8 }
                if let lastNum = nums.last {
                    extractedId = lastNum
                }
            }
        }

        if extractedId == nil, !html.isEmpty {
            let idPatterns = [
                #"/groups/[^/?#]+/posts/(\d{5,25})"#,
                #"/groups/[^/?#]+/permalink/(\d{5,25})"#,
                #""post_id":"(\d+)""#,
                #""top_level_post_id":"(\d+)""#,
                #""story_fbid":"(\d+)""#,
                #""video_id":"(\d+)""#,
                #"story_fbid=(\d+)"#,
                #"fbid=(\d+)"#,
                #"/posts/(\d+)"#,
                #"/reel/(\d+)"#,
                #"/videos/(\d+)"#
            ]
            for pat in idPatterns {
                if let m = firstMatch(pattern: pat, in: html) {
                    extractedId = m
                    break
                }
            }
        }

        var explicitFeedbackId = ""
        if !html.isEmpty {
            let fbPatterns = [
                #""feedback":\{"id":"([A-Za-z0-9+/=]+)""#,
                #""feedback_id":"([A-Za-z0-9+/=]+)""#
            ]
            for pat in fbPatterns {
                if let fb = firstMatch(pattern: pat, in: html), !fb.isEmpty {
                    explicitFeedbackId = fb
                    if extractedId == nil,
                       let decodedData = Data(base64Encoded: fb),
                       let decodedStr = String(data: decodedData, encoding: .utf8),
                       let idPart = firstMatch(pattern: #"(\d+)"#, in: decodedStr) {
                        extractedId = idPart
                    }
                    break
                }
            }
        }

        guard let finalPostId = extractedId, !finalPostId.isEmpty else {
            let errMsg = "Không tìm thấy Post ID / Feedback ID từ liên kết này. Hãy dán link trực tiếp của bài viết/Reel hoặc kiểm tra lại Cookie."
            AppLogger.shared.error("TargetResolver", "Giải mã thất bại cho: \(trimmed)", detail: errMsg)
            throw SpaceLoginError.apiError(errMsg)
        }

        let resolvedFeedbackId = !explicitFeedbackId.isEmpty
            ? explicitFeedbackId
            : Data("feedback:\(finalPostId)".utf8).base64EncodedString()

        var authorName = "Chủ bài đăng"
        if let actorName = firstMatch(pattern: #""actors":\[\{"__typename":"[^"]+","name":"([^"]+)""#, in: html)
            ?? firstMatch(pattern: #"<meta property="og:title" content="([^"]+)""#, in: html) {
            authorName = decodeJSONEscapes(actorName)
        }

        var postText = ""
        if let msgText = firstMatch(pattern: #""message":\{"text":"([^"]+)""#, in: html) {
            postText = decodeJSONEscapes(msgText)
        } else if let ogDesc = firstMatch(pattern: #"<meta property="og:description" content="([^"]+)""#, in: html)
                    ?? firstMatch(pattern: #"<meta name="description" content="([^"]+)""#, in: html) {
            postText = decodeHTMLEntities(ogDesc)
        }

        if postText.isEmpty, !accessToken.isEmpty {
            postText = await fetchGraphMessage(id: finalPostId, accessToken: accessToken, session: session) ?? ""
        }

        AppLogger.shared.info("TargetResolver", "✅ Giải mã thành công: [\(kind)] ID: \(finalPostId) (Tác giả: \(authorName))", detail: postText.isEmpty ? "Không có trích đoạn văn bản" : "Trích: \(postText.prefix(60))...")

        let canonicalOut: URL? = {
            let canonStr = buildCanonicalURL(id: finalPostId, kind: kind, originalURL: finalURL?.absoluteString ?? trimmed)
            return URL(string: canonStr) ?? finalURL
        }()

        return ResolvedTargetPost(
            rawInput: trimmed,
            targetKind: kind,
            postId: finalPostId,
            feedbackId: resolvedFeedbackId,
            authorName: authorName,
            postText: postText,
            canonicalURL: canonicalOut
        )
    }

    static func extractNumericIdFromURL(_ urlStr: String) -> String? {
        let decoded = urlStr.removingPercentEncoding ?? urlStr
        let patterns = [
            #"/groups/[^/?#]+/posts/(\d{5,25})"#,
            #"/groups/[^/?#]+/permalink/(\d{5,25})"#,
            #"/groups/[^/?#]+/multi_permalinks=(\d{5,25})"#,
            #"multi_permalinks=(\d{5,25})"#,
            #"story_fbid=(\d{5,25})"#,
            #"[?&]fbid=(\d{5,25})"#,
            #"/posts/(\d{5,25})"#,
            #"/permalink/(\d{5,25})"#,
            #"/activity/(\d{5,25})"#,
            #"/reel/(\d{5,25})"#,
            #"/reels/(\d{5,25})"#,
            #"/videos/(\d{5,25})"#,
            #"watch/\?v=(\d{5,25})"#,
            #"[?&]v=(\d{5,25})"#,
            #"pfbid0([A-Za-z0-9]+)"#,
            #"/share/g/(\d{5,25})"#,
            #"/groups/(\d{5,25})"#
        ]
        for pat in patterns {
            if let found = firstMatch(pattern: pat, in: decoded) {
                return found
            }
        }
        return nil
    }

    private static func fetchGraphMessage(id: String, accessToken: String, session: URLSession = .shared) async -> String? {
        var comps = URLComponents(string: "https://graph.facebook.com/v18.0/\(id)")
        comps?.queryItems = [
            URLQueryItem(name: "fields", value: "message,description,story"),
            URLQueryItem(name: "access_token", value: accessToken)
        ]
        guard let url = comps?.url else { return nil }
        do {
            let (data, _) = try await session.data(from: url)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let m = json["message"] as? String, !m.isEmpty { return m }
                if let d = json["description"] as? String, !d.isEmpty { return d }
                if let s = json["story"] as? String, !s.isEmpty { return s }
            }
        } catch {}
        return nil
    }

    /// Giải mã link chia sẻ rút gọn Facebook thành URL chính xác (theo redirect, lấy canonical ID).
    /// Trả về (canonicalURL, postId, kind) hoặc nil nếu thất bại.
    static func resolveShareURLToCanonical(
        input: String,
        cookieString: String = "",
        proxy: SpaceProxy? = nil
    ) async -> (canonicalURL: String, postId: String, kind: String)? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.allSatisfy(\.isNumber) {
            return ("https://www.facebook.com/posts/\(trimmed)", trimmed, "Bài viết (Post)")
        }

        var urlStr = trimmed
        if !urlStr.lowercased().hasPrefix("http://") && !urlStr.lowercased().hasPrefix("https://") {
            urlStr = "https://" + urlStr
        }
        guard let url = URL(string: urlStr) else { return nil }

        // Nếu URL đã có ID bài viết rõ ràng trên path (ví dụ /posts/123, /permalink/123), không phải link rút gọn share/...
        let lower = urlStr.lowercased()
        let isShareLink = lower.contains("/share/") || lower.contains("pfbid") || lower.contains("fb.me") || lower.contains("fb.watch")
        if !isShareLink, let directId = extractNumericIdFromURL(urlStr) {
            let kind = detectKind(from: urlStr)
            let canonical = buildCanonicalURL(id: directId, kind: kind, originalURL: urlStr)
            return (canonical, directId, kind)
        }

        // Tạo danh sách URLs để thử: ưu tiên URL gốc, sau đó thử mbasic nếu là link share
        var candidateURLs = [url]
        if isShareLink {
            let mbasicStr = urlStr
                .replacingOccurrences(of: "https://www.facebook.com", with: "https://mbasic.facebook.com")
                .replacingOccurrences(of: "https://web.facebook.com", with: "https://mbasic.facebook.com")
                .replacingOccurrences(of: "https://m.facebook.com", with: "https://mbasic.facebook.com")
            if let mbURL = URL(string: mbasicStr), mbURL != url {
                candidateURLs.append(mbURL)
            }
        }

        // Follow redirects để lấy final URL (kèm Cookie nếu có để giải mã share/p, share/r, pfbid...)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        if !cookieString.isEmpty {
            let cookieStorage = HTTPCookieStorage()
            for c in FacebookGraphQLAutoClient.parseCookies(from: cookieString) {
                cookieStorage.setCookie(c)
            }
            config.httpCookieStorage = cookieStorage
            config.httpCookieAcceptPolicy = .always
            config.httpShouldSetCookies = true
        }
        if let proxy, proxy.isEnabled {
            config.proxyConfigurations = [proxy.toNetworkProxyConfiguration()]
        }
        let session = URLSession(configuration: config)

        let uas = [
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1",
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36"
        ]

        for candURL in candidateURLs {
            for ua in uas {
                var request = URLRequest(url: candURL)
                request.httpMethod = "GET"
                request.setValue(ua, forHTTPHeaderField: "User-Agent")
                request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
                request.setValue("vi,en-US;q=0.8,en;q=0.6", forHTTPHeaderField: "Accept-Language")
                if !cookieString.isEmpty {
                    request.setValue(cookieString, forHTTPHeaderField: "Cookie")
                }

                do {
                    let (data, response) = try await session.data(for: request)
                    if let httpResp = response as? HTTPURLResponse, httpResp.statusCode >= 400 {
                        continue
                    }
                    var finalURLStr = candURL.absoluteString
                    if let httpResp = response as? HTTPURLResponse, let respURL = httpResp.url {
                        finalURLStr = respURL.absoluteString
                    }

                    // 1. Thử lấy ID từ final URL sau redirect (bao gồm cả mbasic redirect có next=...)
                    let decodedFinalURL = finalURLStr.removingPercentEncoding ?? finalURLStr
                    var extractedId = extractNumericIdFromURL(decodedFinalURL)
                    var resolvedFinalURL = finalURLStr

                    let html = String(data: data, encoding: .utf8) ?? ""

                    // 2. Thử bóc tách meta og:url hoặc link canonical
                    let ogPatterns = [
                        #"<meta\s+[^>]*property=[\"']og:url[\"'][^>]*content=[\"']([^\"']+)[\"']"#,
                        #"<meta\s+[^>]*content=[\"']([^\"']+)[\"'][^>]*property=[\"']og:url[\"']"#,
                        #"<link\s+[^>]*rel=[\"']canonical[\"'][^>]*href=[\"']([^\"']+)[\"']"#,
                        #"<link\s+[^>]*href=[\"']([^\"']+)[\"'][^>]*rel=[\"']canonical[\"']"#
                    ]
                    for pat in ogPatterns {
                        if let ogUrl = firstMatch(pattern: pat, in: html) {
                            if let ogId = extractNumericIdFromURL(ogUrl) {
                                extractedId = ogId
                                resolvedFinalURL = ogUrl
                                break
                            }
                        }
                    }

                    // 3. Thử bóc tách al:ios:url graphqlid
                    if extractedId == nil,
                       let alGraphId = firstMatch(pattern: #"graphqlid=([A-Za-z0-9+/=]+)"#, in: html) {
                        if let decData = Data(base64Encoded: alGraphId),
                           let decStr = String(data: decData, encoding: .utf8) {
                            let nums = decStr.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { $0.count >= 8 }
                            if let lastNum = nums.last {
                                extractedId = lastNum
                            }
                        }
                    }

                    // 4. Nếu chưa có ID, tìm các idPatterns trong HTML
                    if extractedId == nil, !html.isEmpty {
                        let idPatterns = [
                            #"/groups/[^/?#]+/posts/(\d{5,25})"#,
                            #"/groups/[^/?#]+/permalink/(\d{5,25})"#,
                            #""post_id"\s*:\s*"?(\d{8,25})"?"#,
                            #""top_level_post_id"\s*:\s*"?(\d{8,25})"?"#,
                            #""story_fbid"\s*:\s*"?(\d{8,25})"?"#,
                            #""video_id"\s*:\s*"?(\d{8,25})"?"#,
                            #"story_fbid=(\d{8,25})"#,
                            #"fbid=(\d{8,25})"#,
                            #"/reel/(\d{8,25})"#,
                            #"/posts/(\d{8,25})"#,
                            #"/videos/(\d{8,25})"#,
                            #"content="fb://post/(\d{8,25})""#,
                            #"content="fb://photo/(\d{8,25})""#
                        ]
                        for pat in idPatterns {
                            if let m = firstMatch(pattern: pat, in: html) {
                                extractedId = m
                                break
                            }
                        }

                        if extractedId == nil {
                            let fbPatterns = [
                                #""feedback":\{"id":"([A-Za-z0-9+/=]+)""#,
                                #""feedback_id":"([A-Za-z0-9+/=]+)""#
                            ]
                            for pat in fbPatterns {
                                if let fb = firstMatch(pattern: pat, in: html),
                                   let decodedData = Data(base64Encoded: fb),
                                   let decodedStr = String(data: decodedData, encoding: .utf8),
                                   let idPart = firstMatch(pattern: #"(\d{8,25})"#, in: decodedStr) {
                                    extractedId = idPart
                                    break
                                }
                            }
                        }
                    }

                    if let postId = extractedId, !postId.isEmpty {
                        let kind = detectKind(from: resolvedFinalURL)
                        let canonical = buildCanonicalURL(id: postId, kind: kind, originalURL: resolvedFinalURL)
                        return (canonical, postId, kind)
                    }
                } catch {
                    continue
                }
            }
        }
        return nil
    }

    static func buildCanonicalURL(id: String, kind: String, originalURL: String) -> String {
        let decoded = originalURL.removingPercentEncoding ?? originalURL
        let lower = decoded.lowercased()
        if lower.contains("/reel/") || lower.contains("/reels/") || lower.contains("/share/r/") || lower.contains("fb.watch") || lower.contains("/watch") {
            return "https://www.facebook.com/reel/\(id)"
        }
        if lower.contains("/groups/") {
            if let groupId = FacebookTargetPostResolver.firstMatch(pattern: #"/groups/([^/?#]+)"#, in: decoded) {
                return "https://www.facebook.com/groups/\(groupId)/posts/\(id)"
            }
        }
        if lower.contains("/videos/") {
            return "https://www.facebook.com/videos/\(id)"
        }
        return "https://www.facebook.com/posts/\(id)"
    }

    static func firstMatch(pattern: String, in text: String) -> String? {
        guard !text.isEmpty,
              let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let nsText = text as NSString
        guard let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: nsText.length)),
              match.numberOfRanges > 1 else {
            return nil
        }
        let r = match.range(at: 1)
        guard r.location != NSNotFound, r.location + r.length <= nsText.length else { return nil }
        return nsText.substring(with: r)
    }

    static func decodeJSONEscapes(_ raw: String) -> String {
        let wrapped = "\"\(raw)\""
        if let data = wrapped.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(String.self, from: data) {
            return decoded
        }
        return decodeHTMLEntities(raw)
    }

    private static func decodeHTMLEntities(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&quot;", with: "\"")
           .replacingOccurrences(of: "&#039;", with: "'")
           .replacingOccurrences(of: "&apos;", with: "'")
           .replacingOccurrences(of: "&amp;", with: "&")
           .replacingOccurrences(of: "&lt;", with: "<")
           .replacingOccurrences(of: "&gt;", with: ">")
    }
}

// MARK: - Cookie-Preserving Redirect Delegate

final class CookiePreservingRedirectDelegate: NSObject, URLSessionTaskDelegate {
    let cookieString: String
    init(cookieString: String) {
        self.cookieString = cookieString
    }
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var req = request
        if !cookieString.isEmpty {
            req.setValue(cookieString, forHTTPHeaderField: "Cookie")
        }
        completionHandler(req)
    }
}

// MARK: - Facebook GraphQL Auto Reaction & Comment Client (Ported from 1758035539-Test.py)

final class FacebookGraphQLAutoClient {
    let spaceId: UUID
    let cookieString: String
    let accessToken: String
    let proxy: SpaceProxy?
    let userAgent: String?
    private(set) var tokens: FacebookWebSessionTokens?

    private let baseHeaders: [String: String]
    // Dùng 1 session duy nhất cho toàn bộ vòng đời client — tránh tạo mới mỗi request
    private let session: URLSession

    init(
        spaceId: UUID,
        cookieString: String,
        accessToken: String = "",
        proxy: SpaceProxy? = nil,
        userAgent: String? = nil
    ) {
        self.spaceId = spaceId
        self.cookieString = cookieString
        self.accessToken = accessToken
        self.proxy = proxy
        self.userAgent = userAgent

        // Giả lập Desktop Chrome khớp 100% với 1758035539-Test.py
        let desktopUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36"
        self.baseHeaders = [
            "User-Agent": desktopUA,
            "sec-ch-ua": "\"Not)A;Brand\";v=\"8\", \"Chromium\";v=\"138\", \"Google Chrome\";v=\"138\"",
            "sec-ch-ua-mobile": "?0",
            "sec-ch-ua-platform": "\"Windows\"",
            "sec-ch-ua-platform-version": "\"19.0.0\"",
            "sec-ch-ua-model": "\"\"",
            "sec-ch-ua-full-version-list": "\"Not)A;Brand\";v=\"8.0.0.0\", \"Chromium\";v=\"138.0.7204.97\", \"Google Chrome\";v=\"138.0.7204.97\"",
            "sec-ch-prefers-color-scheme": "dark",
            "accept-language": "vi,fr-FR;q=0.9,fr;q=0.8,en-US;q=0.7,en;q=0.6",
            "Cookie": cookieString
        ]

        // Khởi tạo cookie storage riêng biệt và nạp cookie để URLSession tự động đính kèm không bị CFNetwork lọc
        let cookieStorage = HTTPCookieStorage()
        let parsedCookies = Self.parseCookies(from: cookieString)
        for c in parsedCookies {
            cookieStorage.setCookie(c)
        }

        let config = URLSessionConfiguration.default
        config.httpCookieStorage = cookieStorage
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        if let proxy, proxy.isEnabled {
            config.proxyConfigurations = [proxy.toNetworkProxyConfiguration()]
        }
        self.session = URLSession(
            configuration: config,
            delegate: CookiePreservingRedirectDelegate(cookieString: cookieString),
            delegateQueue: nil
        )
    }

    func prepareTokens(forceRefresh: Bool = false) async throws -> FacebookWebSessionTokens {
        if !forceRefresh, let cached = WebSessionTokenCache.load(for: spaceId) {
            if let cUser = Self.firstMatch(pattern: #"c_user=(\d+)"#, in: cookieString),
               cUser == cached.userId {
                self.tokens = cached
                return cached
            }
        }
        let fresh = try await fetchFreshTokens()
        WebSessionTokenCache.save(fresh, for: spaceId)
        self.tokens = fresh
        return fresh
    }

    private func fetchFreshTokens() async throws -> FacebookWebSessionTokens {
        guard let userId = Self.firstMatch(pattern: #"c_user=(\d+)"#, in: cookieString) else {
            throw SpaceLoginError.apiError("Không tìm thấy c_user trong Cookie của không gian này.")
        }

        let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
        let desktopUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36"

        // Quét mbasic và m.facebook bằng Mobile User-Agent để tránh 400 Bad Request và 301 Redirect
        let checkEndpoints: [(url: String, ua: String)] = [
            ("https://mbasic.facebook.com/", mobileUA),
            ("https://m.facebook.com/", mobileUA),
            ("https://mbasic.facebook.com/me", mobileUA),
            ("https://m.facebook.com/me", mobileUA),
            ("https://www.facebook.com/", desktopUA)
        ]

        var resolvedDtsg: String? = nil
        var resolvedLsd: String? = nil
        var resolvedJazoest = "25400"

        for item in checkEndpoints {
            guard let url = URL(string: item.url) else { continue }
            var request = URLRequest(url: url, timeoutInterval: 12)
            request.httpMethod = "GET"
            for (k, v) in baseHeaders {
                request.setValue(v, forHTTPHeaderField: k)
            }
            request.setValue(item.ua, forHTTPHeaderField: "User-Agent")
            request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.setValue("1", forHTTPHeaderField: "upgrade-insecure-requests")
            request.setValue("navigate", forHTTPHeaderField: "sec-fetch-mode")
            request.setValue("document", forHTTPHeaderField: "sec-fetch-dest")
            request.setValue(cookieString, forHTTPHeaderField: "Cookie")

            guard let (data, _) = try? await session.data(for: request) else { continue }
            let html = String(data: data, encoding: .utf8) ?? ""
            guard !html.isEmpty else { continue }

            if resolvedDtsg == nil {
                resolvedDtsg = FacebookAPILoginClient.extractDtsg(from: html)
                    ?? Self.firstMatch(pattern: #""dtsg":\{"token":"([^"]+)""#, in: html)
                    ?? Self.firstMatch(pattern: #""DTSGInitialData",\[\],\{"token":"([^"]+)""#, in: html)
                    ?? Self.firstMatch(pattern: #""DTSGInitData",\[\],\{"token":"([^"]+)""#, in: html)
                    ?? Self.firstMatch(pattern: #"name="fb_dtsg"\s+value="([^"]+)""#, in: html)
                    ?? Self.firstMatch(pattern: #"value="([^"]+)"\s+name="fb_dtsg""#, in: html)
                    ?? Self.firstMatch(pattern: #"name='fb_dtsg'\s+value='([^']+)'"#, in: html)
                    ?? Self.firstMatch(pattern: #"\"token\":\"(NA[A-Za-z0-9_\-:]+|AQ[A-Za-z0-9_\-:]+)\""#, in: html)
            }

            if resolvedLsd == nil {
                resolvedLsd = Self.firstMatch(pattern: #""token":"([^"]+)"},323\]"#, in: html)
                    ?? Self.firstMatch(pattern: #""LSD",\[\],\{"token":"([^"]+)""#, in: html)
                    ?? Self.firstMatch(pattern: #"name="lsd"\s+value="([^"]+)""#, in: html)
                    ?? Self.firstMatch(pattern: #"value="([^"]+)"\s+name="lsd""#, in: html)
            }

            if let j = Self.firstMatch(pattern: #"jazoest=(\d+)"#, in: html) {
                resolvedJazoest = j
            }

            if resolvedDtsg != nil { break }
        }

        guard let dtsgToken = resolvedDtsg, !dtsgToken.isEmpty else {
            let err = "Không lấy được fb_dtsg từ Cookie (Cookie có thể đã hết hạn hoặc bị checkpoint)."
            AppLogger.shared.error("FacebookWeb", "Lỗi lấy session tokens cho c_user=\(userId)", detail: err)
            throw SpaceLoginError.apiError(err)
        }

        let lsdToken = resolvedLsd ?? ""
        AppLogger.shared.info("FacebookWeb", "Lấy thành công fb_dtsg & lsd cho c_user=\(userId)")

        return FacebookWebSessionTokens(
            userId: userId,
            jazoest: resolvedJazoest,
            lsdToken: lsdToken,
            dtsgToken: dtsgToken,
            updatedAt: Date()
        )
    }

    func getNewsFeedPosts() async throws -> [FeedPostItem] {
        // Luôn chuẩn bị token (TTL 5 phút đảm bảo fb_dtsg và lsd còn sống)
        let tok = try await prepareTokens()
        AppLogger.shared.info("NewsFeed", "Bắt đầu lấy News Feed — userId: \(tok.userId), dtsg: \(String(tok.dtsgToken.prefix(8)))...")

        // ── Ưu tiên 1: Graph API (nếu có access token, ổn định nhất) ──────
        if !accessToken.isEmpty {
            let graphPosts = await fetchFeedViaGraphAPI(userId: tok.userId)
            if !graphPosts.isEmpty {
                AppLogger.shared.info("NewsFeed", "✅ Graph API — \(graphPosts.count) bài viết")
                return graphPosts
            }
            AppLogger.shared.warning("NewsFeed", "Graph API trả 0 bài, thử phương án GraphQL web...")
        }

        // ── Ưu tiên 2: GraphQL Web theo đúng doc_id của 1758035539-Test.py ──
        let docIds = [
            "24488967877354300",  // chuẩn 1758035539-Test.py
            "9117175968304833",
            "8858919374123928",
            "7851302958266762"
        ]

        for docId in docIds {
            AppLogger.shared.debug("NewsFeed", "Thử GraphQL doc_id: \(docId)")
            do {
                let posts = try await fetchFeedViaGraphQL(tok: tok, docId: docId)
                if !posts.isEmpty {
                    AppLogger.shared.info("NewsFeed", "✅ GraphQL (\(docId)) — \(posts.count) bài viết")
                    return posts
                }
            } catch {
                AppLogger.shared.warning("NewsFeed", "GraphQL doc_id \(docId) exception: \(error.localizedDescription)")
            }
        }

        // Tất cả doc_id thất bại → Bắt buộc làm mới token và thử lại 1 lần
        AppLogger.shared.warning("NewsFeed", "⚠️ Tất cả doc_id thất bại, làm mới fb_dtsg/lsd và retry...")
        let freshTok = try await prepareTokens(forceRefresh: true)
        AppLogger.shared.info("NewsFeed", "Token mới: dtsg=\(String(freshTok.dtsgToken.prefix(8)))..., lsd=\(String(freshTok.lsdToken.prefix(8)))...")

        for docId in docIds {
            AppLogger.shared.debug("NewsFeed", "Retry GraphQL doc_id: \(docId)")
            do {
                let posts = try await fetchFeedViaGraphQL(tok: freshTok, docId: docId)
                if !posts.isEmpty {
                    AppLogger.shared.info("NewsFeed", "✅ GraphQL retry (\(docId)) — \(posts.count) bài viết")
                    return posts
                }
            } catch {
                AppLogger.shared.warning("NewsFeed", "Retry doc_id \(docId) exception: \(error.localizedDescription)")
            }
        }

        // ── Ưu tiên 3: Lấy trực tiếp từ trang chủ Facebook qua HTML scraping ──
        AppLogger.shared.warning("NewsFeed", "GraphQL thất bại hoàn toàn, thử scrape HTML homepage...")
        let htmlPosts = try await fetchFeedViaHomepageScrape(tok: freshTok)
        AppLogger.shared.info("NewsFeed", htmlPosts.isEmpty ? "⚠️ Scrape cũng không tìm thấy bài viết" : "✅ Scrape — \(htmlPosts.count) bài viết")
        return htmlPosts
    }

    // MARK: - Phương án 1: Facebook Graph API /me/feed
    private func fetchFeedViaGraphAPI(userId: String) async -> [FeedPostItem] {
        guard !accessToken.isEmpty else { return [] }
        var comps = URLComponents(string: "https://graph.facebook.com/v18.0/me/feed")
        comps?.queryItems = [
            URLQueryItem(name: "fields", value: "id,message,story,from,created_time"),
            URLQueryItem(name: "limit", value: "20"),
            URLQueryItem(name: "access_token", value: accessToken)
        ]
        guard let url = comps?.url else { return [] }
        do {
            let (data, _) = try await session.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataArr = json["data"] as? [[String: Any]] else {
                if let errJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let err = errJson["error"] as? [String: Any] {
                    AppLogger.shared.warning("NewsFeed", "Graph API lỗi: \((err["message"] as? String) ?? "?")")
                }
                return []
            }
            return dataArr.compactMap { item -> FeedPostItem? in
                // id trả về dạng "userId_postId"
                let rawId = item["id"] as? String ?? ""
                let postId = rawId.contains("_") ? String(rawId.split(separator: "_").last ?? Substring(rawId)) : rawId
                guard !postId.isEmpty else { return nil }
                let msg = (item["message"] as? String)
                    ?? (item["story"] as? String)
                    ?? ""
                let fromName = (item["from"] as? [String: Any])?["name"] as? String ?? "Người dùng Facebook"
                let fromId   = (item["from"] as? [String: Any])?["id"]   as? String ?? ""
                return FeedPostItem(postId: postId, userName: fromName, userId: fromId, postText: msg)
            }
        } catch {
            AppLogger.shared.warning("NewsFeed", "Graph API exception: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Phương án 2: GraphQL Web (NDJSON)
    private func fetchFeedViaGraphQL(tok: FacebookWebSessionTokens, docId: String) async throws -> [FeedPostItem] {
        let variables: [String: Any] = [
            "RELAY_INCREMENTAL_DELIVERY": true,
            "clientQueryId": "7cfd71a6-89d4-49a9-b5b3-7a3ec2b2b4c6",
            "clientSession": NSNull(),
            "connectionClass": "GOOD",
            "count": 10,
            "cursor": "",
            "experimentalValues": NSNull(),
            "feedLocation": "NEWSFEED",
            "feedStyle": "DEFAULT",
            "feedbackSource": 1,
            "focusCommentID": NSNull(),
            "orderby": ["TOP_STORIES"],
            "privacySelectorRenderLocation": "COMET_STREAM",
            "refreshMode": "COLD_START",
            "renderLocation": "homepage_stream",
            "scale": 1,
            "shouldChangeBRSLabelFieldName": false,
            "shouldChangeSponsoredAuctionDistanceFieldName": false,
            "shouldChangeSponsoredDataFieldName": false,
            "shouldObfuscateCategoryField": false,
            "useDefaultActor": false,
            "__relay_internal__pv__GHLShouldChangeSponsoredAuctionDistanceFieldNamerelayprovider": false,
            "__relay_internal__pv__GHLShouldChangeSponsoredDataFieldNamerelayprovider": false,
            "__relay_internal__pv__GHLShouldChangeAdIdFieldNamerelayprovider": false,
            "__relay_internal__pv__IsWorkUserrelayprovider": false,
            "__relay_internal__pv__FBReels_deprecate_short_form_video_context_gkrelayprovider": true,
            "__relay_internal__pv__FeedDeepDiveTopicPillThreadViewEnabledrelayprovider": false,
            "__relay_internal__pv__CometImmersivePhotoCanUserDisable3DMotionrelayprovider": false,
            "__relay_internal__pv__WorkCometIsEmployeeGKProviderrelayprovider": false,
            "__relay_internal__pv__IsMergQAPollsrelayprovider": false,
            "__relay_internal__pv__FBReelsMediaFooter_comet_enable_reels_ads_gkrelayprovider": true,
            "__relay_internal__pv__CometUFIReactionsEnableShortNamerelayprovider": false,
            "__relay_internal__pv__CometUFIShareActionMigrationrelayprovider": true,
            "__relay_internal__pv__CometUFI_dedicated_comment_routable_dialog_gkrelayprovider": false,
            "__relay_internal__pv__StoriesArmadilloReplyEnabledrelayprovider": true,
            "__relay_internal__pv__FBReelsIFUTileContent_reelsIFUPlayOnHoverrelayprovider": true
        ]

        let payload: [String: String] = [
            "av": tok.userId,
            "__aaid": "0",
            "__user": tok.userId,
            "__a": "1",
            "__req": "98",
            "dpr": "1",
            "__ccg": "GOOD",
            "__rev": "1024608489",
            "__comet_req": "15",
            "fb_dtsg": tok.dtsgToken,
            "jazoest": tok.jazoest,
            "lsd": tok.lsdToken,
            "__spin_r": "1024608489",
            "__spin_b": "trunk",
            "__crn": "comet.fbweb.CometHomeRoute",
            "fb_api_caller_class": "RelayModern",
            "fb_api_req_friendly_name": "CometNewsFeedPaginationQuery",
            "variables": Self.jsonString(from: variables),
            "server_timestamps": "true",
            "doc_id": docId
        ]

        var request = URLRequest(url: URL(string: "https://www.facebook.com/api/graphql/")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        for (k, v) in baseHeaders { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue("CometNewsFeedPaginationQuery", forHTTPHeaderField: "x-fb-friendly-name")
        request.setValue("359341", forHTTPHeaderField: "x-asbd-id")
        request.setValue(tok.lsdToken, forHTTPHeaderField: "x-fb-lsd")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        request.setValue("https://www.facebook.com", forHTTPHeaderField: "origin")
        request.setValue("same-origin", forHTTPHeaderField: "sec-fetch-site")
        request.setValue("cors", forHTTPHeaderField: "sec-fetch-mode")
        request.setValue("empty", forHTTPHeaderField: "sec-fetch-dest")
        request.setValue("https://www.facebook.com", forHTTPHeaderField: "referer")
        request.setValue("*/*", forHTTPHeaderField: "accept")
        request.setValue("u=1, i", forHTTPHeaderField: "priority")
        request.httpBody = Self.formEncode(payload)
        let (data, response) = try await session.data(for: request)
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
        let responseText = String(data: data, encoding: .utf8) ?? ""

        // Log raw response để người dùng xem được trong Log Console
        let rawPreview = String(responseText.prefix(250)).replacingOccurrences(of: "\n", with: "↵")
        AppLogger.shared.debug("NewsFeed-RAW", "doc_id \(docId): HTTP \(httpStatus), \(data.count)B → \(rawPreview)")

        // Phát hiện lỗi doc_id không tồn tại
        if responseText.contains("\"errors\"") && (responseText.contains("doc_id") || responseText.contains("DocumentID")) {
            let preview = String(responseText.prefix(200)).replacingOccurrences(of: "\n", with: " ")
            AppLogger.shared.warning("NewsFeed", "doc_id \(docId) lỗi: \(preview)")
            return []
        }

        // Bóc tách bài viết trực tiếp (không chặn nhầm nếu response chứa chữ login)
        var posts = extractPostItems(from: responseText)
        if !accessToken.isEmpty {
            for idx in posts.indices where posts[idx].postText.isEmpty {
                if let t = await fetchPostMessageViaGraphAPI(postId: posts[idx].postId, userId: posts[idx].userId) {
                    posts[idx].postText = t
                }
            }
        }
        return posts
    }

    private func fetchFeedViaHomepageScrape(tok: FacebookWebSessionTokens) async throws -> [FeedPostItem] {
        guard let url = URL(string: "https://www.facebook.com") else { return [] }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        for (k, v) in baseHeaders { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("navigate", forHTTPHeaderField: "sec-fetch-mode")
        request.setValue("?1", forHTTPHeaderField: "sec-fetch-user")
        request.setValue("document", forHTTPHeaderField: "sec-fetch-dest")

        let (data, response) = try await session.data(for: request)
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
        let html = String(data: data, encoding: .utf8) ?? ""
        AppLogger.shared.debug("NewsFeed", "Homepage scrape: HTTP \(httpStatus), \(data.count) bytes")

        var posts: [FeedPostItem] = []
        var seenIds = Set<String>()

        // 1. Quét thẻ <script> nhúng JSON trong HTML
        let scriptPattern = #"<script[^>]*>([\s\S]*?)<\/script>"#
        if let scriptRegex = try? NSRegularExpression(pattern: scriptPattern, options: []) {
            let nsHtml = html as NSString
            let matches = scriptRegex.matches(in: html, range: NSRange(location: 0, length: nsHtml.length))
            for m in matches where m.numberOfRanges > 1 {
                if let range = Range(m.range(at: 1), in: html) {
                    let scriptContent = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if scriptContent.contains("\"post_id\"") || scriptContent.contains("\"story_fbid\"") {
                        var cleaned = scriptContent
                        if cleaned.hasPrefix("for (;;);") {
                            cleaned = String(cleaned.dropFirst(9)).trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        if let d = cleaned.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: d) {
                            extractPostsFromObject(json, into: &posts, seen: &seenIds)
                        }
                    }
                }
            }
        }

        // 2. Quét từng dòng HTML
        let lines = html.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains("\"post_id\""),
               let lineData = trimmed.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: lineData) {
                extractPostsFromObject(json, into: &posts, seen: &seenIds)
            }
        }

        // 3. Fallback: quét regex post_id/story_fbid trực tiếp trong HTML
        if posts.isEmpty {
            let patterns = [
                #""post_id"\s*:\s*"?(\d{8,25})"?"#,
                #""story_fbid"\s*:\s*"?(\d{8,25})"?"#,
                #"data-ft="[^"]*top_level_post_id":(\d{8,25})"#
            ]
            let nsHtml = html as NSString
            for pat in patterns {
                if let regex = try? NSRegularExpression(pattern: pat) {
                    let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHtml.length))
                    for m in matches where m.numberOfRanges > 1 {
                        if let range = Range(m.range(at: 1), in: html) {
                            let pid = String(html[range])
                            if !seenIds.contains(pid) {
                                seenIds.insert(pid)
                                posts.append(FeedPostItem(postId: pid, userName: "Người dùng Facebook", userId: "", postText: ""))
                            }
                        }
                    }
                }
            }
        }

        if !accessToken.isEmpty {
            for idx in posts.indices where posts[idx].postText.isEmpty {
                if let t = await fetchPostMessageViaGraphAPI(postId: posts[idx].postId, userId: posts[idx].userId) {
                    posts[idx].postText = t
                }
            }
        }
        return posts
    }

    private func extractPostsFromObject(_ obj: Any, into posts: inout [FeedPostItem], seen: inout Set<String>) {
        func walk(_ o: Any, depth: Int = 0) {
            guard depth < 12 else { return }
            if let dict = o as? [String: Any] {
                if let postId = (dict["post_id"] as? String) ?? (dict["post_id"].flatMap { "\($0)" }),
                   !postId.isEmpty, !seen.contains(postId) {
                    seen.insert(postId)
                    let msg = (dict["message"] as? [String: Any])?["text"] as? String ?? ""
                    var name = "Người dùng Facebook"
                    if let actors = dict["actors"] as? [[String: Any]],
                       let first = actors.first,
                       let n = first["name"] as? String { name = n }
                    posts.append(FeedPostItem(postId: postId, userName: name, userId: "", postText: msg))
                }
                for (_, v) in dict { walk(v, depth: depth + 1) }
            } else if let arr = o as? [Any] {
                for v in arr { walk(v, depth: depth + 1) }
            }
        }
        walk(obj)
    }

    private func fetchPostMessageViaGraphAPI(postId: String, userId: String) async -> String? {
        guard !accessToken.isEmpty else { return nil }
        let queryId = userId.isEmpty ? postId : "\(userId)_\(postId)"
        var comps = URLComponents(string: "https://graph.facebook.com/v18.0/\(queryId)")
        comps?.queryItems = [
            URLQueryItem(name: "fields", value: "message,description,story"),
            URLQueryItem(name: "access_token", value: accessToken)
        ]
        guard let url = comps?.url else { return nil }
        do {
            let (data, _) = try await session.data(from: url)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let msg = json["message"] as? String, !msg.isEmpty { return msg }
                if let desc = json["description"] as? String, !desc.isEmpty { return desc }
                if let story = json["story"] as? String, !story.isEmpty { return story }
            }
        } catch {}
        return nil
    }

    private func extractPostItems(from responseText: String) -> [FeedPostItem] {
        var posts: [FeedPostItem] = []
        var seenIds = Set<String>()

        func extractStoryText(_ dict: [String: Any], depth: Int = 0) -> String {
            if depth > 6 { return "" }
            if let msg = dict["message"] as? [String: Any],
               let text = msg["text"] as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
            if let cometSections = dict["comet_sections"] as? [String: Any] {
                let text = extractStoryText(cometSections, depth: depth + 1)
                if !text.isEmpty { return text }
            }
            if let content = dict["content"] as? [String: Any] {
                let text = extractStoryText(content, depth: depth + 1)
                if !text.isEmpty { return text }
            }
            if let story = dict["story"] as? [String: Any] {
                let text = extractStoryText(story, depth: depth + 1)
                if !text.isEmpty { return text }
            }
            for (_, val) in dict {
                if let subDict = val as? [String: Any] {
                    let found = extractStoryText(subDict, depth: depth + 1)
                    if !found.isEmpty { return found }
                }
            }
            return ""
        }

        func searchRecursive(_ obj: Any, parentText: String = "", depth: Int = 0) {
            if depth > 15 { return }
            if let dict = obj as? [String: Any] {
                let localText = extractStoryText(dict)
                let effectiveText = !localText.isEmpty ? localText : parentText

                let candidateId: String? = {
                    if let s = dict["post_id"] as? String, !s.isEmpty { return s }
                    if let n = dict["post_id"] as? NSNumber { return n.stringValue }
                    if let s = dict["top_level_post_id"] as? String, !s.isEmpty { return s }
                    if let n = dict["top_level_post_id"] as? NSNumber { return n.stringValue }
                    if let s = dict["story_fbid"] as? String, !s.isEmpty { return s }
                    if let n = dict["story_fbid"] as? NSNumber { return n.stringValue }
                    return nil
                }()

                if let postId = candidateId, !postId.isEmpty {
                    if !seenIds.contains(postId) {
                        seenIds.insert(postId)
                        var userName = "Người dùng Facebook"
                        var authorId = ""
                        if let actors = dict["actors"] as? [[String: Any]] {
                            for actor in actors {
                                if (actor["__typename"] as? String) == "User" || actor["name"] != nil {
                                    userName = (actor["name"] as? String)?.replacingOccurrences(of: "\\", with: "") ?? userName
                                    authorId = (actor["id"] as? String) ?? ((actor["id"] as? NSNumber)?.stringValue ?? "")
                                    break
                                }
                            }
                        }
                        posts.append(FeedPostItem(
                            postId: postId,
                            userName: userName,
                            userId: authorId,
                            postText: effectiveText
                        ))
                    } else if !effectiveText.isEmpty,
                              let existingIdx = posts.firstIndex(where: { $0.postId == postId && $0.postText.isEmpty }) {
                        posts[existingIdx].postText = effectiveText
                    }
                }

                for (_, value) in dict {
                    searchRecursive(value, parentText: effectiveText, depth: depth + 1)
                }
            } else if let array = obj as? [Any] {
                for item in array {
                    searchRecursive(item, parentText: parentText, depth: depth + 1)
                }
            }
        }

        for line in responseText.components(separatedBy: .newlines) {
            var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("for (;;);") {
                trimmed = String(trimmed.dropFirst(9)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) else {
                continue
            }
            searchRecursive(json)
        }

        // Nếu NDJSON không ra bài nào, thử parse toàn bộ response nếu là một JSON duy nhất
        if posts.isEmpty {
            var fullCleaned = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
            if fullCleaned.hasPrefix("for (;;);") {
                fullCleaned = String(fullCleaned.dropFirst(9)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let fullData = fullCleaned.data(using: .utf8),
               let fullJson = try? JSONSerialization.jsonObject(with: fullData) {
                searchRecursive(fullJson)
            }
        }

        // Fallback: nếu vẫn rỗng, quét Regex trực tiếp toàn bộ responseText
        if posts.isEmpty {
            let patterns = [
                #""post_id"\s*:\s*"?(\d{8,25})"?"#,
                #""top_level_post_id"\s*:\s*"?(\d{8,25})"?"#,
                #""story_fbid"\s*:\s*"?(\d{8,25})"?"#
            ]
            let nsStr = responseText as NSString
            for pat in patterns {
                if let regex = try? NSRegularExpression(pattern: pat) {
                    let matches = regex.matches(in: responseText, range: NSRange(location: 0, length: nsStr.length))
                    for m in matches where m.numberOfRanges > 1 {
                        if let range = Range(m.range(at: 1), in: responseText) {
                            let pid = String(responseText[range])
                            if !seenIds.contains(pid) {
                                seenIds.insert(pid)
                                posts.append(FeedPostItem(postId: pid, userName: "Người dùng Facebook", userId: "", postText: ""))
                            }
                        }
                    }
                }
            }
        }

        return posts
    }

    // MARK: - React to Post (Dual Engine: Graph API -> Fallback Comet GraphQL)

    func reactToPost(postId: String, reaction: FacebookReactionType, explicitFeedbackId: String? = nil) async -> (success: Bool, message: String) {
        let concrete = reaction.resolveConcrete()

        // ── 1. Thử qua Facebook Graph API (Nếu có Access Token) ──
        if !accessToken.isEmpty {
            if let graphRes = await reactViaGraphAPI(postId: postId, reaction: concrete) {
                if graphRes.success {
                    AppLogger.shared.info("AutoReact", "✅ [\(concrete.rawValue)] Post ID: \(postId) (Graph API)")
                    return graphRes
                }
                AppLogger.shared.debug("AutoReact", "Graph API react không khả dụng, chuyển sang Comet GraphQL...")
            }
        }

        // ── 2. Comet Web GraphQL Mutation ──
        let tok: FacebookWebSessionTokens
        if let existing = tokens {
            tok = existing
        } else {
            do {
                tok = try await prepareTokens()
            } catch {
                return (false, "Chưa khởi tạo token phiên web: \(error.localizedDescription)")
            }
        }
        let feedbackId = (explicitFeedbackId?.isEmpty == false)
            ? explicitFeedbackId!
            : Data("feedback:\(postId)".utf8).base64EncodedString()

        let variables: [String: Any] = [
            "input": [
                "attribution_id_v2": "CometSinglePostDialogRoot.react,comet.post.single_dialog,via_cold_start,\(Int(Date().timeIntervalSince1970 * 1000)),270454,,,",
                "feedback_id": feedbackId,
                "feedback_reaction_id": concrete.graphQLId,
                "feedback_source": "OBJECT",
                "is_tracking_encrypted": true,
                "tracking": [],
                "session_id": UUID().uuidString.lowercased(),
                "downstream_share_session_id": UUID().uuidString.lowercased(),
                "downstream_share_session_origin_uri": "",
                "downstream_share_session_start_time": String(Int(Date().timeIntervalSince1970 * 1000)),
                "actor_id": tok.userId,
                "client_mutation_id": "1"
            ],
            "useDefaultActor": false,
            "__relay_internal__pv__CometUFIReactionsEnableShortNamerelayprovider": false
        ]

        let payload: [String: String] = [
            "av": tok.userId,
            "__aaid": "0",
            "__user": tok.userId,
            "__a": "1",
            "__req": "1x",
            "__hs": "20100.HYP:comet_pkg.2.1.0.2.1",
            "dpr": "1",
            "__ccg": "GOOD",
            "__rev": "1019282004",
            "__comet_req": "15",
            "fb_dtsg": tok.dtsgToken,
            "jazoest": tok.jazoest,
            "lsd": tok.lsdToken,
            "__spin_r": "1019282004",
            "__spin_b": "trunk",
            "__spin_t": String(Int(Date().timeIntervalSince1970)),
            "fb_api_caller_class": "RelayModern",
            "fb_api_req_friendly_name": "CometUFIFeedbackReactMutation",
            "variables": Self.jsonString(from: variables),
            "server_timestamps": "true",
            "doc_id": "8995964513767096"
        ]

        var request = URLRequest(url: URL(string: "https://www.facebook.com/api/graphql/")!)
        request.httpMethod = "POST"
        for (k, v) in baseHeaders { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue("CometUFIFeedbackReactMutation", forHTTPHeaderField: "x-fb-friendly-name")
        request.setValue("129477", forHTTPHeaderField: "x-asbd-id")
        request.setValue(tok.lsdToken, forHTTPHeaderField: "x-fb-lsd")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        request.setValue("https://www.facebook.com", forHTTPHeaderField: "origin")
        request.setValue("same-origin", forHTTPHeaderField: "sec-fetch-site")
        request.setValue("cors", forHTTPHeaderField: "sec-fetch-mode")
        request.setValue("empty", forHTTPHeaderField: "sec-fetch-dest")
        request.setValue("https://www.facebook.com", forHTTPHeaderField: "referer")
        request.setValue("*/*", forHTTPHeaderField: "accept")
        request.setValue("u=1, i", forHTTPHeaderField: "priority")
        request.httpBody = Self.formEncode(payload)

        do {
            let (data, httpResp) = try await session.data(for: request)
            let httpStatus = (httpResp as? HTTPURLResponse)?.statusCode ?? 0
            let rawStr = String(data: data, encoding: .utf8) ?? ""
            let rawPrev = String(rawStr.prefix(300)).replacingOccurrences(of: "\n", with: "↵")
            AppLogger.shared.debug("AutoReact-RAW", "HTTP \(httpStatus), \(data.count)B: \(rawPrev)")

            let json = Self.parseFacebookGraphQLResponse(data)

            if let json {
                if let dataObj = json["data"] as? [String: Any],
                   let reactObj = dataObj["feedback_react"] as? [String: Any],
                   reactObj["feedback"] != nil {
                    let msg = "Đã thả cảm xúc \(concrete.rawValue)"
                    AppLogger.shared.info("AutoReact", "✅ [\(concrete.rawValue)] Post ID: \(postId)")
                    return (true, msg)
                }
                if let errors = json["errors"] as? [[String: Any]],
                   let desc = (errors.first?["description"] as? String) ?? (errors.first?["message"] as? String) {
                    AppLogger.shared.error("AutoReact", "❌ Thả cảm xúc thất bại: Post ID \(postId)", detail: desc)
                    return (false, desc)
                }
                if let errDesc = (json["errorDescription"] as? String) ?? (json["errorSummary"] as? String) {
                    let desc = errDesc.replacingOccurrences(of: "\\n", with: " ")
                    AppLogger.shared.error("AutoReact", "❌ Facebook chặn cảm xúc: Post ID \(postId)", detail: desc)
                    return (false, desc)
                }
            }

            if rawStr.contains("\"feedback_react\"") {
                AppLogger.shared.info("AutoReact", "✅ [\(concrete.rawValue)] Post ID: \(postId) (Khớp chuỗi)")
                return (true, "Đã thả cảm xúc \(concrete.rawValue)")
            }

            let preview = String(rawStr.prefix(150)).replacingOccurrences(of: "\n", with: " ")
            let failMsg = "Phản hồi: \(preview.isEmpty ? "Rỗng" : preview)"
            AppLogger.shared.error("AutoReact", "❌ Post ID \(postId): \(failMsg)")
            return (false, failMsg)
        } catch {
            AppLogger.shared.error("AutoReact", "❌ Lỗi mạng khi react Post ID \(postId)", detail: error.localizedDescription)
            return (false, error.localizedDescription)
        }
    }

    private func reactViaGraphAPI(postId: String, reaction: FacebookReactionType) async -> (success: Bool, message: String)? {
        guard !accessToken.isEmpty else { return nil }
        guard let url = URL(string: "https://graph.facebook.com/v18.0/\(postId)/reactions") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let bodyParams = [
            "type": reaction.rawValue,
            "access_token": accessToken
        ]
        req.httpBody = Self.formEncode(bodyParams)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        do {
            let (data, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if json["success"] as? Bool == true || status == 200 {
                    return (true, "Đã thả cảm xúc \(reaction.rawValue)")
                }
                if let err = json["error"] as? [String: Any],
                   let msg = err["message"] as? String {
                    return (false, msg)
                }
            }
            return (status == 200, status == 200 ? "Thành công" : "Mã phản hồi \(status)")
        } catch {
            return nil
        }
    }

    // MARK: - Comment on Post (Dual Engine: Graph API -> Fallback Comet GraphQL)

    func commentOnPost(postId: String, commentText: String, explicitFeedbackId: String? = nil) async -> (success: Bool, message: String) {
        // ── 1. Thử qua Facebook Graph API (Nếu có Access Token) ──
        if !accessToken.isEmpty {
            if let graphRes = await commentViaGraphAPI(postId: postId, text: commentText) {
                if graphRes.success {
                    AppLogger.shared.info("AutoComment", "✅ Post ID: \(postId) (Graph API)", detail: "Nội dung: \"\(commentText)\"")
                    return graphRes
                }
                AppLogger.shared.debug("AutoComment", "Graph API comment không khả dụng, chuyển sang Comet GraphQL...")
            }
        }

        // ── 2. Comet Web GraphQL Mutation ──
        let tok: FacebookWebSessionTokens
        if let existing = tokens {
            tok = existing
        } else {
            do {
                tok = try await prepareTokens()
            } catch {
                return (false, "Chưa khởi tạo token phiên web: \(error.localizedDescription)")
            }
        }
        let feedbackId = (explicitFeedbackId?.isEmpty == false)
            ? explicitFeedbackId!
            : Data("feedback:\(postId)".utf8).base64EncodedString()
        let sessionId = UUID().uuidString.lowercased()
        let trackingId = "client:\(UUID().uuidString.lowercased())"

        let variables: [String: Any] = [
            "feedLocation": "DEDICATED_COMMENTING_SURFACE",
            "feedbackSource": 110,
            "groupID": NSNull(),
            "input": [
                "client_mutation_id": String(Int.random(in: 1...10)),
                "actor_id": tok.userId,
                "attachments": NSNull(),
                "feedback_id": feedbackId,
                "formatting_style": NSNull(),
                "message": [
                    "ranges": [],
                    "text": commentText
                ],
                "attribution_id_v2": "CometHomeRoot.react,comet.home,via_cold_start,\(Int(Date().timeIntervalSince1970 * 1000)),267777,4748854339,,",
                "vod_video_timestamp": NSNull(),
                "is_tracking_encrypted": true,
                "tracking": [],
                "feedback_source": "DEDICATED_COMMENTING_SURFACE",
                "idempotence_token": trackingId,
                "session_id": sessionId
            ],
            "inviteShortLinkKey": NSNull(),
            "renderLocation": NSNull(),
            "scale": 1,
            "useDefaultActor": false,
            "focusCommentID": NSNull(),
            "__relay_internal__pv__CometUFICommentAvatarStickerAnimatedImagerelayprovider": false,
            "__relay_internal__pv__IsWorkUserrelayprovider": false
        ]

        let payload: [String: String] = [
            "av": tok.userId,
            "__aaid": "0",
            "__user": tok.userId,
            "__a": "1",
            "__req": String(Int.random(in: 20...30)),
            "__hs": "20347.HYP:comet_pkg.2.1...0",
            "dpr": "1",
            "__ccg": "EXCELLENT",
            "__rev": "1027174263",
            "__comet_req": "15",
            "fb_dtsg": tok.dtsgToken,
            "jazoest": tok.jazoest,
            "lsd": tok.lsdToken,
            "__spin_r": "1027174263",
            "__spin_b": "trunk",
            "__spin_t": String(Int(Date().timeIntervalSince1970)),
            "__crn": "comet.fbweb.CometHomeRoute",
            "fb_api_caller_class": "RelayModern",
            "fb_api_req_friendly_name": "useCometUFICreateCommentMutation",
            "variables": Self.jsonString(from: variables),
            "server_timestamps": "true",
            "doc_id": "24356199814008185"
        ]

        var request = URLRequest(url: URL(string: "https://www.facebook.com/api/graphql/")!)
        request.httpMethod = "POST"
        for (k, v) in baseHeaders { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue("useCometUFICreateCommentMutation", forHTTPHeaderField: "x-fb-friendly-name")
        request.setValue("359341", forHTTPHeaderField: "x-asbd-id")
        request.setValue(tok.lsdToken, forHTTPHeaderField: "x-fb-lsd")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        request.setValue("https://www.facebook.com", forHTTPHeaderField: "origin")
        request.setValue("same-origin", forHTTPHeaderField: "sec-fetch-site")
        request.setValue("cors", forHTTPHeaderField: "sec-fetch-mode")
        request.setValue("empty", forHTTPHeaderField: "sec-fetch-dest")
        request.setValue("https://www.facebook.com", forHTTPHeaderField: "referer")
        request.setValue("*/*", forHTTPHeaderField: "accept")
        request.setValue("u=1, i", forHTTPHeaderField: "priority")
        request.httpBody = Self.formEncode(payload)

        do {
            let (data, httpResp) = try await session.data(for: request)
            let httpStatus = (httpResp as? HTTPURLResponse)?.statusCode ?? 0
            let rawStr = String(data: data, encoding: .utf8) ?? ""
            let rawPrev = String(rawStr.prefix(300)).replacingOccurrences(of: "\n", with: "↵")
            AppLogger.shared.debug("AutoComment-RAW", "HTTP \(httpStatus), \(data.count)B: \(rawPrev)")

            let json = Self.parseFacebookGraphQLResponse(data)

            if let json {
                if let dataObj = json["data"] as? [String: Any],
                   let commentCreate = dataObj["comment_create"] as? [String: Any] {
                    if let edge = commentCreate["feedback_comment_edge"] as? [String: Any],
                       let node = edge["node"] as? [String: Any],
                       node["id"] != nil {
                        let successMsg = "Đã bình luận: \"\(commentText.prefix(55))\""
                        AppLogger.shared.info("AutoComment", "✅ Post ID: \(postId)", detail: "Nội dung: \"\(commentText)\"")
                        return (true, successMsg)
                    }
                    if let feedback = commentCreate["feedback"] as? [String: Any],
                       let notice = feedback["comments_disabled_notice_renderer"] as? [String: Any],
                       (notice["__typename"] as? String) == "GeneralCommentDisableNotice" {
                        let noticeMsg = "Bài viết tắt bình luận UI nhưng API đã xử lý"
                        AppLogger.shared.warning("AutoComment", "⚠️ Post ID: \(postId) — \(noticeMsg)")
                        return (true, noticeMsg)
                    }
                }
                if let errors = json["errors"] as? [[String: Any]],
                   let desc = (errors.first?["description"] as? String) ?? (errors.first?["message"] as? String) {
                    AppLogger.shared.error("AutoComment", "❌ Comment thất bại: Post ID \(postId)", detail: desc)
                    return (false, desc)
                }
                if let errDesc = (json["errorDescription"] as? String) ?? (json["errorSummary"] as? String) {
                    let desc = errDesc.replacingOccurrences(of: "\\n", with: " ")
                    AppLogger.shared.error("AutoComment", "❌ Facebook chặn bình luận: Post ID \(postId)", detail: desc)
                    return (false, desc)
                }
                if let errorObj = json["error"] as? [String: Any],
                   let msg = (errorObj["message"] as? String) ?? (errorObj["description"] as? String) {
                    AppLogger.shared.error("AutoComment", "❌ Comment thất bại: Post ID \(postId)", detail: msg)
                    return (false, msg)
                }
            }

            if rawStr.contains("\"comment_create\"") {
                AppLogger.shared.info("AutoComment", "✅ Post ID: \(postId) (Khớp chuỗi)")
                return (true, "Đã bình luận: \"\(commentText.prefix(55))\"")
            }

            let preview = String(rawStr.prefix(150)).replacingOccurrences(of: "\n", with: " ")
            let failMsg = "Comment thất bại (\(preview.isEmpty ? "Phản hồi rỗng" : preview))"
            AppLogger.shared.error("AutoComment", "❌ Post ID \(postId): \(failMsg)")
            return (false, failMsg)
        } catch {
            AppLogger.shared.error("AutoComment", "❌ Lỗi mạng khi comment Post ID \(postId)", detail: error.localizedDescription)
            return (false, error.localizedDescription)
        }
    }

    private func commentViaGraphAPI(postId: String, text: String) async -> (success: Bool, message: String)? {
        guard !accessToken.isEmpty else { return nil }
        guard let url = URL(string: "https://graph.facebook.com/v18.0/\(postId)/comments") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let bodyParams = [
            "message": text,
            "access_token": accessToken
        ]
        req.httpBody = Self.formEncode(bodyParams)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        do {
            let (data, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let newId = json["id"] as? String, !newId.isEmpty {
                    return (true, "Đã bình luận: \"\(text.prefix(55))\"")
                }
                if let err = json["error"] as? [String: Any],
                   let msg = err["message"] as? String {
                    return (false, msg)
                }
            }
            return (status == 200, status == 200 ? "Thành công" : "Mã phản hồi \(status)")
        } catch {
            return nil
        }
    }

    // MARK: - Robust Facebook GraphQL Response Parser (Hỗ trợ NDJSON, loại bỏ for(;;);)

    private static func parseFacebookGraphQLResponse(_ data: Data) -> [String: Any]? {
        let rawStr = String(data: data, encoding: .utf8) ?? ""
        var cleaned = rawStr.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("for (;;);") {
            cleaned = String(cleaned.dropFirst(9)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let directData = cleaned.data(using: .utf8),
           let directJson = try? JSONSerialization.jsonObject(with: directData) as? [String: Any] {
            return directJson
        }
        for line in cleaned.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let lineData = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            if obj["data"] != nil || obj["errors"] != nil || obj["error"] != nil || obj["errorSummary"] != nil || obj["errorDescription"] != nil {
                return obj
            }
        }
        return nil
    }

    private static func firstMatch(pattern: String, in text: String) -> String? {
        guard !text.isEmpty,
              let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsText = text as NSString
        guard let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: nsText.length)),
              match.numberOfRanges > 1 else {
            return nil
        }
        let r = match.range(at: 1)
        guard r.location != NSNotFound, r.location + r.length <= nsText.length else { return nil }
        return nsText.substring(with: r)
    }

    private static func jsonString(from dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    static func parseCookies(from cookieString: String) -> [HTTPCookie] {
        var cookies: [HTTPCookie] = []
        let pairs = cookieString.components(separatedBy: ";")
        let domains = [".facebook.com", "facebook.com", "m.facebook.com", "mbasic.facebook.com", "www.facebook.com"]
        for pair in pairs {
            let trimmed = pair.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eqIdx = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[..<eqIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(trimmed[trimmed.index(after: eqIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            for d in domains {
                let props: [HTTPCookiePropertyKey: Any] = [
                    .name: name,
                    .value: value,
                    .domain: d,
                    .path: "/",
                    .secure: "TRUE"
                ]
                if let c = HTTPCookie(properties: props) {
                    cookies.append(c)
                }
            }
        }
        return cookies
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
}

// MARK: - Multi-Space & Single-Space Auto Interaction Coordinator + SafeMode

enum MultiSpaceExecutionOrder: String, CaseIterable, Identifiable {
    case parallel = "Song song (Độc lập từng không gian)"
    case sequential = "Tuần tự (Lần lượt từng không gian)"
    var id: String { rawValue }
}

struct SpaceInteractLogEntry: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let spaceName: String
    let postAuthor: String
    let postId: String
    let postSnippet: String
    let reactionSummary: String
    let commentSummary: String
    let isError: Bool
}

struct SpaceRunnerState: Identifiable {
    let id: UUID
    let name: String
    var statusText: String = "Đang chờ..."
    var reactSuccessCount: Int = 0
    var commentSuccessCount: Int = 0
    var processedPostsCount: Int = 0
    var isRunning: Bool = false
}

@MainActor
final class AutoInteractCoordinator: ObservableObject {
    @Published var states: [UUID: SpaceRunnerState] = [:]
    @Published var logs: [SpaceInteractLogEntry] = []
    @Published var isRunning = false

    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var masterTask: Task<Void, Never>?

    func stopAll() {
        isRunning = false
        masterTask?.cancel()
        masterTask = nil
        for (_, task) in activeTasks {
            task.cancel()
        }
        activeTasks.removeAll()
        for key in states.keys {
            states[key]?.isRunning = false
            states[key]?.statusText = "Đã dừng"
        }
    }

    func start(
        spaces: [Space],
        executionOrder: MultiSpaceExecutionOrder,
        useReaction: Bool,
        reactionType: FacebookReactionType,
        useComment: Bool,
        geminiApiKey: String,
        geminiModel: String,
        geminiStylePrompt: String,
        safeModeEnabled: Bool,
        minPostDelay: Double,
        maxPostDelay: Double,
        minActionGap: Double,
        maxActionGap: Double,
        continuousLoop: Bool,
        minCycleDelay: Double,
        maxCycleDelay: Double,
        maxPostsPerRound: Int
    ) {
        stopAll()
        guard !spaces.isEmpty else { return }
        isRunning = true

        states = Dictionary(uniqueKeysWithValues: spaces.map {
            ($0.id, SpaceRunnerState(id: $0.id, name: $0.name, statusText: "Chuẩn bị...", isRunning: true))
        })

        masterTask = Task {
            if executionOrder == .parallel {
                await withTaskGroup(of: Void.self) { group in
                    for space in spaces {
                        group.addTask { [weak self] in
                            await self?.runSingleSpaceLoop(
                                space: space,
                                useReaction: useReaction,
                                reactionType: reactionType,
                                useComment: useComment,
                                geminiApiKey: geminiApiKey,
                                geminiModel: geminiModel,
                                geminiStylePrompt: geminiStylePrompt,
                                safeModeEnabled: safeModeEnabled,
                                minPostDelay: minPostDelay,
                                maxPostDelay: maxPostDelay,
                                minActionGap: minActionGap,
                                maxActionGap: maxActionGap,
                                continuousLoop: continuousLoop,
                                minCycleDelay: minCycleDelay,
                                maxCycleDelay: maxCycleDelay,
                                maxPostsPerRound: maxPostsPerRound
                            )
                        }
                    }
                }
            } else {
                for space in spaces {
                    if Task.isCancelled || !isRunning { break }
                    await runSingleSpaceLoop(
                        space: space,
                        useReaction: useReaction,
                        reactionType: reactionType,
                        useComment: useComment,
                        geminiApiKey: geminiApiKey,
                        geminiModel: geminiModel,
                        geminiStylePrompt: geminiStylePrompt,
                        safeModeEnabled: safeModeEnabled,
                        minPostDelay: minPostDelay,
                        maxPostDelay: maxPostDelay,
                        minActionGap: minActionGap,
                        maxActionGap: maxActionGap,
                        continuousLoop: continuousLoop,
                        minCycleDelay: minCycleDelay,
                        maxCycleDelay: maxCycleDelay,
                        maxPostsPerRound: maxPostsPerRound
                    )
                }
            }
            if !Task.isCancelled {
                isRunning = false
            }
        }
    }

    private func resolveCookieAndToken(for space: Space) async -> (cookie: String, token: String) {
        if let vault = try? SecureLoginStore.readTokenVault(space.id) {
            var cookieStr = vault.cookieString
            if cookieStr.isEmpty, !vault.cookies.isEmpty {
                cookieStr = FacebookAppTokens.formatCookieString(vault.cookies)
            }
            if cookieStr.isEmpty {
                let webCookies = await WebCookieBridge.extractFacebookCookies(from: space.id)
                cookieStr = FacebookAppTokens.formatCookieString(webCookies)
            }
            let tok = !vault.originalToken.isEmpty
                ? vault.originalToken
                : (vault.convertedTokens["FB_ANDROID"]?.accessToken ?? "")
            return (cookieStr, tok)
        } else {
            let webCookies = await WebCookieBridge.extractFacebookCookies(from: space.id)
            let cookieStr = FacebookAppTokens.formatCookieString(webCookies)
            return (cookieStr, "")
        }
    }

    private func randomDelaySeconds(minVal: Double, maxVal: Double, safeMode: Bool) -> Double {
        let low = max(0.1, min(minVal, maxVal))
        let high = max(low, max(minVal, maxVal))
        if safeMode {
            let base = Double.random(in: low...high)
            let microJitter = Double.random(in: 0.05...0.95)
            return base + microJitter
        } else {
            return Double.random(in: low...high)
        }
    }

    private func sleepRandomly(
        for spaceId: UUID,
        minSeconds: Double,
        maxSeconds: Double,
        safeMode: Bool,
        reason: String
    ) async -> Bool {
        let totalWait = randomDelaySeconds(minVal: minSeconds, maxVal: maxSeconds, safeMode: safeMode)
        let prefix = safeMode ? "🛡️ SafeMode" : "⏳ Chờ ngẫu nhiên"
        states[spaceId]?.statusText = String(format: "%@: %@ (%.1fs)...", prefix, reason, totalWait)
        let nanos = UInt64(totalWait * 1_000_000_000)
        do {
            try await Task.sleep(nanoseconds: nanos)
            return !Task.isCancelled && isRunning
        } catch {
            return false
        }
    }

    private func runSingleSpaceLoop(
        space: Space,
        useReaction: Bool,
        reactionType: FacebookReactionType,
        useComment: Bool,
        geminiApiKey: String,
        geminiModel: String,
        geminiStylePrompt: String,
        safeModeEnabled: Bool,
        minPostDelay: Double,
        maxPostDelay: Double,
        minActionGap: Double,
        maxActionGap: Double,
        continuousLoop: Bool,
        minCycleDelay: Double,
        maxCycleDelay: Double,
        maxPostsPerRound: Int
    ) async {
        states[space.id]?.isRunning = true
        states[space.id]?.statusText = "Đang đọc Cookie & Token đã lưu..."

        let credentials = await resolveCookieAndToken(for: space)
        guard !credentials.cookie.isEmpty else {
            states[space.id]?.isRunning = false
            states[space.id]?.statusText = "Thiếu Cookie! Hãy lấy Token/Cookie trước."
            appendLog(
                spaceName: space.name,
                postAuthor: "Hệ thống",
                postId: "-",
                postSnippet: "",
                reactionSummary: "-",
                commentSummary: "Không gian chưa có Cookie trong Kho Token hoặc WebView.",
                isError: true
            )
            return
        }

        let client = FacebookGraphQLAutoClient(
            spaceId: space.id,
            cookieString: credentials.cookie,
            accessToken: credentials.token,
            proxy: space.proxy,
            userAgent: space.fingerprint?.userAgent
        )

        do {
            states[space.id]?.statusText = "Đang chuẩn bị fb_dtsg & lsd token..."
            _ = try await client.prepareTokens()
        } catch {
            states[space.id]?.isRunning = false
            states[space.id]?.statusText = "Lỗi lấy token: \(error.localizedDescription)"
            appendLog(
                spaceName: space.name,
                postAuthor: "Hệ thống",
                postId: "-",
                postSnippet: "",
                reactionSummary: "-",
                commentSummary: error.localizedDescription,
                isError: true
            )
            return
        }

        repeat {
            if Task.isCancelled || !isRunning { break }
            states[space.id]?.statusText = "Đang lấy danh sách bài viết từ News Feed..."

            let allPosts: [FeedPostItem]
            do {
                allPosts = try await client.getNewsFeedPosts()
            } catch {
                let errMsg = "Lỗi News Feed: \(error.localizedDescription)"
                states[space.id]?.statusText = errMsg
                AppLogger.shared.error("AutoInteract", "[\(space.name)] Lỗi lấy News Feed", detail: error.localizedDescription)
                break
            }

            let posts = maxPostsPerRound > 0 ? Array(allPosts.prefix(maxPostsPerRound)) : allPosts
            if posts.isEmpty {
                states[space.id]?.statusText = "Không tìm thấy bài viết mới trên News Feed."
            } else {
                for (index, post) in posts.enumerated() {
                    if Task.isCancelled || !isRunning { break }

                    states[space.id]?.statusText = "Bài \(index + 1)/\(posts.count): \(post.userName)"

                    var geminiResult: GeminiAnalysisResult? = nil
                    var geminiErrorText: String? = nil

                    if useComment || reactionType == .geminiAuto {
                        states[space.id]?.statusText = "✨ Gemini đang phân tích bài của \(post.userName)..."
                        do {
                            geminiResult = try await GeminiCommentService.analyzeAndGenerateComment(
                                post: post,
                                apiKey: geminiApiKey,
                                model: geminiModel,
                                customStylePrompt: geminiStylePrompt
                            )
                        } catch {
                            geminiErrorText = error.localizedDescription
                        }
                    }

                    var reactMsg = "Bỏ qua"
                    var commentMsg = "Bỏ qua"
                    var hasError = false

                    if useReaction {
                        let chosenReaction: FacebookReactionType
                        if reactionType == .geminiAuto, let suggested = geminiResult?.suggestedReaction {
                            chosenReaction = suggested
                        } else {
                            chosenReaction = reactionType.resolveConcrete()
                        }
                        states[space.id]?.statusText = "Đang thả \(chosenReaction.rawValue) bài của \(post.userName)..."
                        let res = await client.reactToPost(postId: post.postId, reaction: chosenReaction)
                        reactMsg = res.message
                        if res.success {
                            states[space.id]?.reactSuccessCount += 1
                        } else {
                            hasError = true
                        }

                        if useComment {
                            let ok = await sleepRandomly(
                                for: space.id,
                                minSeconds: minActionGap,
                                maxSeconds: maxActionGap,
                                safeMode: safeModeEnabled,
                                reason: "nghỉ giữa cảm xúc và bình luận"
                            )
                            if !ok { break }
                        }
                    }

                    if useComment {
                        if let generatedComment = geminiResult?.comment, !generatedComment.isEmpty {
                            states[space.id]?.statusText = "Đang gửi bình luận AI vào bài của \(post.userName)..."
                            let res = await client.commentOnPost(postId: post.postId, commentText: generatedComment)
                            commentMsg = res.message
                            if res.success {
                                states[space.id]?.commentSuccessCount += 1
                            } else {
                                hasError = true
                            }
                        } else {
                            commentMsg = geminiErrorText ?? "Không tạo được bình luận từ Gemini"
                            hasError = true
                        }
                    }

                    states[space.id]?.processedPostsCount += 1
                    appendLog(
                        spaceName: space.name,
                        postAuthor: post.userName,
                        postId: post.postId,
                        postSnippet: post.postText,
                        reactionSummary: reactMsg,
                        commentSummary: commentMsg,
                        isError: hasError
                    )

                    if index < posts.count - 1 {
                        let ok = await sleepRandomly(
                            for: space.id,
                            minSeconds: minPostDelay,
                            maxSeconds: maxPostDelay,
                            safeMode: safeModeEnabled,
                            reason: "nghỉ giữa các bài viết"
                        )
                        if !ok { break }
                    }
                }
            }

            if !continuousLoop || Task.isCancelled || !isRunning {
                break
            }

            let ok = await sleepRandomly(
                for: space.id,
                minSeconds: minCycleDelay,
                maxSeconds: maxCycleDelay,
                safeMode: safeModeEnabled,
                reason: "chờ đợt lấy News Feed tiếp theo"
            )
            if !ok { break }
        } while continuousLoop && !Task.isCancelled && isRunning

        states[space.id]?.isRunning = false
        if !Task.isCancelled {
            states[space.id]?.statusText = "Hoàn tất"
        }
    }

    private func appendLog(
        spaceName: String,
        postAuthor: String,
        postId: String,
        postSnippet: String,
        reactionSummary: String,
        commentSummary: String,
        isError: Bool
    ) {
        let entry = SpaceInteractLogEntry(
            spaceName: spaceName,
            postAuthor: postAuthor,
            postId: postId,
            postSnippet: postSnippet,
            reactionSummary: reactionSummary,
            commentSummary: commentSummary,
            isError: isError
        )
        logs.insert(entry, at: 0)
        if logs.count > 200 {
            logs.removeLast(logs.count - 200)
        }

        let summary = "[\(spaceName)] \(postAuthor) — React: \(reactionSummary) | Cmt: \(commentSummary)"
        if isError {
            AppLogger.shared.error("AutoInteract", summary, detail: "Post ID: \(postId)")
        } else {
            AppLogger.shared.info("AutoInteract", summary)
        }
    }
}

// MARK: - UI: Auto Reaction + Gemini Comment + SafeMode View

struct AutoInteractView: View {
    @EnvironmentObject private var library: SpaceLibrary
    @StateObject private var coordinator = AutoInteractCoordinator()

    let preselectedSpace: Space?

    @State private var selectedIDs: Set<UUID> = []
    @State private var executionOrder: MultiSpaceExecutionOrder = .parallel

    @AppStorage("vie.auto.useReaction") private var useReaction = true
    @AppStorage("vie.auto.reactionType") private var reactionTypeRaw = FacebookReactionType.geminiAuto.rawValue
    @AppStorage("vie.auto.useComment") private var useComment = true
    @AppStorage("vie.auto.geminiModelV2") private var geminiModel = "auto"
    @AppStorage("vie.auto.geminiStyle") private var geminiStylePrompt = "Tự nhiên như người thật trên Facebook, thân thiện, đúng trọng tâm nội dung bài viết, ngắn gọn 1-2 câu."

    @AppStorage("vie.auto.safeMode") private var safeModeEnabled = true
    @AppStorage("vie.auto.minPostDelay") private var minPostDelayText = "5"
    @AppStorage("vie.auto.maxPostDelay") private var maxPostDelayText = "25"
    @AppStorage("vie.auto.minActionGap") private var minActionGapText = "2"
    @AppStorage("vie.auto.maxActionGap") private var maxActionGapText = "6"
    @AppStorage("vie.auto.continuousLoop") private var continuousLoop = false
    @AppStorage("vie.auto.minCycleDelay") private var minCycleDelayText = "180"
    @AppStorage("vie.auto.maxCycleDelay") private var maxCycleDelayText = "420"
    @AppStorage("vie.auto.maxPosts") private var maxPostsText = "10"

    @State private var geminiApiKey = ""
    @State private var discoveredModels: [String] = GeminiCommentService.availableModels
    @State private var alertMessage: String?

    init(preselectedSpace: Space? = nil) {
        self.preselectedSpace = preselectedSpace
    }

    private var facebookSpaces: [Space] {
        library.spaces.filter { $0.platform == .facebook }
    }

    private var selectedSpaces: [Space] {
        facebookSpaces.filter { selectedIDs.contains($0.id) }
    }

    private var reactionType: FacebookReactionType {
        FacebookReactionType(rawValue: reactionTypeRaw) ?? .geminiAuto
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Đã chọn \(selectedSpaces.count)/\(facebookSpaces.count) không gian Facebook")
                        .font(.subheadline.bold())
                    Spacer()
                    Button("Tất cả") {
                        selectedIDs = Set(facebookSpaces.map(\.id))
                    }
                    .disabled(coordinator.isRunning)
                    Button("Bỏ chọn") {
                        selectedIDs.removeAll()
                    }
                    .disabled(coordinator.isRunning)
                }

                if facebookSpaces.isEmpty {
                    Text("Chưa có không gian Facebook nào. Hãy tạo không gian và lấy Token/Cookie trước.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(facebookSpaces) { space in
                        let summary = VaultMetadataIndex.get(space.id)
                        Button {
                            guard !coordinator.isRunning else { return }
                            if selectedIDs.contains(space.id) {
                                selectedIDs.remove(space.id)
                            } else {
                                selectedIDs.insert(space.id)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selectedIDs.contains(space.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedIDs.contains(space.id) ? Color.blue : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(space.name).foregroundStyle(.primary).font(.subheadline.bold())
                                    if summary.hasToken || summary.hasCookies {
                                        Text("Sẵn sàng • Đã có Cookie & Token (\(summary.tokenPrefix))")
                                            .font(.caption2).foregroundStyle(.green)
                                    } else {
                                        Text("Dùng Cookie từ WebView hoặc cần lấy Token")
                                            .font(.caption2).foregroundStyle(.orange)
                                    }
                                }
                                Spacer()
                            }
                        }
                        .disabled(coordinator.isRunning)
                    }
                }

                if selectedSpaces.count > 1 {
                    Picker("Chế độ đa không gian", selection: $executionOrder) {
                        ForEach(MultiSpaceExecutionOrder.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .disabled(coordinator.isRunning)
                }
            } header: {
                Text("1. Chọn 1 hoặc nhiều không gian (Dùng chung Cookie & Token đã lưu)")
            } footer: {
                Text("Tự động dùng luôn Cookie & Access Token đã lưu của từng không gian mà không cần đăng nhập lại.")
            }

            Section("2. Cảm xúc & Bình luận AI Gemini") {
                Toggle("Tự động thả cảm xúc (Reaction)", isOn: $useReaction)
                    .disabled(coordinator.isRunning)

                if useReaction {
                    Picker("Loại cảm xúc", selection: $reactionTypeRaw) {
                        ForEach(FacebookReactionType.allCases) { item in
                            Text(item.label).tag(item.rawValue)
                        }
                    }
                    .disabled(coordinator.isRunning)
                }

                Toggle("Tự động bình luận bằng Gemini AI", isOn: $useComment)
                    .disabled(coordinator.isRunning)

                if useComment || reactionType == .geminiAuto {
                    SecureField("Gemini API Key (AIza...)", text: $geminiApiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(coordinator.isRunning)
                        .onChange(of: geminiApiKey) { _, newValue in
                            SecureGeminiStore.saveKey(newValue)
                        }

                    Picker("Model Gemini", selection: $geminiModel) {
                        ForEach(discoveredModels, id: \.self) { m in
                            Text(GeminiCommentService.modelLabel(m)).tag(m)
                        }
                    }
                    .disabled(coordinator.isRunning)

                    Button {
                        Task { await refreshModelsFromAPIKey() }
                    } label: {
                        Label("Tự dò danh sách Model từ API Key", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                    }
                    .disabled(coordinator.isRunning || geminiApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Yêu cầu phong cách bình luận cho Gemini:")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("Phong cách bình luận...", text: $geminiStylePrompt, axis: .vertical)
                            .lineLimit(2...4)
                            .font(.caption)
                            .disabled(coordinator.isRunning)
                    }
                }
            }

            Section {
                Toggle(isOn: $safeModeEnabled) {
                    Label("SafeMode ngẫu nhiên hóa thời gian chờ", systemImage: "shield.lefthalf.filled.badge.checkmark")
                        .fontWeight(.semibold)
                }
                .disabled(coordinator.isRunning)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Nghỉ ngẫu nhiên giữa các bài viết (giây):")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text("Từ (s):")
                            .font(.caption)
                        TextField("Min giây", text: $minPostDelayText)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder)
                            .disabled(coordinator.isRunning)
                        Text("Đến (s):")
                            .font(.caption)
                        TextField("Max giây", text: $maxPostDelayText)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder)
                            .disabled(coordinator.isRunning)
                    }
                }

                if useReaction && useComment {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Nghỉ ngẫu nhiên giữa React & Comment (giây):")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Text("Từ (s):")
                                .font(.caption)
                            TextField("Min giây", text: $minActionGapText)
                                .keyboardType(.decimalPad)
                                .textFieldStyle(.roundedBorder)
                                .disabled(coordinator.isRunning)
                            Text("Đến (s):")
                                .font(.caption)
                            TextField("Max giây", text: $maxActionGapText)
                                .keyboardType(.decimalPad)
                                .textFieldStyle(.roundedBorder)
                                .disabled(coordinator.isRunning)
                        }
                    }
                }

                HStack {
                    Text("Số bài tối đa mỗi đợt (0 = không giới hạn):")
                        .font(.caption)
                    Spacer()
                    TextField("10", text: $maxPostsText)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .disabled(coordinator.isRunning)
                }

                Toggle("Lặp liên tục các đợt lấy News Feed mới", isOn: $continuousLoop)
                    .disabled(coordinator.isRunning)

                if continuousLoop {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Nghỉ ngẫu nhiên giữa các đợt quét (giây):")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Text("Từ (s):")
                                .font(.caption)
                            TextField("Min giây", text: $minCycleDelayText)
                                .keyboardType(.decimalPad)
                                .textFieldStyle(.roundedBorder)
                                .disabled(coordinator.isRunning)
                            Text("Đến (s):")
                                .font(.caption)
                            TextField("Max giây", text: $maxCycleDelayText)
                                .keyboardType(.decimalPad)
                                .textFieldStyle(.roundedBorder)
                                .disabled(coordinator.isRunning)
                        }
                    }
                }
            } header: {
                Text("3. SafeMode bảo vệ tài khoản")
            } footer: {
                Text("Mỗi lần chờ sẽ sinh ngẫu nhiên một giá trị thực (kèm độ lệch mili-giây) nằm trong khoảng Từ [Min] đến [Max] giây bạn nhập, không giới hạn trần tối đa.")
            }

            Section {
                if coordinator.isRunning {
                    Button(role: .destructive) {
                        coordinator.stopAll()
                    } label: {
                        Label("Dừng toàn bộ tiến trình đang chạy", systemImage: "stop.circle.fill")
                            .fontWeight(.bold)
                    }
                } else {
                    Button {
                        startExecution()
                    } label: {
                        Label("Bắt đầu chạy (\(selectedSpaces.count) không gian)", systemImage: "play.circle.fill")
                            .fontWeight(.bold)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .disabled(selectedSpaces.isEmpty || (!useReaction && !useComment))
                }
            }

            if !coordinator.states.isEmpty {
                Section("Tiến độ từng không gian") {
                    ForEach(selectedSpaces) { space in
                        if let st = coordinator.states[space.id] {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(st.name).font(.subheadline.bold())
                                    Spacer()
                                    if st.isRunning {
                                        ProgressView().controlSize(.small)
                                    }
                                    Text("❤️ \(st.reactSuccessCount) • 💬 \(st.commentSuccessCount)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Text(st.statusText)
                                    .font(.caption)
                                    .foregroundStyle(st.isRunning ? Color.blue : Color.secondary)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            }

            if !coordinator.logs.isEmpty {
                Section("Nhật ký tương tác & Bình luận AI (\(coordinator.logs.count))") {
                    ForEach(coordinator.logs.prefix(30)) { log in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(log.spaceName)
                                    .font(.caption.bold())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.15), in: Capsule())
                                Text("→ \(log.postAuthor)")
                                    .font(.caption.bold())
                                Spacer()
                                Text(log.timestamp, style: .time)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if !log.postSnippet.isEmpty {
                                Text("Bài viết: \"\(log.postSnippet.prefix(90))\"")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Text("• Cảm xúc: \(log.reactionSummary)")
                                .font(.caption2)
                            Text("• Bình luận AI: \(log.commentSummary)")
                                .font(.caption2)
                                .foregroundStyle(log.isError ? Color.red : Color.green)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
        .navigationTitle("Auto Tương tác AI")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if geminiApiKey.isEmpty {
                geminiApiKey = SecureGeminiStore.readKey()
            }
            if selectedIDs.isEmpty {
                if let pre = preselectedSpace {
                    selectedIDs = [pre.id]
                } else {
                    selectedIDs = Set(facebookSpaces.map(\.id))
                }
            }
        }
        .alert("Thông báo", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK") { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    @MainActor
    private func refreshModelsFromAPIKey() async {
        let fetched = await GeminiCommentService.discoverAvailableModels(apiKey: geminiApiKey)
        if fetched.isEmpty {
            alertMessage = "Không lấy được danh sách model từ API Key này. Vui lòng kiểm tra lại Gemini API Key."
        } else {
            var list = ["auto"]
            for m in fetched where !list.contains(m) {
                list.append(m)
            }
            discoveredModels = list
            geminiModel = "auto"
            alertMessage = "Đã tìm thấy \(fetched.count) model khả dụng (ưu tiên: \(fetched.first ?? ""))."
        }
    }

    private func startExecution() {
        // Chỉ cần Gemini API Key khi: bình luận AI hoặc reaction Gemini tự chọn
        let needsGemini = useComment || reactionType == .geminiAuto
        if needsGemini && geminiApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            alertMessage = "Vui lòng nhập Gemini API Key để phân tích bài viết và tự sinh bình luận."
            AppLogger.shared.warning("AutoInteract", "Bắt đầu bị từ chối — thiếu Gemini API Key (cần cho comment/geminiAuto reaction)")
            return
        }
        SecureGeminiStore.saveKey(geminiApiKey)

        let minPost = Double(minPostDelayText.replacingOccurrences(of: ",", with: ".")) ?? 5
        let maxPost = Double(maxPostDelayText.replacingOccurrences(of: ",", with: ".")) ?? 25
        let minGap = Double(minActionGapText.replacingOccurrences(of: ",", with: ".")) ?? 2
        let maxGap = Double(maxActionGapText.replacingOccurrences(of: ",", with: ".")) ?? 6
        let minCycle = Double(minCycleDelayText.replacingOccurrences(of: ",", with: ".")) ?? 180
        let maxCycle = Double(maxCycleDelayText.replacingOccurrences(of: ",", with: ".")) ?? 420
        let maxPosts = Int(maxPostsText) ?? 10

        AppLogger.shared.info("AutoInteract", "▶️ Bắt đầu chạy — \(selectedSpaces.count) không gian | React: \(useReaction ? reactionType.rawValue : "Tắt") | Cmt: \(useComment ? "Bật" : "Tắt") | SafeMode: \(safeModeEnabled ? "Bật" : "Tắt")")

        coordinator.start(
            spaces: selectedSpaces,
            executionOrder: executionOrder,
            useReaction: useReaction,
            reactionType: reactionType,
            useComment: useComment,
            geminiApiKey: geminiApiKey,
            geminiModel: geminiModel,
            geminiStylePrompt: geminiStylePrompt,
            safeModeEnabled: safeModeEnabled,
            minPostDelay: minPost,
            maxPostDelay: maxPost,
            minActionGap: minGap,
            maxActionGap: maxGap,
            continuousLoop: continuousLoop,
            minCycleDelay: minCycle,
            maxCycleDelay: maxCycle,
            maxPostsPerRound: maxPosts
        )
    }
}
