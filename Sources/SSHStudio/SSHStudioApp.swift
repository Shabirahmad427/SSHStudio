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
            CommandGroup(replacing: .newItem) {
                Button("New Connection") {
                    NotificationCenter.default.post(name: .showSSHStudioNewConnection, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("New Terminal Tab") {
                    NotificationCenter.default.post(name: .duplicateSSHStudioActiveTab, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)
            }
            CommandGroup(before: .saveItem) {
                Button("Close Active Tab") {
                    NotificationCenter.default.post(name: .closeSSHStudioActiveTab, object: nil)
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    Task { await updater.checkForUpdates() }
                }
                .disabled(updater.isWorking)
            }
            CommandMenu("Navigate") {
                Button("Toggle Sidebar") {
                    NotificationCenter.default.post(name: .toggleSSHStudioSidebar, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.control, .command])

                Button("Toggle Inspector") {
                    NotificationCenter.default.post(name: .toggleSSHStudioInspector, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.option, .command])

                Divider()

                Button("Command Palette...") {
                    NotificationCenter.default.post(name: .showSSHStudioCommandPalette, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Button("Quick Connect...") {
                    NotificationCenter.default.post(name: .showSSHStudioQuickConnect, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)

                Button("Known Hosts...") {
                    NotificationCenter.default.post(name: .showSSHStudioKnownHosts, object: nil)
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])

                Divider()

                Button("Next Workspace Tab") {
                    NotificationCenter.default.post(name: .selectSSHStudioNextTab, object: nil)
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])

                Button("Previous Workspace Tab") {
                    NotificationCenter.default.post(name: .selectSSHStudioPreviousTab, object: nil)
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            }
            CommandMenu("Connection") {
                Button("Reconnect") {
                    NotificationCenter.default.post(name: .reconnectSSHStudioActiveSession, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("Cancel Reconnect") {
                    NotificationCenter.default.post(name: .cancelSSHStudioReconnect, object: nil)
                }
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

                Divider()

                Button("Increase Terminal Font") {
                    NotificationCenter.default.post(name: .increaseSSHStudioTerminalFont, object: nil)
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("Decrease Terminal Font") {
                    NotificationCenter.default.post(name: .decreaseSSHStudioTerminalFont, object: nil)
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Reset Terminal Font") {
                    NotificationCenter.default.post(name: .resetSSHStudioTerminalFont, object: nil)
                }
                .keyboardShortcut("0", modifiers: .command)
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
