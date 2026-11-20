import AppKit
import ApplicationServices
import Combine
import IOKit

/// Intent is short-lived and only consumed by a real screen-lock notification.
final class HealthDeskMonitor: ObservableObject {
    static let shared = HealthDeskMonitor()
    @Published private(set) var notice: String?
    @Published private(set) var pendingLock = false
    let store: HealthStore
    private let lockScreen: () -> Bool
    private var intentExpiresAt: Date?
    private var timeout: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var timer: Timer?
    init(store: HealthStore = .shared, lockScreen: @escaping () -> Bool = HealthDeskMonitor.postLockShortcut) {
        self.store = store; self.lockScreen = lockScreen
    }
    static var screenLockState: Bool? {
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
           let state = lockState(session) { return state }
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        let users = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [[String: Any]]
        return users?.compactMap(lockState).first
    }
    /// macOS omits CGSSessionScreenIsLocked while the active console session is unlocked.
    /// Treat that documented shape as an explicit false instead of preserving a stale away state forever.
    static func lockState(_ session: [String: Any]) -> Bool? {
        if let locked = session["CGSSessionScreenIsLocked"] as? Bool { return locked }
        if let locked = session["CGSSessionScreenIsLocked"] as? NSNumber { return locked.boolValue }
        let onConsole = (session["kCGSSessionOnConsoleKey"] as? Bool)
            ?? (session["kCGSSessionOnConsoleKey"] as? NSNumber)?.boolValue
        let loginDone = (session["kCGSessionLoginDoneKey"] as? Bool)
            ?? (session["kCGSessionLoginDoneKey"] as? NSNumber)?.boolValue
        if onConsole == true && loginDone != false { return false }
        return nil
    }
    static var screenLocked: Bool { screenLockState == true }
    static func postLockShortcut() -> Bool {
        guard CGPreflightPostEventAccess() || CGRequestPostEventAccess() else { return false }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 12, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 12, keyDown: false) else { return false }
        down.flags = [.maskControl, .maskCommand]
        up.flags = [.maskControl, .maskCommand]
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        return true
    }
    func start() {
        guard timer == nil else { return }
        _ = store.restart(screenLocked: Self.screenLockState ?? (store.document.mode == .away || store.document.mode == .locked))
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.screenDidLock()
        })
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.screenDidUnlock()
        })
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            // Sleep alone never confirms that the user stood up.
            _ = self?.store.locked(explicitAway: false)
        })
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            if Self.screenLockState == false { self?.screenDidUnlock() }
        })
        let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Reconcile missed notifications without ever inventing an away action.
            if Self.screenLockState == true {
                if self.store.document.mode == .desk { _ = self.store.locked(explicitAway: false) }
            } else if Self.screenLockState == false &&
                        (self.store.document.mode == .locked || self.store.document.mode == .away) { self.screenDidUnlock() }
            _ = self.store.tick()
        }
        timer.tolerance = 10
        self.timer = timer
    }
    func stop() {
        timer?.invalidate(); timer = nil
        timeout?.cancel(); timeout = nil
        intentExpiresAt = nil; pendingLock = false
        for token in observers { DistributedNotificationCenter.default().removeObserver(token) }
        for token in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        observers = []; workspaceObservers = []
        _ = store.tick()
    }
    @discardableResult func requestAwayLock(at now: Date = Date()) -> Bool {
        guard !pendingLock, store.error == nil, store.document.mode != .away, !Self.screenLocked else { return false }
        notice = nil; pendingLock = true
        intentExpiresAt = now.addingTimeInterval(8)
        // This only asks macOS to lock; no break is recorded until it actually locks.
        guard lockScreen() else {
            pendingLock = false; intentExpiresAt = nil
            notice = "锁屏未执行，请在系统设置的「辅助功能」中允许 D板控制电脑后重试。"
            return false
        }
        checkPendingLock()
        return true
    }
    private func checkPendingLock() {
        guard pendingLock, let expires = intentExpiresAt else { return }
        if Date() > expires {
            intentExpiresAt = nil; pendingLock = false
            notice = "未确认锁屏，未记录离座；请重试。"
            return
        }
        if Self.screenLockState == true { screenDidLock(); return }
        let work = DispatchWorkItem { [weak self] in self?.checkPendingLock() }
        timeout?.cancel(); timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
    func screenDidLock(at now: Date = Date()) {
        let explicit = intentExpiresAt.map { now <= $0 } ?? false
        if store.locked(at: now, explicitAway: explicit) { notice = nil }
        timeout?.cancel(); timeout = nil; intentExpiresAt = nil; pendingLock = false
    }
    func screenDidUnlock(at now: Date = Date()) {
        timeout?.cancel(); timeout = nil; intentExpiresAt = nil; pendingLock = false
        _ = store.unlocked(at: now)
    }
    deinit {
        timer?.invalidate(); timeout?.cancel()
        for token in observers { DistributedNotificationCenter.default().removeObserver(token) }
        for token in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
    }
}
