import SwiftUI
import WebKit
import UIKit

enum BatchMode: String, CaseIterable {
    case targetInteract = "React & Comment"
    case openURL = "Mở URL"
    case refresh = "Nạp lại"
}

enum TargetCategoryHint: String, CaseIterable, Identifiable {
    case auto = "Tự nhận diện"
    case post = "Bài viết"
    case reel = "Reel / Video"
    case group = "Nhóm (Group)"
    case fanpage = "Fanpage"
    var id: String { rawValue }
}

enum TargetCommentSource: String, CaseIterable, Identifiable {
    case manualLines = "📋 Dán Comment (1 hàng/space)"
    case geminiAI = "✨ Gemini tự sinh (Không trùng)"
    var id: String { rawValue }
}

enum BatchStatus {
    case queued, loading, success, failed, cancelled

    var title: String {
        switch self {
        case .queued: return "Đang chờ"
        case .loading: return "Đang chạy"
        case .success: return "Hoàn tất"
        case .failed: return "Thất bại"
        case .cancelled: return "Đã dừng"
        }
    }

    var symbol: String {
        switch self {
        case .queued: return "clock"
        case .loading: return "arrow.triangle.2.circlepath"
        case .success: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .cancelled: return "stop.circle"
        }
    }

    var tint: Color {
        switch self {
        case .queued: return .secondary
        case .loading: return .blue
        case .success: return .green
        case .failed: return .red
        case .cancelled: return .orange
        }
    }
}

struct BatchRow: Identifiable {
    let id: UUID
    let name: String
    var status: BatchStatus = .queued
    var detail: String = "Chưa thực hiện"
    var assignedComment: String = ""
    var reactionDone: String = ""
}

@MainActor
final class BatchSyncEngine: NSObject, ObservableObject, WKNavigationDelegate {
    @Published private(set) var rows: [BatchRow] = []
    @Published private(set) var isRunning = false
    @Published private(set) var activeWebView: WKWebView?
    @Published var resolvedTargetPreview: ResolvedTargetPost?
    @Published var isResolvingTarget = false

    private var queue: [Space] = []
    private var activeSpace: Space?
    private var activeTarget: URL?
    private var targetURL: URL?
    private var mode: BatchMode = .targetInteract
    private weak var library: SpaceLibrary?
    private var timeoutTask: Task<Void, Never>?
    private var interactTask: Task<Void, Never>?

    var completed: Int {
        rows.filter { $0.status == .success || $0.status == .failed || $0.status == .cancelled }.count
    }
    var succeeded: Int {
        rows.filter { $0.status == .success }.count
    }

    // MARK: - Web Navigation Batch Mode (Mở URL / Nạp lại)

    func start(spaces: [Space], mode: BatchMode, url: URL?, library: SpaceLibrary) {
        guard !isRunning, !spaces.isEmpty else { return }
        if mode == .openURL && url == nil { return }
        self.library = library
        self.mode = mode
        self.targetURL = url
        queue = spaces
        rows = spaces.map { BatchRow(id: $0.id, name: $0.name) }
        isRunning = true
        loadNext()
    }

    // MARK: - Target Post / Reel / Group / Fanpage Reaction & Comment Batch Mode

    func resolveTargetInfo(
        targetInput: String,
        categoryHint: TargetCategoryHint,
        manualContextText: String,
        spaces: [Space]
    ) async throws -> ResolvedTargetPost {
        isResolvingTarget = true
        defer { isResolvingTarget = false }

        var sampleCookie = ""
        var sampleToken = ""
        var sampleProxy: SpaceProxy? = nil
        var sampleUA: String? = nil
        for sp in spaces {
            let creds = await Self.resolveCookieAndToken(for: sp)
            if !creds.cookie.isEmpty {
                sampleCookie = creds.cookie
                sampleToken = creds.token
                sampleProxy = sp.proxy
                sampleUA = sp.fingerprint?.userAgent
                break
            }
        }

        var resolved = try await FacebookTargetPostResolver.resolve(
            input: targetInput,
            cookieString: sampleCookie,
            accessToken: sampleToken,
            proxy: sampleProxy,
            userAgent: sampleUA
        )
        if categoryHint != .auto {
            resolved.targetKind = categoryHint.rawValue
        }
        let extraContext = manualContextText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extraContext.isEmpty {
            resolved.postText = resolved.postText.isEmpty
                ? extraContext
                : "\(resolved.postText)\n[Ghi chú thêm]: \(extraContext)"
        }
        resolvedTargetPreview = resolved
        return resolved
    }

