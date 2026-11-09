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

    // Bật/tắt nút chụp nổi (Mặc định BẬT để user thấy ngay nút 📸)
    @Published var isFloatingCameraEnabled: Bool = true

    // Danh sách ảnh thật đã chụp
    @Published var capturedPhotos: [RealCapturedPhoto] = []

    // MARK: - Chụp trực tiếp cửa sổ màn hình thật (Live Window Hierarchy)
    func captureCurrentWindow(customLabel: String? = nil) -> UIImage? {
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

        // Vẽ trực tiếp các layer thực tế từ GPU/UIKit window
        let image = renderer.image { _ in
            window.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }

        let timeStr = Date().formatted(date: .omitted, time: .standard)
        let itemLabel = customLabel ?? "Ảnh thật lúc \(timeStr)"
        let item = RealCapturedPhoto(image: image, label: itemLabel)
        capturedPhotos.insert(item, at: 0)

        // Tự động lưu ảnh thật vào Album ảnh của iPhone
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)

        return image
    }

    // MARK: - Lưu lại toàn bộ ảnh trong bộ sưu tập vào Album
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
    @State private var dragOffset: CGSize = .zero
    @State private var isHidingForShot: Bool = false
    @State private var showFlash: Bool = false
    @State private var toastMessage: String? = nil

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.clear.ignoresSafeArea()

            // Nút Chụp Nổi (Draggable Floating Camera Button)
            if manager.isFloatingCameraEnabled && !isHidingForShot {
                Button {
                    takeRealScreenshotNow()
                } label: {
                    ZStack {
                        // Nền gradient nổi bật với viền trắng 2.5pt
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color(red: 117/255, green: 160/255, blue: 117/255), Color(red: 143/255, green: 188/255, blue: 143/255)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 62, height: 62)
                            .overlay(Circle().stroke(Color.white, lineWidth: 2.5))
                            .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 4)

                        VStack(spacing: 2) {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(.white)
                            Text("CHỤP THẬT")
                                .font(.system(size: 8, weight: .heavy))
                                .foregroundStyle(.white)
                        }

                        // Badge số lượng ảnh thật đã chụp
                        if !manager.capturedPhotos.isEmpty {
                            Text("\(manager.capturedPhotos.count)")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.red, in: Capsule())
                                .foregroundStyle(.white)
                                .offset(x: 22, y: -22)
                        }
                    }
                }
                .buttonStyle(.plain)
                .padding(.trailing, 20)
                .padding(.bottom, 95)
                .offset(dragOffset)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            dragOffset = value.translation
                        }
                )
            }
        }
        .overlay(alignment: .top) {
            if let msg = toastMessage {
                HStack(spacing: 8) {
                    Image(systemName: "camera.fill")
                        .foregroundStyle(.white)
                    Text(msg)
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.88), in: Capsule())
                .shadow(radius: 8)
                .padding(.top, 55)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay {
            if showFlash {
                Color.white
                    .ignoresSafeArea()
                    .opacity(0.85)
            }
        }
    }

    private func takeRealScreenshotNow() {
        // 1. Tạm ẩn nút chụp nổi để không dính vào ảnh
        isHidingForShot = true

        // 2. Chờ 0.08s để view biến mất khỏi render hierarchy
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            // 3. Chụp ảnh thật của màn hình trực tiếp từ window hierarchy
            if let _ = manager.captureCurrentWindow() {
                // Rung phản hồi haptic
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()

                // Hiệu ứng chớp sáng màn hình như máy ảnh thật
                withAnimation(.easeOut(duration: 0.12)) {
                    showFlash = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showFlash = false
                    }
                }

                // Hiển thị toast xác nhận đã lưu vào Album ảnh
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

    @State private var selectedPhotoForPreview: RealCapturedPhoto? = nil
    @State private var showShareSheet: Bool = false
    @State private var shareImages: [UIImage] = []
    @State private var alertMessage: String? = nil
    @State private var showAlert: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Card Hướng Dẫn: Nút Chụp Nổi
                    floatingButtonGuideCard

                    // Nút Chụp Màn Hình Bên Dưới Ngay Bây Giờ
                    snapUnderlyingScreenCard

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
    private var floatingButtonGuideCard: some View {
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

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "1.circle.fill")
                        .foregroundStyle(Color.themePrimaryDark)
                    Text("Đóng cửa sổ này lại và chuyển đến màn hình bạn cần chụp (Đăng bài, Lịch đăng, Theo dõi, Quản lý AI, lướt Facebook...).")
                        .font(.caption)
                }

                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "2.circle.fill")
                        .foregroundStyle(Color.themePrimaryDark)
                    Text("Bấm 1 chạm vào nút tròn [📸 CHỤP THẬT] ở góc dưới bên phải màn hình.")
                        .font(.caption)
                }

                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "3.circle.fill")
                        .foregroundStyle(Color.themePrimaryDark)
                    Text("Màn hình chớp sáng và ẢNH THẬT 100% được lưu ngay lập tức vào Album ảnh (Photos) của iPhone!")
                        .font(.caption)
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - 2. Snap Underlying Screen Card
    private var snapUnderlyingScreenCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Chụp Ngay Màn Hình Phía Dưới", systemImage: "camera.shutter.button.fill")
                .font(.subheadline.bold())
                .foregroundStyle(Color.themePrimaryDark)

            Text("Tự động đóng Studio lại và chụp ngay màn hình bạn vừa đứng trước khi mở Studio:")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    _ = manager.captureCurrentWindow(customLabel: "Ảnh chụp màn hình")
                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "camera.fill")
                    Text("Đóng & Chụp ngay màn hình phía dưới")
                }
                .font(.subheadline.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Color.themePrimaryDark, in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.white)
            }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - 3. Export Action Buttons
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
                    Text("Hãy bấm nút tròn [📸 CHỤP THẬT] ở góc màn hình khi bạn đang xem bất kỳ tính năng nào để lấy ảnh thật.")
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
