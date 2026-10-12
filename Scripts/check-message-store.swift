// Compiled with the production MessageStore and MIMEHeaders; never touches real mail.
import Foundation

enum SharedPaths {
    static let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    static var messages: URL {
        let url = root.appendingPathComponent("messages")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static var pendingRequest: URL { root.appendingPathComponent("pending.json") }
}

@main
enum MessageStoreCheck {
    static func main() throws {
        defer { try? FileManager.default.removeItem(at: SharedPaths.root) }
        func mail(_ identity: String?, _ body: String) -> Data {
            Data(("Subject: Synthetic reply\r\n" + (identity.map { "Message-ID: \($0)\r\n" } ?? "") + "\r\n" + body).utf8)
        }
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
            print("PASS: \(label)")
        }

        let identity = "<reply@example.test>"
        let full = MessageStore.save(rawMIME: mail(identity, String(repeating: "full body ", count: 20)))
        let small = MessageStore.save(rawMIME: mail(identity, "short body"))
        check(!MessageStore.all().contains { $0.id == small.id }, "smaller version is hidden from picker")
        check(MessageStore.message(id: small.id)?.id == full.id, "click on hidden version resolves to complete mail")

        let newest = MessageStore.save(rawMIME: mail(identity, String(repeating: "complete body ", count: 30)))
        check(MessageStore.rawMessage(id: full.id) == nil, "superseded MIME is removed")
        check(MessageStore.message(id: full.id)?.id == newest.id, "old banner resolves after MIME cleanup")
        check(MessageStore.rawMessage(id: MessageStore.message(id: small.id)!.id) != nil, "resolved content is readable")
        check(MessageStore.message(id: "removed-version", internetMessageID: "reply@example.test")?.id == newest.id,
              "context identity recovers removed metadata")
        check(MessageStore.message(id: "missing") == nil, "missing ID never selects unrelated mail")

        let anonymous = MessageStore.save(rawMIME: mail(nil, "anonymous body"))
        check(MessageStore.message(id: anonymous.id)?.id == anonymous.id, "mail without Message-ID uses exact content ID")
        // Persisted dates have second precision; make eviction order deterministic.
        for url in try FileManager.default.contentsOfDirectory(at: SharedPaths.messages, includingPropertiesForKeys: nil)
        where url.pathExtension == "json" {
            var metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            metadata["capturedAt"] = "2000-01-01T00:00:00Z"
            try JSONSerialization.data(withJSONObject: metadata).write(to: url)
        }
        for number in 0..<MessageStore.maxStoredMessages + 1 {
            MessageStore.save(rawMIME: mail("<\(number)@example.test>", "new body"))
        }
        check(MessageStore.all().count == MessageStore.maxStoredMessages, "retention limit is respected")
        check(MessageStore.message(id: small.id, internetMessageID: identity) == nil, "evicted logical mail cannot resolve")
        check(!FileManager.default.fileExists(atPath: SharedPaths.messages.appendingPathComponent("\(full.id).json").path),
              "eviction removes version aliases too")
    }
}
