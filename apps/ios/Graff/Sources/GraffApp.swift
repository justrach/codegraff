import SwiftUI

@main
struct GraffApp: App {
    var body: some Scene {
        WindowGroup {
            if CommandLine.arguments.contains("--autotest") {
                AutoTestView()
            } else if CommandLine.arguments.contains("--autotest-signin") {
                AccountView()
            } else if CommandLine.arguments.contains("--autotest-sandboxes") {
                // Headless spin-down check: list the account's sandboxes and stop
                // the first started one, so the flow is verifiable without taps.
                NavigationStack { SandboxesView(onSignOut: {}, autoStopFirstStarted: true) }
            } else if CommandLine.arguments.contains("--autotest-keychain") {
                KeychainCheckView()
            } else if CommandLine.arguments.contains("--autotest-cube") {
                // Headless "build for me" proof: broker a cube, have the agent
                // create a file in it via bash, verify through gateway exec.
                CubeAutoTestView()
            } else if CommandLine.arguments.contains("--autotest-turnstate") {
                // Turn-model invariants (#307/#285/#309) checked in memory —
                // no network, no taps, so it runs anywhere the app launches.
                TurnStateCheckView()
            } else if CommandLine.arguments.contains("--autotest-compose") {
                // Render the new-session compose sheet standalone for visual QA.
                NewSessionView { _ in }
            } else {
                SessionsListView()
            }
        }
    }
}

// Launch with `--autotest-keychain` (+ GRAFF_GATEWAY_KEY in the env) to seed
// the Keychain through the real signIn path and read it straight back —
// proves credential persistence across launches without a device approval.
struct KeychainCheckView: View {
    var body: some View {
        Text(Self.result)
            .font(.system(.body, design: .monospaced))
            .padding()
    }
    static var result: String {
        guard let k = ProcessInfo.processInfo.environment["GRAFF_GATEWAY_KEY"] else {
            return "no GRAFF_GATEWAY_KEY in env"
        }
        Gateway.signIn(key: k)
        guard let back = KeychainStore.get("codegraff-api-key") else { return "keychain store FAILED" }
        return "keychain ok: \(back.prefix(9))… persisted"
    }
}

// Launch with `--autotest` to open the first session and fire one real turn
// through `graff serve` on appear - verifies the live transport on the simulator
// without manual tapping. Harmless in normal runs (gated by the arg).
struct AutoTestView: View {
    @State private var session = sampleSessions[0]
    var body: some View {
        NavigationStack {
            ChatView(session: $session,
                     autoSend: "Reply with one short sentence confirming the serve transport works.")
        }
    }
}

// Launch with `--autotest-turnstate` to assert the turn model's invariants
// in-process — the only regression guard these views have, since the app has no
// test target and CI does not build it. Every line is also printed, so
// `xcrun simctl launch --console-pty … --autotest-turnstate` can gate on
// TURNSTATE-PASS.
struct TurnStateCheckView: View {
    var body: some View {
        Text(Self.report)
            .font(.system(.footnote, design: .monospaced))
            .padding()
    }

    static var report: String {
        var lines: [String] = []
        func check(_ name: String, _ ok: Bool) { lines.append((ok ? "ok   " : "FAIL ") + name) }

        let user = ChatMessage(role: .user, text: "hi")
        let turn = ChatMessage(role: .assistant, text: "", state: .streaming)
        let capturedIndex = [user, turn].count - 1 // what runTurn used to keep

        // #309: hydration lands mid-turn and rewrites the transcript. The live
        // row has moved, so only its id can still find it.
        let history = (0..<4).map { ChatMessage(role: .assistant, text: "old \($0)") }
        var hydrated = history + [user, turn]
        check("hydration invalidates the captured index",
              hydrated[capturedIndex].id != turn.id)
        hydrated.updateTurn(turn.id) { $0.text += "streamed" }
        check("update by id reaches the live turn",
              hydrated.last?.id == turn.id && hydrated.last?.text == "streamed")
        check("update by id touches nothing else",
              hydrated.filter { $0.text == "streamed" }.count == 1)

        // A shorter hydrated array is where the captured index used to trap.
        var dropped = [ChatMessage(role: .user, text: "only")]
        check("captured index is out of bounds after hydration",
              capturedIndex >= dropped.count)
        dropped.updateTurn(turn.id) { $0.text = "must not appear" }
        check("update by id on a dropped turn is a safe no-op",
              dropped.count == 1 && dropped[0].text == "only")

        // #285: a failure updates the turn it belongs to, never appends.
        var failing = [user, turn]
        failing.updateTurn(turn.id) { $0.state = .failed("The network connection was lost.") }
        check("failure stays on one assistant record",
              failing.count == 2 && failing[1].state == .failed("The network connection was lost."))
        check("failure reason is not model prose", failing[1].text.isEmpty)

        // #307: a blank record reloaded from history is finished, not typing.
        check("history defaults to completed",
              ChatMessage(role: .assistant, text: "").state == .completed)
        check("garbage NDJSON does not decode",
              GraffServeClient.decode("<html>502 Bad Gateway</html>") == nil)
        var sawTurn = false
        if case .some(.turn) = GraffServeClient.decode("{\"type\":\"turn\",\"text\":\"done\"}") { sawTurn = true }
        check("a terminal turn record decodes", sawTurn)

        let failures = lines.filter { $0.hasPrefix("FAIL") }.count
        let summary = failures == 0 ? "TURNSTATE-PASS" : "TURNSTATE-FAIL (\(failures))"
        print(summary)
        for l in lines { print(l) }
        return ([summary] + lines).joined(separator: "\n")
    }
}

