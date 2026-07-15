import SwiftUI

struct ChatView: View {
    @Binding var session: AgentSession
    var autoSend: String? = nil

    @State private var draft: String = ""
    // Cube sessions carry their own transport; everything else uses the
    // env/loopback default (local serve on the host Mac).
    private var client: GraffServeClient {
        session.cube.map { GraffServeClient(cube: $0) } ?? GraffServeClient()
    }
    @State private var serveSessionID: String?
    @State private var streaming = false
    @State private var didAutoSend = false

    private enum CubeLiveness { case unknown, alive, stopped, gone }
    @State private var cubeLiveness: CubeLiveness = .unknown
    @State private var resuming = false
    @State private var didHydrate = false

    var body: some View {
        VStack(spacing: 0) {
            if !session.todos.isEmpty {
                TaskProgressCard(session: session)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(session.messages) { msg in
                            MessageBubble(message: msg).id(msg.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: session.messages.last?.text) {
                    if let last = session.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            if session.planPending {
                PlanDecisionBar(
                    onImplement: {
                        session.planPending = false
                        session.status = .working
                    },
                    onKeepPlanning: { session.planPending = false }
                )
                .padding(.horizontal)
                .padding(.bottom, 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if session.cube != nil && (cubeLiveness == .stopped || cubeLiveness == .gone) {
                CubeStatusBar(
                    message: cubeLiveness == .stopped
                        ? "This cube is stopped. Waking it resumes sandbox billing (no reinstall)."
                        : "This cube is gone. Resuming creates a fresh sandbox — full spin-up (~1 min) billed to your account.",
                    resuming: resuming,
                    onResume: { Task { await resumeCube() } }
                )
                .padding(.horizontal)
                .padding(.bottom, 6)
            }

            Composer(draft: $draft, streaming: streaming,
                     disabled: session.cube != nil && cubeLiveness != .alive && cubeLiveness != .unknown,
                     onSend: send)
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .animation(.snappy, value: session.planPending)
        .task {
            await hydrateIfNeeded()
            await probeCube()
            if let p = autoSend, !didAutoSend {
                didAutoSend = true
                draft = p
                send()
            }
        }
    }

    private func send() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !streaming else { return }
        draft = ""
        session.messages.append(ChatMessage(role: .user, text: t))
        streaming = true
        session.status = .working
        Task { await runTurn(t) }
    }

    // For cube sessions the agent is told where it is and what credentials it
    // carries — without this, models reflexively claim they have no GitHub
    // access even when gh + git are fully provisioned.
    private var cubeSystemNote: String? {
        guard let cube = session.cube else { return nil }
        var note = "You are graff running inside a disposable cloud sandbox (a codegraff cube) on the user's account. Work directly: run commands, edit files, build."
        if let login = cube.githubLogin {
            note += " GitHub is pre-authenticated as \(login): git clone/push over https works via the credential store, and the gh CLI is installed with GH_TOKEN set (1-hour installation token). Use https://github.com/OWNER/REPO URLs."
        } else {
            note += " GitHub is NOT connected for this account, so you have no repo credentials."
        }
        return note
    }

    @MainActor
    private func runTurn(_ text: String) async {
        defer { streaming = false }
        do {
            if serveSessionID == nil {
                serveSessionID = try await client.createSession(model: session.model,
                                                                yolo: session.cube != nil,
                                                                appendSystemPrompt: cubeSystemNote)
            }
            session.messages.append(ChatMessage(role: .assistant, text: ""))
            let idx = session.messages.count - 1
            for try await ev in client.streamTurn(sessionID: serveSessionID!, text: text) {
                switch ev {
                case .reasoning(let r):
                    session.messages[idx].reasoning = (session.messages[idx].reasoning ?? "") + r
                case .text(let d):
                    session.messages[idx].text += d
                case .turn(let final, _, _):
                    session.messages[idx].text = final
                case .error(let m):
                    session.messages[idx].text = "Error: " + m
                case .toolCall(let name):
                    session.messages[idx].reasoning = ((session.messages[idx].reasoning ?? "") + "\n⚙️ \(name)")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                case .other:
                    break
                }
            }
            session.status = .idle
        } catch {
            session.messages.append(ChatMessage(role: .assistant,
                text: "Transport error: \(error.localizedDescription)"))
            session.status = .idle
        }
        session.lastActivity = "just now"
        AppSessionSync.save(session)
    }

    @MainActor
    private func hydrateIfNeeded() async {
        guard session.needsHydration, !didHydrate else { return }
        didHydrate = true
        if let full = try? await Gateway.fetchAppSession(session.id.uuidString.lowercased()) {
            session.messages = AppSessionSync.messages(fromTranscript: full.transcript)
            session.needsHydration = false
        }
    }

    @MainActor
    private func probeCube() async {
        guard let cube = session.cube else { return }
        let state = (try? await Gateway.sandboxInfo(cube.sandboxID))?.state
        cubeLiveness = state == "started" ? .alive : (state == "stopped" ? .stopped : .gone)
    }

    @MainActor
    private func resumeCube() async {
        resuming = true
        defer { resuming = false }
        // Seed the broker with THIS session's cube so a stopped one is woken
        // rather than a different stored cube being reused.
        session.cube?.store()
        do {
            let conn = try await CubeBroker.launch(purpose: "graff-ios") { _ in }
            session.cube = conn
            serveSessionID = nil // fresh serve session in the (re)woken cube
            cubeLiveness = .alive
            AppSessionSync.save(session)
        } catch {
            session.messages.append(ChatMessage(role: .assistant,
                text: "Resume failed: \(error.localizedDescription)"))
        }
    }
}

struct TaskProgressCard: View {
    let session: AgentSession
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Task progress", systemImage: "checklist")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(session.progress.done)/\(session.progress.total)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            ForEach(session.todos) { todo in
                HStack(spacing: 8) {
                    Image(systemName: todo.status.symbol)
                        .foregroundStyle(todo.status.tint)
                        .symbolEffect(.pulse, isActive: todo.status == .inProgress)
                    Text(todo.title)
                        .font(.callout)
                        .strikethrough(todo.status == .completed, color: .secondary)
                        .foregroundStyle(todo.status == .completed ? .secondary : .primary)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(16)
        .glassPanel(22)
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    private var isBlank: Bool { message.text.isEmpty && (message.reasoning?.isEmpty ?? true) }
    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 6) {
                if let r = message.reasoning, !r.isEmpty {
                    Label(r, systemImage: "brain")
                        .font(.caption).italic()
                        .foregroundStyle(.secondary)
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .foregroundStyle(message.role == .user ? Color.white : Color.primary)
                } else if message.role == .assistant && isBlank {
                    TypingIndicator()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(message.role == .user ? Color.blue.opacity(0.9) : Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }
}

// Three pulsing dots shown in the assistant bubble while a turn is in flight
// but no reasoning/text has streamed yet (e.g. during a tool call) - so an
// in-progress turn never looks like an empty, stuck bubble.
struct TypingIndicator: View {
    @State private var animating = false
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Circle()
                    .frame(width: 7, height: 7)
                    .foregroundStyle(.secondary)
                    .scaleEffect(animating ? 1.0 : 0.5)
                    .opacity(animating ? 1.0 : 0.4)
                    .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true).delay(Double(i) * 0.2), value: animating)
            }
        }
        .padding(.vertical, 2)
        .onAppear { animating = true }
    }
}

struct PlanDecisionBar: View {
    let onImplement: () -> Void
    let onKeepPlanning: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Label("Plan ready for review", systemImage: "list.clipboard")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                Button("Keep planning", action: onKeepPlanning)
                    .buttonStyle(.glass)
                Button("Implement plan", action: onImplement)
                    .buttonStyle(.glassProminent)
            }
        }
        .padding(16)
        .glassPanel(22)
    }
}

struct Composer: View {
    @Binding var draft: String
    var streaming: Bool = false
    var disabled: Bool = false
    let onSend: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            TextField(disabled ? "Resume the cube to continue" : "Type a message", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .glassCapsule()
                .disabled(streaming || disabled)
            Button(action: onSend) {
                Image(systemName: streaming ? "ellipsis" : "arrow.up")
                    .font(.headline.weight(.bold))
            }
            .buttonStyle(.glassProminent)
            .disabled(streaming || disabled || draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

// Shown when a session's cube is stopped or gone: the history stays readable,
// but continuing costs money — say exactly which kind before the user pays it.
struct CubeStatusBar: View {
    let message: String
    let resuming: Bool
    let onResume: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Label(message, systemImage: "shippingbox")
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onResume) {
                if resuming { ProgressView() } else { Text("Resume cube") }
            }
            .buttonStyle(.glassProminent)
            .disabled(resuming)
        }
        .padding(16)
        .glassPanel(22)
    }
}
