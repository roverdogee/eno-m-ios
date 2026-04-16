import Foundation
import CryptoKit
import os

enum BiliApiError: LocalizedError {
    case invalidRequest
    case unsupportedQuery(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "Invalid Bilibili API request"
        case .unsupportedQuery(let query):
            return "Unsupported Bilibili API query: \(query)"
        case .invalidResponse(let message):
            return message
        }
    }
}

struct BiliEndpoint {
    let path: String
    let defaults: [String: Any]
}

final class BiliApiClient {
    private let baseURL = URL(string: "https://api.bilibili.com")!
    private let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    private let logger = Logger(subsystem: "com.eno.music.ios", category: "BiliApi")
    private let cookieStore: CookieStore
    private let session: URLSession
    private let mixinKeyEncTab = [
        46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
        27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
        37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4,
        22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52
    ]

    init(cookieStore: CookieStore, session: URLSession = .shared) {
        self.cookieStore = cookieStore
        self.session = session
    }

    func request(payload: [String: Any]) async throws -> Any {
        guard let query = payload["contentScriptQuery"] as? String else {
            throw BiliApiError.invalidRequest
        }

        let endpoint = try endpoint(for: query)
        var params = endpoint.defaults
        for (key, value) in payload where key != "contentScriptQuery" {
            params[key] = value
        }

        let cookie = cookieStore.read()
        var components = URLComponents(url: baseURL.appendingPathComponent(endpoint.path), resolvingAgainstBaseURL: false)
        if query == "search" {
            components?.percentEncodedQuery = try await signedWbiQuery(params: params, cookie: cookie)
        } else {
            components?.queryItems = params
                .filter { key, value in
                    if value is NSNull {
                        return false
                    }
                    if let text = value as? String, text.isEmpty, key != "keyword" {
                        return false
                    }
                    return true
                }
                .map { URLQueryItem(name: $0.key, value: stringify($0.value)) }
        }

        guard let url = components?.url else {
            throw BiliApiError.invalidRequest
        }
        logRequest(query: query, url: url, cookie: cookie)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        request.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")

        if !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BiliApiError.invalidResponse("Bilibili API returned an invalid response")
        }
        logResponse(query: query, statusCode: httpResponse.statusCode, data: data)
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw BiliApiError.invalidResponse("Bilibili API returned HTTP \(httpResponse.statusCode)")
        }

        if let httpResponse = response as? HTTPURLResponse,
           let setCookie = httpResponse.value(forHTTPHeaderField: "Set-Cookie"),
           !setCookie.isEmpty,
           cookie.isEmpty {
            try? cookieStore.write(setCookie)
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw BiliApiError.invalidResponse("Bilibili API returned a non-JSON response")
        }

        if query == "search",
           !cookie.isEmpty,
           let dict = object as? [String: Any],
           let code = dict["code"] as? NSNumber,
           code.intValue != 0 {
            return try await requestWithoutCookie(url: url)
        }

        return object
    }

    func debugSearch(keyword: String) async -> [String: Any] {
        let searchEndpoint: BiliEndpoint
        do {
            searchEndpoint = try endpoint(for: "search")
        } catch {
            return ["error": error.localizedDescription]
        }

        var params = searchEndpoint.defaults
        params["keyword"] = keyword
        params["page"] = 1
        params["page_size"] = 5

        let cookie = cookieStore.read()
        var report: [String: Any] = [
            "keyword": keyword,
            "hasCookie": !cookie.isEmpty,
            "cookieLength": cookie.count,
            "userAgent": desktopUserAgent
        ]

        do {
            let keys = try await wbiKeys(cookie: cookie)
            report["hasWbiKeys"] = !keys.imgKey.isEmpty && !keys.subKey.isEmpty
            report["imgKeyLength"] = keys.imgKey.count
            report["subKeyLength"] = keys.subKey.count

            let signedQuery = try await signedWbiQuery(params: params, cookie: cookie)
            report["hasWts"] = signedQuery.contains("wts=")
            report["hasWRid"] = signedQuery.contains("w_rid=")
            report["queryPreview"] = redactSignature(in: signedQuery)

            var components = URLComponents(url: baseURL.appendingPathComponent(searchEndpoint.path), resolvingAgainstBaseURL: false)
            components?.percentEncodedQuery = signedQuery
            guard let url = components?.url else {
                report["error"] = "Invalid signed URL"
                return report
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
            request.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
            if !cookie.isEmpty {
                request.setValue(cookie, forHTTPHeaderField: "Cookie")
            }

            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(data: data, encoding: .utf8) ?? ""
            report["httpStatus"] = statusCode
            report["responsePreview"] = String(text.prefix(800))

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                report["code"] = (json["code"] as? NSNumber)?.intValue ?? json["code"] ?? NSNull()
                report["message"] = json["message"] as? String ?? ""
                if let data = json["data"] as? [String: Any],
                   let result = data["result"] as? [Any] {
                    report["resultCount"] = result.count
                }
            } else {
                report["json"] = false
            }
        } catch {
            report["error"] = error.localizedDescription
        }

        return report
    }

    func search(keyword: String, page: Int = 1, pageSize: Int = 20) async throws -> Any {
        let searchEndpoint = try endpoint(for: "search")
        var params = searchEndpoint.defaults
        params["keyword"] = keyword
        params["page"] = page
        params["page_size"] = pageSize

        let cookie = cookieStore.read()
        var components = URLComponents(url: baseURL.appendingPathComponent(searchEndpoint.path), resolvingAgainstBaseURL: false)
        components?.percentEncodedQuery = try await signedWbiQuery(params: params, cookie: cookie)

        guard let url = components?.url else {
            throw BiliApiError.invalidRequest
        }

        logRequest(query: "search", url: url, cookie: cookie)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        request.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
        if !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BiliApiError.invalidResponse("Bilibili API returned an invalid response")
        }

        logResponse(query: "search", statusCode: httpResponse.statusCode, data: data)

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw BiliApiError.invalidResponse("Bilibili API returned HTTP \(httpResponse.statusCode)")
        }

        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw BiliApiError.invalidResponse("Bilibili API returned a non-JSON response")
        }
    }

    func spaceVideos(mid: Int, page: Int = 1, pageSize: Int = 30) async throws -> Any {
        let params: [String: Any] = [
            "mid": mid,
            "pn": page,
            "ps": pageSize,
            "tid": 0,
            "keyword": "",
            "order": "pubdate",
            "platform": "web",
            "web_location": 1550101
        ]

        let cookie = cookieStore.read()
        var components = URLComponents(url: baseURL.appendingPathComponent("/x/space/wbi/arc/search"), resolvingAgainstBaseURL: false)
        components?.percentEncodedQuery = try await signedWbiQuery(params: params, cookie: cookie)

        guard let url = components?.url else {
            throw BiliApiError.invalidRequest
        }

        logger.info("Space videos request mid=\(mid, privacy: .public) page=\(page, privacy: .public) pageSize=\(pageSize, privacy: .public)")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("https://space.bilibili.com/\(mid)/video", forHTTPHeaderField: "Referer")
        request.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
        if !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BiliApiError.invalidResponse("Bilibili API returned an invalid response")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw BiliApiError.invalidResponse("Bilibili API returned HTTP \(httpResponse.statusCode)")
        }

        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw BiliApiError.invalidResponse("Bilibili API returned a non-JSON response")
        }
    }

    private func requestWithoutCookie(url: URL) async throws -> Any {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        request.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            throw BiliApiError.invalidResponse("Bilibili API returned an invalid response")
        }

        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw BiliApiError.invalidResponse("Bilibili API returned a non-JSON response")
        }
    }

    private func logRequest(query: String, url: URL, cookie: String) {
        guard query == "search" else {
            return
        }

        let redacted = redactSignature(in: url.absoluteString)
        logger.info("Search request url=\(redacted, privacy: .public) hasCookie=\(!cookie.isEmpty, privacy: .public) cookieLength=\(cookie.count, privacy: .public)")
    }

    private func logResponse(query: String, statusCode: Int, data: Data) {
        guard query == "search" else {
            return
        }

        let text = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        logger.info("Search response status=\(statusCode, privacy: .public) body=\(String(text.prefix(1000)), privacy: .public)")
    }

    private func redactSignature(in value: String) -> String {
        value
            .replacingOccurrences(
                of: #"w_rid=[^&]+"#,
                with: "w_rid=<redacted>",
                options: .regularExpression
            )
    }

    private func endpoint(for query: String) throws -> BiliEndpoint {
        switch query {
        case "getNav":
            return BiliEndpoint(path: "/x/web-interface/nav", defaults: [:])
        case "search":
            return BiliEndpoint(
                path: "/x/web-interface/search/type",
                defaults: [
                    "page": 1,
                    "page_size": 42,
                    "platform": "pc",
                    "highlight": 1,
                    "single_column": 0,
                    "keyword": "",
                    "category_id": "",
                    "search_type": "video",
                    "dynamic_offset": 0,
                    "preload": true,
                    "com2co": true
                ]
            )
        case "getVideoInfo":
            return BiliEndpoint(path: "/x/web-interface/view", defaults: ["bvid": ""])
        case "getAudioOfVideo":
            return BiliEndpoint(path: "/x/player/playurl", defaults: ["fnval": 16, "bvid": "", "cid": 0])
        case "getSong":
            return BiliEndpoint(path: "/audio/music-service-c/web/url", defaults: ["sid": 0])
        case "getSongInfo":
            return BiliEndpoint(path: "/audio/music-service-c/web/song/info", defaults: ["sid": 0])
        default:
            throw BiliApiError.unsupportedQuery(query)
        }
    }

    private func stringify(_ value: Any) -> String {
        switch value {
        case let value as String:
            return value
        case let value as Bool:
            return value ? "true" : "false"
        case let value as NSNumber:
            return value.stringValue
        default:
            return String(describing: value)
        }
    }

    private func signedWbiQuery(params: [String: Any], cookie: String) async throws -> String {
        let keys = try await wbiKeys(cookie: cookie)
        guard !keys.imgKey.isEmpty, !keys.subKey.isEmpty else {
            return encodedQuery(params: params)
        }

        var signedParams = params
        let timestamp = Int(Date().timeIntervalSince1970.rounded())
        signedParams["wts"] = timestamp

        let mixinKey = mixinKey(imgKey: keys.imgKey, subKey: keys.subKey)
        let query = encodedQuery(params: signedParams)
        let digest = Insecure.MD5.hash(data: Data((query + mixinKey).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(query)&w_rid=\(digest)"
    }

    private func wbiKeys(cookie: String) async throws -> (imgKey: String, subKey: String) {
        var request = URLRequest(url: baseURL.appendingPathComponent("/x/web-interface/nav"))
        request.httpMethod = "GET"
        request.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        if !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let data = json["data"] as? [String: Any],
              let wbiImage = data["wbi_img"] as? [String: Any],
              let imageURL = wbiImage["img_url"] as? String,
              let subURL = wbiImage["sub_url"] as? String
        else {
            return ("", "")
        }

        return (resourceKey(from: imageURL), resourceKey(from: subURL))
    }

    private func resourceKey(from url: String) -> String {
        guard let last = url.split(separator: "/").last,
              let key = last.split(separator: ".").first
        else {
            return ""
        }
        return String(key)
    }

    private func mixinKey(imgKey: String, subKey: String) -> String {
        let characters = Array(imgKey + subKey)
        let mixed = mixinKeyEncTab.compactMap { index -> Character? in
            guard index < characters.count else {
                return nil
            }
            return characters[index]
        }
        return String(mixed.prefix(32))
    }

    private func encodedQuery(params: [String: Any]) -> String {
        params.keys.sorted().map { key in
            let value = sanitizedWbiValue(stringify(params[key] ?? ""))
            return "\(percentEncode(key))=\(percentEncode(value))"
        }
        .joined(separator: "&")
    }

    private func sanitizedWbiValue(_ value: String) -> String {
        value.filter { character in
            character != "!" && character != "'" && character != "(" && character != ")" && character != "*"
        }
    }

    private func percentEncode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
