import SwiftUI

// Account hub for isolated first-party web sessions. It does not request,
// inspect, export or transmit passwords, cookies, 2FA secrets or access tokens.

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

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Vie Account Center", systemImage: "person.crop.rectangle.stack.fill")
                        .font(.title3.bold())
                        .foregroundStyle(.blue)
                    Text("Quản lý đăng nhập các website theo từng không gian riêng tư.")
                        .font(.subheadline).foregroundStyle(.secondary)

                    HStack(spacing: 14) {
                        metric(value: "\(library.spaces.count)", label: "Không gian", icon: "square.stack.3d.up.fill")
                        metric(value: "\(library.spaces.filter { $0.platform == .facebook }.count)",
                               label: "Facebook", icon: "person.2.fill")
                    }
                }
                .padding(.vertical, 10)
            }

            Section("Công cụ") {
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
                        HStack(spacing: 12) {
                            Image(systemName: space.platform.icon)
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(space.platform.color,
                                            in: RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(space.name).font(.subheadline.bold())
                                Text(space.platform.rawValue + " • Phiên riêng")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Button("Mở") { opened = space }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .accessibilityLabel("Mở " + space.name)
                            Menu {
                                Button("Mở/Đăng nhập", systemImage: "rectangle.portrait.and.arrow.right") {
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

            Section("Đăng nhập an toàn") {
                Label {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Đăng nhập trên website chính thức").font(.subheadline.bold())
                        Text("Bấm Mở, nhập thông tin đăng nhập và mã 2FA trên website. WebKit duy trì dữ liệu web riêng của từng không gian.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "lock.shield.fill").foregroundStyle(.green)
                }
                Label {
                    Text("Ứng dụng không đọc hoặc hiển thị cookie, access token, mật khẩu hay khóa bí mật 2FA.")
                        .font(.footnote).foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Tài khoản")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Tìm không gian hoặc nền tảng")
        .sheet(item: $opened) { space in
            NavigationStack {
                SpaceBrowser(space: space)
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
            Text("Chỉ dữ liệu web của không gian này bị xóa. Tài khoản và các không gian khác được giữ nguyên.")
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
        .padding(12)
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
                    Text("Mỗi không gian được tạo trống. Bạn tự đăng nhập từng tài khoản trên website chính thức. Không nhập mật khẩu hoặc 2FA vào trình tạo không gian.")
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
                set: { if !$0 { errorText = nil } }
            )) {
                Button("OK") { errorText = nil }
            } message: {
                Text(errorText ?? "")
            }
        }
    }
}
