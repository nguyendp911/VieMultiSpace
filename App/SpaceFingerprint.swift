import Foundation
import UIKit

// MARK: - Device Model Presets

enum DeviceModelPreset: String, Codable, CaseIterable, Identifiable {
    case iPhone16ProMax = "iPhone 16 Pro Max (A18 Pro - iOS 18.2)"
    case iPhone16Pro = "iPhone 16 Pro (A18 Pro - iOS 18.1)"
    case iPhone16 = "iPhone 16 (A18 - iOS 18.1)"
    case iPhone15ProMax = "iPhone 15 Pro Max (A17 Pro - iOS 17.6)"
    case iPhone15Pro = "iPhone 15 Pro (A17 Pro - iOS 17.5)"
    case iPhone15 = "iPhone 15 (A16 Bionic - iOS 17.5)"
    case iPhone14ProMax = "iPhone 14 Pro Max (A16 Bionic - iOS 17.4)"
    case iPhone14 = "iPhone 14 (A15 Bionic - iOS 17.2)"
    case iPhone13Pro = "iPhone 13 Pro (A15 Bionic - iOS 16.7)"
    case iPhone13 = "iPhone 13 (A15 Bionic - iOS 16.6)"
    case iPadProM4 = "iPad Pro 13 inch (Apple M4 - iPadOS 18.1)"
    case iPadPro129 = "iPad Pro 12.9 inch (M2 - iPadOS 17.5)"
    case galaxyS24Ultra = "Samsung Galaxy S24 Ultra (Snapdragon 8 Gen 3)"
    case pixel9Pro = "Google Pixel 9 Pro (Tensor G4 - Android 15)"
    case macBookProM3 = "MacBook Pro 16 inch (M3 Max - macOS 15.1)"
    case custom = "Tùy chỉnh thông số riêng"

    var id: String { rawValue }

    var shortName: String {
        switch self {
        case .iPhone16ProMax: return "iPhone 16 Pro Max"
        case .iPhone16Pro: return "iPhone 16 Pro"
        case .iPhone16: return "iPhone 16"
        case .iPhone15ProMax: return "iPhone 15 Pro Max"
        case .iPhone15Pro: return "iPhone 15 Pro"
        case .iPhone15: return "iPhone 15"
        case .iPhone14ProMax: return "iPhone 14 Pro Max"
        case .iPhone14: return "iPhone 14"
        case .iPhone13Pro: return "iPhone 13 Pro"
        case .iPhone13: return "iPhone 13"
        case .iPadProM4: return "iPad Pro 13 (M4)"
        case .iPadPro129: return "iPad Pro 12.9"
        case .galaxyS24Ultra: return "Galaxy S24 Ultra"
        case .pixel9Pro: return "Pixel 9 Pro"
        case .macBookProM3: return "MacBook Pro M3"
        case .custom: return "Tùy chỉnh"
        }
    }

    var isMobile: Bool {
        switch self {
        case .macBookProM3: return false
        default: return true
        }
    }

    var isAndroid: Bool {
        switch self {
        case .galaxyS24Ultra, .pixel9Pro: return true
        default: return false
        }
    }
}

// MARK: - Trust Audit Report

struct TrustAuditReport: Hashable {
    let score: Int // 0 - 100
    let level: String // "Tuyệt đối (100%)", "Rất cao (90%)", v.v.
    let statusBadgeColorName: String // "green", "blue", "orange", "red"
    let checks: [TrustCheckItem]
}

struct TrustCheckItem: Hashable, Identifiable {
    var id: String { name }
    let name: String
    let passed: Bool
    let detail: String
}

// MARK: - Space Fingerprint Model

