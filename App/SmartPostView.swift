import SwiftUI
import Foundation
import UIKit
import PhotosUI

// MARK: - Smart Post Models & Privacy Options

enum SmartPostDestinationType: String, CaseIterable, Identifiable, Codable {
    case personalProfile = "Trang cá nhân"
    case group = "Nhóm (Group)"
    case fanpage = "Trang (Fanpage)"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .personalProfile: return "person.crop.circle.fill"
        case .group: return "person.3.fill"
        case .fanpage: return "flag.fill"
        }
    }

    var shortLabel: String {
        switch self {
        case .personalProfile: return "Cá nhân"
        case .group: return "Nhóm"
        case .fanpage: return "Fanpage"
        }
    }

    var gradientColors: [Color] {
        switch self {
        case .personalProfile: return [.blue, .indigo]
        case .group: return [.teal, .green]
        case .fanpage: return [.orange, .pink]
        }
    }
}

struct FacebookDestinationItem: Identifiable, Codable, Hashable {
    var id: String // Group ID hoặc Page ID
    var name: String
    var kind: SmartPostDestinationType
    var pageAccessToken: String?
    var subtitle: String
    var ownerSpaceId: UUID?
    var ownerSpaceName: String
    var viewerPostStatus: String? = nil
    var memberCount: Int? = nil
    var privacy: String? = nil

    var uniqueSelectionKey: String {
        "\(kind.rawValue)_\(id)_\(ownerSpaceId?.uuidString ?? "manual")"
    }
}

// MARK: - Smart Post Theme Colors (#8FBC8F & Trắng làm chủ đạo)

extension Color {
    static let themePrimary = Color(red: 143/255, green: 188/255, blue: 143/255)
    static let themePrimaryDark = Color(red: 117/255, green: 160/255, blue: 117/255)
    static let themeBackgroundPastel = Color(red: 143/255, green: 188/255, blue: 143/255).opacity(0.14)
}

enum SmartPostPrivacy: String, CaseIterable, Identifiable, Codable {
    case everyone = "Công khai (EVERYONE)"
    case friends = "Bạn bè (FRIENDS)"
    case onlyMe = "Chỉ mình tôi (ONLY_ME)"

    var id: String { rawValue }

    var shortName: String {
        switch self {
        case .everyone: return "Công khai"
        case .friends: return "Bạn bè"
        case .onlyMe: return "Chỉ mình tôi"
        }
    }

    var apiKey: String {
        switch self {
        case .everyone: return "EVERYONE"
        case .friends: return "FRIENDS"
        case .onlyMe: return "ONLY_ME"
        }
    }

    var privacyId: String {
        switch self {
        case .everyone: return "300645083384735"
        case .friends: return "291667064279714"
        case .onlyMe: return "286958161406148"
        }
    }

    var icon: String {
        switch self {
        case .everyone: return "globe.asia.australia.fill"
        case .friends: return "person.2.fill"
        case .onlyMe: return "lock.fill"
        }
    }
}

struct SmartPostResult: Identifiable, Codable {
    var id: UUID = UUID()
    let spaceName: String
    let isSuccess: Bool
    let postId: String?
    let postUrl: String?
    let message: String
}

// MARK: - Scheduled Post Models

enum ScheduledTaskStatus: String, Codable {
    case pending = "Chờ đăng"
    case running = "Đang chạy"
    case completed = "Hoàn thành"
    case partial = "Thành công 1 phần"
    case failed = "Thất bại"

    var badgeColor: Color {
        switch self {
        case .pending: return .blue
        case .running: return .orange
        case .completed: return Color.themePrimary
        case .partial: return Color.themePrimary
        case .failed: return .red
        }
    }
}

struct ScheduledPostTask: Identifiable, Codable {
    var id: UUID = UUID()
    var title: String
    var caption: String
    var targetSpaceIds: [UUID]
    var privacy: SmartPostPrivacy
    var destinationType: SmartPostDestinationType? = .personalProfile
    var targetDestinations: [FacebookDestinationItem]? = []
    var scheduledDate: Date
    var status: ScheduledTaskStatus
    var imageFileNames: [String]
    var videoFileName: String?
    var createdAt: Date = Date()
    var executionLog: String?
    var autoReact: Bool? = false
    var reactionType: String? = "LIKE"
    var reactionRate: Double? = 100.0
    var firstComment: String? = nil
}

// MARK: - Scheduled Post Storage Manager

@MainActor
final class ScheduledPostManager: ObservableObject {
    static let shared = ScheduledPostManager()

    @Published var tasks: [ScheduledPostTask] = []
    private let storageKey = "vie.smartpost.scheduled_tasks.v1"
    private var timer: Timer?

    init() {
        loadTasks()
        startScheduler()
    }

    func loadTasks() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([ScheduledPostTask].self, from: data) {
            self.tasks = decoded
        }
    }

    func saveTasks() {
        if let data = try? JSONEncoder().encode(tasks) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    func addTask(
        caption: String,
        spaceIds: [UUID],
        privacy: SmartPostPrivacy,
        destinationType: SmartPostDestinationType = .personalProfile,
        targetDestinations: [FacebookDestinationItem] = [],
        scheduledDate: Date,
        images: [UIImage],
        videoData: Data?,
        autoReact: Bool = false,
        reactionType: String = "LIKE",
        reactionRate: Double = 100.0,
        firstComment: String? = nil
    ) {
        var savedImageNames: [String] = []
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

        for img in images {
            let name = "sp_img_\(UUID().uuidString).jpg"
            if let data = img.jpegData(compressionQuality: 0.85) {
                let fileURL = documentsDir.appendingPathComponent(name)
                try? data.write(to: fileURL)
                savedImageNames.append(name)
            }
        }

        var savedVideoName: String? = nil
        if let vdata = videoData {
            let name = "sp_vid_\(UUID().uuidString).mp4"
            let fileURL = documentsDir.appendingPathComponent(name)
            try? vdata.write(to: fileURL)
            savedVideoName = name
        }

        let baseTitle = caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (savedVideoName != nil ? "Video bài đăng" : "\(savedImageNames.count) Ảnh bài đăng")
            : String(caption.prefix(36))
        let title = "[\(destinationType.shortLabel)] \(baseTitle)"

        let newTask = ScheduledPostTask(
            title: title,
            caption: caption,
            targetSpaceIds: spaceIds,
            privacy: privacy,
            destinationType: destinationType,
            targetDestinations: targetDestinations,
            scheduledDate: scheduledDate,
            status: .pending,
            imageFileNames: savedImageNames,
            videoFileName: savedVideoName,
            autoReact: autoReact,
            reactionType: reactionType,
            reactionRate: reactionRate,
            firstComment: firstComment
        )

        tasks.append(newTask)
        saveTasks()
    }

    func updateTask(_ task: ScheduledPostTask) {
        guard let idx = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[idx] = task
        saveTasks()
    }

    func retryTask(_ task: ScheduledPostTask) {
        guard let idx = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[idx].status = .pending
        tasks[idx].scheduledDate = Date()
        tasks[idx].executionLog = "Đang chuẩn bị thử lại bài đăng..."
        saveTasks()
        Task {
            await checkAndExecuteDueTasks()
        }
    }

    func deleteTask(_ task: ScheduledPostTask) {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for name in task.imageFileNames {
            try? FileManager.default.removeItem(at: documentsDir.appendingPathComponent(name))
        }
        if let vname = task.videoFileName {
            try? FileManager.default.removeItem(at: documentsDir.appendingPathComponent(vname))
        }
        tasks.removeAll { $0.id == task.id }
        saveTasks()
    }

    private func startScheduler() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkAndExecuteDueTasks()
            }
        }
    }

    func checkAndExecuteDueTasks() async {
        let now = Date()
        for idx in tasks.indices {
            let task = tasks[idx]
            if task.status == .pending && task.scheduledDate <= now {
                tasks[idx].status = .running
                saveTasks()

                let resultLog = await executeTask(task)
                if resultLog.successCount == resultLog.totalCount && resultLog.totalCount > 0 {
                    tasks[idx].status = .completed
                } else if resultLog.successCount > 0 {
                    tasks[idx].status = .partial
                } else {
                    tasks[idx].status = .failed
                }
                tasks[idx].executionLog = resultLog.summary
                saveTasks()
            }
        }
    }

    private func executeTask(_ task: ScheduledPostTask) async -> (successCount: Int, totalCount: Int, summary: String) {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var loadedImages: [UIImage] = []
        for name in task.imageFileNames {
            let fileURL = documentsDir.appendingPathComponent(name)
            if let data = try? Data(contentsOf: fileURL), let img = UIImage(data: data) {
                loadedImages.append(img)
            }
        }

        var loadedVideoData: Data? = nil
        if let vname = task.videoFileName {
            let fileURL = documentsDir.appendingPathComponent(vname)
            loadedVideoData = try? Data(contentsOf: fileURL)
        }

        var successCount = 0
        var totalCount = 0
        var logs: [String] = []
        let destType = task.destinationType ?? .personalProfile
        let destinations = task.targetDestinations ?? []

        for sid in task.targetSpaceIds {
            guard let vault = try? SecureLoginStore.readTokenVault(sid) else {
                totalCount += 1
                logs.append("Chưa có thông tin đăng nhập cho không gian ID: \(sid)")
                continue
            }
            guard let token = SmartPostAPIClient.resolveBestAccessToken(from: vault), !token.isEmpty else {
                totalCount += 1
                logs.append("Không tìm thấy Access Token hợp lệ cho không gian \(vault.uid.isEmpty ? sid.uuidString : vault.uid). Vui lòng vào 'Kho Token' kết nối lại tài khoản.")
                continue
            }

            let uid = vault.uid.isEmpty ? "me" : vault.uid
            let accountDisplayName = vault.uid.isEmpty ? "Tài khoản FB" : "FB • \(vault.uid)"

            // Kiểm tra tính hợp lệ của Token trước khi thực hiện tải ảnh
            let tokenValidation = await SmartPostAPIClient.validateAccessToken(token)
            if !tokenValidation.isValid {
                totalCount += 1
                let cleanErr = SmartPostAPIClient.formatFacebookAPIError(tokenValidation.message)
                logs.append("❌ [\(accountDisplayName)] Access Token không hợp lệ (\(cleanErr)). Vui lòng vào 'Kho Token' kiểm tra hoặc kết nối lại.")
                continue
            }

            if destType == .personalProfile || destinations.isEmpty {
                totalCount += 1
                do {
                    if let vdata = loadedVideoData {
                        let vid = try await SmartPostAPIClient.uploadVideo(videoData: vdata, caption: task.caption, accessToken: token, userId: uid)
                        successCount += 1
                        logs.append("✅ Đăng video cá nhân thành công ID: \(vid)")
                        TrackedPostManager.shared.registerPublishedPost(
                            spaceId: sid,
                            spaceName: accountDisplayName,
                            postId: vid,
                            postUrl: "https://www.facebook.com/watch/?v=\(vid)",
                            caption: task.caption,
                            enableAIAutoReply: true
                        )

                        // Thả cảm xúc & bình luận đầu tiên
                        await triggerPostReactionAndComment(postId: vid, task: task, token: token, logs: &logs)
                    } else {
                        var pids: [String] = []
                        for img in loadedImages {
                            if let jdata = img.jpegData(compressionQuality: 0.85) {
                                let pid = try await SmartPostAPIClient.uploadPhoto(imageData: jdata, accessToken: token, targetId: "me")
                                pids.append(pid)
                            }
                        }
                        let res = try await SmartPostAPIClient.createPost(caption: task.caption, photoIds: pids, privacy: task.privacy, destinationType: .personalProfile, accessToken: token, userId: uid)
                        successCount += 1
                        logs.append("✅ Đăng bài cá nhân thành công ID: \(res.postId)")
                        TrackedPostManager.shared.registerPublishedPost(
                            spaceId: sid,
                            spaceName: accountDisplayName,
                            postId: res.postId,
                            postUrl: res.postUrl,
                            caption: task.caption,
                            enableAIAutoReply: true
                        )

                        // Thả cảm xúc & bình luận đầu tiên
                        await triggerPostReactionAndComment(postId: res.postId, task: task, token: token, logs: &logs)
                    }
                } catch {
                    let cleanErr = SmartPostAPIClient.formatFacebookAPIError(error.localizedDescription)
                    logs.append("❌ Lỗi: \(cleanErr)")
                }
            } else {
                let matchingDests = destinations.filter { $0.ownerSpaceId == nil || $0.ownerSpaceId == sid }
                for dest in matchingDests {
                    totalCount += 1
                    let effectiveToken = (destType == .fanpage ? dest.pageAccessToken : nil) ?? token
                    let uploadTarget = destType == .fanpage ? dest.id : "me"
                    let videoTarget = dest.id
                    let displayLabel = "\(accountDisplayName) → \(dest.name)"
                    do {
                        if let vdata = loadedVideoData {
                            let vid = try await SmartPostAPIClient.uploadVideo(videoData: vdata, caption: task.caption, accessToken: effectiveToken, userId: videoTarget)
                            successCount += 1
                            logs.append("✅ [\(dest.name)] Đăng video thành công ID: \(vid)")
                            TrackedPostManager.shared.registerPublishedPost(
                                spaceId: sid,
                                spaceName: displayLabel,
                                postId: vid,
                                postUrl: "https://www.facebook.com/watch/?v=\(vid)",
                                caption: task.caption,
                                enableAIAutoReply: true
                            )

                            // Thả cảm xúc & bình luận đầu tiên
                            await triggerPostReactionAndComment(postId: vid, task: task, token: effectiveToken, logs: &logs)
                        } else {
                            var pids: [String] = []
                            for img in loadedImages {
                                if let jdata = img.jpegData(compressionQuality: 0.85) {
                                    let pid = try await SmartPostAPIClient.uploadPhoto(imageData: jdata, accessToken: effectiveToken, targetId: uploadTarget)
                                    pids.append(pid)
                                }
                            }
                            let res = try await SmartPostAPIClient.createPost(
                                caption: task.caption,
                                photoIds: pids,
                                privacy: task.privacy,
                                destinationType: destType,
                                targetDestinationId: dest.id,
                                pageAccessToken: dest.pageAccessToken,
                                accessToken: token,
                                userId: uid
                            )
                            successCount += 1
                            logs.append("✅ [\(dest.name)] Đăng bài thành công ID: \(res.postId)")
                            TrackedPostManager.shared.registerPublishedPost(
                                spaceId: sid,
                                spaceName: displayLabel,
                                postId: res.postId,
                                postUrl: res.postUrl,
                                caption: task.caption,
                                enableAIAutoReply: true
                            )

                            // Thả cảm xúc & bình luận đầu tiên
                            await triggerPostReactionAndComment(postId: res.postId, task: task, token: effectiveToken, logs: &logs)
                        }
                    } catch {
                        let cleanErr = SmartPostAPIClient.formatFacebookAPIError(error.localizedDescription)
                        logs.append("❌ [\(dest.name)] Lỗi: \(cleanErr)")
                    }
                }
            }
        }

        let df = DateFormatter()
        df.dateFormat = "dd/MM/yyyy, HH:mm"
        let timestamp = df.string(from: Date())
        let statusText = successCount == totalCount ? "Hoàn thành" : (successCount > 0 ? "Thành công \(successCount)/\(totalCount)" : "Thất bại")
        let summary = "Kết quả: \(successCount)/\(totalCount) thành công (\(statusText)) lúc \(timestamp)\n" + logs.joined(separator: "\n")
        return (successCount: successCount, totalCount: totalCount, summary: summary)
    }

    private func triggerPostReactionAndComment(
        postId: String,
        task: ScheduledPostTask,
        token: String,
        logs: inout [String]
    ) async {
        // 1. Thả Reaction theo tỷ lệ %
        if task.autoReact == true {
            let rate = task.reactionRate ?? 100.0
            let roll = Double.random(in: 0...100)
            if roll <= rate {
                let rType = FacebookReactionType(rawValue: task.reactionType ?? "LIKE") ?? .like
                let reactRes = await SmartPostAPIClient.reactToPost(postId: postId, reaction: rType, accessToken: token)
                if reactRes.success {
                    logs.append("👍 Đã thả cảm xúc \(rType.displayName) (\(Int(rate))%)")
                }
            }
        }

        // 2. Gắn bình luận đầu tiên
        if let fc = task.firstComment?.trimmingCharacters(in: .whitespacesAndNewlines), !fc.isEmpty {
            let cmtRes = await SmartPostAPIClient.commentOnPost(postId: postId, commentText: fc, accessToken: token)
            if cmtRes.success {
                logs.append("💬 Đã gắn bình luận đầu tiên: \"\(fc)\"")
            }
        }
    }
}


