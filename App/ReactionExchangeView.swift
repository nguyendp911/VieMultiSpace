import SwiftUI

// MARK: - Tiện ích hiển thị

private func exchangeEmoji(_ raw: String?) -> String {
    switch (raw ?? "").uppercased() {
    case "LIKE": return "👍"
    case "LOVE": return "❤️"
    case "CARE": return "🥰"
    case "HAHA": return "😆"
    case "WOW": return "😮"
    case "SAD": return "😢"
    case "ANGER": return "😡"
    default: return "👍"
    }
}

enum ExchangePostKind: String, CaseIterable, Identifiable {
    case post = "Bài viết"
    case reel = "Reel"
    case video = "Video"
    var id: String { rawValue }

    static func kind(of url: String) -> ExchangePostKind {
        let l = url.lowercased()
        if l.contains("/reel") { return .reel }
        if l.contains("/videos/") || l.contains("/watch") || l.contains("fb.watch") { return .video }
        return .post
    }
}

enum ExchangeSort: String, CaseIterable, Identifiable {
    case reputation = "Uy tín cao"
    case newest = "Mới nhất"
    case popular = "Nhiều người nhận"
    var id: String { rawValue }
}

// MARK: - Manager: tải dữ liệu, tự thả reaction, xác minh, thông báo

@MainActor
final class ReactionExchangeManager: ObservableObject {
    static let shared = ReactionExchangeManager()

    @Published var waiting: [WaitingExchange] = []
    @Published var requests: [MyRequest] = []
    @Published var pairs: [MyPair] = []
    @Published var groups: [ExchangeGroup] = []
    @Published var reputation: ExchangeReputation?
    @Published var isLoading = false
    @Published var banner: String?
    @Published var runningTaskIds: Set<UUID> = []
    @Published var selectedGroupId: UUID? {
        didSet { UserDefaults.standard.set(selectedGroupId?.uuidString, forKey: Self.groupKey) }
    }

    private static let groupKey = "vie.exchange.selectedGroup"
    private var isRunningTasks = false
    private var lastPendingCount = 0
    private let attemptsKey = "vie.exchange.attempts.v1"
    private let maxAttempts = 3

    init() {
        selectedGroupId = UserDefaults.standard.string(forKey: Self.groupKey).flatMap(UUID.init(uuidString:))
    }

    var pendingTaskCount: Int {
        pairs.filter { $0.status == "matched" && $0.myTaskStatus == "pending" }.count
    }

    // MARK: Tải dữ liệu

    func refresh(spaces: [Space], runTasks: Bool = true, maxTasks: Int? = nil) async {
        guard ExchangeConfig.isConfigured, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            // Gọi tuần tự để chỉ tạo đúng một phiên ẩn danh ở lần đầu
            let pairList = try await ExchangeBackend.shared.myPairs()
            let requestList = try await ExchangeBackend.shared.myRequests()
            groups = (try? await ExchangeBackend.shared.myGroups()) ?? groups
            if let gid = selectedGroupId, !groups.contains(where: { $0.groupId == gid }) {
                selectedGroupId = nil
            }
            let openList = try await ExchangeBackend.shared.listOpen(group: selectedGroupId)
            reputation = (try? await ExchangeBackend.shared.myReputation()) ?? reputation
            pairs = pairList
            requests = requestList
            waiting = openList
        } catch let error as DecodingError {
            banner = "⚠️ Dữ liệu máy chủ không khớp bản app (\(error.localizedDescription)). Hãy chạy lại file supabase/schema.sql mới nhất."
            return
        } catch {
            banner = "⚠️ \(error.localizedDescription)"
            return
        }

