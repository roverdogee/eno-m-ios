import Foundation
import Security

final class CookieStore {
    private let service = "com.eno.music.ios"
    private let account = "bilibili-cookie"
    private let cookieAttributeNames: Set<String> = [
        "path",
        "domain",
        "expires",
        "max-age",
        "secure",
        "httponly",
        "samesite"
    ]

    func read() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            return ""
        }

        return normalize(value)
    }

    func write(_ cookie: String) throws {
        let data = Data(normalize(cookie).utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
        }
    }

    func clear() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private func normalize(_ cookie: String) -> String {
        cookie
            .split { character in
                character == ";" || character == "," || character == "\n" || character == "\r"
            }
            .compactMap { part -> String? in
                let token = part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let separator = token.firstIndex(of: "=") else {
                    return nil
                }

                let name = token[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
                let value = token[token.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty,
                      !value.isEmpty,
                      !cookieAttributeNames.contains(name.lowercased())
                else {
                    return nil
                }

                return "\(name)=\(value)"
            }
            .joined(separator: "; ")
    }
}
