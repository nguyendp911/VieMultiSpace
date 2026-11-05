import SwiftUI
import Foundation
import UIKit

// MARK: - Smart Post Models & Privacy Options

enum SmartPostPrivacy: String, CaseIterable, Identifiable {
    case everyone = "Công khai (EVERYONE)"
    case friends = "Bạn bè (FRIENDS)"
    case onlyMe = "Chỉ mình tôi (ONLY_ME)"

    var id: String { rawValue }

    var apiKey: String {
        switch self {
        case .everyone: return "EVERYONE"
        case .friends: return "FRIENDS"
        case .onlyMe: return "ONLY_ME"
        }
    }

    var privacyId: String {
        switch self {
        case .everyone: return "300645083384735"
        case .friends: return "291667064279714"
        case .onlyMe: return "286958161406148"
        }
    }

    var icon: String {
        switch self {
        case .everyone: return "globe.asia.australia.fill"
        case .friends: return "person.2.fill"
        case .onlyMe: return "lock.fill"
        }
    }
}

struct SmartPostResult: Identifiable {
    let id = UUID()
    let spaceName: String
    let isSuccess: Bool
    let postId: String?
    let postUrl: String?
    let message: String
}

// MARK: - Smart Post Engine

enum SmartPostAPIClient {
    private static let fbHeaders: [String: String] = [
        "User-Agent": "[FBAN/FB4A;FBAV/522.0.0.52.96;FBBV/763259015;FBDM/{density=1.5,width=540,height=960};FBLC/vi_VN;FBRV/0;FBCR/MobiFone;FBMF/Honor;FBBD/Honor;FBPN/com.facebook.katana;FBDV/BVL-AN00;FBSV/9;FBOP/1;FBCA/x86_64:arm64-v8a;]",
        "x-tigon-is-retry": "False",
        "x-fb-device-group": "3595",
        "x-zero-eh": "2,,ATY5qyn5pgi0LPFxwgj-nj0AQ_Kv6eqmdL2VIGqwb4BIQOtJlgLIT3SqrGnRwEFhqVI",
        "x-fb-connection-type": "WIFI",
        "app-scope-id-header": "d0db7ed7-f05d-4ab4-a34b-27ea5eb599f1",
        "x-fb-sim-hni": "45201",
        "x-fb-net-hni": "45201",
        "x-zero-f-device-id": "d0db7ed7-f05d-4ab4-a34b-27ea5eb599f1",
        "priority": "u=3, i",
        "x-fb-connection-quality": "EXCELLENT",
        "x-fb-http-engine": "Tigon/Liger",
        "x-fb-client-ip": "True",
        "x-fb-server-cluster": "True"
    ]