        announcePending()
        if runTasks { await runPendingTasks(spaces: spaces, maxTasks: maxTasks) }
    }

    private func announcePending() {
        let n = pendingTaskCount
        if n > lastPendingCount {
            ExchangeNotifier.notify(
                title: "Trao đổi reaction",
                body: "Bạn có \(n) reaction cần thả cho người khác.",
                id: "vie.exchange.pending.now"
            )
        }
        lastPendingCount = n
        ExchangeNotifier.updatePendingReminder(count: n)
    }

    // MARK: Tạo / nhận / hủy / báo cáo / chặn

    /// Chuẩn hóa link bằng chính tài khoản Facebook đã chọn. Trả về (canonicalURL, postId).
    private func canonicalize(_ input: String, space: Space) async throws -> (url: String, id: String) {
        let creds = await TrackedPostManager.resolveCookieAndToken(for: space)
        guard let resolved = await FacebookTargetPostResolver.resolveShareURLToCanonical(
            input: input,
            cookieString: creds.cookie,
            proxy: space.proxy
        ), !resolved.postId.isEmpty else {
            throw ExchangeError.server("Không đọc được bài viết từ link này. Hãy kiểm tra lại link (bài phải công khai).")
        }
        guard Self.isSafePostId(resolved.postId),
              let host = URL(string: resolved.canonicalURL)?.host?.lowercased(),
              host == "facebook.com" || host.hasSuffix(".facebook.com") else {
            throw ExchangeError.server("Link không phải bài viết Facebook hợp lệ.")
        }
        return (resolved.canonicalURL, resolved.postId)
    }

    func createRequest(link: String, reaction: FacebookReactionType, space: Space, groupId: UUID?) async -> Bool {
        do {
            let c = try await canonicalize(link, space: space)
            try await ExchangeBackend.shared.createRequest(
                postURL: c.url, postId: c.id, reaction: reaction.rawValue,
                displayName: ExchangeConfig.displayName, groupId: groupId
            )
            ExchangeConfig.defaultSpaceId = space.id
            banner = "✅ Đã đăng yêu cầu. Ai nhận yêu cầu, hai bên sẽ thả reaction cho nhau."
            return true
        } catch {
            banner = "❌ \(error.localizedDescription)"
            return false
        }
    }

    func accept(target: WaitingExchange, link: String, reaction: FacebookReactionType, space: Space) async -> Bool {
        do {
            let c = try await canonicalize(link, space: space)
            try await ExchangeBackend.shared.accept(
                targetId: target.id, postURL: c.url, postId: c.id,
                reaction: reaction.rawValue, displayName: ExchangeConfig.displayName
            )
            ExchangeConfig.defaultSpaceId = space.id
            banner = "✅ Đã nhận yêu cầu! Hệ thống sẽ thả reaction cho nhau."
            return true
        } catch {
            banner = "❌ \(error.localizedDescription)"
            return false
        }
    }

    func cancel(_ item: MyRequest) async {
        do {
            try await ExchangeBackend.shared.cancel(requestId: item.id)
            banner = "Đã đóng yêu cầu (các lượt đã nhận vẫn tiếp tục)."
        } catch {
            banner = "❌ \(error.localizedDescription)"
        }
    }

    func report(_ item: WaitingExchange, reason: String) async {
        do {
            try await ExchangeBackend.shared.reportRequest(requestId: item.id, reason: reason)
            waiting.removeAll { $0.id == item.id }
            banner = "Đã gửi báo cáo. Cảm ơn bạn."
        } catch {
            banner = "❌ \(error.localizedDescription)"
        }
    }

    func block(_ item: WaitingExchange) async {
        do {
            try await ExchangeBackend.shared.blockOwner(ofRequest: item.id)
            waiting.removeAll { $0.id == item.id }
            banner = "Đã chặn người này. Bạn sẽ không còn thấy yêu cầu của họ."
        } catch {
            banner = "❌ \(error.localizedDescription)"
        }
    }

    func clearBlocks() async {
        do {
            try await ExchangeBackend.shared.clearBlocks()
            banner = "Đã bỏ chặn tất cả."
        } catch {
            banner = "❌ \(error.localizedDescription)"
        }
    }

    // MARK: Nhóm

    func createGroup(name: String) async -> ExchangeGroup? {
        do {
            let g = try await ExchangeBackend.shared.createGroup(name: name)
            groups.insert(g, at: 0)
            banner = "✅ Đã tạo nhóm. Chia sẻ mã \(g.groupCode) để mời người khác."
            return g
        } catch {
            banner = "❌ \(error.localizedDescription)"
            return nil
        }
    }

    func joinGroup(code: String) async -> ExchangeGroup? {
        do {
            let g = try await ExchangeBackend.shared.joinGroup(code: code)
            if !groups.contains(where: { $0.groupId == g.groupId }) { groups.insert(g, at: 0) }
            banner = "✅ Đã tham gia nhóm \(g.groupName)."
            return g
        } catch {
            banner = "❌ \(error.localizedDescription)"
            return nil
        }
    }

    func leaveGroup(_ g: ExchangeGroup) async {
        do {
            try await ExchangeBackend.shared.leaveGroup(id: g.groupId)
            groups.removeAll { $0.groupId == g.groupId }
            if selectedGroupId == g.groupId { selectedGroupId = nil }
        } catch {
            banner = "❌ \(error.localizedDescription)"
        }
    }

    // MARK: Thực thi lệnh thả reaction (chạy trên máy này, bằng tài khoản của chính người dùng)

    nonisolated static func isSafePostId(_ id: String) -> Bool {
        guard (5...200).contains(id.count) else { return false }
        return id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) }
    }

    private func attempts(for id: UUID) -> Int {
        (UserDefaults.standard.dictionary(forKey: attemptsKey) as? [String: Int])?[id.uuidString] ?? 0
    }

    private func setAttempts(_ n: Int, for id: UUID) {
        var dict = (UserDefaults.standard.dictionary(forKey: attemptsKey) as? [String: Int]) ?? [:]
        dict[id.uuidString] = n
        UserDefaults.standard.set(dict, forKey: attemptsKey)
    }

    private func actingSpace(from spaces: [Space]) -> Space? {
        let fb = spaces.filter { $0.platform == .facebook }
        if let id = ExchangeConfig.defaultSpaceId, let s = fb.first(where: { $0.id == id }) { return s }
        return fb.first
    }

    func runPendingTasks(spaces: [Space], maxTasks: Int? = nil) async {
        guard !isRunningTasks else { return }
        isRunningTasks = true
        defer { isRunningTasks = false }

        guard let space = actingSpace(from: spaces) else {
            if pendingTaskCount > 0 { banner = "⚠️ Cần ít nhất 1 tài khoản Facebook để thả reaction." }
            return
        }

        let pending = pairs.filter { $0.status == "matched" && $0.myTaskStatus == "pending" }
        var ran = 0
        for item in pending {
            if let maxTasks, ran >= maxTasks { break }
            if Task.isCancelled { break }
            let gate = ExchangeSafety.canReact(space: space.id)
            guard gate.ok else {
                banner = "⏸ \(gate.reason ?? "Tạm dừng an toàn")"
                break
            }
            await execute(item, space: space)
            ran += 1
        }

        if let updated = try? await ExchangeBackend.shared.myPairs() { pairs = updated }
        await verifyPartners(space: space)
        announcePending()
    }

    private func execute(_ item: MyPair, space: Space) async {
        let postId = item.partnerPostId
        guard Self.isSafePostId(postId) else {
            try? await ExchangeBackend.shared.reportTask(pairId: item.id, success: false, message: "ID bài viết đối tác không hợp lệ")
            return
        }
        let reaction = FacebookReactionType(rawValue: item.partnerReaction) ?? .like

        runningTaskIds.insert(item.id)
        defer { runningTaskIds.remove(item.id) }

        // Nghỉ ngẫu nhiên (đảm bảo giãn cách giữa các lần thả) để hành vi tự nhiên hơn
        try? await Task.sleep(nanoseconds: UInt64(ExchangeSafety.requiredDelay() * 1_000_000_000))

        let creds = await TrackedPostManager.resolveCookieAndToken(for: space)
        guard !creds.cookie.isEmpty || !creds.token.isEmpty else {
            banner = "⚠️ Tài khoản \(space.name) chưa có Token/Cookie."
            return
        }

        let client = FacebookGraphQLAutoClient(
            spaceId: space.id,
            cookieString: creds.cookie,
            accessToken: creds.token,
            proxy: space.proxy,
            userAgent: space.fingerprint?.userAgent
        )
        let result = await client.reactToPost(postId: postId, reaction: reaction)

        if result.success {
            setAttempts(0, for: item.id)
            ExchangeSafety.recordSuccess(space: space.id)
            do {
                try await ExchangeBackend.shared.reportTask(
                    pairId: item.id, success: true,
                    message: "Đã thả \(reaction.rawValue)", actorUid: creds.uid
                )
                banner = "✅ Đã thả \(exchangeEmoji(reaction.rawValue)) lên bài của \(item.partnerDisplayName)."
            } catch {
                // Reaction trên Facebook là idempotent, lần sau thả lại không gây hại
                banner = "⚠️ Đã thả nhưng chưa báo được về máy chủ: \(error.localizedDescription)"
            }
        } else {
            ExchangeSafety.recordFailure(message: result.message)
            let n = attempts(for: item.id) + 1
            setAttempts(n, for: item.id)
            if n >= maxAttempts {
                try? await ExchangeBackend.shared.reportTask(pairId: item.id, success: false, message: String(result.message.prefix(200)))
                banner = "❌ Thả reaction lỗi \(n) lần, đã báo thất bại: \(result.message)"
            } else {
                banner = "⚠️ Thả reaction lỗi (lần \(n)/\(maxAttempts)), sẽ thử lại: \(result.message)"
            }
        }
    }

    // MARK: Xác minh đối tác có thật sự thả reaction lên bài của tôi không

    private func verifyPartners(space: Space) async {
        let todo = pairs.filter {
            $0.partnerTaskStatus == "done" && $0.partnerVerify == "unknown"
                && !($0.partnerActorUid ?? "").isEmpty && Self.isSafePostId($0.myPostId)
        }.prefix(3)
        guard !todo.isEmpty else { return }

        let creds = await TrackedPostManager.resolveCookieAndToken(for: space)
        guard !creds.cookie.isEmpty else { return }

        var changed = false
        for item in todo {
            guard let res = await PostTrackingAPIClient.fetchExactReactionsViaCometUFI(
                postId: item.myPostId,
                postUrl: item.myPostUrl,
                cookieString: creds.cookie,
                proxy: space.proxy
            ) else { continue }

            let uid = item.partnerActorUid ?? ""
            if res.reactors.contains(where: { $0.id == uid }) {
                try? await ExchangeBackend.shared.reportVerification(pairId: item.id, ok: true)
                changed = true
            } else if res.reactors.count >= res.totalCount {
                // Danh sách đầy đủ mà không có đối tác => đối tác chưa thả thật
                try? await ExchangeBackend.shared.reportVerification(pairId: item.id, ok: false)
                ExchangeNotifier.notify(
                    title: "Không thấy reaction",
                    body: "\(item.partnerDisplayName) báo đã thả nhưng không thấy trên bài của bạn.",
                    id: "vie.exchange.missing.\(item.id.uuidString)"
                )
                changed = true
            }
            // Danh sách chưa đầy đủ (bài nhiều reaction): để "chưa xác định", không kết luận sai
        }
        if changed, let updated = try? await ExchangeBackend.shared.myPairs() { pairs = updated }
    }
}

