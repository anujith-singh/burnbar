import Foundation

/// When to ask Claude Code to renew its own expired access token, and whether it did.
///
/// Burnbar never refreshes the token itself (a refresh rotates the refresh token and would sign
/// Claude Code out). Instead it runs the `claude` command, which renews its own token under its
/// own lock and writes it back to the Keychain. See DECISIONS §1.
public enum Renewal {
    /// Background attempts are at least this far apart, so a renewal that keeps failing costs one
    /// short-lived process every 15 minutes rather than one per check.
    public static let minimumGap: TimeInterval = 15 * 60

    public enum Decision: Equatable, Sendable {
        /// The access token is still valid (or carries no expiry): use it.
        case notNeeded
        case renew
        /// Expired, but a background attempt ran recently.
        case tooSoon
        /// The refresh token has expired too: only a new sign-in helps.
        case signInEnded
    }

    /// Renews only once the access token has actually expired. Claude Code decides for itself when
    /// its token needs refreshing; asking earlier could be a no-op that then looks like a failure.
    /// A manual refresh skips the gap, since the user is waiting on it.
    public static func decide(accessExpiresAt: Date?, refreshExpiresAt: Date?, lastAttempt: Date?,
                              manual: Bool, now: Date) -> Decision {
        guard let access = accessExpiresAt, access <= now else { return .notNeeded }
        if let refresh = refreshExpiresAt, refresh <= now { return .signInEnded }
        if !manual, let last = lastAttempt, now.timeIntervalSince(last) < minimumGap { return .tooSoon }
        return .renew
    }

    /// Success is judged by the Keychain, not by the command's exit code or output: the token must
    /// now be valid and newer than before. This keeps working (and keeps failing visibly) whatever
    /// a future Claude Code version prints.
    public static func renewed(previous: Date?, current: Date?, now: Date) -> Bool {
        guard let current, current > now else { return false }
        guard let previous else { return true }
        return current > previous
    }
}
