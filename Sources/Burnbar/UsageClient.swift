import Foundation
import BurnbarCore

enum FetchOutcome: Sendable {
    case success(Usage)
    /// 401/403, missing credentials, or an expired token that couldn't be renewed. The message is
    /// shown to the user as-is, so it says what to do.
    case signedOut(String)
    case rateLimited(retryAfter: TimeInterval?)
    case failed(String)
}

/// Reads the Claude Code CLI's OAuth token and fetches usage. Burnbar never refreshes or writes
/// the token, because a refresh rotates the refresh token and would sign the CLI out. When the
/// token has expired it asks the `claude` command to renew its own (see `ClaudeCLI`).
struct UsageClient: Sendable {
    static let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 30
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    /// Development aid: `BURNBAR_FIXTURE=/path/to/response.json` reads a saved response instead
    /// of the network, so colour states and failures can be exercised without waiting for real usage.
    /// A path that does not exist simulates a failed fetch.
    let fixturePath = ProcessInfo.processInfo.environment["BURNBAR_FIXTURE"]
    private let renewals = RenewalLog()

    /// `manual`: the user chose Refresh Now, so a renewal may run even if one ran recently.
    func fetch(manual: Bool) async -> FetchOutcome {
        if let fixturePath {
            guard let data = FileManager.default.contents(atPath: fixturePath) else { return .failed("Fixture not found") }
            do { return .success(try UsageParser.parse(data, fetchedAt: Date())) } catch { return .failed("\(error)") }
        }

        let credential = await Task.detached { Keychain.readClaudeCode() }.value
        let token: String
        switch credential {
        case .missing:
            return .signedOut("No Claude Code sign-in found in the Keychain. Run `claude auth login` in Terminal.")
        case .error(let message):
            // Not transient (denied prompt, locked keychain): poll at the normal interval, never fast-retry.
            return .signedOut("\(message). Burnbar tries again on its next check.")
        case .ok(let t, let expiresAt, let refreshExpiresAt):
            let now = Date()
            switch Renewal.decide(accessExpiresAt: expiresAt, refreshExpiresAt: refreshExpiresAt,
                                  lastAttempt: await renewals.lastAttempt, manual: manual, now: now) {
            case .notNeeded:
                token = t
            case .signInEnded:
                return .signedOut(SignInMessage.ended)
            case .tooSoon:
                return .signedOut(await renewals.lastFailure ?? SignInMessage.notRenewed)
            case .renew:
                switch await renew(previous: expiresAt) {
                case .success(let renewed): token = renewed
                case .failure(let failure): return .signedOut(failure.message)
                }
            }
        }

        var req = URLRequest(url: Self.url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Burnbar/1.0", forHTTPHeaderField: "User-Agent")

        let data: Data, response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: req)
        } catch let e as URLError {
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: return .failed("Offline")
            case .timedOut: return .failed("Timed out")
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return .failed("Can't reach api.anthropic.com")
            default: return .failed(e.localizedDescription)
            }
        } catch {
            return .failed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { return .failed("No HTTP response") }
        switch http.statusCode {
        case 200:
            do { return .success(try UsageParser.parse(data, fetchedAt: Date())) }
            catch { return .failed("\(error)") }
        case 401, 403:
            return .signedOut("Claude rejected the saved sign-in (HTTP \(http.statusCode)). Run `claude auth login` in Terminal.")
        case 429:
            return .rateLimited(retryAfter: Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After")))
        default:
            return .failed("Server returned HTTP \(http.statusCode)")
        }
    }

    /// Runs `claude` so it renews its own sign-in, then re-reads the Keychain. Success is judged by
    /// the token's expiry moving forward, never by the command's exit status or output.
    private func renew(previous: Date?) async -> Result<String, RenewalFailure> {
        await renewals.attempted(at: Date())
        let run = await Task.detached { ClaudeCLI.runRenewal() }.value
        let after = await Task.detached { Keychain.readClaudeCode() }.value
        if case .ok(let token, let expiresAt, let refreshExpiresAt) = after,
           Renewal.renewed(previous: previous, current: expiresAt, now: Date()) {
            await renewals.succeeded()
            // Expiry times aren't secret; they show whether renewals extend the refresh token too.
            Log.app.notice("renewal ok (\(String(describing: run), privacy: .public)): access until \(Self.logDate(expiresAt), privacy: .public), refresh until \(Self.logDate(refreshExpiresAt), privacy: .public)")
            return .success(token)
        }
        let message: String
        if case .error(let keychainError) = after {
            // Claude Code may well have renewed; Burnbar just couldn't read the result.
            message = "\(keychainError). Burnbar tries again on its next check."
        } else if case .notFound = run {
            message = "Claude Code's sign-in token has expired, and Burnbar couldn't find the `claude` command to renew it. Run `claude` in Terminal once."
        } else {
            message = SignInMessage.notRenewed
        }
        await renewals.failed(message)
        Log.app.notice("renewal didn't renew (\(String(describing: run), privacy: .public))")
        return .failure(RenewalFailure(message: message))
    }

    private static func logDate(_ d: Date?) -> String {
        d.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"
    }

    /// Retry-After as delta-seconds or an HTTP date.
    static func retryAfter(_ value: String?) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let s = TimeInterval(value) { return s.isFinite ? min(3600, max(0, s)) : nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: value).map { min(3600, max(0, $0.timeIntervalSinceNow)) }
    }
}

