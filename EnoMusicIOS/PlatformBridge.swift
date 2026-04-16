import Foundation

enum PlatformBridgeError: LocalizedError {
    case unsupportedChannel(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedChannel(let channel):
            return "Unsupported iOS bridge channel: \(channel)"
        }
    }
}

final class PlatformBridge {
    private let cookieStore = CookieStore()
    private lazy var biliApiClient = BiliApiClient(cookieStore: cookieStore)
    private lazy var biliLoginClient = BiliLoginClient(cookieStore: cookieStore)
    private lazy var audioPlayer = NativeAudioPlayer { [weak self] event, payload in
        self?.sendEvent?(event, payload)
    }
    var sendEvent: ((String, [String: Any]) -> Void)?

    func invoke(channel: String, args: [Any]) async throws -> Any {
        switch channel {
        case "get-platform-info":
            return [
                "platform": "ios",
                "nativeBridge": true
            ]
        case "bili-api":
            guard let payload = args.first as? [String: Any] else {
                throw BiliApiError.invalidRequest
            }
            return try await biliApiClient.request(payload: payload)
        case "bili-search-debug":
            let keyword = args.first as? String ?? "邓紫棋"
            return await biliApiClient.debugSearch(keyword: keyword)
        case "bili-search":
            let payload = args.first as? [String: Any]
            let keyword = payload?["keyword"] as? String ?? args.first as? String ?? ""
            let page = payload?["page"] as? Int ?? 1
            let pageSize = payload?["page_size"] as? Int ?? payload?["pageSize"] as? Int ?? 20
            return try await biliApiClient.search(keyword: keyword, page: page, pageSize: pageSize)
        case "bili-space-videos":
            guard let payload = args.first as? [String: Any],
                  let mid = intValue(payload["mid"])
            else {
                throw BiliApiError.invalidRequest
            }
            let page = intValue(payload["page"]) ?? 1
            let pageSize = intValue(payload["page_size"]) ?? intValue(payload["pageSize"]) ?? 30
            return try await biliApiClient.spaceVideos(mid: mid, page: page, pageSize: pageSize)
        case "bili-qr-generate":
            return try await biliLoginClient.generateQR()
        case "bili-qr-poll":
            guard let oauthKey = args.first as? String else {
                throw BiliLoginError.missingQRCodeKey
            }
            return try await biliLoginClient.pollQR(oauthKey: oauthKey)
        case "bili-user-info":
            return try await biliLoginClient.fetchUserInfo()
        case "bili-user-info-with-cookie":
            let cookie = args.first as? String ?? ""
            return try await biliLoginClient.fetchUserInfo(cookieOverride: cookie)
        case "native-audio-play":
            guard let payload = args.first as? [String: Any],
                  let url = payload["url"] as? String
            else {
                throw NativeAudioError.invalidURL
            }
            return try await audioPlayer.play(
                url: url,
                title: payload["title"] as? String,
                artist: payload["artist"] as? String,
                artworkURL: payload["artwork"] as? String,
                cookie: cookieStore.read()
            )
        case "native-audio-pause":
            return audioPlayer.pause()
        case "native-audio-resume":
            return audioPlayer.resume()
        case "native-audio-stop":
            return audioPlayer.stop()
        case "native-audio-seek":
            let payload = args.first as? [String: Any]
            let seconds = payload?["seconds"] as? Double ?? payload?["position"] as? Double ?? 0
            return audioPlayer.seek(seconds: seconds)
        case "get-cookie":
            return cookieStore.read()
        case "set-cookie":
            let cookie = args.first as? String ?? ""
            try cookieStore.write(cookie)
            return ["success": true]
        case "clear-cookie", "bili-logout":
            try cookieStore.clear()
            return ["success": true]
        default:
            throw PlatformBridgeError.unsupportedChannel(channel)
        }
    }

    private func intValue(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }
}
