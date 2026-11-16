import SwiftUI

// MARK: - Màn hình chính: AI đăng bài tự động theo khung giờ vàng

struct AIAutoPostView: View {
    @EnvironmentObject private var library: SpaceLibrary
    @StateObject private var engine = AIAutoPostEngine.shared
    @StateObject private var scheduler = ScheduledPostManager.shared

    @State private var editing: AIAutoPlan?
    @State private var apiKey = SecureGeminiStore.readKey()
    @State private var keySaved = false
    @State private var runningPlanId: UUID?

    private var facebookSpaces: [Space] { library.spaces.filter { $0.platform == .facebook } }

    private var aiTasks: [ScheduledPostTask] {
        scheduler.tasks.filter { $0.aiPlanId != nil }.sorted { $0.scheduledDate > $1.scheduledDate }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                infoCard
                keyCard
                plansSection
                upcomingSection
                logSection
            }
            .padding(12)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("AI đăng bài tự động")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editing = AIAutoPlan()
                } label: { Image(systemName: "plus.circle.fill") }
            }
        }
        .sheet(item: $editing) { plan in
            AIPlanEditorSheet(plan: plan, spaces: facebookSpaces) { saved in
                engine.upsert(saved)
            }
        }
        .task { await engine.tick(spaces: library.spaces) }
    }

    // MARK: Giới thiệu + lưu ý

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Tới khung giờ vàng, AI tự tạo chủ đề, nội dung và ảnh rồi đăng", systemImage: "sparkles")
                .font(.subheadline.bold())
            Text("• Fanpage: bài được hẹn giờ ngay trên Facebook nên vẫn đăng đúng giờ khi bạn tắt app.\n• Trang cá nhân và Nhóm: app đăng khi đến giờ, nên cần mở app (hoặc iOS cho chạy nền). Bài quá hạn sẽ bị bỏ qua để không đăng sai giờ.\n• Mặc định có dòng \"Ảnh minh họa do AI tạo\" dưới ảnh AI; bạn có thể tắt trong kế hoạch.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var keyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Gemini API Key", systemImage: "key.fill").font(.caption.bold())
                Spacer()
                Text(apiKey.isEmpty ? "Chưa có" : "Đã lưu")
                    .font(.caption.bold())
                    .foregroundStyle(apiKey.isEmpty ? Color.red : Color.trackerPrimaryDark)
            }
            HStack {
                SecureField("Dán Gemini API Key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(8)
                    .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                Button("Lưu") {
                    SecureGeminiStore.saveKey(apiKey)
                    keySaved = true
                }
                .buttonStyle(SoftTintedButtonStyle(tint: .trackerPrimaryDark, isCompact: true))
            }
            if keySaved {
                Text("Đã lưu vào Keychain.").font(.caption2).foregroundStyle(.secondary)
            }
            Text("Tạo ảnh bằng AI cần key có quyền dùng model ảnh của Gemini. Nếu key không hỗ trợ, bài sẽ đăng không kèm ảnh (hoặc bỏ qua, tùy cài đặt kế hoạch).")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Danh sách kế hoạch

    private var plansSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Kế hoạch").font(.caption.bold()).foregroundStyle(.secondary)
            if engine.plans.isEmpty {
                VStack(spacing: 6) {
                    Text("Chưa có kế hoạch nào").font(.subheadline.bold())
                    Text("Bấm dấu + để tạo kế hoạch đầu tiên: chọn nơi đăng, lĩnh vực và khung giờ vàng.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(20)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            }
            ForEach(engine.plans) { plan in planCard(plan) }
        }
    }

    private func planCard(_ plan: AIAutoPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(plan.name).font(.subheadline.bold())
                Spacer()
                Toggle("", isOn: Binding(
                    get: { plan.isEnabled },
                    set: { v in
                        var p = plan
                        p.isEnabled = v
                        engine.upsert(p)
                        if v { Task { await engine.fill(planId: p.id, spaces: library.spaces) } }
                    }
                ))
                .labelsHidden()
            }
            summaryLine("person.3.fill", targetSummary(plan))
            summaryLine("clock.fill", plan.slots.map { $0.label }.joined(separator: " · ") + " (±\(plan.jitterMinutes)′)")
            summaryLine("text.bubble.fill", plan.niche.isEmpty ? "AI tự chọn chủ đề" : plan.niche)
            summaryLine("photo.fill", plan.imageMode.rawValue + (plan.requireApproval ? " · Cần duyệt" : " · Tự đăng"))

            HStack(spacing: 8) {
                Button {
                    runningPlanId = plan.id
                    Task {
                        let horizon = (plan.daysAhead + 1) * 24
                        await engine.fill(planId: plan.id, spaces: library.spaces, horizonHours: horizon)
                        runningPlanId = nil
                    }
                } label: {
                    HStack(spacing: 4) {
                        if runningPlanId == plan.id { ProgressView().controlSize(.mini) } else { Image(systemName: "wand.and.stars") }
                        Text("Tạo lịch ngay")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(GradientPillButtonStyle(colors: [.trackerPrimary, .trackerPrimaryDark], isCompact: true))
                .disabled(runningPlanId != nil)

                Button { editing = plan } label: { Text("Sửa").frame(maxWidth: .infinity) }
                    .buttonStyle(SoftTintedButtonStyle(tint: .trackerPrimaryDark, isCompact: true))

                Button(role: .destructive) { engine.delete(plan) } label: { Image(systemName: "trash") }
                    .buttonStyle(SoftTintedButtonStyle(tint: .red, isCompact: true))
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .opacity(plan.isEnabled ? 1 : 0.65)
    }

    private func summaryLine(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(Color.trackerPrimaryDark).frame(width: 14)
            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    private func targetSummary(_ plan: AIAutoPlan) -> String {
        let profile = plan.targets.filter { $0.kind == .personalProfile }.count
        let groups = plan.targets.filter { $0.kind == .group }.count
        let pages = plan.targets.filter { $0.kind == .fanpage }.count
        var parts: [String] = []
        if profile > 0 { parts.append("\(profile) trang cá nhân") }
        if groups > 0 { parts.append("\(groups) nhóm") }
        if pages > 0 { parts.append("\(pages) page") }
        return parts.isEmpty ? "Chưa chọn nơi đăng" : parts.joined(separator: " · ")
    }

    // MARK: Bài sắp đăng / đã đăng

    private var upcomingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !aiTasks.isEmpty {
                Text("Bài do AI tạo").font(.caption.bold()).foregroundStyle(.secondary)
            }
            ForEach(aiTasks.prefix(30)) { task in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(task.status.rawValue).font(.caption.bold())
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(task.status.badgeColor.opacity(0.18), in: Capsule())
                            .foregroundStyle(task.status.badgeColor)
                        Spacer()
                        Text(task.scheduledDate.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(task.caption).font(.caption).lineLimit(3)
                    if let log = task.executionLog, task.status != .pending, task.status != .draft {
                        Text(log).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                    }
                    HStack {
                        if task.status == .draft {
                            Button { engine.approve(taskId: task.id) } label: { Label("Duyệt đăng", systemImage: "checkmark.circle.fill") }
                                .buttonStyle(GradientPillButtonStyle(colors: [.trackerPrimary, .trackerPrimaryDark], isCompact: true))
                        }
                        Spacer()
                        Button(role: .destructive) { scheduler.deleteTask(task) } label: { Image(systemName: "trash") }
                            .buttonStyle(SoftTintedButtonStyle(tint: .red, isCompact: true))
                    }
                }
                .padding(12)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !engine.logLines.isEmpty {
                Text("Nhật ký").font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(Array(engine.logLines.prefix(12).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Bản xem thử

private struct AIPreviewItem: Identifiable {
    let id = UUID()
    let topic: String
    let caption: String
    let image: UIImage?
}

// MARK: - Sheet chỉnh kế hoạch

struct AIPlanEditorSheet: View {
    let spaces: [Space]
    var onSave: (AIAutoPlan) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var plan: AIAutoPlan
    @State private var topicsText: String
    @State private var profileSpaceIds: Set<UUID>
    @State private var groups: [FacebookDestinationItem]
    @State private var pages: [FacebookDestinationItem]
    @State private var selectedKeys: Set<String>
    @State private var pickerKind: SmartPostDestinationType?
    @State private var isLoadingDest = false
    @State private var isPreviewing = false
    @State private var preview: AIPreviewItem?
    @State private var message: String?
    @State private var suggestionNote: String?

    init(plan: AIAutoPlan, spaces: [Space], onSave: @escaping (AIAutoPlan) -> Void) {
        self.spaces = spaces
        self.onSave = onSave
        _plan = State(initialValue: plan)
        _topicsText = State(initialValue: plan.topics.joined(separator: "\n"))
        _profileSpaceIds = State(initialValue: Set(plan.targets.filter { $0.kind == .personalProfile }.map { $0.spaceId }))
        let g = plan.targets.filter { $0.kind == .group }.compactMap { $0.destination }
        let p = plan.targets.filter { $0.kind == .fanpage }.compactMap { $0.destination }
        _groups = State(initialValue: g)
        _pages = State(initialValue: p)
        _selectedKeys = State(initialValue: Set((g + p).map { $0.uniqueSelectionKey }))
    }

    var body: some View {
        NavigationStack {
            Form {
                nameSection
                targetsSection
                contentSection
                imageSection
                slotsSection
                safetySection
                previewSection
                if let message {
                    Section { Text(message).font(.caption).foregroundStyle(.orange) }
                }
            }
            .navigationTitle("Kế hoạch AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Đóng") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Lưu") { save() } }
            }
            .sheet(item: $pickerKind) { kind in
                DestinationPickerSheet(
                    kind: kind,
                    destinations: kind == .group ? groups : pages,
                    selectedKeys: $selectedKeys
                )
            }
            .sheet(item: $preview) { item in
                AIPreviewSheet(item: item)
            }
        }
    }

    // MARK: Các phần của form

    private var nameSection: some View {
        Section("Tên kế hoạch") {
            TextField("Ví dụ: Page bán hàng – bài buổi tối", text: $plan.name)
        }
    }

    private var targetsSection: some View {
        Section {
            ForEach(spaces) { sp in
                Toggle(isOn: Binding(
                    get: { profileSpaceIds.contains(sp.id) },
                    set: { on in if on { profileSpaceIds.insert(sp.id) } else { profileSpaceIds.remove(sp.id) } }
                )) {
                    Label("Trang cá nhân: \(sp.name)", systemImage: "person.crop.circle.fill")
                }
            }
            destinationRow(kind: .group, title: "Nhóm", items: groups)
            destinationRow(kind: .fanpage, title: "Fanpage", items: pages)
        } header: {
            Text("Nơi đăng")
        } footer: {
            Text("Mỗi loại nơi đăng được AI viết một bản nội dung riêng, giọng văn phù hợp (cá nhân, nhóm, thương hiệu).")
        }
    }

    private func destinationRow(kind: SmartPostDestinationType, title: String, items: [FacebookDestinationItem]) -> some View {
        let selected = items.filter { selectedKeys.contains($0.uniqueSelectionKey) }.count
        return HStack {
            Label("\(title): \(selected)/\(items.count) đã chọn", systemImage: kind.icon)
            Spacer()
            Button {
                Task { await loadDestinations(kind: kind) }
            } label: {
                if isLoadingDest { ProgressView().controlSize(.mini) } else { Text(items.isEmpty ? "Tải danh sách" : "Chọn / tải lại") }
            }
            .font(.caption)
            .buttonStyle(.borderless)
            .disabled(isLoadingDest)
            if !items.isEmpty {
                Button("Sửa") { pickerKind = kind }.font(.caption).buttonStyle(.borderless)
            }
        }
    }

    private var contentSection: some View {
        Section("Nội dung & chủ đề") {
            TextField("Lĩnh vực / ngành (ví dụ: mẹo bán hàng online)", text: $plan.niche)
            Picker("Chủ đề", selection: $plan.topicMode) {
                ForEach(AITopicMode.allCases) { Text($0.rawValue).tag($0) }
            }
            if plan.topicMode == .userList {
                TextEditor(text: $topicsText)
                    .frame(minHeight: 90)
                    .font(.callout)
                Text("Mỗi dòng một chủ đề, AI lần lượt viết theo từng chủ đề.").font(.caption2).foregroundStyle(.secondary)
            }
            TextField("Phong cách bổ sung (ví dụ: hài hước, kể chuyện)", text: $plan.styleNotes)
            Toggle("Dùng hồ sơ thương hiệu đã huấn luyện AI", isOn: $plan.useBrandProfile)
            Picker("Độ dài", selection: $plan.length) {
                ForEach(AIPostLength.allCases) { Text($0.rawValue).tag($0) }
            }
            Stepper("Hashtag: \(plan.hashtagCount)", value: $plan.hashtagCount, in: 0...8)
            Toggle("Dùng emoji", isOn: $plan.includeEmoji)
            Toggle("Thêm câu kêu gọi hành động", isOn: $plan.includeCTA)
        }
    }

    private var imageSection: some View {
        Section("Ảnh") {
            Picker("Ảnh", selection: $plan.imageMode) {
                ForEach(AIImageMode.allCases) { Text($0.rawValue).tag($0) }
            }
            if plan.imageMode == .ai {
                TextField("Phong cách ảnh", text: $plan.imageStyle, axis: .vertical)
                Toggle("Không tạo được ảnh thì vẫn đăng bài chữ", isOn: $plan.textOnlyIfImageFails)
                Toggle("Ghi chú \"Ảnh minh họa do AI tạo\"", isOn: $plan.appendAIDisclosure)
            }
        }
    }

    private var slotsSection: some View {
        Section {
            ForEach($plan.slots) { $slot in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        DatePicker("", selection: timeBinding($slot), displayedComponents: .hourAndMinute).labelsHidden()
                        Spacer()
                        Button(role: .destructive) {
                            plan.slots.removeAll { $0.id == slot.id }
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                    weekdayChips($slot)
                }
            }
            Button {
                plan.slots.append(AIPostSlot(hour: 20, minute: 0))
            } label: { Label("Thêm khung giờ", systemImage: "plus.circle") }
            Button {
                let r = AIAutoPostEngine.shared.suggestGoldenSlots()
                plan.slots = r.slots
                suggestionNote = r.basedOnData
                    ? "Đã gợi ý theo giờ bài của bạn có tương tác cao nhất."
                    : "Chưa đủ dữ liệu bài theo dõi (cần ít nhất 8 bài có tương tác), đã dùng khung giờ phổ biến."
            } label: { Label("Gợi ý khung giờ vàng từ dữ liệu của tôi", systemImage: "wand.and.stars") }
            if let n = suggestionNote { Text(n).font(.caption2).foregroundStyle(.secondary) }
            Stepper("Lệch ngẫu nhiên ±\(plan.jitterMinutes) phút", value: $plan.jitterMinutes, in: 0...30, step: 5)
        } header: {
            Text("Khung giờ vàng")
        } footer: {
            Text("Mỗi khung giờ AI tạo bài mới và đăng vào đúng giờ đó, lệch ngẫu nhiên vài phút cho tự nhiên.")
        }
    }

    private var safetySection: some View {
        Section {
            Stepper("Lên lịch trước \(plan.daysAhead) ngày", value: $plan.daysAhead, in: 1...7)
            Stepper("Tạo bài trước giờ đăng tối đa \(plan.leadHours) giờ", value: $plan.leadHours, in: 1...48)
            Stepper("Tối đa \(plan.maxPostsPerDayPerKind) bài/ngày mỗi loại nơi đăng", value: $plan.maxPostsPerDayPerKind, in: 1...6)
            Stepper("Cách nhau ít nhất \(plan.minGapHours) giờ", value: $plan.minGapHours, in: 1...12)
            Stepper("Bỏ qua nếu trễ quá \(plan.lateToleranceMinutes) phút", value: $plan.lateToleranceMinutes, in: 0...180, step: 15)
            Toggle("Cần tôi duyệt trước khi đăng", isOn: $plan.requireApproval)
            Toggle("Fanpage: hẹn giờ gốc trên Facebook", isOn: $plan.useNativePageSchedule)
            Picker("Quyền riêng tư", selection: $plan.privacy) {
                ForEach(SmartPostPrivacy.allCases) { Text($0.shortName).tag($0) }
            }
        } header: {
            Text("Lịch & an toàn")
        } footer: {
            Text("Đăng quá dày vào nhóm dễ bị quản trị viên xóa bài hoặc Facebook hạn chế. Nên để 1 đến 2 bài/ngày. \"Bỏ qua nếu trễ\" = 0 nghĩa là luôn đăng bù dù trễ.")
        }
    }

    private var previewSection: some View {
        Section("Thử") {
            Button {
                Task { await runPreview() }
            } label: {
                HStack {
                    if isPreviewing { ProgressView() }
                    Text("Xem thử một bài AI (không đăng)")
                }
            }
            .disabled(isPreviewing)
        }
    }

    // MARK: Hành động

    private func weekdayChips(_ slot: Binding<AIPostSlot>) -> some View {
        let names = [(2, "T2"), (3, "T3"), (4, "T4"), (5, "T5"), (6, "T6"), (7, "T7"), (1, "CN")]
        return HStack(spacing: 4) {
            ForEach(names, id: \.0) { day, label in
                let on = slot.wrappedValue.weekdays.contains(day)
                Button {
                    if on { slot.wrappedValue.weekdays.remove(day) } else { slot.wrappedValue.weekdays.insert(day) }
                } label: {
                    Text(label).font(.caption2.bold())
                        .frame(width: 30, height: 24)
                        .foregroundStyle(on ? Color.white : Color.trackerPrimaryDark)
                        .background(on ? Color.trackerPrimaryDark : Color.trackerSoft, in: Capsule())
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func timeBinding(_ slot: Binding<AIPostSlot>) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: slot.wrappedValue.hour, minute: slot.wrappedValue.minute, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                slot.wrappedValue.hour = c.hour ?? 0
                slot.wrappedValue.minute = c.minute ?? 0
            }
        )
    }

    private func loadDestinations(kind: SmartPostDestinationType) async {
        guard !spaces.isEmpty else { return }
        isLoadingDest = true
        defer { isLoadingDest = false }
        var loaded: [FacebookDestinationItem] = []
        for space in spaces {
            let creds = await TrackedPostManager.resolveCookieAndToken(for: space)
            if kind == .fanpage {
                guard !creds.token.isEmpty else { continue }
                loaded += await SmartPostAPIClient.fetchManagedPages(accessToken: creds.token, spaceId: space.id, spaceName: space.name)
            } else if kind == .group {
                loaded += await SmartPostAPIClient.fetchJoinedGroups(
                    accessToken: creds.token, cookieString: creds.cookie, userId: creds.uid,
                    spaceId: space.id, spaceName: space.name
                )
            }
        }
        var current = kind == .group ? groups : pages
        for item in loaded where !current.contains(where: { $0.uniqueSelectionKey == item.uniqueSelectionKey }) {
            current.append(item)
        }
        if kind == .group { groups = current } else { pages = current }
        if loaded.isEmpty {
            message = "Không tải được danh sách \(kind == .group ? "nhóm" : "page"). Kiểm tra token của tài khoản."
        } else {
            message = nil
            pickerKind = kind
        }
    }

    private func buildTargets() -> [AIPlanTarget] {
        var result: [AIPlanTarget] = []
        for sp in spaces where profileSpaceIds.contains(sp.id) {
            result.append(AIPlanTarget(spaceId: sp.id, spaceName: sp.name, kind: .personalProfile, destination: nil))
        }
        for d in groups + pages where selectedKeys.contains(d.uniqueSelectionKey) {
            let owner = d.ownerSpaceId ?? spaces.first?.id
            guard let owner else { continue }
            result.append(AIPlanTarget(spaceId: owner, spaceName: d.ownerSpaceName, kind: d.kind, destination: d))
        }
        return result
    }

    private func save() {
        var p = plan
        p.name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.name.isEmpty { p.name = "Kế hoạch AI" }
        p.topics = topicsText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        p.targets = buildTargets()
        if p.targets.isEmpty { message = "Hãy chọn ít nhất một nơi đăng."; return }
        if p.slots.isEmpty { message = "Hãy thêm ít nhất một khung giờ."; return }
        if p.topicMode == .userList && p.topics.isEmpty { message = "Hãy nhập ít nhất một chủ đề, hoặc chọn \"AI tự nghĩ chủ đề\"."; return }
        onSave(p)
        dismiss()
    }

    private func runPreview() async {
        isPreviewing = true
        defer { isPreviewing = false }
        var p = plan
        p.topics = topicsText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let kind: SmartPostDestinationType = !groups.filter({ selectedKeys.contains($0.uniqueSelectionKey) }).isEmpty && profileSpaceIds.isEmpty && pages.isEmpty
            ? .group : (profileSpaceIds.isEmpty && !pages.filter({ selectedKeys.contains($0.uniqueSelectionKey) }).isEmpty ? .fanpage : .personalProfile)
        do {
            let g = try await AIAutoPostEngine.shared.generatePost(plan: p, kind: kind, fire: Date().addingTimeInterval(3600))
            preview = AIPreviewItem(topic: g.topic, caption: AIAutoPostEngine.shared.finalCaption(g, plan: p), image: g.image)
            message = nil
        } catch {
            message = "Xem thử lỗi: \(error.localizedDescription)"
        }
    }
}

private struct AIPreviewSheet: View {
    let item: AIPreviewItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !item.topic.isEmpty {
                        Text("Chủ đề: \(item.topic)").font(.caption.bold()).foregroundStyle(.secondary)
                    }
                    if let img = item.image {
                        Image(uiImage: img).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        Text("(Không có ảnh)").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(item.caption).font(.body).textSelection(.enabled)
                }
                .padding(16)
            }
            .navigationTitle("Bài AI xem thử")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Xong") { dismiss() } } }
        }
    }
}
