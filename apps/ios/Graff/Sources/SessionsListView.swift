import SwiftUI

struct SessionsListView: View {
    // Signed in → the account's synced history; signed out → demo scaffolding.
    @State private var sessions = Gateway.apiKey != nil ? [] : sampleSessions
    @State private var showAccount = false
    @State private var showNewSession = false
    @State private var loadNote = ""

    var body: some View {
        NavigationStack {
            List {
                if !loadNote.isEmpty {
                    Text(loadNote).font(.footnote).foregroundStyle(.secondary)
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
                    for s in doomed {
                        let id = s.id.uuidString.lowercased()
                        Task.detached { try? await Gateway.deleteAppSession(id) }
                    }
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
        guard Gateway.apiKey != nil else { return }
        do {
            let rows = try await Gateway.listAppSessions()
            let live = (try? await Gateway.sandboxes()) ?? []
            let started = Set(live.filter { $0.state == "started" }.map(\.id))
            let localCube = CubeConnection.stored()
            sessions = rows.map { row in
                var s = AgentSession(title: row.title.isEmpty ? "Session" : row.title,
                                     model: row.model.isEmpty ? "codegraff" : row.model,
                                     status: .idle,
                                     lastActivity: Self.relative(row.updated_at),
                                     todos: [], messages: [])
                s.id = UUID(uuidString: row.id) ?? UUID()
                s.needsHydration = true
                if let sb = row.sandbox_id {
                    if let lc = localCube, lc.sandboxID == sb {
                        s.cube = lc
                    } else {
                        // Known cube, no local credentials (e.g. new device):
                        // resumable via re-key, never via these empty fields.
                        s.cube = CubeConnection(sandboxID: sb, base: "", serveToken: "",
                                                previewToken: nil, githubLogin: nil)
                    }
                    s.status = started.contains(sb) ? .idle : .done
                }
                return s
            }
            loadNote = sessions.isEmpty ? "No sessions yet — tap + to build something." : ""
        } catch {
            loadNote = error.localizedDescription
        }
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
