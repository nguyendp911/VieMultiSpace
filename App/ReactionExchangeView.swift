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

// MARK: - Manager: tải dữ liệu + tự thả reaction khi đã ghép cặp

@MainActor
final class ReactionExchangeManager: ObservableObject {
    static let shared = ReactionExchangeManager()

    @Published var waiting: [WaitingExchange] = []
    @Published var requests: [MyRequest] = []
    @Published var pairs: [MyPair] = []
    @Published var isLoading = false
    @Published var banner: String?
    @Published var runningTaskIds: Set<UUID> = []

    private var isRunningTasks = false
    private let attemptsKey = "vie.exchange.attempts.v1"
    private let maxAttempts = 3

    // MARK: Tải dữ liệu

    func refresh(spaces: [Space], runTasks: Bool = true) async {
        guard ExchangeConfig.isConfigured, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            // Gọi tuần tự để chỉ tạo đúng một phiên ẩn danh ở lần đầu
            let pairList = try await ExchangeBackend.shared.myPairs()
            let requestList = try await ExchangeBackend.shared.myRequests()
            let openList = try await ExchangeBackend.shared.listOpen()
            pairs = pairList
            requests = requestList
            waiting = openList
        } catch {
            banner = "⚠️ \(error.localizedDescription)"
            return
        }
        if runTasks { await runPendingTasks(spaces: spaces) }
    }

    // MARK: Tạo / nhận / hủy

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

    func createRequest(link: String, reaction: FacebookReactionType, space: Space) async -> Bool {
        do {
            let c = try await canonicalize(link, space: space)
            try await ExchangeBackend.shared.createRequest(
                postURL: c.url, postId: c.id, reaction: reaction.rawValue, displayName: ExchangeConfig.displayName
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

    func runPendingTasks(spaces: [Space]) async {
        guard !isRunningTasks else { return }
        isRunningTasks = true
        defer { isRunningTasks = false }

        let pending = pairs.filter { $0.status == "matched" && $0.myTaskStatus == "pending" }
        guard !pending.isEmpty else { return }

        guard let space = actingSpace(from: spaces) else {
            banner = "⚠️ Cần ít nhất 1 tài khoản Facebook để thả reaction."
            return
        }

        for item in pending {
            await execute(item, space: space)
        }
        if let updated = try? await ExchangeBackend.shared.myPairs() { pairs = updated }
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

        // Nghỉ ngẫu nhiên trước khi thả để hành vi tự nhiên hơn
        try? await Task.sleep(nanoseconds: UInt64(Double.random(in: 3...9) * 1_000_000_000))

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
            do {
                try await ExchangeBackend.shared.reportTask(pairId: item.id, success: true, message: "Đã thả \(reaction.rawValue)")
                banner = "✅ Đã thả \(exchangeEmoji(reaction.rawValue)) lên bài của \(item.partnerDisplayName)."
            } catch {
                // Reaction trên Facebook là idempotent, lần sau thả lại không gây hại
                banner = "⚠️ Đã thả nhưng chưa báo được về máy chủ: \(error.localizedDescription)"
            }
        } else {
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
}

// MARK: - Màn hình chính

struct ReactionExchangeView: View {
    @EnvironmentObject private var library: SpaceLibrary
    @StateObject private var manager = ReactionExchangeManager.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var tab = 0
    @State private var showSettings = false
    @State private var acceptTarget: WaitingExchange?
    @State private var createLink = ""
    @State private var createReaction: FacebookReactionType = .like
    @State private var createSpaceId: UUID?
    @State private var isSubmitting = false
    @State private var configured = ExchangeConfig.isConfigured

    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var facebookSpaces: [Space] { library.spaces.filter { $0.platform == .facebook } }

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
            ExchangeSettingsSheet(spaces: facebookSpaces)
        }
        .sheet(item: $acceptTarget) { target in
            AcceptExchangeSheet(target: target, spaces: facebookSpaces) {
                tab = 2
                Task { await reload() }
            }
        }
        .task { await reload() }
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

    // MARK: Tab 1: danh sách chờ

    private var waitingTab: some View {
        VStack(spacing: 10) {
            if manager.waiting.isEmpty {
                emptyState("Chưa có yêu cầu nào đang mở", "Hãy tạo yêu cầu của bạn ở tab \"Tạo yêu cầu\".")
            }
            ForEach(manager.waiting) { item in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(item.displayName, systemImage: "person.crop.circle.fill")
                            .font(.caption.bold())
                        Spacer()
                        Text("Cần nhận \(exchangeEmoji(item.reaction))")
                            .font(.caption.bold())
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.trackerSoft, in: Capsule())
                    }
                    Text(item.postUrl)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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

            Button {
                guard let space = facebookSpaces.first(where: { $0.id == createSpaceId }) ?? facebookSpaces.first else { return }
                isSubmitting = true
                Task {
                    let ok = await manager.createRequest(link: createLink, reaction: createReaction, space: space)
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
        .onAppear { createSpaceId = createSpaceId ?? ExchangeConfig.defaultSpaceId ?? facebookSpaces.first?.id }
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
                running: manager.runningTaskIds.contains(item.id)
            )
            taskLine(
                "\(item.partnerDisplayName) thả \(exchangeEmoji(item.myReaction)) lên bài của bạn",
                status: item.partnerTaskStatus,
                message: nil,
                running: false
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

    private func taskLine(_ text: String, status: String, message: String?, running: Bool) -> some View {
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

// MARK: - Sheet cài đặt

struct ExchangeSettingsSheet: View {
    let spaces: [Space]
    @Environment(\.dismiss) private var dismiss

    @State private var url = ExchangeConfig.supabaseURL
    @State private var anonKey = ExchangeConfig.anonKey
    @State private var name = ExchangeConfig.displayName
    @State private var spaceId: UUID? = ExchangeConfig.defaultSpaceId

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
                    ExchangeSpacePicker(spaces: spaces, selection: $spaceId)
                }
                Section {
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
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) { Button("Đóng") { dismiss() } }
            }
        }
    }
}
