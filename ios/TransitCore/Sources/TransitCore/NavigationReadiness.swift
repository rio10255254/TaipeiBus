import Foundation

/// Permission and preference are separate: an enabled switch does not grant OS access.
public enum NavigationPermission: String, Equatable, Sendable {
    case checking, notDetermined, allowed, denied
}

public enum NavigationFeatureState: Equatable, Sendable {
    case checking, requiresPro, disabled, needsPermission, ready, unavailable
}

public struct NavigationReadiness: Equatable, Sendable {
    public var hasPro: Bool
    public var checkingPro: Bool
    public var notifications: NavigationPermission
    public var location: NavigationPermission
    public var liveActivitiesAllowed: Bool

    public init(hasPro: Bool = false, checkingPro: Bool = true,
                notifications: NavigationPermission = .checking,
                location: NavigationPermission = .notDetermined, liveActivitiesAllowed: Bool = true) {
        self.hasPro = hasPro; self.checkingPro = checkingPro; self.notifications = notifications
        self.location = location; self.liveActivitiesAllowed = liveActivitiesAllowed
    }
    public func reminder(enabled: Bool) -> NavigationFeatureState {
        guard hasPro else { return checkingPro ? .checking : .requiresPro }
        guard enabled else { return .disabled }
        switch notifications {
        case .allowed: return .ready
        case .checking: return .checking
        case .notDetermined, .denied: return .needsPermission
        }
    }
    public func liveActivity(enabled: Bool, failed: Bool = false) -> NavigationFeatureState {
        guard hasPro else { return checkingPro ? .checking : .requiresPro }
        guard enabled else { return .disabled }
        guard liveActivitiesAllowed else { return .needsPermission }
        return failed ? .unavailable : .ready
    }
    /// Foreground notification timers remain usable without location access. Continuous
    /// background location additionally requires permission and a usable trip feature.
    public func canRunInBackground(started: Bool, arrived: Bool, reminderEnabled: Bool,
                                   activityEnabled: Bool, activityRunning: Bool) -> Bool {
        guard hasPro, started, !arrived, location == .allowed else { return false }
        return reminder(enabled: reminderEnabled) == .ready ||
            (activityEnabled && liveActivitiesAllowed && activityRunning)
    }
}
