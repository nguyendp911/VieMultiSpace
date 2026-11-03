import SwiftUI
import Network

// MARK: - Batch Proxy & Fingerprint Manager View

struct BatchProxyManagerView: View {
    @EnvironmentObject private var library: SpaceLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var selectedIDs: Set<UUID> = []
    @State private var selectedTab: Int = 0 // 0: Gán Proxy, 1: Kiểm tra Proxy, 2: Dấu vân tay

    // Tab Gán Proxy
    enum ProxyBatchMode: String, CaseIterable, Identifiable {
        case distributeList = "📋 Phân bổ danh sách"
        case assignSingle = "🔗 Gán 1 Proxy chung"
        case clearDirect = "🌐 Xóa Proxy (Direct)"
        var id: String { rawValue }
    }
    @State private var proxyBatchMode: ProxyBatchMode = .distributeList
    @State private var rawProxyListText = ""
    @State private var singleProxyText = ""
    @State private var defaultProtocol: ProxyProtocol = .http
    @State private var roundRobin = true

    // Tab Kiểm tra
    @State private var isTesting = false
    @State private var testingCurrentIndex = 0
    @State private var testingTotalCount = 0
    @State private var testResults: [UUID: ProxyTester.TestResult] = [:]

    // Tab Dấu vân tay
    @State private var fingerprintPresetChoice: String = "random" // "random" hoặc rawValue của DeviceModelPreset

    // Trạng thái thông báo
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showAlert = false

    // Sheet chỉnh sửa riêng lẻ 1 không gian
    @State private var editingSpace: Space?

    private var selectedSpaces: [Space] {
        library.spaces.filter { selectedIDs.contains($0.id) }
    }

    private var parsedProxyList: [SpaceProxy] {
        ProxyParser.parseMultipleLines(rawProxyListText, defaultScheme: defaultProtocol)
    }

    private var parsedSingleProxy: SpaceProxy? {
        ProxyParser.parse(singleProxyText, defaultScheme: defaultProtocol)
    }

    var body: some View {
        Form {
            spaceSelectionSection
            tabSelectionSection

            if selectedTab == 0 {
                batchProxySetupSection
            } else if selectedTab == 1 {
                batchProxyTestSection
            } else {
                batchFingerprintSection
            }

            statusSummarySection
        }
        .navigationTitle("Proxy & Dấu vân tay")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if selectedIDs.isEmpty {
                selectedIDs = Set(library.spaces.map(\.id))
            }
        }
        .sheet(item: $editingSpace) { space in
            NavigationStack {
                SpaceProxyFingerprintSheet(space: space)
            }
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    // MARK: - Section 1: Chọn Không Gian

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
                .disabled(isTesting)
                Button("Bỏ chọn") {
                    selectedIDs.removeAll()
                }
                .disabled(isTesting)
            }