extension FacebookReactionType {
    var displayName: String { label }
}

// MARK: - Smart Post API Engine

enum SmartPostAPIClient {
    private static let fbHeaders: [String: String] = [
        "User-Agent": "[FBAN/FB4A;FBAV/522.0.0.52.96;FBBV/763259015;FBDM/{density=1.5,width=540,height=960};FBLC/vi_VN;FBRV/0;FBCR/MobiFone;FBMF/Honor;FBBD/Honor;FBPN/com.facebook.katana;FBDV/BVL-AN00;FBSV/9;FBOP/1;FBCA/x86_64:arm64-v8a;]",
        "x-tigon-is-retry": "False",
        "x-fb-device-group": "3595",
        "x-zero-eh": "2,,ATY5qyn5pgi0LPFxwgj-nj0AQ_Kv6eqmdL2VIGqwb4BIQOtJlgLIT3SqrGnRwEFhqVI",
        "x-fb-connection-type": "WIFI",
        "app-scope-id-header": "d0db7ed7-f05d-4ab4-a34b-27ea5eb599f1",
        "x-fb-sim-hni": "45201",
        "x-fb-net-hni": "45201",
        "x-zero-f-device-id": "d0db7ed7-f05d-4ab4-a34b-27ea5eb599f1",
        "priority": "u=3, i",
        "x-fb-connection-quality": "EXCELLENT",
        "x-fb-http-engine": "Tigon/Liger",
        "x-fb-client-ip": "True",
        "x-fb-server-cluster": "True"
    ]

    /// Thả Reaction vào bài viết Facebook qua Graph API
    static func reactToPost(
        postId: String,
        reaction: FacebookReactionType,
        accessToken: String
    ) async -> (success: Bool, message: String) {
        let cleanToken = cleanAccessToken(accessToken)
        guard !cleanToken.isEmpty else { return (false, "Token rỗng") }
        let reactionValue: String = {
            switch reaction {
            case .like: return "LIKE"
            case .love: return "LOVE"
            case .care: return "CARE"
            case .haha: return "HAHA"
            case .wow: return "WOW"
            case .sad: return "SAD"
            case .anger: return "ANGRY"
            case .random, .geminiAuto:
                return ["LIKE", "LOVE", "CARE", "HAHA", "WOW"].randomElement() ?? "LIKE"
            }
        }()

        let cleanPostId = postId.components(separatedBy: "_").last ?? postId
        let targets = [postId, cleanPostId]
        let endpoints = [
            "https://graph.facebook.com",
            "https://b-graph.facebook.com"
        ]

        for base in endpoints {
            for target in targets {
                guard let url = URL(string: "\(base)/\(target)/reactions") else { continue }
                var req = URLRequest(url: url, timeoutInterval: 12)
                req.httpMethod = "POST"
                req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                req.setValue("OAuth \(cleanToken)", forHTTPHeaderField: "authorization")
                for (k, v) in fbHeaders { req.setValue(v, forHTTPHeaderField: k) }
                req.httpBody = "type=\(reactionValue)".data(using: .utf8)
                if let (_, resp) = try? await URLSession.shared.data(for: req),
                   let http = resp as? HTTPURLResponse, (http.statusCode == 200 || http.statusCode == 201) {
                    return (true, "Thả cảm xúc \(reaction.displayName) thành công")
                }
            }
        }
        return (false, "Không thể thả cảm xúc")
    }

    private static var activeCommentLock = Set<String>()
    private static let commentLockQueue = DispatchQueue(label: "vie.smartpost.comment.lock")

    /// Đăng bình luận đầu tiên vào bài viết Facebook qua Graph API (có cơ chế chống gửi double/lặp)
    static func commentOnPost(
        postId: String,
        commentText: String,
        accessToken: String,
        proxy: SpaceProxy? = nil
    ) async -> (success: Bool, message: String) {
        let cleanText = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return (false, "Nội dung rỗng") }
        let cleanToken = cleanAccessToken(accessToken)
        guard !cleanToken.isEmpty else { return (false, "Token rỗng") }

        let cleanPostId = postId.components(separatedBy: "_").last ?? postId
        let lockKey = "\(cleanPostId)_\(cleanText.hashValue)"

        // Chống gửi trùng/double trong cùng một thời điểm
        let canProceed = commentLockQueue.sync { () -> Bool in
            if activeCommentLock.contains(lockKey) { return false }
            activeCommentLock.insert(lockKey)
            return true
        }
        guard canProceed else {
            return (true, "Bình luận đang được xử lý, đã chặn gửi lặp.")
        }
        defer {
            _ = commentLockQueue.sync {
                activeCommentLock.remove(lockKey)
            }
        }

        let config = URLSessionConfiguration.default
        if let proxy, proxy.isEnabled {
            config.proxyConfigurations = [proxy.toNetworkProxyConfiguration()]
        }
        let session = URLSession(configuration: config)

        // Ưu tiên clean numeric post ID trước, chỉ thử postId gốc nếu khác biệt
        let targets: [String] = (cleanPostId != postId) ? [cleanPostId, postId] : [cleanPostId]
        let endpoints = [
            "https://graph.facebook.com",
            "https://b-graph.facebook.com"
        ]

        let allowed = CharacterSet.alphanumerics
        let encMsg = cleanText.addingPercentEncoding(withAllowedCharacters: allowed) ?? cleanText
        let encTok = cleanToken.addingPercentEncoding(withAllowedCharacters: allowed) ?? cleanToken
        let postBody = "message=\(encMsg)&access_token=\(encTok)".data(using: .utf8)