    func startTargetInteraction(
        spaces: [Space],
        targetInput: String,
        categoryHint: TargetCategoryHint,
        manualContextText: String,
        useReaction: Bool,
        reactionType: FacebookReactionType,
        useComment: Bool,
        commentSource: TargetCommentSource,
        manualLines: [String],
        aiFallbackWhenLinesShort: Bool,
        geminiApiKey: String,
        geminiModel: String,
        geminiStylePrompt: String,
        safeModeEnabled: Bool,
        minActionGap: Double,
        maxActionGap: Double,
        minSpaceDelay: Double,
        maxSpaceDelay: Double
    ) {
        guard !isRunning, !spaces.isEmpty else { return }
        stop()
        mode = .targetInteract
        isRunning = true

        var initialRows: [BatchRow] = []
        for idx in spaces.indices {
            let sp = spaces[idx]
            var initialComment = ""
            if useComment && commentSource == .manualLines && idx < manualLines.count {
                initialComment = manualLines[idx]
            }
            initialRows.append(
                BatchRow(
                    id: sp.id,
                    name: sp.name,
                    status: .queued,
                    detail: "Đang chờ tới lượt",
                    assignedComment: initialComment
                )
            )
        }
        rows = initialRows

        interactTask = Task {
            let target: ResolvedTargetPost
            do {
                if !rows.isEmpty {
                    rows[0].detail = "Đang phân tích Link/ID mục tiêu..."
                }
                target = try await resolveTargetInfo(
                    targetInput: targetInput,
                    categoryHint: categoryHint,
                    manualContextText: manualContextText,
                    spaces: spaces
                )
            } catch {
                for i in rows.indices {
                    rows[i].status = .failed
                    rows[i].detail = error.localizedDescription
                }
                isRunning = false
                return
            }

            var usedComments: [String] = []
            for line in manualLines where !line.isEmpty {
                if !usedComments.contains(line) {
                    usedComments.append(line)
                }
            }

            for idx in spaces.indices {
                if Task.isCancelled || !isRunning { break }
                let space = spaces[idx]

                mark(space, status: .loading, detail: "Đang chuẩn bị Cookie & fb_dtsg...")
                let creds = await Self.resolveCookieAndToken(for: space)
                guard !creds.cookie.isEmpty else {
                    mark(space, status: .failed, detail: "Không gian chưa có Cookie! Hãy lấy Token/Cookie trước.")
                    continue
                }

                let client = FacebookGraphQLAutoClient(
                    spaceId: space.id,
                    cookieString: creds.cookie,
                    accessToken: creds.token,
                    proxy: space.proxy,
                    userAgent: space.fingerprint?.userAgent
                )

                do {
                    _ = try await client.prepareTokens()
                } catch {
                    mark(space, status: .failed, detail: "Lỗi lấy token phiên: \(error.localizedDescription)")
                    continue
                }

                var commentToSend = ""
                var aiSuggestedReaction: FacebookReactionType? = nil
                var commentError: String? = nil

                if useComment {
                    if commentSource == .manualLines {
                        if idx < manualLines.count {
                            commentToSend = manualLines[idx]
                        } else if aiFallbackWhenLinesShort {
                            mark(space, status: .loading, detail: "✨ Gemini đang sinh bình luận bổ sung (không trùng)...")
                            do {
                                let res = try await GeminiCommentService.generateUniqueCommentForTarget(
                                    target: target,
                                    spaceName: space.name,
                                    spaceIndex: idx,
                                    totalSpaces: spaces.count,
                                    previousComments: usedComments,
                                    apiKey: geminiApiKey,
                                    model: geminiModel,
                                    customStylePrompt: geminiStylePrompt
                                )
                                commentToSend = res.comment
                                aiSuggestedReaction = res.suggestedReaction
                                usedComments.append(res.comment)
                            } catch {
                                commentError = error.localizedDescription
                            }
                        } else {
                            commentError = "Không có dòng comment tương ứng (dòng \(idx + 1))"
                        }
                    } else {
                        mark(space, status: .loading, detail: "✨ Gemini đang phân tích \(target.targetKind) & sinh cmt riêng...")
                        do {
                            let res = try await GeminiCommentService.generateUniqueCommentForTarget(
                                target: target,
                                spaceName: space.name,
                                spaceIndex: idx,
                                totalSpaces: spaces.count,
                                previousComments: usedComments,
                                apiKey: geminiApiKey,
                                model: geminiModel,
                                customStylePrompt: geminiStylePrompt
                            )
                            commentToSend = res.comment
                            aiSuggestedReaction = res.suggestedReaction
                            usedComments.append(res.comment)
                        } catch {
                            commentError = error.localizedDescription
                        }
                    }
                } else if reactionType == .geminiAuto {
                    mark(space, status: .loading, detail: "✨ Gemini đang chọn cảm xúc phù hợp...")
                    if let res = try? await GeminiCommentService.generateUniqueCommentForTarget(
                        target: target,
                        spaceName: space.name,
                        spaceIndex: idx,
                        totalSpaces: spaces.count,
                        previousComments: usedComments,
                        apiKey: geminiApiKey,
                        model: geminiModel,
                        customStylePrompt: geminiStylePrompt
                    ) {
                        aiSuggestedReaction = res.suggestedReaction
                    }
                }

                updateRowMeta(space, reaction: nil, comment: commentToSend)

                var reactSucceeded = true
                var reactSummary = ""
                if useReaction {
                    let chosenReaction: FacebookReactionType
                    if reactionType == .geminiAuto, let suggested = aiSuggestedReaction {
                        chosenReaction = suggested
                    } else {
                        chosenReaction = reactionType.resolveConcrete()
                    }
                    mark(space, status: .loading, detail: "Đang thả cảm xúc \(chosenReaction.rawValue)...")
                    let reactRes = await client.reactToPost(
                        postId: target.postId,
                        reaction: chosenReaction,
                        explicitFeedbackId: target.feedbackId
                    )
                    reactSucceeded = reactRes.success
                    reactSummary = reactRes.success ? "❤️ \(chosenReaction.rawValue)" : "❌ Lỗi React: \(reactRes.message)"
                    updateRowMeta(space, reaction: chosenReaction.rawValue, comment: nil)

                    if useComment && !commentToSend.isEmpty {
                        let ok = await sleepRandom(
                            space: space,
                            minVal: minActionGap,
                            maxVal: maxActionGap,
                            safeMode: safeModeEnabled,
                            reason: "nghỉ giữa Reaction & Comment"
                        )
                        if !ok { break }
                    }
                }

                var commentSucceeded = true
                var commentSummary = ""
                if useComment {
                    if !commentToSend.isEmpty {
                        mark(space, status: .loading, detail: "Đang gửi bình luận: \"\(commentToSend.prefix(35))...\"")
                        let cmtRes = await client.commentOnPost(
                            postId: target.postId,
                            commentText: commentToSend,
                            explicitFeedbackId: target.feedbackId
                        )
                        commentSucceeded = cmtRes.success
                        commentSummary = cmtRes.success
                            ? "💬 Đã cmt: \"\(commentToSend)\""
                            : "❌ Lỗi Cmt: \(cmtRes.message)"
                    } else {
                        commentSucceeded = false
                        commentSummary = "❌ \(commentError ?? "Chưa có nội dung comment")"
                    }
                }

                let finalSuccess = (!useReaction || reactSucceeded) && (!useComment || commentSucceeded)
                let combinedDetail = [reactSummary, commentSummary]
                    .filter { !$0.isEmpty }
                    .joined(separator: " • ")

                mark(
                    space,
                    status: finalSuccess ? .success : .failed,
                    detail: combinedDetail.isEmpty ? "Hoàn tất" : combinedDetail
                )

                if idx < spaces.count - 1 {
                    let ok = await sleepRandom(
                        space: spaces[idx + 1],
                        minVal: minSpaceDelay,
                        maxVal: maxSpaceDelay,
                        safeMode: safeModeEnabled,
                        reason: "chờ SafeMode trước khi chạy không gian tiếp theo"
                    )
                    if !ok { break }
                }
            }

            if !Task.isCancelled {
                isRunning = false
            }
        }
    }

