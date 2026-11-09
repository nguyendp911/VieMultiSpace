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
        case .genZ: return "Gen Z vui tươi, dí dỏm"
        case .corporate: return "Doanh nghiệp chuẩn mực"
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
        case .short: return "Ngắn gọn (1 câu)"
        case .medium: return "Vừa vặn (2-3 câu)"
        case .detailed: return "Đầy đủ chi tiết"
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
        if !policyAndContact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            kb += "- Chính sách & Liên hệ: \(policyAndContact)\n"
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
           let decoded = try? JSONDecoder().decode(AITrainingProfile.self, data: data) {
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

// MARK: - 3. Comprehensive Training & Management UI Sheet

struct AITrainingAndManagementSheet: View {
    @ObservedObject var store = AITrainingStore.shared
    @Binding var geminiApiKey: String
    @Binding var geminiModel: String

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: Int = 0

    // Toast & Alert State
    @State private var showSaveSuccessBanner: Bool = false
    @State private var showResetConfirmAlert: Bool = false

    // New QA Modal State
    @State private var showAddQASheet: Bool = false
    @State private var newQuestionText: String = ""
    @State private var newAnswerText: String = ""

    // Testing Playground State
    @State private var testPostCaption: String = "Chào mừng bạn đến với shop! Mẫu mới vừa về cực hot hôm nay."
    @State private var testCustomerComment: String = "Sản phẩm này còn bảo hành và freeship không shop?"
    @State private var testAuthorName: String = "Nguyễn Văn A"
    @State private var isTestingAI: Bool = false
    @State private var testResultReply: String = ""
    @State private var testResponseLatency: Double = 0.0
    @State private var testErrorMessage: String? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Top Header info bar (API Key & Model Status)
                topModelBar

                // Custom Segmented Picker
                tabSegmentedControl
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color(uiColor: .systemGroupedBackground))

                Divider()

                // Content View for selected tab
                TabView(selection: $selectedTab) {
                    personaTabView
                        .tag(0)

                    knowledgeTabView
                        .tag(1)

                    fewShotQATabView
                        .tag(2)

                    guardrailsTabView
                        .tag(3)

                    playgroundTabView
                        .tag(4)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Huấn luyện & Quản lý AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Đóng") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            showResetConfirmAlert = true
                        } label: {
                            Label("Khôi phục mặc định", systemImage: "arrow.counterclockwise")
                        }

                        Button {
                            saveAll()
                        } label: {
                            Label("Lưu & Áp dụng", systemImage: "checkmark.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 18))
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                bottomActionBar
            }
            .sheet(isPresented: $showAddQASheet) {
                addQAModalSheet
            }
            .alert("Khôi phục mặc định?", isPresented: $showResetConfirmAlert) {
                Button("Hủy", role: .cancel) {}
                Button("Khôi phục", role: .destructive) {
                    store.resetToDefaults()
                }
            } message: {
                Text("Tất cả kiến thức, nhân cách và mẫu huấn luyện sẽ được đưa về dữ liệu chuẩn ban đầu.")
            }
            .overlay(alignment: .top) {
                if showSaveSuccessBanner {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.white)
                        Text("Đã lưu cấu hình huấn luyện AI thành công!")
                            .font(.footnote.bold())
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.trackerPrimaryDark, in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 8)
                }
            }
        }
    }

    // MARK: - Top Model & Key Bar
    private var topModelBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .font(.footnote)
                    .foregroundStyle(geminiApiKey.isEmpty ? Color.orange : Color.trackerPrimaryDark)

                SecureField("Gemini API Key (AIza...)", text: $geminiApiKey)
                    .font(.caption)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Spacer()

                Menu {
                    ForEach(GeminiCommentService.availableModels, id: \.self) { m in
                        Button {
                            geminiModel = m
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
                    HStack(spacing: 4) {
                        Image(systemName: "cpu")
                        Text(geminiModel == "auto" ? "Tự động dò" : geminiModel)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9))
                    }
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.trackerPrimary.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.trackerPrimaryDark)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
        }
    }

    // MARK: - Tab Segmented Control
    private var tabSegmentedControl: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                tabButton(title: "Nhân cách", icon: "theatermasks.fill", index: 0)
                tabButton(title: "Kiến thức", icon: "book.pages.fill", index: 1)
                tabButton(title: "Mẫu Q&A (\(store.profile.trainedQAs.count))", icon: "brain.head.profile", index: 2)
                tabButton(title: "Nguyên tắc", icon: "shield.lefthalf.filled", index: 3)
                tabButton(title: "Thử nghiệm", icon: "flask.fill", index: 4)
            }
            .padding(.vertical, 2)
        }
    }

    private func tabButton(title: String, icon: String, index: Int) -> some View {
        let isSelected = selectedTab == index
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                selectedTab = index
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .bold : .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                isSelected ? Color.trackerPrimaryDark : Color(uiColor: .secondarySystemGroupedBackground),
                in: Capsule()
            )
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .overlay(
                Capsule().stroke(Color.trackerPrimary.opacity(isSelected ? 0 : 0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab 1: Persona & Voice
    private var personaTabView: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Section: Chọn hình mẫu nhân cách
                VStack(alignment: .leading, spacing: 10) {
                    Label("Chọn phong cách nhân cách (Persona)", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.footnote.bold())
                        .foregroundStyle(Color.trackerPrimaryDark)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(AIPersona.allCases) { p in
                            let isChosen = store.profile.persona == p
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    store.profile.persona = p
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Image(systemName: p.icon)
                                            .font(.system(size: 16))
                                            .foregroundStyle(isChosen ? Color.trackerPrimaryDark : .secondary)
                                        Spacer()
                                        if isChosen {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(Color.trackerPrimaryDark)
                                        }
                                    }
                                    Text(p.title)
                                        .font(.subheadline.bold())
                                        .foregroundStyle(isChosen ? Color.trackerPrimaryDark : .primary)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    isChosen ? Color.trackerPrimary.opacity(0.12) : Color(uiColor: .secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 12)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(isChosen ? Color.trackerPrimaryDark : Color.secondary.opacity(0.2), lineWidth: isChosen ? 1.5 : 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Mô tả chi tiết persona
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Mô tả tính cách hiện tại:")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)

                        if store.profile.persona == .custom {
                            TextEditor(text: $store.profile.customPersonaDescription)
                                .frame(height: 90)
                                .padding(8)
                                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                                )
                        } else {
                            Text(store.profile.persona.defaultDescription)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(14)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))

                // Section: Độ dài & Giọng điệu
                VStack(alignment: .leading, spacing: 14) {
                    Label("Độ dài phản hồi mong muốn", systemImage: "text.alignleft")
                        .font(.footnote.bold())
                        .foregroundStyle(Color.trackerPrimaryDark)

                    Picker("Độ dài", selection: $store.profile.replyLength) {
                        ForEach(AIReplyLength.allCases) { len in
                            Text(len.title).tag(len)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(store.profile.replyLength.instruction)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    // Giọng điệu chi tiết
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Giọng điệu & Cảm xúc chi tiết", systemImage: "waveform.path")
                            .font(.footnote.bold())
                            .foregroundStyle(Color.trackerPrimaryDark)

                        TextField("VD: Nhiệt tình, xưng em, dùng icon sinh động...", text: $store.profile.toneVoice, axis: .vertical)
                            .lineLimit(2...3)
                            .padding(10)
                            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                    }

                    // Lời chào mở đầu
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Lời chào mở đầu ưu tiên", systemImage: "hand.wave.fill")
                            .font(.footnote.bold())
                            .foregroundStyle(Color.trackerPrimaryDark)

                        TextField("VD: Dạ em chào anh/chị ạ! ", text: $store.profile.defaultGreeting)
                            .padding(10)
                            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(14)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            }
            .padding(14)
        }
    }

    // MARK: - Tab 2: Knowledge Base
    private var knowledgeTabView: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Tên thương hiệu
                VStack(alignment: .leading, spacing: 8) {
                    Label("Tên thương hiệu / Trang / Cửa hàng", systemImage: "tag.fill")
                        .font(.footnote.bold())
                        .foregroundStyle(Color.trackerPrimaryDark)

                    TextField("VD: ViePN Smart Store", text: $store.profile.brandName)
                        .padding(10)
                        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(14)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))

                // Danh mục sản phẩm & Bảng giá
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Danh mục sản phẩm & Bảng giá", systemImage: "list.bullet.rectangle.portrait.fill")
                            .font(.footnote.bold())
                            .foregroundStyle(Color.trackerPrimaryDark)
                        Spacer()
                        Text("Dữ liệu gốc")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Text("Nhập thông tin sản phẩm, các gói dịch vụ và mức giá để AI tư vấn chính xác, không nói sai giá:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $store.profile.productCatalog)
                        .frame(minHeight: 120)
                        .padding(8)
                        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                        )
                }
                .padding(14)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))

                // Chính sách & Thông tin liên hệ
                VStack(alignment: .leading, spacing: 8) {
                    Label("Chính sách & Kênh liên hệ (Hotline/Zalo/Địa chỉ)", systemImage: "shield.checkerboard")
                        .font(.footnote.bold())
                        .foregroundStyle(Color.trackerPrimaryDark)

                    Text("Chính sách bảo hành, đổi trả, phí ship, hotline Zalo để AI cung cấp cho khách:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $store.profile.policyAndContact)
                        .frame(minHeight: 100)
                        .padding(8)
                        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                        )
                }
                .padding(14)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            }
            .padding(14)
        }
    }

    // MARK: - Tab 3: Few-shot Q&A Training
    private var fewShotQATabView: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mẫu Hỏi - Đáp đã huấn luyện")
                        .font(.subheadline.bold())
                    Text("AI sẽ học sâu từ các cặp mẫu thực tế này để trả lời chuẩn phong cách bạn muốn.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.trackerPrimaryDark, in: Capsule())
                    .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(uiColor: .secondarySystemGroupedBackground))

            Divider()

            if store.profile.trainedQAs.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "bubble.left.and.exclamationmark.bubble.right.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.trackerPrimary.opacity(0.6))
                    Text("Chưa có mẫu huấn luyện nào")
                        .font(.headline)
                    Text("Nhấn 'Thêm mẫu' để dạy AI cách phản hồi những câu hỏi thường gặp của khách hàng.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    Spacer()
                }
            } else {
                List {
                    ForEach($store.profile.trainedQAs) { $item in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top) {
                                Toggle(isOn: $item.isEnabled) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "person.crop.circle.fill")
                                            .font(.caption)
                                            .foregroundStyle(.blue)
                                        Text(item.question)
                                            .font(.subheadline.bold())
                                            .lineLimit(2)
                                    }
                                }
                                .tint(Color.trackerPrimaryDark)
                            }

                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "bubble.right.fill")
                                    .font(.caption)
                                    .foregroundStyle(Color.trackerPrimaryDark)
                                Text(item.answer)
                                    .font(.footnote)
                                    .foregroundStyle(item.isEnabled ? Color.primary : Color.secondary)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        Color(uiColor: .tertiarySystemGroupedBackground),
                                        in: RoundedRectangle(cornerRadius: 8)
                                    )
                            }
                        }
                        .padding(.vertical, 4)
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

    // MARK: - Tab 4: Guardrails
    private var guardrailsTabView: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Từ ngữ cấm kỵ
                VStack(alignment: .leading, spacing: 8) {
                    Label("Từ ngữ cấm kỵ (AI tuyệt đối không được nói)", systemImage: "xmark.octagon.fill")
                        .font(.footnote.bold())
                        .foregroundStyle(.red)

                    Text("Các từ ngữ nhạy cảm, tiêu cực, chê đối thủ, hoặc nói năng bất lịch sự:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("Cách nhau bằng dấu phẩy (,)...", text: $store.profile.bannedWords, axis: .vertical)
                        .lineLimit(2...4)
                        .padding(10)
                        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.2), lineWidth: 1)
                        )
                }
                .padding(14)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))

                // Cụm từ bắt buộc / ưu tiên
                VStack(alignment: .leading, spacing: 8) {
                    Label("Cụm từ ưu tiên nhắc tới (Key Selling Points)", systemImage: "star.fill")
                        .font(.footnote.bold())
                        .foregroundStyle(Color.trackerPrimaryDark)

                    Text("Các từ khóa cam kết như chính hãng, freeship, bảo hành để tăng uy tín:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("VD: chính hãng 100%, freeship toàn quốc, bảo hành 1 đổi 1...", text: $store.profile.requiredPhrases, axis: .vertical)
                        .lineLimit(2...3)
                        .padding(10)
                        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(14)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))

                // Kêu gọi hành động CTA
                VStack(alignment: .leading, spacing: 8) {
                    Label("Lời kêu gọi hành động (Call To Action)", systemImage: "arrowshape.right.fill")
                        .font(.footnote.bold())
                        .foregroundStyle(Color.trackerPrimaryDark)

                    Text("Câu chốt ở cuối phản hồi để chuyển đổi khách bình luận thành khách mua hàng:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("VD: Anh/chị nhắn tin cho shop để nhận ưu đãi ngay nhé!", text: $store.profile.callToAction)
                        .padding(10)
                        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(14)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            }
            .padding(14)
        }
    }

    // MARK: - Tab 5: Interactive Playground
    private var playgroundTabView: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Phòng thử nghiệm phản hồi AI trực tiếp", systemImage: "flask.fill")
                        .font(.subheadline.bold())
                        .foregroundStyle(Color.trackerPrimaryDark)

                    Text("Nhập câu hỏi giả lập của khách hàng để xem AI đã áp dụng đúng kiến thức và nhân cách huấn luyện hay chưa.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // Post Caption
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Nội dung bài viết:")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        TextField("Nhập nội dung bài viết...", text: $testPostCaption, axis: .vertical)
                            .lineLimit(2...3)
                            .padding(8)
                            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                    }

                    // Customer Name & Comment
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Bình luận giả lập của khách:")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Spacer()
                            TextField("Tên khách", text: $testAuthorName)
                                .font(.caption)
                                .frame(width: 120)
                                .textFieldStyle(.roundedBorder)
                        }

                        TextField("Nhập câu hỏi thử nghiệm của khách...", text: $testCustomerComment, axis: .vertical)
                            .lineLimit(2...3)
                            .padding(8)
                            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                    }

                    // Button Chạy thử nghiệm
                    Button {
                        runPlaygroundTest()
                    } label: {
                        HStack(spacing: 6) {
                            if isTestingAI {
                                ProgressView()
                                    .tint(.white)
                                Text("AI đang suy nghĩ...")
                            } else {
                                Image(systemName: "sparkles")
                                Text("Chạy thử nghiệm AI")
                            }
                        }
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(geminiApiKey.isEmpty ? Color.gray : Color.trackerPrimaryDark, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.white)
                    }
                    .disabled(isTestingAI || geminiApiKey.isEmpty || testCustomerComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(14)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))

                // Kết quả phản hồi của AI
                if !testResultReply.isEmpty || testErrorMessage != nil {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Kết quả AI phản hồi", systemImage: "checkmark.message.fill")
                                .font(.subheadline.bold())
                                .foregroundStyle(Color.trackerPrimaryDark)
                            Spacer()
                            if testResponseLatency > 0 {
                                Text(String(format: "%.2fs", testResponseLatency))
                                    .font(.caption2.monospaced())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Color.trackerPrimary.opacity(0.15), in: Capsule())
                                    .foregroundStyle(Color.trackerPrimaryDark)
                            }
                        }

                        if let error = testErrorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                        } else {
                            Text(testResultReply)
                                .font(.callout)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.trackerPrimary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10).stroke(Color.trackerPrimary.opacity(0.3), lineWidth: 1)
                                )

                            HStack(spacing: 10) {
                                Button {
                                    UIPasteboard.general.string = testResultReply
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "doc.on.doc")
                                        Text("Sao chép")
                                    }
                                    .font(.caption.bold())
                                }
                                .buttonStyle(.bordered)

                                Button {
                                    store.addQA(question: testCustomerComment, answer: testResultReply)
                                    withAnimation {
                                        selectedTab = 2
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "plus.circle")
                                        Text("Lưu vào Mẫu Q&A")
                                    }
                                    .font(.caption.bold())
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Color.trackerPrimaryDark)
                            }
                        }
                    }
                    .padding(14)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .padding(14)
        }
    }

    // MARK: - Bottom Action Bar
    private var bottomActionBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Button {
                    saveAll()
                    dismiss()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                        Text("Lưu & Đóng")
                    }
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.trackerPrimaryDark, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
        }
    }

    // MARK: - Modal Add New QA
    private var addQAModalSheet: some View {
        NavigationStack {
            Form {
                Section("Câu hỏi mẫu của khách hàng") {
                    TextField("VD: Sản phẩm có bảo hành không bạn?", text: $newQuestionText, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section("Câu trả lời chuẩn mong muốn (AI sẽ học theo)") {
                    TextField("VD: Dạ bên em bảo hành 12 tháng 1 đổi 1 tận nơi ạ...", text: $newAnswerText, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("Thêm mẫu Hỏi - Đáp")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Hủy") {
                        showAddQASheet = false
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Lưu mẫu") {
                        store.addQA(question: newQuestionText, answer: newAnswerText)
                        showAddQASheet = false
                    }
                    .bold()
                    .disabled(newQuestionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              newAnswerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    // MARK: - Logic Actions
    private func saveAll() {
        SecureGeminiStore.saveKey(geminiApiKey)
        store.saveToDisk()
        withAnimation {
            showSaveSuccessBanner = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation {
                showSaveSuccessBanner = false
            }
        }
    }

    private func runPlaygroundTest() {
        let cleanKey = geminiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else {
            testErrorMessage = "Vui lòng nhập Gemini API Key ở thanh phía trên để chạy thử."
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
