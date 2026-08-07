import Foundation
import SafariServices

let SFExtensionMessageKey = "message"

/// Receives native-messaging messages from the Safari web extension
/// (browser.runtime.sendNativeMessage) and forwards them to the Fetchster
/// app's loopback control server on 127.0.0.1:8765.
class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private let appBase = URL(string: "http://127.0.0.1:8765")!
    private let session = URLSession(configuration: .ephemeral)

    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any] ?? [:]
        handle(message) { response in
            let reply = NSExtensionItem()
            reply.userInfo = [SFExtensionMessageKey: response]
            context.completeRequest(returningItems: [reply], completionHandler: nil)
        }
    }

    private func handle(_ message: [String: Any], completion: @escaping ([String: Any]) -> Void) {
        let type = message["type"] as? String ?? "capture"
        switch type {
        case "ping":
            call(path: "/api/ping", body: nil, completion: completion)

        case "youtube":
            var body: [String: Any] = [:]
            for key in ["videoId", "format", "browser"] {
                if let value = message[key] { body[key] = value }
            }
            if body["format"] == nil { body["format"] = "b" }
            if body["browser"] == nil { body["browser"] = "safari" }
            call(path: "/api/youtube", body: body, completion: completion)

        default:
            var body: [String: Any] = [:]
            for key in ["url", "filename", "userAgent", "referer"] {
                if let value = message[key] { body[key] = value }
            }
            call(path: "/api/download", body: body, completion: completion)
        }
    }

    private func call(path: String,
                      body: [String: Any]?,
                      completion: @escaping ([String: Any]) -> Void) {
        guard let url = URL(string: path, relativeTo: appBase) else {
            completion(["ok": false, "error": "Invalid app URL"])
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        session.dataTask(with: request) { data, _, error in
            if let error {
                completion(["ok": false, "error": error.localizedDescription])
                return
            }
            if let data,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                completion(object)
            } else {
                completion(["ok": false, "error": "Invalid response from Fetchster"])
            }
        }.resume()
    }
}