// MARK: - Màn hình chính

struct ReactionExchangeView: View {
    @EnvironmentObject private var library: SpaceLibrary
    @StateObject private var manager = ReactionExchangeManager.shared
    @StateObject private var health = AccountHealthMonitor.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var tab = 0
    @State private var showSettings = false
    @State private var showGroups = false
    @State private var acceptTarget: WaitingExchange?
    @State private var createLink = ""
    @State private var createReaction: FacebookReactionType = .like
    @State private var createSpaceId: UUID?
    @State private var createGroupId: UUID?
    @State private var isSubmitting = false
    @State private var configured = ExchangeConfig.isConfigured

    @State private var filterReaction: String?
    @State private var filterKind: ExchangePostKind?
    @State private var sort: ExchangeSort = .reputation

    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var facebookSpaces: [Space] { library.spaces.filter { $0.platform == .facebook } }

    private var filteredWaiting: [WaitingExchange] {
        var list = manager.waiting
        if let r = filterReaction { list = list.filter { $0.reaction == r } }
        if let k = filterKind { list = list.filter { ExchangePostKind.kind(of: $0.postUrl) == k } }
        switch sort {
        case .reputation: list.sort { $0.ownerScore != $1.ownerScore ? $0.ownerScore > $1.ownerScore : $0.createdAt > $1.createdAt }
        case .newest: list.sort { $0.createdAt > $1.createdAt }
        case .popular: list.sort { $0.acceptedCount > $1.acceptedCount }
        }
        return list
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let banner = manager.banner {
                    Text(banner)
                        .font(.caption)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.trackerSoft, in: RoundedRectangle(cornerRadius: 10))
                        .onTapGesture { manager.banner = nil }
                }

