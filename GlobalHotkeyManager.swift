//
//  GlobalHotkeyManager.swift
//  reprompter
//

import AppKit
import CoreGraphics

// MARK: - Global Hotkey Manager

final class GlobalHotkeyManager {
    private var monitor: Any?

    /// Registers a global key-down monitor for the given config.
    /// Replaces any previously registered monitor.
    /// The action is dispatched on the main actor when the shortcut fires.
    func register(config: HotkeyConfig, action: @escaping @MainActor () -> Void) {
        unregister()
        let targetKeyCode = config.keyCode
        let targetModifiers = NSEvent.ModifierFlags(rawValue: config.modifiers)

        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            let eventModifiers = event.modifierFlags
                .intersection([.command, .control, .option, .shift])
            if event.keyCode == targetKeyCode, eventModifiers == targetModifiers {
                Task { @MainActor in action() }
            }
        }
    }

    func unregister() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }

    // MARK: - Input Monitoring Permission

    /// Whether the app currently has Input Monitoring permission.
    /// Global key monitors are silently suppressed without this permission.
    var hasPermission: Bool {
        CGPreflightListenEventAccess()
    }

    /// The system URL that opens the Input Monitoring pane in System Settings.
    /// This is a compile-time constant with a well-known Apple URL scheme — the force unwrap is intentional.
    private static let inputMonitoringSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!

    /// Opens the Input Monitoring pane in System Settings.
    func openPermissionSettings() {
        NSWorkspace.shared.open(Self.inputMonitoringSettingsURL)
    }

    deinit {
        if let m = monitor {
            // NSEvent.removeMonitor must run on the main thread.
            DispatchQueue.main.async { NSEvent.removeMonitor(m) }
        }
    }
}
