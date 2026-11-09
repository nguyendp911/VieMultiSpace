import SwiftUI
import UIKit
import Photos

// MARK: - 1. Showcase Item Model

struct ShowcaseScreenItem: Identifiable, Equatable {
    let id = UUID()
    let featureKey: String
    let title: String
    let subtitle: String
    let icon: String
    var image: UIImage? = nil
    var isSelected: Bool = true

    static func == (lhs: ShowcaseScreenItem, rhs: ShowcaseScreenItem) -> Bool {
        lhs.id == rhs.id && lhs.image == rhs.image && lhs.isSelected == rhs.isSelected
    }
}

// MARK: - 2. Studio Store & Snapshot Engine

@MainActor
final class ShowcaseStudioManager: ObservableObject {
    static let shared = ShowcaseStudioManager()

    @Published var items: [ShowcaseScreenItem] = []
    @Published var isGeneratingAll: Bool = false
    @Published var generationProgress: Double = 0.0
    @Published var generationStatusText: String = ""

    // Options
    @Published var renderStyle: ShowcaseRenderStyle = .marketingPoster // .marketingPoster hoặc .rawScreenshot
    @Published var isFloatingButtonEnabled: Bool = false
    @Published var capturedLiveScreenshots: [UIImage] = []

    enum ShowcaseRenderStyle: String, CaseIterable, Identifiable {
        case marketingPoster = "poster"
        case rawScreenshot = "raw"

        var id: String { rawValue }
        var title: String {
            switch self {
            case .marketingPoster: return "Poster Giới thiệu (Mockup)"
            case .rawScreenshot: return "Ảnh chụp gốc (1:1)"
            }
        }
        var icon: String {
            switch self {
            case .marketingPoster: return "iphone"
            case .rawScreenshot: return "rectangle.ratio.9.to.16"
            }
        }
    }

    init() {
        setupDefaultItems()
    }

    func setupDefaultItems() {
        items = [
            ShowcaseScreenItem(
                featureKey: "home_multispace",
                title: "1. Đa Không Gian & Bảo Mật",
                subtitle: "Tách biệt Cookie, Token, Proxy & Fingerprint riêng từng tài khoản",
                icon: "square.grid.2x2.fill"
            ),
            ShowcaseScreenItem(
                featureKey: "smart_post_compose",
                title: "2. Đăng Bài Đa Tài Khoản",
                subtitle: "Soạn thảo bài đăng, hẹn giờ, bình luận mồi & thả reaction tự động",
                icon: "square.and.pencil"
            ),
            ShowcaseScreenItem(
                featureKey: "smart_post_schedule",
                title: "3. Quản Lý Lịch Đăng",
                subtitle: "Lên lịch tự động đăng bài theo mốc thời gian, quản lý hàng đợi",
                icon: "calendar.badge.clock"
            ),
            ShowcaseScreenItem(
                featureKey: "smart_post_tracker",
                title: "4. Theo Dõi & Chỉ Số",
                subtitle: "Thống kê tương tác thời gian thực, nhắc nhở bình luận cần trả lời",
                icon: "chart.bar.doc.horizontal.fill"
            ),
            ShowcaseScreenItem(
                featureKey: "smart_post_ai",
                title: "5. Huấn Luyện AI Bán Hàng",
                subtitle: "Tùy biến nhân cách, kho kiến thức sản phẩm, Q&A & Guardrails",
                icon: "brain.head.profile"
            ),
            ShowcaseScreenItem(
                featureKey: "auto_feeds",
                title: "6. Tương Tác Newfeeds AI",
                subtitle: "Tự động lướt bài, thả reaction & comment AI tự nhiên như người thật",
                icon: "sparkles"
            ),
            ShowcaseScreenItem(
                featureKey: "account_center",
                title: "7. Kho Token & Cookie",
                subtitle: "Quản lý Profile, kiểm tra Token Live/Die, bảo mật tài khoản",
                icon: "person.2.crop.square.stack"
            ),
            ShowcaseScreenItem(
                featureKey: "multispace_sync",
                title: "8. Đồng Bộ MultiSpace Sync",
                subtitle: "Đồng bộ chéo tương tác an toàn giữa các không gian tài khoản",
                icon: "square.stack.3d.up.fill"
            )
        ]
    }

