import SwiftUI
import AppKit

@main
struct SSHStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appearance = AppAppearanceSettings.shared
    @StateObject private var updater = UpdateManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(StudioTheme.accent)
                .preferredColorScheme(appearance.appearance.colorScheme)
                .frame(minWidth: 1120, minHeight: 700)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    Task { await updater.checkForUpdates() }
                }
                .disabled(updater.isWorking)
            }
            CommandMenu("Navigate") {
                Button("Command Palette...") {
                    NotificationCenter.default.post(name: .showSSHStudioCommandPalette, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Button("Quick Connect...") {
                    NotificationCenter.default.post(name: .showSSHStudioQuickConnect, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
            }
            CommandMenu("Appearance") {
                ForEach(AppAppearance.allCases, id: \.self) { option in
                    Button {
                        appearance.appearance = option
                    } label: {
                        if appearance.appearance == option {
                            Label(option.rawValue, systemImage: "checkmark")
                        } else {
                            Text(option.rawValue)
                        }
                    }
                }
            }
        }

        Settings {
            UpdateSettingsView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
        Task { await UpdateManager.shared.checkAtLaunch() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
