import SwiftUI
import Foundation
import UIKit
import PhotosUI

// MARK: - Smart Post Models & Privacy Options

enum SmartPostPrivacy: String, CaseIterable, Identifiable, Codable {
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

struct SmartPostResult: Identifiable, Codable {
    var id: UUID = UUID()
    let spaceName: String
    let isSuccess: Bool
    let postId: String?
    let postUrl: String?
    let message: String
}

// MARK: - Scheduled Post Models

enum ScheduledTaskStatus: String, Codable {
    case pending = "Chờ đăng"
    case running = "Đang chạy"
    case completed = "Hoàn thành"
    case failed = "Thất bại"

    var badgeColor: Color {
        switch self {
        case .pending: return .blue
        case .running: return .orange
        case .completed: return .green
        case .failed: return .red
        }
    }
}

struct ScheduledPostTask: Identifiable, Codable {
    var id: UUID = UUID()
    var title: String
    var caption: String
    var targetSpaceIds: [UUID]
    var privacy: SmartPostPrivacy
    var scheduledDate: Date
    var status: ScheduledTaskStatus
    var imageFileNames: [String]
    var videoFileName: String?
    var createdAt: Date = Date()
    var executionLog: String?
}

// MARK: - Scheduled Post Storage Manager

@MainActor
final class ScheduledPostManager: ObservableObject {
    static let shared = ScheduledPostManager()

    @Published var tasks: [ScheduledPostTask] = []
    private let storageKey = "vie.smartpost.scheduled_tasks.v1"
    private var timer: Timer?

    init() {
        loadTasks()
        startScheduler()
    }

    func loadTasks() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([ScheduledPostTask].self, from: data) {
            self.tasks = decoded
        }
    }

    func saveTasks() {
        if let data = try? JSONEncoder().encode(tasks) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    func addTask(
        caption: String,
        spaceIds: [UUID],
        privacy: SmartPostPrivacy,
        scheduledDate: Date,
        images: [UIImage],
        videoData: Data?
    ) {
        var savedImageNames: [String] = []
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

        for img in images {
            let name = "sp_img_\(UUID().uuidString).jpg"
            if let data = img.jpegData(compressionQuality: 0.85) {
                let fileURL = documentsDir.appendingPathComponent(name)
                try? data.write(to: fileURL)
                savedImageNames.append(name)
            }
        }

        var savedVideoName: String? = nil
        if let vdata = videoData {
            let name = "sp_vid_\(UUID().uuidString).mp4"
            let fileURL = documentsDir.appendingPathComponent(name)
            try? vdata.write(to: fileURL)
            savedVideoName = name
        }

        let title = caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (savedVideoName != nil ? "Video bài đăng" : "\(savedImageNames.count) Ảnh bài đăng")
            : String(caption.prefix(40))

        let newTask = ScheduledPostTask(
            title: title,
            caption: caption,
            targetSpaceIds: spaceIds,
            privacy: privacy,
            scheduledDate: scheduledDate,
            status: .pending,
            imageFileNames: savedImageNames,
            videoFileName: savedVideoName
        )

        tasks.append(newTask)
        saveTasks()
    }

    func deleteTask(_ task: ScheduledPostTask) {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for name in task.imageFileNames {
            try? FileManager.default.removeItem(at: documentsDir.appendingPathComponent(name))
        }
        if let vname = task.videoFileName {
            try? FileManager.default.removeItem(at: documentsDir.appendingPathComponent(vname))
        }
        tasks.removeAll { $0.id == task.id }
        saveTasks()
    }

    private func startScheduler() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkAndExecuteDueTasks()
            }
        }
    }

    func checkAndExecuteDueTasks() async {
        let now = Date()
        for idx in tasks.indices {
            var task = tasks[idx]
            if task.status == .pending && task.scheduledDate <= now {
                tasks[idx].status = .running
                saveTasks()

                let resultLog = await executeTask(task)
                tasks[idx].status = resultLog.allSuccess ? .completed : .failed
                tasks[idx].executionLog = resultLog.summary
                saveTasks()
            }
        }
    }

    private func executeTask(_ task: ScheduledPostTask) async -> (allSuccess: Bool, summary: String) {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var loadedImages: [UIImage] = []
        for name in task.imageFileNames {
            let fileURL = documentsDir.appendingPathComponent(name)
            if let data = try? Data(contentsOf: fileURL), let img = UIImage(data: data) {
                loadedImages.append(img)
            }
        }

        var loadedVideoData: Data? = nil
        if let vname = task.videoFileName {
            let fileURL = documentsDir.appendingPathComponent(vname)
            loadedVideoData = try? Data(contentsOf: fileURL)
        }

        var successCount = 0
        var totalCount = 0
        var logs: [String] = []

        for sid in task.targetSpaceIds {
            totalCount += 1
            guard let vault = try? SecureLoginStore.readTokenVault(sid), !vault.originalToken.isEmpty else {
                logs.append("Không tìm thấy token cho không gian ID: \(sid)")
                continue
            }
            let token = vault.originalToken
            let uid = vault.uid.isEmpty ? "me" : vault.uid

            do {
                if let vdata = loadedVideoData {
                    let vid = try await SmartPostAPIClient.uploadVideo(videoData: vdata, caption: task.caption, accessToken: token, userId: uid)
                    successCount += 1
                    logs.append("✅ Đăng video thành công ID: \(vid)")
                } else {
                    var pids: [String] = []
                    for img in loadedImages {
                        if let jdata = img.jpegData(compressionQuality: 0.85) {
                            let pid = try await SmartPostAPIClient.uploadPhoto(imageData: jdata, accessToken: token)
                            pids.append(pid)
                        }
                    }
                    let res = try await SmartPostAPIClient.createPost(caption: task.caption, photoIds: pids, privacy: task.privacy, accessToken: token, userId: uid)
                    successCount += 1
                    logs.append("✅ Đăng bài thành công ID: \(res.postId)")
                }
            } catch {
                logs.append("❌ Lỗi: \(error.localizedDescription)")
            }
        }

        let allSuccess = successCount == totalCount && totalCount > 0
        let summary = "Kết quả: \(successCount)/\(totalCount) thành công lúc \(Date().formatted(date: .numeric, time: .shortened))\n" + logs.joined(separator: "\n")
        return (allSuccess, summary)
    }
}