                if !configured {
                    setupCard
                } else {
                    statusStrip

                    Picker("", selection: $tab) {
                        Text("Yêu cầu (\(manager.waiting.count))").tag(0)
                        Text("Tạo yêu cầu").tag(1)
                        Text("Của tôi (\(manager.requests.count + manager.pairs.count))").tag(2)
                    }
                    .pickerStyle(.segmented)

                    switch tab {
                    case 0: waitingTab
                    case 1: createTab
                    default: mineTab
                    }
                }
            }
            .padding(12)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Trao đổi reaction")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    if manager.isLoading { ProgressView().controlSize(.small) }
                    Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(!configured)
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
        }
        .sheet(isPresented: $showSettings, onDismiss: {
            configured = ExchangeConfig.isConfigured
            Task { await reload() }
        }) {
            ExchangeSettingsSheet(spaces: library.spaces)
        }
        .sheet(isPresented: $showGroups, onDismiss: { Task { await reload() } }) {
            ExchangeGroupsSheet()
        }
        .sheet(item: $acceptTarget) { target in
            AcceptExchangeSheet(target: target, spaces: facebookSpaces) {
                tab = 2
                Task { await reload() }
            }
        }
        .task {
            _ = await ExchangeNotifier.requestAuthorization()
            await reload()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await reload() } }
        }
        .onReceive(timer) { _ in
            if configured { Task { await reload() } }
        }
    }

    private func reload() async {
        configured = ExchangeConfig.isConfigured
        await manager.refresh(spaces: library.spaces)
    }

    // MARK: Thanh trạng thái: uy tín + hạn mức

    private var statusStrip: some View {
        let used = ExchangeSafety.doneToday()
        let cap = ExchangeSafety.dailyCap
        return HStack(spacing: 10) {
            Label("\(manager.reputation?.score ?? 100)", systemImage: "star.fill")
                .font(.caption.bold()).foregroundStyle(.orange)
            Label("Hôm nay \(used)/\(cap)", systemImage: "gauge.with.dots.needle.33percent")
                .font(.caption.bold()).foregroundStyle(used >= cap ? .red : Color.trackerPrimaryDark)
            if let until = ExchangeSafety.pausedUntil {
                Label("Tạm dừng đến \(until.formatted(date: .omitted, time: .shortened))", systemImage: "pause.circle.fill")
                    .font(.caption.bold()).foregroundStyle(.red)
            }
            Spacer()
            if health.badCount > 0 {
                Label("\(health.badCount) TK lỗi", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.bold()).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Chưa cấu hình

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Chưa kết nối máy chủ", systemImage: "icloud.slash")
                .font(.subheadline.bold())
            Text("Tính năng này cần một dự án Supabase để lưu và ghép các yêu cầu. Máy chủ không bao giờ nhận cookie hay token Facebook của bạn.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button { showSettings = true } label: {
                Text("Cấu hình máy chủ").frame(maxWidth: .infinity)
            }
            .buttonStyle(GradientPillButtonStyle(colors: [.trackerPrimary, .trackerPrimaryDark]))
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Tab 1: yêu cầu đang mở

    private var currentGroupName: String {
        manager.groups.first(where: { $0.groupId == manager.selectedGroupId })?.groupName ?? "Công khai"
    }

    private var waitingTab: some View {
        VStack(spacing: 10) {
            filterBar

            if filteredWaiting.isEmpty {
                emptyState(
                    manager.waiting.isEmpty ? "Chưa có yêu cầu nào đang mở" : "Không có yêu cầu khớp bộ lọc",
                    manager.waiting.isEmpty ? "Hãy tạo yêu cầu của bạn ở tab \"Tạo yêu cầu\"." : "Thử bỏ bớt bộ lọc."
                )
            }
            ForEach(filteredWaiting) { item in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(item.displayName, systemImage: "person.crop.circle.fill")
                            .font(.caption.bold())
                        Label("\(item.ownerScore)", systemImage: "star.fill")
                            .font(.caption2.bold()).foregroundStyle(.orange)
                        Spacer()
                        Text("Cần nhận \(exchangeEmoji(item.reaction))")
                            .font(.caption.bold())
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.trackerSoft, in: Capsule())
                        Menu {
                            Button("Báo cáo yêu cầu", systemImage: "flag", role: .destructive) {
                                Task { await manager.report(item, reason: "Link rác / không hợp lệ") }
                            }
                            Button("Chặn người này", systemImage: "nosign", role: .destructive) {
                                Task { await manager.block(item) }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 6) {
                        Text(ExchangePostKind.kind(of: item.postUrl).rawValue)
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.blue.opacity(0.15), in: Capsule())
                            .foregroundStyle(.blue)
                        Text(item.postUrl)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    HStack {
                        Text("\(item.acceptedCount) người đã nhận · \(item.createdAt, style: .relative)")
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button { acceptTarget = item } label: {
                            Label("Nhận yêu cầu", systemImage: "arrow.left.arrow.right")
                        }
                        .buttonStyle(GradientPillButtonStyle(colors: [.trackerPrimary, .trackerPrimaryDark], isCompact: true))
                    }
                }
                .padding(12)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    Button("Công khai") { manager.selectedGroupId = nil; Task { await reload() } }
                    ForEach(manager.groups) { g in
                        Button(g.groupName) { manager.selectedGroupId = g.groupId; Task { await reload() } }
                    }
                    Divider()
                    Button("Quản lý nhóm…", systemImage: "person.3") { showGroups = true }
                } label: { filterChip("person.3.fill", currentGroupName, active: manager.selectedGroupId != nil) }

                Menu {
                    Button("Tất cả reaction") { filterReaction = nil }
                    ForEach(FacebookReactionType.concreteReactions) { r in
                        Button("\(exchangeEmoji(r.rawValue)) \(r.rawValue)") { filterReaction = r.rawValue }
                    }
                } label: { filterChip("face.smiling", filterReaction.map { exchangeEmoji($0) } ?? "Reaction", active: filterReaction != nil) }

                Menu {
                    Button("Tất cả loại bài") { filterKind = nil }
                    ForEach(ExchangePostKind.allCases) { k in Button(k.rawValue) { filterKind = k } }
                } label: { filterChip("rectangle.stack", filterKind?.rawValue ?? "Loại bài", active: filterKind != nil) }

                Menu {
                    ForEach(ExchangeSort.allCases) { s in Button(s.rawValue) { sort = s } }
                } label: { filterChip("arrow.up.arrow.down", sort.rawValue, active: false) }
            }
        }
    }

    private func filterChip(_ icon: String, _ text: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold))
            Text(text).font(.caption.bold()).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .foregroundStyle(active ? .white : Color.trackerPrimaryDark)
        .background(active ? AnyShapeStyle(Color.trackerPrimaryDark) : AnyShapeStyle(Color.trackerSoft), in: Capsule())
    }

    // MARK: Tab 2: tạo yêu cầu

    private var createTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Dán link bài viết của bạn và chọn reaction bạn muốn nhận. Ai nhận yêu cầu thì hai bên thả reaction cho nhau. Một yêu cầu có thể được nhiều người nhận.")
                .font(.caption).foregroundStyle(.secondary)

            TextField("Link bài viết Facebook của bạn", text: $createLink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .padding(10)
                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))

            ExchangeReactionPicker(selection: $createReaction, title: "Reaction muốn nhận")
            ExchangeSpacePicker(spaces: facebookSpaces, selection: $createSpaceId)

            HStack {
                Text("Đăng vào").font(.caption.bold())
                Spacer()
                Picker("", selection: $createGroupId) {
                    Text("Công khai").tag(UUID?.none)
                    ForEach(manager.groups) { g in Text(g.groupName).tag(Optional(g.groupId)) }
                }
                .pickerStyle(.menu)
            }

            Button {
                guard let space = facebookSpaces.first(where: { $0.id == createSpaceId }) ?? facebookSpaces.first else { return }
                isSubmitting = true
                Task {
                    let ok = await manager.createRequest(link: createLink, reaction: createReaction, space: space, groupId: createGroupId)
                    isSubmitting = false
                    if ok { createLink = ""; tab = 2; await reload() }
                }
            } label: {
                HStack {
                    if isSubmitting { ProgressView().tint(.white).controlSize(.mini) }
                    Text("Gửi yêu cầu").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(GradientPillButtonStyle(colors: [.trackerPrimary, .trackerPrimaryDark]))
            .disabled(isSubmitting || createLink.trimmingCharacters(in: .whitespaces).isEmpty || facebookSpaces.isEmpty)

            if facebookSpaces.isEmpty {
                Text("⚠️ Cần có ít nhất 1 không gian Facebook đã đăng nhập.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .onAppear {
            createSpaceId = createSpaceId ?? ExchangeConfig.defaultSpaceId ?? facebookSpaces.first?.id
            createGroupId = manager.selectedGroupId
        }
    }

    // MARK: Tab 3: của tôi

    private var mineTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            if manager.requests.isEmpty && manager.pairs.isEmpty {
                emptyState("Bạn chưa có hoạt động nào", "Tạo yêu cầu hoặc nhận một yêu cầu ở tab đầu tiên.")
            }
            if !manager.requests.isEmpty {
                Text("Yêu cầu của tôi").font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(manager.requests) { requestCard($0) }
            }
            if !manager.pairs.isEmpty {
                Text("Các lượt trao đổi").font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 4)
                ForEach(manager.pairs) { pairCard($0) }
            }
        }
    }

    private func requestCard(_ item: MyRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                chip(requestStatusTitle(item.status), color: item.status == "open" ? .orange : .gray)
                if let g = item.groupName {
                    chip(g, color: .purple)
                }
                Spacer()
                Text(item.createdAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
            }
            Text("Bài của bạn · muốn nhận \(exchangeEmoji(item.reaction))").font(.caption.bold())
            Text(item.postUrl).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            HStack {
                Label("\(item.acceptedCount) người đã nhận", systemImage: "person.2.fill")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if item.status == "open" {
                    Button(role: .destructive) {
                        Task { await manager.cancel(item); await reload() }
                    } label: { Text("Đóng yêu cầu") }
                    .buttonStyle(SoftTintedButtonStyle(tint: .red, isCompact: true))
                }
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func pairCard(_ item: MyPair) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                chip(item.status == "done" ? "Hoàn tất" : "Đang thực hiện",
                     color: item.status == "done" ? .trackerPrimaryDark : .blue)
                Spacer()
                Text(item.createdAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
            }
            Text("Trao đổi với \(item.partnerDisplayName)").font(.caption.bold())
            Text(item.role == "requester"
                 ? "\(item.partnerDisplayName) đã nhận yêu cầu của bạn"
                 : "Bạn đã nhận yêu cầu của \(item.partnerDisplayName)")
                .font(.caption2).foregroundStyle(.secondary)
            Divider()
            taskLine(
                "Bạn thả \(exchangeEmoji(item.partnerReaction)) lên bài của \(item.partnerDisplayName)",
                status: item.myTaskStatus,
                message: item.myTaskMessage,
                running: manager.runningTaskIds.contains(item.id),
                verify: item.myVerify
            )
            taskLine(
                "\(item.partnerDisplayName) thả \(exchangeEmoji(item.myReaction)) lên bài của bạn",
                status: item.partnerTaskStatus,
                message: nil,
                running: false,
                verify: item.partnerVerify
            )
            if item.status == "matched" && item.myTaskStatus == "pending" {
                Button {
                    Task { await manager.runPendingTasks(spaces: library.spaces) }
                } label: { Label("Thả ngay", systemImage: "bolt.fill") }
                .buttonStyle(SoftTintedButtonStyle(tint: .trackerPrimaryDark, isCompact: true))
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text).font(.caption.bold())
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private func taskLine(_ text: String, status: String, message: String?, running: Bool, verify: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            if running {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: status == "done" ? "checkmark.circle.fill"
                      : status == "failed" ? "xmark.circle.fill" : "clock")
                    .foregroundStyle(status == "done" ? Color.trackerPrimaryDark
                                     : status == "failed" ? .red : .orange)
                    .font(.caption)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(.caption)
                if status == "done" && verify == "ok" {
                    Text("✔ Đã xác minh reaction thật").font(.caption2).foregroundStyle(Color.trackerPrimaryDark)
                } else if status == "done" && verify == "missing" {
                    Text("⚠️ Không thấy reaction trên bài").font(.caption2).foregroundStyle(.red)
                }
                if status == "failed", let message, !message.isEmpty {
                    Text(message).font(.caption2).foregroundStyle(.red).lineLimit(2)
                }
            }
        }
    }

    private func requestStatusTitle(_ status: String) -> String {
        switch status {
        case "open": return "Đang mở"
        case "cancelled": return "Đã đóng"
        case "expired": return "Hết hạn"
        default: return status
        }
    }

    private func emptyState(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.subheadline.bold())
            Text(subtitle).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Bộ chọn dùng chung

