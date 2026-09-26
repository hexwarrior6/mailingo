import Foundation
import Security

/// API Key 的钥匙串读写。
///
/// 密钥**绝不进 UserDefaults** —— 那是明文落盘，任何进程都能读。
/// 钥匙串条目按 (service, account) 定位，本 App 只用 service
/// `com.zhuyuhao.Mailingo`，每个密钥一个 account（如 `llm.apiKey`）。
struct KeychainStore {

    let service: String

    static let mailingo = KeychainStore(service: "com.zhuyuhao.Mailingo")

    func get(_ account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    /// 写入（空串等价于删除 —— 设置里清空 Key 输入框就是撤销授权）。
    func set(_ value: String, for account: String) {
        guard !value.isEmpty else {
            remove(account)
            return
        }
        let data = Data(value.utf8)

        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, update as CFDictionary)
        guard status == errSecItemNotFound else { return }

        var add = baseQuery(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    func remove(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