// MARK: - Smart Post API Engine

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

    /// Đăng Video lên Facebook qua Graph API /me/videos (chuẩn Video Uploader)
    static func uploadVideo(
        videoData: Data,
        caption: String,
        accessToken: String,
        userId: String
    ) async throws -> String {
        let url = URL(string: "https://graph-video.facebook.com/v19.0/\(userId)/videos")!
        let boundary = "Boundary-\(UUID().uuidString)"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (k, v) in fbHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.setValue("OAuth \(accessToken)", forHTTPHeaderField: "authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "content-type")

        var body = Data()
        let fields: [String: String] = [
            "description": caption,
            "title": String(caption.prefix(30)),
            "published": "true"
        ]

        for (k, v) in fields {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(k)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(v)\r\n".data(using: .utf8)!)
        }

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"source\"; filename=\"video.mp4\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: video/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(videoData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let videoId = json["id"] as? String {
            return videoId
        } else {
            let errText = String(data: data, encoding: .utf8) ?? "HTTP \(statusCode)"
            throw NSError(domain: "SmartPost", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "Lỗi đăng video: \(errText.prefix(140))"])
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

        if let directJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let d = directJson["data"] as? [String: Any],
           let sc = d["story_create"] as? [String: Any],
           let story = sc["story"] as? [String: Any] {
            let pid = (story["id"] as? String) ?? (story["legacy_api_story_id"] as? String) ?? ""
            let purl = story["url"] as? String
            return (pid.isEmpty ? "Đã đăng thành công" : pid, purl)
        }

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

// MARK: - Multiple Photos & Video Picker (PHPickerViewController)

struct SmartPostMediaPicker: UIViewControllerRepresentable {
    var onImagesPicked: ([UIImage]) -> Void
    var onVideoPicked: (Data) -> Void
    var filterType: PHPickerFilter

    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = 15 // Hỗ trợ chọn tối đa 15 ảnh
        config.filter = filterType
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: SmartPostMediaPicker
        init(_ parent: SmartPostMediaPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            guard !results.isEmpty else { return }

            var collectedImages: [UIImage] = []
            let group = DispatchGroup()

            for result in results {
                let provider = result.itemProvider
                if provider.canLoadObject(ofClass: UIImage.self) {
                    group.enter()
                    provider.loadObject(ofClass: UIImage.self) { image, _ in
                        if let img = image as? UIImage {
                            DispatchQueue.main.async { collectedImages.append(img) }
                        }
                        group.leave()
                    }
                } else if provider.hasItemConformingToTypeIdentifier("public.movie") {
                    provider.loadFileRepresentation(forTypeIdentifier: "public.movie") { url, _ in
                        if let fileURL = url, let videoData = try? Data(contentsOf: fileURL) {
                            DispatchQueue.main.async {
                                self.parent.onVideoPicked(videoData)
                            }
                        }
                    }
                }
            }

            group.notify(queue: .main) {
                if !collectedImages.isEmpty {
                    self.parent.onImagesPicked(collectedImages)
                }
            }
        }
    }
}