private struct ExchangeReactionPicker: View {
    @Binding var selection: FacebookReactionType
    let title: String

    var body: some View {
        HStack {
            Text(title).font(.caption.bold())
            Spacer()
            Picker("", selection: $selection) {
                ForEach(FacebookReactionType.concreteReactions) { r in
                    Text("\(exchangeEmoji(r.rawValue)) \(r.rawValue)").tag(r)
                }
            }
            .pickerStyle(.menu)
        }
    }
}

private struct ExchangeSpacePicker: View {
    let spaces: [Space]
    @Binding var selection: UUID?

    var body: some View {
        HStack {
            Text("Tài khoản dùng để thả reaction").font(.caption.bold())
            Spacer()
            Picker("", selection: $selection) {
                ForEach(spaces) { sp in Text(sp.name).tag(Optional(sp.id)) }
            }
            .pickerStyle(.menu)
        }
    }
}

// MARK: - Sheet nhận yêu cầu

struct AcceptExchangeSheet: View {
    let target: WaitingExchange
    let spaces: [Space]
    var onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var manager = ReactionExchangeManager.shared
    @State private var link = ""
    @State private var reaction: FacebookReactionType = .like
    @State private var spaceId: UUID?
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Bạn sẽ thả cho \(target.displayName)") {
                    Text("\(exchangeEmoji(target.reaction)) \(target.reaction) lên bài:")
                    Text(target.postUrl).font(.caption).foregroundStyle(.secondary)
                }
                Section("Bài viết và reaction của bạn") {
                    TextField("Link bài viết Facebook của bạn", text: $link)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    ExchangeReactionPicker(selection: $reaction, title: "Reaction muốn nhận")
                    ExchangeSpacePicker(spaces: spaces, selection: $spaceId)
                }
                Section {
                    Button {
                        guard let space = spaces.first(where: { $0.id == spaceId }) ?? spaces.first else { return }
                        isSubmitting = true
                        Task {
                            let ok = await manager.accept(target: target, link: link, reaction: reaction, space: space)
                            isSubmitting = false
                            if ok { dismiss(); onDone() }
                        }
                    } label: {
                        HStack {
                            if isSubmitting { ProgressView() }
                            Text("Gửi yêu cầu & ghép cặp")
                        }
                    }
                    .disabled(isSubmitting || link.trimmingCharacters(in: .whitespaces).isEmpty || spaces.isEmpty)
                }
                if let banner = manager.banner {
                    Section { Text(banner).font(.caption) }
                }
            }
            .navigationTitle("Nhận yêu cầu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Đóng") { dismiss() } }
            }
            .onAppear { spaceId = ExchangeConfig.defaultSpaceId ?? spaces.first?.id }
        }
    }
}

