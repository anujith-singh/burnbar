import AppKit
import SwiftUI
import IOKit.ps
import ServiceManagement
import BurnbarCore

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusView = StatusView()
    private let menu = NSMenu()
    private let panelHost = NSHostingView(rootView: MenuPanel(model: PanelModel(footer: "", footerIsError: false, stale: true)))
    private let client = UsageClient()
    private let store = SampleStore(url: SampleStore.defaultURL())
    private let notifier = Notifier()
    private let defaults = UserDefaults.standard

    // Data state
    private var usage: Usage?
    private var lastError: String?          // nil when the last attempt succeeded
    private var signedOutReason: String?
    private var lastAttempt: Date?
    private var failureCount = 0
    private var rateLimitedUntil: Date?
    private var rateLimitCount = 0
    private var inFlight = false
    /// Restored values are old but nothing has failed yet: grey, without an error message.
    private var restoredStale = false
    /// A pending wake/unlock fetch; later rescheduling (e.g. a power change) must not push it back.
    private var wakeFetchAt: Date?

    // Environment state
    private var asleep = false
    private var screenLocked = false
    private var sessionInactive = false
    private var onAC = true
    private var menuOpen = false
    private var paused: Bool { asleep || screenLocked || sessionInactive }

    private var fetchTimer: Timer?
    private var nextFetchAt: Date?
    private var tickTimer: Timer?

    // Static menu items
    private let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
    private let notifyItem = NSMenuItem(title: "Notify Near Limits", action: #selector(toggleNotify), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private let coloursItem = NSMenuItem(title: "Customise Appearance…", action: #selector(openColours), keyEquivalent: ",")
    private var coloursWindow: NSWindow?

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = statusItem.button {
            statusView.frame = button.bounds
            statusView.autoresizingMask = [.width, .height]
            button.clipsToBounds = false   // the active-screen pill draws past the slot's edges
            button.addSubview(statusView)
            button.setAccessibilityLabel("Burnbar")
        }
        buildMenu()
        installEditMenu()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.statusView.coloursChanged()
                self?.render()
            }
        }
        restoreLastSample()

        onAC = PowerSource.isOnAC()
        screenLocked = ScreenLock.isLocked()
        observeEnvironment()
        enableLoginItemOnFirstRun()
        notifier.requestAuthorization()
        notifier.refreshAuthorizationStatus()

        Log.app.notice("status item height=\(Double(self.statusItem.button?.bounds.height ?? -1), privacy: .public) thickness=\(Double(NSStatusBar.system.thickness), privacy: .public)")
        Log.app.notice("launch ac=\(self.onAC) locked=\(self.screenLocked) loginItem=\(SMAppService.mainApp.status.rawValue)")
        startTick()
        render()
        scheduleNext()
    }

    /// Show the last stored values straight away (greyed if old) until the first fetch lands.
    private func restoreLastSample() {
        guard let s = store.samples.last else { return }
        usage = Usage(session: LimitWindow(percent: s.s, resetsAt: s.sReset),
                      week: LimitWindow(percent: s.w, resetsAt: s.wReset), fetchedAt: s.t)
        restoredStale = Date().timeIntervalSince(s.t) > 15 * 60
    }

    // MARK: Refresh policy

    /// On AC: 5 min (2 min when the session is ≥ 80 %). On battery: 15 min (5 min when ≥ 80 %).
    /// Weekly usage deliberately has no effect.
    private var refreshInterval: TimeInterval {
        let hot = (usage?.session.percent ?? 0) >= 80
        return onAC ? (hot ? 120 : 300) : (hot ? 300 : 900)
    }

    private func scheduleNext() {
        guard !paused else { cancelFetchTimer(); return }
        let now = Date()
        var next: Date
        var reason: String
        if let last = lastAttempt {
            var delay = refreshInterval
            reason = "interval"
            if failureCount > 0 {
                // Quick retries for transient failures (30 s, 1, 2, 4 min…), never slower than the interval.
                delay = min(delay, 30 * pow(2, Double(failureCount - 1)))
                reason = "retry"
            }
            next = last.addingTimeInterval(delay)
            // Fetch once right after a reset passes (if the last attempt predates it).
            if let wake = wakeFetchAt, wake < next { next = wake; reason = "wake/unlock" }
            if let u = usage {
                for reset in [u.session.resetsAt, u.week.resetsAt].compactMap({ $0 }) {
                    let at = reset.addingTimeInterval(10)
                    if last < at && at < next { next = at; reason = "reset" }
                }
            }
            if let until = rateLimitedUntil, until > next { next = until; reason = "429 backoff" }
        } else {
            next = now
            reason = "launch"
        }
        scheduleFetch(at: max(next, now), reason: reason)
    }

    private func scheduleFetch(at date: Date, reason: String) {
        cancelFetchTimer()
        let delay = date.timeIntervalSinceNow
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fetch(reason: reason) }
        }
        // Let macOS coalesce wake-ups: up to 10 % of the delay, capped at a minute.
        timer.tolerance = min(60, max(1, delay * 0.1))
        RunLoop.main.add(timer, forMode: .common)
        fetchTimer = timer
        nextFetchAt = date
        Log.app.notice("next fetch in \(Int(delay))s (\(reason, privacy: .public); interval \(Int(self.refreshInterval))s, ac=\(self.onAC))")
    }

    private func cancelFetchTimer() {
        fetchTimer?.invalidate()
        fetchTimer = nil
        nextFetchAt = nil
    }

    private func fetch(reason: String) {
        guard !inFlight, !paused else { return }
        inFlight = true
        cancelFetchTimer()
        wakeFetchAt = nil
        lastAttempt = Date()
        refreshItem.title = "Refreshing…"
        refreshItem.isEnabled = false
        Log.app.notice("fetch (\(reason, privacy: .public))")
        Task {
            let outcome = await client.fetch()
            self.inFlight = false
            self.refreshItem.title = "Refresh Now"
            self.refreshItem.isEnabled = true
            self.handle(outcome)
            self.render()
            self.scheduleNext()
        }
    }

    private func handle(_ outcome: FetchOutcome) {
        switch outcome {
        case .success(let u):
            usage = u
            lastError = nil
            restoredStale = false
            signedOutReason = nil
            failureCount = 0
            rateLimitCount = 0
            rateLimitedUntil = nil
            store.append(u)
            notifier.check(u)
            Log.app.notice("ok session=\(u.session.percent) week=\(u.week.percent)")
        case .signedOut(let reason):
            // Not transient: poll at the normal interval and pick the token up once the CLI refreshes it.
            signedOutReason = reason
            lastError = reason
            failureCount = 0
            Log.app.notice("signed out: \(reason, privacy: .public)")
        case .rateLimited(let retryAfter):
            // The token got past the server's auth check, so any signed-out state is over. The 429
            // schedule replaces the quick-retry schedule; Retry-After is a floor, never a shortcut.
            rateLimitCount += 1
            failureCount = 0
            signedOutReason = nil
            let backoff = min(1800, max(retryAfter ?? 0, 60 * pow(2, Double(rateLimitCount - 1))))
            rateLimitedUntil = Date().addingTimeInterval(backoff)
            lastError = "Rate limited by the server"
            Log.app.notice("429, backing off \(Int(backoff))s")
        case .failed(let message):
            failureCount += 1
            signedOutReason = nil      // the token was valid enough to try; show the real error instead
            lastError = message
            Log.app.notice("failed (\(self.failureCount)): \(message, privacy: .public)")
        }
    }

    // MARK: Environment: power, sleep, lock

    private func observeEnvironment() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update { $0.asleep = true } }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // The lock notification may have been missed while asleep; re-read the real state.
                self?.update { $0.asleep = false; $0.screenLocked = ScreenLock.isLocked() }
            }
        }
        ws.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update { $0.sessionInactive = true } }
        }
        ws.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update { $0.sessionInactive = false } }
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update { $0.screenLocked = true } }
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update { $0.screenLocked = false } }
        }

        // Power source changes. The callback runs on the main run loop.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<AppController>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.powerSourceChanged() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    private func powerSourceChanged() {
        let ac = PowerSource.isOnAC()
        guard ac != onAC else { return }   // fires on every battery-level change too
        onAC = ac
        Log.app.notice("power source changed ac=\(ac)")
        guard !paused, !inFlight else { return }
        scheduleNext()                     // new interval applies immediately
        render()
    }

    private func update(_ change: (AppController) -> Void) {
        let wasPaused = paused
        change(self)
        Log.app.notice("env asleep=\(self.asleep) locked=\(self.screenLocked) inactive=\(self.sessionInactive)")
        if paused && !wasPaused {
            cancelFetchTimer()
            tickTimer?.invalidate()
            tickTimer = nil
            Log.app.notice("paused")
        } else if !paused && wasPaused {
            Log.app.notice("resumed")
            startTick()
            render()
            // Fetch on wake/unlock, after a short pause so the network can come back.
            var at = Date().addingTimeInterval(3)
            if let until = rateLimitedUntil, until > at { at = until }
            if !inFlight {
                wakeFetchAt = at
                scheduleFetch(at: at, reason: "wake/unlock")
            }
        }
    }

    // MARK: Display

    /// Ticks on minute boundaries so countdowns change exactly when the minute does. No network.
    private func startTick() {
        tickTimer?.invalidate()
        let next = Date(timeIntervalSinceReferenceDate: (floor(Date().timeIntervalSinceReferenceDate / 60) + 1) * 60)
        let t = Timer(fire: next, interval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t
    }

    private var isStale: Bool { lastError != nil || restoredStale }

    private func render() {
        let now = Date()
        statusView.model = barModel(now: now)
        statusItem.length = statusView.itemLength
        if let button = statusItem.button {
            // Centre the view on the slot; with a negative margin it is wider than the slot.
            let overhang = statusView.overhang
            statusView.frame = NSRect(x: -overhang, y: 0, width: statusItem.length + 2 * overhang, height: button.bounds.height)
        }
        if menuOpen { updateMenu() }
    }

    private func barModel(now: Date) -> BarModel {
        guard let u = usage else {
            return BarModel(segments: [BarSegment(text: "S –", level: nil), BarSegment(text: "W –", level: nil)],
                            stale: true, sessionPercent: nil)
        }
        func segment(_ label: String, _ w: LimitWindow, _ level: Level) -> BarSegment {
            let countdown = w.resetsAt.map { " · " + Format.countdown(to: $0, from: now) } ?? ""
            return BarSegment(text: "\(label) \(Format.percent(w.percent))\(countdown)", level: level)
        }
        return BarModel(segments: [
            segment("S", u.session, Risk.sessionLevel(u.session.percent)),
            segment("W", u.week, Risk.weekPace(u.week, at: u.fetchedAt).level),
        ], stale: isStale, sessionPercent: u.session.percent)
    }

    // MARK: Menu

    private func buildMenu() {
        menu.delegate = self
        menu.autoenablesItems = false
        let panelItem = NSMenuItem()
        panelItem.view = panelHost
        menu.addItem(panelItem)
        menu.addItem(.separator())
        menu.addItem(refreshItem)
        menu.addItem(.separator())
        menu.addItem(coloursItem)
        menu.addItem(.separator())
        menu.addItem(notifyItem)
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Burnbar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != nil && item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) { updateMenu() }
    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        statusView.highlighted = true
        notifier.refreshAuthorizationStatus()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        statusView.highlighted = false
    }

    private func updateMenu() {
        panelHost.rootView = MenuPanel(model: panelModel(now: Date()))
        panelHost.frame.size = panelHost.fittingSize
        notifyItem.state = notifier.enabled ? .on : .off
        // Ad-hoc-signed builds may be refused by macOS; say so instead of showing a checkmark that does nothing.
        // The hint goes in a small second line rather than the title, which set the whole menu's width.
        let blocked = notifier.enabled && notifier.authorized == false
        if #available(macOS 14.4, *) {
            notifyItem.subtitle = blocked ? "Allow in System Settings › Notifications" : nil
        }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        if let until = rateLimitedUntil, until > Date() {
            refreshItem.isEnabled = false
            refreshItem.title = "Refresh Now (wait \(Format.countdown(to: until, from: Date())))"
        } else if !inFlight {
            refreshItem.isEnabled = true
            refreshItem.title = "Refresh Now"
        }
    }

    private func panelModel(now: Date) -> PanelModel {
        PanelModel.build(PanelInputs(usage: usage, samples: store.samples, lastError: lastError,
                                     signedOutReason: signedOutReason, stale: isStale, paused: paused, nextFetchAt: inFlight ? nil : nextFetchAt,
                                     onAC: onAC), now: now)
    }

    // MARK: Actions

    @objc private func refreshNow() {
        if let until = rateLimitedUntil, until > Date() { return }
        fetch(reason: "manual")
    }

    @objc private func toggleNotify() { notifier.enabled.toggle(); updateMenu() }

    @objc private func openColours() {
        if coloursWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: ColourSettingsView()))
            window.title = "Burnbar Appearance"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            coloursWindow = window
        }
        NSApp.activate()
        coloursWindow?.makeKeyAndOrderFront(nil)
    }

    /// A menu-bar-only app has no Edit menu, so ⌘C / ⌘V / ⌘A would do nothing in the hex fields.
    /// The main menu is never shown (LSUIElement); it only provides the key equivalents.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(NSMenuItem())   // slot for the (hidden) app menu
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            Log.app.error("login item: \(error.localizedDescription, privacy: .public)")
        }
        updateMenu()
    }

    /// Turn launch-at-login on once, the first time the installed app runs, so there's nothing to set up.
    private func enableLoginItemOnFirstRun() {
        guard Bundle.main.bundlePath.contains("/Applications/"), !defaults.bool(forKey: "loginItemInitialised") else { return }
        defaults.set(true, forKey: "loginItemInitialised")
        do { try SMAppService.mainApp.register() } catch {
            Log.app.error("login item: \(error.localizedDescription, privacy: .public)")
        }
    }
}