// MARK: - Smart Post Main View

struct SmartPostView: View {
    @EnvironmentObject private var library: SpaceLibrary
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scheduler = ScheduledPostManager.shared

    // Navigation Tabs
    @State private var selectedTab = 0 // 0: Đăng ngay / Lên lịch, 1: Quản lý lịch đăng

    // Selection
    @State private var selectedSpaceIds: Set<UUID> = []
    @State private var postCaption = ""
    @State private var privacyOption: SmartPostPrivacy = .everyone

    // Media
    @State private var selectedImages: [UIImage] = []
    @State private var selectedVideoData: Data? = nil
    @State private var showPhotoPicker = false
    @State private var showVideoPicker = false

    // Scheduling
    @State private var isScheduling = false
    @State private var scheduledDate = Date().addingTimeInterval(3600)

    // Bulk Privacy Mode
    @State private var isPrivacyOnlyMode = false
    @State private var targetPostIdToUpdatePrivacy = ""

    // Publishing states
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
            VStack(spacing: 0) {
                // Segment Switcher
                Picker("Chế độ", selection: $selectedTab) {
                    Text("📝 Soạn & Đăng bài").tag(0)
                    Text("📅 Quản lý lịch (\(scheduler.tasks.count))").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                if selectedTab == 0 {
                    composeForm
                } else {
                    scheduleManagerView
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
            .sheet(isPresented: $showPhotoPicker) {
                SmartPostMediaPicker(
                    onImagesPicked: { imgs in
                        selectedVideoData = nil // Nếu chọn ảnh thì xóa video
                        selectedImages.append(contentsOf: imgs)
                    },
                    onVideoPicked: { _ in },
                    filterType: .images
                )
            }
            .sheet(isPresented: $showVideoPicker) {
                SmartPostMediaPicker(
                    onImagesPicked: { _ in },
                    onVideoPicked: { vdata in
                        selectedImages.removeAll() // Nếu chọn video thì bỏ ảnh
                        selectedVideoData = vdata
                    },
                    filterType: .videos
                )
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

    // MARK: - Compose Form View

    @ViewBuilder
    private var composeForm: some View {
        Form {
            // Header Info
            Section {
                HStack(spacing: 12) {
                    if let img = AppVisualAssets.smartPostImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 52, height: 52)
                            .clipShape(Circle())
                            .shadow(color: .orange.opacity(0.3), radius: 4)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Smart Post • Đăng đa tài khoản & Lên lịch")
                            .font(.headline)
                        Text("Hỗ trợ đăng nhiều ảnh, video MP4, đặt lịch đăng tự động và đổi quyền riêng tư.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }

            // Chế độ thao tác
            Section("Loại thao tác") {
                Picker("Hành động", selection: $isPrivacyOnlyMode) {
                    Text("📝 Đăng bài mới").tag(false)
                    Text("🔒 Đổi quyền riêng tư").tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(isPublishing)
            }

            // Chọn tài khoản
            Section("1. Chọn tài khoản thực hiện (\(selectedSpaces.count)/\(availableSpaces.count))") {
                HStack {
                    Button("Chọn tất cả") { selectedSpaceIds = Set(availableSpaces.map(\.id)) }
                    Spacer()
                    Button("Bỏ chọn") { selectedSpaceIds.removeAll() }
                }
                .font(.caption.bold())
                .disabled(isPublishing)

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
                                    Text("Sẵn sàng API (\(summary.tokenPrefix.isEmpty ? "App" : summary.tokenPrefix))")
                                        .font(.caption2).foregroundStyle(.green)
                                } else {
                                    Text("Chưa có Token API")
                                        .font(.caption2).foregroundStyle(.red)
                                }
                            }
                            Spacer()
                        }
                    }
                    .disabled(isPublishing)
                }
            }

            // Nội dung
            if !isPrivacyOnlyMode {
                Section("2. Nội dung bài viết") {
                    TextField("Nhập nội dung chia sẻ...", text: $postCaption, axis: .vertical)
                        .lineLimit(3...7)
                        .disabled(isPublishing)

                    Picker("Quyền riêng tư", selection: $privacyOption) {
                        ForEach(SmartPostPrivacy.allCases) { opt in
                            Label(opt.rawValue, systemImage: opt.icon).tag(opt)
                        }
                    }
                    .disabled(isPublishing)

                    // Quản lý Media (Ảnh & Video)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Đính kèm Media:")
                                .font(.caption.bold())
                            Spacer()
                            Button {
                                showPhotoPicker = true
                            } label: {
                                Label("Thêm ảnh (\(selectedImages.count))", systemImage: "photo.stack")
                                    .font(.caption.bold())
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .disabled(isPublishing)

                            Button {
                                showVideoPicker = true
                            } label: {
                                Label(selectedVideoData != nil ? "Đã chọn video" : "Chọn video", systemImage: "video.badge.plus")
                                    .font(.caption.bold())
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .tint(selectedVideoData != nil ? .green : .blue)
                            .disabled(isPublishing)
                        }

                        // Preview Video
                        if selectedVideoData != nil {
                            HStack {
                                Image(systemName: "video.fill")
                                    .font(.title2)
                                    .foregroundStyle(.purple)
                                VStack(alignment: .leading) {
                                    Text("Đã đính kèm 1 Video MP4")
                                        .font(.caption.bold())
                                    Text("Dung lượng: ~\(Int((selectedVideoData?.count ?? 0) / 1024 / 1024)) MB")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    selectedVideoData = nil
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.red)
                                }
                            }
                            .padding(8)
                            .background(Color.purple.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                        }

                        // Preview Ảnh
                        if !selectedImages.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(Array(selectedImages.enumerated()), id: \.offset) { idx, img in
                                        ZStack(alignment: .topTrailing) {
                                            Image(uiImage: img)
                                                .resizable()
                                                .scaledToFill()
                                                .frame(width: 60, height: 60)
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

                // Lên lịch đăng
                Section("3. Hẹn giờ / Lên lịch đăng tự động") {
                    Toggle("Bật lên lịch đăng", isOn: $isScheduling)
                        .disabled(isPublishing)

                    if isScheduling {
                        DatePicker("Thời gian đăng", selection: $scheduledDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                            .datePickerStyle(.compact)
                        Text("Hệ thống sẽ tự động đăng bài theo đúng giờ đã hẹn ngay cả khi không thao tác thủ công.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section("2. Đổi quyền riêng tư bài viết") {
                    TextField("Nhập Post ID cần đổi quyền...", text: $targetPostIdToUpdatePrivacy)
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

            // Nút thực hiện
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
                    if isScheduling && !isPrivacyOnlyMode {
                        schedulePost()
                    } else {
                        Task { await executeSmartPost() }
                    }
                } label: {
                    HStack {
                        Spacer()
                        Label(
                            isPrivacyOnlyMode ? "Cập nhật quyền riêng tư" :
                                (isScheduling ? "Lưu vào Lịch Đăng Tự Động" : "Đăng ngay lên các tài khoản"),
                            systemImage: isPrivacyOnlyMode ? "lock.rotation" :
                                (isScheduling ? "calendar.badge.clock" : "paperplane.fill")
                        )
                        .font(.headline)
                        .foregroundStyle(.white)
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
                .listRowBackground(canSubmit ? (isScheduling ? Color.blue : Color.orange) : Color.gray.opacity(0.3))
                .disabled(!canSubmit)
            }

            // Kết quả trực tiếp
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
    }

    // MARK: - Schedule Manager View

    @ViewBuilder
    private var scheduleManagerView: some View {
        List {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Quản lý danh sách lịch đăng")
                            .font(.headline)
                        Text("Hệ thống tự động kiểm tra và đăng theo mốc thời gian.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Kiểm tra ngay") {
                        Task { await scheduler.checkAndExecuteDueTasks() }
                    }
                    .font(.caption.bold())
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }

            if scheduler.tasks.isEmpty {
                ContentUnavailableView(
                    "Chưa có lịch đăng nào",
                    systemImage: "calendar.badge.clock",
                    description: Text("Hãy vào mục 'Soạn & Đăng bài' và bật 'Lên lịch đăng tự động' để tạo lịch.")
                )
            } else {
                ForEach(scheduler.tasks) { task in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(task.title)
                                .font(.subheadline.bold())
                                .lineLimit(1)
                            Spacer()
                            Text(task.status.rawValue)
                                .font(.caption2.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(task.status.badgeColor.opacity(0.15), in: Capsule())
                                .foregroundStyle(task.status.badgeColor)
                        }

                        HStack(spacing: 8) {
                            Label(task.scheduledDate.formatted(date: .numeric, time: .shortened), systemImage: "clock")
                                .font(.caption)
                                .foregroundStyle(.blue)
                            Text("•")
                            Text("\(task.targetSpaceIds.count) tài khoản")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if task.videoFileName != nil {
                                Text("• Video MP4").font(.caption).foregroundStyle(.purple)
                            } else if !task.imageFileNames.isEmpty {
                                Text("• \(task.imageFileNames.count) ảnh").font(.caption).foregroundStyle(.orange)
                            }
                        }

                        if !task.caption.isEmpty {
                            Text(task.caption)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        if let log = task.executionLog {
                            Text(log)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.gray)
                                .padding(6)
                                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(.vertical, 4)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            scheduler.deleteTask(task)
                        } label: {
                            Label("Xóa", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private var canSubmit: Bool {
        guard !isPublishing, !selectedSpaces.isEmpty else { return false }
        if isPrivacyOnlyMode {
            return !targetPostIdToUpdatePrivacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } else {
            return !postCaption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !selectedImages.isEmpty || selectedVideoData != nil
        }
    }

    private func schedulePost() {
        scheduler.addTask(
            caption: postCaption,
            spaceIds: selectedSpaces.map(\.id),
            privacy: privacyOption,
            scheduledDate: scheduledDate,
            images: selectedImages,
            videoData: selectedVideoData
        )
        alertMessage = "Đã lên lịch đăng thành công vào lúc \(scheduledDate.formatted(date: .numeric, time: .shortened))!"
        selectedTab = 1 // Chuyển sang xem danh sách lịch
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
                        message: ok ? "Đã đổi sang \(privacyOption.rawValue)" : "Facebook từ chối"
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
            } else if let vdata = selectedVideoData {
                // Đăng Video
                do {
                    progressMessage = "\(space.name): Đang đăng Video MP4 lên Facebook..."
                    let videoId = try await SmartPostAPIClient.uploadVideo(
                        videoData: vdata,
                        caption: postCaption,
                        accessToken: token,
                        userId: uid
                    )
                    results.append(SmartPostResult(
                        spaceName: space.name,
                        isSuccess: true,
                        postId: videoId,
                        postUrl: "https://www.facebook.com/watch/?v=\(videoId)",
                        message: "Đăng Video thành công!"
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
            } else {
                // Đăng nhiều ảnh / status
                do {
                    var uploadedPhotoIds: [String] = []
                    for (pIdx, uiImg) in selectedImages.enumerated() {
                        progressMessage = "\(space.name): Đang tải ảnh \(pIdx + 1)/\(selectedImages.count)..."
                        if let jpegData = uiImg.jpegData(compressionQuality: 0.85) {
                            let photoId = try await SmartPostAPIClient.uploadPhoto(imageData: jpegData, accessToken: token)
                            uploadedPhotoIds.append(photoId)
                        }
                    }

                    progressMessage = "\(space.name): Đang xuất bản bài viết..."
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