    // MARK: - Capture Current Key Window
    func captureCurrentWindow() -> UIImage? {
        guard let windowScene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let window = windowScene.windows.first(where: { $0.isKeyWindow }) else {
            return nil
        }
        let bounds = window.bounds
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
        let image = renderer.image { _ in
            window.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        capturedLiveScreenshots.append(image)
        return image
    }

    // MARK: - Generate All Showcase Screens
    func generateAllShowcases() async {
        isGeneratingAll = true
        generationProgress = 0.0

        for index in 0..<items.count {
            let item = items[index]
            generationStatusText = "Đang kết xuất: \(item.title)..."

            // Render view into UIImage
            let renderedImage = await renderShowcaseView(for: item, style: renderStyle)
            items[index].image = renderedImage

            generationProgress = Double(index + 1) / Double(items.count)
            // Small pause for smooth UI
            try? await Task.sleep(nanoseconds: 120_000_000)
        }

        generationStatusText = "Hoàn tất tạo \(items.count) ảnh giới thiệu!"
        try? await Task.sleep(nanoseconds: 300_000_000)
        isGeneratingAll = false
    }

    // MARK: - Render individual screen
    private func renderShowcaseView(for item: ShowcaseScreenItem, style: ShowcaseRenderStyle) async -> UIImage? {
        let size = CGSize(width: 393, height: 852) // Chuẩn màn hình iPhone 15/16 Pro

        let targetView = AnyView(
            ShowcaseScreenRenderer(item: item, style: style)
                .frame(width: size.width, height: size.height)
        )

        let renderer = ImageRenderer(content: targetView)
        renderer.scale = 2.5 // Độ phân giải siêu nét (Retina High-Definition)
        renderer.proposedSize = ProposedViewSize(size)

        return renderer.uiImage
    }

    // MARK: - Save all generated images to Photos Album
    func saveAllToPhotos(completion: @escaping (Int, Int) -> Void) {
        let availableImages = items.compactMap { $0.image } + capturedLiveScreenshots
        guard !availableImages.isEmpty else {
            completion(0, 0)
            return
        }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            DispatchQueue.main.async {
                guard status == .authorized || status == .limited else {
                    completion(0, availableImages.count)
                    return
                }

                var savedCount = 0
                for img in availableImages {
                    UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
                    savedCount += 1
                }
                completion(savedCount, availableImages.count)
            }
        }
    }
}

// MARK: - 3. Visual Mock Screen Renderers (Thiết kế đồ họa chuyên nghiệp cho từng màn hình)

struct ShowcaseScreenRenderer: View {
    let item: ShowcaseScreenItem
    let style: ShowcaseStudioManager.ShowcaseRenderStyle

    var body: some View {
        if style == .marketingPoster {
            marketingPosterLayout
        } else {
            rawScreenLayout
        }
    }

    // MARK: Poster phong cách Marketing đẳng cấp
    private var marketingPosterLayout: some View {
        ZStack {
            // Background Gradient sang trọng
            LinearGradient(
                colors: [Color(hex: "1F2937"), Color(hex: "111827"), Color(hex: "030712")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            // Header Banner giới thiệu tính năng
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: item.icon)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.themePrimary)
                    Text("ViePN Smart+ • Giải Pháp Facebook")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.themePrimary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color.themePrimary.opacity(0.18), in: Capsule())

                Text(item.title)
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text(item.subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .lineLimit(2)

                // Khung viền Mockup iPhone
                VStack(spacing: 0) {
                    // Dynamic Island
                    Capsule()
                        .fill(Color.black)
                        .frame(width: 90, height: 24)
                        .padding(.top, 8)
                        .padding(.bottom, 6)

                    // Screen Body Content
                    mockContentForFeature(item.featureKey)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(uiColor: .systemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                }
                .padding(6)
                .background(Color(hex: "27272A"), in: RoundedRectangle(cornerRadius: 32))
                .overlay(
                    RoundedRectangle(cornerRadius: 32)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1.5)
                )
                .shadow(color: Color.black.opacity(0.6), radius: 24, y: 12)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .padding(.top, 24)
        }
    }

