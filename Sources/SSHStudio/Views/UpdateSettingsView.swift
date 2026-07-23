import SwiftUI

struct UpdateSettingsView: View {
    @ObservedObject private var updater = UpdateManager.shared

    var body: some View {
        Form {
            Section("Automatic updates") {
                Toggle("Check for updates automatically", isOn: $updater.checksEnabled)
                Toggle("Download verified updates automatically", isOn: $updater.automaticDownloadsEnabled)
                    .disabled(!updater.checksEnabled)

                Stepper(value: $updater.stabilityDelayDays, in: 0...30) {
                    LabeledContent("Update stability delay") {
                        Text("\(updater.stabilityDelayDays) day\(updater.stabilityDelayDays == 1 ? "" : "s")")
                    }
                }

                Text("New versions are downloaded only after SSH Studio has observed the signed release for the configured number of days.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Status") {
                Text(updater.status)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Check Now") {
                        Task { await updater.checkForUpdates() }
                    }
                    .disabled(updater.isWorking)

                    if updater.availableUpdate != nil, updater.downloadedInstaller == nil {
                        Button("Download and Verify") {
                            Task { await updater.downloadAvailableUpdate() }
                        }
                        .disabled(updater.isWorking)
                    }

                    if updater.downloadedInstaller != nil {
                        Button("Open Installer") {
                            updater.openDownloadedInstaller()
                        }
                        Button("Show in Finder") {
                            updater.revealDownloadedInstaller()
                        }
                    }

                    if updater.isWorking {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }

            Section("Security") {
                Text("SSH Studio accepts only HTTPS update URLs. Release metadata is verified with the embedded Ed25519 public key, and each downloaded installer must match the signed SHA-512 hash before it is offered for installation.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 560, height: 430)
    }
}
