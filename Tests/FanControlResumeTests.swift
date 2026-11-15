// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Resuming fan control after a restart or wake runs the production decisions
/// against doubles: nothing here can reach the helper or the fans.
enum FanControlResumeContract {
    enum Environment {
        static var available = true
    }
    enum AppFeature {
        case fanControl
        var isAvailable: Bool { Environment.available }
    }
    enum UserDefaults {
        static let standard = Store()
        final class Store {
            var values: [String: Any] = [:]
            func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
            func string(forKey key: String) -> String? { values[key] as? String }
            func set(_ value: Any?, forKey key: String) { values[key] = value }
            func removeObject(forKey key: String) { values[key] = nil }
        }
    }
    final class Invalidating {
        var invalidated = false
        func invalidate() { invalidated = true }
    }
    class Fixture {
        enum AccessState { case notRegistered, requiresApproval, enabled, unavailable }
        static let shared = Service()
        static var helperVersion = "bundled"
        var accessState = AccessState.enabled
        var snapshot = FanControlSnapshot.empty
        var panelIsVisible = false
        var timer: Invalidating?
        var connection: Invalidating?
        var observing = true
        var applied: [FanControlConfiguration] = []
        var events: [String] = []
        func refreshAccessState() {}
        func applyConfiguration(_ configuration: FanControlConfiguration) { applied.append(configuration) }
        func restoreAutomatic() { events.append("restore") }
        func restoreAutomatic(supersedingCurrentRequest: Bool) { events.append("restore superseding") }
        func restoreThenUnregister() { events.append("unregister") }
        func refresh() { events.append("refresh") }
        func stopObservingSystemState() { observing = false }
        var isGameModeBoostActive = false
        var configurationBeforeGameMode: FanControlConfiguration?
        var userConfiguration: FanControlConfiguration?
        func endGameModeBoostWithoutRestoring() {
            isGameModeBoostActive = false
            configurationBeforeGameMode = nil
        }
        func gameModePreferenceDidChange() {}
        func startGameModeBoost() { events.append("game mode boost") }
    }
    /// Game Mode detection reads the screen; resume never depends on it.
    final class GameModeMonitor {
        static let shared = GameModeMonitor()
        var isActive = false
        func stop() { isActive = false }
    }

