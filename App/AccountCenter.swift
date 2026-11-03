import SwiftUI
import UIKit

private enum ProfileFilter: String, CaseIterable, Identifiable {
    case all = "Tất cả"
    case facebook = "Facebook"
    case other = "Khác"
    var id: String { rawValue }
}

struct AccountCenterView: View {
    @EnvironmentObject private var library: SpaceLibrary
    @State private var query = ""
    @State private var filter: ProfileFilter = .all
    @State private var opened: Space?
    @State private var pendingClear: Space?
    @State private var isClearing = false
    @State private var showQuickCreate = false
    @State private var loginEditorSpace: Space?
    @State private var autoInteractSpace: Space?
    @State private var toastMessage: String?
    @State private var refreshTick = 0

    private var matches: [Space] {
        library.spaces.filter { space in
            let textMatch = query.isEmpty ||
                space.name.localizedCaseInsensitiveContains(query) ||
                space.platform.rawValue.localizedCaseInsensitiveContains(query)
            let typeMatch: Bool
            switch filter {
            case .all: typeMatch = true
            case .facebook: typeMatch = space.platform == .facebook
            case .other: typeMatch = space.platform != .facebook
            }
            return textMatch && typeMatch
        }
    }

    private var savedTokenSpacesCount: Int {
        _ = refreshTick
        return library.spaces.filter { VaultMetadataIndex.get($0.id).hasToken }.count
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Vie Account Center", systemImage: "person.crop.rectangle.stack.fill")
                        .font(.title3.bold())
                        .foregroundStyle(.blue)
                    Text("Quản lý đăng nhập, lưu trữ Access Token, Convert 6 App Token, nạp Cookie và chạy Auto Tương tác AI.")
                        .font(.subheadline).foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        metric(value: "\(library.spaces.count)", label: "Không gian", icon: "square.stack.3d.up.fill")
                        metric(value: "\(library.spaces.filter { $0.platform == .facebook }.count)",
                               label: "Facebook", icon: "person.2.fill")
                        metric(value: "\(savedTokenSpacesCount)",
                               label: "Đã lưu Token", icon: "key.radiowaves.forward.fill")
                    }
                }
                .padding(.vertical, 10)
            }

            Section("Công cụ") {
                NavigationLink {
                    AutoInteractView()
                } label: {
                    Label("Auto Thả cảm xúc & Comment Gemini AI", systemImage: "sparkles")
                        .fontWeight(.semibold)
                        .foregroundStyle(.purple)
                }

                Button {
                    showQuickCreate = true
                } label: {
                    Label("Tạo nhiều không gian mới", systemImage: "plus.square.on.square")
                        .fontWeight(.semibold)
                }
                .disabled(isClearing)

                Picker("Bộ lọc", selection: $filter) {
                    ForEach(ProfileFilter.allCases) { value in
                        Text(value.rawValue).tag(value)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Danh sách tài khoản · \(matches.count)") {
                if matches.isEmpty {
                    ContentUnavailableView("Chưa có không gian phù hợp",
                                           systemImage: "person.crop.rectangle.stack",
                                           description: Text("Hãy tạo không gian hoặc đổi bộ lọc."))
                } else {
                    ForEach(matches) { space in
                        let summary = VaultMetadataIndex.get(space.id)
                        HStack(spacing: 12) {
                            Image(systemName: space.platform.icon)
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(space.platform.color,
                                            in: RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(space.name).font(.subheadline.bold())
                                HStack(spacing: 6) {
                                    Text(space.platform.rawValue)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    if summary.hasToken {
                                        Text("• \(summary.tokenPrefix.isEmpty ? "Token" : summary.tokenPrefix) (\(summary.convertedCount) App)")
                                            .font(.caption2.bold())
                                            .foregroundStyle(.green)
                                    } else if summary.hasCookies {
                                        Text("• Đã lưu Cookie")
                                            .font(.caption2.bold())
                                            .foregroundStyle(.orange)
                                    } else if summary.hasCredentials {
                                        Text("• Đã lưu Login")
                                            .font(.caption2)
                                            .foregroundStyle(.blue)
                                    } else {
                                        Text("• Phiên riêng")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Spacer(minLength: 4)
                            Button("Token") {
                                loginEditorSpace = space
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("Mở") { opened = space }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .accessibilityLabel("Mở " + space.name)

                            Menu {
                                if space.platform == .facebook {
                                    Button("Auto Thả cảm xúc & Comment AI", systemImage: "sparkles") {
                                        autoInteractSpace = space
                                    }
                                }
                                Button("Đăng nhập API & Kho Token", systemImage: "person.badge.key.fill") {
                                    loginEditorSpace = space
                                }
                                Button("Nạp Cookie đã lưu & Mở", systemImage: "globe.badge.chevron.backward") {
                                    Task { await injectAndOpen(space) }
                                }
                                Button("Sao chép Access Token gốc", systemImage: "doc.on.doc") {
                                    copySavedToken(for: space)
                                }
                                Button("Sao chép Cookie phiên", systemImage: "link") {
                                    copySavedCookie(for: space)
                                }
                                Divider()
                                Button("Mở trình duyệt", systemImage: "rectangle.portrait.and.arrow.right") {
                                    opened = space
                                }
                                Button("Xóa dữ liệu phiên", systemImage: "trash", role: .destructive) {
                                    pendingClear = space
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 30, height: 36)
                            }
                            .disabled(isClearing)
                        }
                        .padding(.vertical, 5)
                    }
                }
            }

            Section("Lưu trữ Token & Bảo mật") {
                Label {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Dùng chung Cookie & Token tự động").font(.subheadline.bold())
                        Text("Access Token gốc, 6 Converted App Tokens và Cookie lưu trong Keychain được tự động dùng cho cả WebView và tính năng Auto Thả cảm xúc + Comment Gemini AI.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "lock.shield.fill").foregroundStyle(.green)
                }
            }
        }
        .navigationTitle("Tài khoản & Token")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Tìm không gian hoặc nền tảng")
        .sheet(item: $opened) { space in
            NavigationStack {
                SpaceBrowser(space: space)
            }
        }
        .sheet(item: $loginEditorSpace, onDismiss: {
            refreshTick += 1
        }) { space in
            LoginEditorSheet(space: space)
        }
        .sheet(item: $autoInteractSpace) { space in
            NavigationStack {
                AutoInteractView(preselectedSpace: space)
            }
        }
        .sheet(isPresented: $showQuickCreate) {
            QuickCreateProfilesSheet()
        }
        .confirmationDialog("Xóa phiên đăng nhập?", isPresented: Binding(
            get: { pendingClear != nil },
            set: { if !$0 { pendingClear = nil } }
        )) {
            Button("Xóa dữ liệu phiên", role: .destructive) {
                guard let space = pendingClear else { return }
                pendingClear = nil
                isClearing = true
                Task {
                    await library.clearData(space)
                    isClearing = false
                }
            }
        } message: {
            Text("Chỉ dữ liệu web của không gian này bị xóa. Kho Token và các không gian khác được giữ nguyên.")
        }
        .alert("Thông báo", isPresented: Binding(
            get: { toastMessage != nil },
            set: { if !$0 { toastMessage = nil } }
        )) {
            Button("OK") { toastMessage = nil }
        } message: {
            Text(toastMessage ?? "")
        }
    }

    @MainActor
    private func injectAndOpen(_ space: Space) async {
        do {
            let vault = try SecureLoginStore.readTokenVault(space.id)
            _ = await WebCookieBridge.injectCookies(from: vault, into: space.id)
            opened = space
        } catch {
            toastMessage = error.localizedDescription
        }
    }

    private func copySavedToken(for space: Space) {
        do {
            let vault = try SecureLoginStore.readTokenVault(space.id)
            guard !vault.originalToken.isEmpty else {
                toastMessage = "Không gian này chưa có Access Token gốc."
                return
            }
            UIPasteboard.general.string = vault.originalToken
            toastMessage = "Đã sao chép Access Token (\(vault.originalPrefix)) của \(space.name)."
        } catch {
            toastMessage = error.localizedDescription
        }
    }

    private func copySavedCookie(for space: Space) {
        do {
            let vault = try SecureLoginStore.readTokenVault(space.id)
            guard !vault.cookieString.isEmpty else {
                toastMessage = "Không gian này chưa có Cookie đã lưu."
                return
            }
            UIPasteboard.general.string = vault.cookieString
            toastMessage = "Đã sao chép Cookie phiên của \(space.name)."
        } catch {
            toastMessage = error.localizedDescription
        }
    }

    private func metric(value: String, label: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.title3.bold()).monospacedDigit()
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .tertiarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12))
    }
}

struct QuickCreateProfilesSheet: View {
    @EnvironmentObject private var library: SpaceLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var platform: SpacePlatform = .facebook
    @State private var prefix = "Facebook"
    @State private var quantity = 5
    @State private var errorText: String?

    private var canCreate: Bool {
        !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        SpaceLibrary.safeURL(platform.home) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Tạo không gian") {
                    Picker("Nền tảng", selection: $platform) {
                        ForEach(SpacePlatform.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .onChange(of: platform) { _, value in prefix = value.rawValue }
                    TextField("Tiền tố tên", text: $prefix)
                    Stepper("Số lượng: \(quantity)", value: $quantity, in: 1...50)
                }

                Section("Xem trước") {
                    ForEach(1...min(quantity, 3), id: \.self) { index in
                        Label(String(format: "%@ %02d", prefix, index),
                              systemImage: platform.icon)
                    }
                    if quantity > 3 {
                        Text("... và \(quantity - 3) không gian nữa")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Text("Mỗi không gian được tạo độc lập. Sau khi tạo, bấm nút Token ở từng không gian để đăng nhập API, lưu trữ Access Token hoặc nạp Cookie.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Tạo nhanh")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Hủy") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Tạo \(quantity)") {
                        do {
                            for index in 1...quantity {
                                let name = String(format: "%@ %02d",
                                                  prefix.trimmingCharacters(in: .whitespacesAndNewlines),
                                                  index)
                                try library.add(name: name, platform: platform, url: platform.home)
                            }
                            dismiss()
                        } catch {
                            errorText = error.localizedDescription
                        }
                    }
                    .disabled(!canCreate)
                }
            }
            .alert("Không thể tạo", isPresented: Binding(
                get: { errorText != nil },
                set: { if !$0 { errorMessageReset() } }
            )) {
                Button("OK") { errorText = nil }
            } message: {
                Text(errorText ?? "")
            }
        }
    }

    private func errorMessageReset() {
        errorText = nil
    }
}
