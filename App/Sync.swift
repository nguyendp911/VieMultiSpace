import SwiftUI
import WebKit

// A conservative batch navigator: one WKWebView at a time, each using the
// profile's own persistent WKWebsiteDataStore. Never copies clicks, posts,
// cookies or passwords between accounts.
enum BatchMode: String, CaseIterable {
    case openURL = "Mở URL"
    case refresh = "Nạp lại"
}

enum BatchStatus {
    case queued, loading, success, failed, cancelled

    var title: String {
        switch self {
        case .queued: return "Đang chờ"
        case .loading: return "Đang tải"
        case .success: return "Đã nạp"
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
}

@MainActor
final class BatchSyncEngine: NSObject, ObservableObject, WKNavigationDelegate {
    @Published private(set) var rows: [BatchRow] = []
    @Published private(set) var isRunning = false
    @Published private(set) var activeWebView: WKWebView?

    private var queue: [Space] = []
    private var activeSpace: Space?
    private var activeTarget: URL?
    private var targetURL: URL?
    private var mode: BatchMode = .openURL
    private weak var library: SpaceLibrary?
    private var timeoutTask: Task<Void, Never>?

    var completed: Int { rows.filter { $0.status == .success || $0.status == .failed || $0.status == .cancelled }.count }
    var succeeded: Int { rows.filter { $0.status == .success }.count }

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

    func stop() {
        guard isRunning else { return }
        isRunning = false
        timeoutTask?.cancel()
        timeoutTask = nil
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
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: space.id)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        activeWebView = webView

        timeoutTask?.cancel()
        timeoutTask = Task { [weak self, weak webView] in
            do {
                try await Task.sleep(nanoseconds: 40_000_000_000)
                guard let self, let webView, self.activeWebView === webView else { return }
                self.finish(webView, status: .failed, detail: "Quá thời gian tải (40 giây)")
            } catch {
                // The timeout was cancelled after a navigation or by Stop.
            }
        }
        // Let SwiftUI attach the WKWebView to the visible preview first.
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
        finish(webView, status: .success, detail: "Trang đã nạp • không xác nhận trạng thái đăng nhập")
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
    @State private var mode: BatchMode = .openURL
    @State private var urlText = "https://www.facebook.com/"

    private var selectedSpaces: [Space] {
        library.spaces.filter { selectedIDs.contains($0.id) }
    }

    private var targetURL: URL? {
        SpaceLibrary.safeURL(urlText)
    }

    private var canStart: Bool {
        !engine.isRunning && !selectedSpaces.isEmpty
            && (mode == .refresh || targetURL != nil)
    }

    var body: some View {
        Form {
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
                    Button {
                        guard !engine.isRunning else { return }
                        if selectedIDs.contains(space.id) { selectedIDs.remove(space.id) }
                        else { selectedIDs.insert(space.id) }
                    } label: {
                        HStack {
                            Image(systemName: selectedIDs.contains(space.id)
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedIDs.contains(space.id) ? .blue : .secondary)
                            Image(systemName: space.platform.icon)
                                .foregroundStyle(space.platform.color)
                            Text(space.name).foregroundStyle(.primary)
                            Spacer()
                        }
                    }
                    .disabled(engine.isRunning)
                }
            } header: {
                Text("Chọn các phiên đăng nhập")
            } footer: {
                Text("Các không gian dùng cookie riêng; nếu đã lưu Cookie trong Kho Token, ứng dụng sẽ tự nạp trước khi mở.")
            }

            Section("Lệnh đồng bộ") {
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
                } else {
                    Text("Nạp lại URL cuối cùng đã mở theo nhóm, hoặc trang chủ của không gian.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                if engine.isRunning {
                    Button(role: .destructive) { engine.stop() } label: {
                        Label("Dừng hàng đợi", systemImage: "stop.fill")
                    }
                } else {
                    Button {
                        engine.start(spaces: selectedSpaces,
                                     mode: mode,
                                     url: mode == .openURL ? targetURL : nil,
                                     library: library)
                    } label: {
                        Label("Thực hiện với \(selectedSpaces.count) không gian",
                              systemImage: "play.fill")
                            .fontWeight(.semibold)
                    }
                    .disabled(!canStart)
                }
            }

            if !engine.rows.isEmpty {
                Section {
                    LabeledContent("Hoàn tất", value: "\(engine.completed)/\(engine.rows.count)")
                    LabeledContent("Nạp thành công", value: "\(engine.succeeded)")
                    ForEach(engine.rows) { row in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: row.status.symbol)
                                .foregroundStyle(row.status.tint)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.name).fontWeight(.medium)
                                Text(row.status.title + " · " + row.detail)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                } header: {
                    Text("Trạng thái từng không gian")
                } footer: {
                    Text("Đã nạp chỉ xác nhận WebKit tải trang thành công, không xác nhận Facebook đã đăng nhập.")
                }
            }

            if engine.isRunning && engine.activeWebView != nil {
                Section("Xem trước phiên đang tải") {
                    BatchWebPreview(webView: engine.activeWebView)
                        .frame(height: 230)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }

            Section {
                Text("Đây là thao tác điều hướng/nạp trang lần lượt, chỉ chạy khi ứng dụng ở phía trước. Không tự động chạm, bình luận, gửi tin nhắn hay đăng bài hàng loạt.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("MultiSpace Sync")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { engine.stop() }
        }
        .onDisappear { engine.stop() }
    }
}