            ForEach(library.spaces) { space in
                let isSelected = selectedIDs.contains(space.id)
                HStack(spacing: 10) {
                    Button {
                        guard !isTesting else { return }
                        if isSelected { selectedIDs.remove(space.id) }
                        else { selectedIDs.insert(space.id) }
                    } label: {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? Color.blue : Color.secondary)
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(space.name)
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                            Spacer()
                            Button {
                                editingSpace = space
                            } label: {
                                Image(systemName: "slider.horizontal.3")
                                    .font(.caption)
                                    .padding(4)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }

                        // Hiển thị trạng thái Proxy
                        if let pxy = space.proxy, pxy.isEnabled {
                            HStack(spacing: 4) {
                                Text(pxy.displaySummary)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.blue)

                                if let res = testResults[space.id] {
                                    if res.success {
                                        Text("• \(res.ip) (\(res.latencyMs)ms)")
                                            .font(.caption2)
                                            .foregroundStyle(.green)
                                    } else {
                                        Text("• ❌ Lỗi kết nối")
                                            .font(.caption2)
                                            .foregroundStyle(.red)
                                    }
                                } else if let lastIP = pxy.lastTestedIP {
                                    Text("• \(lastIP) (\(pxy.lastTestedLatencyMs ?? 0)ms)")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                }
                            }
                        } else {
                            Text("🌐 Kết nối trực tiếp (Direct)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        // Hiển thị thông số vân tay
                        let fp = space.fingerprint ?? SpaceFingerprint.defaultFor(spaceId: space.id)
                        Text("📱 \(fp.displaySummary)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("1. Chọn không gian")
        } footer: {
            Text("Bấm vào biểu tượng thanh trượt bên cạnh mỗi không gian để chỉnh sửa riêng lẻ.")
        }
    }

    // MARK: - Section 2: Chọn Chức Năng

    @ViewBuilder
    private var tabSelectionSection: some View {
        Section("2. Chọn chức năng") {
            Picker("Chức năng", selection: $selectedTab) {
                Text("Gán Proxy").tag(0)
                Text("Kiểm tra").tag(1)
                Text("Dấu vân tay").tag(2)
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Section 3: Gán Proxy Hàng Loạt

    @ViewBuilder
    private var batchProxySetupSection: some View {
        Section {
            Picker("Cách thức gán", selection: $proxyBatchMode) {
                ForEach(ProxyBatchMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }

            if proxyBatchMode == .distributeList {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Dán danh sách Proxy (mỗi hàng 1 proxy):")
                            .font(.caption.bold())
                        Spacer()
                        Button("Dán") {
                            if let clip = UIPasteboard.general.string {
                                rawProxyListText = clip
                            }
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)

                        Button("Xóa") {
                            rawProxyListText = ""
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }

                    TextEditor(text: $rawProxyListText)
                        .frame(minHeight: 120)
                        .font(.caption.monospaced())
                        .padding(6)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))

                    HStack {
                        Text("Đã nhận diện: \(parsedProxyList.count) proxy")
                            .font(.caption.bold())
                            .foregroundStyle(parsedProxyList.isEmpty ? .secondary : .green)
                        Spacer()
                        Picker("Mặc định", selection: $defaultProtocol) {
                            ForEach(ProxyProtocol.allCases) { p in
                                Text(p.rawValue).tag(p)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    Toggle("Lặp vòng (Round-robin) nếu thiếu proxy", isOn: $roundRobin)
                        .font(.caption)

                    if !selectedSpaces.isEmpty && !parsedProxyList.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Xem trước phân bổ cho từng không gian:")
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                            ForEach(0..<selectedSpaces.count, id: \.self) { idx in
                                let sp = selectedSpaces[idx]
                                let pxy: SpaceProxy?
                                if idx < parsedProxyList.count {
                                    pxy = parsedProxyList[idx]
                                } else if roundRobin && !parsedProxyList.isEmpty {
                                    pxy = parsedProxyList[idx % parsedProxyList.count]
                                } else {
                                    pxy = nil
                                }
                                Text("• \(sp.name): \(pxy?.displaySummary ?? "[Bỏ qua - giữ nguyên]")")
                                    .font(.caption2)
                                    .foregroundStyle(pxy != nil ? Color.primary : Color.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.top, 4)
                    }
                }

                Button {
                    applyBatchDistributeProxies()
                } label: {
                    Label("Áp dụng phân bổ cho \(selectedSpaces.count) không gian", systemImage: "checkmark.circle.fill")
                        .fontWeight(.bold)
                }
                .disabled(selectedSpaces.isEmpty || parsedProxyList.isEmpty)

            } else if proxyBatchMode == .assignSingle {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Dán Proxy dùng chung (hỗ trợ mọi định dạng):")
                        .font(.caption.bold())
                    TextField("host:port:user:pass hoặc socks5://user:pass@host:port...", text: $singleProxyText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())

                    if let p = parsedSingleProxy {
                        Text("✅ Hợp lệ: \(p.displaySummary)")
                            .font(.caption2.bold())
                            .foregroundStyle(.green)
                    } else if !singleProxyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("⚠️ Định dạng proxy chưa đúng. Hỗ trợ host:port, host:port:u:p, socks5://...")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }

                Button {
                    applyBatchSingleProxy()
                } label: {
                    Label("Gán Proxy này cho \(selectedSpaces.count) không gian", systemImage: "arrow.triangle.branch")
                        .fontWeight(.bold)
                }
                .disabled(selectedSpaces.isEmpty || parsedSingleProxy == nil)

            } else if proxyBatchMode == .clearDirect {
                Button(role: .destructive) {
                    library.batchClearProxies(for: selectedIDs)
                    alertTitle = "Thành công"
                    alertMessage = "Đã đưa \(selectedSpaces.count) không gian về kết nối mạng trực tiếp (Direct)."
                    showAlert = true
                } label: {
                    Label("Đưa \(selectedSpaces.count) không gian về Direct (Không Proxy)", systemImage: "trash")
                        .fontWeight(.bold)
                }
                .disabled(selectedSpaces.isEmpty)
            }
        } header: {
            Text("3. Thiết lập Proxy")
        } footer: {
            Text("Hỗ trợ mọi định dạng: host:port, host:port:user:pass, user:pass@host:port, socks5://..., http://..., https://...")
        }
    }

    // MARK: - Section 4: Kiểm Tra Proxy Hàng Loạt

    @ViewBuilder
    private var batchProxyTestSection: some View {
        Section {
            let proxySpaces = selectedSpaces.filter { $0.proxy != nil && $0.proxy!.isEnabled }

            Text("Có \(proxySpaces.count)/\(selectedSpaces.count) không gian đang kích hoạt Proxy.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if isTesting {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Đang kiểm tra (\(testingCurrentIndex)/\(testingTotalCount))...")
                        .font(.subheadline)
                    Spacer()
                }
                .padding(.vertical, 4)
            } else {
                Button {
                    Task { await runBatchProxyTest(spaces: proxySpaces) }
                } label: {
                    Label("Kiểm tra kết nối \(proxySpaces.count) Proxy", systemImage: "bolt.horizontal.circle.fill")
                        .fontWeight(.bold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .disabled(proxySpaces.isEmpty)
            }
        } header: {
            Text("3. Kiểm tra kết nối Proxy")
        } footer: {
            Text("Gửi tín hiệu kiểm tra an toàn qua Proxy để xác định IP cổng ra thực tế, quốc gia và độ trễ (ping ms).")
        }
    }

    // MARK: - Section 5: Tạo Dấu Vân Tay Hàng Loạt

    @ViewBuilder
    private var batchFingerprintSection: some View {
        Section {
            Picker("Mẫu thiết bị", selection: $fingerprintPresetChoice) {
                Text("🎲 Ngẫu nhiên đa dạng (Khuyên dùng)").tag("random")
                ForEach(DeviceModelPreset.allCases) { preset in
                    Text(preset.rawValue).tag(preset.rawValue)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Mỗi không gian sẽ được tạo một bộ thông số phần cứng, hạt giống Canvas Seed, Audio Seed và WebGL độc nhất vô nhị.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Đảm bảo các trang web (Facebook, Google, TikTok) không thể đối chiếu hay nhận diện các tài khoản thuộc cùng một người dùng.")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            }
            .padding(.vertical, 4)

            Button {
                applyBatchFingerprints()
            } label: {
                Label("🎲 Sinh dấu vân tay mới cho \(selectedSpaces.count) không gian", systemImage: "sparkles")
                    .fontWeight(.bold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .disabled(selectedSpaces.isEmpty)
        } header: {
            Text("3. Dấu vân tay Anti-Detect")
        } footer: {
            Text("Dấu vân tay mới sẽ được áp dụng ngay lập tức ở lần tải tiếp theo của mỗi không gian.")
        }
    }

    // MARK: - Section 6: Thống kê trạng thái

    @ViewBuilder
    private var statusSummarySection: some View {
        Section("Tổng quan hệ thống") {
            let total = library.spaces.count
            let withProxy = library.spaces.filter { $0.proxy != nil && $0.proxy!.isEnabled }.count
            let direct = total - withProxy
            LabeledContent("Tổng số không gian", value: "\(total)")
            LabeledContent("Không gian có Proxy", value: "\(withProxy)")
            LabeledContent("Kết nối trực tiếp", value: "\(direct)")
        }
    }

    // MARK: - Actions

    private func applyBatchDistributeProxies() {
        let proxies = parsedProxyList
        guard !proxies.isEmpty, !selectedSpaces.isEmpty else { return }

        var assignments: [(spaceId: UUID, proxy: SpaceProxy?)] = []
        for idx in selectedSpaces.indices {
            let sp = selectedSpaces[idx]
            if idx < proxies.count {
                assignments.append((sp.id, proxies[idx]))
            } else if roundRobin {
                assignments.append((sp.id, proxies[idx % proxies.count]))
            }
        }

        library.batchApplyProxies(assignments: assignments)
        alertTitle = "Đã phân bổ Proxy"
        alertMessage = "Đã gán thành công proxy riêng cho \(assignments.count) không gian."
        showAlert = true
    }

    private func applyBatchSingleProxy() {
        guard let pxy = parsedSingleProxy, !selectedSpaces.isEmpty else { return }
        let assignments = selectedSpaces.map { ($0.id, Optional(pxy)) }
        library.batchApplyProxies(assignments: assignments)
        alertTitle = "Đã gán Proxy chung"
        alertMessage = "Đã gán \(pxy.displaySummary) cho \(selectedSpaces.count) không gian."
        showAlert = true
    }

    private func applyBatchFingerprints() {
        let preset: DeviceModelPreset?
        if fingerprintPresetChoice == "random" {
            preset = nil
        } else {
            preset = DeviceModelPreset(rawValue: fingerprintPresetChoice)
        }

        library.batchRegenerateFingerprints(for: selectedIDs, preset: preset)
        alertTitle = "Đã tạo dấu vân tay mới"
        alertMessage = "Đã sinh bộ thông số phần cứng, User-Agent, Canvas & Audio seed độc lập cho \(selectedSpaces.count) không gian."
        showAlert = true
    }

    @MainActor
    private func runBatchProxyTest(spaces: [Space]) async {
        isTesting = true
        testingTotalCount = spaces.count
        testingCurrentIndex = 0

        for sp in spaces {
            guard let pxy = sp.proxy, pxy.isEnabled else { continue }
            testingCurrentIndex += 1
            let result = await ProxyTester.test(proxy: pxy)
            testResults[sp.id] = result

            var updatedProxy = pxy
            if result.success {
                updatedProxy.lastTestedIP = result.ip
                updatedProxy.lastTestedCountry = result.country
                updatedProxy.lastTestedLatencyMs = result.latencyMs
                updatedProxy.lastTestedAt = Date()
                updatedProxy.lastTestError = nil
            } else {
                updatedProxy.lastTestError = result.errorMessage
            }
            library.updateSpaceProxy(sp.id, proxy: updatedProxy)
        }

        isTesting = false
        alertTitle = "Hoàn tất kiểm tra"
        let okCount = testResults.values.filter(\.success).count
        alertMessage = "Đã kiểm tra xong: \(okCount)/\(spaces.count) Proxy hoạt động bình thường."
        showAlert = true
    }
}

// MARK: - Single Space Proxy & Fingerprint Sheet

struct SpaceProxyFingerprintSheet: View {
    @EnvironmentObject private var library: SpaceLibrary
    @Environment(\.dismiss) private var dismiss
    let space: Space

    // Proxy State
    @State private var proxyEnabled = false
    @State private var quickProxyInput = ""
    @State private var proxyScheme: ProxyProtocol = .http
    @State private var proxyHost = ""
    @State private var proxyPortText = "8080"
    @State private var proxyUser = ""
    @State private var proxyPass = ""

    // Proxy Test State
    @State private var isTesting = false
    @State private var testResult: ProxyTester.TestResult?

    // Fingerprint State
    @State private var selectedPreset: DeviceModelPreset = .iPhone15Pro
    @State private var userAgent = ""
    @State private var screenW = "393"
    @State private var screenH = "852"
    @State private var cpuCores = "6"
    @State private var ramGB = "8"
    @State private var webGLRenderer = "Apple GPU (Apple A17 Pro)"
    @State private var canvasSeedText = "12345"
    @State private var audioSeedText = "67890"
    @State private var webrtcProtection = true
    @State private var canvasProtection = true
    @State private var audioProtection = true

    var body: some View {
        Form {
            Section("1. Cấu hình Proxy") {
                Toggle("Bật Proxy", isOn: $proxyEnabled)

                if proxyEnabled {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Dán nhanh (hỗ trợ mọi định dạng):")
                            .font(.caption.bold())
                        HStack {
                            TextField("host:port:user:pass hoặc socks5://...", text: $quickProxyInput)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .textFieldStyle(.roundedBorder)
                                .font(.caption.monospaced())
                            Button("Phân tích") {
                                parseQuickInput()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    Picker("Giao thức", selection: $proxyScheme) {
                        ForEach(ProxyProtocol.allCases) { p in
                            Text(p.rawValue).tag(p)
                        }
                    }

                    TextField("Máy chủ (Host / IP)", text: $proxyHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Cổng (Port)", text: $proxyPortText)
                        .keyboardType(.numberPad)

                    TextField("Tài khoản (Tùy chọn)", text: $proxyUser)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField("Mật khẩu (Tùy chọn)", text: $proxyPass)

                    Button {
                        Task { await testCurrentProxy() }
                    } label: {
                        HStack {
                            if isTesting { ProgressView().controlSize(.small) }
                            Text("⚡ Kiểm tra kết nối Proxy này")
                        }
                    }
                    .disabled(isTesting || proxyHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let res = testResult {
                        if res.success {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("✅ Kết nối thành công!")
                                    .font(.caption.bold())
                                    .foregroundStyle(.green)
                                Text("IP cổng ra: \(res.ip) • \(res.country) (\(res.latencyMs)ms)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("❌ \(res.errorMessage ?? "Lỗi kết nối")")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }

            Section("2. Dấu vân tay Anti-Detect") {
                Picker("Mẫu thiết bị", selection: $selectedPreset) {
                    ForEach(DeviceModelPreset.allCases) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                .onChange(of: selectedPreset) { _, newPreset in
                    if newPreset != .custom {
                        applyPresetValues(newPreset)
                    }
                }

                Button("🎲 Sinh ngẫu nhiên bộ thông số mới") {
                    let rand = SpaceFingerprint.generateRandom()
                    loadFingerprint(rand)
                }
                .font(.caption.bold())

                Group {
                    LabeledContent("Độ phân giải", value: "\(screenW) x \(screenH)")
                    LabeledContent("CPU & RAM", value: "\(cpuCores) nhân • \(ramGB) GB RAM")
                    LabeledContent("Card đồ họa", value: webGLRenderer)
                    LabeledContent("Hạt giống Canvas Seed", value: "#\(canvasSeedText)")
                    LabeledContent("Hạt giống Audio Seed", value: "#\(audioSeedText)")
                }
                .font(.caption)

                Toggle("Chống rò rỉ IP qua WebRTC", isOn: $webrtcProtection)
                    .font(.caption)
                Toggle("Nhiễu Canvas Fingerprint", isOn: $canvasProtection)
                    .font(.caption)
                Toggle("Nhiễu Audio Fingerprint", isOn: $audioProtection)
                    .font(.caption)
            }
        }
        .navigationTitle("Proxy & Vân tay • \(space.name)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Hủy") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Lưu") {
                    saveChanges()
                    dismiss()
                }
            }
        }
        .onAppear {
            loadInitialData()
        }
    }

    private func loadInitialData() {
        if let pxy = space.proxy {
            proxyEnabled = pxy.isEnabled
            proxyScheme = pxy.scheme
            proxyHost = pxy.host
            proxyPortText = String(pxy.port)
            proxyUser = pxy.username ?? ""
            proxyPass = pxy.password ?? ""
        }
        let fp = space.fingerprint ?? SpaceFingerprint.defaultFor(spaceId: space.id)
        loadFingerprint(fp)
    }

    private func loadFingerprint(_ fp: SpaceFingerprint) {
        selectedPreset = fp.preset
        userAgent = fp.userAgent
        screenW = String(fp.screenWidth)
        screenH = String(fp.screenHeight)
        cpuCores = String(fp.hardwareConcurrency)
        ramGB = String(fp.deviceMemory)
        webGLRenderer = fp.webGLRenderer
        canvasSeedText = String(fp.canvasSeed)
        audioSeedText = String(fp.audioSeed)
        webrtcProtection = fp.webrtcProtectionEnabled
        canvasProtection = fp.canvasNoiseEnabled
        audioProtection = fp.audioNoiseEnabled
    }

    private func applyPresetValues(_ preset: DeviceModelPreset) {
        let dummy = SpaceFingerprint.makePreset(
            preset: preset,
            canvasSeed: UInt32(canvasSeedText) ?? 12345,
            audioSeed: UInt32(audioSeedText) ?? 67890
        )
        loadFingerprint(dummy)
    }

    private func parseQuickInput() {
        if let p = ProxyParser.parse(quickProxyInput, defaultScheme: proxyScheme) {
            proxyScheme = p.scheme
            proxyHost = p.host
            proxyPortText = String(p.port)
            proxyUser = p.username ?? ""
            proxyPass = p.password ?? ""
        }
    }

    @MainActor
    private func testCurrentProxy() async {
        guard let port = UInt16(proxyPortText), !proxyHost.isEmpty else { return }
        isTesting = true
        let dummy = SpaceProxy(
            isEnabled: true,
            scheme: proxyScheme,
            host: proxyHost,
            port: port,
            username: proxyUser.isEmpty ? nil : proxyUser,
            password: proxyPass.isEmpty ? nil : proxyPass
        )
        testResult = await ProxyTester.test(proxy: dummy)
        isTesting = false
    }

    private func saveChanges() {
        // Lưu Proxy
        var proxyToSave: SpaceProxy? = nil
        if proxyEnabled, let port = UInt16(proxyPortText), !proxyHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var p = SpaceProxy(
                id: space.proxy?.id ?? UUID(),
                isEnabled: true,
                scheme: proxyScheme,
                host: proxyHost.trimmingCharacters(in: .whitespacesAndNewlines),
                port: port,
                username: proxyUser.isEmpty ? nil : proxyUser,
                password: proxyPass.isEmpty ? nil : proxyPass
            )
            if let res = testResult, res.success {
                p.lastTestedIP = res.ip
                p.lastTestedCountry = res.country
                p.lastTestedLatencyMs = res.latencyMs
                p.lastTestedAt = Date()
            }
            proxyToSave = p
        }
        library.updateSpaceProxy(space.id, proxy: proxyToSave)

        // Lưu Dấu vân tay
        let seedC = UInt32(canvasSeedText) ?? UInt32.random(in: 10_000...999_999)
        let seedA = UInt32(audioSeedText) ?? UInt32.random(in: 10_000...999_999)
        let w = Int(screenW) ?? 393
        let h = Int(screenH) ?? 852
        let cores = Int(cpuCores) ?? 6
        let ram = Int(ramGB) ?? 8

        let fp = SpaceFingerprint(
            id: space.fingerprint?.id ?? UUID(),
            preset: selectedPreset,
            userAgent: userAgent.isEmpty ? "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1" : userAgent,
            appVersion: "5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15",
            platform: "iPhone",
            vendor: "Apple Computer, Inc.",
            screenWidth: w,
            screenHeight: h,
            screenScale: 3.0,
            hardwareConcurrency: cores,
            deviceMemory: ram,
            webGLVendor: "Apple Inc.",
            webGLRenderer: webGLRenderer,
            canvasSeed: seedC,
            audioSeed: seedA,
            canvasNoiseEnabled: canvasProtection,
            audioNoiseEnabled: audioProtection,
            webGLSpoofingEnabled: true,
            webrtcProtectionEnabled: webrtcProtection
        )
        library.updateSpaceFingerprint(space.id, fingerprint: fp)
    }
}
