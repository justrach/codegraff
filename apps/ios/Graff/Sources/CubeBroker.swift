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
        if let old = CubeConnection.stored() {
            await onStep("Checking the last cube…")
            let state = (try? await Gateway.sandboxInfo(old.sandboxID))?.state ?? "gone"
            if state == "started" && !old.base.isEmpty && !old.serveToken.isEmpty {
                await onStep("Reusing the running cube (no new spin-up cost)")
                return old
            }
            // started-but-credential-less happens when a history row from
            // another device seeded the stored connection: re-key it in place.
            if state == "started" || state == "stopped" {
                resumeID = old.sandboxID
                wasRunning = state == "started"
            } else {
                CubeConnection.clearStored()
            }
        }

        let id: String
        if let rid = resumeID {
            await onStep(wasRunning ? "Re-keying the running cube (no reinstall)…"
                                    : "Waking the stopped cube (cheaper — no reinstall)…")
            if !wasRunning { _ = try await Gateway.startSandbox(rid) }
            id = rid
        } else {
            await onStep("Creating sandbox (full spin-up)…")
            id = try await Gateway.createSandbox(purpose: purpose).id
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
                                  previewToken: pv.token, githubLogin: github?.account_login)
        conn.store()
        return conn
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
