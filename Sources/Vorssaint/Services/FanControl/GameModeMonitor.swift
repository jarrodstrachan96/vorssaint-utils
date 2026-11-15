// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import CoreGraphics

/// Watches for macOS Game Mode.
///
/// macOS has no public API that reports Game Mode, so this follows the rule
/// macOS itself uses to turn it on: an app that declares itself a game is the
/// frontmost app and has a full-screen window. Reading window bounds and owner
/// needs no Screen Recording permission.
final class GameModeMonitor {
    static let shared = GameModeMonitor()

    private(set) var isActive = false
    var onChange: ((Bool) -> Void)?

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    private init() {}

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Entering full screen animates; check again once it settles.
                self?.evaluate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self?.evaluate() }
            })
        }
        // Not every full-screen change posts a notification (a game can take
        // full screen inside its current Space), so a slow poll backs them up.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.evaluate()
        }
        timer?.tolerance = 0.5
        evaluate()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
        guard isActive else { return }
        isActive = false
        onChange?(false)
    }

    private func evaluate() {
        let active = Self.gameIsFrontmostInFullScreen()
        guard active != isActive else { return }
        isActive = active
        onChange?(active)
    }

    static func gameIsFrontmostInFullScreen() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              isGame(app) else { return false }
        return hasFullScreenWindow(pid: app.processIdentifier)
    }

    private static func isGame(_ app: NSRunningApplication) -> Bool {
        guard let url = app.bundleURL, let bundle = Bundle(url: url) else { return false }
        return GameModePolicy.declaresGame(
            supportsGameMode: bundle.object(forInfoDictionaryKey: "LSSupportsGameMode") as? Bool,
            category: bundle.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String)
    }

    private static func hasFullScreenWindow(pid: pid_t) -> Bool {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let screens = screenRectsInWindowCoordinates()
        for window in info {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else { continue }
            if screens.contains(where: { GameModePolicy.windowCoversScreen(bounds, screen: $0) }) {
                return true
            }
        }
        return false
    }

    /// Window bounds are top-left based from the primary display; NSScreen
    /// frames are bottom-left based, so flip them into the same space.
    private static func screenRectsInWindowCoordinates() -> [CGRect] {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return [] }
        return NSScreen.screens.map { screen in
            let frame = screen.frame
            return CGRect(x: frame.minX, y: primaryHeight - frame.maxY,
                          width: frame.width, height: frame.height)
        }
    }
}
