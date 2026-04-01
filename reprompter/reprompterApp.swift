//
//  reprompterApp.swift
//  reprompter
//
//  Created by Karthik on 01/04/26.
//

import SwiftUI
import AppKit

@main
struct ReprompterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var panelController = PanelController()

    var body: some Scene {
        MenuBarExtra {
            Button("Show") {
                panelController.showPanel()
            }
            .disabled(panelController.isPanelVisible)

            Button("Hide") {
                panelController.hidePanel()
            }
            .disabled(!panelController.isPanelVisible)

            Divider()

            Toggle("Float On Top", isOn: Bindable(panelController.settings).isFloatingOnTop)
            Toggle("Translucent", isOn: Bindable(panelController.settings).isTranslucent)

            Divider()

            SettingsLink {
                Text("Settings...")
            }
            .keyboardShortcut(",", modifiers: .command)

            Divider()

            Button("Quit") {
                NSApp.terminate(nil)
            }
        } label: {
            Image("MenuBarIcon")
                .renderingMode(.template)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            ReprompterSettingsView(controller: panelController)
                .frame(minWidth: 720, minHeight: 540)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
