import Foundation
import BurnbarCore

enum FetchOutcome: Sendable {
    case success(Usage)
    /// 401/403, missing credentials, or an expired token. The message is shown to the user.
    case signedOut(String)
    case rateLimited(retryAfter: TimeInterval?)
    case failed(String)
}

/// Reads the Claude Code CLI's OAuth token and fetches usage. Strictly read-only:
/// the token is never refreshed or written back, because a refresh rotates the refresh
/// token and would log the CLI out.
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

    func fetch() async -> FetchOutcome {
        if let fixturePath {
            guard let data = FileManager.default.contents(atPath: fixturePath) else { return .failed("Fixture not found") }
            do { return .success(try UsageParser.parse(data, fetchedAt: Date())) } catch { return .failed("\(error)") }
        }

        let credential = await Task.detached { Keychain.readClaudeCode() }.value
        let token: String
        switch credential {
        case .missing:
            return .signedOut("No Claude Code login found in the Keychain.")
        case .error(let message):
            // Not transient (denied prompt, locked keychain): poll at the normal interval, never fast-retry.
            return .signedOut(message)
        case .ok(let t, let expiresAt):
            if let expiresAt, expiresAt < Date() {
                return .signedOut("Claude Code's sign-in token has expired.")
            }
            token = t
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
            return .signedOut("Claude rejected the saved sign-in (HTTP \(http.statusCode)).")
        case 429:
            return .rateLimited(retryAfter: Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After")))
        default:
            return .failed("Server returned HTTP \(http.statusCode)")
        }
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

enum Credential: Sendable {
    case ok(token: String, expiresAt: Date?)
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
        let expiresAt = UsageParser.number(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        return .ok(token: token, expiresAt: expiresAt)
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
