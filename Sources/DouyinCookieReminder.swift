import Foundation
import AppKit
import Combine

/// The upstream expiry is not available; the user-defined lifetime is thirty calendar days.
struct DouyinCookieExpiry {
    let refreshedAt: Date
    let expiresAt: Date
    let remainingDays: Int
    let expired: Bool
    var needsReminder: Bool { remainingDays <= 7 }

    init?(refreshedAt: Date, on now: Date, calendar: Calendar = .current) {
        guard refreshedAt <= now,
              let expires = calendar.date(byAdding: .day, value: 30, to: refreshedAt),
              let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                                   to: calendar.startOfDay(for: expires)).day else { return nil }
        self.refreshedAt = refreshedAt
        expiresAt = expires
        remainingDays = days
        expired = now >= expires
    }

    var reminderTitle: String {
        if expired { return "抖音 Cookie 预计已过期，请刷新" }
        if remainingDays == 0 { return "抖音 Cookie 预计今天到期" }
        return "抖音 Cookie 预计还有 \(remainingDays) 天到期"
    }

    var summary: String {
        if expired { return "预计已过期" }
        if remainingDays == 0 { return "预计今天到期" }
        return "预计剩余 \(remainingDays) 天"
    }

    var detail: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M 月 d 日"
        return "预计 " + formatter.string(from: expiresAt) + "到期 · 按成功刷新后 30 天估算"
    }
}

/// Only dates are stored. Calendar/app events refresh the countdown without polling Cookie or Redis.
final class DouyinCookieReminderStore: ObservableObject {
    static let shared = DouyinCookieReminderStore()
    static let successKey = "ops.douyin-cookie.lastSuccessfulRefresh"
    @Published private(set) var lastSuccessfulRefresh: Date?
    @Published private(set) var referenceDate: Date
    private let defaults: UserDefaults
    private var observations = Set<AnyCancellable>()

    init(defaults: UserDefaults = .standard, on now: Date = Date(), observeCalendar: Bool = true) {
        self.defaults = defaults
        referenceDate = now
        if let stamp = defaults.object(forKey: Self.successKey) as? Double, stamp.isFinite, stamp > 0 {
            lastSuccessfulRefresh = Date(timeIntervalSince1970: stamp)
        } else if let previous = defaults.dictionary(forKey: "ops.last.douyin-cookie"),
                  previous["phase"] as? String == "success",
                  let stamp = previous["at"] as? Double, stamp.isFinite, stamp > 0 {
            lastSuccessfulRefresh = Date(timeIntervalSince1970: stamp)
            defaults.set(stamp, forKey: Self.successKey)
        }
        if observeCalendar {
            let day = NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
            let zone = NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)
            let clock = NotificationCenter.default.publisher(for: .NSSystemClockDidChange)
            let wake = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            let active = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            day.merge(with: zone, clock, wake, active)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.refresh() }
                .store(in: &observations)
        }
    }

    var expiry: DouyinCookieExpiry? {
        lastSuccessfulRefresh.flatMap { DouyinCookieExpiry(refreshedAt: $0, on: referenceDate) }
    }

    func refresh(on now: Date = Date()) { referenceDate = now }

    func recordResult(success: Bool, at now: Date = Date()) {
        guard success else { return }
        defaults.set(now.timeIntervalSince1970, forKey: Self.successKey)
        lastSuccessfulRefresh = now
        referenceDate = now
    }
}
