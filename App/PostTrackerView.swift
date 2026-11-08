import SwiftUI
import Foundation
import UIKit

// MARK: - Models for Tracked Posts & Comments

struct TrackedCommentItem: Identifiable, Codable, Hashable {
    var id: String // Facebook Comment ID
    var authorName: String
    var authorId: String
    var message: String
    var createdTime: String
    var likeCount: Int
    var replyCount: Int
    var isReplied: Bool
    var lastReplyText: String?
    var repliedAt: Date?
}

struct TrackedPostItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var postId: String
    var feedbackId: String
    var postUrl: String
    var spaceId: UUID
    var spaceName: String
    var authorName: String
    var caption: String
    var createdAt: Date = Date()
    var lastSyncedAt: Date? = nil

    // Engagement Statistics
    var reactionCount: Int = 0
    var commentCount: Int = 0
    var shareCount: Int = 0
    var reactionBreakdown: [String: Int] = [:]

    // AI Auto-Reply Configuration
    var isAIAutoReplySelected: Bool = false
    var aiCustomTone: String = ""

    // Cached Comments & Replied Tracking
    var comments: [TrackedCommentItem] = []
    var repliedCommentIds: Set<String> = []

    var unrepliedCommentsCount: Int {
        comments.filter { !isCommentHandled($0) }.count
    }

    func isCommentHandled(_ c: TrackedCommentItem) -> Bool {
        c.isReplied || repliedCommentIds.contains(c.id)
    }
}

// MARK: - Tracked Post Manager (Storage + Sync + AI Auto-Reply Engine)

@MainActor
final class TrackedPostManager: ObservableObject {
    static let shared = TrackedPostManager()

