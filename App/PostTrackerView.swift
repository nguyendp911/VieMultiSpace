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

        let resolvedUrl = postUrl ?? "https://www.facebook.com/\(cleanId)"
        let feedbackId = Data("feedback:\(cleanId)".utf8).base64EncodedString()

        if let existingIdx = posts.firstIndex(where: { $0.postId == cleanId && $0.spaceId == spaceId }) {
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
        customCaption: String = "",
        enableAI: Bool = false
    ) async throws -> TrackedPostItem {
        let creds = await Self.resolveCookieAndToken(for: space)
        let resolved = try await FacebookTargetPostResolver.resolve(
            input: rawInput,
            cookieString: creds.cookie,
            accessToken: creds.token,
            proxy: space.proxy,
            userAgent: space.fingerprint?.userAgent
        )

        let finalCaption = !customCaption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? customCaption
            : resolved.postText
        let finalUrl = resolved.canonicalURL?.absoluteString ?? "https://www.facebook.com/\(resolved.postId)"

        if let existingIdx = posts.firstIndex(where: { $0.postId == resolved.postId && $0.spaceId == space.id }) {
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

    func syncSinglePost(id: UUID, space: Space?) async {
        guard let idx = posts.firstIndex(where: { $0.id == id }) else { return }
        syncingPostIds.insert(id)
        defer { syncingPostIds.remove(id) }

        let post = posts[idx]
        let creds = await Self.resolveCookieAndToken(forId: post.spaceId, fallbackSpace: space)
        guard !creds.cookie.isEmpty || !creds.token.isEmpty else {
            statusBanner = "⚠️ \(post.spaceName) chưa có Token/Cookie để đồng bộ."
            return
        }

        let details = await PostTrackingAPIClient.fetchPostEngagementAndComments(
            postId: post.postId,
            feedbackId: post.feedbackId,
            ownerUserId: creds.uid,
            cookieString: creds.cookie,
            accessToken: creds.token,
            proxy: space?.proxy
        )

        guard let currentIndex = posts.firstIndex(where: { $0.id == id }) else { return }
        posts[currentIndex].reactionCount = details.reactionCount
        posts[currentIndex].commentCount = max(details.commentCount, details.comments.count)
        posts[currentIndex].shareCount = details.shareCount
        if !details.caption.isEmpty && posts[currentIndex].caption.isEmpty {
            posts[currentIndex].caption = details.caption
        }

        // Merge comments while preserving local reply history
        let existingMap = Dictionary(uniqueKeysWithValues: posts[currentIndex].comments.map { ($0.id, $0) })
        let repliedSet = posts[currentIndex].repliedCommentIds

        var mergedComments: [TrackedCommentItem] = []
        for var c in details.comments {
            if let old = existingMap[c.id] {
                if old.isReplied {
                    c.isReplied = true
                    c.lastReplyText = old.lastReplyText ?? c.lastReplyText
                    c.repliedAt = old.repliedAt
                }
            }
            if repliedSet.contains(c.id) {
                c.isReplied = true
            }
            mergedComments.append(c)
        }

        posts[currentIndex].comments = mergedComments
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
            statusBanner = "⚠️ Hãy tick chọn ít nhất 1 bài viết (nút AI Tự trả lời) để chạy!"
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
            let tok = !vault.originalToken.isEmpty
                ? vault.originalToken
                : (vault.convertedTokens["FB_ANDROID"]?.accessToken ?? "")
            let uid = !vault.uid.isEmpty
                ? vault.uid
                : (FacebookTargetPostResolver.firstMatch(pattern: #"c_user=(\d+)"#, in: cookieStr) ?? "")
            return (cookieStr, tok, uid)
        } else {
            let webCookies = await WebCookieBridge.extractFacebookCookies(from: spaceId)
            let cookieStr = FacebookAppTokens.formatCookieString(webCookies)
            let uid = FacebookTargetPostResolver.firstMatch(pattern: #"c_user=(\d+)"#, in: cookieStr) ?? ""
            return (cookieStr, "", uid)
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
        guard !accessToken.isEmpty else { return results }

        let targetUid = userId.isEmpty ? "me" : userId
        var comps = URLComponents(string: "https://graph.facebook.com/v18.0/\(targetUid)/posts")
        comps?.queryItems = [
            URLQueryItem(name: "fields", value: "id,message,story,created_time,permalink_url,shares,reactions.summary(total_count),likes.summary(total_count),comments.limit(20).summary(total_count){id,message,created_time,from,like_count,comment_count}"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "access_token", value: accessToken)
        ]

        guard let url = comps?.url else { return results }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataArr = json["data"] as? [[String: Any]] else {
                return results
            }

            let isoFormatter = ISO8601DateFormatter()
            for item in dataArr {
                let rawId = item["id"] as? String ?? ""
                let cleanPostId = rawId.contains("_")
                    ? String(rawId.split(separator: "_").last ?? Substring(rawId))
                    : rawId
                guard !cleanPostId.isEmpty else { continue }

                let msg = (item["message"] as? String) ?? (item["story"] as? String) ?? ""
                let permalink = (item["permalink_url"] as? String) ?? "https://www.facebook.com/\(rawId)"
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
                    postUrl: permalink,
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
        } catch {
            AppLogger.shared.warning("PostTracker", "Lỗi quét bài đã đăng cho \(space.name): \(error.localizedDescription)")
        }

        return results
    }

    /// Lấy thống kê tương tác (Reaction, Comment, Share) và danh sách bình luận chi tiết của 1 bài viết
    static func fetchPostEngagementAndComments(
        postId: String,
        feedbackId: String,
        ownerUserId: String,
        cookieString: String,
        accessToken: String,
        proxy: SpaceProxy? = nil
    ) async -> PostEngagementSnapshot {
        var snapshot = PostEngagementSnapshot()

        // 1. Ưu tiên truy vấn qua Graph API (thử cả postId trực tiếp và ownerUserId_postId)
        if !accessToken.isEmpty {
            let candidateIds: [String] = {
                if postId.contains("_") || ownerUserId.isEmpty {
                    return [postId]
                }
                return ["\(ownerUserId)_\(postId)", postId]
            }()

            for cid in candidateIds {
                if let graphSnap = await fetchViaGraphAPI(queryPostId: cid, ownerUserId: ownerUserId, accessToken: accessToken) {
                    return graphSnap
                }
            }
        }

        // 2. Fallback: Quét từ trang bài viết bằng Cookie nếu Graph API bị giới hạn quyền
        if !cookieString.isEmpty {
            if let webSnap = await fetchViaWebScrape(postId: postId, cookieString: cookieString, proxy: proxy) {
                snapshot = webSnap
            }
        }

        return snapshot
    }

    private static func fetchViaGraphAPI(
        queryPostId: String,
        ownerUserId: String,
        accessToken: String
    ) async -> PostEngagementSnapshot? {
        var comps = URLComponents(string: "https://graph.facebook.com/v18.0/\(queryPostId)")
        comps?.queryItems = [
            URLQueryItem(name: "fields", value: "id,message,story,shares,reactions.summary(total_count),likes.summary(total_count),comments.limit(50).summary(total_count){id,message,created_time,from,like_count,comment_count,comments.limit(10){id,message,from,created_time}}"),
            URLQueryItem(name: "access_token", value: accessToken)
        ]
        guard let url = comps?.url else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["error"] == nil else {
                return nil
            }

            var snap = PostEngagementSnapshot()
            snap.caption = (json["message"] as? String) ?? (json["story"] as? String) ?? ""
            snap.reactionCount = ((json["reactions"] as? [String: Any])?["summary"] as? [String: Any])?["total_count"] as? Int
                ?? ((json["likes"] as? [String: Any])?["summary"] as? [String: Any])?["total_count"] as? Int
                ?? 0
            snap.shareCount = (json["shares"] as? [String: Any])?["count"] as? Int ?? 0

            let commentsRoot = json["comments"] as? [String: Any]
            snap.comments = parseGraphComments(from: commentsRoot, ownerUserId: ownerUserId)
            snap.commentCount = (commentsRoot?["summary"] as? [String: Any])?["total_count"] as? Int
                ?? snap.comments.count

            return snap
        } catch {
            return nil
        }
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

    private static func fetchViaWebScrape(
        postId: String,
        cookieString: String,
        proxy: SpaceProxy?
    ) async -> PostEngagementSnapshot? {
        guard let url = URL(string: "https://www.facebook.com/\(postId)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("vi,en-US;q=0.8,en;q=0.6", forHTTPHeaderField: "Accept-Language")
        request.setValue(cookieString, forHTTPHeaderField: "Cookie")

        let session: URLSession
        if let proxy, proxy.isEnabled {
            let cfg = URLSessionConfiguration.default
            cfg.proxyConfigurations = [proxy.toNetworkProxyConfiguration()]
            session = URLSession(configuration: cfg)
        } else {
            session = URLSession.shared
        }

        do {
            let (data, _) = try await session.data(for: request)
            let html = String(data: data, encoding: .utf8) ?? ""
            guard !html.isEmpty else { return nil }

            var snap = PostEngagementSnapshot()
            if let rStr = FacebookTargetPostResolver.firstMatch(pattern: #""reaction_count":\{"count":(\d+)"#, in: html)
                ?? FacebookTargetPostResolver.firstMatch(pattern: #""reactors":\{"count":(\d+)"#, in: html) {
                snap.reactionCount = Int(rStr) ?? 0
            }
            if let cStr = FacebookTargetPostResolver.firstMatch(pattern: #""total_comment_count":(\d+)"#, in: html)
                ?? FacebookTargetPostResolver.firstMatch(pattern: #""comment_rendering_instance":\{"comments":\{"total_count":(\d+)"#, in: html) {
                snap.commentCount = Int(cStr) ?? 0
            }
            if let sStr = FacebookTargetPostResolver.firstMatch(pattern: #""share_count":\{"count":(\d+)"#, in: html)
                ?? FacebookTargetPostResolver.firstMatch(pattern: #""reshares":\{"count":(\d+)"#, in: html) {
                snap.shareCount = Int(sStr) ?? 0
            }
            if let msg = FacebookTargetPostResolver.firstMatch(pattern: #""message":\{"text":"([^"]+)""#, in: html) {
                snap.caption = FacebookTargetPostResolver.decodeJSONEscapes(msg)
            }
            return snap
        } catch {
            return nil
        }
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
        let targetObjectId = (commentId?.isEmpty == false) ? commentId! : postId

        // 1. Thử qua Graph API /{targetObjectId}/comments
        if !accessToken.isEmpty,
           let url = URL(string: "https://graph.facebook.com/v18.0/\(targetObjectId)/comments") {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let allowed = CharacterSet.alphanumerics
            let encodedMsg = replyText.addingPercentEncoding(withAllowedCharacters: allowed) ?? replyText
            let encodedTok = accessToken.addingPercentEncoding(withAllowedCharacters: allowed) ?? accessToken
            req.httpBody = "message=\(encodedMsg)&access_token=\(encodedTok)".data(using: .utf8)

            if let (data, response) = try? await URLSession.shared.data(for: req),
               let http = response as? HTTPURLResponse,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let newId = json["id"] as? String, !newId.isEmpty, http.statusCode == 200 {
                    return (true, "Đã gửi phản hồi thành công (ID: \(newId))")
                }
            }
        }

        // 2. Fallback sang Comet Web GraphQL thông qua FacebookGraphQLAutoClient
        guard !cookieString.isEmpty else {
            return (false, "Không thể gửi qua Graph API và không gian chưa có Cookie dự phòng.")
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

// MARK: - Decorated Button Styles & Reusable UI Components

struct GradientPillButtonStyle: ButtonStyle {
    var colors: [Color]
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
                    .stroke(Color.white.opacity(0.25), lineWidth: 0.8)
            )
            .shadow(color: (colors.first ?? .blue).opacity(configuration.isPressed ? 0.12 : 0.28), radius: 4, x: 0, y: 2)
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct SoftTintedButtonStyle: ButtonStyle {
    var tint: Color
    var isCompact: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(isCompact ? .caption.bold() : .subheadline.bold())
            .foregroundStyle(tint)
            .padding(.horizontal, isCompact ? 10 : 14)
            .padding(.vertical, isCompact ? 6 : 8)
            .background(
                tint.opacity(configuration.isPressed ? 0.22 : 0.12),
                in: RoundedRectangle(cornerRadius: isCompact ? 9 : 11)
            )
            .overlay(
                RoundedRectangle(cornerRadius: isCompact ? 9 : 11)
                    .stroke(tint.opacity(0.35), lineWidth: 1)
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
                                .foregroundStyle(.purple)
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
                    .background(Color.purple.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.purple.opacity(0.25), lineWidth: 1)
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
                icon: "doc.richtext.fill",
                colors: [.blue, .cyan]
            )
            statBadge(
                title: "Cảm xúc",
                value: "\(totalReactions)",
                icon: "heart.fill",
                colors: [.pink, .red]
            )
            statBadge(
                title: "Bình luận",
                value: "\(totalComments)",
                icon: "bubble.left.and.bubble.right.fill",
                colors: [.orange, .yellow]
            )
            statBadge(
                title: "Chia sẻ",
                value: "\(totalShares)",
                icon: "arrowshape.turn.up.right.fill",
                colors: [.indigo, .purple]
            )
        }
    }

    private func statBadge(title: String, value: String, icon: String, colors: [Color]) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 4) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
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
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
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
                .buttonStyle(GradientPillButtonStyle(colors: [.blue, .indigo], isCompact: true))

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
                .buttonStyle(GradientPillButtonStyle(colors: [.teal, .green], isCompact: true))
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
                .buttonStyle(SoftTintedButtonStyle(tint: .blue, isCompact: true))
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
                .buttonStyle(SoftTintedButtonStyle(tint: .purple, isCompact: true))
            }
        }
        .padding(10)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
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
                            .foregroundStyle(allTicked ? .purple : .secondary)
                        Text(allTicked ? "Bỏ tick AI (\(aiTickedPostsCount))" : "Tick hết AI (\(aiTickedPostsCount)/\(filteredPosts.count))")
                            .font(.caption.bold())
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color(uiColor: .tertiarySystemGroupedBackground), in: Capsule())
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
                    .foregroundStyle(tracker.autoMonitorEnabled ? .white : .orange)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(
                        tracker.autoMonitorEnabled
                            ? AnyShapeStyle(LinearGradient(colors: [.orange, .red], startPoint: .leading, endPoint: .trailing))
                            : AnyShapeStyle(Color.orange.opacity(0.14)),
                        in: Capsule()
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
                .buttonStyle(GradientPillButtonStyle(colors: [.purple, .pink], isCompact: true))
                .disabled(tracker.isRunningAIReply || aiTickedPostsCount == 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
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
                        ? AnyShapeStyle(LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing))
                        : AnyShapeStyle(Color(uiColor: .secondarySystemGroupedBackground)),
                    in: Capsule()
                )
                .overlay(
                    Capsule()
                        .stroke(isSelected ? Color.clear : Color.primary.opacity(0.1), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 5. Empty State Card

    private var emptyStateCard: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.blue.opacity(0.15), .purple.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 64, height: 64)
                Image(systemName: "chart.bar.doc.horizontal.fill")
                    .font(.title.bold())
                    .foregroundStyle(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
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
                        .foregroundStyle(.blue)
                        .font(.subheadline)
                    Text(post.spaceName)
                        .font(.caption.bold())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.blue.opacity(0.1), in: Capsule())

                Text("ID: \(post.postId.suffix(8))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)

                Spacer()

                // Nút Tick chọn AI tự động trả lời cho bài viết này
                Button {
                    tracker.toggleAIReply(for: post.id)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: post.isAIAutoReplySelected ? "checkmark.square.fill" : "square")
                            .font(.caption.bold())
                        Text("AI Tự trả lời")
                            .font(.caption2.bold())
                    }
                    .foregroundStyle(post.isAIAutoReplySelected ? .white : .purple)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        post.isAIAutoReplySelected
                            ? AnyShapeStyle(LinearGradient(colors: [.purple, .indigo], startPoint: .leading, endPoint: .trailing))
                            : AnyShapeStyle(Color.purple.opacity(0.1)),
                        in: Capsule()
                    )
                    .overlay(
                        Capsule()
                            .stroke(Color.purple.opacity(0.35), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                // Menu phụ gọn gàng
                Menu {
                    if let url = URL(string: post.postUrl) {
                        Link(destination: url) {
                            Label("Mở bài viết trên trình duyệt", systemImage: "safari")
                        }
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

            // Dòng 2: Nội dung bài viết hoặc URL
            VStack(alignment: .leading, spacing: 3) {
                Text(post.caption.isEmpty ? "(Bài viết không có tiêu đề văn bản)" : post.caption)
                    .font(.subheadline)
                    .foregroundStyle(post.caption.isEmpty ? .secondary : .primary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                    Text(post.postUrl)
                        .font(.caption2)
                        .foregroundStyle(.blue)
                        .lineLimit(1)
                    Spacer()
                    if let synced = post.lastSyncedAt {
                        Text("Cập nhật \(synced.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Dòng 3: Thống kê tương tác dạng Pill gọn đẹp
            HStack(spacing: 8) {
                engagementPill(icon: "hand.thumbsup.fill", color: .pink, text: "\(post.reactionCount) cảm xúc")
                engagementPill(icon: "bubble.left.fill", color: .orange, text: "\(post.commentCount) bình luận")
                engagementPill(icon: "arrowshape.turn.up.right.fill", color: .indigo, text: "\(post.shareCount) chia sẻ")

                Spacer(minLength: 0)

                if post.unrepliedCommentsCount > 0 {
                    Text("\(post.unrepliedCommentsCount) chưa trả lời")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.red, in: Capsule())
                } else if !post.comments.isEmpty {
                    Text("Đã trả lời hết")
                        .font(.caption2.bold())
                        .foregroundStyle(.green)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.12), in: Capsule())
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
                    .buttonStyle(SoftTintedButtonStyle(tint: .purple, isCompact: true))

                    // Nút Gửi trực tiếp
                    Button {
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
                    .buttonStyle(GradientPillButtonStyle(colors: [.blue, .cyan], isCompact: true))
                    .disabled(isSendingQuickReply)
                }
                .padding(.top, 2)
            }

            Divider()

            // Dòng 4: Các Button thao tác được trang trí gọn gàng
            HStack(spacing: 8) {
                // 1. Nút Làm mới thống kê
                Button {
                    Task {
                        await tracker.syncSinglePost(id: post.id, space: space)
                    }
                } label: {
                    HStack(spacing: 4) {
                        if isSyncing {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text("Thống kê")
                    }
                }
                .buttonStyle(SoftTintedButtonStyle(tint: .teal, isCompact: true))
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
                    HStack(spacing: 4) {
                        Image(systemName: "text.bubble.fill")
                        Text("Trả lời nhanh")
                    }
                }
                .buttonStyle(SoftTintedButtonStyle(tint: .blue, isCompact: true))

                // 3. Nút Xem DS Bình luận & Tick chọn trả lời chi tiết
                Button {
                    activeReplyPost = post
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "list.bullet.indent")
                        Text("DS Cmt (\(post.comments.count))")
                    }
                }
                .buttonStyle(SoftTintedButtonStyle(tint: .orange, isCompact: true))

                Spacer(minLength: 0)

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
                    HStack(spacing: 4) {
                        if isAIRunning {
                            ProgressView().tint(.white).controlSize(.mini)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text("AI Reply")
                    }
                }
                .buttonStyle(GradientPillButtonStyle(colors: [.purple, .pink], isCompact: true))
                .disabled(isAIRunning)
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    post.isAIAutoReplySelected ? Color.purple.opacity(0.45) : Color.primary.opacity(0.06),
                    lineWidth: post.isAIAutoReplySelected ? 1.3 : 1.0
                )
        )
        .shadow(color: Color.black.opacity(0.04), radius: 4, x: 0, y: 2)
    }

    private func engagementPill(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(color)
            Text(text)
                .font(.caption2.bold())
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.1), in: Capsule())
    }
}

// MARK: - Sheet 1: Thêm Bài Viết Theo Dõi Bằng URL hoặc ID

struct AddTrackedPostSheet: View {
    let spaces: [Space]
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var tracker = TrackedPostManager.shared

    @State private var urlOrIdInput: String = ""
    @State private var customCaption: String = ""
    @State private var selectedSpaceId: UUID? = nil
    @State private var enableAIAutoReply: Bool = true
    @State private var isAdding: Bool = false
    @State private var errorMessage: String? = nil

    private var chosenSpace: Space? {
        spaces.first(where: { $0.id == selectedSpaceId }) ?? spaces.first
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("1. Đường dẫn (URL) hoặc ID bài viết đã đăng") {
                    HStack {
                        TextField("Dán link bài viết, Reel, Video hoặc Post ID...", text: $urlOrIdInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if !urlOrIdInput.isEmpty {
                            Button {
                                urlOrIdInput = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button("Dán") {
                            if let clip = UIPasteboard.general.string {
                                urlOrIdInput = clip
                            }
                        }
                        .buttonStyle(SoftTintedButtonStyle(tint: .blue, isCompact: true))
                    }

                    TextField("Ghi chú / Nội dung bài viết (tùy chọn cho AI đọc)", text: $customCaption, axis: .vertical)
                        .lineLimit(2...4)
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
                            .foregroundStyle(.purple)
                    }
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
                                Text("Đang phân tích & lấy thống kê...")
                            } else {
                                Image(systemName: "plus.circle.fill")
                                Text("Thêm vào danh sách theo dõi")
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(GradientPillButtonStyle(colors: [.blue, .indigo], isCompact: false))
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
                                .foregroundStyle(.blue)
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
                            .buttonStyle(SoftTintedButtonStyle(tint: .purple, isCompact: true))

                            Button {
                                let unreplied = currentPost.comments
                                    .filter { !currentPost.isCommentHandled($0) }
                                    .map(\.id)
                                tickedCommentIds = Set(unreplied)
                            } label: {
                                Text("Tick chưa trả lời")
                            }
                            .buttonStyle(SoftTintedButtonStyle(tint: .orange, isCompact: true))

                            Spacer()

                            Button {
                                Task {
                                    await tracker.syncSinglePost(id: currentPost.id, space: actingSpace)
                                }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(SoftTintedButtonStyle(tint: .teal, isCompact: true))

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
                            .buttonStyle(GradientPillButtonStyle(colors: [.purple, .pink], isCompact: true))
                        }
                    }
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))

                    if !feedbackBanner.isEmpty {
                        Text(feedbackBanner)
                            .font(.caption.bold())
                            .foregroundStyle(.purple)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.purple.opacity(0.1))
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
                                                .foregroundStyle(isTicked ? .purple : .secondary)
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
                                                        .foregroundStyle(.green)
                                                        .padding(.horizontal, 6)
                                                        .padding(.vertical, 2)
                                                        .background(Color.green.opacity(0.14), in: Capsule())
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
                                        .buttonStyle(SoftTintedButtonStyle(tint: .blue, isCompact: true))
                                    }

                                    if let lastReply = cmt.lastReplyText, !lastReply.isEmpty {
                                        HStack(spacing: 6) {
                                            Image(systemName: "checkmark.bubble.fill")
                                                .font(.caption2)
                                                .foregroundStyle(.green)
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
                                        .foregroundStyle(.blue)
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
                            .buttonStyle(SoftTintedButtonStyle(tint: .purple, isCompact: true))
                            .disabled(isGeneratingAI)

                            // Nút Gửi phản hồi
                            Button {
                                isSending = true
                                let text = directReplyText
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
                            .buttonStyle(GradientPillButtonStyle(colors: [.blue, .indigo], isCompact: true))
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
                    .buttonStyle(GradientPillButtonStyle(colors: [.purple, .indigo], isCompact: false))
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
