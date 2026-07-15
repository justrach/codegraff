import Foundation

// Events decoded from the graff serve NDJSON stream (one JSON object per line).
enum GraffEvent {
    case reasoning(String)
    case text(String)
    case toolCall(name: String)
    case turn(text: String, contextTokens: Int, costUSD: Double)
    case error(String)
    case other(String)
}

enum GraffError: LocalizedError {
    case badResponse(String)
    var errorDescription: String? {
        switch self { case .badResponse(let s): return s }
    }
}

// Local `serve` transport: POST /v1/sessions -> session_id, then
// POST /v1/sessions/{id} with a stdio-protocol request, streamed back as NDJSON.
// The simulator's localhost maps to the host Mac, so 127.0.0.1:8787 reaches
// `graff serve`. The `cube` transport is this same client with a different base
// URL + token: the launch environment overrides the loopback defaults so the
// app can point at a remote serve (e.g. a sandbox preview URL) without a rebuild.
struct GraffServeClient {
    var base: String = ProcessInfo.processInfo.environment["GRAFF_SERVE_BASE"] ?? "http://127.0.0.1:8787"
    var token: String? = ProcessInfo.processInfo.environment["GRAFF_SERVE_TOKEN"]
    var previewToken: String? = ProcessInfo.processInfo.environment["GRAFF_SERVE_PREVIEW_TOKEN"]

    init() {}
    // The cube transport proper: same NDJSON contract, pointed at a sandbox
    // preview URL with the Daytona token alongside the serve bearer.
    init(cube: CubeConnection) {
        base = cube.base
        token = cube.serveToken
        previewToken = cube.previewToken
    }

    private func makeRequest(_ path: String, method: String, json: [String: Any]? = nil) -> URLRequest {
        var r = URLRequest(url: URL(string: base + path)!)
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("Graff-iOS/0.1", forHTTPHeaderField: "User-Agent") // CF WAF rejects empty UA on the gateway path
        if let token { r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let previewToken { r.setValue(previewToken, forHTTPHeaderField: "x-daytona-preview-token") }
        if let json { r.httpBody = try? JSONSerialization.data(withJSONObject: json) }
        return r
    }

    // serve answers 201 for session create and 200 for the turn stream - accept any 2xx.
    private static func ok(_ resp: URLResponse?) -> Bool {
        (200...299).contains((resp as? HTTPURLResponse)?.statusCode ?? 0)
    }
    private static func status(_ resp: URLResponse?) -> Int {
        (resp as? HTTPURLResponse)?.statusCode ?? -1
    }

    // yolo=true asks serve for a session whose tools run without approval
    // prompts — right for cube sessions in a disposable sandbox, never for
    // a serve on your own machine.
    func createSession(model: String, yolo: Bool = false, appendSystemPrompt: String? = nil) async throws -> String {
        var body: [String: Any] = ["model": model]
        if yolo { body["yolo"] = true }
        if let appendSystemPrompt { body["append_system_prompt"] = appendSystemPrompt }
        let (data, resp) = try await URLSession.shared.data(for: makeRequest("/v1/sessions", method: "POST", json: body))
        guard Self.ok(resp),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = obj["session_id"] as? String else {
            throw GraffError.badResponse("create HTTP \(Self.status(resp))")
        }
        return id
    }

    func streamTurn(sessionID: String, text: String) -> AsyncThrowingStream<GraffEvent, Error> {
        var req = makeRequest("/v1/sessions/" + sessionID, method: "POST", json: ["type": "user", "text": text])
        req.timeoutInterval = 600 // build turns can run for minutes between events
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    guard Self.ok(resp) else {
                        continuation.finish(throwing: GraffError.badResponse("turn HTTP \(Self.status(resp))"))
                        return
                    }
                    for try await line in bytes.lines {
                        guard !line.isEmpty, let ev = Self.decode(line) else { continue }
                        continuation.yield(ev)
                        if case .turn = ev { break }
                        if case .error = ev { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func decode(_ line: String) -> GraffEvent? {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String else { return nil }
        switch type {
        case "reasoning": return .reasoning(obj["text"] as? String ?? "")
        case "text":      return .text(obj["text"] as? String ?? "")
        case "tool_call": return .toolCall(name: obj["name"] as? String ?? "tool")
        case "turn":      return .turn(text: obj["text"] as? String ?? "",
                                       contextTokens: obj["context_tokens"] as? Int ?? 0,
                                       costUSD: obj["cost_usd"] as? Double ?? 0)
        case "error":     return .error(obj["message"] as? String ?? "error")
        default:          return .other(type)
        }
    }
}
