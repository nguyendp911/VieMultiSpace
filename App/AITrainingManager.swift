import SwiftUI

// MARK: - 1. Enums & Models

enum AIPersona: String, CaseIterable, Identifiable, Codable {
    case shopOwner = "shop_owner"
    case consultant = "consultant"
    case customerCare = "customer_care"
    case genZ = "gen_z"
    case corporate = "corporate"
    case custom = "custom"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shopOwner: return "Chủ shop thân thiện"
        case .consultant: return "Chuyên gia tư vấn"
        case .customerCare: return "CSKH chu đáo"
        case .genZ: return "Gen Z vui tươi"
        case .corporate: return "Doanh nghiệp chuẩn"
        case .custom: return "Tùy chỉnh riêng"
        }
    }

    var icon: String {
        switch self {
        case .shopOwner: return "storefront.fill"
        case .consultant: return "person.badge.shield.checkmark.fill"
        case .customerCare: return "headphones.circle.fill"
        case .genZ: return "sparkles"
        case .corporate: return "building.2.fill"
        case .custom: return "slider.horizontal.3"
        }
    }

    var defaultDescription: String {
        switch self {
        case .shopOwner:
            return "Bạn là chủ shop gần gũi, xưng 'shop' hoặc 'em', gọi khách là 'anh/chị' hoặc 'bạn yêu'. Nói chuyện chân thành, nhiệt tình hỗ trợ, luôn mang lại cảm giác được chào đón."
        case .consultant:
            return "Bạn là chuyên gia tư vấn am hiểu sâu sắc về sản phẩm. Giọng điệu chuyên nghiệp, tự tin, phân tích rõ ràng ưu điểm, giúp khách hàng đưa ra quyết định đúng đắn."
        case .customerCare:
            return "Bạn là nhân viên chăm sóc khách hàng lịch sự, chu đáo, kiên nhẫn giải đáp từng thắc mắc, tạo cảm giác an tâm tuyệt đối cho khách hàng."
        case .genZ:
            return "Bạn là một người bạn trẻ trung, năng động, dùng từ ngữ hóm hỉnh, vui vẻ, thường chèn icon cảm xúc tự nhiên, bắt trend mà vẫn lịch sự."
        case .corporate:
            return "Bạn đại diện cho thương hiệu cao cấp. Giọng điệu trang trọng, chuẩn mực, lịch thiệp, câu cú gãy gọn, thể hiện đẳng cấp và uy tín."
        case .custom:
            return "Tùy chỉnh vai trò và tính cách của AI theo ý muốn riêng của bạn."
        }
    }
}

enum AIReplyLength: String, CaseIterable, Identifiable, Codable {
    case short = "short"
    case medium = "medium"
    case detailed = "detailed"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .short: return "Ngắn (1 câu)"
        case .medium: return "Vừa (2-3 câu)"
        case .detailed: return "Chi tiết"
        }
    }

    var instruction: String {
        switch self {
        case .short:
            return "Chỉ trả lời đúng trọng tâm trong 1 câu duy nhất, ngắn gọn, súc tích."
        case .medium:
            return "Trả lời vừa vặn từ 2 đến 3 câu, chào hỏi nhẹ nhàng, trả lời câu hỏi và gợi ý tiếp theo."
        case .detailed:
            return "Trả lời đầy đủ chi tiết, giải thích cụ thể tính năng, giá trị và kèm lời mời hành động rõ ràng."
        }
    }
}

struct AITrainedQA: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var question: String
    var answer: String
    var isEnabled: Bool = true
}

struct AITrainingProfile: Codable, Equatable {
    var persona: AIPersona = .shopOwner
    var customPersonaDescription: String = ""
    var toneVoice: String = "Thân thiện, niềm nở, tư vấn tận tình, dùng 1-2 icon sinh động tự nhiên"
    var replyLength: AIReplyLength = .medium
    var creativityTemperature: Double = 0.7
    var defaultGreeting: String = "Dạ em chào anh/chị ạ! "