    /// Tải ảnh lên Graph API /me/photos để lấy Photo ID
    static func uploadPhoto(imageData: Data, accessToken: String) async throws -> String {
        let url = URL(string: "https://graph.facebook.com/me/photos")!
        let sessionId = UUID().uuidString
        let boundary = "Boundary-\(UUID().uuidString)"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (k, v) in fbHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.setValue("OAuth \(accessToken)", forHTTPHeaderField: "authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "content-type")
        request.setValue("upload-photo", forHTTPHeaderField: "x-fb-friendly-name")

        var body = Data()
        let fields: [String: String] = [
            "published": "false",
            "audience_exp": "true",
            "qn": sessionId,
            "composer_session_id": sessionId,
            "idempotence_token": "\(sessionId)_-1495512223_0",
            "composer_entry_point": "camera_roll",
            "locale": "vi_VN",
            "client_country_code": "VN",
            "fb_api_req_friendly_name": "upload-photo",
            "fb_api_caller_class": "MultiPhotoUploader"
        ]

        for (k, v) in fields {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(k)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(v)\r\n".data(using: .utf8)!)
        }

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"source\"; filename=\"photo.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let photoId = json["id"] as? String {
            return photoId
        } else {
            let errText = String(data: data, encoding: .utf8) ?? "HTTP \(statusCode)"
            throw NSError(domain: "SmartPost", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "Lỗi tải ảnh: \(errText.prefix(120))"])
        }
    }

    /// Đăng bài viết (status hoặc ảnh) qua GraphQL ComposerStoryCreateMutation
    static func createPost(
        caption: String,
        photoIds: [String] = [],
        privacy: SmartPostPrivacy = .everyone,
        accessToken: String,
        userId: String
    ) async throws -> (postId: String, postUrl: String?) {
        let url = URL(string: "https://graph.facebook.com/graphql")!
        let composerSessionId = UUID().uuidString
        let clientTraceId = UUID().uuidString
        let actionTimestamp = Int(Date().timeIntervalSince1970)

        var attachments: [[String: Any]] = []
        for pid in photoIds {
            attachments.append([
                "photo": [
                    "unified_stories_media_source": "CAMERA_ROLL",
                    "story_media_audio_data": [
                        "raw_media_type": "PHOTO"
                    ],
                    "media_source_info": [
                        "entry_point": "COMPOSER_MEDIA_SPROUT"
                    ],
                    "id": pid
                ]
            ])
        }

        var inputDict: [String: Any] = [
            "producer_supported_features": ["LIGHTWEIGHT_REPLY"],
            "logging": [
                "composer_session_id": composerSessionId
            ],
            "is_throwback_post": "NOT_THROWBACK_POST",
            "navigation_data": [
                "attribution_id_v2": "ProfileFragment,profile_vnext_tab_posts,tap_bookmark,\(actionTimestamp).871,244483734,\(userId),,,\(actionTimestamp).378"
            ],
            "reshare_original_post": "SHARE_LINK_ONLY",
            "idempotence_token": "FEED_\(composerSessionId)",
            "camera_post_context": [
                "source": "COMPOSER",
                "platform": "FACEBOOK",
                "deduplication_id": composerSessionId
            ],
            "connection_class": "EXCELLENT",
            "composer_type": "status",
            "composer_source_surface": "timeline",
            "message": [
                "text": caption
            ],
            "implicit_with_tags_ids": [],
            "composer_entry_point": "profile_inline_composer",
            "nectar_module": "profile_timeline_composer",
            "composer_entry_picker": "NULL",
            "action_timestamp": actionTimestamp,
            "audiences": [[
                "undirected": [
                    "privacy": [
                        "tag_expansion_state": "UNSPECIFIED",
                        "deny": [],
                        "base_state": privacy.apiKey,
                        "allow": []
                    ]
                ]
            ]],
            "tag_expansion_metadata": [
                "tag_expansion_ids": []
            ],
            "place_attachment_setting": "SHOW_ATTACHMENT",
            "ai_generated_self_disclosure_metadata": [
                "was_self_disclosed_as_ai_generated": false
            ],
            "composer_session_events_log": [
                "number_of_keystrokes": caption.count,
                "number_of_copy_pastes": 0,
                "composition_duration": 15
            ],
            "audiences_is_complete": true,
            "source": "MOBILE",
            "actor_id": userId
        ]

        if !attachments.isEmpty {
            inputDict["attachments"] = attachments
        }

        let variablesDict: [String: Any] = [
            "default_image_scale": "1.5",
            "should_fetch_adaptive_ufi": true,
            "media_type": "image/jpeg",
            "input": inputDict
        ]

        let variablesJson = (try? String(data: JSONSerialization.data(withJSONObject: variablesDict), encoding: .utf8)) ?? "{}"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (k, v) in fbHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.setValue("OAuth \(accessToken)", forHTTPHeaderField: "authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        request.setValue("graphservice", forHTTPHeaderField: "x-graphql-client-library")
        request.setValue("ComposerStoryCreateMutation", forHTTPHeaderField: "x-fb-friendly-name")

        let postParams: [String: String] = [
            "method": "post",
            "pretty": "false",
            "format": "json",
            "server_timestamps": "true",
            "locale": "vi_VN",
            "fb_api_req_friendly_name": "ComposerStoryCreateMutation",
            "fb_api_caller_class": "graphservice",
            "client_doc_id": "91093790613512646032808605640",
            "fb_api_client_context": "{\"is_background\":false}",
            "variables": variablesJson,
            "client_trace_id": clientTraceId
        ]

        let formPairs = postParams.map { k, v in
            let ek = k.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? k
            let ev = v.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? v
            return "\(ek)=\(ev)"
        }
        request.httpBody = formPairs.joined(separator: "&").data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let respString = String(data: data, encoding: .utf8) ?? ""

        // Parse story_create or post ID from response
        if let directJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let d = directJson["data"] as? [String: Any],
           let sc = d["story_create"] as? [String: Any],
           let story = sc["story"] as? [String: Any] {
            let pid = (story["id"] as? String) ?? (story["legacy_api_story_id"] as? String) ?? ""
            let purl = story["url"] as? String
            return (pid.isEmpty ? "Đã đăng thành công" : pid, purl)
        }

        // Regex fallback to find post_id or legacy_api_story_id
        if let pidMatch = FacebookTargetPostResolver.firstMatch(pattern: "\"legacy_api_story_id\":\"([0-9]+)\"", in: respString)
            ?? FacebookTargetPostResolver.firstMatch(pattern: "\"id\":\"([0-9_]+)\"", in: respString) {
            return (pidMatch, "https://www.facebook.com/\(pidMatch)")
        }

        if respString.contains("\"story_create\"") {
            return ("Thành công", nil)
        }

        throw NSError(domain: "SmartPost", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "Đăng bài thất bại: \(respString.prefix(120))"])
    }

    /// Đổi quyền riêng tư bài viết (Công khai, Bạn bè, Chỉ mình tôi)
    static func updatePostPrivacy(postId: String, privacy: SmartPostPrivacy, accessToken: String) async throws -> Bool {
        let url = URL(string: "https://graph.facebook.com/graphql")!
        let clientTraceId = UUID().uuidString
        let privacySessionId = String(Int(Date().timeIntervalSince1970 * 1000))
        let latencyQpl = String(Int(Date().timeIntervalSince1970 * 1000000))

        let optionId = "40f262f9f9c2c8bab6e9fc22c213a4308f931a6fe9a236cad328e002cd907c7e"
        let clientInputParams: [String: Any] = [
            "privacy_post_param": privacy.privacyId,
            "option_id": optionId,
            "privacy_session_id": privacySessionId,
            "save_default_privacy": 1,
            "creation_session_id": NSNull()
        ]
        let serverParams: [String: Any] = [
            "privacy_write_id": "{\"id\":\"\(postId)\"}",
            "INTERNAL__latency_qpl_marker_id": 36707139,
            "render_location": "BPS_COMPOSER_STANDALONE_EDIT",
            "should_update_privacy_button": 1,
            "should_log_audience_overrides": 1,
            "auto_save": 1,
            "callsite_context": [:],
            "INTERNAL__latency_qpl_instance_id": latencyQpl,
            "use_graphql_for_privacy_save_mutations": 1
        ]
        let innerParams: [String: Any] = [
            "client_input_params": clientInputParams,
            "server_params": serverParams
        ]
        let innerJson = (try? String(data: JSONSerialization.data(withJSONObject: innerParams), encoding: .utf8)) ?? "{}"
        let middleJson = (try? String(data: JSONSerialization.data(withJSONObject: ["params": innerJson]), encoding: .utf8)) ?? "{}"

        let outerParams: [String: Any] = [
            "params": [
                "params": middleJson,
                "bloks_versioning_id": "8d129b12c898b410587535d8971dae35526b73451a4d950f95c1eee58666db21",
                "app_id": "com.bloks.www.fb.privacy.audiences.basic_write"
            ],
            "scale": "1.5",
            "nt_context": [
                "using_white_navbar": true,
                "pixel_ratio": 1.5,
                "is_push_on": true,
                "styles_id": "51609fb901550a6035225e028a3e4fc3",
                "bloks_version": "8d129b12c898b410587535d8971dae35526b73451a4d950f95c1eee58666db21"
            ]
        ]
        let variablesJson = (try? String(data: JSONSerialization.data(withJSONObject: outerParams), encoding: .utf8)) ?? "{}"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (k, v) in fbHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.setValue("OAuth \(accessToken)", forHTTPHeaderField: "authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        request.setValue("graphservice", forHTTPHeaderField: "x-graphql-client-library")

        let postParams: [String: String] = [
            "method": "post",
            "pretty": "false",
            "format": "json",
            "server_timestamps": "true",
            "locale": "vi_VN",
            "fb_api_req_friendly_name": "FbBloksScreenRootQuery-com.bloks.www.fb.privacy.audiences.basic_write",
            "fb_api_caller_class": "graphservice",
            "client_doc_id": "8756910793616235492211993202",
            "variables": variablesJson,
            "client_trace_id": clientTraceId
        ]

        let formPairs = postParams.map { k, v in
            let ek = k.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? k
            let ev = v.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? v
            return "\(ek)=\(ev)"
        }
        request.httpBody = formPairs.joined(separator: "&").data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let respString = String(data: data, encoding: .utf8) ?? ""
        if statusCode == 200 && !respString.contains("\"error\"") {
            return true
        }
        return false
    }
}

