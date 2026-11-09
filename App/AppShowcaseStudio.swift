import SwiftUI
import UIKit
import Photos

// MARK: - 1. Real Captured Photo Model

struct RealCapturedPhoto: Identifiable, Equatable {
    let id = UUID()
    let image: UIImage
    let date: Date = Date()
    var label: String

    static func == (lhs: RealCapturedPhoto, rhs: RealCapturedPhoto) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - 2. Studio Manager (Quản lý chụp ảnh thật)

@MainActor
final class ShowcaseStudioManager: ObservableObject {
    static let shared = ShowcaseStudioManager()

    // Bật/tắt nút chụp nổi
    @Published var isFloatingCameraEnabled: Bool = true

    // Danh sách ảnh thật đã chụp
    @Published var capturedPhotos: [RealCapturedPhoto] = []

    // Trạng thái tự động chụp
    @Published var isAutoCapturing: Bool = false
    @Published var autoCaptureProgress: Double = 0.0
    @Published var currentCapturingName: String = ""

    // MARK: - Chụp trực tiếp cửa sổ màn hình đang hiển thị
    func captureCurrentWindow() -> UIImage? {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let window = windowScene.windows.first(where: { $0.isKeyWindow }) ?? windowScene.windows.first else {
            return nil
        }

        let bounds = window.bounds
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)

        let image = renderer.image { _ in
            window.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }

        let timeStr = Date().formatted(date: .omitted, time: .standard)
        let item = RealCapturedPhoto(image: image, label: "Ảnh chụp thật lúc \(timeStr)")
        capturedPhotos.insert(item, at: 0)

        // Tự động lưu vào Album ảnh của máy
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)

        return image
    }

    // MARK: - Tự động kết xuất ảnh thật từ các View thực tế của App
    func autoCaptureAllRealViews(library: SpaceLibrary?) async {
        isAutoCapturing = true
        autoCaptureProgress = 0.0

        let screens: [(name: String, view: AnyView)] = [
            ("1. Trang chủ MultiSpace", AnyView(
                NavigationStack {
                    SpaceDashboard()
                }
            )),
            ("2. Smart Post - Đăng bài", AnyView(
                NavigationStack {
                    SmartPostView(initialTab: 0)
                }
            )),
            ("3. Smart Post - Lịch đăng", AnyView(
                NavigationStack {
                    SmartPostView(initialTab: 1)
                }
            )),
            ("4. Smart Post - Theo dõi bài", AnyView(
                NavigationStack {
                    SmartPostView(initialTab: 2)
                }
            )),
            ("5. Smart Post - Quản lý AI", AnyView(
                NavigationStack {
                    SmartPostView(initialTab: 3)
                }
            )),
            ("6. Auto Feeds - Tương tác AI", AnyView(
                NavigationStack {
                    AutoInteractView()
                }
            )),
            ("7. Trung tâm Tài khoản & Token", AnyView(
                NavigationStack {
                    AccountCenterView()
                }
            )),
            ("8. Mạng Proxy & Vân tay", AnyView(
                NavigationStack {
                    BatchProxyManagerView()
                }
            )),
            ("9. MultiSpace Sync", AnyView(
                NavigationStack {
                    MultiSpaceSyncView()
                }
            ))
        ]

        let screenSize = UIScreen.main.bounds.size

        let lib = library ?? SpaceLibrary.shared ?? SpaceLibrary()

        for (index, item) in screens.enumerated() {
            currentCapturingName = "Đang chụp: \(item.name)..."

            let target = item.view
                .environmentObject(lib)
                .frame(width: screenSize.width, height: screenSize.height)
                .background(Color(uiColor: .systemBackground))

            let renderer = ImageRenderer(content: target)
            renderer.scale = UIScreen.main.scale
            renderer.proposedSize = ProposedViewSize(screenSize)

            if let img = renderer.uiImage {
                let photoItem = RealCapturedPhoto(image: img, label: item.name)
                capturedPhotos.insert(photoItem, at: 0)
                UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
            }

            autoCaptureProgress = Double(index + 1) / Double(screens.count)
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        currentCapturingName = "Đã chụp và lưu thành công tất cả màn hình thật vào Album ảnh!"
        try? await Task.sleep(nanoseconds: 500_000_000)
        isAutoCapturing = false
    }

    // MARK: - Lưu toàn bộ ảnh trong bộ sưu tập vào Album
    func saveAllToPhotos(completion: @escaping (Int) -> Void) {
        guard !capturedPhotos.isEmpty else {
            completion(0)
            return
        }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            DispatchQueue.main.async {
                guard status == .authorized || status == .limited else {
                    completion(0)
                    return
                }

                var count = 0
                for item in self.capturedPhotos {
                    UIImageWriteToSavedPhotosAlbum(item.image, nil, nil, nil)
                    count += 1
                }
                completion(count)
            }
        }
    }
}