// MARK: - Sheet quản lý nhóm riêng (mã mời)

struct ExchangeGroupsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var manager = ReactionExchangeManager.shared
    @State private var newName = ""
    @State private var joinCode = ""
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Nhóm của tôi") {
                    if manager.groups.isEmpty {
                        Text("Bạn chưa tham gia nhóm nào.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(manager.groups) { g in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(g.groupName).font(.subheadline.bold())
                                if g.isOwner { Text("Chủ nhóm").font(.caption2).foregroundStyle(.orange) }
                                Spacer()
                                Text("\(g.memberCount) thành viên").font(.caption2).foregroundStyle(.secondary)
                            }
                            HStack {
                                Text("Mã mời: \(g.groupCode)").font(.caption.monospaced())
                                Spacer()
                                Button("Sao chép") { UIPasteboard.general.string = g.groupCode }
                                    .font(.caption)
                                Button("Rời nhóm", role: .destructive) {
                                    Task { await manager.leaveGroup(g) }
                                }
                                .font(.caption)
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Section("Tạo nhóm mới") {
                    TextField("Tên nhóm", text: $newName)
                    Button("Tạo nhóm") {
                        isWorking = true
                        Task {
                            if await manager.createGroup(name: newName) != nil { newName = "" }
                            isWorking = false
                        }
                    }
                    .disabled(isWorking || newName.trimmingCharacters(in: .whitespaces).count < 2)
                }
                Section("Tham gia bằng mã mời") {
                    TextField("Mã 6 ký tự", text: $joinCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Button("Tham gia") {
                        isWorking = true
                        Task {
                            if await manager.joinGroup(code: joinCode) != nil { joinCode = "" }
                            isWorking = false
                        }
                    }
                    .disabled(isWorking || joinCode.trimmingCharacters(in: .whitespaces).count < 4)
                }
                if let banner = manager.banner {
                    Section { Text(banner).font(.caption) }
                }
            }
            .navigationTitle("Nhóm riêng")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Xong") { dismiss() } } }
        }
    }
}

