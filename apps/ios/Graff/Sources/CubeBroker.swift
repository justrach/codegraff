import Foundation
import Security

// Everything a serve client needs to stream turns into a sandbox cube, plus
// the sandbox id for spin-down. Persisted in the Keychain so a relaunch can
// reattach to a still-running cube instead of paying spin-up again.
struct CubeConnection: Codable, Equatable {
    let sandboxID: String
    let base: String        // Daytona preview URL fronting the serve port
    let serveToken: String
    let previewToken: String?
    var githubLogin: String? = nil   // set when the cube carries repo access
    // When the installation token wired into this cube dies. A cube outlives
    // its 1-hour token, and the reuse fast path used to hand the connection
    // straight back (#314) — so git/gh inside kept running on dead credentials
    // while the chat still told the model GitHub was wired up.
    var githubTokenExpiry: Date? = nil

    // Re-mint a few minutes early: a turn that starts on a nearly-dead token
    // still has to finish its clone/push.
    static let githubRefreshSkew: TimeInterval = 5 * 60

    // Nothing to refresh when the cube never carried repo access. An expiry we
    // never recorded (a connection stored before #314) counts as expired — its
    // real age is unknowable, so assume the worst and re-key once.
    func githubNeedsRefresh(asOf now: Date = Date()) -> Bool {
        guard githubLogin != nil else { return false }
        guard let expiry = githubTokenExpiry else { return true }
        return expiry.timeIntervalSince(now) <= Self.githubRefreshSkew
    }

    private static let account = "cube-connection"
    static func stored() -> CubeConnection? {
        guard let raw = KeychainStore.get(account), let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CubeConnection.self, from: data)
    }
    func store() {
        if let data = try? JSONEncoder().encode(self), let s = String(data: data, encoding: .utf8) {
            KeychainStore.set(Self.account, s)
        }
    }
    static func clearStored() { KeychainStore.delete(account) }
}

// What /api/github/mint-token returns — a 1-hour installation token with the
// same scopes @codegraff-bot gets (contents/pull_requests/issues write).
struct MintedGitHub: Decodable {
    let token: String
    let expires_at: String
    let account_login: String

    // #314: the wire carries an ISO-8601 instant; the stored connection needs a
    // Date it can compare against on reuse. An unparseable stamp falls back to
    // an hour out, which is what the endpoint promises anyway.
    var expiry: Date {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: expires_at) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: expires_at) { return d }
        return Date().addingTimeInterval(3600)
    }
}

// Client-side mirror of `graff cube new` (the CLI got the capability first).
// Cost ladder, cheapest first: a running cube is reused as-is; a stopped one
// is woken without reinstalling (its disk survives a stop); only a gone one
// pays the full spin-up. Every bring-up wires the account's GitHub in (fresh
// 1-hour token) when connected, so the agent can clone, push, and open PRs.
enum CubeBroker {
    static let port = 8787
    static let mintURL = "https://codegraff.com/api/github/mint-token"

    struct StepError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func launch(purpose: String, onStep: @escaping @MainActor (String) -> Void) async throws -> CubeConnection {
        var resumeID: String? = nil
        var wasRunning = false
        var refreshingGitHub = false
        if let old = CubeConnection.stored() {
            await onStep("Checking the last cube…")
            let state = (try? await Gateway.sandboxInfo(old.sandboxID))?.state ?? "gone"
            let staleGitHub = old.githubNeedsRefresh()
            if state == "started" && !old.base.isEmpty && !old.serveToken.isEmpty && !staleGitHub {
                await onStep("Reusing the running cube (no new spin-up cost)")
                return old
            }
            // started-but-credential-less happens when a history row from
            // another device seeded the stored connection: re-key it in place.
            // A running cube whose installation token has aged out lands here
            // too (#314): the token is baked into the serve process environment
            // as much as into the credential files, so a re-key — mint, rewrite,
            // restart serve — is what makes the "fresh token every bring-up"
            // promise above true on the reuse path. Still no reinstall, so this
            // stays the cheap rung of the ladder.
            if state == "started" || state == "stopped" {
                resumeID = old.sandboxID
                wasRunning = state == "started"
                refreshingGitHub = wasRunning && staleGitHub
            } else {
                CubeConnection.clearStored()
            }
        }