// MARK: - Liquid Glass helpers
extension View {
    func glassPanel(_ radius: CGFloat = 22) -> some View {
        self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
    func glassCapsule() -> some View {
        self.glassEffect(.regular, in: Capsule())
    }
}

// MARK: - Model
enum Role { case user, assistant }

// How a turn ended. The assistant row has to carry this itself: an empty
// bubble is not evidence that work is still in flight (#307), and a transport
// failure belongs ON the turn instead of becoming a second assistant record
// (#285) or having nowhere to land when the turn is stopped (#59).
enum TurnState: Equatable {
    case streaming
    case completed
    case failed(String)
    case cancelled
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: Role
    var text: String
    var reasoning: String? = nil
    // Defaults to .completed so history (samples, hydrated transcripts) is
    // never mistaken for an in-flight turn; runTurn passes .streaming
    // explicitly for the row it is filling in.
    var state: TurnState = .completed
}

extension Array where Element == ChatMessage {
    // #309: the only way to touch an in-flight turn. Addressing it by its
    // stable id means a hydration that replaces the transcript mid-stream can
    // no longer misapply an event to a historical row - or trap, when the
    // hydrated array is shorter than the index the turn captured.
    mutating func updateTurn(_ id: UUID, _ mutate: (inout ChatMessage) -> Void) {
        guard let i = firstIndex(where: { $0.id == id }) else { return }
        mutate(&self[i])
    }
}

enum TodoStatus {
    case pending, inProgress, completed
    var symbol: String {
        switch self {
        case .pending: return "circle"
        case .inProgress: return "circle.dotted"
        case .completed: return "checkmark.circle.fill"
        }
    }
    var tint: Color {
        switch self {
        case .pending: return .secondary
        case .inProgress: return .blue
        case .completed: return .green
        }
    }
}

struct TodoItem: Identifiable {
    let id = UUID()
    let title: String
    var status: TodoStatus
}

enum SessionStatus: String {
    case working, waiting, idle, done
    var label: String {
        switch self {
        case .working: return "Working"
        case .waiting: return "Waiting on you"
        case .idle: return "Idle"
        case .done: return "Done"
        }
    }
    var symbol: String {
        switch self {
        case .working: return "circle.dotted"
        case .waiting: return "exclamationmark.circle.fill"
        case .idle: return "pause.circle"
        case .done: return "checkmark.circle.fill"
        }
    }
    var tint: Color {
        switch self {
        case .working: return .blue
        case .waiting: return .orange
        case .idle: return .secondary
        case .done: return .green
        }
    }
}

struct AgentSession: Identifiable {
    // Settable so history rows keep their server id across launches; sessions
    // synced from the account are hydrated (transcript fetched) on first open.
    var id = UUID()
    var needsHydration = false
    var title: String
    var model: String
    var status: SessionStatus
    var lastActivity: String
    var todos: [TodoItem]
    var messages: [ChatMessage]
    var planPending: Bool = false
    // Set for sessions running in a cloud sandbox (the cube transport);
    // nil means the env/loopback serve default.
    var cube: CubeConnection? = nil
    var progress: (done: Int, total: Int) {
        (todos.filter { $0.status == .completed }.count, todos.count)
    }
}

let sampleSessions: [AgentSession] = [
    AgentSession(
        title: "Add cube transport to client",
        model: "deepseek-v4-pro",
        status: .working,
        lastActivity: "just now",
        todos: [
            TodoItem(title: "Factor desktop client behind a transport interface", status: .completed),
            TodoItem(title: "Add local serve transport", status: .completed),
            TodoItem(title: "Add cube transport via gateway host-port proxy", status: .inProgress),
            TodoItem(title: "Send required User-Agent header (CF WAF)", status: .pending),
            TodoItem(title: "Decode reasoning / text / turn events", status: .pending),
        ],
        messages: [
            ChatMessage(role: .user, text: "Wire up the cube transport so the app streams from a sandbox."),
            ChatMessage(role: .assistant, text: "On it. I'll add a third transport alongside tauri and serve, routing HTTP/NDJSON through the gateway host-port proxy with a tenant-scoped capability header.", reasoning: "serve and cube share the NDJSON contract - only base URL + auth header differ."),
        ]
    ),
    AgentSession(
        title: "Extend graff serve exec timeout",
        model: "deepseek-v4-pro",
        status: .waiting,
        lastActivity: "2m ago",
        todos: [
            TodoItem(title: "Locate the ~100s exec timeout", status: .completed),
            TodoItem(title: "Make it configurable", status: .inProgress),
            TodoItem(title: "Plumb through to the orchestrator", status: .pending),
        ],
        messages: [
            ChatMessage(role: .user, text: "The persistent serve session dies at ~100s. Extend it."),
            ChatMessage(role: .assistant, text: "I've drafted a plan to make the exec timeout configurable and raise the default for serve. Implement it?"),
        ],
        planPending: true
    ),
    AgentSession(
        title: "Notarize v0.0.16 build",
        model: "deepseek-v4-pro",
        status: .done,
        lastActivity: "1h ago",
        todos: [
            TodoItem(title: "Sign the .app", status: .completed),
            TodoItem(title: "Submit to notary", status: .completed),
            TodoItem(title: "Staple the ticket", status: .completed),
        ],
        messages: [
            ChatMessage(role: .user, text: "Notarize the release build."),
            ChatMessage(role: .assistant, text: "Done - signed, notarized (Accepted), stapled. spctl assessment passes."),
        ]
    ),
]