    private func sleepRandom(
        space: Space,
        minVal: Double,
        maxVal: Double,
        safeMode: Bool,
        reason: String
    ) async -> Bool {
        let low = max(0.1, min(minVal, maxVal))
        let high = max(low, max(minVal, maxVal))
        var waitSec = Double.random(in: low...high)
        if safeMode {
            waitSec += Double.random(in: 0.05...0.95)
        }
        let prefix = safeMode ? "🛡️ SafeMode" : "⏳ Chờ"
        mark(space, status: .loading, detail: String(format: "%@: %@ (%.1fs)...", prefix, reason, waitSec))
        do {
            try await Task.sleep(nanoseconds: UInt64(waitSec * 1_000_000_000))
            return !Task.isCancelled && isRunning
        } catch {
            return false
        }
    }

    private static func resolveCookieAndToken(for space: Space) async -> (cookie: String, token: String) {
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
            return (FacebookAppTokens.formatCookieString(webCookies), "")
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        timeoutTask?.cancel()
        timeoutTask = nil
        interactTask?.cancel()
        interactTask = nil
        activeWebView?.navigationDelegate = nil
        activeWebView?.stopLoading()
        activeWebView = nil
        activeSpace = nil
        activeTarget = nil
        queue.removeAll()
        for index in rows.indices {
            if rows[index].status == .queued || rows[index].status == .loading {
                rows[index].status = .cancelled
                rows[index].detail = "Đã dừng theo yêu cầu"
            }
        }
    }