    // MARK: Ảnh chụp giao diện gốc
    private var rawScreenLayout: some View {
        VStack(spacing: 0) {
            // iOS Status Bar
            HStack {
                Text("9:41")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                HStack(spacing: 5) {
                    Image(systemName: "cellularbars")
                    Image(systemName: "wifi")
                    Image(systemName: "battery.100")
                }
                .font(.system(size: 12))
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 6)
            .background(Color(uiColor: .secondarySystemGroupedBackground))

            mockContentForFeature(item.featureKey)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    // MARK: - Mock UI per feature
    @ViewBuilder
    private func mockContentForFeature(_ key: String) -> some View {
        switch key {
        case "home_multispace":
            mockHomeMultiSpaceView
        case "smart_post_compose":
            mockSmartPostComposeView
        case "smart_post_schedule":
            mockSmartPostScheduleView
        case "smart_post_tracker":
            mockSmartPostTrackerView
        case "smart_post_ai":
            mockAITrainingView
        case "auto_feeds":
            mockAutoFeedsView
        case "account_center":
            mockAccountCenterView
        default:
            mockMultiSpaceSyncView
        }
    }

    // 1. Mock Home MultiSpace
    private var mockHomeMultiSpaceView: some View {
        VStack(spacing: 10) {
            HStack {
                Text("MultiSpace")
                    .font(.title2.bold())
                Spacer()
                Image(systemName: "gearshape.fill")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            // Feature Quick Tiles
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                mockTile(title: "Smart Post", subtitle: "Đăng & Lên lịch", icon: "paperplane.fill", color: .orange)
                mockTile(title: "Theo dõi bài", subtitle: "Thống kê & AI Reply", icon: "chart.bar.doc.horizontal.fill", color: .teal)
                mockTile(title: "Auto Feeds", subtitle: "Reaction & Cmt AI", icon: "sparkles", color: .purple)
                mockTile(title: "MultiSpace", subtitle: "Sync Tương tác", icon: "square.stack.3d.up.fill", color: .indigo)
            }
            .padding(.horizontal, 16)

            // Account Spaces List
            VStack(alignment: .leading, spacing: 6) {
                Text("KHÔNG GIAN CỦA TÔI (4)")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)

                VStack(spacing: 6) {
                    mockSpaceRow(name: "Shop Thời Trang Nam (Chính)", tag: "99% Trust • Chrome macOS", proxy: "103.142.x.x:8080 (VN)", isToken: true)
                    mockSpaceRow(name: "Fanpage Mỹ Phẩm Organic", tag: "96% Trust • Safari iOS", proxy: "14.225.x.x:3128 (VN)", isToken: true)
                    mockSpaceRow(name: "Tài Khoản Phụ - Seeding 01", tag: "94% Trust • Edge Windows", proxy: "116.118.x.x:8000 (VN)", isToken: true)
                    mockSpaceRow(name: "Tài Khoản Chăm Sóc Khách", tag: "98% Trust • Firefox Windows", proxy: "Direct (Không Proxy)", isToken: false)
                }
                .padding(.horizontal, 16)
            }
            Spacer()
        }
    }

    // 2. Mock Smart Post Compose
    private var mockSmartPostComposeView: some View {
        VStack(spacing: 10) {
            // Tab switcher
            HStack(spacing: 4) {
                mockTabPill(title: "Đăng bài", isSelected: true)
                mockTabPill(title: "Lịch đăng (3)", isSelected: false)
                mockTabPill(title: "Theo dõi (5)", isSelected: false)
                mockTabPill(title: "Quản lý AI", isSelected: false)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)

            // Post Form
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("ĐÍCH ĐĂNG (3 đã chọn):")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Trang cá nhân + 2 Fanpages")
                        .font(.caption2.bold())
                        .foregroundStyle(Color.themePrimaryDark)
                }

                // Caption
                VStack(alignment: .leading, spacing: 4) {
                    Text("🔥 BỘ SƯU TẬP MỚI CẬP BẾN HÔM NAY! 🔥\nƯu đãi giảm ngay 30% cho 50 khách hàng đầu tiên. Chất liệu thoáng mát, bảo hành 1 đổi 1 trong 7 ngày!\n👉 Inbox ngay để nhận quà tặng kèm!")
                        .font(.caption)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                }

                // Media Previews
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.blue.opacity(0.3))
                        .frame(height: 50)
                        .overlay(Image(systemName: "photo.fill").foregroundStyle(.blue))
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.purple.opacity(0.3))
                        .frame(height: 50)
                        .overlay(Image(systemName: "photo.fill").foregroundStyle(.purple))
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.orange.opacity(0.3))
                        .frame(height: 50)
                        .overlay(Image(systemName: "video.fill").foregroundStyle(.orange))
                }

                // Auto Toggles
                HStack {
                    Label("Tự động thả Reaction (100% ❤️)", systemImage: "heart.fill")
                        .font(.caption2.bold())
                        .foregroundStyle(.pink)
                    Spacer()
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .padding(8)
                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 6))

                HStack {
                    Label("Bình luận mồi đầu tiên (Comment mồi)", systemImage: "bubble.left.fill")
                        .font(.caption2.bold())
                        .foregroundStyle(Color.themePrimaryDark)
                    Spacer()
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .padding(8)
                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 6))

                // Post Button
                Button {} label: {
                    HStack {
                        Image(systemName: "paperplane.fill")
                        Text("Đăng ngay lên 3 Đích")
                    }
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.themePrimaryDark, in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.white)
                }
            }
            .padding(12)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 12)
            Spacer()
        }
    }

    // 3. Mock Smart Post Schedule
    private var mockSmartPostScheduleView: some View {
        VStack(spacing: 10) {
            // Tab switcher
            HStack(spacing: 4) {
                mockTabPill(title: "Đăng bài", isSelected: false)
                mockTabPill(title: "Lịch đăng (3)", isSelected: true)
                mockTabPill(title: "Theo dõi (5)", isSelected: false)
                mockTabPill(title: "Quản lý AI", isSelected: false)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)

            VStack(spacing: 8) {
                mockScheduleCard(
                    title: "Khai xuân đắc lộc - Giảm giá toàn bộ sản phẩm",
                    time: "Hôm nay, 20:00 (Sau 1h 30m)",
                    dest: "Trang cá nhân • 2 Tài khoản",
                    status: "Chờ đăng",
                    statusColor: .orange
                )
                mockScheduleCard(
                    title: "Video Review thực tế áo polo cao cấp",
                    time: "Ngày mai, 08:30 sáng",
                    dest: "Fanpage Mỹ Phẩm Organic",
                    status: "Đã sẵn sàng",
                    statusColor: .blue
                )
                mockScheduleCard(
                    title: "Chúc mừng năm mới Quý khách hàng thân yêu",
                    time: "Hôm qua, 10:00",
                    dest: "3 Không gian tài khoản",
                    status: "Thành công (100%)",
                    statusColor: .green
                )
            }
            .padding(.horizontal, 12)
            Spacer()
        }
    }

    // 4. Mock Smart Post Tracker
    private var mockSmartPostTrackerView: some View {
        VStack(spacing: 8) {
            // Tab switcher
            HStack(spacing: 4) {
                mockTabPill(title: "Đăng bài", isSelected: false)
                mockTabPill(title: "Lịch đăng", isSelected: false)
                mockTabPill(title: "Theo dõi (5)", isSelected: true)
                mockTabPill(title: "Quản lý AI", isSelected: false)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)

            // Metrics Summary
            HStack(spacing: 8) {
                mockMetricBox(icon: "hand.thumbsup.fill", number: "1,420", label: "Cảm xúc", color: .blue)
                mockMetricBox(icon: "bubble.left.and.bubble.right.fill", number: "385", label: "Bình luận", color: .green)
                mockMetricBox(icon: "arrowshape.turn.up.right.fill", number: "92", label: "Chia sẻ", color: .purple)
                mockMetricBox(icon: "clock.badge.exclamationmark.fill", number: "14", label: "Cần trả lời", color: .orange)
            }
            .padding(10)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 12)

            // Tracked Posts
            VStack(spacing: 6) {
                mockTrackerPostRow(
                    caption: "BST Mới ra mắt: Áo Polo thoáng khí 4 chiều...",
                    time: "Vừa xong • Trang cá nhân",
                    stats: "👍 480  💬 120  ↗️ 35",
                    aiStatus: "AI Auto: Đã bật"
                )
                mockTrackerPostRow(
                    caption: "Livestream giải đáp thắc mắc và tặng quà...",
                    time: "2 giờ trước • Fanpage VIP",
                    stats: "👍 940  💬 265  ↗️ 57",
                    aiStatus: "AI Auto: Đang canh cmt"
                )
            }
            .padding(.horizontal, 12)
            Spacer()
        }
    }

    // 5. Mock AI Training & Management
    private var mockAITrainingView: some View {
        VStack(spacing: 8) {
            // Tab switcher
            HStack(spacing: 4) {
                mockTabPill(title: "Đăng bài", isSelected: false)
                mockTabPill(title: "Lịch đăng", isSelected: false)
                mockTabPill(title: "Theo dõi", isSelected: false)
                mockTabPill(title: "Quản lý AI", isSelected: true)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)

            // Persona Grid 3x2
            VStack(alignment: .leading, spacing: 6) {
                Text("HÌNH MẪU NHÂN CÁCH AI:")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    mockPersonaBadge(title: "Chủ shop", icon: "storefront.fill", isChosen: true)
                    mockPersonaBadge(title: "Chuyên gia", icon: "person.badge.shield.checkmark.fill", isChosen: false)
                    mockPersonaBadge(title: "CSKH", icon: "headphones.circle.fill", isChosen: false)
                }
                HStack(spacing: 6) {
                    mockPersonaBadge(title: "Gen Z", icon: "sparkles", isChosen: false)
                    mockPersonaBadge(title: "Doanh nghiệp", icon: "building.2.fill", isChosen: false)
                    mockPersonaBadge(title: "Tùy chỉnh", icon: "slider.horizontal.3", isChosen: false)
                }

                // Knowledge Card
                VStack(alignment: .leading, spacing: 4) {
                    Text("Thương hiệu: ViePN Smart Store • Hotline: 0988.xxx.xxx")
                        .font(.caption2.bold())
                        .foregroundStyle(Color.themePrimaryDark)
                    Text("Sản phẩm: Áo polo 199k, Quần đũi 149k, Combo 499k freeship...")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 6))

                // Few-shot QA Sample
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mẫu Q&A Huấn Luyện (Đã học 3 câu):")
                        .font(.caption2.bold())
                    Text("Q: Còn size L cho 70kg không shop?\nA: Dạ có sẵn anh nhé! Anh mặc size L là vừa vặn, thoải mái luôn ạ!")
                        .font(.caption2)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.themePrimary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(12)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 12)
            Spacer()
        }
    }

    // 6. Mock Auto Feeds
    private var mockAutoFeedsView: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Auto Feeds")
                    .font(.title3.bold())
                Spacer()
                Text("Đang chạy ngầm")
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.2), in: Capsule())
                    .foregroundStyle(.green)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 8) {
                mockFeedConfigRow(title: "Thả cảm xúc ngẫu nhiên", desc: "Tỷ lệ: 70% Thích, 20% Yêu thích, 10% Thương thương", icon: "heart.fill", color: .pink)
                mockFeedConfigRow(title: "Gemini AI Phân tích bài viết", desc: "Tự tạo bình luận đúng ngữ cảnh, không dùng văn mẫu", icon: "wand.and.stars", color: .purple)
                mockFeedConfigRow(title: "Giãn cách thời gian an toàn", desc: "Nghỉ 45s - 90s giữa các bài để chống checkpoint", icon: "timer", color: .blue)
            }
            .padding(12)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 12)

            // Live Activity Logs
            VStack(alignment: .leading, spacing: 4) {
                Text("NHẬT KÝ TƯƠNG TÁC THỜI GIAN THỰC:")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)

                VStack(alignment: .leading, spacing: 4) {
                    Text("• 09:40: Đã thích bài viết của 'Minh Tuấn' (Nhóm Bán Hàng)")
                    Text("• 09:39: Gemini AI comment: 'Mẫu này nhìn đẹp và form chuẩn quá!'")
                    Text("• 09:37: Tự động lướt Newfeed và kiểm tra checkpoint: An toàn")
                }
                .font(.caption2.monospaced())
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(.green)
                .padding(.horizontal, 16)
            }
            Spacer()
        }
    }

    // 7. Mock Account Center
    private var mockAccountCenterView: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Kho Token & Tài Khoản")
                    .font(.title3.bold())
                Spacer()
                Text("4/4 Live")
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.2), in: Capsule())
                    .foregroundStyle(.green)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            VStack(spacing: 8) {
                mockTokenRow(name: "Nguyễn Văn A (Shop Nam)", token: "EAABwz...92Kd (Token EAAI)", status: "Live", expires: "Vĩnh viễn")
                mockTokenRow(name: "Lê Thị B (Mỹ Phẩm VIP)", token: "EAAGNO...48Xp (Token Full)", status: "Live", expires: "60 ngày")
                mockTokenRow(name: "Trần C (Seeding 01)", token: "EAABsb...11Za (Token Page)", status: "Live", expires: "Vĩnh viễn")
            }
            .padding(.horizontal, 16)
            Spacer()
        }
    }

    // 8. Mock MultiSpace Sync
    private var mockMultiSpaceSyncView: some View {
        VStack(spacing: 10) {
            HStack {
                Text("MultiSpace Sync")
                    .font(.title3.bold())
                Spacer()
                Text("Đồng bộ chéo")
                    .font(.caption2.bold())
                    .foregroundStyle(Color.themePrimaryDark)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 8) {
                Text("Ma trận tương tác chéo giữa các không gian:")
                    .font(.caption.bold())
                Text("Hỗ trợ tự động đẩy tương tác, like bài chéo giữa các tài khoản phụ cho bài viết chính mà không bị trùng IP hay Fingerprint.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack {
                    Label("Bảo vệ chống liên đới tài khoản", systemImage: "shield.lefthalf.filled")
                        .font(.caption2.bold())
                        .foregroundStyle(.green)
                    Spacer()
                    Text("100% Độc lập").font(.caption2.bold())
                }
                .padding(8)
                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(12)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
            Spacer()
        }
    }

    // Sub-components
    private func mockTile(title: String, subtitle: String, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(color, in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.bold())
                Text(subtitle).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(8)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private func mockSpaceRow(name: String, tag: String, proxy: String, isToken: Bool) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.themePrimary.opacity(0.3))
                .frame(width: 28, height: 28)
                .overlay(Text(String(name.prefix(1))).font(.caption.bold()).foregroundStyle(Color.themePrimaryDark))

            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.caption.bold()).lineLimit(1)
                Text("\(tag) • \(proxy)").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if isToken {
                Image(systemName: "key.fill").font(.system(size: 10)).foregroundStyle(.green)
            }
        }
        .padding(8)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private func mockTabPill(title: String, isSelected: Bool) -> some View {
        Text(title)
            .font(.system(size: 10, weight: isSelected ? .bold : .medium))
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(isSelected ? Color.themePrimaryDark : Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(isSelected ? .white : .primary)
    }

    private func mockScheduleCard(title: String, time: String, dest: String, status: String, statusColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.bold()).lineLimit(1)
                Spacer()
                Text(status)
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(statusColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(statusColor)
            }
            Text("\(time) • \(dest)").font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private func mockMetricBox(icon: String, number: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon).font(.caption).foregroundStyle(color)
            Text(number).font(.caption.bold())
            Text(label).font(.system(size: 8)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func mockTrackerPostRow(caption: String, time: String, stats: String, aiStatus: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption).font(.caption.bold()).lineLimit(1)
            HStack {
                Text(time).font(.system(size: 9)).foregroundStyle(.secondary)
                Spacer()
                Text(aiStatus).font(.system(size: 9, weight: .bold)).foregroundStyle(Color.themePrimaryDark)
            }
            Text(stats).font(.system(size: 10, weight: .medium)).foregroundStyle(.blue)
        }
        .padding(8)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private func mockPersonaBadge(title: String, icon: String, isChosen: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9))
            Text(title).font(.system(size: 10, weight: isChosen ? .bold : .regular))
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(isChosen ? Color.themePrimary.opacity(0.2) : Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(isChosen ? Color.themePrimaryDark : .primary)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(isChosen ? Color.themePrimaryDark : Color.clear, lineWidth: 1))
    }

    private func mockFeedConfigRow(title: String, desc: String, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.caption).foregroundStyle(color).frame(width: 24, height: 24).background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.bold())
                Text(desc).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(6)
    }

    private func mockTokenRow(name: String, token: String, status: String, expires: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.caption.bold())
                Text("\(token) • \(expires)").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(status).font(.system(size: 9, weight: .bold)).foregroundStyle(.green).padding(.horizontal, 6).padding(.vertical, 2).background(Color.green.opacity(0.15), in: Capsule())
        }
        .padding(8)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - 4. Main Showcase Studio Sheet View