    // Business Knowledge Base
    var brandName: String = "ViePN Smart Store"
    var contactPhone: String = "0988.xxx.xxx"
    var productCatalog: String = "Sản phẩm công nghệ & phần mềm tự động hóa cao cấp. Giá cả cạnh tranh, chất lượng chuẩn mực, hỗ trợ kỹ thuật trọn đời."
    var policyAndContact: String = "Hỗ trợ 24/7. Được dùng thử miễn phí, bảo hành lỗi 1 đổi 1. Hotline/Zalo: 0988.xxx.xxx, Website: viepn.vn"

    // Few-Shot Trained Q&As
    var trainedQAs: [AITrainedQA] = [
        AITrainedQA(
            question: "Giá bao nhiêu vậy shop?",
            answer: "Dạ sản phẩm đang có giá ưu đãi cực tốt hôm nay ạ! Em inbox báo giá chi tiết và gửi kèm quà tặng cho mình ngay nhé!",
            isEnabled: true
        ),
        AITrainedQA(
            question: "Có được kiểm tra hàng trước khi nhận không?",
            answer: "Dạ bên em luôn hỗ trợ đồng kiểm thoải mái trước khi nhận hàng ạ. Ưng ý mới thanh toán nên anh/chị yên tâm tuyệt đối nhé!",
            isEnabled: true
        ),
        AITrainedQA(
            question: "Giao hàng mất bao lâu thì tới nơi?",
            answer: "Dạ đơn nội thành nhận ngay trong ngày, các tỉnh thành khác từ 2-3 ngày là nhận được ạ. Shop gửi hàng liền cho mình nhé!",
            isEnabled: true
        )
    ]

    // Guardrails
    var bannedWords: String = "lừa đảo, không biết, giá đắt, bận rồi, mua thì mua không mua thì thôi"
    var requiredPhrases: String = "chính hãng, hỗ trợ tận tâm, ưu đãi hôm nay"
    var callToAction: String = "Anh/chị nhắn tin cho shop để nhận ưu đãi ngay nhé!"