    @Published var posts: [TrackedPostItem] = []
    @Published var isSyncingAll: Bool = false
    @Published var isRunningAIReply: Bool = false
    @Published var syncingPostIds: Set<UUID> = []
    @Published var aiReplyingPostIds: Set<UUID> = []
    @Published var statusBanner: String = ""
    @Published var autoMonitorEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(autoMonitorEnabled, forKey: autoMonitorKey)
            configureAutoMonitorTimer()
        }
    }

    private let storageKey = "vie.smartpost.tracked_posts.v1"
    private let autoMonitorKey = "vie.smartpost.auto_monitor_ai.v1"
    private var monitorTimer: Timer?

    init() {
        loadPosts()
        self.autoMonitorEnabled = UserDefaults.standard.bool(forKey: autoMonitorKey)
        if autoMonitorEnabled {
            configureAutoMonitorTimer()
        }
    }

    func loadPosts() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([TrackedPostItem].self, from: data) else {
            return
        }
        self.posts = decoded
    }

    func savePosts() {
        if let data = try? JSONEncoder().encode(posts) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    // MARK: - Register / Add Tracked Post

    func registerPublishedPost(
        spaceId: UUID,
        spaceName: String,
        postId: String,
        postUrl: String?,
        caption: String,
        enableAIAutoReply: Bool = false
    ) {
        let cleanId = postId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty, cleanId != "Thành công", cleanId != "Đã đăng thành công" else { return }

        let rawUrl = postUrl ?? "https://www.facebook.com/posts/\(cleanId)"
        let kind = FacebookTargetPostResolver.detectKind(from: rawUrl)
        let resolvedUrl = FacebookTargetPostResolver.buildCanonicalURL(id: cleanId, kind: kind, originalURL: rawUrl)
        let feedbackId = Data("feedback:\(cleanId)".utf8).base64EncodedString()

        if let existingIdx = posts.firstIndex(where: { $0.postId == cleanId && $0.spaceId == spaceId }) {
            posts[existingIdx].postUrl = resolvedUrl
            if !caption.isEmpty && posts[existingIdx].caption.isEmpty {
                posts[existingIdx].caption = caption
            }
            if enableAIAutoReply {
                posts[existingIdx].isAIAutoReplySelected = true
            }
            savePosts()
            return
        }

        let item = TrackedPostItem(
            postId: cleanId,
            feedbackId: feedbackId,
            postUrl: resolvedUrl,
            spaceId: spaceId,
            spaceName: spaceName,
            authorName: spaceName,
            caption: caption,
            createdAt: Date(),
            isAIAutoReplySelected: enableAIAutoReply
        )
        posts.insert(item, at: 0)
        savePosts()
        AppLogger.shared.info("PostTracker", "Đã thêm bài viết vào danh sách theo dõi: ID \(cleanId) (\(spaceName))")
    }

    func addPostByURLOrID(
        rawInput: String,
        space: Space,
        categoryHint: TargetCategoryHint = .auto,
        customCaption: String = "",
        enableAI: Bool = false
    ) async throws -> TrackedPostItem {
        let creds = await Self.resolveCookieAndToken(for: space)

        // Bước 1: Chuyển đổi URL chia sẻ / rút gọn giống hệt tính năng MultiSpace
        var effectiveInput = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        var canonicalFromShare: String? = nil
        if let converted = await FacebookTargetPostResolver.resolveShareURLToCanonical(
            input: effectiveInput,
            cookieString: creds.cookie,
            proxy: space.proxy
        ) {
            effectiveInput = converted.canonicalURL
            canonicalFromShare = converted.canonicalURL
        }

        // Bước 2: Giải mã chi tiết Post ID, Feedback ID, Tác giả & Nội dung
        var resolved = try await FacebookTargetPostResolver.resolve(
            input: effectiveInput,
            cookieString: creds.cookie,
            accessToken: creds.token,
            proxy: space.proxy,
            userAgent: space.fingerprint?.userAgent
        )
        if categoryHint != .auto {
            resolved.targetKind = categoryHint.rawValue
        }

        let finalCaption = !customCaption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? customCaption
            : resolved.postText
        let finalUrl = canonicalFromShare
            ?? resolved.canonicalURL?.absoluteString
            ?? FacebookTargetPostResolver.buildCanonicalURL(
                id: resolved.postId,
                kind: resolved.targetKind,
                originalURL: effectiveInput
            )

        if let existingIdx = posts.firstIndex(where: { $0.postId == resolved.postId && $0.spaceId == space.id }) {
            posts[existingIdx].postUrl = finalUrl
            if !finalCaption.isEmpty {
                posts[existingIdx].caption = finalCaption
            }
            if enableAI {
                posts[existingIdx].isAIAutoReplySelected = true
            }
            savePosts()
            await syncSinglePost(id: posts[existingIdx].id, space: space)
            return posts[existingIdx]
        }

        let newItem = TrackedPostItem(
            postId: resolved.postId,
            feedbackId: resolved.feedbackId,
            postUrl: finalUrl,
            spaceId: space.id,
            spaceName: space.name,
            authorName: resolved.authorName.isEmpty ? space.name : resolved.authorName,
            caption: finalCaption,
            createdAt: Date(),
            isAIAutoReplySelected: enableAI
        )
        posts.insert(newItem, at: 0)
        savePosts()

        await syncSinglePost(id: newItem.id, space: space)
        return posts.first(where: { $0.id == newItem.id }) ?? newItem
    }

    func removePost(_ item: TrackedPostItem) {
        posts.removeAll { $0.id == item.id }
        savePosts()
    }

    func toggleAIReply(for postId: UUID) {
        guard let idx = posts.firstIndex(where: { $0.id == postId }) else { return }
        posts[idx].isAIAutoReplySelected.toggle()
        savePosts()
    }

    func setAllAIReply(_ enabled: Bool, for spaceFilter: UUID? = nil) {
        for idx in posts.indices {
            if let filter = spaceFilter, posts[idx].spaceId != filter { continue }
            posts[idx].isAIAutoReplySelected = enabled
        }
        savePosts()
    }

    // MARK: - Fetch Account's Published Timeline Posts

    func importAccountPublishedPosts(for spaces: [Space], limitPerAccount: Int = 10) async -> Int {
        isSyncingAll = true
        defer { isSyncingAll = false }

        var addedCount = 0
        for space in spaces {
            statusBanner = "Đang quét bài đã đăng của \(space.name)..."
            let creds = await Self.resolveCookieAndToken(for: space)
            guard !creds.token.isEmpty || !creds.cookie.isEmpty else { continue }

            let fetched = await PostTrackingAPIClient.fetchAccountPublishedPosts(
                space: space,
                cookieString: creds.cookie,
                accessToken: creds.token,
                userId: creds.uid,
                limit: limitPerAccount
            )

            for p in fetched {
                if let existingIdx = posts.firstIndex(where: { $0.postId == p.postId && $0.spaceId == space.id }) {
                    posts[existingIdx].reactionCount = max(posts[existingIdx].reactionCount, p.reactionCount)
                    posts[existingIdx].commentCount = max(posts[existingIdx].commentCount, p.commentCount)
                    posts[existingIdx].shareCount = max(posts[existingIdx].shareCount, p.shareCount)
                    if posts[existingIdx].caption.isEmpty && !p.caption.isEmpty {
                        posts[existingIdx].caption = p.caption
                    }
                    posts[existingIdx].lastSyncedAt = Date()
                } else {
                    posts.insert(p, at: 0)
                    addedCount += 1
                }
            }
            savePosts()
        }
        statusBanner = addedCount > 0
            ? "✅ Đã nạp thêm \(addedCount) bài viết từ tài khoản!"
            : "Đã cập nhật danh sách bài viết của tài khoản."
        return addedCount
    }

    // MARK: - Sync Engagement Stats & Comments

    func convertPostURL(id: UUID, space: Space?) async {
        guard let idx = posts.firstIndex(where: { $0.id == id }) else { return }
        let post = posts[idx]
        let creds = await Self.resolveCookieAndToken(forId: post.spaceId, fallbackSpace: space)
        let inputToConvert = post.postUrl.isEmpty ? post.postId : post.postUrl
        if let converted = await FacebookTargetPostResolver.resolveShareURLToCanonical(
            input: inputToConvert,
            cookieString: creds.cookie,
            proxy: space?.proxy
        ) {
            if let currentIndex = posts.firstIndex(where: { $0.id == id }) {
                posts[currentIndex].postUrl = converted.canonicalURL
                if !converted.postId.isEmpty {
                    posts[currentIndex].postId = converted.postId
                    posts[currentIndex].feedbackId = Data("feedback:\(converted.postId)".utf8).base64EncodedString()
                }
                savePosts()
                statusBanner = "✅ Đã chuyển đổi URL chuẩn: \(converted.canonicalURL)"
            }
        } else {
            let kind = FacebookTargetPostResolver.detectKind(from: post.postUrl)
            let fallbackCanonical = FacebookTargetPostResolver.buildCanonicalURL(
                id: post.postId,
                kind: kind,
                originalURL: post.postUrl
            )
            if let currentIndex = posts.firstIndex(where: { $0.id == id }) {
                posts[currentIndex].postUrl = fallbackCanonical
                savePosts()
                statusBanner = "✅ Đã chuẩn hóa URL: \(fallbackCanonical)"
            }
        }
    }

    func syncSinglePost(id: UUID, space: Space?) async {
        guard let idx = posts.firstIndex(where: { $0.id == id }) else { return }
        syncingPostIds.insert(id)
        defer { syncingPostIds.remove(id) }

        var post = posts[idx]
        let creds = await Self.resolveCookieAndToken(forId: post.spaceId, fallbackSpace: space)
        guard !creds.cookie.isEmpty || !creds.token.isEmpty else {
            statusBanner = "⚠️ \(post.spaceName) chưa có Token/Cookie để đồng bộ."
            return
        }

        // Tự động chuyển đổi URL sang dạng chuẩn (giống MultiSpace) nếu URL là link rút gọn hoặc chưa chuẩn
        let lowerUrl = post.postUrl.lowercased()
        let needsCanonicalize = lowerUrl.contains("/share/") || lowerUrl.contains("pfbid") || lowerUrl.contains("fb.watch") || (!lowerUrl.contains("/posts/") && !lowerUrl.contains("/reel/") && !lowerUrl.contains("/videos/"))
        if needsCanonicalize {
            if let converted = await FacebookTargetPostResolver.resolveShareURLToCanonical(
                input: post.postUrl.isEmpty ? post.postId : post.postUrl,
                cookieString: creds.cookie,
                proxy: space?.proxy
            ) {
                post.postUrl = converted.canonicalURL
                if !converted.postId.isEmpty {
                    post.postId = converted.postId
                    post.feedbackId = Data("feedback:\(converted.postId)".utf8).base64EncodedString()
                }
            } else {
                let kind = FacebookTargetPostResolver.detectKind(from: post.postUrl)
                post.postUrl = FacebookTargetPostResolver.buildCanonicalURL(
                    id: post.postId,
                    kind: kind,
                    originalURL: post.postUrl
                )
            }
            if let cur = posts.firstIndex(where: { $0.id == id }) {
                posts[cur].postUrl = post.postUrl
                posts[cur].postId = post.postId
                posts[cur].feedbackId = post.feedbackId
            }
        }

        let details = await PostTrackingAPIClient.fetchPostEngagementAndComments(
            postId: post.postId,
            postUrl: post.postUrl,
            feedbackId: post.feedbackId,
            ownerUserId: creds.uid,
            spaceId: post.spaceId,
            cookieString: creds.cookie,
            accessToken: creds.token,
            proxy: space?.proxy
        )

        guard let currentIndex = posts.firstIndex(where: { $0.id == id }) else { return }
        posts[currentIndex].reactionCount = details.reactionCount
        posts[currentIndex].reactionBreakdown = details.reactionBreakdown
        posts[currentIndex].commentCount = max(details.commentCount, details.comments.count)
        posts[currentIndex].shareCount = details.shareCount
        if !details.caption.isEmpty && posts[currentIndex].caption.isEmpty {
            posts[currentIndex].caption = details.caption
        }

        // Merge comments while preserving local reply history (chống double/duplicate comment)
        var existingMap: [String: TrackedCommentItem] = [:]
        for c in posts[currentIndex].comments {
            existingMap[c.id] = c
            let canon = PostTrackingAPIClient.canonicalCommentId(c.id)
            existingMap[canon] = c
        }
        let repliedSet = posts[currentIndex].repliedCommentIds

        var seenCanonIds = Set<String>()
        var seenSignatures = Set<String>()
        var mergedComments: [TrackedCommentItem] = []

        for var c in details.comments {
            let canonId = PostTrackingAPIClient.canonicalCommentId(c.id)
            let sig = "\(c.authorName.lowercased().trimmingCharacters(in: .whitespaces))|\(c.message.trimmingCharacters(in: .whitespacesAndNewlines))"
            if seenCanonIds.contains(c.id) || seenCanonIds.contains(canonId) || (!c.message.isEmpty && seenSignatures.contains(sig)) {
                continue // Bỏ qua nếu đã có bình luận trùng lặp
            }
            seenCanonIds.insert(c.id)
            seenCanonIds.insert(canonId)
            if !c.message.isEmpty { seenSignatures.insert(sig) }

            if let old = existingMap[c.id] ?? existingMap[canonId] {
                if old.isReplied {
                    c.isReplied = true
                    c.lastReplyText = old.lastReplyText ?? c.lastReplyText
                    c.repliedAt = old.repliedAt
                }
            }
            if repliedSet.contains(c.id) || repliedSet.contains(canonId) {
                c.isReplied = true
            }
            mergedComments.append(c)
        }

        if !mergedComments.isEmpty {
            posts[currentIndex].comments = mergedComments
        }
        posts[currentIndex].lastSyncedAt = Date()
        savePosts()
    }

    func syncAllPosts(spaces: [Space]) async {
        guard !isSyncingAll else { return }
        isSyncingAll = true
        defer { isSyncingAll = false }

        let spaceMap = Dictionary(uniqueKeysWithValues: spaces.map { ($0.id, $0) })
        for (i, post) in posts.enumerated() {
            statusBanner = "Đang cập nhật thống kê (\(i + 1)/\(posts.count)): \(post.spaceName)..."
            await syncSinglePost(id: post.id, space: spaceMap[post.spaceId])
        }
        statusBanner = "✅ Đã cập nhật thống kê tương tác cho \(posts.count) bài viết!"
    }

    // MARK: - Direct Reply to Post or Comment

    func sendDirectReply(
        postItemId: UUID,
        targetCommentId: String?,
        replyText: String,
        actingSpace: Space?
    ) async -> (success: Bool, message: String) {
        let cleanText = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else {
            return (false, "Nội dung trả lời không được để trống.")
        }
        guard let idx = posts.firstIndex(where: { $0.id == postItemId }) else {
            return (false, "Không tìm thấy bài viết.")
        }

        let post = posts[idx]
        let targetSpaceId = actingSpace?.id ?? post.spaceId
        let creds = await Self.resolveCookieAndToken(forId: targetSpaceId, fallbackSpace: actingSpace)

        guard !creds.cookie.isEmpty || !creds.token.isEmpty else {
            return (false, "Tài khoản chưa có Cookie hoặc Access Token.")
        }

        let res = await PostTrackingAPIClient.replyToPostOrComment(
            postId: post.postId,
            postFeedbackId: post.feedbackId,
            commentId: targetCommentId,
            replyText: cleanText,
            spaceId: targetSpaceId,
            cookieString: creds.cookie,
            accessToken: creds.token,
            proxy: actingSpace?.proxy,
            userAgent: actingSpace?.fingerprint?.userAgent
        )

        if res.success, let currentIndex = posts.firstIndex(where: { $0.id == postItemId }) {
            if let cid = targetCommentId {
                posts[currentIndex].repliedCommentIds.insert(cid)
                if let cIdx = posts[currentIndex].comments.firstIndex(where: { $0.id == cid }) {
                    posts[currentIndex].comments[cIdx].isReplied = true
                    posts[currentIndex].comments[cIdx].lastReplyText = cleanText
                    posts[currentIndex].comments[cIdx].repliedAt = Date()
                    posts[currentIndex].comments[cIdx].replyCount += 1
                }
            } else {
                posts[currentIndex].commentCount += 1
            }
            savePosts()
        }

        return res
    }

    // MARK: - AI Auto-Reply Execution (Single Post, Selected Comments, or All Ticked Posts)

    func runAIReplyForPost(
        postItemId: UUID,
        specificCommentIds: Set<String>? = nil,
        replyDirectlyToPostIfNoComments: Bool = false,
        actingSpace: Space?,
        geminiApiKey: String,
        geminiModel: String,
        globalStylePrompt: String
    ) async -> (repliedCount: Int, errorMessage: String?) {
        guard let idx = posts.firstIndex(where: { $0.id == postItemId }) else {
            return (0, "Không tìm thấy bài viết.")
        }

        aiReplyingPostIds.insert(postItemId)
        defer { aiReplyingPostIds.remove(postItemId) }

        // Đồng bộ bình luận mới nhất trước khi trả lời
        await syncSinglePost(id: postItemId, space: actingSpace)

        guard let freshIdx = posts.firstIndex(where: { $0.id == postItemId }) else {
            return (0, nil)
        }
        let post = posts[freshIdx]
        let effectiveStyle = !post.aiCustomTone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? post.aiCustomTone
            : globalStylePrompt

        // Xác định danh sách bình luận cần AI trả lời
        let targetComments: [TrackedCommentItem]
        if let explicitIds = specificCommentIds, !explicitIds.isEmpty {
            targetComments = post.comments.filter { explicitIds.contains($0.id) }
        } else {
            // Mặc định lọc các bình luận chưa trả lời và không phải do chính chủ bài viết tự cmt
            let creds = await Self.resolveCookieAndToken(forId: post.spaceId, fallbackSpace: actingSpace)
            targetComments = post.comments.filter { c in
                !post.isCommentHandled(c) && (creds.uid.isEmpty || c.authorId != creds.uid)
            }
        }

        var successCount = 0
        var lastError: String? = nil
        var previousReplies: [String] = []

        if targetComments.isEmpty && replyDirectlyToPostIfNoComments {
            statusBanner = "✨ AI đang tạo bình luận tương tác cho bài viết..."
            do {
                let generated = try await PostTrackingAPIClient.generateAIReply(
                    postCaption: post.caption,
                    commentAuthor: nil,
                    commentText: nil,
                    previousReplies: [],
                    apiKey: geminiApiKey,
                    model: geminiModel,
                    stylePrompt: effectiveStyle
                )
                let sendRes = await sendDirectReply(
                    postItemId: postItemId,
                    targetCommentId: nil,
                    replyText: generated,
                    actingSpace: actingSpace
                )
                if sendRes.success {
                    successCount += 1
                    statusBanner = "✅ AI đã bình luận vào bài viết!"
                } else {
                    lastError = sendRes.message
                }
            } catch {
                lastError = error.localizedDescription
            }
            return (successCount, lastError)
        }

        for (cIdx, comment) in targetComments.enumerated() {
            statusBanner = "🤖 AI đang trả lời (\(cIdx + 1)/\(targetComments.count)): \(comment.authorName)..."
            do {
                let aiReply = try await PostTrackingAPIClient.generateAIReply(
                    postCaption: post.caption,
                    commentAuthor: comment.authorName,
                    commentText: comment.message,
                    previousReplies: previousReplies,
                    apiKey: geminiApiKey,
                    model: geminiModel,
                    stylePrompt: effectiveStyle
                )
                previousReplies.append(aiReply)

                let sendRes = await sendDirectReply(
                    postItemId: postItemId,
                    targetCommentId: comment.id,
                    replyText: aiReply,
                    actingSpace: actingSpace
                )
                if sendRes.success {
                    successCount += 1
                } else {
                    lastError = sendRes.message
                }

                if cIdx < targetComments.count - 1 {
                    let waitNs = UInt64(Double.random(in: 1.8...3.8) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: waitNs)
                }
            } catch {
                lastError = error.localizedDescription
            }
        }

        if successCount > 0 {
            statusBanner = "✅ AI đã tự động trả lời \(successCount) bình luận!"
        } else if let err = lastError {
            statusBanner = "⚠️ Lỗi AI trả lời: \(err)"
        } else {
            statusBanner = "Không có bình luận mới nào chưa trả lời."
        }
        return (successCount, lastError)
    }

    func runAIReplyForAllSelectedPosts(
        spaces: [Space],
        geminiApiKey: String,
        geminiModel: String,
        globalStylePrompt: String
    ) async -> Int {
        guard !isRunningAIReply else { return 0 }
        isRunningAIReply = true
        defer { isRunningAIReply = false }

        let selectedPosts = posts.filter(\.isAIAutoReplySelected)
        guard !selectedPosts.isEmpty else {
            statusBanner = "⚠️ Hãy tick chọn ít nhất 1 bài viết (nút AI Auto) để chạy!"
            return 0
        }

        let spaceMap = Dictionary(uniqueKeysWithValues: spaces.map { ($0.id, $0) })
        var totalReplied = 0

        for (idx, post) in selectedPosts.enumerated() {
            statusBanner = "🤖 Đang quét & trả lời AI bài \(idx + 1)/\(selectedPosts.count) (\(post.spaceName))..."
            let res = await runAIReplyForPost(
                postItemId: post.id,
                specificCommentIds: nil,
                replyDirectlyToPostIfNoComments: false,
                actingSpace: spaceMap[post.spaceId],
                geminiApiKey: geminiApiKey,
                geminiModel: geminiModel,
                globalStylePrompt: globalStylePrompt
            )
            totalReplied += res.repliedCount
        }

        statusBanner = totalReplied > 0
            ? "🎉 Hoàn tất! AI đã trả lời tổng cộng \(totalReplied) bình luận mới."
            : "✅ Đã kiểm tra \(selectedPosts.count) bài đã tick: Chưa có bình luận mới cần trả lời."
        return totalReplied
    }

    // MARK: - Background Periodic Auto-Monitor

    private func configureAutoMonitorTimer() {
        monitorTimer?.invalidate()
        monitorTimer = nil
        guard autoMonitorEnabled else { return }

        monitorTimer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.autoMonitorEnabled, !self.isRunningAIReply else { return }
                let apiKey = SecureGeminiStore.readKey()
                guard !apiKey.isEmpty else { return }
                let model = UserDefaults.standard.string(forKey: "vie.auto.geminiModelV2") ?? "auto"
                let style = UserDefaults.standard.string(forKey: "vie.tracker.aiStylePrompt")
                    ?? "Lịch sự, thân thiện như chủ bài viết đang phản hồi người đọc, ngắn gọn 1-2 câu tự nhiên."
                _ = await self.runAIReplyForAllSelectedPosts(
                    spaces: [],
                    geminiApiKey: apiKey,
                    geminiModel: model,
                    globalStylePrompt: style
                )
            }
        }
    }

    // MARK: - Credential Helper

    static func resolveCookieAndToken(for space: Space) async -> (cookie: String, token: String, uid: String) {
        await resolveCookieAndToken(forId: space.id, fallbackSpace: space)
    }

    static func resolveCookieAndToken(forId spaceId: UUID, fallbackSpace: Space? = nil) async -> (cookie: String, token: String, uid: String) {
        if let vault = try? SecureLoginStore.readTokenVault(spaceId) {
            var cookieStr = vault.cookieString
            if cookieStr.isEmpty, !vault.cookies.isEmpty {
                cookieStr = FacebookAppTokens.formatCookieString(vault.cookies)
            }
            if cookieStr.isEmpty {
                let webCookies = await WebCookieBridge.extractFacebookCookies(from: spaceId)
                cookieStr = FacebookAppTokens.formatCookieString(webCookies)
            }
            // Ưu tiên resolve token tốt nhất từ mọi nguồn trong vault (originalToken, FB_ANDROID, ADS_MANAGER_WEB, PAGES_MANAGER...)
            var tok = SmartPostAPIClient.resolveBestAccessToken(from: vault) ?? ""
            if tok.isEmpty {
                tok = !vault.originalToken.isEmpty
                    ? vault.originalToken
                    : (vault.convertedTokens.values.first(where: { $0.accessToken.hasPrefix("EAA") && $0.accessToken.count >= 20 })?.accessToken ?? "")
            }
            let uid = !vault.uid.isEmpty
                ? vault.uid
                : (FacebookTargetPostResolver.firstMatch(pattern: #"c_user=(\d+)"#, in: cookieStr) ?? "")
            return (cookieStr, tok, uid)
        } else {
            let webCookies = await WebCookieBridge.extractFacebookCookies(from: spaceId)
            let cookieStr = FacebookAppTokens.formatCookieString(webCookies)
            let uid = FacebookTargetPostResolver.firstMatch(pattern: #"c_user=(\d+)"#, in: cookieStr) ?? ""
            var tok = ""
            if !cookieStr.isEmpty {
                if let extracted = await FacebookAPILoginClient.extractTokenFromCookieString(cookieStr), !extracted.isEmpty {
                    tok = extracted
                }
            }
            return (cookieStr, tok, uid)
        }
    }
}

// MARK: - Post Tracking & Comment Reply API Client

enum PostTrackingAPIClient {
    struct PostEngagementSnapshot {
        var caption: String = ""
        var reactionCount: Int = 0
        var commentCount: Int = 0
        var shareCount: Int = 0
        var comments: [TrackedCommentItem] = []
        var reactionBreakdown: [String: Int] = [:]
        var reactors: [(id: String, name: String, type: String)] = []
    }

    /// Quét danh sách các bài viết mà tài khoản đã đăng trên dòng thời gian
    static func fetchAccountPublishedPosts(
        space: Space,
        cookieString: String,
        accessToken: String,
        userId: String,
        limit: Int = 10
    ) async -> [TrackedPostItem] {
        var results: [TrackedPostItem] = []

        if !accessToken.isEmpty {
            let targetUid = userId.isEmpty ? "me" : userId
            let endpoints = [
                ("https://graph.facebook.com/\(targetUid)/posts", "id,message,story,created_time,permalink_url,shares,reactions.summary(true),likes.summary(true),comments.limit(20).summary(true){id,message,created_time,from,like_count,comment_count}"),
                ("https://graph.facebook.com/\(targetUid)/feed", "id,message,story,created_time,permalink_url,shares,likes.summary(true),comments.limit(20).summary(true){id,message,created_time,from,like_count,comment_count}"),
                ("https://graph.facebook.com/me/posts", "id,message,story,created_time,permalink_url,likes.summary(true),comments.limit(20).summary(true){id,message,created_time,from,like_count,comment_count}")
            ]

            let isoFormatter = ISO8601DateFormatter()

            for (ep, fields) in endpoints {
                guard var comps = URLComponents(string: ep) else { continue }
                comps.queryItems = [
                    URLQueryItem(name: "fields", value: fields),
                    URLQueryItem(name: "limit", value: "\(limit)"),
                    URLQueryItem(name: "access_token", value: accessToken)
                ]
                guard let url = comps.url else { continue }
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let dataArr = json["data"] as? [[String: Any]], !dataArr.isEmpty else {
                        continue
                    }

                    for item in dataArr {
                        let rawId = item["id"] as? String ?? ""
                        let cleanPostId = rawId.contains("_")
                            ? String(rawId.split(separator: "_").last ?? Substring(rawId))
                            : rawId
                        guard !cleanPostId.isEmpty else { continue }

                        let msg = (item["message"] as? String) ?? (item["story"] as? String) ?? ""
                        let rawPermalink = (item["permalink_url"] as? String) ?? "https://www.facebook.com/posts/\(cleanPostId)"
                        let kind = FacebookTargetPostResolver.detectKind(from: rawPermalink)
                        let canonicalPermalink = FacebookTargetPostResolver.buildCanonicalURL(
                            id: cleanPostId,
                            kind: kind,
                            originalURL: rawPermalink
                        )
                        let createdStr = item["created_time"] as? String ?? ""
                        let createdDate = isoFormatter.date(from: createdStr) ?? Date()

                        let reactCount = ((item["reactions"] as? [String: Any])?["summary"] as? [String: Any])?["total_count"] as? Int
                            ?? ((item["likes"] as? [String: Any])?["summary"] as? [String: Any])?["total_count"] as? Int
                            ?? 0
                        let shareCount = (item["shares"] as? [String: Any])?["count"] as? Int ?? 0

                        let commentsRoot = item["comments"] as? [String: Any]
                        let parsedComments = parseGraphComments(from: commentsRoot, ownerUserId: userId)
                        let cmtCount = (commentsRoot?["summary"] as? [String: Any])?["total_count"] as? Int ?? parsedComments.count

                        let tracked = TrackedPostItem(
                            postId: cleanPostId,
                            feedbackId: Data("feedback:\(cleanPostId)".utf8).base64EncodedString(),
                            postUrl: canonicalPermalink,
                            spaceId: space.id,
                            spaceName: space.name,
                            authorName: space.name,
                            caption: msg,
                            createdAt: createdDate,
                            lastSyncedAt: Date(),
                            reactionCount: reactCount,
                            commentCount: cmtCount,
                            shareCount: shareCount,
                            comments: parsedComments
                        )
                        results.append(tracked)
                    }
                    if !results.isEmpty { break }
                } catch {
                    continue
                }
            }
        }

        // Fallback quét trang cá nhân bằng Cookie nếu Graph API không trả về bài viết
        if results.isEmpty, !cookieString.isEmpty {
            let targetUid = userId.isEmpty ? (FacebookTargetPostResolver.firstMatch(pattern: #"c_user=(\d+)"#, in: cookieString) ?? "") : userId
            if !targetUid.isEmpty, let profileURL = URL(string: "https://www.facebook.com/profile.php?id=\(targetUid)") {
                let session = makeCookieSession(cookieString: cookieString, proxy: space.proxy)
                var req = URLRequest(url: profileURL)
                req.httpMethod = "GET"
                req.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
                req.setValue(cookieString, forHTTPHeaderField: "Cookie")
                if let (data, _) = try? await session.data(for: req),
                   let html = String(data: data, encoding: .utf8), !html.isEmpty {
                    var seen = Set<String>()
                    let pat = #""(?:post_id|top_level_post_id|story_fbid)"\s*:\s*"?(\d{8,25})"?"#
                    if let regex = try? NSRegularExpression(pattern: pat) {
                        let ns = html as NSString
                        for m in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges > 1 {
                            let pid = ns.substring(with: m.range(at: 1))
                            if !seen.contains(pid), results.count < limit {
                                seen.insert(pid)
                                results.append(
                                    TrackedPostItem(
                                        postId: pid,
                                        feedbackId: Data("feedback:\(pid)".utf8).base64EncodedString(),
                                        postUrl: "https://www.facebook.com/posts/\(pid)",
                                        spaceId: space.id,
                                        spaceName: space.name,
                                        authorName: space.name,
                                        caption: ""
                                    )
                                )
                            }
                        }
                    }
                }
            }
        }

        return results
    }

    static let cometReactions: [(name: String, id: String)] = [
        ("Like", "1635855486666999"),
        ("Love", "1678524932434102"),
        ("Haha", "115940658764963"),
        ("Sad", "908563459236466"),
        ("Care", "613557422527858"),
        ("Wow", "478547315650144"),
        ("Angry", "444813342392137")
    ]

    /// Lấy chính xác 100% số lượng từng Reaction & danh sách người thả cảm xúc theo 1748401675-getuidnamereactionpostfacebookcachetoken.py
    static func fetchExactReactionsViaCometUFI(
        postId: String,
        postUrl: String,
        cookieString: String,
        proxy: SpaceProxy? = nil
    ) async -> (totalCount: Int, breakdown: [String: Int], reactors: [(id: String, name: String, type: String)])? {
        let cleanPostUrl = postUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        var targetUrlStr = cleanPostUrl
        if targetUrlStr.isEmpty {
            targetUrlStr = "https://www.facebook.com/\(postId)"
        }

        let session = makeCookieSession(cookieString: cookieString, proxy: proxy)

        // 1. Trích xuất pfbid từ URL nếu có
        var extractedFeedbackTargetId: String? = nil
        let urlParts = targetUrlStr.components(separatedBy: "/")
        for part in urlParts {
            if part.hasPrefix("pfbid") {
                extractedFeedbackTargetId = part
                break
            }
        }

        var lsdToken = ""
        var jazoestToken = ""

        // 2. Tải HTML bài viết để lấy feedback_target_id, lsd, jazoest
        if let targetUrl = URL(string: targetUrlStr) {
            var req = URLRequest(url: targetUrl)
            req.timeoutInterval = 12
            req.httpMethod = "GET"
            req.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
            req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8", forHTTPHeaderField: "Accept")
            req.setValue("vi-VN,vi;q=0.9,en-US;q=0.8", forHTTPHeaderField: "Accept-Language")
            if !cookieString.isEmpty {
                req.setValue(cookieString, forHTTPHeaderField: "Cookie")
            }

            if let (data, _) = try? await session.data(for: req),
               let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {

                lsdToken = FacebookTargetPostResolver.firstMatch(pattern: #"\"LSD\"[^{]*\{\"token\":\"([^\"]+)\""#, in: html) ?? ""
                jazoestToken = FacebookTargetPostResolver.firstMatch(pattern: #"\"jazoest\":\{\"name\":\"jazoest\",\"value\":\"([^\"]+)\"\}"#, in: html) ?? ""

                if extractedFeedbackTargetId == nil {
                    let patterns = [
                        #"\"feedback_target_id\":\"([^\"]+)\""#,
                        #"\"feedbackTargetID\":\"([^\"]+)\""#,
                        #"\"target_id\":\"([^\"]+)\""#,
                        #"\"post_id\":\"([^\"]+)\""#,
                        #"feedbackTargetID[\"\s]*:[\"\s]*\"([^\"]+)\""#,
                        #"feedback_target_id[\"\s]*:[\"\s]*\"([^\"]+)\""#,
                        #"\"feedback\":[^}]*\"target_id\":\"([^\"]+)\""#,
                        #"pfbid[A-Za-z0-9_-]+"#,
                        #"\"videoID\":\"(\d+)\""#,
                        #"\"video_id\":\"(\d+)\""#,
                        #"\"legacyID\":\"(\d+)\""#
                    ]
                    for pat in patterns {
                        if let match = FacebookTargetPostResolver.firstMatch(pattern: pat, in: html), match.count > 5 {
                            extractedFeedbackTargetId = match
                            break
                        }
                    }
                }
            }
        }

        let targetId = extractedFeedbackTargetId ?? postId
        guard !targetId.isEmpty, targetId.count > 4 else { return nil }

        let lsd = !lsdToken.isEmpty ? lsdToken : "AV..."
        let jazoest = !jazoestToken.isEmpty ? jazoestToken : "2955"

        var breakdown: [String: Int] = [:]
        var reactorsList: [(id: String, name: String, type: String)] = []
        var totalReactionSum = 0

        guard let gqlUrl = URL(string: "https://www.facebook.com/api/graphql/") else { return nil }

        for reaction in cometReactions {
            var req = URLRequest(url: gqlUrl)
            req.timeoutInterval = 10
            req.httpMethod = "POST"
            req.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
            req.setValue("CometUFIReactionIconTooltipContentQuery", forHTTPHeaderField: "x-fb-friendly-name")
            req.setValue("359341", forHTTPHeaderField: "x-asbd-id")
            req.setValue(lsd, forHTTPHeaderField: "x-fb-lsd")
            req.setValue("https://www.facebook.com", forHTTPHeaderField: "origin")
            req.setValue("same-origin", forHTTPHeaderField: "sec-fetch-site")
            req.setValue("cors", forHTTPHeaderField: "sec-fetch-mode")
            req.setValue("empty", forHTTPHeaderField: "sec-fetch-dest")
            req.setValue("u=1, i", forHTTPHeaderField: "priority")
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            if !cookieString.isEmpty {
                req.setValue(cookieString, forHTTPHeaderField: "Cookie")
            }

            let bodyPairs: [(String, String)] = [
                ("av", "0"),
                ("__aaid", "0"),
                ("__user", "0"),
                ("__a", "1"),
                ("__req", "n"),
                ("__hs", "20234.HYP:comet_loggedout_pkg.2.1...0"),
                ("dpr", "1"),
                ("__ccg", "GOOD"),
                ("__rev", "1023183597"),
                ("__s", "jmehfj:ejwx64:a718cb"),
                ("__hsi", "7508579432954383764"),
                ("__comet_req", "15"),
                ("lsd", lsd),
                ("jazoest", jazoest),
                ("__spin_r", "1023183597"),
                ("__spin_b", "trunk"),
                ("__spin_t", "1748227382"),
                ("__crn", "comet.fbweb.CometSinglePostDialogRoute"),
                ("fb_api_caller_class", "RelayModern"),
                ("fb_api_req_friendly_name", "CometUFIReactionIconTooltipContentQuery"),
                ("variables", "{\"feedbackTargetID\":\"\(targetId)\",\"reactionID\":\"\(reaction.id)\"}"),
                ("server_timestamps", "true"),
                ("doc_id", "9516958201714477")
            ]

            let allowed = CharacterSet.alphanumerics
            let bodyStr = bodyPairs.map { k, v in
                let ek = k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k
                let ev = v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
                return "\(ek)=\(ev)"
            }.joined(separator: "&")
            req.httpBody = Data(bodyStr.utf8)

            if let (data, resp) = try? await session.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let feedback = (json["data"] as? [String: Any])?["feedback"] as? [String: Any],
               let reactors = feedback["reactors"] as? [String: Any] {

                let count = reactors["count"] as? Int ?? 0
                if count > 0 {
                    breakdown[reaction.name] = count
                    totalReactionSum += count
                }
                if let nodes = reactors["nodes"] as? [[String: Any]] {
                    for node in nodes {
                        let uid = (node["id"] as? String) ?? ""
                        let name = (node["name"] as? String) ?? ""
                        if !uid.isEmpty {
                            reactorsList.append((id: uid, name: name, type: reaction.name))
                        }
                    }
                }
            }
        }

        if totalReactionSum > 0 || !breakdown.isEmpty {
            return (totalCount: totalReactionSum, breakdown: breakdown, reactors: reactorsList)
        }
        return nil
    }

    /// Lấy thống kê tương tác (Reaction, Comment, Share) và danh sách bình luận chi tiết của 1 bài viết (Đa tầng: Comet UFI + Graph API + Comet Relay JSON + GraphQL Feedback)
    static func fetchPostEngagementAndComments(
        postId: String,
        postUrl: String = "",
        feedbackId: String,
        ownerUserId: String,
        spaceId: UUID? = nil,
        cookieString: String,
        accessToken: String,
        proxy: SpaceProxy? = nil
    ) async -> PostEngagementSnapshot {
        var finalSnap = PostEngagementSnapshot()

        // Tầng 0: Lấy chính xác Reaction theo CometUFI (chuẩn 1748401675-getuidnamereactionpostfacebookcachetoken.py)
        if let exactReactions = await fetchExactReactionsViaCometUFI(
            postId: postId,
            postUrl: postUrl,
            cookieString: cookieString,
            proxy: proxy
        ) {
            finalSnap.reactionCount = exactReactions.totalCount
            finalSnap.reactionBreakdown = exactReactions.breakdown
            finalSnap.reactors = exactReactions.reactors
        }

        // Tầng 1: Truy vấn qua Graph API (thử cả ownerUserId_postId và postId trực tiếp + truy vấn nhánh con /comments & /reactions)
        if !accessToken.isEmpty {
            let candidateIds: [String] = {
                if postId.contains("_") || ownerUserId.isEmpty {
                    return [postId]
                }
                return ["\(ownerUserId)_\(postId)", postId]
            }()

            for cid in candidateIds {
                if let graphSnap = await fetchViaGraphAPI(queryPostId: cid, ownerUserId: ownerUserId, accessToken: accessToken) {
                    mergeSnapshots(into: &finalSnap, from: graphSnap)
                    if finalSnap.reactionCount > 0 || finalSnap.commentCount > 0 || !finalSnap.comments.isEmpty {
                        break
                    }
                }
            }
        }

        // Tầng 2: Quét trực tiếp từ trang bài viết (Comet Relay JSON + HTML Regex) bằng Cookie phiên để lấy đủ Reaction, Comment, Share thực tế
        if !cookieString.isEmpty {
            if let webSnap = await fetchViaWebScrape(
                postId: postId,
                postUrl: postUrl,
                feedbackId: feedbackId,
                ownerUserId: ownerUserId,
                cookieString: cookieString,
                proxy: proxy
            ) {
                mergeSnapshots(into: &finalSnap, from: webSnap)
            }

            // Tầng 3: Nếu vẫn chưa lấy được số liệu hoặc danh sách comment, gọi trực tiếp Comet GraphQL Feedback API
            if finalSnap.reactionCount == 0 && finalSnap.commentCount == 0 && finalSnap.comments.isEmpty {
                let effectiveFbId = feedbackId.isEmpty
                    ? Data("feedback:\(postId)".utf8).base64EncodedString()
                    : feedbackId
                if let gqlSnap = await fetchViaCometGraphQLFeedback(
                    postId: postId,
                    feedbackId: effectiveFbId,
                    ownerUserId: ownerUserId,
                    spaceId: spaceId ?? UUID(),
                    cookieString: cookieString,
                    proxy: proxy
                ) {
                    mergeSnapshots(into: &finalSnap, from: gqlSnap)
                }
            }
        }

        finalSnap.commentCount = max(finalSnap.commentCount, finalSnap.comments.count)
        return finalSnap
    }

    /// Rút trích ID chuẩn (loại bỏ prefix post_id_ nếu có) để chống duplicate comment
    static func canonicalCommentId(_ id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = trimmed.components(separatedBy: "_").last, !last.isEmpty {
            return last
        }
        return trimmed
    }

    private static func mergeSnapshots(into target: inout PostEngagementSnapshot, from source: PostEngagementSnapshot) {
        target.reactionCount = max(target.reactionCount, source.reactionCount)
        target.commentCount = max(target.commentCount, source.commentCount)
        target.shareCount = max(target.shareCount, source.shareCount)
        if !source.reactionBreakdown.isEmpty {
            target.reactionBreakdown = source.reactionBreakdown
        }
        if !source.reactors.isEmpty {
            target.reactors = source.reactors
        }
        if target.caption.isEmpty && !source.caption.isEmpty {
            target.caption = source.caption
        }
        if !source.comments.isEmpty {
            var seenIds = Set<String>()
            var seenSignatures = Set<String>()
            for c in target.comments {
                seenIds.insert(c.id)
                seenIds.insert(canonicalCommentId(c.id))
                let sig = "\(c.authorName.lowercased().trimmingCharacters(in: .whitespaces))|\(c.message.trimmingCharacters(in: .whitespacesAndNewlines))"
                if !c.message.isEmpty { seenSignatures.insert(sig) }
            }
            for c in source.comments {
                let canonId = canonicalCommentId(c.id)
                let sig = "\(c.authorName.lowercased().trimmingCharacters(in: .whitespaces))|\(c.message.trimmingCharacters(in: .whitespacesAndNewlines))"
                if seenIds.contains(c.id) || seenIds.contains(canonId) || (!c.message.isEmpty && seenSignatures.contains(sig)) {
                    continue
                }
                seenIds.insert(c.id)
                seenIds.insert(canonId)
                if !c.message.isEmpty { seenSignatures.insert(sig) }
                target.comments.append(c)
            }
        }
    }

    private static func makeCookieSession(cookieString: String, proxy: SpaceProxy?) -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 18
        if !cookieString.isEmpty {
            let storage = HTTPCookieStorage()
            for c in FacebookGraphQLAutoClient.parseCookies(from: cookieString) {
                storage.setCookie(c)
            }
            cfg.httpCookieStorage = storage
            cfg.httpCookieAcceptPolicy = .always
            cfg.httpShouldSetCookies = true
        }
        if let proxy, proxy.isEnabled {
            cfg.proxyConfigurations = [proxy.toNetworkProxyConfiguration()]
        }
        return URLSession(configuration: cfg)
    }

    private static func fetchViaGraphAPI(
        queryPostId: String,
        ownerUserId: String,
        accessToken: String
    ) async -> PostEngagementSnapshot? {
        // Thử lần lượt bộ fields đầy đủ và bộ fields an toàn (dành cho Reel/Photo/Video không hỗ trợ trường shares)
        let fieldSets = [
            "id,message,story,shares,reactions.summary(true),likes.summary(true),comments.limit(50).summary(true){id,message,created_time,from,like_count,comment_count,comments.limit(10){id,message,from,created_time}}",
            "id,message,description,story,likes.summary(true),comments.limit(50).summary(true){id,message,created_time,from,like_count,comment_count,comments.limit(10){id,message,from,created_time}}",
            "id,likes.summary(true),comments.summary(true)"
        ]

        var snap = PostEngagementSnapshot()
        var gotAnyResponse = false

        for fields in fieldSets {
            var comps = URLComponents(string: "https://graph.facebook.com/\(queryPostId)")
            comps?.queryItems = [
                URLQueryItem(name: "fields", value: fields),
                URLQueryItem(name: "access_token", value: accessToken)
            ]
            guard let url = comps?.url else { continue }

            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      json["error"] == nil else {
                    continue
                }
                gotAnyResponse = true

                let msg = (json["message"] as? String)
                    ?? (json["description"] as? String)
                    ?? (json["story"] as? String)
                    ?? ""
                if snap.caption.isEmpty && !msg.isEmpty {
                    snap.caption = msg
                }

                let rCount = ((json["reactions"] as? [String: Any])?["summary"] as? [String: Any])?["total_count"] as? Int
                    ?? ((json["likes"] as? [String: Any])?["summary"] as? [String: Any])?["total_count"] as? Int
                    ?? 0
                snap.reactionCount = max(snap.reactionCount, rCount)

                let sCount = (json["shares"] as? [String: Any])?["count"] as? Int ?? 0
                snap.shareCount = max(snap.shareCount, sCount)

                if let commentsRoot = json["comments"] as? [String: Any] {
                    let parsed = parseGraphComments(from: commentsRoot, ownerUserId: ownerUserId)
                    if !parsed.isEmpty && snap.comments.isEmpty {
                        snap.comments = parsed
                    }
                    let cCount = (commentsRoot["summary"] as? [String: Any])?["total_count"] as? Int ?? parsed.count
                    snap.commentCount = max(snap.commentCount, cCount)
                }

                if snap.reactionCount > 0 || snap.commentCount > 0 || !snap.comments.isEmpty {
                    break
                }
            } catch {
                continue
            }
        }

        // Bổ sung: Truy vấn trực tiếp nhánh /{queryPostId}/comments và /{queryPostId}/reactions nếu chưa có
        if snap.comments.isEmpty {
            var cComps = URLComponents(string: "https://graph.facebook.com/\(queryPostId)/comments")
            cComps?.queryItems = [
                URLQueryItem(name: "summary", value: "true"),
                URLQueryItem(name: "filter", value: "toplevel"),
                URLQueryItem(name: "limit", value: "50"),
                URLQueryItem(name: "fields", value: "id,message,created_time,from,like_count,comment_count,comments.limit(10){id,message,from,created_time}"),
                URLQueryItem(name: "access_token", value: accessToken)
            ]
            if let cUrl = cComps?.url,
               let (cData, cResp) = try? await URLSession.shared.data(from: cUrl),
               (cResp as? HTTPURLResponse)?.statusCode == 200,
               let cJson = try? JSONSerialization.jsonObject(with: cData) as? [String: Any],
               cJson["error"] == nil {
                gotAnyResponse = true
                let parsed = parseGraphComments(from: cJson, ownerUserId: ownerUserId)
                if !parsed.isEmpty {
                    snap.comments = parsed
                }
                let total = (cJson["summary"] as? [String: Any])?["total_count"] as? Int ?? parsed.count
                snap.commentCount = max(snap.commentCount, total)
            }
        }

        if snap.reactionCount == 0 {
            var rComps = URLComponents(string: "https://graph.facebook.com/\(queryPostId)/reactions")
            rComps?.queryItems = [
                URLQueryItem(name: "summary", value: "true"),
                URLQueryItem(name: "limit", value: "1"),
                URLQueryItem(name: "access_token", value: accessToken)
            ]
            if let rUrl = rComps?.url,
               let (rData, rResp) = try? await URLSession.shared.data(from: rUrl),
               (rResp as? HTTPURLResponse)?.statusCode == 200,
               let rJson = try? JSONSerialization.jsonObject(with: rData) as? [String: Any],
               let total = (rJson["summary"] as? [String: Any])?["total_count"] as? Int {
                gotAnyResponse = true
                snap.reactionCount = max(snap.reactionCount, total)
            }
        }

        return gotAnyResponse ? snap : nil
    }

    private static func parseGraphComments(from commentsRoot: [String: Any]?, ownerUserId: String) -> [TrackedCommentItem] {
        guard let dataArr = commentsRoot?["data"] as? [[String: Any]] else { return [] }
        var items: [TrackedCommentItem] = []

        for c in dataArr {
            guard let cid = c["id"] as? String, !cid.isEmpty else { continue }
            let msg = (c["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let created = c["created_time"] as? String ?? ""
            let fromDict = c["from"] as? [String: Any]
            let authorName = (fromDict?["name"] as? String) ?? "Người dùng Facebook"
            let authorId = (fromDict?["id"] as? String) ?? ""
            let likeCount = c["like_count"] as? Int ?? 0
            let replyCount = c["comment_count"] as? Int ?? 0

            // Kiểm tra xem chủ tài khoản đã trả lời trong thread con của bình luận này chưa
            var alreadyReplied = false
            var lastReplyMsg: String? = nil
            if let subComments = (c["comments"] as? [String: Any])?["data"] as? [[String: Any]] {
                for sub in subComments {
                    let subFromId = ((sub["from"] as? [String: Any])?["id"] as? String) ?? ""
                    if !ownerUserId.isEmpty && subFromId == ownerUserId {
                        alreadyReplied = true
                        lastReplyMsg = sub["message"] as? String
                    }
                }
            }

            items.append(
                TrackedCommentItem(
                    id: cid,
                    authorName: authorName,
                    authorId: authorId,
                    message: msg,
                    createdTime: formatShortTime(created),
                    likeCount: likeCount,
                    replyCount: replyCount,
                    isReplied: alreadyReplied,
                    lastReplyText: lastReplyMsg,
                    repliedAt: nil
                )
            )
        }
        return items
    }

    private static func parseCompactCount(_ raw: String) -> Int? {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
        guard !cleaned.isEmpty else { return nil }
        if let direct = Int(cleaned.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: "")) {
            return direct
        }
        let mult: Double
        var numPart = cleaned
        if cleaned.hasSuffix("K") || cleaned.hasSuffix("N") {
            mult = 1_000
            numPart = String(cleaned.dropLast())
        } else if cleaned.hasSuffix("TR") {
            mult = 1_000_000
            numPart = String(cleaned.dropLast(2))
        } else if cleaned.hasSuffix("M") {
            mult = 1_000_000
            numPart = String(cleaned.dropLast())
        } else {
            return nil
        }
        numPart = numPart.replacingOccurrences(of: ",", with: ".")
        guard let val = Double(numPart) else { return nil }
        return Int(val * mult)
    }

    private static func maxIntMatch(patterns: [String], in text: String) -> Int {
        var best = 0
        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        for pat in patterns {
            guard let regex = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) else { continue }
            for m in regex.matches(in: text, options: [], range: fullRange) where m.numberOfRanges > 1 {
                let raw = ns.substring(with: m.range(at: 1))
                if let val = Int(raw) ?? parseCompactCount(raw) {
                    best = max(best, val)
                }
            }
        }
        return best
    }

    private static func extractFromRelayObject(
        _ obj: Any,
        ownerUserId: String,
        into snap: inout PostEngagementSnapshot,
        seenCommentIds: inout Set<String>,
        depth: Int = 0
    ) {
        guard depth < 18 else { return }
        if let dict = obj as? [String: Any] {
            // 1. Reaction counts
            if let rc = (dict["reaction_count"] as? [String: Any])?["count"] as? Int {
                snap.reactionCount = max(snap.reactionCount, rc)
            }
            if let rc = (dict["reactors"] as? [String: Any])?["count"] as? Int {
                snap.reactionCount = max(snap.reactionCount, rc)
            }
            if let rc = (dict["unified_reactors"] as? [String: Any])?["count"] as? Int {
                snap.reactionCount = max(snap.reactionCount, rc)
            }
            if let rc = (dict["likers"] as? [String: Any])?["count"] as? Int {
                snap.reactionCount = max(snap.reactionCount, rc)
            }
            if let i18nR = dict["i18n_reaction_count"] as? String, let parsed = parseCompactCount(i18nR) {
                snap.reactionCount = max(snap.reactionCount, parsed)
            }

            // 2. Comment counts
            if let cc = dict["total_comment_count"] as? Int {
                snap.commentCount = max(snap.commentCount, cc)
            }
            if let cc = (dict["comment_count"] as? [String: Any])?["total_count"] as? Int {
                snap.commentCount = max(snap.commentCount, cc)
            }
            if let cc = ((dict["comment_rendering_instance"] as? [String: Any])?["comments"] as? [String: Any])?["total_count"] as? Int {
                snap.commentCount = max(snap.commentCount, cc)
            }
            if let cc = (dict["top_level_comments"] as? [String: Any])?["total_count"] as? Int
                ?? (dict["top_level_comments"] as? [String: Any])?["count"] as? Int {
                snap.commentCount = max(snap.commentCount, cc)
            }
            if let cc = (dict["comments"] as? [String: Any])?["total_count"] as? Int
                ?? (dict["comments"] as? [String: Any])?["count"] as? Int {
                snap.commentCount = max(snap.commentCount, cc)
            }
            if let i18nC = dict["i18n_comment_count"] as? String, let parsed = parseCompactCount(i18nC) {
                snap.commentCount = max(snap.commentCount, parsed)
            }

            // 3. Share counts
            if let sc = (dict["share_count"] as? [String: Any])?["count"] as? Int {
                snap.shareCount = max(snap.shareCount, sc)
            }
            if let sc = (dict["reshares"] as? [String: Any])?["count"] as? Int {
                snap.shareCount = max(snap.shareCount, sc)
            }
            if let i18nS = dict["i18n_share_count"] as? String, let parsed = parseCompactCount(i18nS) {
                snap.shareCount = max(snap.shareCount, parsed)
            }

            // 4. Caption
            if snap.caption.isEmpty,
               let msgText = (dict["message"] as? [String: Any])?["text"] as? String,
               !msgText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                snap.caption = msgText
            }

            // 5. Individual Comment Node
            let typeName = (dict["__typename"] as? String) ?? ""
            let bodyText = (dict["body"] as? [String: Any])?["text"] as? String
            let authorDict = dict["author"] as? [String: Any]
            if (typeName == "Comment" || bodyText != nil),
               let text = bodyText?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty,
               let authorName = authorDict?["name"] as? String {
                var commentId = (dict["legacy_fbid"] as? String)
                    ?? (dict["legacy_token"] as? String)
                    ?? (dict["id"] as? String)
                    ?? ""
                if let decodedData = Data(base64Encoded: commentId),
                   let decodedStr = String(data: decodedData, encoding: .utf8),
                   decodedStr.lowercased().contains("comment"),
                   let numeric = FacebookTargetPostResolver.firstMatch(pattern: #"(\d{6,25})\s*$"#, in: decodedStr) {
                    commentId = numeric
                }
                if !commentId.isEmpty, !seenCommentIds.contains(commentId) {
                    seenCommentIds.insert(commentId)
                    let authorId = (authorDict?["id"] as? String) ?? ""
                    let createdTs = (dict["created_time"] as? Int) ?? 0
                    let createdStr = createdTs > 0
                        ? Date(timeIntervalSince1970: TimeInterval(createdTs)).formatted(date: .abbreviated, time: .shortened)
                        : "Gần đây"
                    let likes = ((dict["reactors"] as? [String: Any])?["count"] as? Int) ?? 0
                    let replies = ((dict["comment_replies"] as? [String: Any])?["count"] as? Int) ?? 0
                    snap.comments.append(
                        TrackedCommentItem(
                            id: commentId,
                            authorName: authorName,
                            authorId: authorId,
                            message: text,
                            createdTime: createdStr,
                            likeCount: likes,
                            replyCount: replies,
                            isReplied: false,
                            lastReplyText: nil,
                            repliedAt: nil
                        )
                    )
                }
            }

            for (_, v) in dict {
                extractFromRelayObject(v, ownerUserId: ownerUserId, into: &snap, seenCommentIds: &seenCommentIds, depth: depth + 1)
            }
        } else if let arr = obj as? [Any] {
            for item in arr {
                extractFromRelayObject(item, ownerUserId: ownerUserId, into: &snap, seenCommentIds: &seenCommentIds, depth: depth + 1)
            }
        }
    }

    private static func parseHTMLAndRelayPayload(_ html: String, ownerUserId: String) -> PostEngagementSnapshot {
        var snap = PostEngagementSnapshot()
        var seenCommentIds = Set<String>()

        // 1. Duyệt toàn bộ các khối <script type="application/json"> của Facebook Comet
        let scriptPattern = #"<script[^>]*>([\s\S]*?)<\/script>"#
        if let scriptRegex = try? NSRegularExpression(pattern: scriptPattern, options: []) {
            let nsHtml = html as NSString
            let matches = scriptRegex.matches(in: html, range: NSRange(location: 0, length: nsHtml.length))
            for m in matches where m.numberOfRanges > 1 {
                let content = nsHtml.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard content.contains("reaction_count") || content.contains("total_comment_count") || content.contains("comment_rendering_instance") || content.contains("share_count") || content.contains("\"Comment\"") || content.contains("i18n_reaction_count") else {
                    continue
                }
                var cleaned = content
                if cleaned.hasPrefix("for (;;);") {
                    cleaned = String(cleaned.dropFirst(9)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let d = cleaned.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: d) {
                    extractFromRelayObject(json, ownerUserId: ownerUserId, into: &snap, seenCommentIds: &seenCommentIds)
                }
            }
        }

        // 2. Nếu dữ liệu là NDJSON (nhiều dòng JSON từ /api/graphql/)
        for line in html.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("{"),
                  let d = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: d) else { continue }
            extractFromRelayObject(json, ownerUserId: ownerUserId, into: &snap, seenCommentIds: &seenCommentIds)
        }

        // 3. Quét Regex trực tiếp trên toàn bộ HTML để đảm bảo không sót số liệu
        let rMax = maxIntMatch(
            patterns: [
                #""reaction_count"\s*:\s*\{\s*"count"\s*:\s*(\d+)"#,
                #""reactors"\s*:\s*\{\s*"count"\s*:\s*(\d+)"#,
                #""unified_reactors"\s*:\s*\{\s*"count"\s*:\s*(\d+)"#,
                #""likers"\s*:\s*\{\s*"count"\s*:\s*(\d+)"#,
                #""i18n_reaction_count"\s*:\s*"([^"]+)""#
            ],
            in: html
        )
        snap.reactionCount = max(snap.reactionCount, rMax)

        let cMax = maxIntMatch(
            patterns: [
                #""total_comment_count"\s*:\s*(\d+)"#,
                #""comment_count"\s*:\s*\{\s*"total_count"\s*:\s*(\d+)"#,
                #""comment_rendering_instance"\s*:\s*\{\s*"comments"\s*:\s*\{\s*"total_count"\s*:\s*(\d+)"#,
                #""top_level_comments"\s*:\s*\{\s*"(?:total_count|count)"\s*:\s*(\d+)"#,
                #""i18n_comment_count"\s*:\s*"([^"]+)""#
            ],
            in: html
        )
        snap.commentCount = max(snap.commentCount, max(cMax, snap.comments.count))

        let sMax = maxIntMatch(
            patterns: [
                #""share_count"\s*:\s*\{\s*"count"\s*:\s*(\d+)"#,
                #""reshares"\s*:\s*\{\s*"count"\s*:\s*(\d+)"#,
                #""i18n_share_count"\s*:\s*"([^"]+)""#
            ],
            in: html
        )
        snap.shareCount = max(snap.shareCount, sMax)

        if snap.caption.isEmpty,
           let msg = FacebookTargetPostResolver.firstMatch(pattern: #""message":\{"text":"([^"]+)""#, in: html) {
            snap.caption = FacebookTargetPostResolver.decodeJSONEscapes(msg)
        }

        return snap
    }

    private static func fetchViaWebScrape(
        postId: String,
        postUrl: String,
        feedbackId: String,
        ownerUserId: String,
        cookieString: String,
        proxy: SpaceProxy?
    ) async -> PostEngagementSnapshot? {
        let session = makeCookieSession(cookieString: cookieString, proxy: proxy)
        let kind = FacebookTargetPostResolver.detectKind(from: postUrl)
        let canonical = FacebookTargetPostResolver.buildCanonicalURL(id: postId, kind: kind, originalURL: postUrl)

        var candidateURLs: [String] = []
        if !postUrl.isEmpty { candidateURLs.append(postUrl) }
        if !candidateURLs.contains(canonical) { candidateURLs.append(canonical) }
        let directUrl = "https://www.facebook.com/\(postId)"
        if !candidateURLs.contains(directUrl) { candidateURLs.append(directUrl) }

        var combinedSnap = PostEngagementSnapshot()
        var anyLoaded = false

        for urlStr in candidateURLs {
            guard let url = URL(string: urlStr) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue(
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36",
                forHTTPHeaderField: "User-Agent"
            )
            request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.setValue("vi,en-US;q=0.8,en;q=0.6", forHTTPHeaderField: "Accept-Language")
            request.setValue("document", forHTTPHeaderField: "sec-fetch-dest")
            request.setValue("navigate", forHTTPHeaderField: "sec-fetch-mode")
            request.setValue("none", forHTTPHeaderField: "sec-fetch-site")
            request.setValue("?1", forHTTPHeaderField: "sec-fetch-user")
            request.setValue("1", forHTTPHeaderField: "upgrade-insecure-requests")
            request.setValue(cookieString, forHTTPHeaderField: "Cookie")

            do {
                let (data, _) = try await session.data(for: request)
                let html = String(data: data, encoding: .utf8) ?? ""
                guard !html.isEmpty else { continue }
                anyLoaded = true

                let parsed = parseHTMLAndRelayPayload(html, ownerUserId: ownerUserId)
                mergeSnapshots(into: &combinedSnap, from: parsed)

                if combinedSnap.reactionCount > 0 || combinedSnap.commentCount > 0 || !combinedSnap.comments.isEmpty {
                    break
                }
            } catch {
                continue
            }
        }

        return anyLoaded ? combinedSnap : nil
    }

    private static func fetchViaCometGraphQLFeedback(
        postId: String,
        feedbackId: String,
        ownerUserId: String,
        spaceId: UUID,
        cookieString: String,
        proxy: SpaceProxy?
    ) async -> PostEngagementSnapshot? {
        let client = FacebookGraphQLAutoClient(
            spaceId: spaceId,
            cookieString: cookieString,
            accessToken: "",
            proxy: proxy,
            userAgent: nil
        )
        guard let tok = try? await client.prepareTokens() else { return nil }

        let session = makeCookieSession(cookieString: cookieString, proxy: proxy)
        let docIds = [
            "9058824614191395",
            "7259676384135483",
            "8322650087796518"
        ]

        var snap = PostEngagementSnapshot()
        for docId in docIds {
            let variables: [String: Any] = [
                "feedbackTargetID": feedbackId,
                "scale": 1,
                "feedLocation": "PERMALINK"
            ]
            guard let varData = try? JSONSerialization.data(withJSONObject: variables),
                  let varStr = String(data: varData, encoding: .utf8),
                  let gqlURL = URL(string: "https://www.facebook.com/api/graphql/") else { continue }

            var req = URLRequest(url: gqlURL)
            req.httpMethod = "POST"
            req.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.setValue(cookieString, forHTTPHeaderField: "Cookie")
            req.setValue(tok.lsdToken, forHTTPHeaderField: "x-fb-lsd")

            let allowed = CharacterSet.alphanumerics
            let bodyPairs: [(String, String)] = [
                ("av", tok.userId),
                ("__user", tok.userId),
                ("__a", "1"),
                ("fb_dtsg", tok.dtsgToken),
                ("jazoest", tok.jazoest),
                ("lsd", tok.lsdToken),
                ("variables", varStr),
                ("doc_id", docId)
            ]
            let bodyStr = bodyPairs.map { k, v in
                let ek = k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k
                let ev = v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
                return "\(ek)=\(ev)"
            }.joined(separator: "&")
            req.httpBody = Data(bodyStr.utf8)

            if let (data, _) = try? await session.data(for: req),
               let text = String(data: data, encoding: .utf8), !text.isEmpty {
                let parsed = parseHTMLAndRelayPayload(text, ownerUserId: ownerUserId)
                mergeSnapshots(into: &snap, from: parsed)
                if snap.reactionCount > 0 || snap.commentCount > 0 || !snap.comments.isEmpty {
                    return snap
                }
            }
        }
        return nil
    }

    /// Trả lời trực tiếp vào bài viết hoặc trả lời vào 1 bình luận cụ thể (Dual Engine: Graph API + Comet GraphQL)
    static func replyToPostOrComment(
        postId: String,
        postFeedbackId: String,
        commentId: String?,
        replyText: String,
        spaceId: UUID,
        cookieString: String,
        accessToken: String,
        proxy: SpaceProxy?,
        userAgent: String?
    ) async -> (success: Bool, message: String) {
        let cleanPostId = postId.components(separatedBy: "_").last ?? postId
        let targetObjectId = (commentId?.isEmpty == false) ? commentId! : cleanPostId

        // ── 1. Ưu tiên cao nhất: Gửi qua Facebook Graph API chuẩn FB4A Android (đầy đủ OAuth header & fbHeaders) ──
        if !accessToken.isEmpty {
            let res = await SmartPostAPIClient.commentOnPost(
                postId: targetObjectId,
                commentText: replyText,
                accessToken: accessToken
            )
            if res.success {
                return (true, "Đã gửi phản hồi thành công (\(res.message))")
            }

            // Nếu postId gốc khác cleanPostId và commentId rỗng, thử thêm 1 lần với postId gốc
            if commentId == nil && cleanPostId != postId {
                let res2 = await SmartPostAPIClient.commentOnPost(
                    postId: postId,
                    commentText: replyText,
                    accessToken: accessToken
                )
                if res2.success {
                    return (true, "Đã gửi phản hồi thành công (\(res2.message))")
                }
            }
        }

        // ── 2. Fallback sang Comet Web GraphQL thông qua FacebookGraphQLAutoClient ──
        guard !cookieString.isEmpty else {
            return (false, "Không thể gửi: Không gian chưa có Access Token API và chưa có Cookie.")
        }

        let client = FacebookGraphQLAutoClient(
            spaceId: spaceId,
            cookieString: cookieString,
            accessToken: accessToken,
            proxy: proxy,
            userAgent: userAgent
        )

        let explicitFbId: String
        if let cid = commentId, !cid.isEmpty {
            explicitFbId = Data("feedback:\(cid)".utf8).base64EncodedString()
        } else if !postFeedbackId.isEmpty {
            explicitFbId = postFeedbackId
        } else {
            explicitFbId = Data("feedback:\(postId)".utf8).base64EncodedString()
        }

        let res = await client.commentOnPost(
            postId: targetObjectId,
            commentText: replyText,
            explicitFeedbackId: explicitFbId
        )
        return res
    }

    /// Sinh nội dung trả lời tự động bằng Gemini AI
    static func generateAIReply(
        postCaption: String,
        commentAuthor: String?,
        commentText: String?,
        previousReplies: [String],
        apiKey: String,
        model: String,
        stylePrompt: String
    ) async throws -> String {
        let contextCaption = postCaption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "(Bài đăng chia sẻ hình ảnh/video trên trang cá nhân)"
            : postCaption

        var avoidBlock = ""
        if !previousReplies.isEmpty {
            let list = previousReplies.suffix(10).map { "- \"\($0)\"" }.joined(separator: "\n")
            avoidBlock = "\nKhông lặp lại câu chữ với các phản hồi vừa gửi:\n\(list)"
        }

        let prompt: String
        let targetUserName: String

        if let cAuthor = commentAuthor, let cText = commentText, !cText.isEmpty {
            targetUserName = cAuthor
            prompt = """
            \(stylePrompt)
            Bạn là CHỦ BÀI VIẾT đang trả lời bình luận của "\(cAuthor)".
            - Nội dung bài viết gốc của bạn: "\(contextCaption)"
            - Bình luận của \(cAuthor): "\(cText)"
            Hãy viết câu trả lời trực tiếp, thân thiện, đúng ngữ cảnh bình luận của \(cAuthor), ngắn gọn 1-2 câu tự nhiên.\(avoidBlock)
            """
        } else {
            targetUserName = "Chủ bài viết"
            prompt = """
            \(stylePrompt)
            Hãy viết 1 bình luận tương tác tự nhiên, lịch sự vào bài viết có nội dung: "\(contextCaption)".\(avoidBlock)
            """
        }

        let postItem = FeedPostItem(
            postId: "reply_target",
            userName: targetUserName,
            userId: "",
            postText: prompt
        )

        let result = try await GeminiCommentService.analyzeAndGenerateComment(
            post: postItem,
            apiKey: apiKey,
            model: model,
            customStylePrompt: prompt
        )
        return result.comment
    }

    private static func formatShortTime(_ isoString: String) -> String {
        guard !isoString.isEmpty else { return "Vừa xong" }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: isoString) {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        return String(isoString.prefix(16)).replacingOccurrences(of: "T", with: " ")
    }
}

// MARK: - Color Palette for Tracker & AI (#8FBC8F & Trắng làm chủ đạo)

extension Color {
    /// Màu chủ đạo: #8FBC8F (Dark Sea Green)
    static let trackerPrimary = Color(red: 143/255, green: 188/255, blue: 143/255)
    /// Đậm hơn một chút để tương phản cao trên nền trắng và chữ: #75A075
    static let trackerPrimaryDark = Color(red: 117/255, green: 160/255, blue: 117/255)
    /// Nền mềm dịu mắt: #8FBC8F với opacity 14%
    static let trackerSoft = Color(red: 143/255, green: 188/255, blue: 143/255).opacity(0.14)
}

// MARK: - Decorated Button Styles & Reusable UI Components

struct GradientPillButtonStyle: ButtonStyle {
    var colors: [Color] = [.trackerPrimary, .trackerPrimaryDark]
    var isCompact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(isCompact ? .caption.bold() : .subheadline.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, isCompact ? 11 : 15)
            .padding(.vertical, isCompact ? 6 : 9)
            .background(
                LinearGradient(
                    colors: colors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.35), lineWidth: 0.8)
            )
            .shadow(color: Color.trackerPrimaryDark.opacity(configuration.isPressed ? 0.12 : 0.28), radius: 4, x: 0, y: 2)
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct SoftTintedButtonStyle: ButtonStyle {
    var tint: Color = .trackerPrimaryDark
    var isCompact: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(isCompact ? .caption.bold() : .subheadline.bold())
            .foregroundStyle(tint)
            .padding(.horizontal, isCompact ? 10 : 14)
            .padding(.vertical, isCompact ? 6 : 8)
            .background(
                Color.trackerSoft.opacity(configuration.isPressed ? 1.6 : 1.0),
                in: RoundedRectangle(cornerRadius: isCompact ? 9 : 11)
            )
            .overlay(
                RoundedRectangle(cornerRadius: isCompact ? 9 : 11)
                    .stroke(Color.trackerPrimary.opacity(0.35), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Main Post Tracker & AI Reply View

struct PostTrackerView: View {
    @EnvironmentObject private var library: SpaceLibrary
    @StateObject private var tracker = TrackedPostManager.shared

    @State private var selectedSpaceFilter: UUID? = nil // nil = Tất cả tài khoản
    @State private var searchText: String = ""
    @State private var showAddURLSheet = false
    @State private var showAISettingsSheet = false
    @State private var activeReplyPost: TrackedPostItem? = nil
    @State private var quickReplyPostId: UUID? = nil
    @State private var quickReplyText: String = ""
    @State private var isSendingQuickReply: Bool = false

    @AppStorage("vie.auto.geminiModelV2") private var geminiModel = "auto"
    @AppStorage("vie.tracker.aiStylePrompt") private var aiStylePrompt = "Thân thiện, lịch sự như chủ bài đăng đang trò chuyện với bạn bè/khách hàng, đúng trọng tâm bình luận, ngắn gọn 1-2 câu."
    @State private var geminiApiKey: String = ""

    private var facebookSpaces: [Space] {
        library.spaces.filter { $0.platform == .facebook }
    }

    private var filteredPosts: [TrackedPostItem] {
        tracker.posts.filter { item in
            let matchSpace = (selectedSpaceFilter == nil) || (item.spaceId == selectedSpaceFilter)
            let matchQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || item.caption.localizedCaseInsensitiveContains(searchText)
                || item.postId.localizedCaseInsensitiveContains(searchText)
                || item.spaceName.localizedCaseInsensitiveContains(searchText)
            return matchSpace && matchQuery
        }
    }

    private var totalReactions: Int {
        filteredPosts.reduce(0) { $0 + $1.reactionCount }
    }

    private var totalComments: Int {
        filteredPosts.reduce(0) { $0 + $1.commentCount }
    }

    private var totalShares: Int {
        filteredPosts.reduce(0) { $0 + $1.shareCount }
    }

    private var aiTickedPostsCount: Int {
        filteredPosts.filter(\.isAIAutoReplySelected).count
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // 1. Thống kê tổng quan gọn gàng
                summaryDashboardCard

                // 2. Thanh công cụ thao tác nhanh với các Button trang trí đẹp mắt
                decoratedToolbarCard

                // 3. Thanh điều khiển Tick chọn AI tự động trả lời
                aiBatchControlBar

                // 4. Bộ lọc tài khoản & tìm kiếm gọn gàng
                if !facebookSpaces.isEmpty {
                    accountFilterStrip
                }

                // 5. Thanh trạng thái trực tiếp (nếu có)
                if !tracker.statusBanner.isEmpty {
                    HStack(spacing: 8) {
                        if tracker.isSyncingAll || tracker.isRunningAIReply {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                                .foregroundStyle(Color.trackerPrimaryDark)
                        }
                        Text(tracker.statusBanner)
                            .font(.caption.bold())
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Spacer()
                        Button {
                            tracker.statusBanner = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.trackerSoft, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.trackerPrimary.opacity(0.3), lineWidth: 1)
                    )
                }

                // 6. Danh sách bài viết đang theo dõi
                if filteredPosts.isEmpty {
                    emptyStateCard
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(filteredPosts) { post in
                            trackedPostCard(post)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .onAppear {
            if geminiApiKey.isEmpty {
                geminiApiKey = SecureGeminiStore.readKey()
            }
        }
        .sheet(isPresented: $showAddURLSheet) {
            AddTrackedPostSheet(spaces: facebookSpaces)
        }
        .sheet(isPresented: $showAISettingsSheet) {
            TrackerAISettingsSheet(
                geminiApiKey: $geminiApiKey,
                geminiModel: $geminiModel,
                aiStylePrompt: $aiStylePrompt
            )
        }
        .sheet(item: $activeReplyPost) { post in
            PostDetailAndReplySheet(
                postId: post.id,
                spaces: facebookSpaces,
                geminiApiKey: geminiApiKey,
                geminiModel: geminiModel,
                globalStylePrompt: aiStylePrompt
            )
        }
    }

    // MARK: - 1. Summary Dashboard Card

    private var summaryDashboardCard: some View {
        HStack(spacing: 8) {
            statBadge(
                title: "Bài đăng",
                value: "\(filteredPosts.count)",
                icon: "doc.richtext.fill"
            )
            statBadge(
                title: "Cảm xúc",
                value: "\(totalReactions)",
                icon: "heart.fill"
            )
            statBadge(
                title: "Bình luận",
                value: "\(totalComments)",
                icon: "bubble.left.and.bubble.right.fill"
            )
            statBadge(
                title: "Chia sẻ",
                value: "\(totalShares)",
                icon: "arrowshape.turn.up.right.fill"
            )
        }
    }

    private func statBadge(title: String, value: String, icon: String) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 4) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [.trackerPrimary, .trackerPrimaryDark], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 22, height: 22)
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
                Text(value)
                    .font(.subheadline.bold().monospacedDigit())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .padding(.horizontal, 4)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.trackerPrimary.opacity(0.18), lineWidth: 1)
        )
    }

    // MARK: - 2. Decorated Toolbar Card

    private var decoratedToolbarCard: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                // Nút Thêm URL / ID bài viết
                Button {
                    showAddURLSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "link.badge.plus")
                        Text("Thêm URL / ID")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(GradientPillButtonStyle(colors: [.trackerPrimary, .trackerPrimaryDark], isCompact: true))

                // Nút Quét bài đã đăng của tài khoản
                Button {
                    let targets = selectedSpaceFilter == nil
                        ? facebookSpaces
                        : facebookSpaces.filter { $0.id == selectedSpaceFilter }
                    Task {
                        _ = await tracker.importAccountPublishedPosts(for: targets)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.doc.fill")
                        Text("Quét bài đã đăng")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(SoftTintedButtonStyle(tint: .trackerPrimaryDark, isCompact: true))
                .disabled(tracker.isSyncingAll || facebookSpaces.isEmpty)
            }

            HStack(spacing: 8) {
                // Nút Cập nhật thống kê tất cả
                Button {
                    Task {
                        await tracker.syncAllPosts(spaces: facebookSpaces)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Cập nhật tương tác")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(SoftTintedButtonStyle(tint: .trackerPrimaryDark, isCompact: true))
                .disabled(tracker.isSyncingAll || tracker.posts.isEmpty)

                // Nút Cấu hình Gemini AI
                Button {
                    showAISettingsSheet = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "wand.and.stars")
                        Text(geminiApiKey.isEmpty ? "Cài đặt AI Key" : "Cấu hình AI Reply")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(SoftTintedButtonStyle(tint: .trackerPrimaryDark, isCompact: true))
            }
        }
        .padding(10)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.trackerPrimary.opacity(0.18), lineWidth: 1)
        )
    }

    // MARK: - 3. AI Batch Control Bar (Tick chọn AI trả lời)

    private var aiBatchControlBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                // Tick chọn tất cả / Bỏ chọn tất cả cho AI
                let allTicked = !filteredPosts.isEmpty && aiTickedPostsCount == filteredPosts.count
                Button {
                    tracker.setAllAIReply(!allTicked, for: selectedSpaceFilter)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: allTicked ? "checkmark.square.fill" : "square")
                            .foregroundStyle(allTicked ? Color.trackerPrimaryDark : Color.secondary)
                        Text(allTicked ? "Bỏ tick AI (\(aiTickedPostsCount))" : "Tick hết AI (\(aiTickedPostsCount)/\(filteredPosts.count))")
                            .font(.caption.bold())
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color(uiColor: .tertiarySystemGroupedBackground), in: Capsule())
                    .overlay(
                        Capsule().stroke(Color.trackerPrimary.opacity(0.2), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                // Toggle Tự động canh bình luận mới
                Button {
                    tracker.autoMonitorEnabled.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tracker.autoMonitorEnabled ? "antenna.radiowaves.left.and.right" : "clock.arrow.circlepath")
                        Text(tracker.autoMonitorEnabled ? "Auto Canh: BẬT" : "Auto Canh: TẮT")
                    }
                    .font(.caption2.bold())
                    .foregroundStyle(tracker.autoMonitorEnabled ? .white : Color.trackerPrimaryDark)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(
                        tracker.autoMonitorEnabled
                            ? AnyShapeStyle(LinearGradient(colors: [.trackerPrimary, .trackerPrimaryDark], startPoint: .leading, endPoint: .trailing))
                            : AnyShapeStyle(Color.trackerSoft),
                        in: Capsule()
                    )
                    .overlay(
                        Capsule().stroke(Color.trackerPrimary.opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                // Nút Chạy AI trả lời các bài đã tick
                Button {
                    if geminiApiKey.isEmpty {
                        geminiApiKey = SecureGeminiStore.readKey()
                    }
                    if geminiApiKey.isEmpty {
                        showAISettingsSheet = true
                    } else {
                        Task {
                            _ = await tracker.runAIReplyForAllSelectedPosts(
                                spaces: facebookSpaces,
                                geminiApiKey: geminiApiKey,
                                geminiModel: geminiModel,
                                globalStylePrompt: aiStylePrompt
                            )
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        if tracker.isRunningAIReply {
                            ProgressView().tint(.white).controlSize(.mini)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text("AI Trả lời (\(aiTickedPostsCount))")
                    }
                }
                .buttonStyle(GradientPillButtonStyle(colors: [.trackerPrimary, .trackerPrimaryDark], isCompact: true))
                .disabled(tracker.isRunningAIReply || aiTickedPostsCount == 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.trackerPrimary.opacity(0.18), lineWidth: 1)
        )
    }

    // MARK: - 4. Account Filter Strip

    private var accountFilterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                filterChip(title: "Tất cả (\(tracker.posts.count))", isSelected: selectedSpaceFilter == nil) {
                    selectedSpaceFilter = nil
                }
                ForEach(facebookSpaces) { sp in
                    let count = tracker.posts.filter { $0.spaceId == sp.id }.count
                    filterChip(title: "\(sp.name) (\(count))", isSelected: selectedSpaceFilter == sp.id) {
                        selectedSpaceFilter = sp.id
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func filterChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(isSelected ? .white : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    isSelected
                        ? AnyShapeStyle(LinearGradient(colors: [.trackerPrimary, .trackerPrimaryDark], startPoint: .leading, endPoint: .trailing))
                        : AnyShapeStyle(Color(uiColor: .secondarySystemGroupedBackground)),
                    in: Capsule()
                )
                .overlay(
                    Capsule()
                        .stroke(isSelected ? Color.clear : Color.trackerPrimary.opacity(0.25), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 5. Empty State Card

    private var emptyStateCard: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.trackerSoft)
                    .frame(width: 64, height: 64)
                Image(systemName: "chart.bar.doc.horizontal.fill")
                    .font(.title.bold())
                    .foregroundStyle(Color.trackerPrimaryDark)
            }
            Text("Chưa có bài viết nào được theo dõi")
                .font(.subheadline.bold())
            Text("Các bài đăng qua Smart Post sẽ tự động hiển thị tại đây. Bạn cũng có thể bấm 'Thêm URL / ID' hoặc 'Quét bài đã đăng' để bắt đầu theo dõi tương tác và bật AI trả lời.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.trackerPrimary.opacity(0.18), lineWidth: 1)
        )
    }

    // MARK: - 6. Individual Tracked Post Card

    private func trackedPostCard(_ post: TrackedPostItem) -> some View {
        let isSyncing = tracker.syncingPostIds.contains(post.id)
        let isAIRunning = tracker.aiReplyingPostIds.contains(post.id)
        let space = facebookSpaces.first(where: { $0.id == post.spaceId })

        return VStack(alignment: .leading, spacing: 10) {
            // Dòng 1: Tên tài khoản + Thời gian + Nút Tick chọn AI trả lời
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle.fill")
                        .foregroundStyle(Color.trackerPrimaryDark)
                        .font(.subheadline)
                    Text(post.spaceName)
                        .font(.caption.bold())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.trackerSoft, in: Capsule())
                .overlay(
                    Capsule().stroke(Color.trackerPrimary.opacity(0.2), lineWidth: 1)
                )

                Text("ID: \(post.postId.suffix(8))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)

                Spacer()

                // Nút Tick chọn AI tự động trả lời cho bài viết này (gọn gàng, thanh lịch)
                Button {
                    tracker.toggleAIReply(for: post.id)
                } label: {
                    HStack(spacing: 3.5) {
                        Image(systemName: post.isAIAutoReplySelected ? "checkmark.circle.fill" : "sparkles")
                            .font(.system(size: 9.5, weight: .bold))
                        Text(post.isAIAutoReplySelected ? "AI Auto" : "AI Auto")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(post.isAIAutoReplySelected ? .white : Color.trackerPrimaryDark)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3.5)
                    .background(
                        post.isAIAutoReplySelected
                            ? AnyShapeStyle(LinearGradient(colors: [.trackerPrimary, .trackerPrimaryDark], startPoint: .leading, endPoint: .trailing))
                            : AnyShapeStyle(Color.trackerSoft),
                        in: Capsule()
                    )
                    .overlay(
                        Capsule()
                            .stroke(post.isAIAutoReplySelected ? Color.clear : Color.trackerPrimary.opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                // Menu phụ gọn gàng
                HStack(spacing: 6) {
                    Button(role: .destructive) {
                        tracker.removePost(post)
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(.red.opacity(0.75))
                            .padding(2)
                    }
                    .buttonStyle(.plain)

                    Menu {
                        if let url = URL(string: post.postUrl) {
                            Link(destination: url) {
                                Label("Mở bài viết trên trình duyệt", systemImage: "safari")
                            }
                        }
                        Button {
                            Task {
                                await tracker.convertPostURL(id: post.id, space: space)
                            }
                        } label: {
                            Label("Chuyển đổi URL chuẩn (MultiSpace)", systemImage: "arrow.triangle.2.circlepath")
                        }
                        Button {
                            UIPasteboard.general.string = post.postUrl
                            tracker.statusBanner = "📋 Đã sao chép URL bài viết!"
                        } label: {
                            Label("Sao chép URL bài viết", systemImage: "doc.on.doc")
                        }
                        Button {
                            UIPasteboard.general.string = post.postId
                            tracker.statusBanner = "📋 Đã sao chép ID: \(post.postId)"
                        } label: {
                            Label("Sao chép Post ID", systemImage: "number")
                        }
                        Divider()
                        Button(role: .destructive) {
                            tracker.removePost(post)
                        } label: {
                            Label("Xóa khỏi danh sách theo dõi", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(2)
                    }
                }
            }

            // Dòng 2: Nội dung bài viết hoặc URL
            VStack(alignment: .leading, spacing: 3) {
                Text(post.caption.isEmpty ? "(Bài viết không có tiêu đề văn bản)" : post.caption)
                    .font(.subheadline)
                    .foregroundStyle(post.caption.isEmpty ? .secondary : .primary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .font(.caption2)
                        .foregroundStyle(Color.trackerPrimaryDark)
                    Text(post.postUrl)
                        .font(.caption2)
                        .foregroundStyle(Color.trackerPrimaryDark)
                        .lineLimit(1)
                    Button {
                        Task {
                            await tracker.convertPostURL(id: post.id, space: space)
                        }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption2.bold())
                            .foregroundStyle(Color.trackerPrimaryDark)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    if let synced = post.lastSyncedAt {
                        Text("Cập nhật \(synced.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Dòng 3: Thống kê tương tác dạng Pill gọn đẹp (#8FBC8F và trắng)
            HStack(spacing: 8) {
                engagementPill(icon: "hand.thumbsup.fill", text: reactionSummaryText(for: post))
                engagementPill(icon: "bubble.left.fill", text: "\(post.commentCount) bình luận")
                engagementPill(icon: "arrowshape.turn.up.right.fill", text: "\(post.shareCount) chia sẻ")

                Spacer(minLength: 0)

                if post.unrepliedCommentsCount > 0 {
                    Text("\(post.unrepliedCommentsCount) chưa trả lời")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.trackerPrimaryDark, in: Capsule())
                } else if !post.comments.isEmpty {
                    Text("Đã trả lời hết")
                        .font(.caption2.bold())
                        .foregroundStyle(Color.trackerPrimaryDark)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.trackerSoft, in: Capsule())
                }
            }

            // Khung Trả lời nhanh trực tiếp ngay trên thẻ (khi mở)
            if quickReplyPostId == post.id {
                HStack(spacing: 8) {
                    TextField("Nhập bình luận / trả lời trực tiếp...", text: $quickReplyText)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 9))

                    // Nút AI Gợi ý nhanh
                    Button {
                        Task {
                            let key = geminiApiKey.isEmpty ? SecureGeminiStore.readKey() : geminiApiKey
                            guard !key.isEmpty else {
                                showAISettingsSheet = true
                                return
                            }
                            if let draft = try? await PostTrackingAPIClient.generateAIReply(
                                postCaption: post.caption,
                                commentAuthor: nil,
                                commentText: nil,
                                previousReplies: [],
                                apiKey: key,
                                model: geminiModel,
                                stylePrompt: aiStylePrompt
                            ) {
                                quickReplyText = draft
                            }
                        }
                    } label: {
                        Image(systemName: "wand.and.stars")
                    }
                    .buttonStyle(SoftTintedButtonStyle(tint: .trackerPrimaryDark, isCompact: true))

                    // Nút Gửi trực tiếp
                    Button {
                        guard !isSendingQuickReply else { return }
                        guard !quickReplyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        isSendingQuickReply = true
                        let textToSend = quickReplyText
                        Task {
                            let res = await tracker.sendDirectReply(
                                postItemId: post.id,
                                targetCommentId: nil,
                                replyText: textToSend,
                                actingSpace: space
                            )
                            isSendingQuickReply = false
                            if res.success {
                                quickReplyText = ""
                                quickReplyPostId = nil
                                tracker.statusBanner = "✅ Đã gửi bình luận trực tiếp vào bài viết!"
                            } else {
                                tracker.statusBanner = "❌ Lỗi gửi: \(res.message)"
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if isSendingQuickReply {
                                ProgressView().tint(.white).controlSize(.mini)
                            } else {
                                Image(systemName: "paperplane.fill")
                            }
                            Text("Gửi")
                        }
                    }
                    .buttonStyle(GradientPillButtonStyle(colors: [.trackerPrimary, .trackerPrimaryDark], isCompact: true))
                    .disabled(isSendingQuickReply)
                }
                .padding(.top, 2)
            }

            Divider()

            // Dòng 4: Các Button thao tác thiết kế chống tràn dòng (#8FBC8F và trắng)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // 1. Nút Làm mới thống kê
                    Button {
                        Task {
                            await tracker.syncSinglePost(id: post.id, space: space)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            if isSyncing {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text("Thống kê")
                                .lineLimit(1)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(SoftTintedButtonStyle(tint: .trackerPrimaryDark, isCompact: true))
                    .disabled(isSyncing)

                    // 2. Nút Trả lời nhanh trực tiếp
                    Button {
                        withAnimation(.spring(response: 0.25)) {
                            if quickReplyPostId == post.id {
                                quickReplyPostId = nil
                            } else {
                                quickReplyPostId = post.id
                                quickReplyText = ""
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "text.bubble.fill")
                            Text("Trả lời nhanh")
                                .lineLimit(1)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(SoftTintedButtonStyle(tint: .trackerPrimaryDark, isCompact: true))

                    // 3. Nút Xem DS Bình luận & Tick chọn trả lời chi tiết
                    Button {
                        activeReplyPost = post
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "list.bullet.indent")
                            Text("DS Cmt (\(post.comments.count))")
                                .lineLimit(1)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(SoftTintedButtonStyle(tint: .trackerPrimaryDark, isCompact: true))

                    // 4. Nút Chạy AI trả lời ngay cho bài viết này
                    Button {
                        let key = geminiApiKey.isEmpty ? SecureGeminiStore.readKey() : geminiApiKey
                        if key.isEmpty {
                            showAISettingsSheet = true
                        } else {
                            Task {
                                _ = await tracker.runAIReplyForPost(
                                    postItemId: post.id,
                                    specificCommentIds: nil,
                                    replyDirectlyToPostIfNoComments: true,
                                    actingSpace: space,
                                    geminiApiKey: key,
                                    geminiModel: geminiModel,
                                    globalStylePrompt: aiStylePrompt
                                )
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            if isAIRunning {
                                ProgressView().tint(.white).controlSize(.mini)
                            } else {
                                Image(systemName: "sparkles")
                            }
                            Text("AI Reply")
                                .lineLimit(1)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(GradientPillButtonStyle(colors: [.trackerPrimary, .trackerPrimaryDark], isCompact: true))
                    .disabled(isAIRunning)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    post.isAIAutoReplySelected ? Color.trackerPrimary.opacity(0.65) : Color.trackerPrimary.opacity(0.18),
                    lineWidth: post.isAIAutoReplySelected ? 1.5 : 1.0
                )
        )
        .shadow(color: Color.black.opacity(0.04), radius: 4, x: 0, y: 2)
    }

    private func reactionSummaryText(for post: TrackedPostItem) -> String {
        guard !post.reactionBreakdown.isEmpty else { return "\(post.reactionCount) cảm xúc" }
        let mapEmoji = [
            "Like": "👍",
            "Love": "❤️",
            "Care": "🥰",
            "Haha": "😆",
            "Wow": "😮",
            "Sad": "😢",
            "Angry": "😡"
        ]
        let nonZero = post.reactionBreakdown.filter { $0.value > 0 }.sorted(by: { $0.value > $1.value })
        if nonZero.isEmpty { return "\(post.reactionCount) cảm xúc" }
        let emojis = nonZero.prefix(2).map { k, v in "\(mapEmoji[k] ?? "")\(v)" }.joined(separator: " ")
        return "\(emojis) (\(post.reactionCount))"
    }

    private func engagementPill(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.trackerPrimaryDark)
            Text(text)
                .font(.caption2.bold())
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.trackerSoft, in: Capsule())
        .overlay(
            Capsule().stroke(Color.trackerPrimary.opacity(0.18), lineWidth: 0.8)
        )
    }
}

// MARK: - Sheet 1: Thêm Bài Viết Theo Dõi Bằng URL hoặc ID (Chuyển đổi URL chuẩn giống MultiSpace)

struct AddTrackedPostSheet: View {
    let spaces: [Space]
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var tracker = TrackedPostManager.shared

    @State private var targetCategory: TargetCategoryHint = .auto
    @State private var urlOrIdInput: String = ""
    @State private var customCaption: String = ""
    @State private var selectedSpaceId: UUID? = nil
    @State private var enableAIAutoReply: Bool = true
    @State private var isAdding: Bool = false
    @State private var isResolvingLink: Bool = false
    @State private var isPreviewingTarget: Bool = false
    @State private var resolvedLinkMessage: String? = nil
    @State private var resolvedPreview: ResolvedTargetPost? = nil
    @State private var previewStats: PostTrackingAPIClient.PostEngagementSnapshot? = nil
    @State private var errorMessage: String? = nil

    private var chosenSpace: Space? {
        spaces.first(where: { $0.id == selectedSpaceId }) ?? spaces.first
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Loại mục tiêu", selection: $targetCategory) {
                        ForEach(TargetCategoryHint.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .disabled(isAdding)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Link hoặc ID Bài viết / Reel / Nhóm / Fanpage:")
                                .font(.caption.bold())
                            Spacer()
                            Button("Dán") {
                                if let clip = UIPasteboard.general.string {
                                    urlOrIdInput = clip
                                    Task { await resolveShareLink() }
                                }
                            }
                            .buttonStyle(SoftTintedButtonStyle(tint: .trackerPrimaryDark, isCompact: true))
                            .disabled(isAdding || isResolvingLink)

                            Button {
                                Task { await resolveShareLink() }
                            } label: {
                                HStack(spacing: 4) {
                                    if isResolvingLink {
                                        ProgressView().controlSize(.mini)
                                    } else {
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                    }
                                    Text("Mở rộng link")
                                }
                            }
                            .buttonStyle(SoftTintedButtonStyle(tint: .trackerPrimaryDark, isCompact: true))
                            .disabled(isAdding || isResolvingLink || urlOrIdInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }

                        HStack {
                            TextField("Dán link bài viết, Reel, share/p, share/r hoặc ID...", text: $urlOrIdInput)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .textFieldStyle(.roundedBorder)
                            if !urlOrIdInput.isEmpty {
                                Button {
                                    urlOrIdInput = ""
                                    resolvedLinkMessage = nil
                                    resolvedPreview = nil
                                    previewStats = nil
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if let msg = resolvedLinkMessage {
                            Text(msg)
                                .font(.caption2)
                                .foregroundStyle(msg.hasPrefix("✅") ? Color.trackerPrimaryDark : Color.secondary)
                                .lineLimit(2)
                        }
                    }

                    TextField("Ghi chú / Nội dung bài viết bổ sung (tùy chọn cho AI đọc)", text: $customCaption, axis: .vertical)
                        .lineLimit(2...4)

                    Button {
                        Task { await previewTargetPostAndStats() }
                    } label: {
                        HStack(spacing: 6) {
                            if isPreviewingTarget {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "magnifyingglass.circle.fill")
                            }
                            Text("Kiểm tra Link, Chuyển đổi URL & Đọc thống kê mục tiêu")
                                .font(.caption.bold())
                        }
                    }
                    .disabled(isAdding || isPreviewingTarget || urlOrIdInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let resolved = resolvedPreview {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("✅ Đã nhận diện: \(resolved.targetKind) • ID: \(resolved.postId)")
                                .font(.caption.bold())
                                .foregroundStyle(Color.trackerPrimaryDark)
                            if let canon = resolved.canonicalURL?.absoluteString {
                                Text("🔗 URL chuẩn: \(canon)")
                                    .font(.caption2)
                                    .foregroundStyle(Color.trackerPrimaryDark)
                                    .lineLimit(1)
                            }
                            Text("Đăng bởi: \(resolved.authorName)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if let st = previewStats {
                                Text("📊 Thống kê: ❤️ \(st.reactionCount) cảm xúc • 💬 \(max(st.commentCount, st.comments.count)) bình luận • 🔄 \(st.shareCount) chia sẻ")
                                    .font(.caption2.bold())
                                    .foregroundStyle(Color.trackerPrimaryDark)
                            }
                            if !resolved.postText.isEmpty {
                                Text("Nội dung: \"\(resolved.postText.prefix(140))\"")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("1. Đường dẫn (URL) hoặc ID bài viết đã đăng")
                } footer: {
                    Text("Hỗ trợ chuyển đổi mọi định dạng link giống MultiSpace: share/p/..., share/r/..., pfbid..., fb.watch, Reel, bài Nhóm, Fanpage hoặc Post ID.")
                }

                Section("2. Tài khoản quản lý & trả lời") {
                    if spaces.isEmpty {
                        Text("Chưa có không gian Facebook nào.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Chọn tài khoản", selection: $selectedSpaceId) {
                            ForEach(spaces) { sp in
                                Text(sp.name).tag(Optional(sp.id))
                            }
                        }
                    }

                    Toggle(isOn: $enableAIAutoReply) {
                        Label("Tick bật AI tự động trả lời bình luận", systemImage: "sparkles")
                            .font(.subheadline.bold())
                            .foregroundStyle(Color.trackerPrimaryDark)
                    }
                    .tint(.trackerPrimary)
                }

                if let err = errorMessage {
                    Section {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        guard let space = chosenSpace else { return }
                        isAdding = true
                        errorMessage = nil
                        Task {
                            do {
                                _ = try await tracker.addPostByURLOrID(
                                    rawInput: urlOrIdInput,
                                    space: space,
                                    categoryHint: targetCategory,
                                    customCaption: customCaption,
                                    enableAI: enableAIAutoReply
                                )
                                isAdding = false
                                dismiss()
                            } catch {
                                isAdding = false
                                errorMessage = error.localizedDescription
                            }
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if isAdding {
                                ProgressView().tint(.white)
                                Text("Đang chuyển đổi URL & lấy thống kê...")
                            } else {
                                Image(systemName: "plus.circle.fill")
                                Text("Thêm vào danh sách theo dõi")
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(GradientPillButtonStyle(colors: [.trackerPrimary, .trackerPrimaryDark], isCompact: false))
                    .disabled(isAdding || urlOrIdInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chosenSpace == nil)
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Thêm bài viết theo dõi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Đóng") { dismiss() }
                }
            }
            .onAppear {
                if selectedSpaceId == nil {
                    selectedSpaceId = spaces.first?.id
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @MainActor
    private func resolveShareLink() async {
        let raw = urlOrIdInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        isResolvingLink = true
        resolvedLinkMessage = nil
        defer { isResolvingLink = false }

        var sampleCookie = ""
        if let sp = chosenSpace {
            let creds = await TrackedPostManager.resolveCookieAndToken(for: sp)
            sampleCookie = creds.cookie
        }

        if let result = await FacebookTargetPostResolver.resolveShareURLToCanonical(
            input: raw,
            cookieString: sampleCookie,
            proxy: chosenSpace?.proxy
        ) {
            urlOrIdInput = result.canonicalURL
            resolvedLinkMessage = "✅ Đã chuyển thành: \(result.canonicalURL)"
        } else {
            resolvedLinkMessage = "⚠️ Không thể giải mã link rút gọn. Hãy dán trực tiếp link bài viết."
        }
    }

    @MainActor
    private func previewTargetPostAndStats() async {
        guard let space = chosenSpace else { return }
        isPreviewingTarget = true
        errorMessage = nil
        defer { isPreviewingTarget = false }

        await resolveShareLink()

        do {
            let creds = await TrackedPostManager.resolveCookieAndToken(for: space)
            var resolved = try await FacebookTargetPostResolver.resolve(
                input: urlOrIdInput,
                cookieString: creds.cookie,
                accessToken: creds.token,
                proxy: space.proxy,
                userAgent: space.fingerprint?.userAgent
            )
            if targetCategory != .auto {
                resolved.targetKind = targetCategory.rawValue
            }
            if let canon = resolved.canonicalURL?.absoluteString {
                urlOrIdInput = canon
                resolvedLinkMessage = "✅ Đã chuyển thành: \(canon)"
            }
            resolvedPreview = resolved

            let stats = await PostTrackingAPIClient.fetchPostEngagementAndComments(
                postId: resolved.postId,
                postUrl: resolved.canonicalURL?.absoluteString ?? urlOrIdInput,
                feedbackId: resolved.feedbackId,
                ownerUserId: creds.uid,
                spaceId: space.id,
                cookieString: creds.cookie,
                accessToken: creds.token,
                proxy: space.proxy
            )
            previewStats = stats
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Sheet 2: Chi Tiết Bình Luận, Trả Lời Trực Tiếp & Tick Chọn AI Trả Lời

struct PostDetailAndReplySheet: View {
    let postId: UUID
    let spaces: [Space]
    let geminiApiKey: String
    let geminiModel: String
    let globalStylePrompt: String

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var tracker = TrackedPostManager.shared

    @State private var tickedCommentIds: Set<String> = []
    @State private var selectedReplyTargetComment: TrackedCommentItem? = nil
    @State private var directReplyText: String = ""
    @State private var actingSpaceId: UUID? = nil
    @State private var isSending: Bool = false
    @State private var isGeneratingAI: Bool = false
    @State private var feedbackBanner: String = ""

    private var post: TrackedPostItem? {
        tracker.posts.first(where: { $0.id == postId })
    }

    private var actingSpace: Space? {
        spaces.first(where: { $0.id == actingSpaceId })
            ?? spaces.first(where: { $0.id == post?.spaceId })
            ?? spaces.first
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let currentPost = post {
                    // Header tóm tắt bài viết & chọn tài khoản phản hồi
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(currentPost.spaceName, systemImage: "person.crop.circle.badge.checkmark")
                                .font(.caption.bold())
                                .foregroundStyle(Color.trackerPrimaryDark)
                            Spacer()
                            Text("❤️ \(currentPost.reactionCount) • 💬 \(currentPost.commentCount) • 🔄 \(currentPost.shareCount)")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                        }

                        Text(currentPost.caption.isEmpty ? currentPost.postUrl : currentPost.caption)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(2)

                        // Thanh công cụ Tick chọn bình luận để AI trả lời
                        HStack(spacing: 8) {
                            let allIds = Set(currentPost.comments.map(\.id))
                            let allSelected = !allIds.isEmpty && tickedCommentIds == allIds

                            Button {
                                if allSelected {
                                    tickedCommentIds.removeAll()
                                } else {
                                    tickedCommentIds = allIds
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: allSelected ? "checkmark.square.fill" : "square")
                                    Text("Chọn hết (\(tickedCommentIds.count))")
                                }
                            }
                            .buttonStyle(SoftTintedButtonStyle(tint: .trackerPrimaryDark, isCompact: true))

                            Button {
                                let unreplied = currentPost.comments
                                    .filter { !currentPost.isCommentHandled($0) }
                                    .map(\.id)
                                tickedCommentIds = Set(unreplied)
                            } label: {
                                Text("Tick chưa trả lời")
                            }
                            .buttonStyle(SoftTintedButtonStyle(tint: .trackerPrimaryDark, isCompact: true))

                            Spacer()

                            Button {
                                Task {
                                    await tracker.syncSinglePost(id: currentPost.id, space: actingSpace)
                                }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(SoftTintedButtonStyle(tint: .trackerPrimaryDark, isCompact: true))

                            Button {
                                let key = geminiApiKey.isEmpty ? SecureGeminiStore.readKey() : geminiApiKey
                                guard !key.isEmpty else {
                                    feedbackBanner = "⚠️ Hãy cài đặt Gemini API Key trước!"
                                    return
                                }
                                Task {
                                    let res = await tracker.runAIReplyForPost(
                                        postItemId: currentPost.id,
                                        specificCommentIds: tickedCommentIds.isEmpty ? nil : tickedCommentIds,
                                        replyDirectlyToPostIfNoComments: currentPost.comments.isEmpty,
                                        actingSpace: actingSpace,
                                        geminiApiKey: key,
                                        geminiModel: geminiModel,
                                        globalStylePrompt: globalStylePrompt
                                    )
                                    feedbackBanner = res.repliedCount > 0
                                        ? "✅ AI đã trả lời \(res.repliedCount) bình luận!"
                                        : (res.errorMessage ?? "Không có bình luận nào cần trả lời.")
                                    tickedCommentIds.removeAll()
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "sparkles")
                                    Text(tickedCommentIds.isEmpty ? "AI Trả lời tự động" : "AI Trả lời (\(tickedCommentIds.count))")
                                }
                            }
                            .buttonStyle(GradientPillButtonStyle(colors: [.trackerPrimary, .trackerPrimaryDark], isCompact: true))
                        }
                    }
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))

                    if !feedbackBanner.isEmpty {
                        Text(feedbackBanner)
                            .font(.caption.bold())
                            .foregroundStyle(Color.trackerPrimaryDark)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.trackerSoft)
                    }

                    Divider()

                    // Danh sách bình luận
                    if currentPost.comments.isEmpty {
                        VStack(spacing: 10) {
                            Spacer()
                            Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("Chưa có bình luận nào được tải")
                                .font(.subheadline.bold())
                            Text("Bạn có thể bấm nút Làm mới ở trên để tải bình luận mới nhất hoặc gửi bình luận trực tiếp vào bài viết ở khung bên dưới.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 28)
                            Spacer()
                        }
                    } else {
                        List {
                            ForEach(currentPost.comments) { cmt in
                                let isTicked = tickedCommentIds.contains(cmt.id)
                                let isHandled = currentPost.isCommentHandled(cmt)

                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 8) {
                                        // Nút tick chọn bình luận cho AI
                                        Button {
                                            if isTicked { tickedCommentIds.remove(cmt.id) }
                                            else { tickedCommentIds.insert(cmt.id) }
                                        } label: {
                                            Image(systemName: isTicked ? "checkmark.square.fill" : "square")
                                                .font(.title3)
                                                .foregroundStyle(isTicked ? Color.trackerPrimaryDark : .secondary)
                                        }
                                        .buttonStyle(.plain)

                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 6) {
                                                Text(cmt.authorName)
                                                    .font(.subheadline.bold())
                                                Text(cmt.createdTime)
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                                if isHandled {
                                                    Text("Đã trả lời")
                                                        .font(.caption2.bold())
                                                        .foregroundStyle(Color.trackerPrimaryDark)
                                                        .padding(.horizontal, 6)
                                                        .padding(.vertical, 2)
                                                        .background(Color.trackerSoft, in: Capsule())
                                                }
                                            }
                                            Text(cmt.message)
                                                .font(.subheadline)
                                                .foregroundStyle(.primary)
                                        }

                                        Spacer()

                                        // Nút chọn để trả lời trực tiếp hoặc AI trả lời lẻ
                                        Button {
                                            selectedReplyTargetComment = cmt
                                        } label: {
                                            HStack(spacing: 3) {
                                                Image(systemName: "arrowshape.turn.up.left.fill")
                                                Text("Trả lời")
                                            }
                                        }
                                        .buttonStyle(SoftTintedButtonStyle(tint: .trackerPrimaryDark, isCompact: true))
                                    }

                                    if let lastReply = cmt.lastReplyText, !lastReply.isEmpty {
                                        HStack(spacing: 6) {
                                            Image(systemName: "checkmark.bubble.fill")
                                                .font(.caption2)
                                                .foregroundStyle(Color.trackerPrimaryDark)
                                            Text("Phản hồi: \"\(lastReply)\"")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                        .padding(.leading, 30)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .listStyle(.plain)
                    }

                    Divider()

                    // Khung nhập trả lời trực tiếp ở đáy màn hình
                    VStack(spacing: 8) {
                        HStack {
                            if let targetCmt = selectedReplyTargetComment {
                                HStack(spacing: 4) {
                                    Text("Đang trả lời: \(targetCmt.authorName)")
                                        .font(.caption.bold())
                                        .foregroundStyle(Color.trackerPrimaryDark)
                                    Button {
                                        selectedReplyTargetComment = nil
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            } else {
                                Text("Bình luận trực tiếp vào bài viết")
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if !spaces.isEmpty {
                                Picker("Tài khoản gửi", selection: $actingSpaceId) {
                                    ForEach(spaces) { sp in
                                        Text(sp.name).tag(Optional(sp.id))
                                    }
                                }
                                .labelsHidden()
                                .controlSize(.mini)
                            }
                        }

                        HStack(spacing: 8) {
                            TextField(
                                selectedReplyTargetComment != nil
                                    ? "Nhập câu trả lời cho \(selectedReplyTargetComment!.authorName)..."
                                    : "Nhập nội dung bình luận trực tiếp...",
                                text: $directReplyText,
                                axis: .vertical
                            )
                            .font(.subheadline)
                            .lineLimit(1...3)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))

                            // Nút dùng AI soạn câu trả lời vào ô nhập
                            Button {
                                let key = geminiApiKey.isEmpty ? SecureGeminiStore.readKey() : geminiApiKey
                                guard !key.isEmpty else {
                                    feedbackBanner = "⚠️ Chưa nhập Gemini API Key!"
                                    return
                                }
                                isGeneratingAI = true
                                Task {
                                    do {
                                        let draft = try await PostTrackingAPIClient.generateAIReply(
                                            postCaption: currentPost.caption,
                                            commentAuthor: selectedReplyTargetComment?.authorName,
                                            commentText: selectedReplyTargetComment?.message,
                                            previousReplies: [],
                                            apiKey: key,
                                            model: geminiModel,
                                            stylePrompt: globalStylePrompt
                                        )
                                        directReplyText = draft
                                    } catch {
                                        feedbackBanner = "Lỗi AI: \(error.localizedDescription)"
                                    }
                                    isGeneratingAI = false
                                }
                            } label: {
                                HStack(spacing: 3) {
                                    if isGeneratingAI {
                                        ProgressView().controlSize(.mini)
                                    } else {
                                        Image(systemName: "wand.and.stars")
                                    }
                                    Text("AI Soạn")
                                }
                            }
                            .buttonStyle(SoftTintedButtonStyle(tint: .trackerPrimaryDark, isCompact: true))
                            .disabled(isGeneratingAI)

                            // Nút Gửi phản hồi
                            Button {
                                guard !isSending else { return }
                                let text = directReplyText.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !text.isEmpty else { return }
                                isSending = true
                                let targetCid = selectedReplyTargetComment?.id
                                Task {
                                    let res = await tracker.sendDirectReply(
                                        postItemId: currentPost.id,
                                        targetCommentId: targetCid,
                                        replyText: text,
                                        actingSpace: actingSpace
                                    )
                                    isSending = false
                                    if res.success {
                                        directReplyText = ""
                                        selectedReplyTargetComment = nil
                                        feedbackBanner = "✅ \(res.message)"
                                    } else {
                                        feedbackBanner = "❌ \(res.message)"
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    if isSending {
                                        ProgressView().tint(.white).controlSize(.mini)
                                    } else {
                                        Image(systemName: "paperplane.fill")
                                    }
                                    Text("Gửi")
                                }
                            }
                            .buttonStyle(GradientPillButtonStyle(colors: [.trackerPrimary, .trackerPrimaryDark], isCompact: true))
                            .disabled(isSending || directReplyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                }
            }
            .navigationTitle("Thống kê & Trả lời bài viết")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Đóng") { dismiss() }
                }
            }
            .onAppear {
                actingSpaceId = post?.spaceId ?? spaces.first?.id
                if let p = post, p.comments.isEmpty {
                    Task {
                        await tracker.syncSinglePost(id: p.id, space: actingSpace)
                    }
                }
            }
        }
    }
}

// MARK: - Sheet 3: Cấu Hình Gemini AI Cho Trả Lời Bài Viết

struct TrackerAISettingsSheet: View {
    @Binding var geminiApiKey: String
    @Binding var geminiModel: String
    @Binding var aiStylePrompt: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Gemini API Key (Dùng chung toàn hệ thống)") {
                    SecureField("Nhập Gemini API Key (AIza...)", text: $geminiApiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Model AI & Phong cách trả lời") {
                    Picker("Model Gemini", selection: $geminiModel) {
                        ForEach(GeminiCommentService.availableModels, id: \.self) { m in
                            Text(GeminiCommentService.modelLabel(m)).tag(m)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Hướng dẫn văn phong khi AI trả lời:")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        TextField("Nhập phong cách trả lời...", text: $aiStylePrompt, axis: .vertical)
                            .lineLimit(3...5)
                    }
                }

                Section {
                    Button {
                        SecureGeminiStore.saveKey(geminiApiKey)
                        dismiss()
                    } label: {
                        HStack {
                            Spacer()
                            Image(systemName: "checkmark.seal.fill")
                            Text("Lưu cấu hình AI Reply")
                            Spacer()
                        }
                    }
                    .buttonStyle(GradientPillButtonStyle(colors: [.trackerPrimary, .trackerPrimaryDark], isCompact: false))
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Cấu hình AI Trả lời")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Đóng") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
