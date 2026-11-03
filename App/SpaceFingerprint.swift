import Foundation
import UIKit

// MARK: - Device Model Presets

enum DeviceModelPreset: String, Codable, CaseIterable, Identifiable {
    case iPhone15ProMax = "iPhone 15 Pro Max (A17 Pro)"
    case iPhone15Pro = "iPhone 15 Pro (A17 Pro)"
    case iPhone15 = "iPhone 15 (A16 Bionic)"
    case iPhone14ProMax = "iPhone 14 Pro Max (A16 Bionic)"
    case iPhone14 = "iPhone 14 (A15 Bionic)"
    case iPhone13Pro = "iPhone 13 Pro (A15 Bionic)"
    case iPhone13 = "iPhone 13 (A15 Bionic)"
    case iPadPro129 = "iPad Pro 12.9 inch (M2)"
    case custom = "Tùy chỉnh thông số riêng"

    var id: String { rawValue }

    var shortName: String {
        switch self {
        case .iPhone15ProMax: return "iPhone 15 Pro Max"
        case .iPhone15Pro: return "iPhone 15 Pro"
        case .iPhone15: return "iPhone 15"
        case .iPhone14ProMax: return "iPhone 14 Pro Max"
        case .iPhone14: return "iPhone 14"
        case .iPhone13Pro: return "iPhone 13 Pro"
        case .iPhone13: return "iPhone 13"
        case .iPadPro129: return "iPad Pro 12.9"
        case .custom: return "Tùy chỉnh"
        }
    }
}

// MARK: - Space Fingerprint Model

