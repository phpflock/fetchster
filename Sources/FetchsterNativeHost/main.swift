import Foundation

// Native messaging host for the Fetchster browser extension.
//
// Chrome/Edge/Brave launch this executable when the extension sends a
// message, then exchange JSON over stdin/stdout framed with a 4-byte
// native-endian length prefix. This host bridges those messages to the
// Fetchster app's existing loopback control server on 127.0.0.1:8765.

private let serverBase = "http://127.0.0.1:8765"
private let session = URLSession(configuration: .ephemeral)

func readExactly(_ count: Int) -> Data? {
    var data = Data()
    while data.count < count {
        guard let chunk = try? FileHandle.standardInput.read(upToCount: count - data.count),
              !chunk.isEmpty else {
            return nil
        }
        data.append(chunk)
    }
    return data
}

func readFrame() -> Data? {
    guard let lengthData = readExactly(4) else { return nil }
    let length = lengthData.withUnsafeBytes { raw in
        raw.loadUnaligned(as: UInt32.self)
    }
    guard length > 0, length < 16 * 1024 * 1024 else { return nil }
    return readExactly(Int(length))
}

func writeFrame(_ object: [String: Any]) {
    guard JSONSerialization.isValidJSONObject(object),
          let payload = try? JSONSerialization.data(withJSONObject: object) else {
        return
    }
    var length = UInt32(payload.count)
    var out = Data()
    out.append(Data(bytes: &length, count: 4))
    out.append(payload)
    FileHandle.standardOutput.write(out)
}

func callApp(path: String, jsonBody: [String: Any]?) -> [String: Any] {
    guard let url = URL(string: serverBase + path) else {
        return ["ok": false, "error": "Invalid app URL"]
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    if let jsonBody {
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: jsonBody)
    }

    let semaphore = DispatchSemaphore(value: 0)
    var result: [String: Any] = ["ok": false, "error": "No response from Fetchster"]
    let task = session.dataTask(with: request) { data, _, error in
        defer { semaphore.signal() }
        if let error {
            result = ["ok": false, "error": error.localizedDescription]
            return
        }
        if let data,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            result = object
        } else {
            result = ["ok": false, "error": "Invalid response from Fetchster"]
        }
    }
    task.resume()
    semaphore.wait()
    return result
}

while let frame = readFrame() {
    let message = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any] ?? [:]

    if let type = message["type"] as? String, type == "ping" {
        writeFrame(callApp(path: "/api/ping", jsonBody: nil))
        continue
    }

    if let type = message["type"] as? String, type == "youtube" {
        var body: [String: Any] = [:]
        for key in ["videoId", "format", "browser"] {
            if let value = message[key] {
                body[key] = value
            }
        }
        if body["format"] == nil { body["format"] = "b" }
        if body["browser"] == nil { body["browser"] = "safari" }
        writeFrame(callApp(path: "/api/youtube", jsonBody: body))
        continue
    }

    var body: [String: Any] = [:]
    for key in ["url", "filename", "userAgent", "referer", "title"] {
        if let value = message[key] {
            body[key] = value
        }
    }
    writeFrame(callApp(path: "/api/download", jsonBody: body))
}

exit(0)