    private func mark(_ space: Space, status: BatchStatus, detail: String) {
        guard let index = rows.firstIndex(where: { $0.id == space.id }) else { return }
        rows[index].status = status
        rows[index].detail = detail
    }

    private func updateRowMeta(_ space: Space, reaction: String?, comment: String?) {
        guard let index = rows.firstIndex(where: { $0.id == space.id }) else { return }
        if let reaction { rows[index].reactionDone = reaction }
        if let comment, !comment.isEmpty { rows[index].assignedComment = comment }
    }

    private func loadNext() {
        guard isRunning else { return }
        guard !queue.isEmpty else {
            isRunning = false
            activeWebView = nil
            return
        }

        let space = queue.removeFirst()
        let address = mode == .openURL
            ? targetURL
            : (library?.lastPage(for: space) ?? SpaceLibrary.safeURL(space.url))
        guard let address else {
            mark(space, status: .failed, detail: "Địa chỉ HTTPS không hợp lệ")
            loadNext()
            return
        }

        activeSpace = space
        activeTarget = address
        mark(space, status: .loading, detail: address.host ?? "Đang kết nối")

        let config = WKWebViewConfiguration()
        let store = WKWebsiteDataStore(forIdentifier: space.id)
        if let proxy = space.proxy, proxy.isEnabled {
            store.proxyConfigurations = [proxy.toNetworkProxyConfiguration()]
        } else {
            store.proxyConfigurations = []
        }
        config.websiteDataStore = store

        let fp = space.fingerprint ?? SpaceFingerprint.defaultFor(spaceId: space.id)

        let contentController = WKUserContentController()
        let scriptSource = fp.buildAntiDetectScript()
        contentController.addUserScript(WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = fp.userAgent
        webView.navigationDelegate = self
        activeWebView = webView

        timeoutTask?.cancel()
        timeoutTask = Task { [weak self, weak webView] in
            do {
                try await Task.sleep(nanoseconds: 40_000_000_000)
                guard let self, let webView, self.activeWebView === webView else { return }
                self.finish(webView, status: .failed, detail: "Quá thời gian tải (40 giây)")
            } catch {}
        }
        Task { [weak self, weak webView] in
            await Task.yield()
            guard let self, let webView,
                  self.activeWebView === webView, self.isRunning else { return }
            if let vault = try? SecureLoginStore.readTokenVault(space.id) {
                _ = await WebCookieBridge.injectCookies(from: vault, into: space.id)
            }
            guard self.activeWebView === webView, self.isRunning else { return }
            webView.load(URLRequest(url: address))
        }
    }

    private func finish(_ webView: WKWebView, status: BatchStatus, detail: String) {
        guard isRunning, let space = activeSpace, activeWebView === webView else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        if status == .success, let address = activeTarget {
            library?.remember(address, for: space)
        }
        mark(space, status: status, detail: detail)
        webView.navigationDelegate = nil
        webView.stopLoading()
        activeWebView = nil
        activeSpace = nil
        activeTarget = nil
        loadNext()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(webView, status: .success, detail: "Trang đã nạp thành công")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(webView, status: .failed, detail: error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(webView, status: .failed, detail: error.localizedDescription)
    }
}

struct BatchWebPreview: UIViewRepresentable {
    let webView: WKWebView?

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .systemBackground
        container.clipsToBounds = true
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        guard container.subviews.first !== webView else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        if let webView {
            webView.frame = container.bounds
            webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(webView)
        }
    }
}

struct MultiSpaceSyncView: View {
    @EnvironmentObject private var library: SpaceLibrary
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var engine = BatchSyncEngine()