struct SpaceFingerprint: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var preset: DeviceModelPreset = .iPhone16Pro
    var osFamily: String = "iOS"
    var osVersion: String = "18.1"
    var deviceModel: String = "iPhone17,1"

    var userAgent: String
    var appVersion: String
    var platform: String = "iPhone"
    var vendor: String = "Apple Computer, Inc."

    // Màn hình & Hiển thị
    var screenWidth: Int
    var screenHeight: Int
    var screenScale: Double
    var colorDepth: Int = 30
    var pixelDepth: Int = 30

    // Phần cứng
    var hardwareConcurrency: Int // Số nhân CPU (4, 6, 8, 10, 14)
    var deviceMemory: Int         // Dung lượng RAM tính theo GB (4, 6, 8, 12, 16, 36)
    var maxTouchPoints: Int = 5

    // WebGL
    var webGLVendor: String = "Apple Inc."
    var webGLRenderer: String

    // Hạt giống nhiễu bảo vệ độc nhất theo không gian (4 lớp bảo vệ độc lập)
    var canvasSeed: UInt32
    var audioSeed: UInt32
    var fontSeed: UInt32
    var webglSeed: UInt32

    // Định danh thiết bị Android FB4A (cho Meta API, 2FA, GraphQL)
    var androidDeviceId: String
    var androidAdid: String
    var androidSimSerial: String
    var androidBuildModel: String
    var androidBrand: String

    // Thiết bị Ngoại vi Ảo (Cameras, Mics, Speakers)
    var audioInputDeviceId: String
    var videoInputDeviceId: String
    var audioOutputDeviceId: String
    var audioInputLabel: String
    var videoInputLabel: String
    var audioOutputLabel: String

    // Ngôn ngữ & Múi giờ
    var timeZone: String = "Asia/Ho_Chi_Minh"
    var timeZoneOffsetMinutes: Int = -420
    var languages: [String] = ["vi-VN", "vi", "en-US", "en"]

    // Mạng mô phỏng
    var connectionType: String = "4g"
    var downlinkSpeed: Double = 10.0
    var rttMs: Int = 45

    // Bật/tắt các lớp bảo vệ dấu vân tay
    var canvasNoiseEnabled: Bool = true
    var audioNoiseEnabled: Bool = true
    var fontNoiseEnabled: Bool = true
    var webGLSpoofingEnabled: Bool = true
    var webGLNoiseEnabled: Bool = true
    var webrtcProtectionEnabled: Bool = true
    var mediaDevicesProtectionEnabled: Bool = true
    var clientHintsProtectionEnabled: Bool = true

    // MARK: - Initializer

    init(
        id: UUID = UUID(),
        preset: DeviceModelPreset = .iPhone16Pro,
        osFamily: String = "iOS",
        osVersion: String = "18.1",
        deviceModel: String = "iPhone17,1",
        userAgent: String,
        appVersion: String,
        platform: String = "iPhone",
        vendor: String = "Apple Computer, Inc.",
        screenWidth: Int,
        screenHeight: Int,
        screenScale: Double,
        colorDepth: Int = 30,
        pixelDepth: Int = 30,
        hardwareConcurrency: Int,
        deviceMemory: Int,
        maxTouchPoints: Int = 5,
        webGLVendor: String = "Apple Inc.",
        webGLRenderer: String,
        canvasSeed: UInt32,
        audioSeed: UInt32,
        fontSeed: UInt32? = nil,
        webglSeed: UInt32? = nil,
        androidDeviceId: String? = nil,
        androidAdid: String? = nil,
        androidSimSerial: String? = nil,
        androidBuildModel: String? = nil,
        androidBrand: String? = nil,
        audioInputDeviceId: String? = nil,
        videoInputDeviceId: String? = nil,
        audioOutputDeviceId: String? = nil,
        audioInputLabel: String? = nil,
        videoInputLabel: String? = nil,
        audioOutputLabel: String? = nil,
        timeZone: String = "Asia/Ho_Chi_Minh",
        timeZoneOffsetMinutes: Int = -420,
        languages: [String] = ["vi-VN", "vi", "en-US", "en"],
        connectionType: String = "4g",
        downlinkSpeed: Double = 10.0,
        rttMs: Int = 45,
        canvasNoiseEnabled: Bool = true,
        audioNoiseEnabled: Bool = true,
        fontNoiseEnabled: Bool = true,
        webGLSpoofingEnabled: Bool = true,
        webGLNoiseEnabled: Bool = true,
        webrtcProtectionEnabled: Bool = true,
        mediaDevicesProtectionEnabled: Bool = true,
        clientHintsProtectionEnabled: Bool = true
    ) {
        self.id = id
        self.preset = preset
        self.osFamily = osFamily
        self.osVersion = osVersion
        self.deviceModel = deviceModel
        self.userAgent = userAgent
        self.appVersion = appVersion
        self.platform = platform
        self.vendor = vendor
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.screenScale = screenScale
        self.colorDepth = colorDepth
        self.pixelDepth = pixelDepth
        self.hardwareConcurrency = hardwareConcurrency
        self.deviceMemory = deviceMemory
        self.maxTouchPoints = maxTouchPoints
        self.webGLVendor = webGLVendor
        self.webGLRenderer = webGLRenderer

        self.canvasSeed = canvasSeed
        self.audioSeed = audioSeed
        self.fontSeed = fontSeed ?? UInt32(truncatingIfNeeded: canvasSeed &+ 1337)
        self.webglSeed = webglSeed ?? UInt32(truncatingIfNeeded: audioSeed &+ 7919)

        let seedHex = String(format: "%08x", canvasSeed)
        self.androidDeviceId = androidDeviceId ?? "\(seedHex)\(String(format: "%08x", audioSeed))"
        self.androidAdid = androidAdid ?? UUID().uuidString.lowercased()
        self.androidSimSerial = androidSimSerial ?? "898404\(String(format: "%010u", canvasSeed % 1_000_000_000))"
        self.androidBuildModel = androidBuildModel ?? "SM-S928B"
        self.androidBrand = androidBrand ?? "samsung"

        let devSeed = String(format: "%08x%08x", canvasSeed, audioSeed)
        self.audioInputDeviceId = audioInputDeviceId ?? "\(devSeed)a1"
        self.videoInputDeviceId = videoInputDeviceId ?? "\(devSeed)v1"
        self.audioOutputDeviceId = audioOutputDeviceId ?? "\(devSeed)o1"
        self.audioInputLabel = audioInputLabel ?? (preset.isMobile ? "Microphone" : "Built-in Microphone")
        self.videoInputLabel = videoInputLabel ?? (preset.isMobile ? "Back Camera" : "FaceTime HD Camera")
        self.audioOutputLabel = audioOutputLabel ?? (preset.isMobile ? "Speaker" : "Built-in Output")

        self.timeZone = timeZone
        self.timeZoneOffsetMinutes = timeZoneOffsetMinutes
        self.languages = languages
        self.connectionType = connectionType
        self.downlinkSpeed = downlinkSpeed
        self.rttMs = rttMs

        self.canvasNoiseEnabled = canvasNoiseEnabled
        self.audioNoiseEnabled = audioNoiseEnabled
        self.fontNoiseEnabled = fontNoiseEnabled
        self.webGLSpoofingEnabled = webGLSpoofingEnabled
        self.webGLNoiseEnabled = webGLNoiseEnabled
        self.webrtcProtectionEnabled = webrtcProtectionEnabled
        self.mediaDevicesProtectionEnabled = mediaDevicesProtectionEnabled
        self.clientHintsProtectionEnabled = clientHintsProtectionEnabled
    }

    // MARK: - Backward-Compatible Decodable

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        preset = try container.decodeIfPresent(DeviceModelPreset.self, forKey: .preset) ?? .iPhone16Pro
        osFamily = try container.decodeIfPresent(String.self, forKey: .osFamily) ?? "iOS"
        osVersion = try container.decodeIfPresent(String.self, forKey: .osVersion) ?? "18.1"
        deviceModel = try container.decodeIfPresent(String.self, forKey: .deviceModel) ?? "iPhone17,1"

        userAgent = try container.decode(String.self, forKey: .userAgent)
        appVersion = try container.decodeIfPresent(String.self, forKey: .appVersion) ?? userAgent
        platform = try container.decodeIfPresent(String.self, forKey: .platform) ?? "iPhone"
        vendor = try container.decodeIfPresent(String.self, forKey: .vendor) ?? "Apple Computer, Inc."

        screenWidth = try container.decodeIfPresent(Int.self, forKey: .screenWidth) ?? 393
        screenHeight = try container.decodeIfPresent(Int.self, forKey: .screenHeight) ?? 852
        screenScale = try container.decodeIfPresent(Double.self, forKey: .screenScale) ?? 3.0
        colorDepth = try container.decodeIfPresent(Int.self, forKey: .colorDepth) ?? 30
        pixelDepth = try container.decodeIfPresent(Int.self, forKey: .pixelDepth) ?? 30

        hardwareConcurrency = try container.decodeIfPresent(Int.self, forKey: .hardwareConcurrency) ?? 6
        deviceMemory = try container.decodeIfPresent(Int.self, forKey: .deviceMemory) ?? 8
        maxTouchPoints = try container.decodeIfPresent(Int.self, forKey: .maxTouchPoints) ?? 5

        webGLVendor = try container.decodeIfPresent(String.self, forKey: .webGLVendor) ?? "Apple Inc."
        webGLRenderer = try container.decodeIfPresent(String.self, forKey: .webGLRenderer) ?? "Apple GPU (Apple A18 Pro)"

        let cSeed = try container.decodeIfPresent(UInt32.self, forKey: .canvasSeed) ?? 12345
        let aSeed = try container.decodeIfPresent(UInt32.self, forKey: .audioSeed) ?? 67890
        canvasSeed = cSeed
        audioSeed = aSeed
        fontSeed = try container.decodeIfPresent(UInt32.self, forKey: .fontSeed) ?? UInt32(truncatingIfNeeded: cSeed &+ 1337)
        webglSeed = try container.decodeIfPresent(UInt32.self, forKey: .webglSeed) ?? UInt32(truncatingIfNeeded: aSeed &+ 7919)

        let seedHex = String(format: "%08x%08x", cSeed, aSeed)
        androidDeviceId = try container.decodeIfPresent(String.self, forKey: .androidDeviceId) ?? seedHex
        androidAdid = try container.decodeIfPresent(String.self, forKey: .androidAdid) ?? UUID().uuidString.lowercased()
        androidSimSerial = try container.decodeIfPresent(String.self, forKey: .androidSimSerial) ?? "898404\(String(format: "%010u", cSeed % 1_000_000_000))"
        androidBuildModel = try container.decodeIfPresent(String.self, forKey: .androidBuildModel) ?? "SM-S928B"
        androidBrand = try container.decodeIfPresent(String.self, forKey: .androidBrand) ?? "samsung"

        audioInputDeviceId = try container.decodeIfPresent(String.self, forKey: .audioInputDeviceId) ?? "\(seedHex)a1"
        videoInputDeviceId = try container.decodeIfPresent(String.self, forKey: .videoInputDeviceId) ?? "\(seedHex)v1"
        audioOutputDeviceId = try container.decodeIfPresent(String.self, forKey: .audioOutputDeviceId) ?? "\(seedHex)o1"
        audioInputLabel = try container.decodeIfPresent(String.self, forKey: .audioInputLabel) ?? "Microphone"
        videoInputLabel = try container.decodeIfPresent(String.self, forKey: .videoInputLabel) ?? "Back Camera"
        audioOutputLabel = try container.decodeIfPresent(String.self, forKey: .audioOutputLabel) ?? "Speaker"

        timeZone = try container.decodeIfPresent(String.self, forKey: .timeZone) ?? "Asia/Ho_Chi_Minh"
        timeZoneOffsetMinutes = try container.decodeIfPresent(Int.self, forKey: .timeZoneOffsetMinutes) ?? -420
        languages = try container.decodeIfPresent([String].self, forKey: .languages) ?? ["vi-VN", "vi", "en-US", "en"]

        connectionType = try container.decodeIfPresent(String.self, forKey: .connectionType) ?? "4g"
        downlinkSpeed = try container.decodeIfPresent(Double.self, forKey: .downlinkSpeed) ?? 10.0
        rttMs = try container.decodeIfPresent(Int.self, forKey: .rttMs) ?? 45

        canvasNoiseEnabled = try container.decodeIfPresent(Bool.self, forKey: .canvasNoiseEnabled) ?? true
        audioNoiseEnabled = try container.decodeIfPresent(Bool.self, forKey: .audioNoiseEnabled) ?? true
        fontNoiseEnabled = try container.decodeIfPresent(Bool.self, forKey: .fontNoiseEnabled) ?? true
        webGLSpoofingEnabled = try container.decodeIfPresent(Bool.self, forKey: .webGLSpoofingEnabled) ?? true
        webGLNoiseEnabled = try container.decodeIfPresent(Bool.self, forKey: .webGLNoiseEnabled) ?? true
        webrtcProtectionEnabled = try container.decodeIfPresent(Bool.self, forKey: .webrtcProtectionEnabled) ?? true
        mediaDevicesProtectionEnabled = try container.decodeIfPresent(Bool.self, forKey: .mediaDevicesProtectionEnabled) ?? true
        clientHintsProtectionEnabled = try container.decodeIfPresent(Bool.self, forKey: .clientHintsProtectionEnabled) ?? true
    }

    // MARK: - Trust Audit Engine

    var trustReport: TrustAuditReport {
        var score = 0
        var checks: [TrustCheckItem] = []

        // 1. Tính nhất quán Phần cứng & Tỷ lệ hiển thị (20đ)
        let hwValid = hardwareConcurrency >= 4 && deviceMemory >= 4 && screenWidth > 0 && screenHeight > 0
        score += hwValid ? 20 : 10
        checks.append(TrustCheckItem(
            name: "Phần cứng & Độ phân giải",
            passed: hwValid,
            detail: "\(screenWidth)x\(screenHeight) @\(Int(screenScale))x • \(hardwareConcurrency) Nhân • \(deviceMemory)GB RAM"
        ))

        // 2. Lớp bảo vệ Canvas 2D & Font Subpixel (20đ)
        let canvasActive = canvasNoiseEnabled && fontNoiseEnabled && canvasSeed > 0
        score += canvasActive ? 20 : (canvasNoiseEnabled ? 12 : 0)
        checks.append(TrustCheckItem(
            name: "Canvas 2D & Font Subpixel",
            passed: canvasActive,
            detail: canvasActive ? "Hạt giống Seed #\(canvasSeed % 10000) • Chống trích xuất Font" : "Chưa đủ 2 lớp"
        ))

        // 3. Khử vết dấu AudioContext & Analyser (15đ)
        let audioActive = audioNoiseEnabled && audioSeed > 0
        score += audioActive ? 15 : 0
        checks.append(TrustCheckItem(
            name: "Âm thanh AudioContext",
            passed: audioActive,
            detail: audioActive ? "Nhiễu tần số độc nhất Seed #\(audioSeed % 10000)" : "Tắt"
        ))

        // 4. Card đồ họa WebGL Mask & readPixels (15đ)
        let webglActive = webGLSpoofingEnabled && webGLNoiseEnabled
        score += webglActive ? 15 : (webGLSpoofingEnabled ? 10 : 0)
        checks.append(TrustCheckItem(
            name: "WebGL GPU & readPixels",
            passed: webglActive,
            detail: "\(webGLRenderer) • Seed #\(webglSeed % 10000)"
        ))

        // 5. Chống rò rỉ WebRTC IP & Đồng bộ Múi giờ (15đ)
        let netActive = webrtcProtectionEnabled
        score += netActive ? 15 : 0
        let gmtSign = timeZoneOffsetMinutes <= 0 ? "+" : "-"
        let gmtHours = abs(timeZoneOffsetMinutes) / 60
        checks.append(TrustCheckItem(
            name: "WebRTC Shield & Múi giờ",
            passed: netActive,
            detail: "\(timeZone) (GMT\(gmtSign)\(gmtHours)) • Chống lộ IP"
        ))

        // 6. Giả lập Ngoại vi Media Devices (Camera/Mic) (15đ)
        let mediaActive = mediaDevicesProtectionEnabled && !audioInputDeviceId.isEmpty
        score += mediaActive ? 15 : 0
        checks.append(TrustCheckItem(
            name: "Ngoại vi Ảo (Mic / Camera)",
            passed: mediaActive,
            detail: mediaActive ? "3 thiết bị phần cứng độc lập (Mic, Cam, Loa)" : "Mặc định hệ thống"
        ))

        let finalScore = min(100, max(0, score))
        let level: String
        let colorName: String
        switch finalScore {
        case 95...100:
            level = "Tuyệt đối (\(finalScore)%)"
            colorName = "green"
        case 85..<95:
            level = "Rất cao (\(finalScore)%)"
            colorName = "blue"
        case 70..<85:
            level = "Khá (\(finalScore)%)"
            colorName = "orange"
        default:
            level = "Cần tối ưu (\(finalScore)%)"
            colorName = "red"
        }

        return TrustAuditReport(score: finalScore, level: level, statusBadgeColorName: colorName, checks: checks)
    }

    /// Tóm tắt hiển thị trực quan trên UI
    var displaySummary: String {
        return "\(preset.shortName) • 🛡️ \(trustReport.score)% • Seed #\(canvasSeed % 10000)"
    }

    // MARK: - Presets Factory

    static func defaultFor(spaceId: UUID) -> SpaceFingerprint {
        let hash = abs(spaceId.hashValue)
        let allPresets: [DeviceModelPreset] = [
            .iPhone16ProMax,
            .iPhone16Pro,
            .iPhone16,
            .iPhone15ProMax,
            .iPhone15Pro,
            .iPhone15,
            .iPhone14ProMax,
            .galaxyS24Ultra,
            .pixel9Pro
        ]
        let chosenPreset = allPresets[hash % allPresets.count]
        return makePreset(
            preset: chosenPreset,
            canvasSeed: UInt32(truncatingIfNeeded: hash &+ 1013),
            audioSeed: UInt32(truncatingIfNeeded: (hash >> 8) &+ 7919),
            fontSeed: UInt32(truncatingIfNeeded: (hash >> 4) &+ 31337),
            webglSeed: UInt32(truncatingIfNeeded: (hash >> 12) &+ 54321),
            spaceId: spaceId
        )
    }

    static func generateRandom(preset: DeviceModelPreset? = nil) -> SpaceFingerprint {
        let allPresets: [DeviceModelPreset] = [
            .iPhone16ProMax,
            .iPhone16Pro,
            .iPhone16,
            .iPhone15ProMax,
            .iPhone15Pro,
            .iPhone15,
            .iPhone14ProMax,
            .galaxyS24Ultra,
            .pixel9Pro,
            .iPadProM4
        ]
        let chosenPreset = preset ?? allPresets.randomElement() ?? .iPhone16Pro
        let canvasSeed = UInt32.random(in: 10_000...999_999)
        let audioSeed = UInt32.random(in: 10_000...999_999)
        let fontSeed = UInt32.random(in: 10_000...999_999)
        let webglSeed = UInt32.random(in: 10_000...999_999)
        return makePreset(
            preset: chosenPreset,
            canvasSeed: canvasSeed,
            audioSeed: audioSeed,
            fontSeed: fontSeed,
            webglSeed: webglSeed
        )
    }

    static func generateSuperTrust(spaceId: UUID? = nil, preset: DeviceModelPreset? = nil) -> SpaceFingerprint {
        var fp = generateRandom(preset: preset)
        if let sid = spaceId {
            fp.id = sid
        }
        // Kích hoạt toàn bộ các lớp bảo vệ tối đa để đạt 100% Trust
        fp.canvasNoiseEnabled = true
        fp.audioNoiseEnabled = true
        fp.fontNoiseEnabled = true
        fp.webGLSpoofingEnabled = true
        fp.webGLNoiseEnabled = true
        fp.webrtcProtectionEnabled = true
        fp.mediaDevicesProtectionEnabled = true
        fp.clientHintsProtectionEnabled = true
        return fp
    }

    static func makePreset(
        preset: DeviceModelPreset,
        canvasSeed: UInt32,
        audioSeed: UInt32,
        fontSeed: UInt32? = nil,
        webglSeed: UInt32? = nil,
        spaceId: UUID? = nil
    ) -> SpaceFingerprint {
        let fSeed = fontSeed ?? UInt32(truncatingIfNeeded: canvasSeed &+ 1337)
        let wSeed = webglSeed ?? UInt32(truncatingIfNeeded: audioSeed &+ 7919)

        switch preset {
        case .iPhone16ProMax:
            return SpaceFingerprint(
                preset: .iPhone16ProMax,
                osFamily: "iOS",
                osVersion: "18.2",
                deviceModel: "iPhone17,2",
                userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Mobile/15E148 Safari/604.1",
                appVersion: "5.0 (iPhone; CPU iPhone OS 18_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Mobile/15E148 Safari/604.1",
                platform: "iPhone",
                vendor: "Apple Computer, Inc.",
                screenWidth: 430,
                screenHeight: 932,
                screenScale: 3.0,
                hardwareConcurrency: 6,
                deviceMemory: 8,
                webGLVendor: "Apple Inc.",
                webGLRenderer: "Apple GPU (Apple A18 Pro)",
                canvasSeed: canvasSeed,
                audioSeed: audioSeed,
                fontSeed: fSeed,
                webglSeed: wSeed
            )

        case .iPhone16Pro:
            return SpaceFingerprint(
                preset: .iPhone16Pro,
                osFamily: "iOS",
                osVersion: "18.1",
                deviceModel: "iPhone17,1",
                userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1",
                appVersion: "5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1",
                platform: "iPhone",
                vendor: "Apple Computer, Inc.",
                screenWidth: 393,
                screenHeight: 852,
                screenScale: 3.0,
                hardwareConcurrency: 6,
                deviceMemory: 8,
                webGLVendor: "Apple Inc.",
                webGLRenderer: "Apple GPU (Apple A18 Pro)",
                canvasSeed: canvasSeed,
                audioSeed: audioSeed,
                fontSeed: fSeed,
                webglSeed: wSeed
            )

        case .iPhone16:
            return SpaceFingerprint(
                preset: .iPhone16,
                osFamily: "iOS",
                osVersion: "18.1",
                deviceModel: "iPhone17,3",
                userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1",
                appVersion: "5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1",
                platform: "iPhone",
                vendor: "Apple Computer, Inc.",
                screenWidth: 393,
                screenHeight: 852,
                screenScale: 3.0,
                hardwareConcurrency: 6,
                deviceMemory: 8,
                webGLVendor: "Apple Inc.",
                webGLRenderer: "Apple GPU (Apple A18)",
                canvasSeed: canvasSeed,
                audioSeed: audioSeed,
                fontSeed: fSeed,
                webglSeed: wSeed
            )

        case .iPhone15ProMax:
            return SpaceFingerprint(
                preset: .iPhone15ProMax,
                osFamily: "iOS",
                osVersion: "17.6.1",
                deviceModel: "iPhone16,2",
                userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6.1 Mobile/15E148 Safari/604.1",
                appVersion: "5.0 (iPhone; CPU iPhone OS 17_6_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6.1 Mobile/15E148 Safari/604.1",
                platform: "iPhone",
                vendor: "Apple Computer, Inc.",
                screenWidth: 430,
                screenHeight: 932,
                screenScale: 3.0,
                hardwareConcurrency: 6,
                deviceMemory: 8,
                webGLVendor: "Apple Inc.",
                webGLRenderer: "Apple GPU (Apple A17 Pro)",
                canvasSeed: canvasSeed,
                audioSeed: audioSeed,
                fontSeed: fSeed,
                webglSeed: wSeed
            )

        case .iPhone15Pro:
            return SpaceFingerprint(
                preset: .iPhone15Pro,
                osFamily: "iOS",
                osVersion: "17.5.1",
                deviceModel: "iPhone16,1",
                userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5.1 Mobile/15E148 Safari/604.1",
                appVersion: "5.0 (iPhone; CPU iPhone OS 17_5_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5.1 Mobile/15E148 Safari/604.1",
                platform: "iPhone",
                vendor: "Apple Computer, Inc.",
                screenWidth: 393,
                screenHeight: 852,
                screenScale: 3.0,
                hardwareConcurrency: 6,
                deviceMemory: 8,
                webGLVendor: "Apple Inc.",
                webGLRenderer: "Apple GPU (Apple A17 Pro)",
                canvasSeed: canvasSeed,
                audioSeed: audioSeed,
                fontSeed: fSeed,
                webglSeed: wSeed
            )

        case .iPhone15:
            return SpaceFingerprint(
                preset: .iPhone15,
                osFamily: "iOS",
                osVersion: "17.5",
                deviceModel: "iPhone15,4",
                userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1",
                appVersion: "5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1",
                platform: "iPhone",
                vendor: "Apple Computer, Inc.",
                screenWidth: 393,
                screenHeight: 852,
                screenScale: 3.0,
                hardwareConcurrency: 6,
                deviceMemory: 6,
                webGLVendor: "Apple Inc.",
                webGLRenderer: "Apple GPU (Apple A16 Bionic)",
                canvasSeed: canvasSeed,
                audioSeed: audioSeed,
                fontSeed: fSeed,
                webglSeed: wSeed
            )

        case .iPhone14ProMax:
            return SpaceFingerprint(
                preset: .iPhone14ProMax,
                osFamily: "iOS",
                osVersion: "17.4",
                deviceModel: "iPhone15,3",
                userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1",
                appVersion: "5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1",
                platform: "iPhone",
                vendor: "Apple Computer, Inc.",
                screenWidth: 430,
                screenHeight: 932,
                screenScale: 3.0,
                hardwareConcurrency: 6,
                deviceMemory: 6,
                webGLVendor: "Apple Inc.",
                webGLRenderer: "Apple GPU (Apple A16 Bionic)",
                canvasSeed: canvasSeed,
                audioSeed: audioSeed,
                fontSeed: fSeed,
                webglSeed: wSeed
            )

        case .iPhone14:
            return SpaceFingerprint(
                preset: .iPhone14,
                osFamily: "iOS",
                osVersion: "17.2",
                deviceModel: "iPhone14,7",
                userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Mobile/15E148 Safari/604.1",
                appVersion: "5.0 (iPhone; CPU iPhone OS 17_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Mobile/15E148 Safari/604.1",
                platform: "iPhone",
                vendor: "Apple Computer, Inc.",
                screenWidth: 390,
                screenHeight: 844,
                screenScale: 3.0,
                hardwareConcurrency: 6,
                deviceMemory: 6,
                webGLVendor: "Apple Inc.",
                webGLRenderer: "Apple GPU (Apple A15 Bionic)",
                canvasSeed: canvasSeed,
                audioSeed: audioSeed,
                fontSeed: fSeed,
                webglSeed: wSeed
            )

        case .iPhone13Pro:
            return SpaceFingerprint(
                preset: .iPhone13Pro,
                osFamily: "iOS",
                osVersion: "16.7",
                deviceModel: "iPhone14,2",
                userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 16_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.7 Mobile/15E148 Safari/604.1",
                appVersion: "5.0 (iPhone; CPU iPhone OS 16_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.7 Mobile/15E148 Safari/604.1",
                platform: "iPhone",
                vendor: "Apple Computer, Inc.",
                screenWidth: 390,
                screenHeight: 844,
                screenScale: 3.0,
                hardwareConcurrency: 6,
                deviceMemory: 6,
                webGLVendor: "Apple Inc.",
                webGLRenderer: "Apple GPU (Apple A15 Bionic)",
                canvasSeed: canvasSeed,
                audioSeed: audioSeed,
                fontSeed: fSeed,
                webglSeed: wSeed
            )

        case .iPhone13:
            return SpaceFingerprint(
                preset: .iPhone13,
                osFamily: "iOS",
                osVersion: "16.6",
                deviceModel: "iPhone14,5",
                userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1",
                appVersion: "5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1",
                platform: "iPhone",
                vendor: "Apple Computer, Inc.",
                screenWidth: 390,
                screenHeight: 844,
                screenScale: 3.0,
                hardwareConcurrency: 6,
                deviceMemory: 4,
                webGLVendor: "Apple Inc.",
                webGLRenderer: "Apple GPU (Apple A15 Bionic)",
                canvasSeed: canvasSeed,
                audioSeed: audioSeed,
                fontSeed: fSeed,
                webglSeed: wSeed
            )

        case .iPadProM4:
            return SpaceFingerprint(
                preset: .iPadProM4,
                osFamily: "iOS",
                osVersion: "18.1",
                deviceModel: "iPad16,3",
                userAgent: "Mozilla/5.0 (iPad; CPU OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1",
                appVersion: "5.0 (iPad; CPU OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1",
                platform: "iPad",
                vendor: "Apple Computer, Inc.",
                screenWidth: 1024,
                screenHeight: 1366,
                screenScale: 2.0,
                hardwareConcurrency: 10,
                deviceMemory: 16,
                webGLVendor: "Apple Inc.",
                webGLRenderer: "Apple GPU (Apple M4)",
                canvasSeed: canvasSeed,
                audioSeed: audioSeed,
                fontSeed: fSeed,
                webglSeed: wSeed
            )

        case .iPadPro129:
            return SpaceFingerprint(
                preset: .iPadPro129,
                osFamily: "iOS",
                osVersion: "17.5",
                deviceModel: "iPad14,5",
                userAgent: "Mozilla/5.0 (iPad; CPU OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1",
                appVersion: "5.0 (iPad; CPU OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1",
                platform: "iPad",
                vendor: "Apple Computer, Inc.",
                screenWidth: 1024,
                screenHeight: 1366,
                screenScale: 2.0,
                hardwareConcurrency: 8,
                deviceMemory: 16,
                webGLVendor: "Apple Inc.",
                webGLRenderer: "Apple GPU (Apple M2)",
                canvasSeed: canvasSeed,
                audioSeed: audioSeed,
                fontSeed: fSeed,
                webglSeed: wSeed
            )

        case .galaxyS24Ultra:
            return SpaceFingerprint(
                preset: .galaxyS24Ultra,
                osFamily: "Android",
                osVersion: "14.0",
                deviceModel: "SM-S928B",
                userAgent: "Mozilla/5.0 (Linux; Android 14; SM-S928B Build/UP1A.231005.007) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.6723.102 Mobile Safari/537.36",
                appVersion: "5.0 (Linux; Android 14; SM-S928B Build/UP1A.231005.007) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.6723.102 Mobile Safari/537.36",
                platform: "Linux armv8l",
                vendor: "Google Inc.",
                screenWidth: 412,
                screenHeight: 915,
                screenScale: 3.5,
                hardwareConcurrency: 8,
                deviceMemory: 12,
                webGLVendor: "Qualcomm",
                webGLRenderer: "Adreno (TM) 750",
                canvasSeed: canvasSeed,
                audioSeed: audioSeed,
                fontSeed: fSeed,
                webglSeed: wSeed,
                androidBuildModel: "SM-S928B",
                androidBrand: "samsung"
            )

        case .pixel9Pro:
            return SpaceFingerprint(
                preset: .pixel9Pro,
                osFamily: "Android",
                osVersion: "15.0",
                deviceModel: "Pixel 9 Pro",
                userAgent: "Mozilla/5.0 (Linux; Android 15; Pixel 9 Pro Build/AP3A.241005.015) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.6723.102 Mobile Safari/537.36",
                appVersion: "5.0 (Linux; Android 15; Pixel 9 Pro Build/AP3A.241005.015) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.6723.102 Mobile Safari/537.36",
                platform: "Linux armv8l",
                vendor: "Google Inc.",
                screenWidth: 412,
                screenHeight: 915,
                screenScale: 3.5,
                hardwareConcurrency: 8,
                deviceMemory: 16,
                webGLVendor: "ARM",
                webGLRenderer: "Mali-G715",
                canvasSeed: canvasSeed,
                audioSeed: audioSeed,
                fontSeed: fSeed,
                webglSeed: wSeed,
                androidBuildModel: "Pixel 9 Pro",
                androidBrand: "google"
            )

        case .macBookProM3:
            return SpaceFingerprint(
                preset: .macBookProM3,
                osFamily: "macOS",
                osVersion: "15.1",
                deviceModel: "Mac15,9",
                userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Safari/605.1.15",
                appVersion: "5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Safari/605.1.15",
                platform: "MacIntel",
                vendor: "Apple Computer, Inc.",
                screenWidth: 1728,
                screenHeight: 1117,
                screenScale: 2.0,
                hardwareConcurrency: 14,
                deviceMemory: 36,
                maxTouchPoints: 0,
                webGLVendor: "Apple Inc.",
                webGLRenderer: "Apple GPU (Apple M3 Max)",
                canvasSeed: canvasSeed,
                audioSeed: audioSeed,
                fontSeed: fSeed,
                webglSeed: wSeed,
                audioInputLabel: "Built-in Microphone",
                videoInputLabel: "FaceTime HD Camera",
                audioOutputLabel: "Built-in Output"
            )

        case .custom:
            return SpaceFingerprint(
                preset: .custom,
                osFamily: "iOS",
                osVersion: "18.1",
                deviceModel: "iPhone17,1",
                userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1",
                appVersion: "5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1",
                platform: "iPhone",
                vendor: "Apple Computer, Inc.",
                screenWidth: 393,
                screenHeight: 852,
                screenScale: 3.0,
                hardwareConcurrency: 6,
                deviceMemory: 8,
                webGLVendor: "Apple Inc.",
                webGLRenderer: "Apple GPU (Apple A18 Pro)",
                canvasSeed: canvasSeed,
                audioSeed: audioSeed,
                fontSeed: fSeed,
                webglSeed: wSeed
            )
        }
    }

    // MARK: - Anti-Detect JavaScript Generator

    /// Tạo mã JavaScript được tiêm vào WKWebView ở thời điểm `atDocumentStart` để bảo vệ và tạo dấu vân tay độc lập
    func buildAntiDetectScript() -> String {
        let languagesJson = (try? String(data: JSONEncoder().encode(languages), encoding: .utf8)) ?? "[\"vi-VN\", \"vi\"]"

        let escapedUA = userAgent.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let escapedAppVer = appVersion.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let escapedPlatform = platform.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedVendor = vendor.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedWebGLVendor = webGLVendor.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedWebGLRenderer = webGLRenderer.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedTimeZone = timeZone.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedConnType = connectionType.replacingOccurrences(of: "\"", with: "\\\"")

        let escapedAudioInId = audioInputDeviceId.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedVideoInId = videoInputDeviceId.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedAudioOutId = audioOutputDeviceId.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedAudioInLbl = audioInputLabel.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedVideoInLbl = videoInputLabel.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedAudioOutLbl = audioOutputLabel.replacingOccurrences(of: "\"", with: "\\\"")

        // 1. Khối nhiễu Canvas 2D & Font Subpixel
        let canvasBlock = canvasNoiseEnabled ? """
            // 4. Khử vết dấu Canvas 2D & toBlob bằng hạt giống độc nhất
            if (window.HTMLCanvasElement) {
                const origToDataURL = HTMLCanvasElement.prototype.toDataURL;
                HTMLCanvasElement.prototype.toDataURL = function() {
                    try {
                        const ctx = this.getContext('2d');
                        if (ctx && this.width > 0 && this.height > 0) {
                            const img = ctx.getImageData(0, 0, Math.min(this.width, 10), Math.min(this.height, 10));
                            const d = img.data;
                            const offset = (fp.canvasSeed % 3) - 1;
                            if (d.length >= 4) {
                                d[0] = Math.max(0, Math.min(255, d[0] + offset));
                                ctx.putImageData(img, 0, 0);
                            }
                        }
                    } catch(e) {}
                    return origToDataURL.apply(this, arguments);
                };

                const origToBlob = HTMLCanvasElement.prototype.toBlob;
                if (origToBlob) {
                    HTMLCanvasElement.prototype.toBlob = function(callback, type, quality) {
                        try {
                            const ctx = this.getContext('2d');
                            if (ctx && this.width > 0 && this.height > 0) {
                                const img = ctx.getImageData(0, 0, Math.min(this.width, 10), Math.min(this.height, 10));
                                const d = img.data;
                                const offset = (fp.canvasSeed % 3) - 1;
                                if (d.length >= 4) {
                                    d[0] = Math.max(0, Math.min(255, d[0] + offset));
                                    ctx.putImageData(img, 0, 0);
                                }
                            }
                        } catch(e) {}
                        return origToBlob.apply(this, arguments);
                    };
                }

                const origGetImageData = CanvasRenderingContext2D.prototype.getImageData;
                CanvasRenderingContext2D.prototype.getImageData = function() {
                    const res = origGetImageData.apply(this, arguments);
                    if (res && res.data && res.data.length >= 4) {
                        const offset = (fp.canvasSeed % 3) - 1;
                        res.data[0] = Math.max(0, Math.min(255, res.data[0] + offset));
                    }
                    return res;
                };
            }
        """ : ""

        // 2. Khối nhiễu Font Subpixel
        let fontBlock = fontNoiseEnabled ? """
            // 4b. Khử vết dấu Font Fingerprint qua kích thước chữ
            if (window.CanvasRenderingContext2D) {
                const origMeasureText = CanvasRenderingContext2D.prototype.measureText;
                CanvasRenderingContext2D.prototype.measureText = function(text) {
                    const metrics = origMeasureText.apply(this, arguments);
                    const fontOffset = ((fp.fontSeed % 7) - 3) * 0.001;
                    try {
                        const fake = Object.create(metrics);
                        Object.defineProperty(fake, 'width', {
                            get: () => Math.max(0, metrics.width + fontOffset)
                        });
                        return fake;
                    } catch(e) {
                        return metrics;
                    }
                };
            }
        """ : ""

        // 3. Khối nhiễu AudioContext Fingerprint
        let audioBlock = audioNoiseEnabled ? """
            // 5. Khử vết AudioContext & AnalyserNode Fingerprint
            if (window.AudioBuffer) {
                const origGetChannelData = AudioBuffer.prototype.getChannelData;
                AudioBuffer.prototype.getChannelData = function(channel) {
                    const data = origGetChannelData.apply(this, arguments);
                    const noise = ((fp.audioSeed % 100) - 50) * 0.00000001;
                    if (data && data.length > 5) {
                        data[0] += noise;
                        data[4] += noise;
                    }
                    return data;
                };
            }
            if (window.AnalyserNode) {
                const origGetFloatFreq = AnalyserNode.prototype.getFloatFrequencyData;
                if (origGetFloatFreq) {
                    AnalyserNode.prototype.getFloatFrequencyData = function(array) {
                        origGetFloatFreq.apply(this, arguments);
                        if (array && array.length > 2) {
                            const noise = ((fp.audioSeed % 10) - 5) * 0.001;
                            array[0] += noise;
                        }
                    };
                }
            }
        """ : ""

        // 4. Khối WebGL Spoofing & readPixels
        let webglBlock = webGLSpoofingEnabled ? """
            // 3. Giả lập thông số card đồ họa WebGL & readPixels
            const getParamHook = function(origFn) {
                return function(param) {
                    if (param === 37445) return fp.webglVendor;
                    if (param === 37446) return fp.webglRenderer;
                    return origFn.call(this, param);
                };
            };
            if (window.WebGLRenderingContext) {
                WebGLRenderingContext.prototype.getParameter = getParamHook(WebGLRenderingContext.prototype.getParameter);
                \(webGLNoiseEnabled ? """
                const origReadPixels = WebGLRenderingContext.prototype.readPixels;
                WebGLRenderingContext.prototype.readPixels = function() {
                    origReadPixels.apply(this, arguments);
                    const pixels = arguments[6];
                    if (pixels && pixels.length >= 4) {
                        const offset = (fp.webglSeed % 3) - 1;
                        pixels[0] = Math.max(0, Math.min(255, pixels[0] + offset));
                    }
                };
                """ : "")
            }
            if (window.WebGL2RenderingContext) {
                WebGL2RenderingContext.prototype.getParameter = getParamHook(WebGL2RenderingContext.prototype.getParameter);
                \(webGLNoiseEnabled ? """
                const origReadPixels2 = WebGL2RenderingContext.prototype.readPixels;
                WebGL2RenderingContext.prototype.readPixels = function() {
                    origReadPixels2.apply(this, arguments);
                    const pixels = arguments[6];
                    if (pixels && pixels.length >= 4) {
                        const offset = (fp.webglSeed % 3) - 1;
                        pixels[0] = Math.max(0, Math.min(255, pixels[0] + offset));
                    }
                };
                """ : "")
            }
        """ : ""

        // 5. Khối WebRTC IP Leak Protection
        let webrtcBlock = webrtcProtectionEnabled ? """
            // 6. Ngăn rò rỉ địa chỉ IP nội bộ qua WebRTC STUN
            if (window.RTCPeerConnection) {
                const origCreateOffer = RTCPeerConnection.prototype.createOffer;
                RTCPeerConnection.prototype.createOffer = function(options) {
                    return origCreateOffer.apply(this, arguments).then(offer => {
                        if (offer && offer.sdp) {
                            offer.sdp = offer.sdp.replace(/a=candidate:\\S+ \\S+ \\S+ \\S+ (?:192\\.168\\.\\d+\\.\\d+|10\\.\\d+\\.\\d+\\.\\d+|172\\.(?:1[6-9]|2\\d|3[0-1])\\.\\d+\\.\\d+)[^\\r\\n]*/g, '');
                        }
                        return offer;
                    });
                };
                const origCreateAnswer = RTCPeerConnection.prototype.createAnswer;
                if (origCreateAnswer) {
                    RTCPeerConnection.prototype.createAnswer = function(options) {
                        return origCreateAnswer.apply(this, arguments).then(ans => {
                            if (ans && ans.sdp) {
                                ans.sdp = ans.sdp.replace(/a=candidate:\\S+ \\S+ \\S+ \\S+ (?:192\\.168\\.\\d+\\.\\d+|10\\.\\d+\\.\\d+\\.\\d+|172\\.(?:1[6-9]|2\\d|3[0-1])\\.\\d+\\.\\d+)[^\\r\\n]*/g, '');
                            }
                            return ans;
                        });
                    };
                }
            }
        """ : ""

        // 6. Khối Media Devices Spoofing (Microphone, Camera, Speaker)
        let mediaBlock = mediaDevicesProtectionEnabled ? """
            // 7. Giả lập danh sách MediaDevices phần cứng độc lập
            if (navigator.mediaDevices && navigator.mediaDevices.enumerateDevices) {
                navigator.mediaDevices.enumerateDevices = async function() {
                    return [
                        {
                            deviceId: fp.audioInputDeviceId,
                            kind: 'audioinput',
                            label: fp.audioInputLabel,
                            groupId: fp.audioInputDeviceId.substring(0, 16)
                        },
                        {
                            deviceId: fp.videoInputDeviceId,
                            kind: 'videoinput',
                            label: fp.videoInputLabel,
                            groupId: fp.videoInputDeviceId.substring(0, 16)
                        },
                        {
                            deviceId: fp.audioOutputDeviceId,
                            kind: 'audiooutput',
                            label: fp.audioOutputLabel,
                            groupId: fp.audioOutputDeviceId.substring(0, 16)
                        }
                    ];
                };
            }
        """ : ""

        return """
        (function() {
            'use strict';
            const fp = {
                userAgent: "\(escapedUA)",
                appVersion: "\(escapedAppVer)",
                platform: "\(escapedPlatform)",
                vendor: "\(escapedVendor)",
                hardwareConcurrency: \(hardwareConcurrency),
                deviceMemory: \(deviceMemory),
                maxTouchPoints: \(maxTouchPoints),
                screenWidth: \(screenWidth),
                screenHeight: \(screenHeight),
                screenScale: \(screenScale),
                canvasSeed: \(canvasSeed),
                audioSeed: \(audioSeed),
                fontSeed: \(fontSeed),
                webglSeed: \(webglSeed),
                webglVendor: "\(escapedWebGLVendor)",
                webglRenderer: "\(escapedWebGLRenderer)",
                timeZone: "\(escapedTimeZone)",
                timeZoneOffsetMinutes: \(timeZoneOffsetMinutes),
                languages: \(languagesJson),
                connectionType: "\(escapedConnType)",
                downlinkSpeed: \(downlinkSpeed),
                rttMs: \(rttMs),
                audioInputDeviceId: "\(escapedAudioInId)",
                videoInputDeviceId: "\(escapedVideoInId)",
                audioOutputDeviceId: "\(escapedAudioOutId)",
                audioInputLabel: "\(escapedAudioInLbl)",
                videoInputLabel: "\(escapedVideoInLbl)",
                audioOutputLabel: "\(escapedAudioOutLbl)"
            };

            // 1. Giả lập thông số Navigator
            const navProps = {
                userAgent: { get: () => fp.userAgent },
                appVersion: { get: () => fp.appVersion },
                platform: { get: () => fp.platform },
                vendor: { get: () => fp.vendor },
                hardwareConcurrency: { get: () => fp.hardwareConcurrency },
                deviceMemory: { get: () => fp.deviceMemory },
                maxTouchPoints: { get: () => fp.maxTouchPoints },
                language: { get: () => fp.languages[0] || 'vi-VN' },
                languages: { get: () => Object.freeze([...fp.languages]) },
                webdriver: { get: () => undefined },
                pdfViewerEnabled: { get: () => true }
            };
            for (const [prop, desc] of Object.entries(navProps)) {
                try {
                    Object.defineProperty(navigator, prop, { ...desc, configurable: true });
                } catch(e) {}
            }

            // 1b. Giả lập thông số Network Information API
            try {
                const conn = {
                    effectiveType: fp.connectionType || '4g',
                    rtt: fp.rttMs || 45,
                    downlink: fp.downlinkSpeed || 10.0,
                    saveData: false,
                    onchange: null
                };
                Object.defineProperty(navigator, 'connection', { get: () => conn, configurable: true });
            } catch(e) {}

            // 2. Giả lập thông số Màn hình & Tỷ lệ điểm ảnh
            const screenProps = {
                width: { get: () => fp.screenWidth },
                height: { get: () => fp.screenHeight },
                availWidth: { get: () => fp.screenWidth },
                availHeight: { get: () => fp.screenHeight },
                colorDepth: { get: () => \(colorDepth) },
                pixelDepth: { get: () => \(pixelDepth) }
            };
            for (const [prop, desc] of Object.entries(screenProps)) {
                try {
                    Object.defineProperty(screen, prop, { ...desc, configurable: true });
                } catch(e) {}
            }
            try {
                Object.defineProperty(window, 'devicePixelRatio', { get: () => fp.screenScale, configurable: true });
            } catch(e) {}

            \(webglBlock)
            \(canvasBlock)
            \(fontBlock)
            \(audioBlock)
            \(webrtcBlock)
            \(mediaBlock)

            // 8. Đồng bộ Múi giờ & Offset
            try {
                const origResolvedOptions = Intl.DateTimeFormat.prototype.resolvedOptions;
                Intl.DateTimeFormat.prototype.resolvedOptions = function() {
                    const opts = origResolvedOptions.apply(this, arguments);
                    opts.timeZone = fp.timeZone;
                    return opts;
                };
                Date.prototype.getTimezoneOffset = function() {
                    return fp.timeZoneOffsetMinutes;
                };
            } catch(e) {}
        })();
        """
    }
}