// MARK: - Sheet cài đặt

struct ExchangeSettingsSheet: View {
    let spaces: [Space]
    @Environment(\.dismiss) private var dismiss
    @StateObject private var manager = ReactionExchangeManager.shared
    @StateObject private var health = AccountHealthMonitor.shared

    @State private var url = ExchangeConfig.supabaseURL
    @State private var anonKey = ExchangeConfig.anonKey
    @State private var name = ExchangeConfig.displayName
    @State private var spaceId: UUID? = ExchangeConfig.defaultSpaceId
    @State private var cap = ExchangeSafety.dailyCap
    @State private var pausedUntil = ExchangeSafety.pausedUntil
    @State private var notificationsOK: Bool?

    private var facebookSpaces: [Space] { spaces.filter { $0.platform == .facebook } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://xxxx.supabase.co", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("anon public key", text: $anonKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Máy chủ Supabase")
                } footer: {
                    Text("Lấy ở Supabase > Project Settings > API (Project URL và anon public key). Chạy file supabase/schema.sql trong SQL Editor và bật \"Allow anonymous sign-ins\" ở Authentication > Sign In / Providers.")
                }

                Section("Hiển thị") {
                    TextField("Tên hiển thị (để trống = Ẩn danh)", text: $name)
                }

                Section("Tài khoản thả reaction mặc định") {
                    ExchangeSpacePicker(spaces: facebookSpaces, selection: $spaceId)
                }

