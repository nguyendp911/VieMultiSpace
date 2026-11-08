import SwiftUI
import WebKit
import LocalAuthentication

struct SpaceDashboard: View {
    @EnvironmentObject private var library: SpaceLibrary
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("vie.multispace.requireUnlock") private var requireUnlock = false
    @State private var showAdd = false
    @State private var openSpace: Space?
    @State private var tokenSpace: Space?
    @State private var autoSpace: Space?
    @State private var proxySpace: Space?
    @State private var renameSpace: Space?
    @State private var renameValue = ""
    @State private var deleteSpace: Space?
    @State private var clearSpace: Space?
    @State private var errorMessage: String?
    @State private var busy = false
    @State private var isLocked = false
    @State private var showLog = false
    @State private var editMode: EditMode = .inactive
    @State private var navigateToAutoInteract = false
    @State private var navigateToSync = false
    @State private var navigateToSmartPost = false
    @State private var navigateToPostTracker = false
    @State private var inlineRenameId: UUID? = nil
    @State private var inlineRenameText = ""
    @ObservedObject private var logger = AppLogger.shared
    @ObservedObject private var postTracker = TrackedPostManager.shared

    var body: some View {
        NavigationStack {
            ZStack {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("ViePN Smart+", systemImage: "square.stack.3d.up.fill")
                                .font(.title2.bold())
                            Text("Quản lý nhiều phiên đăng nhập web độc lập, Proxy & Vân tay Anti-Detect, Kho Token và Auto AI.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("\(library.spaces.count) không gian")
                                .font(.caption.monospacedDigit())
                        }
                        .padding(.vertical, 10)
                    }
                    Section("Mạng & Bảo mật phiên") {
                        NavigationLink {
                            BatchProxyManagerView()
                        } label: {
                            Label("Proxy & Vân tay Anti-Detect", systemImage: "network.badge.shield.half.filled")
                                .fontWeight(.semibold)
                        }
                        Button {
                            logger.clearErrorBadge()
                            showLog = true
                        } label: {
                            HStack {
                                Label("Nhật ký hoạt động & Lỗi", systemImage: "list.bullet.rectangle")
                                Spacer()
                                if logger.errorCount > 0 {
                                    Text("\(logger.errorCount) lỗi")
                                        .font(.caption.bold())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(.red, in: Capsule())
                                }
                            }
                        }
                    }
                    Section("Quản lý tài khoản & Token") {
                        NavigationLink {
                            AccountCenterView()
                        } label: {
                            Label("Trung tâm tài khoản & Kho Token", systemImage: "person.2.crop.square.stack")
                        }
                    }
                    Section("Tự động hóa & Quản lý bài viết") {
                        VStack(spacing: 8) {
                            HStack(spacing: 8) {
                                compactFeatureButton(
                                    title: "Smart Post",
                                    subtitle: "Đăng & Lên lịch",
                                    icon: "paperplane.fill",
                                    colors: [Color.orange, Color.red],
                                    badge: nil
                                ) {
                                    navigateToSmartPost = true
                                }

                                compactFeatureButton(
                                    title: "Theo dõi bài",
                                    subtitle: "Thống kê & AI Reply",
                                    icon: "chart.bar.doc.horizontal.fill",
                                    colors: [Color.teal, Color.blue],
                                    badge: postTracker.posts.isEmpty ? nil : "\(postTracker.posts.count)"
                                ) {
                                    navigateToPostTracker = true
                                }
                            }

                            HStack(spacing: 8) {
                                compactFeatureButton(
                                    title: "Auto Feeds",
                                    subtitle: "Reaction & Cmt AI",
                                    icon: "sparkles",
                                    colors: [Color.purple, Color.pink],
                                    badge: nil
                                ) {
                                    navigateToAutoInteract = true
                                }

                                compactFeatureButton(
                                    title: "MultiSpace",
                                    subtitle: "Sync Tương tác",
                                    icon: "square.stack.3d.up.fill",
                                    colors: [Color.indigo, Color.cyan],
                                    badge: nil
                                ) {
                                    navigateToSync = true
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    Section("Không gian của tôi") {
                        ForEach(library.spaces) { space in
                            let summary = VaultMetadataIndex.get(space.id)
                            HStack(spacing: 8) {
                                Button { openSpace = space } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: space.platform.icon)
                                            .font(.title3)
                                            .foregroundStyle(.white)
                                            .frame(width: 40, height: 40)
                                            .background(space.platform.color, in: RoundedRectangle(cornerRadius: 10))
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(space.name)
                                                .font(.headline)
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            HStack(spacing: 4) {
                                                Text(space.platform.rawValue)
                                                if summary.hasToken {
                                                    Text("· \(summary.tokenPrefix.isEmpty ? "Token" : summary.tokenPrefix) (\(summary.convertedCount) App)")
                                                        .foregroundStyle(.green)
                                                        .fontWeight(.semibold)
                                                } else if summary.hasCookies {
                                                    Text("· Đã lưu Cookie")
                                                        .foregroundStyle(.orange)
                                                } else {
                                                    Text("· Phiên riêng")
                                                }
                                            }
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)

                                            if let pxy = space.proxy, pxy.isEnabled {
                                                Text(pxy.displaySummary)
                                                    .font(.caption2.monospaced())
                                                    .foregroundStyle(.blue)
                                                    .lineLimit(1)
                                            }
                                        }
                                        Spacer(minLength: 4)
                                    }
                                }
                                .buttonStyle(.plain)

                                Button {
                                    proxySpace = space
                                } label: {
                                    Image(systemName: space.proxy?.isEnabled == true ? "network" : "slider.horizontal.3")
                                        .foregroundStyle(space.proxy?.isEnabled == true ? Color.blue : Color.secondary)
                                        .frame(width: 28, height: 28)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)

                                if space.platform == .facebook {
                                    Button {
                                        autoSpace = space
                                    } label: {
                                        Image(systemName: "sparkles")
                                            .foregroundStyle(.purple)
                                            .frame(width: 28, height: 28)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)

                                    Button {
                                        tokenSpace = space
                                    } label: {
                                        Image(systemName: summary.hasToken ? "key.radiowaves.forward.fill" : "key.fill")
                                            .foregroundStyle(summary.hasToken ? Color.green : Color.blue)
                                            .frame(width: 28, height: 28)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                }


                            }
                            .padding(.vertical, 3)
                            .contextMenu {
                                Button("Cấu hình Proxy & Dấu vân tay", systemImage: "slider.horizontal.3") {
                                    proxySpace = space
                                }
                                if space.platform == .facebook {
                                    Button("Auto Thả cảm xúc & Comment AI", systemImage: "sparkles") {
                                        autoSpace = space
                                    }
                                }
                                Button("Đăng nhập & Kho Token", systemImage: "person.badge.key.fill") {
                                    tokenSpace = space
                                }
                                Button("Đổi tên", systemImage: "pencil") {
                                    renameSpace = space
                                    renameValue = space.name
                                }
                                Button("Xóa phiên đăng nhập", systemImage: "rectangle.portrait.and.arrow.right") {
                                    clearSpace = space
                                }
                                Button("Xóa không gian", systemImage: "trash", role: .destructive) {
                                    deleteSpace = space
                                }
                            }
                        }
                        .onMove { from, to in
                            library.move(from: from, to: to)
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                if index < library.spaces.count {
                                    deleteSpace = library.spaces[index]
                                }
                            }
                        }
                        Button { showAdd = true } label: {
                            Label("Tạo không gian mới", systemImage: "plus.circle.fill")
                                .fontWeight(.semibold)
                        }
                        .disabled(busy)
                    }
                    Section {
                        Text("Cookie, Access Token, Proxy và dữ liệu web của mỗi không gian chỉ được lưu trong Keychain & WebKit trên iPhone.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .environment(\.editMode, $editMode)
                .scrollContentBackground(.hidden)
                .background(Color(uiColor: .systemGroupedBackground))

                if isLocked {
                    VStack(spacing: 20) {
                        Image(systemName: "lock.shield.fill").font(.system(size: 55))
                        Text("ViePN Smart+ đã khóa").font(.title2.bold())
                        Button("Mở khóa bằng Face ID / mã máy") { authenticate() }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .systemBackground).ignoresSafeArea())
                }
            }
            .navigationTitle("MultiSpace")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Khóa bằng Face ID / mã máy", isOn: $requireUnlock)
                        Button("Khóa ngay", systemImage: "lock") { isLocked = true }
                            .disabled(!requireUnlock)
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .navigationDestination(isPresented: $navigateToAutoInteract) {
                AutoInteractView()
            }
            .navigationDestination(isPresented: $navigateToSync) {
                MultiSpaceSyncView()
            }
            .navigationDestination(isPresented: $navigateToSmartPost) {
                SmartPostView(initialTab: 0)
            }
            .navigationDestination(isPresented: $navigateToPostTracker) {
                SmartPostView(initialTab: 2)
            }
            .sheet(isPresented: $showLog) {
                LogConsoleView()
            }
            .sheet(isPresented: $showAdd) { AddSpaceSheet() }
            .sheet(item: $openSpace) { space in
                NavigationStack { SpaceBrowser(space: space) }
            }
            .sheet(item: $tokenSpace) { space in
                LoginEditorSheet(space: space)
            }
            .sheet(item: $autoSpace) { space in
                NavigationStack {
                    AutoInteractView(preselectedSpace: space)
                }
            }
            .sheet(item: $proxySpace) { space in
                NavigationStack {
                    SpaceProxyFingerprintSheet(space: space)
                }
            }
            .sheet(item: $renameSpace) { space in
                NavigationStack {
                    Form { TextField("Tên mới", text: $renameValue) }
                        .navigationTitle("Đổi tên")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Hủy") { renameSpace = nil }
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Lưu") {
                                    library.rename(space, to: renameValue)
                                    renameSpace = nil
                                }
                            }
                        }
                }
                .presentationDetents([.medium])
            }
            .confirmationDialog("Xóa không gian này?", isPresented: Binding(
                get: { deleteSpace != nil },
                set: { if !$0 { deleteSpace = nil } }
            )) {
                Button("Xóa không gian và dữ liệu", role: .destructive) {
                    guard let space = deleteSpace else { return }
                    deleteSpace = nil
                    if openSpace?.id == space.id { openSpace = nil }
                    if tokenSpace?.id == space.id { tokenSpace = nil }
                    if autoSpace?.id == space.id { autoSpace = nil }
                    if proxySpace?.id == space.id { proxySpace = nil }
                    if renameSpace?.id == space.id { renameSpace = nil }
                    if clearSpace?.id == space.id { clearSpace = nil }
                    busy = true
                    Task {
                        await library.delete(space)
                        busy = false
                    }
                }
            } message: {
                Text("Cookie, Token, phiên đăng nhập và dữ liệu web của không gian này sẽ bị xóa.")
            }
            .confirmationDialog("Đăng xuất không gian này?", isPresented: Binding(
                get: { clearSpace != nil },
                set: { if !$0 { clearSpace = nil } }
            )) {
                Button("Xóa cookie và dữ liệu", role: .destructive) {
                    guard let space = clearSpace else { return }
                    clearSpace = nil
                    busy = true
                    Task {
                        await library.clearData(space)
                        busy = false
                    }
                }
            } message: {
                Text("Các không gian khác sẽ không bị ảnh hưởng.")
            }
            .alert("Thông báo", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear {
                if requireUnlock { isLocked = true; authenticate() }
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .background && requireUnlock { isLocked = true }
                if newPhase == .active && requireUnlock && isLocked { authenticate() }
            }
            .onChange(of: requireUnlock) { _, newValue in
                isLocked = newValue
                if newValue { authenticate() }
            }
        }
    }

    @ViewBuilder
    private func compactFeatureButton(
        title: String,
        subtitle: String,
        icon: String,
        colors: [Color],
        badge: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 32, height: 32)
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(title)
                            .font(.caption.bold())
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if let badge, !badge.isEmpty {
                            Text(badge)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(colors.first ?? .blue, in: Capsule())
                        }
                    }
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill((colors.first ?? .blue).opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke((colors.first ?? .blue).opacity(0.24), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func authenticate() {
        let context = LAContext()
        context.evaluatePolicy(.deviceOwnerAuthentication,
                                localizedReason: "Mở khóa ViePN Smart+") { success, _ in
            DispatchQueue.main.async {
                if success { isLocked = false }
            }
        }
    }
}

struct AddSpaceSheet: View {
    @EnvironmentObject private var library: SpaceLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var platform: SpacePlatform = .facebook
    @State private var name = "Facebook 01"
    @State private var urlText = SpacePlatform.facebook.home
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Dịch vụ") {
                    Picker("Chọn nền tảng", selection: $platform) {
                        ForEach(SpacePlatform.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .onChange(of: platform) { _, value in
                        name = value.rawValue + " 01"
                        urlText = value.home
                    }
                }
                Section("Không gian") {
                    TextField("Tên gợi nhớ", text: $name)
                    TextField("Địa chỉ HTTPS", text: $urlText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    Label("Mỗi không gian có vùng cookie, dữ liệu web, Dấu vân tay và Kho Token riêng biệt.",
                          systemImage: "lock.shield")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Không gian mới")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Hủy") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Tạo") {
                        do {
                            try library.add(name: name, platform: platform, url: urlText)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            }
            .alert("Không thể tạo", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }
}

@MainActor
final class BrowserState: ObservableObject {
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    weak var webView: WKWebView?

    func sync(_ webView: WKWebView) {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
    }

    func back() { webView?.goBack() }
    func forward() { webView?.goForward() }
    func reload() { webView?.reload() }
}

struct SpaceBrowser: View {
    @EnvironmentObject private var library: SpaceLibrary
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = BrowserState()
    let space: Space

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Phiên độc lập • " + space.platform.rawValue, systemImage: "lock.shield.fill")
                    .font(.caption).foregroundStyle(.secondary)
                if let pxy = space.proxy, pxy.isEnabled {
                    Text("• \(pxy.displaySummary)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.blue)
                }
                Spacer()
                if browser.isLoading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            IsolatedWebView(space: space, browser: browser, launchURL: library.lastPage(for: space))
            if space.platform == .facebook {
                SecureLoginControls(space: space, webView: browser.webView)
            }
            HStack {
                Button(action: browser.back) { Image(systemName: "chevron.left") }
                    .disabled(!browser.canGoBack)
                Spacer()
                Button(action: browser.forward) { Image(systemName: "chevron.right") }
                    .disabled(!browser.canGoForward)
                Spacer()
                Button(action: browser.reload) { Image(systemName: "arrow.clockwise") }
            }
            .font(.title3)
            .padding(.horizontal, 32).padding(.vertical, 14)
            .background(.regularMaterial)
        }
        .navigationTitle(space.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Đóng") { dismiss() }
            }
        }
    }
}

struct IsolatedWebView: UIViewRepresentable {
    let space: Space
    @ObservedObject var browser: BrowserState
    let launchURL: URL?

    func makeCoordinator() -> Coordinator { Coordinator(space: space, browser: browser) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let store = WKWebsiteDataStore(forIdentifier: space.id)

        // 1. Cấu hình Proxy (nếu có và đang bật)
        if let proxy = space.proxy, proxy.isEnabled {
            store.proxyConfigurations = [proxy.toNetworkProxyConfiguration()]
        } else {
            store.proxyConfigurations = []
        }
        config.websiteDataStore = store

        // 2. Cấu hình Dấu vân tay độc lập (Anti-Detect)
        let fp = space.fingerprint ?? SpaceFingerprint.defaultFor(spaceId: space.id)

        let contentController = WKUserContentController()
        let scriptSource = fp.buildAntiDetectScript()
        let userScript = WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        contentController.addUserScript(userScript)
        config.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = fp.userAgent
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        browser.webView = webView
        let targetURL = launchURL ?? SpaceLibrary.safeURL(space.url)
        Task { @MainActor in
            if let vault = try? SecureLoginStore.readTokenVault(space.id) {
                _ = await WebCookieBridge.injectCookies(from: vault, into: space.id)
            }
            if let url = targetURL {
                webView.load(URLRequest(url: url))
            }
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        uiView.navigationDelegate = nil
        uiView.configuration.userContentController.removeAllUserScripts()
        coordinator.browser.webView = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let space: Space
        let browser: BrowserState
        private var lastExtractedUser: String = ""
        private var isExtracting = false

        init(space: Space, browser: BrowserState) {
            self.space = space
            self.browser = browser
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            browser.sync(webView)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            browser.sync(webView)
            AppLogger.shared.debug("WebView", "[\(space.name)] Tải xong: \(webView.url?.host ?? "?")")

            // Tự động trích xuất Cookie & Token khi người dùng đăng nhập Facebook thành công trong không gian
            guard space.platform == .facebook,
                  let host = webView.url?.host?.lowercased(),
                  host.contains("facebook.com"),
                  !isExtracting else { return }

            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                if let cUser = cookies.first(where: { $0.name == "c_user" && !$0.value.isEmpty })?.value {
                    let existingVault = try? SecureLoginStore.readTokenVault(self.space.id)
                    let needsExtraction = existingVault == nil ||
                        existingVault?.originalToken.isEmpty == true ||
                        existingVault?.uid != cUser

                    if needsExtraction && self.lastExtractedUser != cUser {
                        self.isExtracting = true
                        defer { self.isExtracting = false }
                        self.lastExtractedUser = cUser
                        let res = await WebCookieBridge.extractTokenAndSave(for: self.space, webView: webView)
                        if res.success {
                            AppLogger.shared.info("Auth", "[\(self.space.name)] Tự động lấy Token cho UID \(cUser): \(res.message)")
                        }
                    }
                }
            }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            browser.sync(webView)
            AppLogger.shared.error("WebView", "[\(space.name)] Lỗi điều hướng", detail: error.localizedDescription)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            browser.sync(webView)
            AppLogger.shared.error("WebView", "[\(space.name)] Lỗi tải trang", detail: error.localizedDescription)
        }
    }
}
