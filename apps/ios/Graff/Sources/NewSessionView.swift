import SwiftUI

// "+" on Sessions: describe the task, watch the cube spin up (sandbox ->
// install -> serve -> preview), then chat with graff building in YOUR
// sandbox. The broker is the same one `graff cube new` runs in the CLI.
struct NewSessionView: View {
    var onCreated: (AgentSession) -> Void
    @Environment(\.dismiss) private var dismiss

    private enum Phase { case compose, launching, chat, failed(String) }
    @State private var phase: Phase = .compose
    @State private var prompt = ""
    @State private var steps: [String] = []
    @State private var session = AgentSession(title: "New session", model: "codegraff", status: .working,
                                              lastActivity: "now", todos: [], messages: [])
    @State private var signedIn = Gateway.apiKey != nil
    @State private var showAccount = false
    @State private var handedOff = false

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .compose: compose
                case .launching: launching
                case .chat:
                    ChatView(session: $session, autoSend: prompt)
                        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { finish() } } }
                case .failed(let msg): failedView(msg)
                }
            }
        }
        .onDisappear { finish() }
    }

    private var compose: some View {
        VStack(spacing: 18) {
            Image(systemName: "shippingbox").font(.system(size: 44)).foregroundStyle(.tint)
            Text("Build in a cube").font(.title2.bold())
            Text("graff gets a fresh cloud sandbox on your account and starts working on this.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            TextField("What should graff build?", text: $prompt, axis: .vertical)
                .lineLimit(2...5)
                .padding(14)
                .glassPanel(18)
            if signedIn {
                Button {
                    phase = .launching
                    Task { await launch() }
                } label: {
                    Label("Start building", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty)
            } else {
                Button("Sign in to codegraff first") { showAccount = true }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .navigationTitle("New session")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAccount, onDismiss: { signedIn = Gateway.apiKey != nil }) { AccountView() }
    }

    private var launching: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                HStack(spacing: 10) {
                    if i == steps.count - 1 {
                        ProgressView()
                    } else {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    Text(s).font(.callout)
                }
            }
        }
        .padding(20)
        .glassPanel(22)
        .padding()
        .navigationTitle("Spinning up")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func failedView(_ msg: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
            Text("Spin-up failed").font(.headline)
            Text(msg).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Try again") { phase = .compose }.buttonStyle(.borderedProminent)
        }
        .padding()
    }

    @MainActor
    private func launch() async {
        do {
            let conn = try await CubeBroker.launch(purpose: "graff-ios") { msg in steps.append(msg) }
            let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = trimmed.count > 42 ? String(trimmed.prefix(42)) + "…" : trimmed
            session = AgentSession(title: title.isEmpty ? "Cloud session" : title, model: "codegraff",
                                   status: .working, lastActivity: "now", todos: [], messages: [], cube: conn)
            phase = .chat
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // Hand the session (with whatever transcript it accumulated) back to the
    // list exactly once, whether the user taps Done or swipes the sheet away.
    private func finish() {
        guard !handedOff else { dismiss(); return }
        if case .chat = phase {
            handedOff = true
            onCreated(session)
        }
        dismiss()
    }
}

// Launch with `--autotest-cube` (+ GRAFF_GATEWAY_KEY): brokers a real cube on
// the account, has the agent BUILD something in it (a file, via its bash tool
// in a yolo session), then verifies the artifact from OUTSIDE the serve pipe
// (gateway exec) and prints PASS/FAIL — the whole "phone asks, sandbox
// builds" loop with no taps.
struct CubeAutoTestView: View {
    @State private var lines: [String] = ["cube autotest…"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                    Text(l).font(.system(.footnote, design: .monospaced))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .task { await run() }
    }

    @MainActor
    private func run() async {
        guard let k = ProcessInfo.processInfo.environment["GRAFF_GATEWAY_KEY"] else {
            lines.append("FAIL: no GRAFF_GATEWAY_KEY in env")
            return
        }
        Gateway.signIn(key: k)
        do {
            let conn = try await CubeBroker.launch(purpose: "ios-cube-autotest") { msg in lines.append(msg) }
            lines.append("cube ready: \(conn.sandboxID)")
            lines.append("base: \(conn.base)")
            let client = GraffServeClient(cube: conn)
            let sid = try await client.createSession(model: "codegraff", yolo: true)
            lines.append("session: \(sid)")
            lines.append("asking graff to build…")
            for try await ev in client.streamTurn(sessionID: sid,
                text: "Using bash, write the exact text BUILT-FROM-IOS into /tmp/built-from-ios.txt. Then reply DONE.") {
                switch ev {
                case .toolCall(let name): lines.append("  tool: \(name)")
                case .turn(let text, _, _): lines.append("  turn: \(String(text.prefix(80)))")
                case .error(let m): lines.append("  error: \(m)")
                default: break
                }
            }
            let check = try await Gateway.exec(conn.sandboxID, command: "cat /tmp/built-from-ios.txt", timeoutSeconds: 20)
            let content = (check.result ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("sandbox file: \(content)")
            lines.append(content == "BUILT-FROM-IOS" ? "CUBE-BUILD-PASS" : "CUBE-BUILD-FAIL")

            // GitHub: prove the cube carries the account's repo access — the
            // same check the CLI verify runs, from the app's own pipeline.
            if let login = conn.githubLogin {
                let gh = try await Gateway.exec(conn.sandboxID,
                    command: "GH_TOKEN=$(cat $HOME/.cube-github-token) $HOME/bin/gh api /installation/repositories -q .total_count",
                    timeoutSeconds: 30)
                let n = (gh.result ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                lines.append("gh sees \(n) repos as \(login)")
                lines.append(Int(n) != nil ? "CUBE-GH-PASS" : "CUBE-GH-FAIL")
            } else {
                lines.append("CUBE-GH-SKIP (github not connected)")
            }

            // History: round-trip a transcript through the account store.
            let hist = AgentSession(title: "cube autotest", model: "codegraff", status: .done,
                                    lastActivity: "now", todos: [],
                                    messages: [ChatMessage(role: .user, text: "autotest build"),
                                               ChatMessage(role: .assistant, text: "DONE")],
                                    cube: conn)
            let hid = hist.id.uuidString.lowercased()
            try await Gateway.putAppSession(id: hid, title: hist.title, model: hist.model,
                                            sandboxID: conn.sandboxID,
                                            transcript: AppSessionSync.transcriptJSON(hist.messages))
            let back = try await Gateway.fetchAppSession(hid)
            let msgs = AppSessionSync.messages(fromTranscript: back.transcript)
            lines.append("history: \(msgs.count) msgs round-tripped")
            lines.append(msgs.count == 2 && msgs[1].text == "DONE" ? "CUBE-HIST-PASS" : "CUBE-HIST-FAIL")
            try? await Gateway.deleteAppSession(hid)
        } catch {
            lines.append("FAIL: \(error.localizedDescription)")
        }
    }
}