    // MARK: - Prompt Synthesizer
    func buildEffectivePrompt(
        postCaption: String? = nil,
        commentAuthor: String? = nil,
        commentText: String? = nil,
        previousReplies: [String] = []
    ) -> String {
        let activePersonaDesc = (persona == .custom && !customPersonaDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            ? customPersonaDescription
            : persona.defaultDescription

        var sections: [String] = []

        // Section 1: Persona & Style
        sections.append("""
        ### 1. NHÂN CÁCH & VAI TRÒ CỦA BẠN:
        - Tên thương hiệu: \(brandName.isEmpty ? "Cửa hàng" : brandName)
        - Vai trò: \(activePersonaDesc)
        - Giọng điệu & Cảm xúc: \(toneVoice)
        - Độ dài câu trả lời: \(replyLength.instruction)
        - Lời chào / Mở đầu ưu tiên: \(defaultGreeting)
        """)

        // Section 2: Knowledge Base
        var kb = "### 2. DỮ LIỆU & KIẾN THỨC SẢN PHẨM (SỰ THẬT DUY NHẤT, TUYỆT ĐỐI KHÔNG BỊA ĐẶT):\n"
        if !productCatalog.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            kb += "- Sản phẩm & Bảng giá: \(productCatalog)\n"
        }
        if !contactPhone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            kb += "- Hotline / Zalo: \(contactPhone)\n"
        }
        if !policyAndContact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            kb += "- Chính sách & Hỗ trợ: \(policyAndContact)\n"
        }
        sections.append(kb)

        // Section 3: Few-shot Examples
        let activeQAs = trainedQAs.filter { $0.isEnabled && !$0.question.isEmpty && !$0.answer.isEmpty }
        if !activeQAs.isEmpty {
            var qaText = "### 3. CÁC MẪU TRẢ LỜI ĐÃ ĐƯỢC HUẤN LUYỆN (HỌC THEO PHONG CÁCH NÀY):\n"
            for (idx, qa) in activeQAs.enumerated() {
                qaText += "Mẫu \(idx + 1):\n- Khách hỏi: \"\(qa.question)\"\n- Bạn trả lời mẫu: \"\(qa.answer)\"\n\n"
            }
            sections.append(qaText)
        }

        // Section 4: Guardrails
        var guardrails = "### 4. QUY TẮC & NGUYÊN TẮC BẮT BUỘC:\n"
        if !bannedWords.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guardrails += "- TỪ NGỮ TUYỆT ĐỐI CẤM SỬ DỤNG: \(bannedWords)\n"
        }
        if !requiredPhrases.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guardrails += "- Cụm từ ưu tiên khéo léo lồng ghép: \(requiredPhrases)\n"
        }
        if !callToAction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guardrails += "- Kêu gọi hành động nhẹ nhàng (CTA): \(callToAction)\n"
        }
        guardrails += "- Trả lời tự nhiên như người thật đang gõ trên Facebook, không như robot.\n"
        sections.append(guardrails)

        // Section 5: Target Context
        if !previousReplies.isEmpty {
            let list = previousReplies.suffix(8).map { "- \"\($0)\"" }.joined(separator: "\n")
            sections.append("### 5. TRÁNH LẶP LẠI VỚI CÁC CÂU ĐÃ TRẢ LỜI GẦN ĐÂY:\n\(list)")
        }

        if let author = commentAuthor, let cText = commentText, !cText.isEmpty {
            sections.append("""
            ### 6. NHIỆM VỤ CỤ THỂ BÂY GIỜ:
            Bạn đang trả lời bình luận của khách hàng tên là: "\(author)"
            - Nội dung bài viết bạn đã đăng: "\(postCaption ?? "")"
            - Bình luận của "\(author)": "\(cText)"
            Hãy viết câu trả lời hoàn chỉnh, chuẩn xác theo toàn bộ huấn luyện ở trên.
            """)
        } else if let caption = postCaption, !caption.isEmpty {
            sections.append("""
            ### 6. NHIỆM VỤ CỤ THỂ BÂY GIỜ:
            Hãy viết 1 bình luận mồi tương tác tự nhiên, hấp dẫn vào bài viết của bạn có nội dung: "\(caption)"
            """)
        }

        return sections.joined(separator: "\n\n")
    }

    static var defaultProfile: AITrainingProfile {
        AITrainingProfile()
    }
}

// MARK: - 2. Storage Manager

@MainActor
final class AITrainingStore: ObservableObject {
    static let shared = AITrainingStore()
    private let storageKey = "vie.ai_training_profile.v2"

    @Published var profile: AITrainingProfile {
        didSet {
            saveToDisk()
        }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(AITrainingProfile.self, from: data) {
            self.profile = decoded
        } else {
            self.profile = .defaultProfile
        }
    }

    func saveToDisk() {
        if let encoded = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(encoded, forKey: storageKey)
        }
    }

    func resetToDefaults() {
        profile = .defaultProfile
        saveToDisk()
    }

    func addQA(question: String, answer: String) {
        let trimmedQ = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedA = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQ.isEmpty, !trimmedA.isEmpty else { return }
        profile.trainedQAs.insert(AITrainedQA(question: trimmedQ, answer: trimmedA, isEnabled: true), at: 0)
    }

    func removeQA(at offsets: IndexSet) {
        profile.trainedQAs.remove(atOffsets: offsets)
    }

    func deleteQA(id: UUID) {
        profile.trainedQAs.removeAll(where: { $0.id == id })
    }
}

// MARK: - 3. Clean & Modern AI Training View (Reusable & Compact)

struct AITrainingManagementView: View {
    @ObservedObject var store = AITrainingStore.shared
    @Binding var geminiApiKey: String
    @Binding var geminiModel: String
    var isEmbedded: Bool = false
    var onDismiss: (() -> Void)? = nil

    @State private var selectedTab: Int = 0
    @State private var showSaveSuccessBanner: Bool = false
    @State private var showResetConfirmAlert: Bool = false
    @State private var showApiKeyField: Bool = false

