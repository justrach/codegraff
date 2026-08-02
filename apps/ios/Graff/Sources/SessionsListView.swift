import SwiftUI

struct SessionsListView: View {
    // #316: this list only ever holds the signed-in account's real history.
    // It used to open on `sampleSessions` when signed out — fabricated rows
    // with realistic titles, models, progress and timestamps, and nothing
    // marking them as examples, so a fresh install looked like it had
    // retained someone's account data. Signed out now means an empty list and
    // a sign-in call to action; the fixtures stay behind `--autotest`.
    @State private var sessions: [AgentSession] = []
    @State private var signedIn = Gateway.apiKey != nil
    @State private var showAccount = false
    @State private var showNewSession = false
    @State private var loadNote = ""
    @State private var needsSessionRelogin = false

    var body: some View {
        NavigationStack {
            List {
                if !signedIn {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("You're not signed in").font(.headline)
                        Text("Sign in with your codegraff account to see your sessions here. Nothing is shown until then — this list only ever contains your own history.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Sign in") { showAccount = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 6)
                }
                if !loadNote.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(loadNote).font(.footnote).foregroundStyle(.secondary)
                        if needsSessionRelogin {
                            Button("Sign in again") {
                                Gateway.signOut()
                                sessions = []
                                signedIn = false
                                showAccount = true
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
                ForEach($sessions) { $session in
                    NavigationLink {
                        ChatView(session: $session)
                    } label: {
                        SessionRow(session: session)
                    }
                }
                .onDelete { offsets in
                    let doomed = offsets.map { sessions[$0] }
                    sessions.remove(atOffsets: offsets)
                    // #310: routed through the sync engine so the DELETE is
                    // ordered against this session's in-flight saves and the id
                    // is tombstoned — a late PUT can no longer resurrect it.
                    for s in doomed { AppSessionSync.delete(s.id) }
                }
            }
            .navigationTitle("Sessions")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showAccount = true } label: { Image(systemName: "person.crop.circle") }
                        .buttonStyle(.glass)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNewSession = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.glass)
                }
            }
            .sheet(isPresented: $showAccount, onDismiss: { Task { await loadHistory() } }) { AccountView() }
            .sheet(isPresented: $showNewSession) {
                NewSessionView { newSession in
                    sessions.insert(newSession, at: 0)
                    AppSessionSync.save(newSession)
                }
            }
            .refreshable { await loadHistory() }
            .task { await loadHistory() }
        }
    }

    // Rebuild the list from /v1/app/sessions. Rows carry no transcript — they
    // hydrate when opened. A row whose cube matches the locally stored
    // connection is fully attachable; otherwise it keeps just the sandbox id
    // (ChatView offers a resume, which re-keys or respins as needed).
    @MainActor
    private func loadHistory() async {
        // #316: signed out is an honest empty state, not a fixture gallery.
        guard Gateway.apiKey != nil else {
            signedIn = false
            sessions = []
            loadNote = ""
            needsSessionRelogin = false
            return
        }
        signedIn = true
        do {
            let rows = try await Gateway.listAppSessions()
            // #286: a failed sandbox listing is not evidence that anything
            // finished. Keep it nil so rows fall back to what we already knew,
            // or to Unknown — never to a manufactured Done.
            var started: Set<String>? = nil
            var livenessNote = ""
            do {
                started = Set(try await Gateway.sandboxes().filter { $0.state == "started" }.map(\.id))
            } catch {
                livenessNote = "Sandbox state unavailable — cube status may be out of date."
            }
            // Outcomes already read from a transcript survive a reload; only
            // liveness-derived guesses are recomputed.
            let priorStatus = Dictionary(sessions.map { ($0.id, $0.status) },
                                         uniquingKeysWith: { first, _ in first })
            let localCube = CubeConnection.stored()
            sessions = rows.map { row in
                var s = AgentSession(title: row.title.isEmpty ? "Session" : row.title,
                                     model: row.model.isEmpty ? "codegraff" : row.model,
                                     status: .idle,
                                     lastActivity: Self.relative(row.updated_at),
                                     todos: [], messages: [])
                s.id = UUID(uuidString: row.id) ?? UUID()
                s.needsHydration = true
                let prior = priorStatus[s.id]
                if let sb = row.sandbox_id {
                    if let lc = localCube, lc.sandboxID == sb {
                        s.cube = lc
                    } else {
                        // Known cube, no local credentials (e.g. new device):
                        // resumable via re-key, never via these empty fields.
                        s.cube = CubeConnection(sandboxID: sb, base: "", serveToken: "",
                                                previewToken: nil, githubLogin: nil)
                    }
                }
                s.status = Self.rowStatus(prior: prior, sandbox: row.sandbox_id, started: started)
                return s
            }
            needsSessionRelogin = false
            let emptyNote = sessions.isEmpty ? "No sessions yet — tap + to build something." : ""
            loadNote = [emptyNote, livenessNote].filter { !$0.isEmpty }.joined(separator: "\n")
        } catch {
            if let gatewayError = error as? GatewayError,
               gatewayError.isInsufficientSessionScope {
                needsSessionRelogin = true
                loadNote = "This sign-in predates session sync. Sign in again to renew access."
            } else {
                needsSessionRelogin = false
                loadNote = error.localizedDescription
            }
        }
    }

    // #286: the whole liveness→status decision, kept pure so the invariant is
    // checkable in-process (--autotest-turnstate) without a network or a tap.
    //
    //   * an outcome already read from the transcript always wins;
    //   * `started == nil` means the sandbox listing FAILED — that is unknown,
    //     never Done;
    //   * a stopped/gone sandbox has only Ended: the gateway exposes no task
    //     outcome on the sandbox (only a liveness `state`), so success must not
    //     be inferred from a sandbox that is no longer running.
    static func rowStatus(prior: SessionStatus?, sandbox: String?, started: Set<String>?) -> SessionStatus {
        if let prior, prior.isTranscriptOutcome { return prior }
        guard let sandbox else { return prior ?? .idle }
        guard let started else { return prior ?? .unknown }
        return started.contains(sandbox) ? .idle : .ended
    }

    private static func relative(_ epoch: Int) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: Date(timeIntervalSince1970: TimeInterval(epoch)), relativeTo: Date())
    }
}

struct SessionRow: View {
    let session: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(session.title).font(.headline).lineLimit(1)
                Spacer()
                StatusChip(status: session.status)
            }
            HStack(spacing: 10) {
                Label(session.model, systemImage: "cpu")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if session.cube != nil {
                    Label("cube", systemImage: "shippingbox")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !session.todos.isEmpty {
                    Text("\(session.progress.done)/\(session.progress.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(session.lastActivity).font(.caption2).foregroundStyle(.tertiary)
            }
            if !session.todos.isEmpty {
                ProgressView(value: Double(session.progress.done),
                             total: Double(max(session.progress.total, 1)))
                    .tint(session.status.tint)
            }
        }
        .padding(.vertical, 4)
    }
}

struct StatusChip: View {
    let status: SessionStatus
    var body: some View {
        Label(status.label, systemImage: status.symbol)
            .font(.caption2.weight(.medium))
            .foregroundStyle(status.tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassCapsule()
    }
}