    static func run(_ suite: TestSuite) {
        let service = Service.shared
        let defaults = UserDefaults.standard
        let manual = FanControlConfiguration.manual(level: 100)
        func reset(resume: Bool = true, stored: FanControlConfiguration? = manual,
                   recovery: Bool = false) {
            Environment.available = true
            defaults.values = [:]
            defaults.values[DefaultsKey.fanControlResume] = resume
            defaults.values[DefaultsKey.fanControlRecoveryNeeded] = recovery
            defaults.values[DefaultsKey.fanControlMode] = FanControlMode.manual.rawValue
            if let stored {
                defaults.values[DefaultsKey.fanControlResumeConfiguration] =
                    FanControlConfiguration.encodeResume(stored)
            }
            service.accessState = .enabled
            service.snapshot = .empty
            service.panelIsVisible = false
            service.timer = Invalidating()
            service.connection = Invalidating()
            service.observing = true
            service.applied = []
            service.events = []
            service.endGameModeBoostWithoutRestoring()
            GameModeMonitor.shared.isActive = false
            service.userConfiguration = nil
        }
        var storedResume: String? { defaults.string(forKey: DefaultsKey.fanControlResumeConfiguration) }

        reset(resume: false, recovery: true)
        Service.recoverIfNeeded()
        suite.expect(service.applied.isEmpty && service.events == ["restore"],
                     "without resume, a launch after an interrupted session only returns the fans to the system")
        reset(recovery: true)
        Service.recoverIfNeeded()
        suite.expect(service.applied == [manual] && service.events.isEmpty,
                     "with resume on, a launch re-applies the kept control instead of restoring first")
        reset()
        service.accessState = .requiresApproval
        Service.recoverIfNeeded()
        suite.expect(service.applied.isEmpty && service.events.isEmpty,
                     "a resume never asks for helper approval on its own")
        reset()
        Environment.available = false
        Service.recoverIfNeeded()
        suite.expect(service.applied.isEmpty, "a feature removed from the hub resumes nothing")
        reset()
        defaults.values[DefaultsKey.fanControlResumeConfiguration] =
            #"{"curves":[],"manualLevel":100,"mode":"system"}"#
        Service.recoverIfNeeded()
        suite.expect(service.applied.isEmpty, "a damaged or System value is never re-applied")
        reset()
        defaults.values[DefaultsKey.fanControlMode] = FanControlMode.system.rawValue
        Service.recoverIfNeeded()
        service.workspaceDidWake()
        service.stopIdleWorkIfPossible()
        suite.expect(service.applied.isEmpty && !service.observing,
                     "picking System in the card, with the fans already back there, is never undone by a resume")
        reset()
        defaults.values[DefaultsKey.fanControlHelperVersion] = "registered before the update"
        Service.recoverIfNeeded()
        service.workspaceDidWake()
        suite.expect(service.applied.isEmpty,
                     "a helper replaced by an update is registered anew before any resume holds the fans")
        reset()
        defaults.values[DefaultsKey.fanControlHelperVersion] = Service.helperVersion
        Service.recoverIfNeeded()
        suite.expect(service.applied == [manual], "the registered helper resumes as before")

        reset(resume: false, stored: nil)
        service.rememberForResume(manual)
        suite.expect(storedResume == nil, "applied control is not kept while resume is off")
        reset(stored: nil)
        service.rememberForResume(.manual(level: 60))
        suite.expect(FanControlConfiguration.decodeResume(storedResume ?? "") == .manual(level: 60),
                     "applied control is kept while resume is on")

        reset(stored: nil)
        service.snapshot.isCooling = true
        service.snapshot.configuration = manual
        service.resumePreferenceDidChange()
        suite.expect(FanControlConfiguration.decodeResume(storedResume ?? "") == manual,
                     "turning resume on keeps the control already running")
        defaults.values[DefaultsKey.fanControlResume] = false
        service.resumePreferenceDidChange()
        suite.expect(storedResume == nil, "turning resume off forgets the kept control")
        reset(stored: nil)
        service.resumePreferenceDidChange()
        suite.expect(storedResume == nil, "turning resume on with the fans on System keeps nothing")
        reset()
        service.resumePreferenceDidChange()
        suite.expect(storedResume == nil,
                     "turning resume on with the fans on System drops an older kept control, such as a restored one")

        reset()
        service.returnToSystem()
        suite.expect(storedResume == nil && service.events == ["restore"],
                     "returning to System forgets the kept control and restores the fans")

        reset()
        service.stopIdleWorkIfPossible()
        suite.expect(service.timer == nil && service.connection == nil && service.observing,
                     "idle work stops while a pending resume keeps watching for the next wake")
        reset(resume: false)
        service.stopIdleWorkIfPossible()
        suite.expect(!service.observing, "without a pending resume the sleep observers stop too")

        reset()
        service.workspaceDidWake()
        suite.expect(service.applied == [manual] && service.events.isEmpty,
                     "waking re-applies the kept control")
        reset(resume: false, recovery: true)
        service.workspaceDidWake()
        suite.expect(service.applied.isEmpty && service.events == ["restore superseding"],
                     "without resume, waking still returns an interrupted session to the system")
        reset(resume: false)
        service.panelIsVisible = true
        service.workspaceDidWake()
        suite.expect(service.applied.isEmpty && service.events == ["refresh"],
                     "without resume, waking only refreshes a visible panel")

        reset()
        Environment.available = false
        service.syncWithPreferences()
        suite.expect(storedResume == nil && service.events == ["unregister"],
                     "removing the feature forgets the kept control before unregistering the helper")

        reset()
        let curve = FanControlConfiguration.curve([FanControlConfiguration.defaultCurve])
        service.isGameModeBoostActive = true
        service.configurationBeforeGameMode = curve
        service.resumePreferenceDidChange()
        suite.expect(storedResume == FanControlConfiguration.encodeResume(curve),
                     "turning resume on during Game Mode keeps the user's control, not the boost")
        reset()
        service.isGameModeBoostActive = true
        service.resumePreferenceDidChange()
        suite.expect(storedResume == nil,
                     "a Game Mode boost over System control is never kept for resume")
        reset()
        service.isGameModeBoostActive = true
        GameModeMonitor.shared.isActive = true
        service.workspaceDidWake()
        suite.expect(service.applied.isEmpty && service.events == ["game mode boost"],
                     "waking mid-game puts the boost back instead of the kept control")
        reset()
        service.isGameModeBoostActive = true
        service.userConfiguration = manual
        service.returnToSystem()
        suite.expect(!service.isGameModeBoostActive && service.userConfiguration == nil,
                     "returning to System cancels a Game Mode boost and forgets the user's control")

        suite.expect(GameModePolicy.declaresGame(supportsGameMode: nil,
                                                 category: "public.app-category.action-games"),
                     "a games category marks a game")
        suite.expect(GameModePolicy.declaresGame(supportsGameMode: nil,
                                                 category: "public.app-category.games"),
                     "the plain games category marks a game")
        suite.expect(!GameModePolicy.declaresGame(supportsGameMode: nil,
                                                  category: "public.app-category.productivity"),
                     "other categories are not games")
        suite.expect(!GameModePolicy.declaresGame(supportsGameMode: false,
                                                  category: "public.app-category.games"),
                     "an explicit Game Mode opt-out wins over the category")
        suite.expect(GameModePolicy.declaresGame(supportsGameMode: true, category: nil),
                     "an explicit Game Mode opt-in marks a game")
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        suite.expect(GameModePolicy.windowCoversScreen(screen, screen: screen),
                     "a window filling the display is full screen")
        suite.expect(!GameModePolicy.windowCoversScreen(CGRect(x: 0, y: 33, width: 1512, height: 949),
                                                        screen: screen),
                     "a maximized window below the menu bar is not full screen")
        reset()
    }
}