struct AppShowcaseStudioView: View {
    @ObservedObject var manager = ShowcaseStudioManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selectedItemForPreview: ShowcaseScreenItem? = nil
    @State private var showShareSheet: Bool = false
    @State private var shareImages: [UIImage] = []
    @State private var alertMessage: String? = nil
    @State private var showAlert: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header Bar & Controls
                studioTopControlBar

                Divider()

                // Showcase Grid
                ScrollView {
                    VStack(spacing: 16) {
                        // Quick Action Buttons
                        actionButtonsHeader

                        // Grid of screens
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            ForEach(manager.items) { item in
                                showcaseCard(item: item)
                            }
                        }
                        .padding(.horizontal, 14)

                        // Live Captured Screenshots section (if any)
                        if !manager.capturedLiveScreenshots.isEmpty {
                            liveScreenshotsSection
                        }
                    }
                    .padding(.vertical, 14)
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Studio Giới thiệu App")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Đóng") { dismiss() }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        snapCurrentWindowNow()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "camera.fill")
                            Text("Chụp màn hình này")
                        }
                        .font(.caption.bold())
                    }
                }
            }
            .sheet(item: $selectedItemForPreview) { item in
                if let img = item.image {
                    ShowcaseFullPreviewSheet(image: img, title: item.title)
                }
            }
            .sheet(isPresented: $showShareSheet) {
                ShareSheet(items: shareImages)
            }
            .alert("Thông báo", isPresented: $showAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "")
            }
        }
        .onAppear {
            if manager.items.allSatisfy({ $0.image == nil }) {
                Task {
                    await manager.generateAllShowcases()
                }
            }
        }
    }

    // MARK: - Top Controls Bar
    private var studioTopControlBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                // Style Picker: Poster (Mockup) vs Raw
                Picker("Phong cách", selection: $manager.renderStyle) {
                    ForEach(ShowcaseStudioManager.ShowcaseRenderStyle.allCases) { s in
                        Label(s.title, systemImage: s.icon).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: manager.renderStyle) { _ in
                    Task {
                        await manager.generateAllShowcases()
                    }
                }
            }

            if manager.isGeneratingAll {
                VStack(spacing: 4) {
                    ProgressView(value: manager.generationProgress, total: 1.0)
                        .tint(Color.themePrimaryDark)
                    Text(manager.generationStatusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }

    // MARK: - Action Buttons Header
    private var actionButtonsHeader: some View {
        HStack(spacing: 10) {
            // Re-render button
            Button {
                Task {
                    await manager.generateAllShowcases()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Tạo lại tất cả")
                }
                .font(.caption.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(Color.themePrimaryDark)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.themePrimaryDark.opacity(0.3), lineWidth: 1))
            }
            .disabled(manager.isGeneratingAll)

            // Save all to Photos
            Button {
                saveAllImagesToAlbum()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.down.fill")
                    Text("Lưu vào Album ảnh")
                }
                .font(.caption.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(Color.themePrimaryDark, in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(.white)
            }
            .disabled(manager.isGeneratingAll)

            // Export / Share
            Button {
                exportAllImages()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.caption.bold())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.primary)
            }
        }
        .padding(.horizontal, 14)
    }

    // MARK: - Showcase Card
    private func showcaseCard(item: ShowcaseScreenItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if let img = item.image {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .shadow(color: Color.black.opacity(0.12), radius: 4, y: 2)
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                        .aspectRatio(9/16, contentMode: .fit)
                        .overlay(
                            ProgressView()
                        )
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if item.image != nil {
                    selectedItemForPreview = item
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.caption.bold())
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack {
                Button {
                    if let img = item.image {
                        UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
                        alertMessage = "Đã lưu '\(item.title)' vào Thư viện ảnh!"
                        showAlert = true
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.down.circle")
                        Text("Lưu ảnh")
                    }
                    .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                Spacer()

                Button {
                    if let img = item.image {
                        shareImages = [img]
                        showShareSheet = true
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
        .padding(10)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Live Captured Screenshots Section
    private var liveScreenshotsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Ảnh chụp màn hình thực tế (\(manager.capturedLiveScreenshots.count))", systemImage: "camera.viewfinder")
                    .font(.caption.bold())
                    .foregroundStyle(Color.themePrimaryDark)
                Spacer()
                Button("Xóa hết") {
                    manager.capturedLiveScreenshots.removeAll()
                }
                .font(.caption2)
                .foregroundStyle(.red)
            }
            .padding(.horizontal, 14)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(manager.capturedLiveScreenshots.enumerated()), id: \.offset) { index, img in
                        VStack(spacing: 4) {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFit()
                                .frame(height: 140)
                                .clipShape(RoundedRectangle(cornerRadius: 8))

                            Button {
                                UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
                                alertMessage = "Đã lưu ảnh chụp #\(index + 1) vào Album ảnh!"
                                showAlert = true
                            } label: {
                                Text("Lưu ảnh")
                                    .font(.system(size: 9, weight: .bold))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                }
                .padding(.horizontal, 14)
            }
        }
        .padding(.top, 10)
    }

    // MARK: - Actions
    private func snapCurrentWindowNow() {
        if let img = manager.captureCurrentWindow() {
            alertMessage = "Đã chụp thành công cửa sổ màn hình! Ảnh đã được thêm vào bộ sưu tập bên dưới."
            showAlert = true
        }
    }

    private func saveAllImagesToAlbum() {
        manager.saveAllToPhotos { saved, total in
            if saved > 0 {
                alertMessage = "Đã lưu thành công \(saved)/\(total) ảnh vào Album ảnh của bạn!"
            } else {
                alertMessage = "Không thể lưu ảnh. Vui lòng kiểm tra quyền truy cập Album ảnh trong Cài đặt iPhone."
            }
            showAlert = true
        }
    }

    private func exportAllImages() {
        let imgs = manager.items.compactMap { $0.image } + manager.capturedLiveScreenshots
        guard !imgs.isEmpty else {
            alertMessage = "Chưa có ảnh nào được tạo để xuất."
            showAlert = true
            return
        }
        shareImages = imgs
        showShareSheet = true
    }
}

// MARK: - 5. Full Screen Zoom Preview Sheet

struct ShowcaseFullPreviewSheet: View {
    let image: UIImage
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(8)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Đóng") { dismiss() }
                        .foregroundStyle(.white)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                        dismiss()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle.fill")
                            Text("Lưu ảnh")
                        }
                        .foregroundStyle(Color.themePrimary)
                    }
                }
            }
        }
    }
}

// MARK: - 6. Share Sheet Wrapper

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - 7. Color Hex Extension Helper (if not defined elsewhere)
private extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