    @State private var selectedIDs: Set<UUID> = []
    @State private var mode: BatchMode = .targetInteract
    @State private var urlText = "https://www.facebook.com/"

    @State private var targetCategory: TargetCategoryHint = .auto
    @State private var targetPostInput = ""
    @State private var manualContextText = ""

    @AppStorage("vie.sync.useReaction") private var useReaction = true
    @AppStorage("vie.sync.reactionType") private var reactionTypeRaw = FacebookReactionType.love.rawValue
    @AppStorage("vie.sync.useComment") private var useComment = true
    @AppStorage("vie.sync.commentSource") private var commentSourceRaw = TargetCommentSource.geminiAI.rawValue
    @State private var rawManualComments = ""
    @AppStorage("vie.sync.aiFallbackShort") private var aiFallbackWhenLinesShort = true

    @AppStorage("vie.auto.geminiModelV2") private var geminiModel = "auto"
    @AppStorage("vie.sync.geminiStyle") private var geminiStylePrompt = "Tự nhiên như người dùng thật, đúng trọng tâm nội dung bài đăng, ngắn gọn 1-2 câu, mỗi tài khoản một văn phong khác nhau."
    @State private var geminiApiKey = ""

    @AppStorage("vie.sync.safeMode") private var safeModeEnabled = true
    @AppStorage("vie.sync.minActionGap") private var minActionGapText = "2"
    @AppStorage("vie.sync.maxActionGap") private var maxActionGapText = "5"
    @AppStorage("vie.sync.minSpaceDelay") private var minSpaceDelayText = "5"
    @AppStorage("vie.sync.maxSpaceDelay") private var maxSpaceDelayText = "20"

    @State private var alertMessage: String?

    private var selectedSpaces: [Space] {
        library.spaces.filter { selectedIDs.contains($0.id) }
    }

    private var targetURL: URL? {
        SpaceLibrary.safeURL(urlText)
    }

    private var reactionType: FacebookReactionType {
        FacebookReactionType(rawValue: reactionTypeRaw) ?? .love
    }

    private var commentSource: TargetCommentSource {
        TargetCommentSource(rawValue: commentSourceRaw) ?? .geminiAI
    }

