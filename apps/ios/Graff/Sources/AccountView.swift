import SwiftUI

// Account sheet: device-code sign-in to codegraff (same flow as `graff
// login`), then the account's sandboxes with spin-down.
struct AccountView: View {
    @State private var signedIn = Gateway.apiKey != nil

    var body: some View {
        NavigationStack {
            if signedIn {
                SandboxesView(onSignOut: {
                    Gateway.signOut()
                    signedIn = false
                })
            } else {
                DeviceSignInView(onSignedIn: { signedIn = true })
            }
        }
    }
}

struct DeviceSignInView: View {
    var onSignedIn: () -> Void
    @State private var start: DeviceStart?
    @State private var status = ""
    @State private var failed = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Sign in to codegraff").font(.title2.bold())
            if let start {
                Text("Enter this code at codegraff.com:")
                    .foregroundStyle(.secondary)
                Text(start.user_code)
                    .font(.system(.largeTitle, design: .monospaced).bold())
                    .padding(.horizontal, 24).padding(.vertical, 12)
                    .glassPanel()
                if let s = start.verification_uri_complete ?? start.verification_uri,
                   let url = URL(string: s) {
                    Link("Open codegraff.com", destination: url)
                        .buttonStyle(.borderedProminent)
                }
                Text(status.isEmpty ? "Waiting for approval…" : status)
                    .font(.footnote).foregroundStyle(.secondary)
            } else if failed {
                Text(status).foregroundStyle(.red).font(.footnote)
                Button("Try again") {
                    failed = false
                    Task { await run() }
                }
                .buttonStyle(.borderedProminent)
            } else {
                ProgressView("Requesting device code…")
            }
        }
        .padding()
        .navigationTitle("Account")
        .task { await run() }
    }

    private func run() async {
        do {
            let s = try await Gateway.deviceStart()
            start = s
            let interval = max(1, s.interval ?? 2)
            var waited = 0
            let expires = s.expires_in ?? 600
            while waited < expires {
                try await Task.sleep(for: .seconds(interval))
                waited += interval
                let (st, key) = (try? await Gateway.devicePoll(s.device_code)) ?? ("pending", nil)
                if st == "ok", let key {
                    Gateway.signIn(key: key)
                    onSignedIn()
                    return
                } else if st == "denied" || st == "expired" {
                    status = "Authorization \(st)"
                    failed = true
                    start = nil
                    return
                }
            }
            status = "Timed out waiting for approval"
            failed = true
            start = nil
        } catch {
            status = error.localizedDescription
            failed = true
            start = nil
        }
    }
}

// The account's gateway sandboxes. Started ones can be spun down right here -
// the same operation as `graff sandboxes stop <id>` in the CLI.
struct SandboxesView: View {
    var onSignOut: () -> Void
    var autoStopFirstStarted = false // --autotest-sandboxes: exercise spin-down headlessly
    @State private var sandboxes: [Sandbox] = []
    @State private var stopping: Set<String> = []
    @State private var note = ""

    var body: some View {
        List {
            if !note.isEmpty {
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(sandboxes) { sb in
                SandboxRow(sandbox: sb, stopping: stopping.contains(sb.id)) {
                    Task { await stop(sb.id) }
                }
            }
        }
        .navigationTitle("Sandboxes")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Sign out", action: onSignOut)
            }
        }
        .refreshable { await load() }
        .task {
            await load()
            if autoStopFirstStarted, let first = sandboxes.first(where: { $0.state == "started" }) {
                await stop(first.id)
            }
        }
    }

    private func load() async {
        do { sandboxes = try await Gateway.sandboxes() }
        catch { note = error.localizedDescription }
    }

    private func stop(_ id: String) async {
        stopping.insert(id)
        defer { stopping.remove(id) }
        do {
            let state = try await Gateway.stopSandbox(id)
            note = "\(id.prefix(8))… → \(state)"
            await load()
        } catch { note = error.localizedDescription }
    }
}

struct SandboxRow: View {
    let sandbox: Sandbox
    let stopping: Bool
    var onStop: () -> Void

    private var running: Bool { sandbox.state == "started" }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(running ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(sandbox.label.isEmpty ? String(sandbox.id.prefix(13)) : sandbox.label)
                    .font(.subheadline.weight(.medium))
                Text("\(sandbox.state) · \(sandbox.cpu)c/\(sandbox.memory)g/\(sandbox.disk)g · \(String(sandbox.createdAt?.prefix(10) ?? ""))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if running {
                Button {
                    onStop()
                } label: {
                    if stopping { ProgressView() } else { Text("Spin down") }
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(stopping)
            }
        }
    }
}