        // #312: what this launch is on the hook for. The New Session sheet can
        // be dismissed mid-provisioning; the cube this launch paid to bring up
        // then has to go back down (Gateway.createSandbox's autoStopMinutes: 30
        // caps the bleed, it never undoes the spin-up). A cube that was already
        // running when we found it is not ours to stop.
        var broughtUp: String? = nil
        do {
            let id: String
            if let rid = resumeID {
                await onStep(refreshingGitHub
                    ? "GitHub token expired — re-keying the cube (no reinstall)…"
                    : wasRunning ? "Re-keying the running cube (no reinstall)…"
                                 : "Waking the stopped cube (cheaper — no reinstall)…")
                if !wasRunning {
                    _ = try await Gateway.startSandbox(rid)
                    broughtUp = rid
                }
                id = rid
            } else {
                // #312: never buy a cube for a sheet that is already gone.
                try Task.checkCancellation()
                await onStep("Creating sandbox (full spin-up)…")
                id = try await Gateway.createSandbox(purpose: purpose).id
                broughtUp = id
            }

            var state = ""
            var waits = 0
            while state != "started" && waits < 60 {
                state = (try? await Gateway.sandboxInfo(id).state) ?? state
                if state == "started" { break }
                try await Task.sleep(for: .seconds(2))
                waits += 1
            }
            guard state == "started" else { throw StepError(message: "sandbox never reached started (\(state))") }

            if resumeID == nil {
                await onStep("Installing graff…")
                let inst = try await Gateway.exec(id,
                    command: "curl -fsSL https://raw.githubusercontent.com/justrach/codegraff/main/install.sh | bash",
                    timeoutSeconds: 120)
                guard inst.exitCode == 0 else {
                    throw StepError(message: "graff install failed: \(String((inst.result ?? "").suffix(200)))")
                }
            }

            // Fresh token every bring-up — the previous one expires after an hour.
            let github = await provisionGitHub(sandboxID: id, onStep: onStep)
            // provisionGitHub swallows its own errors, cancellation included, so
            // ask again before spending anything more on an abandoned launch (#312).
            try Task.checkCancellation()

            // A resumed cube may still have an old serve bound to the port
            // (re-key case, or a crashed-but-lingering process after a wake).
            if resumeID != nil {
                _ = try? await Gateway.exec(id, command: "pkill -f 'graff serve' >/dev/null 2>&1; sleep 1; true", timeoutSeconds: 20)
            }
            await onStep("Starting graff serve…")
            guard let key = Gateway.apiKey else { throw StepError(message: "not signed in") }
            let token = freshToken()
            let env = github.map { "CODEGRAFF_API_KEY=\(key) GH_TOKEN=\($0.token) GITHUB_LOGIN=\($0.account_login)" }
                ?? "CODEGRAFF_API_KEY=\(key)"
            _ = try await Gateway.exec(id,
                command: "\(env) exec $HOME/bin/graff serve --host 0.0.0.0 --port \(port) --token \(token)",
                timeoutSeconds: 60, async: true)
            var up = false
            for _ in 0..<20 {
                if let probe = try? await Gateway.exec(id,
                    command: "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:\(port)/", timeoutSeconds: 15) {
                    let code = (probe.result ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n'"))
                    if !code.isEmpty && code != "000" { up = true; break }
                }
                try await Task.sleep(for: .seconds(1))
            }
            guard up else { throw StepError(message: "serve never came up in the sandbox") }

            await onStep("Minting preview URL…")
            let pv = try await Gateway.preview(id, port: port)
            let base = pv.url.hasSuffix("/") ? String(pv.url.dropLast()) : pv.url
            let conn = CubeConnection(sandboxID: id, base: base, serveToken: token,
                                      previewToken: pv.token, githubLogin: github?.account_login,
                                      githubTokenExpiry: github?.expiry)
            conn.store()
            return conn
        } catch {
            // #312: put back only what this launch brought up, and only when the
            // caller walked away — a genuine spin-up failure keeps its sandbox so
            // the next attempt can resume it instead of paying again.
            if Task.isCancelled, let id = broughtUp {
                await onStep("Cancelled — stopping the cube…")
                // Detached on purpose: every URLSession call made from a
                // cancelled task fails instantly, and this rollback is the one
                // thing that still has to happen.
                await Task.detached { _ = try? await Gateway.stopSandbox(id) }.value
            }
            throw error
        }
    }

    // GitHub for the cube — the same access @codegraff-bot gets. Degrades to a
    // plain cube when the account has no GitHub connected.
    private static func provisionGitHub(sandboxID: String, onStep: @escaping @MainActor (String) -> Void) async -> MintedGitHub? {
        guard let key = Gateway.apiKey, let url = URL(string: mintURL) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Graff-iOS/0.1", forHTTPHeaderField: "User-Agent")
        req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        req.httpBody = Data("{}".utf8)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let minted = try? JSONDecoder().decode(MintedGitHub.self, from: data) else {
            await onStep("GitHub: not connected — cube gets no repo access")
            return nil
        }
        await onStep("Wiring GitHub (\(minted.account_login))…")
        let t = minted.token, l = minted.account_login
        let cmd = "mkdir -p $HOME/bin && git config --global credential.helper store && "
            + "printf 'https://x-access-token:%s@github.com\\n' '\(t)' > $HOME/.git-credentials && chmod 600 $HOME/.git-credentials && "
            + "printf '%s' '\(t)' > $HOME/.cube-github-token && chmod 600 $HOME/.cube-github-token && "
            + "git config --global user.name '\(l)' && git config --global user.email '\(l)@users.noreply.github.com' && "
            + "(command -v gh >/dev/null 2>&1 || (A=$(uname -m); case \"$A\" in x86_64) A=amd64;; aarch64|arm64) A=arm64;; esac; "
            + "V=$(curl -s https://api.github.com/repos/cli/cli/releases/latest | grep -o '\"tag_name\": *\"[^\"]*\"' | head -1 | cut -d'\"' -f4); "
            + "curl -fsSL https://github.com/cli/cli/releases/download/$V/gh_${V#v}_linux_$A.tar.gz | tar -xz -C /tmp && "
            + "mv /tmp/gh_${V#v}_linux_$A/bin/gh $HOME/bin/gh)) && echo GH-PROVISIONED"
        guard let res = try? await Gateway.exec(sandboxID, command: cmd, timeoutSeconds: 90),
              (res.result ?? "").contains("GH-PROVISIONED") else {
            await onStep("GitHub: provisioning failed — continuing without")
            return nil
        }
        return minted
    }

    private static func freshToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