                Section {
                    Stepper("Tối đa \(cap) reaction/ngày/tài khoản", value: $cap, in: 5...200, step: 5)
                    LabeledContent("Đã thả hôm nay", value: "\(ExchangeSafety.doneToday())")
                    if let until = pausedUntil {
                        LabeledContent("Tạm dừng đến", value: until.formatted(date: .omitted, time: .shortened))
                        Button("Bỏ tạm dừng") {
                            ExchangeSafety.clearPause()
                            pausedUntil = nil
                        }
                    }
                } header: {
                    Text("Hạn mức an toàn")
                } footer: {
                    Text("Thả quá nhiều reaction trong ngày dễ khiến Facebook khóa tài khoản. App tự tạm dừng khi gặp lỗi giống bị chặn.")
                }

                Section("Uy tín của bạn") {
                    if let r = manager.reputation {
                        LabeledContent("Điểm", value: "\(r.score)")
                        LabeledContent("Đã thả thành công", value: "\(r.doneCount)")
                        LabeledContent("Thất bại", value: "\(r.failedCount)")
                        LabeledContent("Bị báo không thấy reaction", value: "\(r.missingCount)")
                    } else {
                        Text("Chưa có dữ liệu.").foregroundStyle(.secondary)
                    }
                }

                Section("Sức khỏe tài khoản") {
                    ForEach(facebookSpaces) { sp in
                        HStack {
                            Text(sp.name)
                            Spacer()
                            let st = health.results[sp.id]?.status ?? .unknown
                            Text(st.title)
                                .font(.caption.bold())
                                .foregroundStyle(st == .ok ? Color.trackerPrimaryDark : (st.isBad ? Color.red : Color.secondary))
                        }
                    }
                    Button {
                        Task { await health.checkAll(spaces: spaces) }
                    } label: {
                        HStack {
                            if health.isChecking { ProgressView() }
                            Text("Kiểm tra token / cookie ngay")
                        }
                    }
                    .disabled(health.isChecking)
                }

                Section("Thông báo") {
                    Button("Bật thông báo nhắc việc") {
                        Task { notificationsOK = await ExchangeNotifier.requestAuthorization() }
                    }
                    if let ok = notificationsOK {
                        Text(ok ? "Đã bật thông báo." : "Thông báo đang bị tắt. Hãy bật trong Cài đặt iOS.")
                            .font(.caption).foregroundStyle(ok ? Color.trackerPrimaryDark : .orange)
                    }
                }

                Section {
                    Button("Bỏ chặn tất cả người dùng") {
                        Task { await manager.clearBlocks() }
                    }
                    Button("Đặt lại phiên đăng nhập máy chủ", role: .destructive) {
                        Task { await ExchangeBackend.shared.resetSession() }
                    }
                }
            }
            .navigationTitle("Cài đặt trao đổi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Lưu") {
                        var trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
                        while trimmed.hasSuffix("/") { trimmed.removeLast() }
                        ExchangeConfig.supabaseURL = trimmed
                        ExchangeConfig.anonKey = anonKey
                        ExchangeConfig.displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        ExchangeConfig.defaultSpaceId = spaceId
                        ExchangeSafety.dailyCap = cap
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) { Button("Đóng") { dismiss() } }
            }
        }
    }
}