    // New QA Modal State
    @State private var showAddQASheet: Bool = false
    @State private var newQuestionText: String = ""
    @State private var newAnswerText: String = ""

    // Testing Playground State
    @State private var testPostCaption: String = "Hàng mới về cực hot hôm nay! Mời mọi người tham khảo nha."
    @State private var testCustomerComment: String = "Shop ơi cho mình hỏi giá và phí ship thế nào?"
    @State private var testAuthorName: String = "Khách hàng"
    @State private var isTestingAI: Bool = false
    @State private var testResultReply: String = ""
    @State private var testResponseLatency: Double = 0.0
    @State private var testErrorMessage: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            // 1. Compact Unified API Key & Model Card
            compactTopControlCard

            // 2. Responsive 5-Tab Segmented Switcher (Không bị tràn/cắt chữ)
            compactSegmentedTabs
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

            Divider()

            // 3. Tab Content
            TabView(selection: $selectedTab) {
                compactPersonaTab.tag(0)
                compactKnowledgeTab.tag(1)
                compactFewShotQATab.tag(2)
                compactGuardrailsTab.tag(3)
                compactPlaygroundTab.tag(4)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .alert("Khôi phục mặc định?", isPresented: $showResetConfirmAlert) {
            Button("Hủy", role: .cancel) {}
            Button("Khôi phục", role: .destructive) {
                store.resetToDefaults()
                notifySaved()
            }
        } message: {
            Text("Toàn bộ nhân cách, kiến thức và mẫu huấn luyện sẽ được trả về mặc định ban đầu.")
        }
        .sheet(isPresented: $showAddQASheet) {
            addQAModalSheet
        }
        .overlay(alignment: .top) {
            if showSaveSuccessBanner {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white)
                    Text("Đã lưu cấu hình AI")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.trackerPrimaryDark, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                .transition(.move(edge: .top).combined(with: .opacity))
                .padding(.top, 6)
            }
        }
    }

    // MARK: - 1. Compact Top Control Card
    private var compactTopControlCard: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                // Key Icon + Input
                Image(systemName: geminiApiKey.isEmpty ? "key.slash.fill" : "key.fill")
                    .font(.footnote)
                    .foregroundStyle(geminiApiKey.isEmpty ? Color.orange : Color.trackerPrimaryDark)

                if showApiKeyField {
                    TextField("Nhập Gemini API Key (AIza...)", text: $geminiApiKey)
                        .font(.caption)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: geminiApiKey) { _ in
                            SecureGeminiStore.saveKey(geminiApiKey)
                        }
                } else {
                    HStack(spacing: 4) {
                        Text(geminiApiKey.isEmpty ? "Chưa cài đặt Gemini API Key" : "Gemini API Key: ••••••••••••")
                            .font(.caption)
                            .foregroundStyle(geminiApiKey.isEmpty ? .secondary : .primary)
                        Spacer()
                    }
                }

                Button {
                    showApiKeyField.toggle()
                } label: {
                    Image(systemName: showApiKeyField ? "eye.slash" : "pencil.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color.trackerPrimaryDark)
                }
                .buttonStyle(.plain)

                // Model Selection Pill
                Menu {
                    ForEach(GeminiCommentService.availableModels, id: \.self) { m in
                        Button {
                            geminiModel = m
                            notifySaved()
                        } label: {
                            HStack {
                                Text(GeminiCommentService.modelLabel(m))
                                if geminiModel == m {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "cpu")
                            .font(.system(size: 10))
                        Text(geminiModel == "auto" ? "Tự dò" : geminiModel.replacingOccurrences(of: "gemini-", with: ""))
                            .font(.system(size: 11, weight: .bold))
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.trackerPrimary.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.trackerPrimaryDark)
                }

                // Reset Menu
                Menu {
                    Button(role: .destructive) {
                        showResetConfirmAlert = true
                    } label: {
                        Label("Khôi phục mẫu mặc định", systemImage: "arrow.counterclockwise")
                    }

                    Button {
                        SecureGeminiStore.saveKey(geminiApiKey)
                        store.saveToDisk()
                        notifySaved()
                    } label: {
                        Label("Lưu cấu hình", systemImage: "checkmark.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }

    // MARK: - 2. Responsive 5-Tab Bar (Fit 100% màn hình, không bị cắt chữ)
    private var compactSegmentedTabs: some View {
        HStack(spacing: 4) {
            tabItemButton(title: "Nhân cách", icon: "theatermasks.fill", index: 0)
            tabItemButton(title: "Dữ liệu", icon: "book.pages.fill", index: 1)
            tabItemButton(title: "Mẫu Q&A", icon: "brain.head.profile", badge: store.profile.trainedQAs.count, index: 2)
            tabItemButton(title: "Quy tắc", icon: "shield.lefthalf.filled", index: 3)
            tabItemButton(title: "Thử test", icon: "flask.fill", index: 4)
        }
    }

    private func tabItemButton(title: String, icon: String, badge: Int? = nil, index: Int) -> some View {
        let isSelected = selectedTab == index
        return Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                selectedTab = index
            }
        } label: {
            VStack(spacing: 2) {
                HStack(spacing: 3) {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                    if let b = badge, b > 0 {
                        Text("\(b)")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(isSelected ? Color.white.opacity(0.3) : Color.trackerPrimaryDark, in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                isSelected ? Color.trackerPrimaryDark : Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.trackerPrimary.opacity(isSelected ? 0 : 0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab 0: Persona & Voice (Gọn gàng & Hiện đại)
    private var compactPersonaTab: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Card 1: Chọn Persona (Dạng grid 3x2 cực kỳ gọn gàng)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Hình mẫu nhân cách", systemImage: "person.crop.circle.badge.checkmark")
                            .font(.caption.bold())
                            .foregroundStyle(Color.trackerPrimaryDark)
                        Spacer()
                        Text("Chạm để chọn")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                        ForEach(AIPersona.allCases) { p in
                            let isChosen = store.profile.persona == p
                            Button {
                                withAnimation(.spring(response: 0.25)) {
                                    store.profile.persona = p
                                }
                            } label: {
                                VStack(spacing: 3) {
                                    Image(systemName: p.icon)
                                        .font(.system(size: 14))
                                        .foregroundStyle(isChosen ? Color.trackerPrimaryDark : .secondary)
                                    Text(p.title)
                                        .font(.system(size: 10, weight: isChosen ? .bold : .regular))
                                        .lineLimit(1)
                                        .foregroundStyle(isChosen ? Color.trackerPrimaryDark : .primary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(
                                    isChosen ? Color.trackerPrimary.opacity(0.15) : Color(uiColor: .tertiarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(isChosen ? Color.trackerPrimaryDark : Color.clear, lineWidth: 1.5)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Mô tả ngắn persona hiện tại
                    if store.profile.persona == .custom {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Nhập mô tả nhân cách theo ý bạn:")
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                            TextEditor(text: $store.profile.customPersonaDescription)
                                .frame(height: 60)
                                .padding(6)
                                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                        }
                    } else {
                        Text(store.profile.persona.defaultDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(12)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))

                // Card 2: Thiết lập Giọng điệu & Độ dài
                VStack(alignment: .leading, spacing: 10) {
                    // Độ dài phản hồi
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Độ dài phản hồi", systemImage: "text.alignleft")
                            .font(.caption.bold())
                            .foregroundStyle(Color.trackerPrimaryDark)

                        Picker("Độ dài", selection: $store.profile.replyLength) {
                            ForEach(AIReplyLength.allCases) { len in
                                Text(len.title).tag(len)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    Divider()

                    // Giọng điệu chi tiết
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Giọng điệu & Cảm xúc", systemImage: "waveform.path")
                            .font(.caption.bold())
                            .foregroundStyle(Color.trackerPrimaryDark)

                        TextField("VD: Nhiệt tình, xưng em, dùng icon nhẹ nhàng...", text: $store.profile.toneVoice)
                            .font(.caption)
                            .padding(8)
                            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                    }

                    // Lời chào mở đầu
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Lời chào mở đầu", systemImage: "hand.wave.fill")
                            .font(.caption.bold())
                            .foregroundStyle(Color.trackerPrimaryDark)

                        TextField("VD: Dạ em chào anh/chị ạ! ", text: $store.profile.defaultGreeting)
                            .font(.caption)
                            .padding(8)
                            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(12)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(10)
        }
    }

    // MARK: - Tab 1: Knowledge Base (Dữ liệu sản phẩm & Doanh nghiệp)
    private var compactKnowledgeTab: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Thương hiệu & Hotline
                VStack(alignment: .leading, spacing: 8) {
                    Label("Thương hiệu & Hotline", systemImage: "storefront.fill")
                        .font(.caption.bold())
                        .foregroundStyle(Color.trackerPrimaryDark)

                    HStack(spacing: 8) {
                        TextField("Tên thương hiệu / Shop", text: $store.profile.brandName)
                            .font(.caption)
                            .padding(8)
                            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))

                        TextField("Hotline / Zalo", text: $store.profile.contactPhone)
                            .font(.caption)
                            .padding(8)
                            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(12)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))

                // Danh mục sản phẩm & Bảng giá
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Danh mục sản phẩm & Bảng giá", systemImage: "list.bullet.rectangle.portrait.fill")
                            .font(.caption.bold())
                            .foregroundStyle(Color.trackerPrimaryDark)
                        Spacer()
                        Text("Dữ liệu gốc")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Text("Nhập thông tin sản phẩm và giá để AI tư vấn chuẩn xác:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $store.profile.productCatalog)
                        .font(.caption)
                        .frame(minHeight: 110)
                        .padding(6)
                        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(12)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))

                // Chính sách & Bảo hành
                VStack(alignment: .leading, spacing: 6) {
                    Label("Chính sách & Bảo hành", systemImage: "shield.checkerboard")
                        .font(.caption.bold())
                        .foregroundStyle(Color.trackerPrimaryDark)

                    TextEditor(text: $store.profile.policyAndContact)
                        .font(.caption)
                        .frame(minHeight: 80)
                        .padding(6)
                        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(12)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(10)
        }
    }

    // MARK: - Tab 2: Few-shot Q&A Training (Mẫu huấn luyện)
    private var compactFewShotQATab: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                Text("Mẫu Hỏi - Đáp (\(store.profile.trainedQAs.count))")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()

                Button {
                    newQuestionText = ""
                    newAnswerText = ""
                    showAddQASheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                        Text("Thêm mẫu")
                    }
                    .font(.caption2.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.trackerPrimaryDark, in: Capsule())
                    .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(uiColor: .secondarySystemGroupedBackground))

            Divider()

            if store.profile.trainedQAs.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 36))
                        .foregroundStyle(Color.trackerPrimary.opacity(0.5))
                    Text("Chưa có mẫu câu huấn luyện")
                        .font(.footnote.bold())
                    Text("Nhấn 'Thêm mẫu' để dạy AI cách phản hồi câu hỏi phổ biến của khách.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                List {
                    ForEach($store.profile.trainedQAs) { $item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .top) {
                                Toggle(isOn: $item.isEnabled) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "person.crop.circle.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.blue)
                                        Text(item.question)
                                            .font(.caption.bold())
                                            .lineLimit(2)
                                    }
                                }
                                .tint(Color.trackerPrimaryDark)
                            }

                            HStack(alignment: .top, spacing: 4) {
                                Image(systemName: "bubble.right.fill")
                                    .font(.caption2)
                                    .foregroundStyle(Color.trackerPrimaryDark)
                                Text(item.answer)
                                    .font(.caption)
                                    .foregroundStyle(item.isEnabled ? Color.primary : Color.secondary)
                                    .padding(6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                        .padding(.vertical, 2)
                        .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.deleteQA(id: item.id)
                            } label: {
                                Label("Xóa", systemImage: "trash")
                            }
                        }
                    }
                    .onDelete(perform: store.removeQA)
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    // MARK: - Tab 3: Guardrails (Quy tắc & Từ cấm)
    private var compactGuardrailsTab: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Từ ngữ cấm kỵ
                VStack(alignment: .leading, spacing: 6) {
                    Label("Từ ngữ cấm kỵ (AI tuyệt đối không được nói)", systemImage: "xmark.octagon.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.red)

                    Text("Các từ ngữ nhạy cảm, tiêu cực, chê đối thủ:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    TextField("Cách nhau bằng dấu phẩy (,)...", text: $store.profile.bannedWords, axis: .vertical)
                        .font(.caption)
                        .lineLimit(2...3)
                        .padding(8)
                        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.2), lineWidth: 1)
                        )
                }
                .padding(12)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))

                // Cụm từ ưu tiên
                VStack(alignment: .leading, spacing: 6) {
                    Label("Cụm từ ưu tiên lồng ghép (Key Points)", systemImage: "star.fill")
                        .font(.caption.bold())
                        .foregroundStyle(Color.trackerPrimaryDark)

                    TextField("VD: chính hãng 100%, freeship toàn quốc, bảo hành 1 đổi 1...", text: $store.profile.requiredPhrases, axis: .vertical)
                        .font(.caption)
                        .lineLimit(2...3)
                        .padding(8)
                        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(12)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))

                // Lời kêu gọi hành động CTA
                VStack(alignment: .leading, spacing: 6) {
                    Label("Kêu gọi hành động (Call To Action)", systemImage: "arrowshape.right.fill")
                        .font(.caption.bold())
                        .foregroundStyle(Color.trackerPrimaryDark)

                    TextField("VD: Anh/chị nhắn tin cho shop để nhận ưu đãi ngay nhé!", text: $store.profile.callToAction)
                        .font(.caption)
                        .padding(8)
                        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(12)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(10)
        }
    }

    // MARK: - Tab 4: Live Playground (Phòng thử nghiệm)
    private var compactPlaygroundTab: some View {
        ScrollView {
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Thử nghiệm phản hồi thực tế", systemImage: "flask.fill")
                            .font(.caption.bold())
                            .foregroundStyle(Color.trackerPrimaryDark)
                        Spacer()
                        Text("Môi trường Test")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    // Bình luận giả lập của khách
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Bình luận của khách:")
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                            Spacer()
                            TextField("Tên khách", text: $testAuthorName)
                                .font(.caption2)
                                .frame(width: 90)
                                .textFieldStyle(.roundedBorder)
                        }

                        TextField("Nhập câu hỏi thử nghiệm của khách...", text: $testCustomerComment)
                            .font(.caption)
                            .padding(8)
                            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                    }

                    // Button Chạy thử nghiệm
                    Button {
                        runPlaygroundTest()
                    } label: {
                        HStack(spacing: 5) {
                            if isTestingAI {
                                ProgressView()
                                    .tint(.white)
                                    .scaleEffect(0.8)
                                Text("Đang phân tích...")
                            } else {
                                Image(systemName: "sparkles")
                                Text("Chạy thử nghiệm AI")
                            }
                        }
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(geminiApiKey.isEmpty ? Color.gray : Color.trackerPrimaryDark, in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.white)
                    }
                    .disabled(isTestingAI || geminiApiKey.isEmpty || testCustomerComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(12)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))

                // Kết quả
                if !testResultReply.isEmpty || testErrorMessage != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("Kết quả AI phản hồi", systemImage: "checkmark.message.fill")
                                .font(.caption.bold())
                                .foregroundStyle(Color.trackerPrimaryDark)
                            Spacer()
                            if testResponseLatency > 0 {
                                Text(String(format: "%.2fs", testResponseLatency))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let error = testErrorMessage {
                            Text(error)
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                        } else {
                            Text(testResultReply)
                                .font(.footnote)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.trackerPrimary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8).stroke(Color.trackerPrimary.opacity(0.25), lineWidth: 1)
                                )

                            HStack(spacing: 8) {
                                Button {
                                    UIPasteboard.general.string = testResultReply
                                } label: {
                                    HStack(spacing: 3) {
                                        Image(systemName: "doc.on.doc")
                                        Text("Sao chép")
                                    }
                                    .font(.caption2.bold())
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Button {
                                    store.addQA(question: testCustomerComment, answer: testResultReply)
                                    notifySaved()
                                    withAnimation { selectedTab = 2 }
                                } label: {
                                    HStack(spacing: 3) {
                                        Image(systemName: "plus.circle")
                                        Text("Lưu vào Mẫu Q&A")
                                    }
                                    .font(.caption2.bold())
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Color.trackerPrimaryDark)
                                .controlSize(.small)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(10)
        }
    }

    // MARK: - Modal Add New QA
    private var addQAModalSheet: some View {
        NavigationStack {
            Form {
                Section("Câu hỏi mẫu của khách hàng") {
                    TextField("VD: Sản phẩm có bảo hành không bạn?", text: $newQuestionText, axis: .vertical)
                        .lineLimit(2...3)
                }

                Section("Câu trả lời chuẩn mong muốn (AI sẽ học theo)") {
                    TextField("VD: Dạ bên em bảo hành 12 tháng 1 đổi 1 tận nơi ạ...", text: $newAnswerText, axis: .vertical)
                        .lineLimit(3...5)
                }
            }
            .navigationTitle("Thêm mẫu Hỏi - Đáp")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Hủy") { showAddQASheet = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Lưu mẫu") {
                        store.addQA(question: newQuestionText, answer: newAnswerText)
                        showAddQASheet = false
                        notifySaved()
                    }
                    .bold()
                    .disabled(newQuestionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              newAnswerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    // MARK: - Actions
    private func notifySaved() {
        withAnimation { showSaveSuccessBanner = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation { showSaveSuccessBanner = false }
        }
    }

    private func runPlaygroundTest() {
        let cleanKey = geminiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else {
            testErrorMessage = "Vui lòng nhập Gemini API Key ở ô phía trên."
            return
        }

        isTestingAI = true
        testErrorMessage = nil
        testResultReply = ""
        let startTime = CFAbsoluteTimeGetCurrent()

        Task {
            do {
                let synthesizedPrompt = store.profile.buildEffectivePrompt(
                    postCaption: testPostCaption,
                    commentAuthor: testAuthorName.isEmpty ? "Khách hàng" : testAuthorName,
                    commentText: testCustomerComment,
                    previousReplies: []
                )

                let postItem = FeedPostItem(
                    postId: "test_playground",
                    userName: testAuthorName.isEmpty ? "Khách hàng" : testAuthorName,
                    userId: "",
                    postText: synthesizedPrompt
                )

                let result = try await GeminiCommentService.analyzeAndGenerateComment(
                    post: postItem,
                    apiKey: cleanKey,
                    model: geminiModel,
                    customStylePrompt: synthesizedPrompt
                )

                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                await MainActor.run {
                    self.testResponseLatency = elapsed
                    self.testResultReply = result.comment
                    self.isTestingAI = false
                }
            } catch {
                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                await MainActor.run {
                    self.testResponseLatency = elapsed
                    self.testErrorMessage = "Lỗi khi gọi AI: \(error.localizedDescription)"
                    self.isTestingAI = false
                }
            }
        }
    }
}

// MARK: - 4. Modal Sheet Wrapper
struct AITrainingAndManagementSheet: View {
    @Binding var geminiApiKey: String
    @Binding var geminiModel: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AITrainingManagementView(
                geminiApiKey: $geminiApiKey,
                geminiModel: $geminiModel,
                isEmbedded: false,
                onDismiss: { dismiss() }
            )
            .navigationTitle("Huấn luyện & Quản lý AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Đóng") { dismiss() }
                }
            }
        }
    }
}