enum SignInMessage {
    static let notRenewed = "Claude Code's sign-in token has expired and `claude` didn't renew it. Run `claude` in Terminal once; if it asks you to log in, run `claude auth login`."
    static let ended = "Claude Code's sign-in has ended. Run `claude auth login` in Terminal to sign in again."
}

struct RenewalFailure: Error {
    let message: String
}

/// When the last renewal ran and why it failed, shared across fetches.
private actor RenewalLog {
    private(set) var lastAttempt: Date?
    private(set) var lastFailure: String?
    func attempted(at date: Date) { lastAttempt = date }
    func succeeded() { lastFailure = nil }
    func failed(_ message: String) { lastFailure = message }
}

enum Credential: Sendable {
    case ok(token: String, expiresAt: Date?, refreshExpiresAt: Date?)
    case missing
    case error(String)
}

enum Keychain {
    static let service = "Claude Code-credentials"

    /// Reads via /usr/bin/security rather than SecItemCopyMatching: the CLI created the item with
    /// `security`, so that binary is already on the item's access list and no prompt appears — and
    /// the answer does not change when this app's ad-hoc signature changes on every rebuild.
    static func readClaudeCode() -> Credential {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return .error("Couldn't run /usr/bin/security") }

        // Never hang a fetch on a locked keychain or a stuck prompt.
        let pid = p.processIdentifier
        let watchdog = DispatchWorkItem { kill(pid, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
        let raw = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        watchdog.cancel()

        switch p.terminationStatus {
        case 0: break
        case 44: return .missing                 // errSecItemNotFound
        default: return .error("Keychain read failed (status \(p.terminationStatus))")
        }

        guard let data = decode(raw),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return .missing }
        func date(_ key: String) -> Date? {
            UsageParser.number(oauth[key]).map { Date(timeIntervalSince1970: $0 / 1000) }
        }
        return .ok(token: token, expiresAt: date("expiresAt"), refreshExpiresAt: date("refreshTokenExpiresAt"))
    }

    /// `security -w` prints the secret as-is, or as hex if it contains non-printable bytes.
    private static func decode(_ raw: Data) -> Data? {
        guard let s = String(data: raw, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return nil }
        if s.hasPrefix("{") { return Data(s.utf8) }
        guard s.count.isMultiple(of: 2), s.allSatisfy(\.isHexDigit) else { return nil }
        var bytes = [UInt8]()
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
            bytes.append(b)
            i = j
        }
        return Data(bytes)
    }
}