// MARK: - 3. Floating Capture Button Overlay (Nút chụp ảnh thật nổi trên toàn màn hình)

struct FloatingCaptureOverlay: View {
    @ObservedObject var manager = ShowcaseStudioManager.shared
    @State private var position: CGPoint = CGPoint(
        x: UIScreen.main.bounds.width - 45,
        y: UIScreen.main.bounds.height - 180
    )
    @State private var isHidingForShot: Bool = false
    @State private var showFlash: Bool = false
    @State private var toastMessage: String? = nil

    var body: some View {
        ZStack {
            // Flash Effect khi chụp
            if showFlash {
                Color.white
                    .ignoresSafeArea()
                    .opacity(0.85)
                    .transition(.opacity)
            }

            // Toast thông báo chụp thành công
            if let msg = toastMessage {
                VStack {
                    HStack(spacing: 8) {
                        Image(systemName: "camera.fill")
                            .foregroundStyle(.white)
                        Text(msg)
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.85), in: Capsule())
                    .shadow(radius: 8)
                    .padding(.top, 55)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Nút Chụp Nổi (Draggable Floating Camera Button)
            if manager.isFloatingCameraEnabled && !isHidingForShot {
                Button {
                    takeRealScreenshotNow()
                } label: {
                    ZStack {
                        // Nền gradient nổi bật
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color(red: 117/255, green: 160/255, blue: 117/255), Color(red: 143/255, green: 188/255, blue: 143/255)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 58, height: 58)
                            .shadow(color: Color.black.opacity(0.35), radius: 6, x: 0, y: 3)

                        VStack(spacing: 2) {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(.white)
                            Text("Chụp thật")
                                .font(.system(size: 8, weight: .heavy))
                                .foregroundStyle(.white)
                        }

                        // Badge số lượng ảnh thật đã chụp
                        if !manager.capturedPhotos.isEmpty {
                            Text("\(manager.capturedPhotos.count)")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Color.red, in: Capsule())
                                .foregroundStyle(.white)
                                .offset(x: 20, y: -20)
                        }
                    }
                }
                .position(position)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            position = value.location
                        }
                )
            }
        }
        .allowsHitTesting(manager.isFloatingCameraEnabled)
    }

    private func takeRealScreenshotNow() {
        // 1. Tạm ẩn nút chụp nổi để không dính vào ảnh
        isHidingForShot = true

        // 2. Chờ 0.08s để view biến mất khỏi hierarchy
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            // 3. Chụp ảnh thật của cửa sổ màn hình
            if let img = manager.captureCurrentWindow() {
                // Rung phản hồi haptic
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()

                // Hiệu ứng chớp sáng màn hình
                withAnimation(.easeOut(duration: 0.12)) {
                    showFlash = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showFlash = false
                    }
                }

                // Hiển thị toast
                withAnimation {
                    toastMessage = "Đã chụp ảnh thật & lưu vào Album ảnh (\(manager.capturedPhotos.count))"
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation {
                        toastMessage = nil
                    }
                }
            }

            // 4. Hiện lại nút chụp nổi
            isHidingForShot = false
        }
    }
}