struct SpaceFingerprint: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var preset: DeviceModelPreset = .iPhone15Pro
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
    var hardwareConcurrency: Int // Số nhân CPU (4, 6, 8)
    var deviceMemory: Int         // Dung lượng RAM tính theo GB (4, 6, 8, 16)
    var maxTouchPoints: Int = 5

    // WebGL
    var webGLVendor: String = "Apple Inc."
    var webGLRenderer: String

    // Hạt giống nhiễu bảo vệ Canvas & Audio (Mỗi không gian 1 hạt giống độc nhất)
    var canvasSeed: UInt32
    var audioSeed: UInt32

    // Ngôn ngữ & Múi giờ
    var timeZone: String = "Asia/Ho_Chi_Minh"
    var languages: [String] = ["vi-VN", "vi", "en-US", "en"]

    // Bật/tắt các lớp bảo vệ dấu vân tay
    var canvasNoiseEnabled: Bool = true
    var audioNoiseEnabled: Bool = true
    var webGLSpoofingEnabled: Bool = true
    var webrtcProtectionEnabled: Bool = true

    /// Tóm tắt hiển thị trên UI
    var displaySummary: String {
        return "\(preset.shortName) • \(screenWidth)x\(screenHeight) • Seed #\(canvasSeed % 10000)"
    }

    // MARK: - Presets Factory

    static func defaultFor(spaceId: UUID) -> SpaceFingerprint {
        // Sinh dấu vân tay mặc định nhất quán theo spaceId (mỗi không gian sinh ra có bộ thông số riêng)
        let hash = abs(spaceId.hashValue)
        let allPresets: [DeviceModelPreset] = [
            .iPhone15ProMax,
            .iPhone15Pro,
            .iPhone15,
            .iPhone14ProMax,
            .iPhone14,
            .iPhone13Pro,
            .iPhone13
        ]
        let chosenPreset = allPresets[hash % allPresets.count]
        return makePreset(
            preset: chosenPreset,
            canvasSeed: UInt32(truncatingIfNeeded: hash &+ 1013),
            audioSeed: UInt32(truncatingIfNeeded: (hash >> 8) &+ 7919)
        )
    }

    static func generateRandom(preset: DeviceModelPreset? = nil) -> SpaceFingerprint {
        let allPresets: [DeviceModelPreset] = [
            .iPhone15ProMax,
            .iPhone15Pro,
            .iPhone15,
            .iPhone14ProMax,
            .iPhone14,
            .iPhone13Pro,
            .iPhone13
        ]
        let chosenPreset = preset ?? allPresets.randomElement() ?? .iPhone15Pro
        let canvasSeed = UInt32.random(in: 10_000...999_999)
        let audioSeed = UInt32.random(in: 10_000...999_999)
        return makePreset(preset: chosenPreset, canvasSeed: canvasSeed, audioSeed: audioSeed)
    }

    static func makePreset(preset: DeviceModelPreset, canvasSeed: UInt32, audioSeed: UInt32) -> SpaceFingerprint {
        switch preset {
        case .iPhone15ProMax:
            return SpaceFingerprint(
                preset: .iPhone15ProMax,
                userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5.1 Mobile/15E148 Safari/604.1",
                appVersion: "5.0 (iPhone; CPU iPhone OS 17_5_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5.1 Mobile/15E148 Safari/604.1",
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
                audioSeed: audioSeed
            )
        case .iPhone15Pro:
            return SpaceFingerprint(
                preset: .iPhone15Pro,
                userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4.1 Mobile/15E148 Safari/604.1",
                appVersion: "5.0 (iPhone; CPU iPhone OS 17_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4.1 Mobile/15E148 Safari/604.1",
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
                audioSeed: audioSeed
            )
        case .iPhone15:
            return SpaceFingerprint(
                preset: .iPhone15,
                userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6.1 Mobile/15E148 Safari/604.1",
                appVersion: "5.0 (iPhone; CPU iPhone OS 17_6_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6.1 Mobile/15E148 Safari/604.1",
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
                audioSeed: audioSeed
            )
        case .iPhone14ProMax:
            return SpaceFingerprint(
                preset: .iPhone14ProMax,
                userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Mobile/15E148 Safari/604.1",
                appVersion: "5.0 (iPhone; CPU iPhone OS 17_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Mobile/15E148 Safari/604.1",
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
                audioSeed: audioSeed
            )
        case .iPhone14:
            return SpaceFingerprint(
                preset: .iPhone14,
                userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1 Mobile/15E148 Safari/604.1",
                appVersion: "5.0 (iPhone; CPU iPhone OS 17_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1 Mobile/15E148 Safari/604.1",
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
                audioSeed: audioSeed
            )
        case .iPhone13Pro:
            return SpaceFingerprint(
                preset: .iPhone13Pro,
                userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1",
                appVersion: "5.0 (iPhone; CPU iPhone OS 16_6_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1",
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
                audioSeed: audioSeed
            )
        case .iPhone13:
            return SpaceFingerprint(
                preset: .iPhone13,
                userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 16_7_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.7 Mobile/15E148 Safari/604.1",
                appVersion: "5.0 (iPhone; CPU iPhone OS 16_7_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.7 Mobile/15E148 Safari/604.1",
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
                audioSeed: audioSeed
            )
        case .iPadPro129:
            return SpaceFingerprint(
                preset: .iPadPro129,
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
                audioSeed: audioSeed
            )
        case .custom:
            return SpaceFingerprint(
                preset: .custom,
                userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1",
                appVersion: "5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1",
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
                audioSeed: audioSeed
            )
        }
    }

    // MARK: - Anti-Detect JavaScript Generator

    /// Tạo mã JavaScript được tiêm vào WKWebView ở thời điểm `atDocumentStart` để giả lập dấu vân tay trình duyệt
    func buildAntiDetectScript() -> String {
        let languagesJson = (try? String(data: JSONEncoder().encode(languages), encoding: .utf8)) ?? "[\"vi-VN\", \"vi\"]"

        let escapedUA = userAgent.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let escapedAppVer = appVersion.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let escapedPlatform = platform.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedVendor = vendor.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedWebGLVendor = webGLVendor.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedWebGLRenderer = webGLRenderer.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedTimeZone = timeZone.replacingOccurrences(of: "\"", with: "\\\"")

        let canvasBlock = canvasNoiseEnabled ? """
            // 4. Khử vết dấu Canvas Fingerprint bằng hạt giống độc nhất
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

        let audioBlock = audioNoiseEnabled ? """
            // 5. Khử vết AudioContext Fingerprint
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
        """ : ""

        let webglBlock = webGLSpoofingEnabled ? """
            // 3. Giả lập thông số card đồ họa WebGL
            const getParamHook = function(origFn) {
                return function(param) {
                    if (param === 37445) return fp.webglVendor;
                    if (param === 37446) return fp.webglRenderer;
                    return origFn.call(this, param);
                };
            };
            if (window.WebGLRenderingContext) {
                WebGLRenderingContext.prototype.getParameter = getParamHook(WebGLRenderingContext.prototype.getParameter);
            }
            if (window.WebGL2RenderingContext) {
                WebGL2RenderingContext.prototype.getParameter = getParamHook(WebGL2RenderingContext.prototype.getParameter);
            }
        """ : ""

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
                screenWidth: \(screenWidth),
                screenHeight: \(screenHeight),
                screenScale: \(screenScale),
                canvasSeed: \(canvasSeed),
                audioSeed: \(audioSeed),
                webglVendor: "\(escapedWebGLVendor)",
                webglRenderer: "\(escapedWebGLRenderer)",
                timeZone: "\(escapedTimeZone)",
                languages: \(languagesJson)
            };

            // 1. Giả lập thông số Navigator
            const navProps = {
                userAgent: { get: () => fp.userAgent },
                appVersion: { get: () => fp.appVersion },
                platform: { get: () => fp.platform },
                vendor: { get: () => fp.vendor },
                hardwareConcurrency: { get: () => fp.hardwareConcurrency },
                deviceMemory: { get: () => fp.deviceMemory },
                maxTouchPoints: { get: () => 5 },
                language: { get: () => fp.languages[0] || 'vi-VN' },
                languages: { get: () => Object.freeze([...fp.languages]) }
            };
            for (const [prop, desc] of Object.entries(navProps)) {
                try {
                    Object.defineProperty(navigator, prop, { ...desc, configurable: true });
                } catch(e) {}
            }

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
            \(audioBlock)
            \(webrtcBlock)

            // 7. Múi giờ
            try {
                const origResolvedOptions = Intl.DateTimeFormat.prototype.resolvedOptions;
                Intl.DateTimeFormat.prototype.resolvedOptions = function() {
                    const opts = origResolvedOptions.apply(this, arguments);
                    opts.timeZone = fp.timeZone;
                    return opts;
                };
            } catch(e) {}
        })();
        """
    }
}