// MARK: - Photo Picker Representable

struct SmartPostImagePicker: UIViewControllerRepresentable {
    var onSelected: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = .photoLibrary
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: SmartPostImagePicker
        init(_ parent: SmartPostImagePicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onSelected(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

// MARK: - Smart Post View

struct SmartPostView: View {
    @EnvironmentObject private var library: SpaceLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var selectedSpaceIds: Set<UUID> = []
    @State private var postCaption = ""
    @State private var privacyOption: SmartPostPrivacy = .everyone
    @State private var selectedImages: [UIImage] = []
    @State private var showImagePicker = false

    // Bulk Privacy Mode
    @State private var targetPostIdToUpdatePrivacy = ""
    @State private var isPrivacyOnlyMode = false

    // Running states
    @State private var isPublishing = false
    @State private var progressMessage = ""
    @State private var results: [SmartPostResult] = []
    @State private var alertMessage: String?

    private var availableSpaces: [Space] {
        library.spaces.filter { $0.platform == .facebook }
    }

    private var selectedSpaces: [Space] {
        availableSpaces.filter { selectedSpaceIds.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            Form {
                // Header Banner
                Section {
                    HStack(spacing: 12) {
                        if let img = AppVisualAssets.smartPostImage {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 54, height: 54)
                                .clipShape(Circle())
                                .shadow(color: .orange.opacity(0.3), radius: 4)
                        } else {
                            Image(systemName: "paperplane.fill")
                                .font(.title)
                                .foregroundStyle(.orange)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Smart Post • Quản lý & Đăng bài")
                                .font(.headline)
                            Text("Đăng bài viết kèm ảnh đa tài khoản, đồng bộ quyền riêng tư tự động qua Graph API.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Chế độ thao tác
                Section("Chế độ") {
                    Picker("Hành động", selection: $isPrivacyOnlyMode) {
                        Text("📝 Đăng bài mới").tag(false)
                        Text("🔒 Đổi quyền riêng tư bài có sẵn").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .disabled(isPublishing)
                }

                // 1. Chọn không gian đăng
                Section("1. Chọn tài khoản thực hiện (\(selectedSpaces.count)/\(availableSpaces.count))") {
                    HStack {
                        Button("Chọn tất cả") {
                            selectedSpaceIds = Set(availableSpaces.map(\.id))
                        }
                        .disabled(isPublishing)
                        Spacer()
                        Button("Bỏ chọn") {
                            selectedSpaceIds.removeAll()
                        }
                        .disabled(isPublishing)
                    }
                    .font(.caption.bold())

                    ForEach(availableSpaces) { sp in
                        let summary = VaultMetadataIndex.get(sp.id)
                        let isSelected = selectedSpaceIds.contains(sp.id)
                        Button {
                            if isSelected { selectedSpaceIds.remove(sp.id) }
                            else { selectedSpaceIds.insert(sp.id) }
                        } label: {
                            HStack {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isSelected ? Color.blue : Color.secondary)
                                Image(systemName: sp.platform.icon)
                                    .foregroundStyle(sp.platform.color)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(sp.name).foregroundStyle(.primary)
                                    if summary.hasToken {
                                        Text("Sẵn sàng Token API (\(summary.tokenPrefix.isEmpty ? "App" : summary.tokenPrefix))")
                                            .font(.caption2).foregroundStyle(.green)
                                    } else {
                                        Text("Chưa có Token API — Cần đăng nhập")
                                            .font(.caption2).foregroundStyle(.red)
                                    }
                                }
                                Spacer()
                            }
                        }
                        .disabled(isPublishing)
                    }
                }

                // 2. Nội dung bài viết hoặc đổi quyền riêng tư
                if !isPrivacyOnlyMode {
                    Section("2. Nội dung bài viết") {
                        TextField("Bạn đang nghĩ gì? Nhập nội dung bài viết...", text: $postCaption, axis: .vertical)
                            .lineLimit(3...7)
                            .disabled(isPublishing)

                        Picker("Quyền riêng tư", selection: $privacyOption) {
                            ForEach(SmartPostPrivacy.allCases) { opt in
                                Label(opt.rawValue, systemImage: opt.icon).tag(opt)
                            }
                        }
                        .disabled(isPublishing)

                        // Quản lý ảnh đính kèm
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Ảnh đính kèm (\(selectedImages.count)):")
                                    .font(.caption.bold())
                                Spacer()
                                Button {
                                    showImagePicker = true
                                } label: {
                                    Label("Thêm ảnh", systemImage: "photo.badge.plus")
                                        .font(.caption.bold())
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                                .disabled(isPublishing)
                            }

                            if !selectedImages.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(Array(selectedImages.enumerated()), id: \.offset) { idx, img in
                                            ZStack(alignment: .topTrailing) {
                                                Image(uiImage: img)
                                                    .resizable()
                                                    .scaledToFill()
                                                    .frame(width: 64, height: 64)
                                                    .clipShape(RoundedRectangle(cornerRadius: 8))

                                                Button {
                                                    selectedImages.remove(at: idx)
                                                } label: {
                                                    Image(systemName: "xmark.circle.fill")
                                                        .foregroundStyle(.red)
                                                        .background(Circle().fill(.white))
                                                }
                                                .offset(x: 4, y: -4)
                                                .disabled(isPublishing)
                                            }
                                        }
                                    }
                                    .padding(.top, 4)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } else {
                    Section("2. Đổi quyền riêng tư bài viết") {
                        TextField("Nhập Post ID cần đổi quyền riêng tư...", text: $targetPostIdToUpdatePrivacy)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .disabled(isPublishing)

                        Picker("Quyền mới", selection: $privacyOption) {
                            ForEach(SmartPostPrivacy.allCases) { opt in
                                Label(opt.rawValue, systemImage: opt.icon).tag(opt)
                            }
                        }
                        .disabled(isPublishing)
                    }
                }

                // 3. Tiến trình & Nút Thực Hiện
                Section {
                    if isPublishing {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(progressMessage)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }

                    Button {
                        Task { await executeSmartPost() }
                    } label: {
                        HStack {
                            Spacer()
                            Label(
                                isPrivacyOnlyMode ? "Cập nhật quyền riêng tư bài viết" : "Đăng bài đồng loạt lên các tài khoản",
                                systemImage: isPrivacyOnlyMode ? "lock.rotation" : "paperplane.fill"
                            )
                            .font(.headline)
                            .foregroundStyle(.white)
                            Spacer()
                        }
                        .padding(.vertical, 6)
                    }
                    .listRowBackground(canSubmit ? Color.orange : Color.gray.opacity(0.3))
                    .disabled(!canSubmit)
                }

                // 4. Kết quả đăng tải
                if !results.isEmpty {
                    Section("Kết quả thực hiện (\(results.filter(\.isSuccess).count)/\(results.count) thành công)") {
                        ForEach(results) { res in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: res.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundStyle(res.isSuccess ? Color.green : Color.red)
                                    Text(res.spaceName)
                                        .font(.subheadline.bold())
                                    Spacer()
                                    if let pid = res.postId {
                                        Text("ID: \(pid)")
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Text(res.message)
                                    .font(.caption)
                                    .foregroundStyle(res.isSuccess ? Color.secondary : Color.red)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .navigationTitle("Smart Post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Đóng") { dismiss() }
                        .disabled(isPublishing)
                }
            }
            .sheet(isPresented: $showImagePicker) {
                SmartPostImagePicker { img in
                    selectedImages.append(img)
                }
            }
            .alert("Thông báo", isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )) {
                Button("OK") { alertMessage = nil }
            } message: {
                Text(alertMessage ?? "")
            }
            .onAppear {
                if selectedSpaceIds.isEmpty {
                    selectedSpaceIds = Set(availableSpaces.map(\.id))
                }
            }
        }
    }

    private var canSubmit: Bool {
        guard !isPublishing, !selectedSpaces.isEmpty else { return false }
        if isPrivacyOnlyMode {
            return !targetPostIdToUpdatePrivacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } else {
            return !postCaption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !selectedImages.isEmpty
        }
    }

    @MainActor
    private func executeSmartPost() async {
        isPublishing = true
        results.removeAll()
        defer { isPublishing = false }

        for (idx, space) in selectedSpaces.enumerated() {
            progressMessage = "Đang xử lý (\(idx + 1)/\(selectedSpaces.count)): \(space.name)..."

            guard let vault = try? SecureLoginStore.readTokenVault(space.id),
                  !vault.originalToken.isEmpty else {
                results.append(SmartPostResult(
                    spaceName: space.name,
                    isSuccess: false,
                    postId: nil,
                    postUrl: nil,
                    message: "Chưa có Access Token API."
                ))
                continue
            }

            let token = vault.originalToken
            let uid = vault.uid.isEmpty ? "me" : vault.uid

            if isPrivacyOnlyMode {
                // Update Privacy
                do {
                    let ok = try await SmartPostAPIClient.updatePostPrivacy(
                        postId: targetPostIdToUpdatePrivacy.trimmingCharacters(in: .whitespacesAndNewlines),
                        privacy: privacyOption,
                        accessToken: token
                    )
                    results.append(SmartPostResult(
                        spaceName: space.name,
                        isSuccess: ok,
                        postId: targetPostIdToUpdatePrivacy,
                        postUrl: nil,
                        message: ok ? "Đã đổi sang \(privacyOption.rawValue)" : "Facebook từ chối cập nhật"
                    ))
                } catch {
                    results.append(SmartPostResult(
                        spaceName: space.name,
                        isSuccess: false,
                        postId: targetPostIdToUpdatePrivacy,
                        postUrl: nil,
                        message: error.localizedDescription
                    ))
                }
            } else {
                // Create Post
                do {
                    var uploadedPhotoIds: [String] = []
                    for (pIdx, uiImg) in selectedImages.enumerated() {
                        progressMessage = "\(space.name): Đang tải ảnh \(pIdx + 1)/\(selectedImages.count)..."
                        if let jpegData = uiImg.jpegData(compressionQuality: 0.85) {
                            let photoId = try await SmartPostAPIClient.uploadPhoto(imageData: jpegData, accessToken: token)
                            uploadedPhotoIds.append(photoId)
                        }
                    }

                    progressMessage = "\(space.name): Đang tạo bài viết trên Facebook..."
                    let res = try await SmartPostAPIClient.createPost(
                        caption: postCaption,
                        photoIds: uploadedPhotoIds,
                        privacy: privacyOption,
                        accessToken: token,
                        userId: uid
                    )

                    results.append(SmartPostResult(
                        spaceName: space.name,
                        isSuccess: true,
                        postId: res.postId,
                        postUrl: res.postUrl,
                        message: "Đăng thành công! (\(privacyOption.rawValue))"
                    ))
                } catch {
                    results.append(SmartPostResult(
                        spaceName: space.name,
                        isSuccess: false,
                        postId: nil,
                        postUrl: nil,
                        message: error.localizedDescription
                    ))
                }
            }
        }
        progressMessage = "Hoàn tất!"
    }
}