// MARK: - 4. Main App Showcase Studio View

struct AppShowcaseStudioView: View {
    @ObservedObject var manager = ShowcaseStudioManager.shared
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: SpaceLibrary

    @State private var selectedPhotoForPreview: RealCapturedPhoto? = nil
    @State private var showShareSheet: Bool = false
    @State private var shareImages: [UIImage] = []
    @State private var alertMessage: String? = nil
    @State private var showAlert: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Header Card: Hướng dẫn & Tùy chọn Nút Chụp Nổi
                    floatingButtonControlCard

                    // Action Card: Nút Tự Động Chụp Tất Cả Cửa Sổ Thật
                    autoCaptureActionCard

                    // Action Buttons: Lưu & Xuất ảnh
                    if !manager.capturedPhotos.isEmpty {
                        exportActionButtons
                    }

                    // Gallery: Danh sách Ảnh Thật Đã Chụp
                    realPhotosGallerySection
                }
                .padding(14)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Chụp Ảnh Thật Từ App")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Đóng") { dismiss() }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        snapActiveWindowNow()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "camera.fill")
                            Text("Chụp màn hình này")
                        }
                        .font(.caption.bold())
                    }
                }
            }
            .sheet(item: $selectedPhotoForPreview) { photo in
                RealPhotoFullPreviewSheet(photo: photo)
            }
            .sheet(isPresented: $showShareSheet) {
                RealPhotoShareSheet(items: shareImages)
            }
            .alert("Thông báo", isPresented: $showAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "")
            }
        }
    }

    // MARK: - 1. Floating Button Control Card
    private var floatingButtonControlCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Nút Chụp Ảnh Nổi Trên Màn Hình", systemImage: "camera.viewfinder")
                    .font(.subheadline.bold())
                    .foregroundStyle(Color.themePrimaryDark)
                Spacer()
                Toggle("", isOn: $manager.isFloatingCameraEnabled)
                    .labelsHidden()
                    .tint(Color.themePrimaryDark)
            }

            Text("Khi bật, nút chụp 📸 sẽ nổi trên góc màn hình. Bạn chỉ cần mở bất kỳ cửa sổ nào của ứng dụng (Đăng bài, Lịch đăng, Theo dõi, Quản lý AI, Facebook...), bấm nút 📸 là ứng dụng sẽ CHỤP ẢNH THẬT của màn hình đó và tự động lưu vào Album ảnh iPhone của bạn!")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineSpacing(2)
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - 2. Auto Capture Action Card
    private var autoCaptureActionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Tự Động Chụp Tất Cả Cửa Sổ Thật", systemImage: "bolt.fill")
                .font(.subheadline.bold())
                .foregroundStyle(Color.themePrimaryDark)

            Text("Hệ thống sẽ tự động duyệt qua lần lượt các cửa sổ thực tế của ứng dụng (Trang chủ, Đăng bài, Lịch đăng, Theo dõi tương tác, Quản lý AI, Auto Feeds, Kho Token, Proxy, Sync) và chụp ảnh thật lưu vào Album ảnh.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if manager.isAutoCapturing {
                VStack(spacing: 6) {
                    ProgressView(value: manager.autoCaptureProgress, total: 1.0)
                        .tint(Color.themePrimaryDark)
                    Text(manager.currentCapturingName)
                        .font(.caption2.bold())
                        .foregroundStyle(Color.themePrimaryDark)
                }
                .padding(.vertical, 4)
            } else {
                Button {
                    Task {
                        await manager.autoCaptureAllRealViews(library: library)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "camera.on.rectangle.fill")
                        Text("Bắt đầu tự động chụp 9 cửa sổ thật")
                    }
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color.themePrimaryDark, in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.white)
                }
            }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - 3. Export & Save Buttons
    private var exportActionButtons: some View {
        HStack(spacing: 10) {
            Button {
                saveAllPhotosToAlbum()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.down.fill")
                    Text("Lưu tất cả (\(manager.capturedPhotos.count)) vào Album")
                }
                .font(.caption.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.themePrimaryDark, in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(.white)
            }

            Button {
                exportAllPhotos()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.up")
                    Text("Chia sẻ / Xuất")
                }
                .font(.caption.bold())
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(.primary)
            }
        }
    }

    // MARK: - 4. Real Photos Gallery
    private var realPhotosGallerySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("BỘ SƯU TẬP ẢNH THẬT ĐÃ CHỤP (\(manager.capturedPhotos.count))")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                Spacer()

                if !manager.capturedPhotos.isEmpty {
                    Button("Xóa tất cả") {
                        manager.capturedPhotos.removeAll()
                    }
                    .font(.caption2)
                    .foregroundStyle(.red)
                }
            }

            if manager.capturedPhotos.isEmpty {
                VStack(spacing: 8) {
                    Spacer(minLength: 20)
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.themePrimary.opacity(0.5))
                    Text("Chưa có ảnh thật nào được chụp")
                        .font(.footnote.bold())
                    Text("Bấm 'Chụp màn hình này', hoặc bật 'Nút Chụp Nổi' rồi chuyển đến các màn hình bạn muốn chụp.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                    Spacer(minLength: 20)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(manager.capturedPhotos) { photo in
                        realPhotoCard(photo: photo)
                    }
                }
            }
        }
    }

    private func realPhotoCard(photo: RealCapturedPhoto) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(uiImage: photo.image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: Color.black.opacity(0.1), radius: 3, y: 1)
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedPhotoForPreview = photo
                }

            Text(photo.label)
                .font(.system(size: 11, weight: .bold))
                .lineLimit(1)

            HStack {
                Button {
                    UIImageWriteToSavedPhotosAlbum(photo.image, nil, nil, nil)
                    alertMessage = "Đã lưu ảnh '\(photo.label)' vào Thư viện ảnh!"
                    showAlert = true
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.down.circle")
                        Text("Lưu")
                    }
                    .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                Spacer()

                Button {
                    shareImages = [photo.image]
                    showShareSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Actions
    private func snapActiveWindowNow() {
        if let img = manager.captureCurrentWindow() {
            alertMessage = "Đã chụp ảnh thật của màn hình này và tự động lưu vào Album ảnh của bạn!"
            showAlert = true
        }
    }

    private func saveAllPhotosToAlbum() {
        manager.saveAllToPhotos { count in
            if count > 0 {
                alertMessage = "Đã lưu thành công \(count) ảnh thật vào Album ảnh của bạn!"
            } else {
                alertMessage = "Không có ảnh nào để lưu hoặc chưa cấp quyền Album ảnh."
            }
            showAlert = true
        }
    }

    private func exportAllPhotos() {
        let imgs = manager.capturedPhotos.map { $0.image }
        guard !imgs.isEmpty else { return }
        shareImages = imgs
        showShareSheet = true
    }
}

// MARK: - 5. Full Screen Preview Sheet

struct RealPhotoFullPreviewSheet: View {
    let photo: RealCapturedPhoto
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                Image(uiImage: photo.image)
                    .resizable()
                    .scaledToFit()
                    .padding(4)
            }
            .navigationTitle(photo.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Đóng") { dismiss() }
                        .foregroundStyle(.white)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIImageWriteToSavedPhotosAlbum(photo.image, nil, nil, nil)
                        dismiss()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle.fill")
                            Text("Lưu vào Album")
                        }
                        .foregroundStyle(Color.themePrimary)
                    }
                }
            }
        }
    }
}

// MARK: - 6. Real Photo Share Sheet Wrapper

struct RealPhotoShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
