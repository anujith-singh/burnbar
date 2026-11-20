import Foundation

/// Asks the official `claude` command to renew its own sign-in. Burnbar never refreshes or writes
/// the token itself; Claude Code does, under its own lock, exactly as when the user runs it.
enum ClaudeCLI {
    /// `claude mcp get` with a name that isn't configured: Claude Code loads its sign-in (renewing an
    /// expired access token), reports that no such server exists and exits with status 1. It starts
    /// no MCP server, opens no browser and makes no model call. `claude auth status` stopped renewing
    /// in Claude Code 2.1.300. See DECISIONS §1.
    static let renewArguments = ["mcp", "get", "burnbar-renewal-probe"]
    /// Generous: killing `claude` mid-refresh, after the server has rotated the refresh token but
    /// before the new one is saved, would sign Claude Code out. A renewal normally takes ~2 s, and
    /// only this background fetch (or a Refresh Now the user is watching) waits on it.
    static let timeout: TimeInterval = 120

    enum RunResult: Sendable {
        case ran(status: Int32)
        case timedOut
        case notFound
        case failedToStart(String)
    }

    static func runRenewal() -> RunResult {
        guard let path = locate() else { return .notFound }
        return run(path, renewArguments, timeout: timeout)
    }

    /// Apps launched from Finder or at login don't inherit the shell's PATH, so check the usual
    /// install locations first, then ask the user's login shell.
    static func locate() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",     // native installer
            "/opt/homebrew/bin/claude",      // Homebrew, Apple silicon
            "/usr/local/bin/claude",         // Homebrew, Intel
        ]
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return hit }
        return lookUpInLoginShell()
    }

    /// A login shell, not an interactive one: it reads `.zprofile` (where Homebrew sets PATH) but
    /// not `.zshrc`, whose prompts, tmux auto-attach and similar don't belong in a background check.
    /// Installs only on PATH via `.zshrc` (nvm, for example) aren't found; the panel then says so.
    private static func lookUpInLoginShell() -> String? {
        guard let pw = getpwuid(getuid()), let shellPtr = pw.pointee.pw_shell else { return nil }
        let shell = String(cString: shellPtr)
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        // A file rather than a pipe: a daemon started by the profile could hold a pipe open forever.
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("burnbar-which-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: outURL.path, contents: nil),
              let out = try? FileHandle(forWritingTo: outURL) else { return nil }
        defer { try? out.close(); try? FileManager.default.removeItem(at: outURL) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-lc", "command -v claude"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil, !waitBounded(p, timeout: 10), p.terminationStatus == 0,
              let raw = try? String(contentsOf: outURL, encoding: .utf8),
              let line = raw.split(separator: "\n").last?.trimmingCharacters(in: .whitespaces),
              line.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: line) else { return nil }
        return line
    }

    private static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> RunResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        p.environment = environment(for: path)
        // Output isn't used (success is judged from the Keychain) and is never logged.
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return .failedToStart(error.localizedDescription) }
        return waitBounded(p, timeout: timeout) ? .timedOut : .ran(status: p.terminationStatus)
    }

    /// Waits for `p` to exit; after `timeout` sends SIGTERM, and SIGKILL 3 s later, so a stuck child
    /// can never hold a fetch (and the Refresh Now item) forever. Returns true if it timed out.
    private static func waitBounded(_ p: Process, timeout: TimeInterval) -> Bool {
        let pid = p.processIdentifier
        let timedOut = Flag()
        let term = DispatchWorkItem { timedOut.set(); kill(pid, SIGTERM) }
        let killer = DispatchWorkItem { kill(pid, SIGKILL) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: term)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 3, execute: killer)
        p.waitUntilExit()
        term.cancel()
        killer.cancel()
        return timedOut.value
    }

    /// The inherited environment without Claude Code's own variables, which could point it at a
    /// different config directory (and so a different Keychain item) than the one Burnbar reads.
    /// PATH gains the binary's own folder and Homebrew's, for installs that are scripts run by `node`.
    private static func environment(for path: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("CLAUDE") && !$0.key.hasPrefix("ANTHROPIC")
        }
        let dir = (path as NSString).deletingLastPathComponent
        let base = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = ([dir, "/opt/homebrew/bin", "/usr/local/bin"] + [base]).joined(separator: ":")
        return env
    }
}

/// Set once from the watchdog's queue, read after the process exits.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}