        for target in targets {
            for base in endpoints {
                guard let url = URL(string: "\(base)/\(target)/comments") else { continue }
                var req = URLRequest(url: url, timeoutInterval: 15)
                req.httpMethod = "POST"
                req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                req.setValue("OAuth \(cleanToken)", forHTTPHeaderField: "authorization")
                for (k, v) in fbHeaders { req.setValue(v, forHTTPHeaderField: k) }
                req.httpBody = postBody

                if let (data, resp) = try? await session.data(for: req),
                   let http = resp as? HTTPURLResponse {
                    // Nếu status 200...299 thì Facebook đã tiếp nhận và tạo bình luận thành công!
                    // Dừng ngay lập tức để không bị double comment trên Facebook
                    if (200...299).contains(http.statusCode) {
                        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                        let cid = (json?["id"] as? String) ?? (json?["id"] as? Int).map(String.init) ?? "ok"
                        return (true, "Đã bình luận ID: \(cid)")
                    }
                }
            }
        }
        return (false, "Không thể bình luận qua Graph API")
    }

    /// Lấy danh sách Trang (Fanpage) do tài khoản quản trị (kèm Page Access Token riêng)
    static func fetchManagedPages(
        accessToken: String,
        spaceId: UUID,
        spaceName: String
    ) async -> [FacebookDestinationItem] {
        var items: [FacebookDestinationItem] = []
        var seenIds = Set<String>()
        let cleanToken = cleanAccessToken(accessToken)
        guard !cleanToken.isEmpty else { return items }

        let pageEndpoints = [
            "https://b-graph.facebook.com/me/accounts?fields=id,name,access_token,category&limit=200",
            "https://graph.facebook.com/v19.0/me/accounts?fields=id,name,access_token,category&limit=200",
            "https://graph.facebook.com/me/accounts?fields=id,name,access_token,category&limit=200"
        ]

        for ep in pageEndpoints {
            guard let url = URL(string: ep) else { continue }
            var request = URLRequest(url: url, timeoutInterval: 18)
            request.httpMethod = "GET"
            for (k, v) in fbHeaders { request.setValue(v, forHTTPHeaderField: k) }
            request.setValue("OAuth \(cleanToken)", forHTTPHeaderField: "authorization")

            if let (data, _) = try? await URLSession.shared.data(for: request),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataArr = json["data"] as? [[String: Any]], !dataArr.isEmpty {
                for row in dataArr {
                    guard let id = row["id"] as? String, !id.isEmpty, !seenIds.contains(id) else { continue }
                    seenIds.insert(id)
                    let name = (row["name"] as? String) ?? "Fanpage \(id)"
                    let pageToken = row["access_token"] as? String
                    let category = (row["category"] as? String) ?? "Trang Fanpage"
                    items.append(FacebookDestinationItem(
                        id: id,
                        name: name,
                        kind: .fanpage,
                        pageAccessToken: pageToken,
                        subtitle: "\(category) • \(spaceName)",
                        ownerSpaceId: spaceId,
                        ownerSpaceName: spaceName
                    ))
                }
                if !items.isEmpty {
                    break
                }
            }
        }
        return items
    }

    final class StopRedirectDelegate: NSObject, URLSessionTaskDelegate {
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

    /// Lấy access_token từ Ads Manager bằng Cookie theo đúng quy trình của 1769064737-GetGroupUid.py
    static func fetchAdsManagerAccessToken(cookieString: String) async -> String? {
        let trimmed = cookieString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let delegate = StopRedirectDelegate()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        var currentUrl = URL(string: "https://adsmanager.facebook.com/adsmanager/manage/campaigns")
        var redirectCount = 0
        let maxRedirects = 2

        while let url = currentUrl, redirectCount <= maxRedirects {
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.setValue(trimmed, forHTTPHeaderField: "Cookie")
            req.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
            req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7", forHTTPHeaderField: "Accept")
            req.setValue("gzip, deflate, br, zstd", forHTTPHeaderField: "Accept-Encoding")
            req.setValue("vi-VN,vi;q=0.9,fr-FR;q=0.8,fr;q=0.7,en-US;q=0.6,en;q=0.5", forHTTPHeaderField: "Accept-Language")
            req.setValue("\"Google Chrome\";v=\"143\", \"Chromium\";v=\"143\", \"Not A(Brand\";v=\"24\"", forHTTPHeaderField: "sec-ch-ua")
            req.setValue("?0", forHTTPHeaderField: "sec-ch-ua-mobile")
            req.setValue("\"Windows\"", forHTTPHeaderField: "sec-ch-ua-platform")
            req.setValue("1", forHTTPHeaderField: "upgrade-insecure-requests")
            req.setValue("none", forHTTPHeaderField: "sec-fetch-site")
            req.setValue("navigate", forHTTPHeaderField: "sec-fetch-mode")
            req.setValue("?1", forHTTPHeaderField: "sec-fetch-user")
            req.setValue("document", forHTTPHeaderField: "sec-fetch-dest")
            req.setValue("u=0, i", forHTTPHeaderField: "priority")

            guard let (data, resp) = try? await session.data(for: req),
                  let http = resp as? HTTPURLResponse else {
                break
            }

            let bodyStr = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
            if let tok = FacebookTargetPostResolver.firstMatch(pattern: #"window\.__accessToken\s*=\s*\"([^\"]+)\""#, in: bodyStr)
                ?? FacebookTargetPostResolver.firstMatch(pattern: #"\"accessToken\"\s*:\s*\"(EAA[A-Za-z0-9_\-\|=]{20,500})\""#, in: bodyStr) {
                if !tok.isEmpty { return tok }
            }

            if [301, 302, 303, 307, 308].contains(http.statusCode), redirectCount < maxRedirects {
                redirectCount += 1
                if let loc = http.value(forHTTPHeaderField: "Location") ?? http.value(forHTTPHeaderField: "location"),
                   let next = URL(string: loc, relativeTo: url)?.absoluteURL {
                    currentUrl = next
                    continue
                }
            }
            break
        }
        return nil
    }

    /// Truy vấn danh sách Nhóm đã tham gia qua GraphQL endpoint theo 1769064737-GetGroupUid.py
    static func queryGraphQLGroups(
        query: String,
        token: String,
        cookieString: String?,
        spaceId: UUID,
        spaceName: String,
        seenIds: inout Set<String>
    ) async -> [FacebookDestinationItem]? {
        guard let url = URL(string: "https://graph.facebook.com/graphql") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        req.setValue("https://graph.facebook.com", forHTTPHeaderField: "Origin")
        req.setValue("https://graph.facebook.com", forHTTPHeaderField: "Referer")
        req.setValue("same-origin", forHTTPHeaderField: "sec-fetch-site")
        req.setValue("cors", forHTTPHeaderField: "sec-fetch-mode")
        req.setValue("empty", forHTTPHeaderField: "sec-fetch-dest")
        req.setValue("u=1, i", forHTTPHeaderField: "priority")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        if let c = cookieString, !c.isEmpty {
            req.setValue(c, forHTTPHeaderField: "Cookie")
        }

        let postBody = [
            "q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)",
            "access_token=\(token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? token)"
        ].joined(separator: "&")
        req.httpBody = Data(postBody.utf8)

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode != 404,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let err = json["error"] as? [String: Any], let code = err["code"] as? Int, code == 190 {
            return nil
        }

        var groupNodes: [[String: Any]] = []
        if let dataDict = json["data"] as? [String: Any] {
            if let groupsDict = dataDict["groups"] as? [String: Any],
               let nodes = groupsDict["nodes"] as? [[String: Any]] {
                groupNodes = nodes
            } else {
                for (_, val) in dataDict {
                    if let dict = val as? [String: Any],
                       let groupsDict = dict["groups"] as? [String: Any],
                       let nodes = groupsDict["nodes"] as? [[String: Any]] {
                        groupNodes = nodes
                        break
                    }
                }
            }
        } else {
            for (_, val) in json {
                if let dict = val as? [String: Any],
                   let groupsDict = dict["groups"] as? [String: Any],
                   let nodes = groupsDict["nodes"] as? [[String: Any]] {
                    groupNodes = nodes
                    break
                }
            }
        }

        var results: [FacebookDestinationItem] = []
        for node in groupNodes {
            guard let id = node["id"] as? String, !id.isEmpty, !seenIds.contains(id) else { continue }
            seenIds.insert(id)
            let name = (node["name"] as? String) ?? "Nhóm \(id)"
            let status = (node["viewer_post_status"] as? String) ?? ""
            let visibility = (node["visibility"] as? String) ?? "GROUP"
            let count = (node["group_member_profiles"] as? [String: Any])?["count"] as? Int ?? 0

            let postStatusText = (status == "CAN_POST_DIRECTLY") ? "Đăng trực tiếp" : (status.isEmpty ? "" : "Cần duyệt")
            var parts: [String] = []
            if !postStatusText.isEmpty { parts.append(postStatusText) }
            if count > 0 { parts.append("\(count) TV") }
            if !visibility.isEmpty { parts.append(visibility) }
            parts.append(spaceName)
            let sub = parts.joined(separator: " • ")

            results.append(FacebookDestinationItem(
                id: id,
                name: name,
                kind: .group,
                pageAccessToken: nil,
                subtitle: sub,
                ownerSpaceId: spaceId,
                ownerSpaceName: spaceName,
                viewerPostStatus: status,
                memberCount: count,
                privacy: visibility
            ))
        }
        return results
    }

    /// Lấy danh sách Nhóm (Group) mà tài khoản đã tham gia hoặc quản trị
    static func fetchJoinedGroups(
        accessToken: String,
        cookieString: String?,
        userId: String? = nil,
        spaceId: UUID,
        spaceName: String
    ) async -> [FacebookDestinationItem] {
        var items: [FacebookDestinationItem] = []
        var seenIds = Set<String>()
        var effectiveToken = cleanAccessToken(accessToken)

        // 1. Dò tìm UID tài khoản
        var effectiveUid = userId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if effectiveUid.isEmpty, let c = cookieString {
            effectiveUid = FacebookTargetPostResolver.firstMatch(pattern: #"c_user=(\d+)"#, in: c) ?? ""
        }
        if effectiveUid.isEmpty {
            if let vault = try? SecureLoginStore.readTokenVault(spaceId), !vault.uid.isEmpty {
                effectiveUid = vault.uid
            }
        }

        // 2. Chuẩn bị token Ads Manager (theo 1769064737-GetGroupUid.py)
        if let cookie = cookieString, !cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if effectiveToken.isEmpty || !effectiveToken.hasPrefix("EAAB") {
                if let adsTok = await fetchAdsManagerAccessToken(cookieString: cookie) {
                    effectiveToken = adsTok
                    Task.detached {
                        if var vault = try? SecureLoginStore.readTokenVault(spaceId) {
                            vault.convertedTokens["ADS_MANAGER_WEB"] = ConvertedTokenRecord(
                                appKey: "ADS_MANAGER_WEB",
                                appName: "Ads Manager Web",
                                appId: "438142079694454",
                                tokenPrefix: FacebookAppTokens.extractTokenPrefix(adsTok),
                                accessToken: adsTok,
                                cookieString: cookie,
                                cookies: []
                            )
                            if vault.originalToken.isEmpty { vault.originalToken = adsTok }
                            try? SecureLoginStore.saveTokenVault(vault, for: spaceId)
                        }
                    }
                }
            }
        }

        // 3. TẦNG 1: Truy vấn GraphQL chính xác theo 1769064737-GetGroupUid.py
        if !effectiveToken.isEmpty {
            let queriesToTry: [String] = {
                if !effectiveUid.isEmpty {
                    return [
                        "nodes(\(effectiveUid)){groups{nodes{id,name,viewer_post_status,visibility,group_member_profiles{count}}}}",
                        "me(){groups{nodes{id,name,viewer_post_status,visibility,group_member_profiles{count}}}}"
                    ]
                }
                return ["me(){groups{nodes{id,name,viewer_post_status,visibility,group_member_profiles{count}}}}"]
            }()

            for q in queriesToTry {
                if let gqlResults = await queryGraphQLGroups(
                    query: q,
                    token: effectiveToken,
                    cookieString: cookieString,
                    spaceId: spaceId,
                    spaceName: spaceName,
                    seenIds: &seenIds
                ) {
                    if !gqlResults.isEmpty {
                        items.append(contentsOf: gqlResults)
                        break
                    }
                } else if let cookie = cookieString, !cookie.isEmpty {
                    if let freshTok = await fetchAdsManagerAccessToken(cookieString: cookie) {
                        effectiveToken = freshTok
                        if let retryResults = await queryGraphQLGroups(
                            query: q,
                            token: freshTok,
                            cookieString: cookieString,
                            spaceId: spaceId,
                            spaceName: spaceName,
                            seenIds: &seenIds
                        ), !retryResults.isEmpty {
                            items.append(contentsOf: retryResults)
                            break
                        }
                    }
                }
            }
        }

        if !items.isEmpty { return items }

        // 4. TẦNG 2: Fallback qua các endpoint Graph API cũ
        let graphURLs = [
            "https://b-graph.facebook.com/me/groups?fields=id,name,privacy,administrator,icon&limit=200",
            "https://graph.facebook.com/v19.0/me/groups?fields=id,name,privacy,administrator,icon&limit=200",
            "https://graph.facebook.com/me/groups?fields=id,name,privacy,administrator&limit=200"
        ]

        for urlStr in graphURLs {
            guard let url = URL(string: urlStr) else { continue }
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.httpMethod = "GET"
            for (k, v) in fbHeaders { request.setValue(v, forHTTPHeaderField: k) }
            if !effectiveToken.isEmpty {
                request.setValue("OAuth \(effectiveToken)", forHTTPHeaderField: "authorization")
            }
            if let c = cookieString, !c.isEmpty {
                request.setValue(c, forHTTPHeaderField: "Cookie")
            }

            if let (data, _) = try? await URLSession.shared.data(for: request),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataArr = json["data"] as? [[String: Any]], !dataArr.isEmpty {
                for row in dataArr {
                    guard let id = row["id"] as? String, !id.isEmpty, !seenIds.contains(id) else { continue }
                    seenIds.insert(id)
                    let name = (row["name"] as? String) ?? "Nhóm \(id)"
                    let privacy = (row["privacy"] as? String) ?? "GROUP"
                    let isAdmin = (row["administrator"] as? Bool) == true
                    items.append(FacebookDestinationItem(
                        id: id,
                        name: name,
                        kind: .group,
                        pageAccessToken: nil,
                        subtitle: "\(isAdmin ? "Quản trị viên • " : "")\(privacy) • \(spaceName)",
                        ownerSpaceId: spaceId,
                        ownerSpaceName: spaceName,
                        privacy: privacy
                    ))
                }
                if !items.isEmpty {
                    break
                }
            }
        }

        // 5. TẦNG 3: Nếu Graph API rỗng, quét qua Mobile/Web bằng Cookie
        if items.isEmpty, let cookie = cookieString, !cookie.isEmpty {
            let groupListURLs = [
                "https://www.facebook.com/groups/joins/",
                "https://m.facebook.com/groups/joins/?seemore",
                "https://m.facebook.com/groups_browse/your_groups/",
                "https://m.facebook.com/groups/?seemore"
            ]
            for rawUrl in groupListURLs {
                guard let gUrl = URL(string: rawUrl) else { continue }
                var req = URLRequest(url: gUrl, timeoutInterval: 15)
                req.setValue(cookie, forHTTPHeaderField: "Cookie")
                req.setValue(cookie, forHTTPHeaderField: "cookie")
                req.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
                guard let (data, _) = try? await URLSession.shared.data(for: req),
                      let html = String(data: data, encoding: .utf8) else { continue }

                // Bắt pattern 1: "Group", [ ],"id":"123","name":"ABC"
                if let regex = try? NSRegularExpression(pattern: #"\"Group\"[^\}]{0,150}\"id\"\s*:\s*\"(\d{5,25})\"[^\}]{0,200}\"name\"\s*:\s*\"([^\"]+)\""#) {
                    let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
                    for match in regex.matches(in: html, range: nsRange) {
                        if let idRange = Range(match.range(at: 1), in: html),
                           let nameRange = Range(match.range(at: 2), in: html) {
                            let gid = String(html[idRange])
                            guard !seenIds.contains(gid) else { continue }
                            seenIds.insert(gid)
                            let rawName = String(html[nameRange])
                            let decodedName = FacebookTargetPostResolver.decodeJSONEscapes(rawName)
                            items.append(FacebookDestinationItem(
                                id: gid,
                                name: decodedName.isEmpty ? "Nhóm \(gid)" : decodedName,
                                kind: .group,
                                pageAccessToken: nil,
                                subtitle: "Nhóm đã tham gia • \(spaceName)",
                                ownerSpaceId: spaceId,
                                ownerSpaceName: spaceName
                            ))
                        }
                    }
                }

                // Bắt pattern 2: href="/groups/123456789..."
                if let aRegex = try? NSRegularExpression(pattern: #"href=[\"']/groups/(\d{5,25})[^\"']*[\"'][^>]*>([^<]{2,120})<"#) {
                    let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
                    for match in aRegex.matches(in: html, range: nsRange) {
                        if let idRange = Range(match.range(at: 1), in: html),
                           let nameRange = Range(match.range(at: 2), in: html) {
                            let gid = String(html[idRange])
                            guard !seenIds.contains(gid) else { continue }
                            seenIds.insert(gid)
                            let rawName = String(html[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                            let decodedName = FacebookTargetPostResolver.decodeJSONEscapes(rawName)
                            if !decodedName.isEmpty && !decodedName.contains("http") && decodedName.count > 1 {
                                items.append(FacebookDestinationItem(
                                    id: gid,
                                    name: decodedName,
                                    kind: .group,
                                    pageAccessToken: nil,
                                    subtitle: "Nhóm đã tham gia • \(spaceName)",
                                    ownerSpaceId: spaceId,
                                    ownerSpaceName: spaceName
                                ))
                            }
                        }
                    }
                }
                if !items.isEmpty {
                    break
                }
            }
        }
        return items
    }

    /// Chuyển đổi URL Nhóm / URL Fanpage (kể cả link rút gọn share/g/..., share/..., username) sang ID chuẩn & lấy tên
    // MARK: - Token Helpers & Error Formatter

    static func cleanAccessToken(_ raw: String) -> String {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.lowercased().hasPrefix("bearer ") {
            cleaned = String(cleaned.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if cleaned.lowercased().hasPrefix("oauth ") {
            cleaned = String(cleaned.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"") && cleaned.count > 2 {
            cleaned = String(cleaned.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }

    static func resolveBestAccessToken(from vault: SpaceTokenVault) -> String? {
        let orig = cleanAccessToken(vault.originalToken)
        if (orig.hasPrefix("EAA") || orig.contains("|")) && orig.count >= 20 {
            return orig
        }
        if let fb = vault.convertedTokens["FB_ANDROID"]?.accessToken {
            let clean = cleanAccessToken(fb)
            if clean.hasPrefix("EAA") && clean.count >= 20 {
                return clean
            }
        }
        for key in ["PAGES_MANAGER_ANDROID", "ADS_MANAGER_ANDROID", "FB_LITE"] {
            if let rec = vault.convertedTokens[key]?.accessToken {
                let clean = cleanAccessToken(rec)
                if clean.hasPrefix("EAA") && clean.count >= 20 {
                    return clean
                }
            }
        }
        if !orig.isEmpty && orig.count >= 20 {
            return orig
        }
        return nil
    }

    static func formatFacebookAPIError(_ errorText: String) -> String {
        if let data = errorText.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errObj = json["error"] as? [String: Any] {
            let code = (errObj["code"] as? Int) ?? 0
            let msg = (errObj["message"] as? String) ?? ""
            let userMsg = (errObj["error_user_msg"] as? String)

            if let userMsg, !userMsg.isEmpty {
                return userMsg
            }
            if code == 190 {
                if msg.lowercased().contains("malformed") {
                    return "Access Token bị lỗi định dạng (Malformed). Vui lòng vào 'Kho Token' kiểm tra hoặc kết nối lại tài khoản."
                }
                return "Phiên đăng nhập hoặc Access Token đã hết hạn (Mã 190). Hãy vào 'Kho Token' để lấy lại token mới."
            }
            if code == 200 || code == 10 {
                return "Tài khoản không có quyền đăng bài lên đích này (Nhóm hoặc Trang yêu cầu quyền thành viên/quản trị)."
            }
            if code == 368 {
                return "Tài khoản đang bị Facebook tạm hạn chế tính năng đăng bài (Spam/Checkpoint - Mã 368)."
            }
            if !msg.isEmpty {
                return "\(msg) (Mã \(code))"
            }
        }
        if errorText.contains("Malformed access token") {
            return "Access Token bị lỗi định dạng (Malformed). Hãy vào 'Kho Token' để lấy hoặc lưu lại token chuẩn."
        }
        return errorText
    }

    static func validateAccessToken(_ token: String) async -> (isValid: Bool, message: String) {
        let clean = cleanAccessToken(token)
        guard !clean.isEmpty, clean.count >= 20 else {
            return (false, "Token rỗng hoặc quá ngắn.")
        }
        guard let url = URL(string: "https://graph.facebook.com/me?fields=id,name") else {
            return (false, "URL Graph API không hợp lệ.")
        }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("OAuth \(clean)", forHTTPHeaderField: "authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                return (true, "Token hợp lệ.")
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = json["error"] as? [String: Any],
               let msg = err["message"] as? String {
                return (false, msg)
            }
            return (false, "HTTP \(status)")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    static func resolveDestinationFromInput(
        rawInput: String,
        kind: SmartPostDestinationType,
        accessToken: String?,
        cookieString: String?,
        spaceId: UUID?,
        spaceName: String
    ) async -> FacebookDestinationItem? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var resolvedId: String? = nil
        var resolvedName: String? = nil
        var resolvedPageToken: String? = nil

        // 1. Nếu người dùng nhập trực tiếp dãy số ID
        if trimmed.allSatisfy(\.isNumber), trimmed.count >= 5 {
            resolvedId = trimmed
        } else {
            // Trích xuất số ID nếu có sẵn trên URL (vd: /groups/123456789 hoặc /share/g/123456789)
            let directPatterns = [
                #"(?:groups/|share/g/|fb://group/)(\d{5,25})"#,
                #"profile\.php\?id=(\d{5,25})"#,
                #"facebook\.com/(?:pages/[^/]+/|people/[^/]+/)(\d{5,25})"#,
                #"^(\d{5,25})$"#
            ]
            for pat in directPatterns {
                if let m = FacebookTargetPostResolver.firstMatch(pattern: pat, in: trimmed) {
                    resolvedId = m
                    break
                }
            }

            // 2. Mở rộng link nếu là link rút gọn share/g/..., share/... hoặc slug
            if resolvedId == nil {
                var workingURL = trimmed
                if !workingURL.lowercased().hasPrefix("http") {
                    workingURL = "https://www.facebook.com/\(workingURL)"
                }

                if let expanded = await FacebookTargetPostResolver.resolveShareURLToCanonical(input: workingURL, cookieString: cookieString ?? "") {
                    if expanded.postId.allSatisfy(\.isNumber), expanded.postId.count >= 5 {
                        resolvedId = expanded.postId
                    } else if let num = FacebookTargetPostResolver.firstMatch(pattern: #"(\d{5,25})"#, in: expanded.canonicalURL) {
                        resolvedId = num
                    }
                }

                // Nếu vẫn chưa có ID (dạng slug facebook.com/groups/ten_nhom), tải HTML để bóc tách ID
                if resolvedId == nil, let fetchUrl = URL(string: workingURL) {
                    var req = URLRequest(url: fetchUrl, timeoutInterval: 15)
                    if let cookie = cookieString, !cookie.isEmpty {
                        req.setValue(cookie, forHTTPHeaderField: "Cookie")
                    }
                    req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
                    if let (data, resp) = try? await URLSession.shared.data(for: req) {
                        if let finalUrl = resp.url?.absoluteString {
                            if let m = FacebookTargetPostResolver.firstMatch(pattern: #"(?:groups/|share/g/)(\d{5,25})"#, in: finalUrl) {
                                resolvedId = m
                            } else if let m = FacebookTargetPostResolver.firstMatch(pattern: #"profile\.php\?id=(\d{5,25})"#, in: finalUrl) {
                                resolvedId = m
                            }
                        }
                        if resolvedId == nil, let html = String(data: data, encoding: .utf8) {
                            let groupHtmlPatterns = [
                                #"al:(?:android|ios):url"\s+content="fb://group/(\d{5,25})"#,
                                #"al:(?:android|ios):url"\s+content="fb://page/(\d{5,25})"#,
                                #"fb://group/(\d{5,25})"#,
                                #"fb://page/(\d{5,25})"#,
                                #""groupID"\s*:\s*"?(\d{5,25})"?"#,
                                #""group_id"\s*:\s*"?(\d{5,25})"?"#,
                                #""pageID"\s*:\s*"?(\d{5,25})"?"#,
                                #""entity_id"\s*:\s*"?(\d{5,25})"?"#,
                                #""owning_profile"\s*:\s*\{\s*"__typename"\s*:\s*"(?:Page|Group|User)"\s*,\s*"id"\s*:\s*"(\d{5,25})""#
                            ]
                            for pat in groupHtmlPatterns {
                                if let m = FacebookTargetPostResolver.firstMatch(pattern: pat, in: html) {
                                    resolvedId = m
                                    break
                                }
                            }


                            if let titleMatch = FacebookTargetPostResolver.firstMatch(pattern: #"<title[^>]*>([^<]+)</title>"#, in: html) {
                                let cleanTitle = titleMatch
                                    .replacingOccurrences(of: " | Facebook", with: "")
                                    .replacingOccurrences(of: " - Facebook", with: "")
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                if !cleanTitle.isEmpty && !cleanTitle.lowercased().contains("facebook") {
                                    resolvedName = cleanTitle
                                }
                            }
                        }
                    }
                }
            }
        }

        guard let finalId = resolvedId, !finalId.isEmpty else { return nil }

        // 3. Tra cứu thêm thông tin tên & Page Access Token qua Graph API nếu có token
        let cleanTok = accessToken != nil ? cleanAccessToken(accessToken!) : ""
        if !cleanTok.isEmpty {
            let fields = kind == .fanpage ? "id,name,access_token,category" : "id,name,privacy"
            if let infoUrl = URL(string: "https://graph.facebook.com/\(finalId)?fields=\(fields)") {
                var req = URLRequest(url: infoUrl, timeoutInterval: 12)
                for (k, v) in fbHeaders { req.setValue(v, forHTTPHeaderField: k) }
                req.setValue("OAuth \(cleanTok)", forHTTPHeaderField: "authorization")
                if let (data, _) = try? await URLSession.shared.data(for: req),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let n = json["name"] as? String, !n.isEmpty {
                        resolvedName = n
                    }
                    if let pt = json["access_token"] as? String, !pt.isEmpty {
                        resolvedPageToken = pt
                    }
                }
            }
        }

        let displayTitle = resolvedName ?? "\(kind == .group ? "Nhóm" : "Fanpage") • \(finalId)"
        let subtitle = "ID: \(finalId) • \(spaceName)"
        return FacebookDestinationItem(
            id: finalId,
            name: displayTitle,
            kind: kind,
            pageAccessToken: resolvedPageToken,
            subtitle: subtitle,
            ownerSpaceId: spaceId,
            ownerSpaceName: spaceName
        )
    }

    /// Tải ảnh lên Graph API /\(targetId)/photos để lấy Photo ID (hỗ trợ me, Group hoặc Fanpage)

    static func uploadPhoto(imageData: Data, accessToken: String, targetId: String = "me") async throws -> String {
        let cleanToken = cleanAccessToken(accessToken)
        let cleanTarget = targetId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "me" : targetId
        let url = URL(string: "https://graph.facebook.com/\(cleanTarget)/photos")!
        let sessionId = UUID().uuidString
        let boundary = "Boundary-\(UUID().uuidString)"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (k, v) in fbHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.setValue("OAuth \(cleanToken)", forHTTPHeaderField: "authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "content-type")
        request.setValue("upload-photo", forHTTPHeaderField: "x-fb-friendly-name")

        var body = Data()
        let fields: [String: String] = [
            "access_token": cleanToken,
            "published": "false",
            "audience_exp": "true",
            "qn": sessionId,
            "composer_session_id": sessionId,
            "idempotence_token": "\(sessionId)_-1495512223_0",
            "composer_entry_point": "camera_roll",
            "locale": "vi_VN",
            "client_country_code": "VN",
            "fb_api_req_friendly_name": "upload-photo",
            "fb_api_caller_class": "MultiPhotoUploader"
        ]

        for (k, v) in fields {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(k)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(v)\r\n".data(using: .utf8)!)
        }

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"source\"; filename=\"photo.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let photoId = json["id"] as? String {
            return photoId
        } else if cleanTarget != "me" {
            // Fallback về /me/photos nếu endpoint đích từ chối unpublished photo
            return try await uploadPhoto(imageData: imageData, accessToken: cleanToken, targetId: "me")
        } else {
            let errText = String(data: data, encoding: .utf8) ?? "HTTP \(statusCode)"
            let cleanErr = formatFacebookAPIError(errText)
            throw NSError(domain: "SmartPost", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "Lỗi tải ảnh: \(cleanErr)"])
        }
    }

    /// Đăng Video lên Facebook qua Graph API /\(userId)/videos (hỗ trợ Trang cá nhân, Group ID, hoặc Page ID)

    static func uploadVideo(
        videoData: Data,
        caption: String,
        accessToken: String,
        userId: String
    ) async throws -> String {
        let url = URL(string: "https://graph-video.facebook.com/v19.0/\(userId)/videos")!
        let boundary = "Boundary-\(UUID().uuidString)"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (k, v) in fbHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.setValue("OAuth \(accessToken)", forHTTPHeaderField: "authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "content-type")

        var body = Data()
        let fields: [String: String] = [
            "description": caption,
            "title": String(caption.prefix(30)),
            "published": "true"
        ]

        for (k, v) in fields {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(k)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(v)\r\n".data(using: .utf8)!)
        }

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"source\"; filename=\"video.mp4\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: video/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(videoData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let videoId = json["id"] as? String {
            return videoId
        } else {
            let errText = String(data: data, encoding: .utf8) ?? "HTTP \(statusCode)"
            throw NSError(domain: "SmartPost", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "Lỗi đăng video: \(errText.prefix(140))"])
        }
    }

    /// Đăng bài qua Graph API /\(targetId)/feed (dùng cho Fanpage hoặc Fallback cho Nhóm / Cá nhân)
    private static func createFeedPostGraphAPI(
        targetId: String,
        caption: String,
        photoIds: [String],
        accessToken: String
    ) async throws -> (postId: String, postUrl: String?) {
        guard let url = URL(string: "https://graph.facebook.com/\(targetId)/feed") else {
            throw NSError(domain: "SmartPost", code: -1, userInfo: [NSLocalizedDescriptionKey: "Target ID không hợp lệ"])
        }

        var request = URLRequest(url: url, timeoutInterval: 25)
        request.httpMethod = "POST"
        for (k, v) in fbHeaders { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue("OAuth \(accessToken)", forHTTPHeaderField: "authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")

        var params: [String: String] = [
            "format": "json",
            "locale": "vi_VN"
        ]
        if !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["message"] = caption
        }
        for (idx, pid) in photoIds.enumerated() {
            params["attached_media[\(idx)]"] = "{\"media_fbid\":\"\(pid)\"}"
        }

        let formPairs = params.map { k, v in
            let ek = k.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? k
            let ev = v.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? v
            return "\(ek)=\(ev)"
        }
        request.httpBody = formPairs.joined(separator: "&").data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = json["id"] as? String, !id.isEmpty {
            let cleanId = id.contains("_") ? String(id.split(separator: "_").last ?? Substring(id)) : id
            let canonicalUrl = FacebookTargetPostResolver.buildCanonicalURL(
                id: cleanId,
                kind: "Bài viết (Post)",
                originalURL: "https://www.facebook.com/\(targetId)/posts/\(cleanId)"
            )
            return (id, canonicalUrl)
        }
        let errText = String(data: data, encoding: .utf8) ?? "HTTP \(statusCode)"
        let cleanErr = formatFacebookAPIError(errText)
        throw NSError(domain: "SmartPost", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "Graph feed lỗi: \(cleanErr)"])
    }

    /// Đăng bài viết (status hoặc ảnh) hỗ trợ Trang cá nhân, Nhóm (Group) và Trang (Fanpage)
    static func createPost(
        caption: String,
        photoIds: [String] = [],
        privacy: SmartPostPrivacy = .everyone,
        destinationType: SmartPostDestinationType = .personalProfile,
        targetDestinationId: String? = nil,
        pageAccessToken: String? = nil,
        accessToken: String,
        userId: String
    ) async throws -> (postId: String, postUrl: String?) {
        let cleanDestId = (targetDestinationId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Nếu đăng lên Fanpage: Ưu tiên dùng Page Access Token + Graph API /pageId/feed trước
        if destinationType == .fanpage, !cleanDestId.isEmpty {
            var effectivePageToken = pageAccessToken ?? ""
            if effectivePageToken.isEmpty {
                // Tự động lấy Page Access Token nếu chưa có
                if let pageUrl = URL(string: "https://graph.facebook.com/\(cleanDestId)?fields=access_token") {
                    var req = URLRequest(url: pageUrl, timeoutInterval: 10)
                    req.setValue("OAuth \(accessToken)", forHTTPHeaderField: "authorization")
                    if let (d, _) = try? await URLSession.shared.data(for: req),
                       let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                       let pt = j["access_token"] as? String, !pt.isEmpty {
                        effectivePageToken = pt
                    }
                }
            }
            let tokenToUse = effectivePageToken.isEmpty ? accessToken : effectivePageToken

            if let feedRes = try? await createFeedPostGraphAPI(
                targetId: cleanDestId,
                caption: caption,
                photoIds: photoIds,
                accessToken: tokenToUse
            ) {
                return feedRes
            }
        }

        // 2. Đăng qua GraphQL ComposerStoryCreateMutation (Hỗ trợ Cá nhân, Nhóm, Fanpage)
        let url = URL(string: "https://graph.facebook.com/graphql")!
        let composerSessionId = UUID().uuidString
        let clientTraceId = UUID().uuidString
        let actionTimestamp = Int(Date().timeIntervalSince1970)

        var attachments: [[String: Any]] = []
        for pid in photoIds {
            attachments.append([
                "photo": [
                    "unified_stories_media_source": "CAMERA_ROLL",
                    "story_media_audio_data": [
                        "raw_media_type": "PHOTO"
                    ],
                    "media_source_info": [
                        "entry_point": "COMPOSER_MEDIA_SPROUT"
                    ],
                    "id": pid
                ]
            ])
        }

        let effectiveActorId: String
        let effectiveToken: String
        let audiencesArray: [[String: Any]]
        let composerType: String
        let sourceSurface: String
        let entryPoint: String
        let nectarModule: String

        switch destinationType {
        case .personalProfile:
            effectiveActorId = userId
            effectiveToken = accessToken
            audiencesArray = [[
                "undirected": [
                    "privacy": [
                        "tag_expansion_state": "UNSPECIFIED",
                        "deny": [],
                        "base_state": privacy.apiKey,
                        "allow": []
                    ]
                ]
            ]]
            composerType = "status"
            sourceSurface = "timeline"
            entryPoint = "profile_inline_composer"
            nectarModule = "profile_timeline_composer"

        case .group:
            effectiveActorId = userId
            effectiveToken = accessToken
            audiencesArray = [[
                "to_id": cleanDestId
            ]]
            composerType = "group"
            sourceSurface = "group_feed"
            entryPoint = "group_composer"
            nectarModule = "group_composer"

        case .fanpage:
            effectiveActorId = cleanDestId.isEmpty ? userId : cleanDestId
            effectiveToken = (pageAccessToken?.isEmpty == false) ? pageAccessToken! : accessToken
            audiencesArray = [[
                "to_id": effectiveActorId
            ]]
            composerType = "page"
            sourceSurface = "page_feed"
            entryPoint = "page_inline_composer"
            nectarModule = "page_timeline_composer"
        }

        var inputDict: [String: Any] = [
            "producer_supported_features": ["LIGHTWEIGHT_REPLY"],
            "logging": [
                "composer_session_id": composerSessionId
            ],
            "is_throwback_post": "NOT_THROWBACK_POST",
            "navigation_data": [
                "attribution_id_v2": "ProfileFragment,profile_vnext_tab_posts,tap_bookmark,\(actionTimestamp).871,244483734,\(effectiveActorId),,,\(actionTimestamp).378"
            ],
            "reshare_original_post": "SHARE_LINK_ONLY",
            "idempotence_token": "FEED_\(composerSessionId)",
            "camera_post_context": [
                "source": "COMPOSER",
                "platform": "FACEBOOK",
                "deduplication_id": composerSessionId
            ],
            "connection_class": "EXCELLENT",
            "composer_type": composerType,
            "composer_source_surface": sourceSurface,
            "message": [
                "text": caption
            ],
            "implicit_with_tags_ids": [],
            "composer_entry_point": entryPoint,
            "nectar_module": nectarModule,
            "composer_entry_picker": "NULL",
            "action_timestamp": actionTimestamp,
            "audiences": audiencesArray,
            "tag_expansion_metadata": [
                "tag_expansion_ids": []
            ],
            "place_attachment_setting": "SHOW_ATTACHMENT",
            "ai_generated_self_disclosure_metadata": [
                "was_self_disclosed_as_ai_generated": false
            ],
            "composer_session_events_log": [
                "number_of_keystrokes": caption.count,
                "number_of_copy_pastes": 0,
                "composition_duration": 15
            ],
            "audiences_is_complete": true,
            "source": "MOBILE",
            "actor_id": effectiveActorId
        ]

        if !attachments.isEmpty {
            inputDict["attachments"] = attachments
        }

        let variablesDict: [String: Any] = [
            "default_image_scale": "1.5",
            "should_fetch_adaptive_ufi": true,
            "media_type": "image/jpeg",
            "input": inputDict
        ]

        let variablesJson = (try? String(data: JSONSerialization.data(withJSONObject: variablesDict), encoding: .utf8)) ?? "{}"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (k, v) in fbHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.setValue("OAuth \(effectiveToken)", forHTTPHeaderField: "authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        request.setValue("graphservice", forHTTPHeaderField: "x-graphql-client-library")
        request.setValue("ComposerStoryCreateMutation", forHTTPHeaderField: "x-fb-friendly-name")

        let postParams: [String: String] = [
            "method": "post",
            "pretty": "false",
            "format": "json",
            "server_timestamps": "true",
            "locale": "vi_VN",
            "fb_api_req_friendly_name": "ComposerStoryCreateMutation",
            "fb_api_caller_class": "graphservice",
            "client_doc_id": "91093790613512646032808605640",
            "fb_api_client_context": "{\"is_background\":false}",
            "variables": variablesJson,
            "client_trace_id": clientTraceId
        ]

        let formPairs = postParams.map { k, v in
            let ek = k.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? k
            let ev = v.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? v
            return "\(ek)=\(ev)"
        }
        request.httpBody = formPairs.joined(separator: "&").data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let respString = String(data: data, encoding: .utf8) ?? ""

        if let directJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let d = directJson["data"] as? [String: Any],
           let sc = d["story_create"] as? [String: Any],
           let story = sc["story"] as? [String: Any] {
            let pid = (story["legacy_api_story_id"] as? String) ?? (story["id"] as? String) ?? ""
            var purl = story["url"] as? String
            if purl == nil && !pid.isEmpty {
                if destinationType == .group && !cleanDestId.isEmpty {
                    purl = "https://www.facebook.com/groups/\(cleanDestId)/posts/\(pid)"
                } else {
                    let ownerActor = cleanDestId.isEmpty ? userId : cleanDestId
                    purl = FacebookTargetPostResolver.buildCanonicalURL(
                        id: pid,
                        kind: "Bài viết (Post)",
                        originalURL: "https://www.facebook.com/\(ownerActor)/posts/\(pid)"
                    )
                }
            }
            return (pid.isEmpty ? "Đã đăng thành công" : pid, purl)
        }

        if let pidMatch = FacebookTargetPostResolver.firstMatch(pattern: "\"legacy_api_story_id\":\"([0-9]+)\"", in: respString)
            ?? FacebookTargetPostResolver.firstMatch(pattern: "\"id\":\"([0-9_]+)\"", in: respString) {
            let purl = (destinationType == .group && !cleanDestId.isEmpty)
                ? "https://www.facebook.com/groups/\(cleanDestId)/posts/\(pidMatch)"
                : "https://www.facebook.com/\(pidMatch)"
            return (pidMatch, purl)
        }

        if respString.contains("\"story_create\"") && !respString.contains("\"errors\"") {
            return ("Thành công", nil)
        }

        // 3. Fallback qua Graph API /targetId/feed nếu GraphQL trả lỗi
        let fallbackTarget = cleanDestId.isEmpty ? "me" : cleanDestId
        if let fallbackRes = try? await createFeedPostGraphAPI(
            targetId: fallbackTarget,
            caption: caption,
            photoIds: photoIds,
            accessToken: effectiveToken
        ) {
            return fallbackRes
        }

        throw NSError(domain: "SmartPost", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "Đăng bài thất bại: \(respString.prefix(120))"])
    }

    /// Đổi quyền riêng tư bài viết (Công khai, Bạn bè, Chỉ mình tôi)
    static func updatePostPrivacy(postId: String, privacy: SmartPostPrivacy, accessToken: String) async throws -> Bool {
        let url = URL(string: "https://graph.facebook.com/graphql")!
        let clientTraceId = UUID().uuidString
        let privacySessionId = String(Int(Date().timeIntervalSince1970 * 1000))
        let latencyQpl = String(Int(Date().timeIntervalSince1970 * 1000000))

        let optionId = "40f262f9f9c2c8bab6e9fc22c213a4308f931a6fe9a236cad328e002cd907c7e"
        let clientInputParams: [String: Any] = [
            "privacy_post_param": privacy.privacyId,
            "option_id": optionId,
            "privacy_session_id": privacySessionId,
            "save_default_privacy": 1,
            "creation_session_id": NSNull()
        ]
        let serverParams: [String: Any] = [
            "privacy_write_id": "{\"id\":\"\(postId)\"}",
            "INTERNAL__latency_qpl_marker_id": 36707139,
            "render_location": "BPS_COMPOSER_STANDALONE_EDIT",
            "should_update_privacy_button": 1,
            "should_log_audience_overrides": 1,
            "auto_save": 1,
            "callsite_context": [:],
            "INTERNAL__latency_qpl_instance_id": latencyQpl,
            "use_graphql_for_privacy_save_mutations": 1
        ]
        let innerParams: [String: Any] = [
            "client_input_params": clientInputParams,
            "server_params": serverParams
        ]
        let innerJson = (try? String(data: JSONSerialization.data(withJSONObject: innerParams), encoding: .utf8)) ?? "{}"
        let middleJson = (try? String(data: JSONSerialization.data(withJSONObject: ["params": innerJson]), encoding: .utf8)) ?? "{}"

        let outerParams: [String: Any] = [
            "params": [
                "params": middleJson,
                "bloks_versioning_id": "8d129b12c898b410587535d8971dae35526b73451a4d950f95c1eee58666db21",
                "app_id": "com.bloks.www.fb.privacy.audiences.basic_write"
            ],
            "scale": "1.5",
            "nt_context": [
                "using_white_navbar": true,
                "pixel_ratio": 1.5,
                "is_push_on": true,
                "styles_id": "51609fb901550a6035225e028a3e4fc3",
                "bloks_version": "8d129b12c898b410587535d8971dae35526b73451a4d950f95c1eee58666db21"
            ]
        ]
        let variablesJson = (try? String(data: JSONSerialization.data(withJSONObject: outerParams), encoding: .utf8)) ?? "{}"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (k, v) in fbHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.setValue("OAuth \(accessToken)", forHTTPHeaderField: "authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        request.setValue("graphservice", forHTTPHeaderField: "x-graphql-client-library")

        let postParams: [String: String] = [
            "method": "post",
            "pretty": "false",
            "format": "json",
            "server_timestamps": "true",
            "locale": "vi_VN",
            "fb_api_req_friendly_name": "FbBloksScreenRootQuery-com.bloks.www.fb.privacy.audiences.basic_write",
            "fb_api_caller_class": "graphservice",
            "client_doc_id": "8756910793616235492211993202",
            "variables": variablesJson,
            "client_trace_id": clientTraceId
        ]

        let formPairs = postParams.map { k, v in
            let ek = k.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? k
            let ev = v.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? v
            return "\(ek)=\(ev)"
        }
        request.httpBody = formPairs.joined(separator: "&").data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let respString = String(data: data, encoding: .utf8) ?? ""
        if statusCode == 200 && !respString.contains("\"error\"") {
            return true
        }
        return false
    }
}

// MARK: - Multiple Photos & Video Picker (PHPickerViewController)

struct SmartPostMediaPicker: UIViewControllerRepresentable {
    var onImagesPicked: ([UIImage]) -> Void
    var onVideoPicked: (Data) -> Void
    var filterType: PHPickerFilter

    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = 15 // Hỗ trợ chọn tối đa 15 ảnh
        config.filter = filterType
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: SmartPostMediaPicker
        init(_ parent: SmartPostMediaPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            guard !results.isEmpty else { return }

            var collectedImages: [UIImage] = []
            let group = DispatchGroup()

            for result in results {
                let provider = result.itemProvider
                if provider.canLoadObject(ofClass: UIImage.self) {
                    group.enter()
                    provider.loadObject(ofClass: UIImage.self) { image, _ in
                        if let img = image as? UIImage {
                            DispatchQueue.main.async { collectedImages.append(img) }
                        }
                        group.leave()
                    }
                } else if provider.hasItemConformingToTypeIdentifier("public.movie") {
                    provider.loadFileRepresentation(forTypeIdentifier: "public.movie") { url, _ in
                        if let fileURL = url, let videoData = try? Data(contentsOf: fileURL) {
                            DispatchQueue.main.async {
                                self.parent.onVideoPicked(videoData)
                            }
                        }
                    }
                }
            }

            group.notify(queue: .main) {
                if !collectedImages.isEmpty {
                    self.parent.onImagesPicked(collectedImages)
                }
            }
        }
    }
}

// MARK: - Smart Post Main View

struct SmartPostView: View {
    @EnvironmentObject private var library: SpaceLibrary
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scheduler = ScheduledPostManager.shared
    @StateObject private var tracker = TrackedPostManager.shared

    // Navigation Tabs: 0 = Soạn & Đăng, 1 = Lịch đăng, 2 = Theo dõi & AI
    @State private var selectedTab: Int

    // Selection
    @State private var selectedSpaceIds: Set<UUID> = []
    @State private var destinationType: SmartPostDestinationType = .personalProfile
    @State private var discoveredGroups: [FacebookDestinationItem] = []
    @State private var discoveredPages: [FacebookDestinationItem] = []
    @State private var selectedDestinationKeys: Set<String> = []
    @State private var manualDestinationInput: String = ""
    @State private var isLoadingDestinations = false
    @State private var isResolvingManualDestination = false

    @State private var postCaption = ""
    @State private var privacyOption: SmartPostPrivacy = .everyone
    @State private var autoTrackAndAIReply = true

    // Tương tác tự động: Reaction & Bình luận mồi
    @State private var enableAutoReact = false
    @State private var selectedReaction: String = "LIKE"
    @State private var reactionPercentage: Double = 100.0
    @State private var enableFirstComment = false
    @State private var firstCommentText = ""

    // Bộ tìm kiếm Nhóm & Trang
    @State private var destinationSearchText = ""

    // Quản lý sửa lịch đăng
    @State private var editingTask: ScheduledPostTask? = nil

    init(initialTab: Int = 0) {
        _selectedTab = State(initialValue: initialTab)
    }

    // Media
    @State private var selectedImages: [UIImage] = []
    @State private var selectedVideoData: Data? = nil
    @State private var showPhotoPicker = false
    @State private var showVideoPicker = false

    // Scheduling
    @State private var isScheduling = false
    @State private var scheduledDate = Date().addingTimeInterval(3600)

    // Bulk Privacy Mode
    @State private var isPrivacyOnlyMode = false
    @State private var targetPostIdToUpdatePrivacy = ""

    // Publishing states
    @State private var isPublishing = false
    @State private var progressMessage = ""
    @State private var results: [SmartPostResult] = []
    @State private var alertMessage: String?

    private var availableSpaces: [Space] {
        library.spaces.filter { $0.platform == .facebook }
    }

    private var selectedSpaces: [Space] {
        availableSpaces.filter { selectedSpaceIds.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Custom Modern 3-Tab Switcher (Gọn gàng & Trang trí đẹp mắt với tone #8FBC8F)
                HStack(spacing: 6) {
                    smartTabButton(
                        index: 0,
                        title: "Soạn & Đăng",
                        icon: "square.and.pencil",
                        badgeCount: 0,
                        activeColors: [Color.themePrimary, Color.themePrimaryDark]
                    )
                    smartTabButton(
                        index: 1,
                        title: "Lịch đăng",
                        icon: "calendar.badge.clock",
                        badgeCount: scheduler.tasks.count,
                        activeColors: [Color.themePrimary, Color.themePrimaryDark]
                    )
                    smartTabButton(
                        index: 2,
                        title: "Theo dõi & AI",
                        icon: "chart.bar.doc.horizontal.fill",
                        badgeCount: tracker.posts.count,
                        activeColors: [Color.themePrimary, Color.themePrimaryDark]
                    )
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

                if selectedTab == 0 {
                    composeForm
                } else if selectedTab == 1 {
                    scheduleManagerView
                } else {
                    PostTrackerView()
                }
            }
            .navigationTitle("Smart Post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Đóng") { dismiss() }
                        .disabled(isPublishing)
                }
            }
            .sheet(isPresented: $showPhotoPicker) {
                SmartPostMediaPicker(
                    onImagesPicked: { imgs in
                        selectedVideoData = nil // Nếu chọn ảnh thì xóa video
                        selectedImages.append(contentsOf: imgs)
                    },
                    onVideoPicked: { _ in },
                    filterType: .images
                )
            }
            .sheet(isPresented: $showVideoPicker) {
                SmartPostMediaPicker(
                    onImagesPicked: { _ in },
                    onVideoPicked: { vdata in
                        selectedImages.removeAll() // Nếu chọn video thì bỏ ảnh
                        selectedVideoData = vdata
                    },
                    filterType: .videos
                )
            }
            .sheet(item: $editingTask) { task in
                EditScheduleSheet(task: task)
            }
            .alert("Thông báo", isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )) {
                Button("OK") { alertMessage = nil }
            } message: {
                Text(alertMessage ?? "")
            }
            .onAppear {
                if selectedSpaceIds.isEmpty {
                    selectedSpaceIds = Set(availableSpaces.map(\.id))
                }
            }
        }
    }

    // MARK: - Custom Tab Switcher Button

    @ViewBuilder
    private func smartTabButton(
        index: Int,
        title: String,
        icon: String,
        badgeCount: Int,
        activeColors: [Color]
    ) -> some View {
        let isSelected = selectedTab == index
        Button {
            withAnimation(.spring(response: 0.28)) { selectedTab = index }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption.bold())
                Text(title)
                    .font(.caption.bold())
                    .lineLimit(1)
                if badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(isSelected ? Color.white.opacity(0.28) : (activeColors.first ?? .blue), in: Capsule())
                        .foregroundStyle(.white)
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        isSelected
                            ? AnyShapeStyle(LinearGradient(colors: activeColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                            : AnyShapeStyle(Color(uiColor: .tertiarySystemGroupedBackground))
                    )
                    .shadow(color: isSelected ? (activeColors.first ?? .blue).opacity(0.25) : Color.clear, radius: 3, x: 0, y: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Compose Form View

    @ViewBuilder
    private var composeForm: some View {
        Form {
            // Chế độ thao tác với Icon & Card chuyên nghiệp (#8FBC8F và Trắng chủ đạo)
            Section("Loại thao tác") {
                HStack(spacing: 12) {
                    Button {
                        withAnimation(.spring(response: 0.3)) { isPrivacyOnlyMode = false }
                    } label: {
                        HStack(spacing: 10) {
                            ZStack {
                                Circle()
                                    .fill(LinearGradient(
                                        colors: isPrivacyOnlyMode ? [Color.gray.opacity(0.3), Color.gray.opacity(0.2)] : [Color.themePrimary, Color.themePrimaryDark],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ))
                                    .frame(width: 36, height: 36)
                                Image(systemName: "paperplane.fill")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.white)
                            }
                            Text("Đăng bài")
                                .font(.subheadline.bold())
                                .foregroundStyle(isPrivacyOnlyMode ? Color.primary : Color.themePrimaryDark)
                            Spacer(minLength: 0)
                            if !isPrivacyOnlyMode {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.themePrimary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(!isPrivacyOnlyMode ? Color.themeBackgroundPastel : Color(uiColor: .secondarySystemGroupedBackground))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(!isPrivacyOnlyMode ? Color.themePrimary : Color.gray.opacity(0.2), lineWidth: 1.2)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isPublishing)

                    Button {
                        withAnimation(.spring(response: 0.3)) { isPrivacyOnlyMode = true }
                    } label: {
                        HStack(spacing: 10) {
                            ZStack {
                                Circle()
                                    .fill(LinearGradient(
                                        colors: !isPrivacyOnlyMode ? [Color.gray.opacity(0.3), Color.gray.opacity(0.2)] : [Color.themePrimary, Color.themePrimaryDark],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ))
                                    .frame(width: 36, height: 36)
                                Image(systemName: "lock.shield.fill")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.white)
                            }
                            Text("Đổi quyền")
                                .font(.subheadline.bold())
                                .foregroundStyle(!isPrivacyOnlyMode ? Color.primary : Color.themePrimaryDark)
                            Spacer(minLength: 0)
                            if isPrivacyOnlyMode {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.themePrimary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(isPrivacyOnlyMode ? Color.themeBackgroundPastel : Color(uiColor: .secondarySystemGroupedBackground))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(isPrivacyOnlyMode ? Color.themePrimary : Color.gray.opacity(0.2), lineWidth: 1.2)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isPublishing)
                }
                .padding(.vertical, 2)
            }

            // Chọn tài khoản
            Section("1. Chọn tài khoản thực hiện (\(selectedSpaces.count)/\(availableSpaces.count))") {
                HStack {
                    Button("Chọn tất cả") { selectedSpaceIds = Set(availableSpaces.map(\.id)) }
                    Spacer()
                    Button("Bỏ chọn") { selectedSpaceIds.removeAll() }
                }
                .font(.caption.bold())
                .disabled(isPublishing)

                ForEach(availableSpaces) { sp in
                    let summary = VaultMetadataIndex.get(sp.id)
                    let isSelected = selectedSpaceIds.contains(sp.id)
                    Button {
                        if isSelected { selectedSpaceIds.remove(sp.id) }
                        else { selectedSpaceIds.insert(sp.id) }
                    } label: {
                        HStack {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isSelected ? Color.themePrimary : Color.secondary)
                            Image(systemName: sp.platform.icon)
                                .foregroundStyle(sp.platform.color)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sp.name).foregroundStyle(.primary)
                                if summary.hasToken {
                                    Text("Sẵn sàng API (\(summary.tokenPrefix.isEmpty ? "App" : summary.tokenPrefix))")
                                        .font(.caption2).foregroundStyle(.green)
                                } else {
                                    Text("Chưa có Token API")
                                        .font(.caption2).foregroundStyle(.red)
                                }
                            }
                            Spacer()
                        }
                    }
                    .disabled(isPublishing)
                }
            }

            // Nội dung & Nơi đăng bài
            if !isPrivacyOnlyMode {
                Section("2. Nơi đăng bài (Trang cá nhân / Nhóm / Fanpage)") {
                    // 3 Nút chọn Nơi đăng gọn gàng, trang trí đẹp
                    HStack(spacing: 8) {
                        ForEach(SmartPostDestinationType.allCases) { dtype in
                            let isSelected = destinationType == dtype
                            Button {
                                withAnimation(.spring(response: 0.28)) {
                                    destinationType = dtype
                                }
                                if dtype == .group && discoveredGroups.isEmpty {
                                    Task { await loadDestinationsForSelectedSpaces(kind: .group) }
                                } else if dtype == .fanpage && discoveredPages.isEmpty {
                                    Task { await loadDestinationsForSelectedSpaces(kind: .fanpage) }
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: dtype.icon)
                                        .font(.caption.bold())
                                    Text(dtype.shortLabel)
                                        .font(.caption.bold())
                                        .lineLimit(1)
                                }
                                .foregroundStyle(isSelected ? Color.white : Color.primary)
                                .padding(.vertical, 9)
                                .frame(maxWidth: .infinity)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(
                                            isSelected
                                                ? AnyShapeStyle(LinearGradient(colors: dtype.gradientColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                                                : AnyShapeStyle(Color(uiColor: .secondarySystemGroupedBackground))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(isSelected ? Color.clear : Color.gray.opacity(0.22), lineWidth: 1)
                                        )
                                        .shadow(color: isSelected ? (dtype.gradientColors.first ?? .blue).opacity(0.25) : .clear, radius: 3, x: 0, y: 1.5)
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(isPublishing)
                        }
                    }
                    .padding(.vertical, 2)

                    if destinationType == .personalProfile {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Quyền riêng tư bài đăng (Trang cá nhân)")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)

                            HStack(spacing: 8) {
                                ForEach(SmartPostPrivacy.allCases) { opt in
                                    let isSelected = privacyOption == opt
                                    Button {
                                        withAnimation(.spring(response: 0.28)) { privacyOption = opt }
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: opt.icon)
                                                .font(.caption.bold())
                                            Text(opt.shortName)
                                                .font(.caption.bold())
                                        }
                                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                                        .padding(.vertical, 8)
                                        .frame(maxWidth: .infinity)
                                        .background(
                                            RoundedRectangle(cornerRadius: 10)
                                                .fill(
                                                    isSelected
                                                        ? AnyShapeStyle(LinearGradient(colors: [Color.themePrimary, Color.themePrimaryDark], startPoint: .topLeading, endPoint: .bottomTrailing))
                                                        : AnyShapeStyle(Color(uiColor: .secondarySystemGroupedBackground))
                                                )
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 10)
                                                        .stroke(isSelected ? Color.clear : Color.gray.opacity(0.22), lineWidth: 1)
                                                )
                                                .shadow(color: isSelected ? Color.themePrimary.opacity(0.25) : .clear, radius: 2, x: 0, y: 1)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(isPublishing)
                                }
                            }
                        }
                        .padding(.vertical, 3)
                    } else {
                        destinationSelectorPanel(for: destinationType)
                    }
                }

                Section("3. Nội dung & Hình ảnh / Video") {
                    TextField("Nhập nội dung chia sẻ...", text: $postCaption, axis: .vertical)
                        .lineLimit(3...7)
                        .disabled(isPublishing)

                    // Quản lý Media (Ảnh & Video)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Đính kèm hình ảnh hoặc Video:")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            // Nút Thêm ảnh thiết kế Card
                            Button {
                                showPhotoPicker = true
                            } label: {
                                HStack(spacing: 8) {
                                    ZStack {
                                        Circle()
                                            .fill(LinearGradient(
                                                colors: [Color.green, Color.teal],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            ))
                                            .frame(width: 36, height: 36)
                                        Image(systemName: "photo.on.rectangle.angled")
                                            .font(.subheadline.bold())
                                            .foregroundStyle(.white)
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Thêm ảnh")
                                            .font(.subheadline.bold())
                                            .foregroundStyle(.primary)
                                        Text(selectedImages.isEmpty ? "Tối đa 15 ảnh" : "\(selectedImages.count) ảnh đã chọn")
                                            .font(.caption2)
                                            .foregroundStyle(selectedImages.isEmpty ? Color.secondary : Color.green)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(selectedImages.isEmpty ? Color(uiColor: .secondarySystemGroupedBackground) : Color.green.opacity(0.12))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(selectedImages.isEmpty ? Color.gray.opacity(0.2) : Color.green, lineWidth: 1.2)
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(isPublishing)

                            // Nút Chọn video thiết kế Card
                            Button {
                                showVideoPicker = true
                            } label: {
                                HStack(spacing: 8) {
                                    ZStack {
                                        Circle()
                                            .fill(LinearGradient(
                                                colors: [Color.pink, Color.purple],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            ))
                                            .frame(width: 36, height: 36)
                                        Image(systemName: "video.fill")
                                            .font(.subheadline.bold())
                                            .foregroundStyle(.white)
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Chọn video")
                                            .font(.subheadline.bold())
                                            .foregroundStyle(.primary)
                                        Text(selectedVideoData != nil ? "Đã nạp MP4" : "Video MP4")
                                            .font(.caption2)
                                            .foregroundStyle(selectedVideoData != nil ? Color.purple : Color.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(selectedVideoData == nil ? Color(uiColor: .secondarySystemGroupedBackground) : Color.purple.opacity(0.12))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(selectedVideoData == nil ? Color.gray.opacity(0.2) : Color.purple, lineWidth: 1.2)
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(isPublishing)
                        }

                        // Preview Video đã chọn
                        if selectedVideoData != nil {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(LinearGradient(colors: [Color.purple.opacity(0.8), Color.pink.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .frame(width: 44, height: 44)
                                    Image(systemName: "play.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(.white)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Video bài đăng MP4")
                                        .font(.subheadline.bold())
                                    Text("Dung lượng nén: ~\(max(1, Int((selectedVideoData?.count ?? 0) / 1024 / 1024))) MB")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    selectedVideoData = nil
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(.red)
                                }
                            }
                            .padding(10)
                            .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        }

                        // Preview Ảnh đã chọn
                        if !selectedImages.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(Array(selectedImages.enumerated()), id: \.offset) { idx, img in
                                        ZStack(alignment: .topTrailing) {
                                            Image(uiImage: img)
                                                .resizable()
                                                .scaledToFill()
                                                .frame(width: 68, height: 68)
                                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 10)
                                                        .stroke(Color.white.opacity(0.8), lineWidth: 1)
                                                )
                                                .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 1)

                                            Button {
                                                selectedImages.remove(at: idx)
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .font(.system(size: 20))
                                                    .foregroundStyle(.red)
                                                    .background(Circle().fill(.white).padding(2))
                                            }
                                            .offset(x: 6, y: -6)
                                            .disabled(isPublishing)
                                        }
                                    }
                                }
                                .padding(.top, 6)
                                .padding(.trailing, 8)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Tương tác tự động: Reaction & Bình luận đầu tiên
                Section("4. Tương tác tự động (Reaction & Bình luận đầu tiên)") {
                    Toggle(isOn: $enableAutoReact) {
                        Label("Tự động thả Reaction bài viết", systemImage: "hand.thumbsup.fill")
                            .font(.subheadline)
                    }
                    .tint(Color.themePrimary)
                    .disabled(isPublishing)

                    if enableAutoReact {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Loại cảm xúc:")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(FacebookReactionType.concreteReactions) { rType in
                                        let isSel = selectedReaction == rType.rawValue
                                        Button {
                                            selectedReaction = rType.rawValue
                                        } label: {
                                            Text(rType.label)
                                                .font(.caption.bold())
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 6)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 8)
                                                        .fill(isSel ? Color.themePrimary : Color(uiColor: .secondarySystemGroupedBackground))
                                                )
                                                .foregroundStyle(isSel ? Color.white : Color.primary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }

                            HStack {
                                Text("Tỷ lệ thả:")
                                    .font(.caption.bold())
                                Spacer()
                                Text("\(Int(reactionPercentage))%")
                                    .font(.caption.bold())
                                    .foregroundStyle(Color.themePrimary)
                            }

                            Slider(value: $reactionPercentage, in: 10...100, step: 10)
                                .tint(Color.themePrimary)
                        }
                        .padding(.vertical, 2)
                    }

                    Toggle(isOn: $enableFirstComment) {
                        Label("Gắn 1 bình luận đầu tiên ngay khi đăng", systemImage: "bubble.left.fill")
                            .font(.subheadline)
                    }
                    .tint(Color.themePrimary)
                    .disabled(isPublishing)

                    if enableFirstComment {
                        TextField("Nhập nội dung bình luận mồi...", text: $firstCommentText, axis: .vertical)
                            .lineLimit(2...4)
                            .font(.subheadline)
                            .disabled(isPublishing)
                    }
                }

                // Lên lịch đăng & Theo dõi tự động
                Section("5. Hẹn giờ & Theo dõi tương tác AI") {
                    Toggle(isOn: $autoTrackAndAIReply) {
                        Label("Tự động theo dõi & tick AI trả lời sau khi đăng", systemImage: "sparkles")
                            .font(.subheadline)
                    }
                    .tint(Color.themePrimary)
                    .disabled(isPublishing)

                    Toggle("Bật lên lịch đăng tự động", isOn: $isScheduling)
                        .tint(Color.themePrimary)
                        .disabled(isPublishing)

                    if isScheduling {
                        DatePicker("Thời gian đăng", selection: $scheduledDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                            .datePickerStyle(.compact)
                        Text("Hệ thống sẽ tự động đăng bài theo đúng giờ đã hẹn, áp dụng tỷ lệ reaction, bình luận mồi và thêm vào mục Theo dõi.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section("2. Đổi quyền riêng tư bài viết") {
                    TextField("Nhập Post ID cần đổi quyền...", text: $targetPostIdToUpdatePrivacy)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .disabled(isPublishing)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Quyền mới:")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            ForEach(SmartPostPrivacy.allCases) { opt in
                                let isSelected = privacyOption == opt
                                Button {
                                    withAnimation(.spring(response: 0.28)) { privacyOption = opt }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: opt.icon)
                                            .font(.caption.bold())
                                        Text(opt.shortName)
                                            .font(.caption.bold())
                                    }
                                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(
                                                isSelected
                                                    ? AnyShapeStyle(LinearGradient(colors: [Color.themePrimary, Color.themePrimaryDark], startPoint: .topLeading, endPoint: .bottomTrailing))
                                                    : AnyShapeStyle(Color(uiColor: .secondarySystemGroupedBackground))
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 10)
                                                    .stroke(isSelected ? Color.clear : Color.gray.opacity(0.22), lineWidth: 1)
                                            )
                                    )
                                }
                                .buttonStyle(.plain)
                                .disabled(isPublishing)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            // Nút thực hiện (#8FBC8F và Trắng chủ đạo)
            Section {
                if isPublishing {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(progressMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Button {
                    if isScheduling && !isPrivacyOnlyMode {
                        schedulePost()
                    } else {
                        Task { await executeSmartPost() }
                    }
                } label: {
                    HStack {
                        Spacer()
                        Label(
                            isPrivacyOnlyMode ? "Cập nhật quyền riêng tư" :
                                (isScheduling ? "Lưu vào Lịch Đăng (\(destinationType.shortLabel))" : "Đăng ngay lên \(destinationType.rawValue)"),
                            systemImage: isPrivacyOnlyMode ? "lock.rotation" :
                                (isScheduling ? "calendar.badge.clock" : "paperplane.fill")
                        )
                        .font(.headline)
                        .foregroundStyle(.white)
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
                .listRowBackground(canSubmit ? Color.themePrimary : Color.gray.opacity(0.3))
                .disabled(!canSubmit)
            }

            // Kết quả trực tiếp
            if !results.isEmpty {
                Section("Kết quả thực hiện (\(results.filter(\.isSuccess).count)/\(results.count) thành công)") {
                    if results.contains(where: \.isSuccess) {
                        Button {
                            withAnimation(.spring(response: 0.3)) { selectedTab = 2 }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "chart.bar.doc.horizontal.fill")
                                Text("Mở Theo dõi tương tác & AI Trả lời")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.bold())
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(GradientPillButtonStyle(colors: [Color(red: 143/255, green: 188/255, blue: 143/255), Color(red: 118/255, green: 163/255, blue: 118/255)], isCompact: true))
                    }

                    ForEach(results) { res in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: res.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(res.isSuccess ? Color.green : Color.red)
                                Text(res.spaceName)
                                    .font(.subheadline.bold())
                                Spacer()
                                if let pid = res.postId {
                                    Text("ID: \(pid)")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(res.message)
                                .font(.caption)
                                .foregroundStyle(res.isSuccess ? Color.secondary : Color.red)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    // MARK: - Destination Selector Panel (Group / Fanpage)

    private var currentDestinationList: [FacebookDestinationItem] {
        destinationType == .group ? discoveredGroups : discoveredPages
    }

    private var activeSelectedDestinations: [FacebookDestinationItem] {
        currentDestinationList.filter { selectedDestinationKeys.contains($0.uniqueSelectionKey) }
    }

    @ViewBuilder
    private func destinationSelectorPanel(for kind: SmartPostDestinationType) -> some View {
        let isGroup = (kind == .group)
        VStack(alignment: .leading, spacing: 10) {
            // Nút tải tự động danh sách Nhóm / Fanpage từ các tài khoản đã chọn
            HStack(spacing: 8) {
                Button {
                    Task { await loadDestinationsForSelectedSpaces(kind: kind) }
                } label: {
                    HStack(spacing: 6) {
                        if isLoadingDestinations {
                            ProgressView().controlSize(.mini).tint(.white)
                        } else {
                            Image(systemName: isGroup ? "person.3.sequence.fill" : "flag.2.crossed.fill")
                        }
                        Text(isLoadingDestinations
                             ? "Đang tải danh sách \(isGroup ? "Nhóm" : "Fanpage")..."
                             : "Tải danh sách \(isGroup ? "Nhóm đã tham gia" : "Fanpage quản trị")")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(GradientPillButtonStyle(colors: [Color.themePrimary, Color.themePrimaryDark], isCompact: true))
                .disabled(isLoadingDestinations || isPublishing || selectedSpaces.isEmpty)
            }

            // Ô nhập tay Link hoặc ID Nhóm / Fanpage kèm Chuyển đổi URL
            VStack(alignment: .leading, spacing: 6) {
                Text(isGroup ? "Hoặc dán Link / ID Nhóm bất kỳ:" : "Hoặc dán Link / ID Trang Fanpage:")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    TextField(
                        isGroup ? "VD: https://facebook.com/groups/... hoặc ID" : "VD: https://facebook.com/... hoặc Page ID",
                        text: $manualDestinationInput
                    )
                    .font(.caption)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))

                    Button {
                        if let clip = UIPasteboard.general.string {
                            manualDestinationInput = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "doc.on.clipboard")
                            Text("Dán")
                        }
                    }
                    .buttonStyle(GradientPillButtonStyle(colors: [.gray, .secondary], isCompact: true))

                    Button {
                        Task { await resolveAndAddManualDestination(kind: kind) }
                    } label: {
                        HStack(spacing: 4) {
                            if isResolvingManualDestination {
                                ProgressView().controlSize(.mini).tint(.white)
                            } else {
                                Image(systemName: "plus.circle.fill")
                            }
                            Text("Thêm")
                        }
                    }
                    .buttonStyle(GradientPillButtonStyle(colors: [Color.themePrimary, Color.themePrimaryDark], isCompact: true))
                    .disabled(manualDestinationInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isResolvingManualDestination)
                }
            }

            // Danh sách Nhóm / Fanpage để tick chọn kèm Bộ tìm kiếm
            let list = currentDestinationList
            if list.isEmpty {
                Text(isGroup
                     ? "Chưa có Nhóm nào trong danh sách. Hãy bấm 'Tải danh sách Nhóm' hoặc dán Link/ID Nhóm ở trên."
                     : "Chưa có Fanpage nào. Hãy bấm 'Tải danh sách Fanpage quản trị' hoặc dán Link/ID Fanpage ở trên.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            } else {
                // Thanh tìm kiếm nhanh danh sách Nhóm / Fanpage
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField("Tìm kiếm tên hoặc ID \(isGroup ? "nhóm" : "trang")...", text: $destinationSearchText)
                        .font(.caption)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if !destinationSearchText.isEmpty {
                        Button {
                            destinationSearchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))

                let filteredList = list.filter { item in
                    let q = destinationSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if q.isEmpty { return true }
                    return item.name.lowercased().contains(q) || item.id.contains(q) || item.subtitle.lowercased().contains(q)
                }

                HStack {
                    Text("Đã chọn \(activeSelectedDestinations.count)/\(list.count) \(isGroup ? "Nhóm" : "Fanpage")")
                        .font(.caption.bold())
                        .foregroundStyle(Color.themePrimary)
                    Spacer()
                    Button("Chọn hết") {
                        for item in filteredList { selectedDestinationKeys.insert(item.uniqueSelectionKey) }
                    }
                    .font(.caption2.bold())
                    Text("•").foregroundStyle(.secondary)
                    Button("Bỏ chọn") {
                        for item in filteredList { selectedDestinationKeys.remove(item.uniqueSelectionKey) }
                    }
                    .font(.caption2.bold())
                }

                if filteredList.isEmpty {
                    Text("Không tìm thấy kết quả phù hợp với \"\(destinationSearchText)\"")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(filteredList, id: \.uniqueSelectionKey) { item in
                        let isChecked = selectedDestinationKeys.contains(item.uniqueSelectionKey)
                        Button {
                            if isChecked {
                                selectedDestinationKeys.remove(item.uniqueSelectionKey)
                            } else {
                                selectedDestinationKeys.insert(item.uniqueSelectionKey)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(isChecked ? Color.themePrimary : .secondary)
                                    .font(.subheadline)
                                Image(systemName: item.kind.icon)
                                    .font(.caption)
                                    .foregroundStyle(Color.themePrimary)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(item.name)
                                            .font(.caption.bold())
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        if let postStatus = item.viewerPostStatus {
                                            if postStatus == "CAN_POST_DIRECTLY" {
                                                Text("Tự do đăng")
                                                    .font(.system(size: 8, weight: .bold))
                                                    .padding(.horizontal, 4)
                                                    .padding(.vertical, 1.5)
                                                    .background(Color.green.opacity(0.18))
                                                    .foregroundStyle(Color.green)
                                                    .clipShape(Capsule())
                                            } else if postStatus == "CAN_POST_AFTER_APPROVAL" || postStatus == "NEEDS_ADMIN_APPROVAL" {
                                                Text("Cần duyệt")
                                                    .font(.system(size: 8, weight: .bold))
                                                    .padding(.horizontal, 4)
                                                    .padding(.vertical, 1.5)
                                                    .background(Color.orange.opacity(0.18))
                                                    .foregroundStyle(Color.orange)
                                                    .clipShape(Capsule())
                                            }
                                        }
                                    }
                                    HStack(spacing: 4) {
                                        Text("ID: \(item.id)")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                        Text("•")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        Text(item.subtitle)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                if item.pageAccessToken != nil {
                                    Text("Page Token")
                                        .font(.system(size: 9, weight: .bold))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Color.themeBackgroundPastel, in: Capsule())
                                        .foregroundStyle(Color.themePrimaryDark)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    @MainActor
    private func loadDestinationsForSelectedSpaces(kind: SmartPostDestinationType) async {
        guard !selectedSpaces.isEmpty else { return }
        isLoadingDestinations = true
        defer { isLoadingDestinations = false }

        var loaded: [FacebookDestinationItem] = []
        for space in selectedSpaces {
            let creds = await TrackedPostManager.resolveCookieAndToken(for: space)
            let token = creds.token
            let cookie = creds.cookie

            if kind == .fanpage {
                guard !token.isEmpty else { continue }
                let pages = await SmartPostAPIClient.fetchManagedPages(
                    accessToken: token,
                    spaceId: space.id,
                    spaceName: space.name
                )
                loaded.append(contentsOf: pages)
            } else if kind == .group {
                let groups = await SmartPostAPIClient.fetchJoinedGroups(
                    accessToken: token,
                    cookieString: cookie,
                    userId: creds.uid,
                    spaceId: space.id,
                    spaceName: space.name
                )
                loaded.append(contentsOf: groups)
            }
        }

        if kind == .group {
            // Giữ lại các nhóm nhập tay trước đó
            let manualExisting = discoveredGroups.filter { $0.ownerSpaceId == nil }
            var combined = manualExisting
            for g in loaded where !combined.contains(where: { $0.uniqueSelectionKey == g.uniqueSelectionKey }) {
                combined.append(g)
            }
            discoveredGroups = combined
            for g in combined { selectedDestinationKeys.insert(g.uniqueSelectionKey) }
        } else if kind == .fanpage {
            let manualExisting = discoveredPages.filter { $0.ownerSpaceId == nil }
            var combined = manualExisting
            for p in loaded where !combined.contains(where: { $0.uniqueSelectionKey == p.uniqueSelectionKey }) {
                combined.append(p)
            }
            discoveredPages = combined
            for p in combined { selectedDestinationKeys.insert(p.uniqueSelectionKey) }
        }
    }

    @MainActor
    private func resolveAndAddManualDestination(kind: SmartPostDestinationType) async {
        let raw = manualDestinationInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        isResolvingManualDestination = true
        defer { isResolvingManualDestination = false }

        let firstSpace = selectedSpaces.first ?? availableSpaces.first
        let creds: (cookie: String, token: String, uid: String)
        if let firstSpace {
            creds = await TrackedPostManager.resolveCookieAndToken(for: firstSpace)
        } else {
            creds = ("", "", "")
        }

        if let item = await SmartPostAPIClient.resolveDestinationFromInput(
            rawInput: raw,
            kind: kind,
            accessToken: creds.token,
            cookieString: creds.cookie,
            spaceId: nil, // Áp dụng cho mọi tài khoản đã chọn
            spaceName: "Áp dụng cho tài khoản đã chọn"
        ) {
            if kind == .group {
                if !discoveredGroups.contains(where: { $0.id == item.id && $0.ownerSpaceId == nil }) {
                    discoveredGroups.insert(item, at: 0)
                }
            } else if kind == .fanpage {
                if !discoveredPages.contains(where: { $0.id == item.id && $0.ownerSpaceId == nil }) {
                    discoveredPages.insert(item, at: 0)
                }
            }
            selectedDestinationKeys.insert(item.uniqueSelectionKey)
            manualDestinationInput = ""
        } else {
            alertMessage = "Không tìm thấy ID \(kind == .group ? "Nhóm" : "Fanpage") hợp lệ từ đường dẫn hoặc chuỗi đã nhập."
        }
    }

    // MARK: - Schedule Manager View

    @ViewBuilder
    private var scheduleManagerView: some View {
        List {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Quản lý danh sách lịch đăng")
                            .font(.headline)
                        Text("Hệ thống tự động kiểm tra và đăng theo mốc thời gian.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Kiểm tra ngay") {
                        Task { await scheduler.checkAndExecuteDueTasks() }
                    }
                    .font(.caption.bold())
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }

            if scheduler.tasks.isEmpty {
                ContentUnavailableView(
                    "Chưa có lịch đăng nào",
                    systemImage: "calendar.badge.clock",
                    description: Text("Hãy vào mục 'Soạn & Đăng bài' và bật 'Lên lịch đăng tự động' để tạo lịch.")
                )
            } else {
                ForEach(scheduler.tasks) { task in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(task.title)
                                .font(.subheadline.bold())
                                .lineLimit(1)
                            Spacer()
                            Text(task.status.rawValue)
                                .font(.caption2.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(task.status.badgeColor.opacity(0.18), in: Capsule())
                                .foregroundStyle(task.status.badgeColor)
                        }

                        HStack(spacing: 8) {
                            Label(task.scheduledDate.formatted(date: .numeric, time: .shortened), systemImage: "clock")
                                .font(.caption)
                                .foregroundStyle(Color.themePrimary)
                            Text("•")
                            Text("\((task.destinationType ?? .personalProfile).rawValue)")
                                .font(.caption.bold())
                                .foregroundStyle(Color.themePrimaryDark)
                            Text("•")
                            Text("\(task.targetSpaceIds.count) TK")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if task.videoFileName != nil {
                                Text("• Video MP4").font(.caption).foregroundStyle(.purple)
                            } else if !task.imageFileNames.isEmpty {
                                Text("• \(task.imageFileNames.count) ảnh").font(.caption).foregroundStyle(Color.themePrimary)
                            }
                        }

                        // Tags cho Reaction & Bình luận mồi
                        if task.autoReact == true || !(task.firstComment?.isEmpty ?? true) {
                            HStack(spacing: 6) {
                                if task.autoReact == true {
                                    Text("👍 \(task.reactionType ?? "LIKE") (\(Int(task.reactionRate ?? 100))%)")
                                        .font(.system(size: 10, weight: .semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.themeBackgroundPastel, in: Capsule())
                                        .foregroundStyle(Color.themePrimaryDark)
                                }
                                if let cmt = task.firstComment, !cmt.isEmpty {
                                    Text("💬 Bình luận mồi")
                                        .font(.system(size: 10, weight: .semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.teal.opacity(0.15), in: Capsule())
                                        .foregroundStyle(.teal)
                                }
                            }
                        }

                        if !task.caption.isEmpty {
                            Text(task.caption)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        if let log = task.executionLog {
                            Text(log)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.gray)
                                .padding(6)
                                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 6))
                        }

                        // Hàng nút thao tác nhanh: Theo dõi, Sửa, Thử lại, Xóa
                        HStack(spacing: 8) {
                            if let log = task.executionLog, log.contains("ID: ") {
                                Button {
                                    extractAndTrackPost(from: task)
                                    selectedTab = 2
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "chart.line.uptrend.xyaxis")
                                        Text("Theo dõi bài này")
                                    }
                                    .font(.caption.bold())
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.mini)
                                .tint(Color.themePrimary)
                            }

                            Button {
                                editingTask = task
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "pencil")
                                    Text("Sửa")
                                }
                                .font(.caption.bold())
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)

                            if task.status == .failed || task.status == .partial {
                                Button {
                                    scheduler.retryTask(task)
                                } label: {
                                    HStack(spacing: 3) {
                                        Image(systemName: "arrow.clockwise")
                                        Text("Thử lại")
                                    }
                                    .font(.caption.bold())
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                                .tint(Color.themePrimary)
                            }

                            Button(role: .destructive) {
                                scheduler.deleteTask(task)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .tint(.red)

                            Spacer()
                        }
                        .padding(.top, 2)
                    }
                    .padding(.vertical, 4)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            scheduler.deleteTask(task)
                        } label: {
                            Label("Xóa", systemImage: "trash")
                        }

                        Button {
                            editingTask = task
                        } label: {
                            Label("Sửa", systemImage: "pencil")
                        }
                        .tint(Color.themePrimary)
                    }
                    .swipeActions(edge: .leading) {
                        if task.status == .failed || task.status == .partial {
                            Button {
                                scheduler.retryTask(task)
                            } label: {
                                Label("Thử lại", systemImage: "arrow.clockwise")
                            }
                            .tint(Color.themePrimary)
                        }
                    }
                }
            }
        }
    }

    private func extractAndTrackPost(from task: ScheduledPostTask) {
        guard let log = task.executionLog else { return }
        let pattern = #"ID:\s*([0-9_]{5,35})"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let nsRange = NSRange(log.startIndex..<log.endIndex, in: log)
            for match in regex.matches(in: log, range: nsRange) {
                if let idRange = Range(match.range(at: 1), in: log) {
                    let pid = String(log[idRange])
                    let firstSpace = selectedSpaces.first(where: { task.targetSpaceIds.contains($0.id) }) ?? availableSpaces.first
                    let spaceId = firstSpace?.id ?? UUID()
                    let spaceName = firstSpace?.name ?? "Lịch đăng"
                    let postUrl = "https://www.facebook.com/\(pid)"
                    TrackedPostManager.shared.registerPublishedPost(
                        spaceId: spaceId,
                        spaceName: spaceName,
                        postId: pid,
                        postUrl: postUrl,
                        caption: task.caption,
                        enableAIAutoReply: true
                    )
                }
            }
        }
    }

    private var canSubmit: Bool {
        guard !isPublishing, !selectedSpaces.isEmpty else { return false }
        if isPrivacyOnlyMode {
            return !targetPostIdToUpdatePrivacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } else {
            let hasContent = !postCaption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !selectedImages.isEmpty || selectedVideoData != nil
            guard hasContent else { return false }
            if destinationType == .personalProfile {
                return true
            } else {
                return !activeSelectedDestinations.isEmpty || !manualDestinationInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
    }

    private func schedulePost() {
        scheduler.addTask(
            caption: postCaption,
            spaceIds: selectedSpaces.map(\.id),
            privacy: privacyOption,
            destinationType: destinationType,
            targetDestinations: activeSelectedDestinations,
            scheduledDate: scheduledDate,
            images: selectedImages,
            videoData: selectedVideoData,
            autoReact: enableAutoReact,
            reactionType: selectedReaction,
            reactionRate: reactionPercentage,
            firstComment: enableFirstComment ? firstCommentText : nil
        )
        alertMessage = "Đã lên lịch đăng (\(destinationType.rawValue)) thành công vào lúc \(scheduledDate.formatted(date: .numeric, time: .shortened))!"
        selectedTab = 1 // Chuyển sang xem danh sách lịch
    }

    @MainActor
    private func executeSmartPost() async {
        guard !isPublishing else { return }
        isPublishing = true
        results.removeAll()
        defer { isPublishing = false }

        // Nếu người dùng đang gõ dở link/ID Nhóm hoặc Fanpage mà quên bấm "Thêm", tự động chuyển đổi & thêm luôn
        if destinationType != .personalProfile && activeSelectedDestinations.isEmpty && !manualDestinationInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await resolveAndAddManualDestination(kind: destinationType)
        }

        for (idx, space) in selectedSpaces.enumerated() {
            progressMessage = "Đang xử lý (\(idx + 1)/\(selectedSpaces.count)): \(space.name)..."

            guard let vault = try? SecureLoginStore.readTokenVault(space.id),
                  let token = SmartPostAPIClient.resolveBestAccessToken(from: vault),
                  !token.isEmpty else {
                results.append(SmartPostResult(
                    spaceName: space.name,
                    isSuccess: false,
                    postId: nil,
                    postUrl: nil,
                    message: "Chưa có Access Token API hợp lệ. Vui lòng vào 'Kho Token' kiểm tra hoặc kết nối lại."
                ))
                continue
            }

            // Kiểm tra token trước khi đăng
            let tokenValidation = await SmartPostAPIClient.validateAccessToken(token)
            if !tokenValidation.isValid {
                let cleanErr = SmartPostAPIClient.formatFacebookAPIError(tokenValidation.message)
                results.append(SmartPostResult(
                    spaceName: space.name,
                    isSuccess: false,
                    postId: nil,
                    postUrl: nil,
                    message: "Token không hợp lệ (\(cleanErr)). Hãy vào 'Kho Token' lấy lại token."
                ))
                continue
            }
            let uid = vault.uid.isEmpty ? "me" : vault.uid

            if isPrivacyOnlyMode {
                do {
                    let ok = try await SmartPostAPIClient.updatePostPrivacy(
                        postId: targetPostIdToUpdatePrivacy.trimmingCharacters(in: .whitespacesAndNewlines),
                        privacy: privacyOption,
                        accessToken: token
                    )
                    results.append(SmartPostResult(
                        spaceName: space.name,
                        isSuccess: ok,
                        postId: targetPostIdToUpdatePrivacy,
                        postUrl: nil,
                        message: ok ? "Đã đổi sang \(privacyOption.rawValue)" : "Facebook từ chối"
                    ))
                } catch {
                    results.append(SmartPostResult(
                        spaceName: space.name,
                        isSuccess: false,
                        postId: targetPostIdToUpdatePrivacy,
                        postUrl: nil,
                        message: error.localizedDescription
                    ))
                }
                continue
            }

            // Trường hợp 1: Đăng lên Trang cá nhân (Personal Profile)
            if destinationType == .personalProfile {
                if let vdata = selectedVideoData {
                    do {
                        progressMessage = "\(space.name): Đang đăng Video MP4 lên Trang cá nhân..."
                        let videoId = try await SmartPostAPIClient.uploadVideo(
                            videoData: vdata,
                            caption: postCaption,
                            accessToken: token,
                            userId: uid
                        )
                        let videoUrl = "https://www.facebook.com/watch/?v=\(videoId)"
                        tracker.registerPublishedPost(
                            spaceId: space.id,
                            spaceName: space.name,
                            postId: videoId,
                            postUrl: videoUrl,
                            caption: postCaption,
                            enableAIAutoReply: autoTrackAndAIReply
                        )
                        await triggerPostReactionAndCommentDirect(postId: videoId, token: token)
                        results.append(SmartPostResult(
                            spaceName: "\(space.name) (Cá nhân)",
                            isSuccess: true,
                            postId: videoId,
                            postUrl: videoUrl,
                            message: "Đăng Video lên Trang cá nhân thành công!"
                        ))
                    } catch {
                        results.append(SmartPostResult(
                            spaceName: "\(space.name) (Cá nhân)",
                            isSuccess: false,
                            postId: nil,
                            postUrl: nil,
                            message: error.localizedDescription
                        ))
                    }
                } else {
                    do {
                        var uploadedPhotoIds: [String] = []
                        for (pIdx, uiImg) in selectedImages.enumerated() {
                            progressMessage = "\(space.name): Đang tải ảnh \(pIdx + 1)/\(selectedImages.count)..."
                            if let jpegData = uiImg.jpegData(compressionQuality: 0.85) {
                                let photoId = try await SmartPostAPIClient.uploadPhoto(imageData: jpegData, accessToken: token)
                                uploadedPhotoIds.append(photoId)
                            }
                        }

                        progressMessage = "\(space.name): Đang xuất bản bài viết lên Trang cá nhân..."
                        let res = try await SmartPostAPIClient.createPost(
                            caption: postCaption,
                            photoIds: uploadedPhotoIds,
                            privacy: privacyOption,
                            destinationType: .personalProfile,
                            accessToken: token,
                            userId: uid
                        )

                        tracker.registerPublishedPost(
                            spaceId: space.id,
                            spaceName: space.name,
                            postId: res.postId,
                            postUrl: res.postUrl,
                            caption: postCaption,
                            enableAIAutoReply: autoTrackAndAIReply
                        )
                        await triggerPostReactionAndCommentDirect(postId: res.postId, token: token)

                        results.append(SmartPostResult(
                            spaceName: "\(space.name) (Cá nhân)",
                            isSuccess: true,
                            postId: res.postId,
                            postUrl: res.postUrl,
                            message: "Đăng Trang cá nhân thành công! (\(privacyOption.rawValue))"
                        ))
                    } catch {
                        results.append(SmartPostResult(
                            spaceName: "\(space.name) (Cá nhân)",
                            isSuccess: false,
                            postId: nil,
                            postUrl: nil,
                            message: error.localizedDescription
                        ))
                    }
                }
            } else {
                // Trường hợp 2: Đăng lên Nhóm (Group) hoặc Trang (Fanpage)
                let targetsForSpace = activeSelectedDestinations.filter { $0.ownerSpaceId == nil || $0.ownerSpaceId == space.id }
                if targetsForSpace.isEmpty {
                    results.append(SmartPostResult(
                        spaceName: space.name,
                        isSuccess: false,
                        postId: nil,
                        postUrl: nil,
                        message: "Không có \(destinationType.shortLabel) nào được chọn cho tài khoản này."
                    ))
                    continue
                }

                for dest in targetsForSpace {
                    let label = "\(space.name) → \(dest.name)"
                    let effectiveUploadToken = (destinationType == .fanpage ? dest.pageAccessToken : nil) ?? token
                    let photoUploadTarget = destinationType == .fanpage ? dest.id : "me"

                    if let vdata = selectedVideoData {
                        do {
                            progressMessage = "\(label): Đang đăng Video MP4..."
                            let videoId = try await SmartPostAPIClient.uploadVideo(
                                videoData: vdata,
                                caption: postCaption,
                                accessToken: effectiveUploadToken,
                                userId: dest.id
                            )
                            let videoUrl = "https://www.facebook.com/watch/?v=\(videoId)"
                            tracker.registerPublishedPost(
                                spaceId: space.id,
                                spaceName: label,
                                postId: videoId,
                                postUrl: videoUrl,
                                caption: postCaption,
                                enableAIAutoReply: autoTrackAndAIReply
                            )
                            await triggerPostReactionAndCommentDirect(postId: videoId, token: effectiveUploadToken)

                            results.append(SmartPostResult(
                                spaceName: label,
                                isSuccess: true,
                                postId: videoId,
                                postUrl: videoUrl,
                                message: "Đăng Video lên \(destinationType.shortLabel) thành công!"
                            ))
                        } catch {
                            results.append(SmartPostResult(
                                spaceName: label,
                                isSuccess: false,
                                postId: nil,
                                postUrl: nil,
                                message: error.localizedDescription
                            ))
                        }
                    } else {
                        do {
                            var uploadedPhotoIds: [String] = []
                            for (pIdx, uiImg) in selectedImages.enumerated() {
                                progressMessage = "\(label): Đang tải ảnh \(pIdx + 1)/\(selectedImages.count)..."
                                if let jpegData = uiImg.jpegData(compressionQuality: 0.85) {
                                    let photoId = try await SmartPostAPIClient.uploadPhoto(
                                        imageData: jpegData,
                                        accessToken: effectiveUploadToken,
                                        targetId: photoUploadTarget
                                    )
                                    uploadedPhotoIds.append(photoId)
                                }
                            }

                            progressMessage = "\(label): Đang xuất bản bài viết..."
                            let res = try await SmartPostAPIClient.createPost(
                                caption: postCaption,
                                photoIds: uploadedPhotoIds,
                                privacy: privacyOption,
                                destinationType: destinationType,
                                targetDestinationId: dest.id,
                                pageAccessToken: dest.pageAccessToken,
                                accessToken: token,
                                userId: uid
                            )

                            tracker.registerPublishedPost(
                                spaceId: space.id,
                                spaceName: label,
                                postId: res.postId,
                                postUrl: res.postUrl,
                                caption: postCaption,
                                enableAIAutoReply: autoTrackAndAIReply
                            )
                            await triggerPostReactionAndCommentDirect(postId: res.postId, token: effectiveUploadToken)

                            results.append(SmartPostResult(
                                spaceName: label,
                                isSuccess: true,
                                postId: res.postId,
                                postUrl: res.postUrl,
                                message: "Đăng lên \(destinationType.shortLabel) (\(dest.name)) thành công!"
                            ))
                        } catch {
                            results.append(SmartPostResult(
                                spaceName: label,
                                isSuccess: false,
                                postId: nil,
                                postUrl: nil,
                                message: error.localizedDescription
                            ))
                        }
                    }
                }
            }
        }
        progressMessage = "Hoàn tất!"
    }

    private func triggerPostReactionAndCommentDirect(postId: String, token: String) async {
        if enableAutoReact {
            let roll = Double.random(in: 0...100)
            if roll <= reactionPercentage {
                let rType = FacebookReactionType(rawValue: selectedReaction) ?? .like
                _ = await SmartPostAPIClient.reactToPost(postId: postId, reaction: rType, accessToken: token)
            }
        }
        if enableFirstComment && !firstCommentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = await SmartPostAPIClient.commentOnPost(postId: postId, commentText: firstCommentText, accessToken: token)
        }
    }
}

// MARK: - Edit Scheduled Post Sheet

struct EditScheduleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var scheduler = ScheduledPostManager.shared
    @State var task: ScheduledPostTask

    @State private var caption: String
    @State private var scheduledDate: Date
    @State private var autoReact: Bool
    @State private var reactionType: String
    @State private var reactionRate: Double
    @State private var enableFirstComment: Bool
    @State private var firstComment: String

    init(task: ScheduledPostTask) {
        self._task = State(initialValue: task)
        self._caption = State(initialValue: task.caption)
        self._scheduledDate = State(initialValue: task.scheduledDate)
        self._autoReact = State(initialValue: task.autoReact ?? false)
        self._reactionType = State(initialValue: task.reactionType ?? "LIKE")
        self._reactionRate = State(initialValue: task.reactionRate ?? 100.0)
        let hasComment = !(task.firstComment?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        self._enableFirstComment = State(initialValue: hasComment)
        self._firstComment = State(initialValue: task.firstComment ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Nội dung bài viết") {
                    TextField("Nhập nội dung chia sẻ...", text: $caption, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section("Thời gian đăng") {
                    DatePicker("Hẹn giờ", selection: $scheduledDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.compact)
                }

                Section("Tương tác tự động (Reaction & Bình luận mồi)") {
                    Toggle("Tự động thả Reaction", isOn: $autoReact)
                        .tint(Color.themePrimary)

                    if autoReact {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Loại cảm xúc:")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(FacebookReactionType.concreteReactions) { rType in
                                        let isSel = reactionType == rType.rawValue
                                        Button {
                                            reactionType = rType.rawValue
                                        } label: {
                                            Text(rType.label)
                                                .font(.caption.bold())
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 6)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 8)
                                                        .fill(isSel ? Color.themePrimary : Color(uiColor: .secondarySystemGroupedBackground))
                                                )
                                                .foregroundStyle(isSel ? Color.white : Color.primary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }

                            HStack {
                                Text("Tỷ lệ thả:")
                                    .font(.caption.bold())
                                Spacer()
                                Text("\(Int(reactionRate))%")
                                    .font(.caption.bold())
                                    .foregroundStyle(Color.themePrimary)
                            }

                            Slider(value: $reactionRate, in: 10...100, step: 10)
                                .tint(Color.themePrimary)
                        }
                        .padding(.vertical, 2)
                    }

                    Toggle("Gắn 1 bình luận đầu tiên", isOn: $enableFirstComment)
                        .tint(Color.themePrimary)

                    if enableFirstComment {
                        TextField("Nội dung bình luận mồi...", text: $firstComment, axis: .vertical)
                            .lineLimit(2...4)
                    }
                }

                Section {
                    Button {
                        var updated = task
                        updated.caption = caption
                        updated.scheduledDate = scheduledDate
                        updated.autoReact = autoReact
                        updated.reactionType = reactionType
                        updated.reactionRate = reactionRate
                        updated.firstComment = enableFirstComment ? firstComment : nil
                        if updated.status == .failed || updated.status == .partial {
                            updated.status = .pending
                        }
                        scheduler.updateTask(updated)
                        dismiss()
                    } label: {
                        HStack {
                            Spacer()
                            Label("Lưu thay đổi", systemImage: "checkmark.circle.fill")
                                .font(.headline)
                                .foregroundStyle(.white)
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(Color.themePrimary)
                }
            }
            .navigationTitle("Sửa lịch đăng")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Hủy") { dismiss() }
                }
            }
        }
    }
}
