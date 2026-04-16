import SwiftUI
import WebKit

struct EnoWebView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "enoBridge")

        if let bridgeURL = Bundle.main.url(forResource: "bridge", withExtension: "js", subdirectory: "Web"),
           let bridgeSource = try? String(contentsOf: bridgeURL, encoding: .utf8) {
            let bridgeScript = WKUserScript(
                source: bridgeSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
            contentController.addUserScript(bridgeScript)
        }

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.overrideUserInterfaceStyle = .dark
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.overrideUserInterfaceStyle = .dark
        webView.uiDelegate = context.coordinator

        loadBundledHome(in: webView)

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    private func loadBundledHome(in webView: WKWebView) {
        guard let indexURL = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Web") else {
            return
        }

        if let html = try? String(contentsOf: indexURL, encoding: .utf8) {
            webView.loadHTMLString(html, baseURL: indexURL.deletingLastPathComponent())
        } else {
            webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
        }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKUIDelegate {
        private let bridge = PlatformBridge()

        override init() {
            super.init()
            bridge.sendEvent = { [weak self] event, payload in
                Task { @MainActor in
                    self?.emit(event: event, payload: payload)
                }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "enoBridge",
                  let body = message.body as? [String: Any],
                  let id = body["id"] as? String,
                  let channel = body["channel"] as? String
            else {
                return
            }

            let args = body["args"] as? [Any] ?? []
            currentWebView = message.webView

            Task { @MainActor in
                do {
                    if channel == "bili-web-login-open" {
                        openBiliWebLogin(in: message.webView)
                        reply(to: message.webView, id: id, result: ["success": true], error: nil)
                        return
                    }

                    if channel == "bili-web-login-sync" {
                        let result = try await syncBiliCookies(from: message.webView)
                        reply(to: message.webView, id: id, result: result, error: nil)
                        return
                    }

                    if channel == "bili-web-login-close" {
                        loadHome(in: message.webView)
                        reply(to: message.webView, id: id, result: ["success": true], error: nil)
                        return
                    }

                    let result = try await bridge.invoke(channel: channel, args: args)
                    reply(to: message.webView, id: id, result: result, error: nil)
                } catch {
                    reply(to: message.webView, id: id, result: nil, error: error.localizedDescription)
                }
            }
        }

        @MainActor
        private func openBiliWebLogin(in webView: WKWebView?) {
            guard let url = URL(string: "https://passport.bilibili.com/login") else {
                return
            }

            var request = URLRequest(url: url)
            request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
            webView?.load(request)
        }

        @MainActor
        private func loadHome(in webView: WKWebView?) {
            guard let indexURL = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Web") else {
                return
            }

            if let html = try? String(contentsOf: indexURL, encoding: .utf8) {
                webView?.loadHTMLString(html, baseURL: indexURL.deletingLastPathComponent())
            } else {
                webView?.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
            }
        }

        @MainActor
        private func syncBiliCookies(from webView: WKWebView?) async throws -> Any {
            guard let webView else {
                return ["success": false, "message": "WebView unavailable"]
            }

            let cookies = await allCookies(from: webView.configuration.websiteDataStore.httpCookieStore)
            let biliCookies = cookies.filter { cookie in
                cookie.domain.contains("bilibili.com")
                    || cookie.domain.contains("biliapi.net")
                    || cookie.domain.contains("biliapi.com")
            }

            let cookieString = biliCookies
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")

            guard !cookieString.isEmpty else {
                return [
                    "success": false,
                    "message": "没有读取到 B 站 Cookie，请确认网页登录已完成"
                ]
            }

            let userInfo = try await bridge.invoke(channel: "bili-user-info-with-cookie", args: [cookieString])
            guard isLoggedIn(userInfo) else {
                return [
                    "success": false,
                    "cookieCount": biliCookies.count,
                    "info": userInfo,
                    "message": "网页登录尚未完成，已保留原登录"
                ]
            }

            _ = try await bridge.invoke(channel: "set-cookie", args: [cookieString])

            return [
                "success": true,
                "cookieCount": biliCookies.count,
                "info": userInfo
            ]
        }

        private func isLoggedIn(_ userInfo: Any) -> Bool {
            guard let dict = userInfo as? [String: Any],
                  let info = dict["info"] as? [String: Any]
            else {
                return false
            }

            return (info["isLogin"] as? Bool) ?? false
        }

        private func allCookies(from cookieStore: WKHTTPCookieStore) async -> [HTTPCookie] {
            await withCheckedContinuation { continuation in
                cookieStore.getAllCookies { cookies in
                    continuation.resume(returning: cookies)
                }
            }
        }

        @MainActor
        private func emit(event: String, payload: [String: Any]) {
            let eventPayload: [String: Any] = [
                "channel": event,
                "args": [payload]
            ]

            guard JSONSerialization.isValidJSONObject(eventPayload),
                  let data = try? JSONSerialization.data(withJSONObject: eventPayload),
                  let json = String(data: data, encoding: .utf8)
            else {
                return
            }

            currentWebView?.evaluateJavaScript("window.__enoBridgeEmit(\(json));")
        }

        private weak var currentWebView: WKWebView?

        @MainActor
        private func reply(to webView: WKWebView?, id: String, result: Any?, error: String?) {
            currentWebView = webView
            var payload: [String: Any] = ["id": id]
            if let error {
                payload["error"] = error
            } else {
                payload["result"] = result ?? NSNull()
            }

            guard JSONSerialization.isValidJSONObject(payload),
                  let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8)
            else {
                return
            }

            webView?.evaluateJavaScript("window.__enoBridgeResolve(\(json));")
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            let isLogout = message.contains("确认退出登录")
            let alert = UIAlertController(title: isLogout ? "确认退出" : "确认删除", message: message, preferredStyle: .alert)
            alert.overrideUserInterfaceStyle = .dark
            alert.view.tintColor = UIColor.systemOrange
            alert.addAction(UIAlertAction(title: isLogout ? "确认退出" : "确认删除", style: .destructive) { _ in
                completionHandler(true)
            })
            alert.addAction(UIAlertAction(title: "我点错了", style: .cancel) { _ in
                completionHandler(false)
            })

            present(alert, from: webView) {
                completionHandler(false)
            }
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (String?) -> Void
        ) {
            let alert = UIAlertController(title: prompt, message: nil, preferredStyle: .alert)
            alert.overrideUserInterfaceStyle = .dark
            alert.view.tintColor = UIColor.systemOrange
            alert.addTextField { textField in
                textField.overrideUserInterfaceStyle = .dark
                textField.keyboardAppearance = .dark
                textField.text = defaultText
                textField.placeholder = prompt
                textField.clearButtonMode = .whileEditing
            }
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in
                completionHandler(nil)
            })
            alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in
                completionHandler(alert.textFields?.first?.text)
            })

            present(alert, from: webView) {
                completionHandler(nil)
            }
        }

        private func present(_ alert: UIAlertController, from webView: WKWebView, fallback: @escaping () -> Void) {
            guard let controller = webView.window?.rootViewController else {
                fallback()
                return
            }

            var presenter = controller
            while let presented = presenter.presentedViewController {
                presenter = presented
            }
            presenter.present(alert, animated: true)
        }
    }
}