    private var parsedManualCommentLines: [String] {
        rawManualComments
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var hasDuplicateManualLines: Bool {
        let lines = parsedManualCommentLines
        return Set(lines).count != lines.count
    }

    private var canStart: Bool {
        guard !engine.isRunning, !selectedSpaces.isEmpty else { return false }
        switch mode {
        case .openURL:
            return targetURL != nil
        case .refresh:
            return true
        case .targetInteract:
            return !targetPostInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (useReaction || useComment)
        }
    }

    var body: some View {
        Form {
            spaceSelectionSection
            modeSelectionSection
            if mode == .targetInteract {
                targetInputSection
                reactionAndCommentSection
                safeModeSection
            }
            actionButtonSection
            statusRowsSection
            webPreviewSection
        }
        .navigationTitle("MultiSpace Sync")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if geminiApiKey.isEmpty {
                geminiApiKey = SecureGeminiStore.readKey()
            }
            if selectedIDs.isEmpty {
                selectedIDs = Set(library.spaces.map(\.id))
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background && mode != .targetInteract { engine.stop() }
        }
        .onDisappear { engine.stop() }
        .alert("Thông báo", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK") { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    @ViewBuilder
    private var spaceSelectionSection: some View {
        Section {
            HStack {
                Text("Đã chọn \(selectedSpaces.count)/\(library.spaces.count) không gian")
                    .font(.subheadline.bold())
                Spacer()
                Button("Tất cả") {
                    selectedIDs = Set(library.spaces.map(\.id))
                }
                .disabled(engine.isRunning)
                Button("Bỏ chọn") {
                    selectedIDs.removeAll()
                }
                .disabled(engine.isRunning)
            }
            ForEach(library.spaces) { space in
                let summary = VaultMetadataIndex.get(space.id)
                let isSelected = selectedIDs.contains(space.id)
                Button {
                    guard !engine.isRunning else { return }
                    if isSelected { selectedIDs.remove(space.id) }
                    else { selectedIDs.insert(space.id) }
                } label: {
                    HStack {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? Color.blue : Color.secondary)
                        Image(systemName: space.platform.icon)
                            .foregroundStyle(space.platform.color)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(space.name).foregroundStyle(.primary)
                            if summary.hasToken || summary.hasCookies {
                                Text("Sẵn sàng • Đã lưu Cookie & Token")
                                    .font(.caption2).foregroundStyle(.green)
                            }
                        }
                        Spacer()
                    }
                }
                .disabled(engine.isRunning)
            }
        } header: {
            Text("1. Chọn không gian")
        } footer: {
            Text("Dùng trực tiếp Cookie & Token đã lưu của từng không gian mà không cần đăng nhập lại.")
        }
    }

    @ViewBuilder
    private var modeSelectionSection: some View {
        Section("2. Chế độ hoạt động") {
            Picker("Thao tác", selection: $mode) {
                ForEach(BatchMode.allCases, id: \.self) { action in
                    Text(action.rawValue).tag(action)
                }
            }
            .pickerStyle(.segmented)
            .disabled(engine.isRunning)

            if mode == .openURL {
                TextField("https://www.facebook.com/", text: $urlText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(engine.isRunning)
                if targetURL == nil {
                    Text("Hãy nhập URL HTTPS hợp lệ.")
                        .font(.caption).foregroundStyle(.red)
                }
            } else if mode == .refresh {
                Text("Nạp lại URL cuối cùng đã mở theo nhóm, hoặc trang chủ của không gian.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var targetInputSection: some View {
        Section {
            Picker("Loại mục tiêu", selection: $targetCategory) {
                ForEach(TargetCategoryHint.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .disabled(engine.isRunning)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Link hoặc ID Bài viết / Reel / Nhóm / Fanpage:")
                        .font(.caption.bold())
                    Spacer()
                    Button("Dán") {
                        if let clip = UIPasteboard.general.string {
                            targetPostInput = clip
                        }
                    }
                    .font(.caption.bold())
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(engine.isRunning)
                }
                TextField("Dán link bài viết, Reel, bài Group, Fanpage hoặc ID...", text: $targetPostInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .disabled(engine.isRunning)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Mô tả / Nội dung bài viết bổ sung (Tùy chọn cho AI):")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Nhập thêm nội dung bài/Reel nếu muốn định hướng sát hơn...", text: $manualContextText, axis: .vertical)
                    .lineLimit(1...3)
                    .font(.caption)
                    .textFieldStyle(.roundedBorder)
                    .disabled(engine.isRunning)
            }

            Button {
                Task { await previewTargetPost() }
            } label: {
                HStack {
                    if engine.isResolvingTarget {
                        ProgressView().controlSize(.small)
                    }
                    Label("Kiểm tra Link & Đọc nội dung mục tiêu", systemImage: "magnifyingglass.circle.fill")
                        .font(.caption.bold())
                }
            }
            .disabled(engine.isRunning || engine.isResolvingTarget || targetPostInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if let resolved = engine.resolvedTargetPreview {
                VStack(alignment: .leading, spacing: 4) {
                    Text("✅ Đã nhận diện: \(resolved.targetKind) • ID: \(resolved.postId)")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                    Text("Đăng bởi: \(resolved.authorName)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
            Text("3. Mục tiêu tương tác (Post / Reel / Group / Page)")
        } footer: {
            Text("Hỗ trợ mọi định dạng: Link bài viết cá nhân, Reel (facebook.com/reel/...), bài trong Nhóm (facebook.com/groups/...), bài Fanpage, link chia sẻ (share/p/..., share/r/...) hoặc ID số.")
        }
    }

    @ViewBuilder
    private var reactionAndCommentSection: some View {
        Section("4. Cảm xúc & Bình luận (Không trùng)") {
            Toggle("Thả cảm xúc (Reaction)", isOn: $useReaction)
                .disabled(engine.isRunning)

            if useReaction {
                Picker("Cảm xúc", selection: $reactionTypeRaw) {
                    ForEach(FacebookReactionType.allCases) { item in
                        Text(item.label).tag(item.rawValue)
                    }
                }
                .disabled(engine.isRunning)
            }

            Toggle("Bình luận (Comment) vào bài chỉ định", isOn: $useComment)
                .disabled(engine.isRunning)

            if useComment {
                Picker("Nguồn Comment", selection: $commentSourceRaw) {
                    ForEach(TargetCommentSource.allCases) { src in
                        Text(src.rawValue).tag(src.rawValue)
                    }
                }
                .disabled(engine.isRunning)

                if commentSource == .manualLines {
                    manualCommentLinesView
                }

                if shouldShowGeminiConfig {
                    geminiConfigurationView
                }
            }
        }
    }

    private var shouldShowGeminiConfig: Bool {
        if commentSource == .geminiAI { return true }
        if commentSource == .manualLines && aiFallbackWhenLinesShort && parsedManualCommentLines.count < selectedSpaces.count {
            return true
        }
        if reactionType == .geminiAuto { return true }
        return false
    }

    @ViewBuilder
    private var manualCommentLinesView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Mỗi hàng = 1 không gian (\(parsedManualCommentLines.count)/\(selectedSpaces.count) hàng):")
                    .font(.caption.bold())
                Spacer()
                Button("Dán") {
                    if let clip = UIPasteboard.general.string {
                        rawManualComments = clip
                    }
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.mini)

                if hasDuplicateManualLines {
                    Button("Lọc trùng") {
                        deduplicateManualLines()
                    }
                    .font(.caption)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                }

                Button("Xóa") {
                    rawManualComments = ""
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            TextEditor(text: $rawManualComments)
                .frame(minHeight: 110)
                .font(.caption)
                .padding(6)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                .disabled(engine.isRunning)

            if hasDuplicateManualLines {
                Text("⚠️ Có dòng bình luận bị trùng nhau. Bấm 'Lọc trùng' để mỗi không gian có nội dung riêng biệt.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            if !selectedSpaces.isEmpty && !parsedManualCommentLines.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Xem trước phân bổ từng hàng cho từng không gian:")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                    ForEach(0..<selectedSpaces.count, id: \.self) { (idx: Int) in
                        let sp = selectedSpaces[idx]
                        let isManual = idx < parsedManualCommentLines.count
                        let lineText = isManual
                            ? parsedManualCommentLines[idx]
                            : (aiFallbackWhenLinesShort ? "[✨ AI tự sinh bù không trùng]" : "[Bỏ qua]")
                        Text("• \(sp.name): \(lineText)")
                            .font(.caption2)
                            .foregroundStyle(isManual ? Color.primary : Color.blue)
                            .lineLimit(1)
                    }
                }
                .padding(.top, 2)
            }

            if parsedManualCommentLines.count < selectedSpaces.count {
                Toggle("Tự dùng AI Gemini sinh bù (không trùng) nếu thiếu dòng", isOn: $aiFallbackWhenLinesShort)
                    .font(.caption)
                    .disabled(engine.isRunning)
            }
        }
    }

    @ViewBuilder
    private var geminiConfigurationView: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField("Gemini API Key (AIza...)", text: $geminiApiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .disabled(engine.isRunning)
                .onChange(of: geminiApiKey) { _, newValue in
                    SecureGeminiStore.saveKey(newValue)
                }

            Text("Phong cách / Yêu cầu cho AI Gemini:")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Phong cách bình luận...", text: $geminiStylePrompt, axis: .vertical)
                .lineLimit(2...3)
                .font(.caption)
                .textFieldStyle(.roundedBorder)
                .disabled(engine.isRunning)
            Text("✨ AI tự động truyền danh sách bình luận đã tạo của các tài khoản trước vào bộ lọc loại trừ để đảm bảo mỗi không gian bình luận một câu hoàn toàn khác nhau.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var safeModeSection: some View {
        Section {
            Toggle(isOn: $safeModeEnabled) {
                Label("SafeMode ngẫu nhiên hóa thời gian chờ", systemImage: "shield.lefthalf.filled.badge.checkmark")
                    .fontWeight(.semibold)
            }
            .disabled(engine.isRunning)

            if useReaction && useComment {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nghỉ ngẫu nhiên giữa React & Comment (giây):")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text("Từ (s):").font(.caption)
                        TextField("Min", text: $minActionGapText)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder)
                            .disabled(engine.isRunning)
                        Text("Đến (s):").font(.caption)
                        TextField("Max", text: $maxActionGapText)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder)
                            .disabled(engine.isRunning)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Nghỉ ngẫu nhiên giữa các không gian (giây):")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Từ (s):").font(.caption)
                    TextField("Min", text: $minSpaceDelayText)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .disabled(engine.isRunning)
                    Text("Đến (s):").font(.caption)
                    TextField("Max", text: $maxSpaceDelayText)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .disabled(engine.isRunning)
                }
            }
        } header: {
            Text("5. SafeMode bảo vệ tài khoản")
        }
    }

    @ViewBuilder
    private var actionButtonSection: some View {
        Section {
            if engine.isRunning {
                Button(role: .destructive) { engine.stop() } label: {
                    Label("Dừng hàng đợi đang chạy", systemImage: "stop.fill")
                        .fontWeight(.bold)
                }
            } else {
                Button {
                    triggerStart()
                } label: {
                    Label("Thực hiện với \(selectedSpaces.count) không gian",
                          systemImage: "play.fill")
                        .fontWeight(.bold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .disabled(!canStart)
            }
        }
    }

    @ViewBuilder
    private var statusRowsSection: some View {
        if !engine.rows.isEmpty {
            Section {
                LabeledContent("Hoàn tất", value: "\(engine.completed)/\(engine.rows.count)")
                LabeledContent("Thành công", value: "\(engine.succeeded)")
                ForEach(engine.rows) { row in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: row.status.symbol)
                            .foregroundStyle(row.status.tint)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.name).fontWeight(.semibold)
                            Text(row.status.title + " · " + row.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !row.assignedComment.isEmpty {
                                Text("💬 Nội dung: \"\(row.assignedComment)\"")
                                    .font(.caption2)
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                    .padding(.vertical, 3)
                }
            } header: {
                Text("Tiến độ từng không gian")
            }
        }
    }

    @ViewBuilder
    private var webPreviewSection: some View {
        if engine.isRunning && engine.activeWebView != nil {
            Section("Xem trước phiên đang tải") {
                BatchWebPreview(webView: engine.activeWebView)
                    .frame(height: 230)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func deduplicateManualLines() {
        var seen = Set<String>()
        var unique: [String] = []
        for line in parsedManualCommentLines {
            if !seen.contains(line) {
                seen.insert(line)
                unique.append(line)
            }
        }
        rawManualComments = unique.joined(separator: "\n")
    }

    @MainActor
    private func previewTargetPost() async {
        do {
            _ = try await engine.resolveTargetInfo(
                targetInput: targetPostInput,
                categoryHint: targetCategory,
                manualContextText: manualContextText,
                spaces: selectedSpaces.isEmpty ? library.spaces : selectedSpaces
            )
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func triggerStart() {
        if mode != .targetInteract {
            engine.start(
                spaces: selectedSpaces,
                mode: mode,
                url: mode == .openURL ? targetURL : nil,
                library: library
            )
            return
        }

        let needsGemini = useComment && (
            commentSource == .geminiAI ||
            (commentSource == .manualLines && aiFallbackWhenLinesShort && parsedManualCommentLines.count < selectedSpaces.count)
        ) || (useReaction && reactionType == .geminiAuto)

        if needsGemini && geminiApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            alertMessage = "Vui lòng nhập Gemini API Key để AI tự động phân tích bài viết và sinh comment."
            return
        }

        if useComment && commentSource == .manualLines && parsedManualCommentLines.isEmpty && !aiFallbackWhenLinesShort {
            alertMessage = "Vui lòng dán danh sách comment (mỗi hàng 1 không gian) hoặc bật AI tự sinh."
            return
        }

        if !geminiApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            SecureGeminiStore.saveKey(geminiApiKey)
        }

        let minGap = Double(minActionGapText.replacingOccurrences(of: ",", with: ".")) ?? 2
        let maxGap = Double(maxActionGapText.replacingOccurrences(of: ",", with: ".")) ?? 5
        let minSpace = Double(minSpaceDelayText.replacingOccurrences(of: ",", with: ".")) ?? 5
        let maxSpace = Double(maxSpaceDelayText.replacingOccurrences(of: ",", with: ".")) ?? 20

        engine.startTargetInteraction(
            spaces: selectedSpaces,
            targetInput: targetPostInput,
            categoryHint: targetCategory,
            manualContextText: manualContextText,
            useReaction: useReaction,
            reactionType: reactionType,
            useComment: useComment,
            commentSource: commentSource,
            manualLines: parsedManualCommentLines,
            aiFallbackWhenLinesShort: aiFallbackWhenLinesShort,
            geminiApiKey: geminiApiKey,
            geminiModel: geminiModel,
            geminiStylePrompt: geminiStylePrompt,
            safeModeEnabled: safeModeEnabled,
            minActionGap: minGap,
            maxActionGap: maxGap,
            minSpaceDelay: minSpace,
            maxSpaceDelay: maxSpace
        )
    }
}
