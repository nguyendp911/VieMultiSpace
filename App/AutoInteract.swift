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
}

enum GeminiCommentService {
    static let availableModels = [
        "gemini-2.5-flash",
        "gemini-2.0-flash",
        "gemini-1.5-flash",
        "gemini-1.5-pro"
    ]

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
        let chosenModel = model.isEmpty ? "gemini-2.5-flash" : model
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(chosenModel):generateContent?key=\(cleanKey)") else {
            throw SpaceLoginError.apiError("URL Gemini API không hợp lệ.")
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

        Yêu cầu bắt buộc:
        1. Trả về ĐÚNG định dạng JSON hợp lệ với 2 trường:
           {"reaction": "LIKE|LOVE|CARE|HAHA|WOW|SAD", "comment": "nội dung bình luận"}
        2. Trường "comment" phải bám sát nội dung bài viết, tự nhiên, tuyệt đối KHÔNG dùng câu mẫu chung chung kiểu spam, KHÔNG lặp lại nguyên văn bài viết, KHÔNG giải thích gì thêm ngoài JSON.
        """

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
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResp = response as? HTTPURLResponse, httpResp.statusCode != 200 {
            let errBody = String(data: data, encoding: .utf8) ?? "HTTP \(httpResp.statusCode)"
            throw SpaceLoginError.apiError("Gemini API lỗi (\(httpResp.statusCode)): \(errBody.prefix(160))")
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = root["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let rawText = parts.first?["text"] as? String else {
            throw SpaceLoginError.apiError("Gemini không trả về nội dung hợp lệ.")
        }

        return parseGeminiOutput(rawText)
    }

    private static func parseGeminiOutput(_ rawText: String) -> GeminiAnalysisResult {
        let cleaned = rawText
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let jsonData = cleaned.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            let comment = (obj["comment"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let reactionRaw = (obj["reaction"] as? String)?.uppercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? "LIKE"
            let reaction = FacebookReactionType(rawValue: reactionRaw) ?? .like
            if !comment.isEmpty {
                return GeminiAnalysisResult(comment: comment, suggestedReaction: reaction)
            }
        }

        let fallbackComment = cleaned
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' \n\t"))
        return GeminiAnalysisResult(
            comment: fallbackComment,
            suggestedReaction: .like
        )
    }
}

// MARK: - Facebook GraphQL Auto Reaction & Comment Client (Ported from 1758035539-Test.py)

final class FacebookGraphQLAutoClient {
    let spaceId: UUID
    let cookieString: String
    let accessToken: String
    private(set) var tokens: FacebookWebSessionTokens?

    private let baseHeaders: [String: String]

    init(spaceId: UUID, cookieString: String, accessToken: String = "") {
        self.spaceId = spaceId
        self.cookieString = cookieString
        self.accessToken = accessToken
        self.baseHeaders = [
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36",
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

        guard let url = URL(string: "https://www.facebook.com") else {
            throw SpaceLoginError.apiError("URL Facebook không hợp lệ.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (k, v) in baseHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "dpr")
        request.setValue("1920", forHTTPHeaderField: "viewport-width")
        request.setValue("1", forHTTPHeaderField: "upgrade-insecure-requests")
        request.setValue("none", forHTTPHeaderField: "sec-fetch-site")
        request.setValue("navigate", forHTTPHeaderField: "sec-fetch-mode")
        request.setValue("?1", forHTTPHeaderField: "sec-fetch-user")
        request.setValue("document", forHTTPHeaderField: "sec-fetch-dest")
        request.setValue("u=0, i", forHTTPHeaderField: "priority")

        let (data, _) = try await URLSession.shared.data(for: request)
        let html = String(data: data, encoding: .utf8) ?? ""

        let jazoest = Self.firstMatch(pattern: #"jazoest=(\d+)"#, in: html) ?? "25400"
        let lsdToken = Self.firstMatch(pattern: #""token":"([^"]+)"},323\]"#, in: html)
            ?? Self.firstMatch(pattern: #""LSD",\[\],\{"token":"([^"]+)""#, in: html)
            ?? ""
        guard let dtsgToken = Self.firstMatch(pattern: #""dtsg":\{"token":"([^"]+)""#, in: html)
                ?? Self.firstMatch(pattern: #""DTSGInitialData",\[\],\{"token":"([^"]+)""#, in: html),
              !dtsgToken.isEmpty else {
            throw SpaceLoginError.apiError("Không lấy được fb_dtsg từ Cookie (Cookie có thể đã hết hạn hoặc bị checkpoint).")
        }

        return FacebookWebSessionTokens(
            userId: userId,
            jazoest: jazoest,
            lsdToken: lsdToken,
            dtsgToken: dtsgToken,
            updatedAt: Date()
        )
    }

    func getNewsFeedPosts() async throws -> [FeedPostItem] {
        let tok: FacebookWebSessionTokens
        if let existing = tokens {
            tok = existing
        } else {
            tok = try await prepareTokens()
        }

        let variables: [String: Any] = [
            "RELAY_INCREMENTAL_DELIVERY": true,
            "clientQueryId": UUID().uuidString.lowercased(),
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

        let variablesJSON = Self.jsonString(from: variables)
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
            "variables": variablesJSON,
            "server_timestamps": "true",
            "doc_id": "24488967877354300"
        ]

        var request = URLRequest(url: URL(string: "https://www.facebook.com/api/graphql/")!)
        request.httpMethod = "POST"
        for (k, v) in baseHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.setValue("CometNewsFeedPaginationQuery", forHTTPHeaderField: "x-fb-friendly-name")
        request.setValue("359341", forHTTPHeaderField: "x-asbd-id")
        request.setValue(tok.lsdToken, forHTTPHeaderField: "x-fb-lsd")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        request.setValue("https://www.facebook.com", forHTTPHeaderField: "origin")
        request.setValue("same-origin", forHTTPHeaderField: "sec-fetch-site")
        request.setValue("cors", forHTTPHeaderField: "sec-fetch-mode")
        request.setValue("empty", forHTTPHeaderField: "sec-fetch-dest")
        request.setValue("https://www.facebook.com", forHTTPHeaderField: "referer")
        request.setValue("u=1, i", forHTTPHeaderField: "priority")
        request.httpBody = Self.formEncode(payload)

        let (data, _) = try await URLSession.shared.data(for: request)
        let responseText = String(data: data, encoding: .utf8) ?? ""
        var posts = extractPostItems(from: responseText)

        // Enrich post text via Graph API if Access Token is available and postText is empty
        if !accessToken.isEmpty {
            for idx in posts.indices where posts[idx].postText.isEmpty {
                if let fetchedText = await fetchPostMessageViaGraphAPI(postId: posts[idx].postId, userId: posts[idx].userId) {
                    posts[idx].postText = fetchedText
                }
            }
        }
        return posts
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
            let (data, _) = try await URLSession.shared.data(from: url)
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

                if let postId = dict["post_id"] as? String, !postId.isEmpty {
                    if !seenIds.contains(postId) {
                        seenIds.insert(postId)
                        var userName = "Người dùng Facebook"
                        var authorId = ""
                        if let actors = dict["actors"] as? [[String: Any]] {
                            for actor in actors {
                                if (actor["__typename"] as? String) == "User" || actor["name"] != nil {
                                    userName = (actor["name"] as? String)?.replacingOccurrences(of: "\\", with: "") ?? userName
                                    authorId = (actor["id"] as? String) ?? ""
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
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) else {
                continue
            }
            searchRecursive(json)
        }

        return posts
    }

    func reactToPost(postId: String, reaction: FacebookReactionType) async -> (success: Bool, message: String) {
        guard let tok = tokens else {
            return (false, "Chưa khởi tạo token phiên web.")
        }
        let concrete = reaction.resolveConcrete()
        let feedbackId = Data("feedback:\(postId)".utf8).base64EncodedString()

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
        for (k, v) in baseHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }
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
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let dataObj = json["data"] as? [String: Any],
                   let reactObj = dataObj["feedback_react"] as? [String: Any],
                   reactObj["feedback"] != nil {
                    return (true, "Đã thả cảm xúc \(concrete.rawValue)")
                }
                if let errors = json["errors"] as? [[String: Any]],
                   let desc = errors.first?["description"] as? String {
                    return (false, desc)
                }
            }
            return (false, "Thả cảm xúc \(concrete.rawValue) thất bại")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    func commentOnPost(postId: String, commentText: String) async -> (success: Bool, message: String) {
        guard let tok = tokens else {
            return (false, "Chưa khởi tạo token phiên web.")
        }
        let feedbackId = Data("feedback:\(postId)".utf8).base64EncodedString()
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
        for (k, v) in baseHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }
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
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let dataObj = json["data"] as? [String: Any],
                   let commentCreate = dataObj["comment_create"] as? [String: Any] {
                    if let edge = commentCreate["feedback_comment_edge"] as? [String: Any],
                       let node = edge["node"] as? [String: Any],
                       node["id"] != nil {
                        return (true, "Đã bình luận: \"\(commentText.prefix(45))\"")
                    }
                    if let feedback = commentCreate["feedback"] as? [String: Any],
                       let notice = feedback["comments_disabled_notice_renderer"] as? [String: Any],
                       (notice["__typename"] as? String) == "GeneralCommentDisableNotice" {
                        return (true, "Bài viết tắt bình luận UI nhưng API đã xử lý")
                    }
                }
                if let errors = json["errors"] as? [[String: Any]],
                   let desc = errors.first?["description"] as? String {
                    return (false, desc)
                }
            }
            return (false, "Comment thất bại")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    private static func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private static func jsonString(from dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
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
            // Ngẫu nhiên thực sự với độ lệch thập phân để tránh hành vi máy móc
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
            accessToken: credentials.token
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
                states[space.id]?.statusText = "Lỗi News Feed: \(error.localizedDescription)"
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
                            appendLog(
                                spaceName: space.name,
                                postAuthor: post.userName,
                                postId: post.postId,
                                postSnippet: post.postText,
                                reactionSummary: "-",
                                commentSummary: "Lỗi Gemini: \(error.localizedDescription)",
                                isError: true
                            )
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
                            commentMsg = "Không tạo được bình luận từ Gemini"
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
    @AppStorage("vie.auto.geminiModel") private var geminiModel = "gemini-2.5-flash"
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
                                    .foregroundStyle(selectedIDs.contains(space.id) ? .blue : .secondary)
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
                        ForEach(GeminiCommentService.availableModels, id: \.self) { m in
                            Text(m).tag(m)
                        }
                    }
                    .disabled(coordinator.isRunning)

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
                    Label("Bật SafeMode (Ngẫu nhiên hóa toàn bộ thời gian chờ)", systemImage: "shield.lefthalf.filled.badge.checkmark")
                        .fontWeight(.semibold)
                }
                .disabled(coordinator.isRunning)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Thời gian nghỉ ngẫu nhiên giữa các bài viết (giây — không giới hạn):")
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
                        Text("Nghỉ ngẫu nhiên giữa Thả cảm xúc và Bình luận (giây — không giới hạn):")
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
                        Text("Nghỉ ngẫu nhiên giữa các đợt quét News Feed (giây — không giới hạn):")
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
                Text("3. Chế độ an toàn SafeMode (Tùy chỉnh giây không giới hạn)")
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
                    }
                    .disabled(selectedSpaces.isEmpty || (!useReaction && !useComment))
                }
            }

            if !coordinator.states.isEmpty {
                Section("Trạng thái từng không gian") {
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
                                    .foregroundStyle(st.isRunning ? .blue : .secondary)
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
                                .foregroundStyle(log.isError ? .red : .green)
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

    private func startExecution() {
        if (useComment || reactionType == .geminiAuto) &&
            geminiApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            alertMessage = "Vui lòng nhập Gemini API Key để phân tích bài viết và tự sinh bình luận."
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
