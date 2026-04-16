import CoreImage
import Foundation
import UIKit

enum BiliLoginError: LocalizedError {
    case invalidResponse
    case missingQRCodeKey
    case qrImageGenerationFailed

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid Bilibili login response"
        case .missingQRCodeKey:
            return "Missing Bilibili QR code key"
        case .qrImageGenerationFailed:
            return "Failed to generate QR image"
        }
    }
}

final class BiliLoginClient {
    private let cookieStore: CookieStore
    private let session: URLSession
    private let context = CIContext()

    init(cookieStore: CookieStore, session: URLSession = .shared) {
        self.cookieStore = cookieStore
        self.session = session
    }

    func generateQR() async throws -> Any {
        let json = try await requestJSON(URL(string: "https://passport.bilibili.com/x/passport-login/web/qrcode/generate")!, cookieOverride: "")
        guard let dict = json as? [String: Any],
              let code = dict["code"] as? NSNumber,
              code.intValue == 0,
              let data = dict["data"] as? [String: Any],
              let url = data["url"] as? String
        else {
            throw BiliLoginError.invalidResponse
        }

        let oauthKey = data["qrcode_key"] as? String
            ?? data["oauthKey"] as? String
            ?? data["key"] as? String

        guard let oauthKey, !oauthKey.isEmpty else {
            throw BiliLoginError.missingQRCodeKey
        }

        return [
            "url": url,
            "oauthKey": oauthKey,
            "qrImage": try makeQRCodeDataURL(from: url)
        ]
    }

    func pollQR(oauthKey: String) async throws -> Any {
        var components = URLComponents(string: "https://passport.bilibili.com/x/passport-login/web/qrcode/poll")
        components?.queryItems = [
            URLQueryItem(name: "qrcode_key", value: oauthKey)
        ]

        guard let url = components?.url else {
            throw BiliLoginError.invalidResponse
        }

        let (json, response) = try await requestJSONWithResponse(url, cookieOverride: "")
        guard let dict = json as? [String: Any],
              let code = dict["code"] as? NSNumber,
              code.intValue == 0,
              let data = dict["data"] as? [String: Any]
        else {
            return [
                "status": "pending",
                "message": (json as? [String: Any])?["message"] as? String ?? "服务器错误"
            ]
        }

        let scanCode = (data["code"] as? NSNumber)?.intValue ?? -1
        switch scanCode {
        case 0:
            let cookie = cookieString(from: response)
            guard !cookie.isEmpty else {
                return [
                    "status": "failed",
                    "message": "登录未返回 Cookie，已保留原登录"
                ]
            }

            guard try await isValidLoginCookie(cookie) else {
                return [
                    "status": "failed",
                    "message": "登录 Cookie 验证失败，已保留原登录"
                ]
            }
            try cookieStore.write(cookie)

            return [
                "status": "confirmed",
                "cookie": cookie,
                "message": "登录成功！"
            ]
        case 86101:
            return ["status": "pending", "message": "等待扫码..."]
        case 86090:
            return ["status": "scanned", "message": "已扫码，请在手机上确认"]
        case 86038:
            return ["status": "failed", "message": "二维码已失效，请重新生成"]
        default:
            return [
                "status": "pending",
                "message": "状态: \(data["message"] ?? scanCode)，继续等待..."
            ]
        }
    }

    func fetchUserInfo(cookieOverride: String? = nil) async throws -> Any {
        let json = try await requestJSON(URL(string: "https://api.bilibili.com/x/web-interface/nav")!, cookieOverride: cookieOverride)
        guard let dict = json as? [String: Any],
              let code = dict["code"] as? NSNumber,
              code.intValue == 0,
              let data = dict["data"] as? [String: Any]
        else {
            return ["info": ["isLogin": false]]
        }

        return [
            "info": [
                "isLogin": (data["isLogin"] as? Bool) ?? false,
                "uname": data["uname"] as? String ?? "",
                "face": data["face"] as? String ?? ""
            ]
        ]
    }

    private func isValidLoginCookie(_ cookie: String) async throws -> Bool {
        guard let userInfo = try await fetchUserInfo(cookieOverride: cookie) as? [String: Any],
              let info = userInfo["info"] as? [String: Any]
        else {
            return false
        }

        return (info["isLogin"] as? Bool) ?? false
    }

    private func requestJSON(_ url: URL, cookieOverride: String? = nil) async throws -> Any {
        let (json, _) = try await requestJSONWithResponse(url, cookieOverride: cookieOverride)
        return json
    }

    private func requestJSONWithResponse(_ url: URL, cookieOverride: String? = nil) async throws -> (Any, HTTPURLResponse?) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        request.setValue("https://passport.bilibili.com", forHTTPHeaderField: "Origin")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")

        let cookie = cookieOverride ?? cookieStore.read()
        if !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await session.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data)
        return (json, response as? HTTPURLResponse)
    }

    private func cookieString(from response: HTTPURLResponse?) -> String {
        guard let response else {
            return ""
        }

        let cookies = HTTPCookie.cookies(withResponseHeaderFields: response.allHeaderFields as? [String: String] ?? [:], for: response.url ?? URL(string: "https://bilibili.com")!)
        if !cookies.isEmpty {
            return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }

        if let header = response.value(forHTTPHeaderField: "Set-Cookie"), !header.isEmpty {
            return header
                .split(separator: ",")
                .compactMap { part in
                    part.split(separator: ";").first?.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .filter { !$0.isEmpty && $0.contains("=") }
                .joined(separator: "; ")
        }

        return ""
    }

    private func makeQRCodeDataURL(from value: String) throws -> String {
        guard let filter = CIFilter(name: "CIQRCodeGenerator"),
              let data = value.data(using: .utf8)
        else {
            throw BiliLoginError.qrImageGenerationFailed
        }

        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")

        guard let outputImage = filter.outputImage else {
            throw BiliLoginError.qrImageGenerationFailed
        }

        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent),
              let pngData = UIImage(cgImage: cgImage).pngData()
        else {
            throw BiliLoginError.qrImageGenerationFailed
        }

        return "data:image/png;base64,\(pngData.base64EncodedString())"
    }
}
