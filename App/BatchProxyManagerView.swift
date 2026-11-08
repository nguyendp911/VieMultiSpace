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
                            .foregroundStyle(parsedProxyList.isEmpty ? Color.secondary : Color.green)
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
                                let pxy = previewProxy(forIndex: idx)
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
            // Header hiển thị Độ Trust Vân tay trung bình
            let scores = selectedSpaces.compactMap { $0.fingerprint?.trustReport.score }
            let avgScore = scores.isEmpty ? 98 : (scores.reduce(0, +) / scores.count)
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Độ Trust Vân tay Trung bình")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Image(systemName: avgScore >= 90 ? "shield.checkmark.fill" : "shield.fill")
                            .foregroundStyle(avgScore >= 90 ? .green : .orange)
                        Text("\(avgScore)/100")
                            .font(.title3.bold().monospacedDigit())
                            .foregroundStyle(.primary)
                        Text(avgScore >= 95 ? "• Tuyệt đối an toàn" : (avgScore >= 85 ? "• Rất cao" : "• Khá"))
                            .font(.caption2.bold())
                            .foregroundStyle(avgScore >= 90 ? .green : .orange)
                    }
                }
                Spacer()
                Button {
                    applyBatchFingerprints()
                } label: {
                    Label("Nâng 100% Trust", systemImage: "sparkles")
                        .font(.caption.bold())
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.small)
            }
            .padding(.vertical, 4)

            Picker("Mẫu thiết bị", selection: $fingerprintPresetChoice) {
                Text("🎲 Ngẫu nhiên đa dạng (Khuyên dùng)").tag("random")
                ForEach(DeviceModelPreset.allCases) { preset in
                    Text(preset.rawValue).tag(preset.rawValue)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("🛡️ 6 Lớp bảo vệ chống nhận diện & tăng độ Trust:")
                    .font(.caption.bold())
                VStack(alignment: .leading, spacing: 3) {
                    Text("• Canvas 2D + Font Subpixel (Hạt giống Seed độc nhất)")
                    Text("• AudioContext & AnalyserNode Micro-noise")
                    Text("• WebGL GPU Mask & readPixels Shield")
                    Text("• Chống rò rỉ IP qua WebRTC STUN Candidates")
                    Text("• MediaDevices ảo riêng (Mic, Cam, Loa)")
                    Text("• Định danh Android FB4A riêng (ADID, SIM, Device ID)")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)

            Button {
                applyBatchFingerprints()
            } label: {
                Label("🚀 Tạo vân tay Siêu Sạch cho \(selectedSpaces.count) không gian", systemImage: "wand.and.stars")
                    .fontWeight(.bold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .disabled(selectedSpaces.isEmpty)
        } header: {
            Text("3. Dấu vân tay Anti-Detect Cao Cấp")
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

    private func previewProxy(forIndex idx: Int) -> SpaceProxy? {
        let proxies = parsedProxyList
        if idx < proxies.count {
            return proxies[idx]
        } else if roundRobin && !proxies.isEmpty {
            return proxies[idx % proxies.count]
        } else {
            return nil
        }
    }

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
    @State private var selectedPreset: DeviceModelPreset = .iPhone16Pro
    @State private var userAgent = ""
    @State private var screenW = "393"
    @State private var screenH = "852"
    @State private var cpuCores = "6"
    @State private var ramGB = "8"
    @State private var webGLRenderer = "Apple GPU (Apple A18 Pro)"
    @State private var canvasSeedText = "12345"
    @State private var audioSeedText = "67890"
    @State private var fontSeedText = "13579"
    @State private var webglSeedText = "24680"
    @State private var webrtcProtection = true
    @State private var canvasProtection = true
    @State private var fontProtection = true
    @State private var audioProtection = true
    @State private var webglNoiseProtection = true
    @State private var mediaDevicesProtection = true
    @State private var androidDeviceId = ""
    @State private var androidAdid = ""
    @State private var androidSimSerial = ""
    @State private var timeZone = "Asia/Ho_Chi_Minh"

    private var currentPreviewFP: SpaceFingerprint {
        let seedC = UInt32(canvasSeedText) ?? 12345
        let seedA = UInt32(audioSeedText) ?? 67890
        let seedF = UInt32(fontSeedText) ?? 13579
        let seedW = UInt32(webglSeedText) ?? 24680
        let w = Int(screenW) ?? 393
        let h = Int(screenH) ?? 852
        let cores = Int(cpuCores) ?? 6
        let ram = Int(ramGB) ?? 8

        return SpaceFingerprint(
            id: space.id,
            preset: selectedPreset,
            userAgent: userAgent.isEmpty ? "Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15" : userAgent,
            appVersion: "5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15",
            platform: selectedPreset.isAndroid ? "Linux armv8l" : (selectedPreset == .macBookProM3 ? "MacIntel" : "iPhone"),
            vendor: selectedPreset.isAndroid ? "Google Inc." : "Apple Computer, Inc.",
            screenWidth: w,
            screenHeight: h,
            screenScale: selectedPreset == .iPadProM4 || selectedPreset == .iPadPro129 || selectedPreset == .macBookProM3 ? 2.0 : 3.0,
            hardwareConcurrency: cores,
            deviceMemory: ram,
            maxTouchPoints: selectedPreset == .macBookProM3 ? 0 : 5,
            webGLVendor: selectedPreset.isAndroid ? "Qualcomm" : "Apple Inc.",
            webGLRenderer: webGLRenderer,
            canvasSeed: seedC,
            audioSeed: seedA,
            fontSeed: seedF,
            webglSeed: seedW,
            androidDeviceId: androidDeviceId.isEmpty ? nil : androidDeviceId,
            androidAdid: androidAdid.isEmpty ? nil : androidAdid,
            androidSimSerial: androidSimSerial.isEmpty ? nil : androidSimSerial,
            timeZone: timeZone,
            canvasNoiseEnabled: canvasProtection,
            audioNoiseEnabled: audioProtection,
            fontNoiseEnabled: fontProtection,
            webGLSpoofingEnabled: true,
            webGLNoiseEnabled: webglNoiseProtection,
            webrtcProtectionEnabled: webrtcProtection,
            mediaDevicesProtectionEnabled: mediaDevicesProtection
        )
    }

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

            Section("2. Điểm Tin Cậy & Vân Tay Anti-Detect") {
                let report = currentPreviewFP.trustReport
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: report.score >= 90 ? "shield.checkmark.fill" : "shield.fill")
                            .foregroundStyle(report.score >= 90 ? .green : .orange)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Độ Trust Vân tay: \(report.score)/100")
                                .font(.subheadline.bold())
                            Text(report.level)
                                .font(.caption2)
                                .foregroundStyle(report.score >= 90 ? .green : .orange)
                        }
                        Spacer()
                        Button {
                            optimizeTo100Percent()
                        } label: {
                            Label("Tối ưu 100%", systemImage: "sparkles")
                                .font(.caption.bold())
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .controlSize(.small)
                    }

                    Divider()

                    ForEach(report.checks) { chk in
                        HStack(spacing: 6) {
                            Image(systemName: chk.passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(chk.passed ? .green : .orange)
                                .font(.caption)
                            Text(chk.name)
                                .font(.caption.bold())
                            Spacer()
                            Text(chk.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.vertical, 4)

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
                    LabeledContent("Hạt giống Font Seed", value: "#\(fontSeedText)")
                    LabeledContent("Hạt giống WebGL Seed", value: "#\(webglSeedText)")
                }
                .font(.caption)

                Toggle("Chống rò rỉ IP qua WebRTC", isOn: $webrtcProtection)
                    .font(.caption)
                Toggle("Nhiễu Canvas 2D Fingerprint", isOn: $canvasProtection)
                    .font(.caption)
                Toggle("Khử vết đo chữ Font Subpixel", isOn: $fontProtection)
                    .font(.caption)
                Toggle("Nhiễu AudioContext & Analyser", isOn: $audioProtection)
                    .font(.caption)
                Toggle("Mặt nạ WebGL readPixels", isOn: $webglNoiseProtection)
                    .font(.caption)
                Toggle("Ngoại vi Ảo (Mic, Cam, Loa)", isOn: $mediaDevicesProtection)
                    .font(.caption)
            }

            Section("3. Định danh Android FB4A (Meta API / 2FA)") {
                LabeledContent("Android Device ID", value: androidDeviceId.isEmpty ? "Tự động sinh" : String(androidDeviceId.prefix(16)))
                    .font(.caption.monospaced())
                LabeledContent("Advertising ID (ADID)", value: androidAdid.isEmpty ? "Tự động sinh" : String(androidAdid.prefix(18)) + "...")
                    .font(.caption.monospaced())
                LabeledContent("SIM Serial (ICCID)", value: androidSimSerial.isEmpty ? "Tự động sinh" : androidSimSerial)
                    .font(.caption.monospaced())
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
        fontSeedText = String(fp.fontSeed)
        webglSeedText = String(fp.webglSeed)
        webrtcProtection = fp.webrtcProtectionEnabled
        canvasProtection = fp.canvasNoiseEnabled
        fontProtection = fp.fontNoiseEnabled
        audioProtection = fp.audioNoiseEnabled
        webglNoiseProtection = fp.webGLNoiseEnabled
        mediaDevicesProtection = fp.mediaDevicesProtectionEnabled
        androidDeviceId = fp.androidDeviceId
        androidAdid = fp.androidAdid
        androidSimSerial = fp.androidSimSerial
        timeZone = fp.timeZone
    }

    private func applyPresetValues(_ preset: DeviceModelPreset) {
        let dummy = SpaceFingerprint.makePreset(
            preset: preset,
            canvasSeed: UInt32(canvasSeedText) ?? 12345,
            audioSeed: UInt32(audioSeedText) ?? 67890,
            fontSeed: UInt32(fontSeedText) ?? 13579,
            webglSeed: UInt32(webglSeedText) ?? 24680,
            spaceId: space.id
        )
        loadFingerprint(dummy)
    }

    private func optimizeTo100Percent() {
        let superFp = SpaceFingerprint.generateSuperTrust(spaceId: space.id, preset: selectedPreset)
        loadFingerprint(superFp)
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
        let seedF = UInt32(fontSeedText) ?? UInt32.random(in: 10_000...999_999)
        let seedW = UInt32(webglSeedText) ?? UInt32.random(in: 10_000...999_999)
        let w = Int(screenW) ?? 393
        let h = Int(screenH) ?? 852
        let cores = Int(cpuCores) ?? 6
        let ram = Int(ramGB) ?? 8

        let fp = SpaceFingerprint(
            id: space.fingerprint?.id ?? UUID(),
            preset: selectedPreset,
            userAgent: userAgent.isEmpty ? "Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15" : userAgent,
            appVersion: "5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15",
            platform: selectedPreset.isAndroid ? "Linux armv8l" : (selectedPreset == .macBookProM3 ? "MacIntel" : "iPhone"),
            vendor: selectedPreset.isAndroid ? "Google Inc." : "Apple Computer, Inc.",
            screenWidth: w,
            screenHeight: h,
            screenScale: selectedPreset == .iPadProM4 || selectedPreset == .iPadPro129 || selectedPreset == .macBookProM3 ? 2.0 : 3.0,
            hardwareConcurrency: cores,
            deviceMemory: ram,
            maxTouchPoints: selectedPreset == .macBookProM3 ? 0 : 5,
            webGLVendor: selectedPreset.isAndroid ? "Qualcomm" : "Apple Inc.",
            webGLRenderer: webGLRenderer,
            canvasSeed: seedC,
            audioSeed: seedA,
            fontSeed: seedF,
            webglSeed: seedW,
            androidDeviceId: androidDeviceId.isEmpty ? nil : androidDeviceId,
            androidAdid: androidAdid.isEmpty ? nil : androidAdid,
            androidSimSerial: androidSimSerial.isEmpty ? nil : androidSimSerial,
            timeZone: timeZone,
            canvasNoiseEnabled: canvasProtection,
            audioNoiseEnabled: audioProtection,
            fontNoiseEnabled: fontProtection,
            webGLSpoofingEnabled: true,
            webGLNoiseEnabled: webglNoiseProtection,
            webrtcProtectionEnabled: webrtcProtection,
            mediaDevicesProtectionEnabled: mediaDevicesProtection
        )
        library.updateSpaceFingerprint(space.id, fingerprint: fp)
    }
}
