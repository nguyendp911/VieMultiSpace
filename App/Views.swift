import SwiftUI
import WebKit
import LocalAuthentication

struct SpaceDashboard: View {
    @EnvironmentObject private var library: SpaceLibrary
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("vie.multispace.requireUnlock") private var requireUnlock = false
    @State private var showAdd = false
    @State private var openSpace: Space?
    @State private var renameSpace: Space?
    @State private var renameValue = ""
    @State private var deleteSpace: Space?
    @State private var clearSpace: Space?
    @State private var errorMessage: String?
    @State private var busy = false
    @State private var isLocked = false

    var body: some View {
        NavigationStack {
            ZStack {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Vie MultiSpace", systemImage: "square.stack.3d.up.fill")
                                .font(.title2.bold())
                            Text("Quản lý nhiều phiên đăng nhập web độc lập trên iPhone.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("\(library.spaces.count) không gian")
                                .font(.caption.monospacedDigit())
                        }
                        .padding(.vertical, 10)
                    }
                    Section("Quản lý tài khoản") {
                        NavigationLink {
                            AccountCenterView()
                        } label: {
                            Label("Trung tâm tài khoản", systemImage: "person.2.crop.square.stack")
                        }
                    }
                    Section("Điều khiển nhóm") {
                        NavigationLink {
                            MultiSpaceSyncView()
                        } label: {
                            Label("MultiSpace Sync — thao tác theo nhóm", systemImage: "square.stack.3d.up")
                        }
                    }
                    Section("Không gian của tôi") {
                        ForEach(library.spaces) { space in
                            Button { openSpace = space } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: space.platform.icon)
                                        .font(.title3)
                                        .foregroundStyle(.white)
                                        .frame(width: 43, height: 43)
                                        .background(space.platform.color, in: RoundedRectangle(cornerRadius: 11))
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(space.name).font(.headline).foregroundStyle(.primary)
                                        Text(space.platform.rawValue + " · Phiên web riêng")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 4)
                            }
                            .contextMenu {
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
                        Button { showAdd = true } label: {
                            Label("Tạo không gian mới", systemImage: "plus.circle.fill")
                                .fontWeight(.semibold)
                        }
                        .disabled(busy)
                    }
                    Section {
                        Text("Ứng dụng không sao chép Facebook gốc. Cookie và dữ liệu web của mỗi không gian chỉ được lưu trên iPhone; không gửi về máy chủ của chúng tôi.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color(uiColor: .systemGroupedBackground))

                if isLocked {
                    VStack(spacing: 20) {
                        Image(systemName: "lock.shield.fill").font(.system(size: 55))
                        Text("Vie MultiSpace đã khóa").font(.title2.bold())
                        Button("Mở khóa bằng Face ID / mã máy") { authenticate() }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .systemBackground).ignoresSafeArea())
                }
            }
            .navigationTitle("MultiSpace")
            .toolbar {
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
            .sheet(isPresented: $showAdd) { AddSpaceSheet() }
            .sheet(item: $openSpace) { space in
                NavigationStack { SpaceBrowser(space: space) }
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
                    busy = true
                    Task {
                        do { try await library.delete(space) }
                        catch { errorMessage = error.localizedDescription }
                        busy = false
                    }
                }
            } message: {
                Text("Cookie, phiên đăng nhập và dữ liệu web của không gian này sẽ bị xóa.")
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

    private func authenticate() {
        let context = LAContext()
        context.evaluatePolicy(.deviceOwnerAuthentication,
                               localizedReason: "Mở khóa Vie MultiSpace") { success, _ in
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
                    Label("Chỉ đăng nhập trên website chính thức. Mỗi không gian có vùng cookie và dữ liệu web riêng.",
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

    func makeCoordinator() -> Coordinator { Coordinator(browser: browser) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: space.id)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        browser.webView = webView
        if let url = launchURL ?? SpaceLibrary.safeURL(space.url) {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let browser: BrowserState
        init(browser: BrowserState) { self.browser = browser }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            browser.sync(webView)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            browser.sync(webView)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            browser.sync(webView)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            browser.sync(webView)
        }
    }
}
