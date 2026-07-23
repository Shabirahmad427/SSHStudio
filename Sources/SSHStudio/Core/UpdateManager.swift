import AppKit
import CryptoKit
import Foundation

struct UpdateManifest: Decodable {
    let payload: Payload
    let signature: String

    struct Payload: Codable {
        let version: String
        let publishedAt: Date
        let downloadURL: URL
        let sha512: String
    }
}

@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    @Published private(set) var status = "Updates have not been checked yet."
    @Published private(set) var availableUpdate: UpdateManifest.Payload?
    @Published private(set) var downloadedInstaller: URL?
    @Published private(set) var isWorking = false

    @Published var checksEnabled: Bool {
        didSet { defaults.set(checksEnabled, forKey: Keys.checksEnabled) }
    }

    @Published var automaticDownloadsEnabled: Bool {
        didSet { defaults.set(automaticDownloadsEnabled, forKey: Keys.automaticDownloadsEnabled) }
    }

    @Published var stabilityDelayDays: Int {
        didSet { defaults.set(stabilityDelayDays, forKey: Keys.stabilityDelayDays) }
    }

    private enum Keys {
        static let checksEnabled = "updates_checks_enabled"
        static let automaticDownloadsEnabled = "updates_automatic_downloads_enabled"
        static let stabilityDelayDays = "updates_stability_delay_days"
        static let lastCheck = "updates_last_check"
        static let observations = "updates_first_seen"
    }

    private let defaults = SSHStudioDefaults.shared
    private let session: URLSession

    private init() {
        let configured = Self.isUpdateConfigured
        checksEnabled = configured && (defaults.object(forKey: Keys.checksEnabled) as? Bool ?? true)
        automaticDownloadsEnabled = configured && (defaults.object(forKey: Keys.automaticDownloadsEnabled) as? Bool ?? true)
        stabilityDelayDays = defaults.object(forKey: Keys.stabilityDelayDays) as? Int ?? 3

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        session = URLSession(configuration: configuration)
    }

    func checkAtLaunch() async {
        guard Self.isUpdateConfigured else {
            status = "Update checks are disabled because no update manifest URL and public key are configured."
            return
        }
        guard checksEnabled else {
            status = "Automatic update checks are disabled."
            return
        }

        if let lastCheck = defaults.object(forKey: Keys.lastCheck) as? Date,
           Date().timeIntervalSince(lastCheck) < 24 * 60 * 60 {
            return
        }

        await checkForUpdates()
    }

    func checkForUpdates() async {
        guard !isWorking else { return }
        guard Self.isUpdateConfigured else {
            status = "Update checks are disabled because no update manifest URL and public key are configured."
            return
        }
        isWorking = true
        defer { isWorking = false }

        do {
            let manifestURL = try configuredManifestURL()
            status = "Checking for updates..."
            let (data, response) = try await session.data(from: manifestURL)
            try validateHTTPSResponse(response)

            let manifest = try JSONDecoder.updateDecoder.decode(UpdateManifest.self, from: data)
            try verify(manifest)
            defaults.set(Date(), forKey: Keys.lastCheck)

            guard isNewer(manifest.payload.version, than: currentVersion) else {
                availableUpdate = nil
                status = "SSH Studio \(currentVersion) is up to date."
                return
            }

            availableUpdate = manifest.payload
            let firstSeen = firstSeenDate(for: manifest.payload)
            let eligibleDate = Calendar.current.date(
                byAdding: .day,
                value: stabilityDelayDays,
                to: firstSeen
            ) ?? firstSeen

            guard Date() >= eligibleDate else {
                status = "Version \(manifest.payload.version) is available. The stability delay ends \(eligibleDate.formatted(date: .abbreviated, time: .shortened))."
                return
            }

            status = "Version \(manifest.payload.version) is ready to download."
            if automaticDownloadsEnabled {
                try await downloadAndVerify(manifest.payload)
            }
        } catch {
            status = "Update check failed: \(error.localizedDescription)"
        }
    }

    func downloadAvailableUpdate() async {
        guard !isWorking, let update = availableUpdate else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            try await downloadAndVerify(update)
        } catch {
            status = "Update download failed: \(error.localizedDescription)"
        }
    }

    func openDownloadedInstaller() {
        guard let downloadedInstaller else { return }
        NSWorkspace.shared.open(downloadedInstaller)
    }

    func revealDownloadedInstaller() {
        guard let downloadedInstaller else { return }
        NSWorkspace.shared.activateFileViewerSelecting([downloadedInstaller])
    }

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private static var isUpdateConfigured: Bool {
        guard let manifest = Bundle.main.object(forInfoDictionaryKey: "SSHStudioUpdateManifestURL") as? String,
              let manifestURL = URL(string: manifest),
              manifestURL.scheme?.lowercased() == "https",
              let publicKey = Bundle.main.object(forInfoDictionaryKey: "SSHStudioUpdatePublicKey") as? String,
              let publicKeyData = Data(base64Encoded: publicKey),
              publicKeyData.count == 32 else {
            return false
        }
        return true
    }

    private func configuredManifestURL() throws -> URL {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: "SSHStudioUpdateManifestURL") as? String,
              let url = URL(string: rawValue),
              url.scheme?.lowercased() == "https" else {
            throw UpdateError.configuration("Set SSHStudioUpdateManifestURL to an HTTPS URL in Info.plist.")
        }
        return url
    }

    private func configuredPublicKey() throws -> Curve25519.Signing.PublicKey {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: "SSHStudioUpdatePublicKey") as? String,
              let data = Data(base64Encoded: rawValue) else {
            throw UpdateError.configuration("Set SSHStudioUpdatePublicKey to a base64 Ed25519 public key in Info.plist.")
        }
        do {
            return try Curve25519.Signing.PublicKey(rawRepresentation: data)
        } catch {
            throw UpdateError.configuration("SSHStudioUpdatePublicKey is not a valid Ed25519 public key.")
        }
    }

    private func verify(_ manifest: UpdateManifest) throws {
        guard manifest.payload.downloadURL.scheme?.lowercased() == "https" else {
            throw UpdateError.invalidManifest("The installer URL must use HTTPS.")
        }
        guard manifest.payload.sha512.range(of: "^[0-9a-fA-F]{128}$", options: .regularExpression) != nil else {
            throw UpdateError.invalidManifest("The installer SHA-512 value is malformed.")
        }
        guard let signature = Data(base64Encoded: manifest.signature) else {
            throw UpdateError.invalidManifest("The update signature is malformed.")
        }

        let signedData = try JSONEncoder.updateEncoder.encode(manifest.payload)
        guard try configuredPublicKey().isValidSignature(signature, for: signedData) else {
            throw UpdateError.invalidManifest("The update manifest signature is invalid.")
        }
    }

    private func validateHTTPSResponse(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw UpdateError.network("The update server returned an unsuccessful response.")
        }
        guard response.url?.scheme?.lowercased() == "https" else {
            throw UpdateError.network("The update server redirected to a non-HTTPS URL.")
        }
    }

    private func firstSeenDate(for update: UpdateManifest.Payload) -> Date {
        var observations = defaults.dictionary(forKey: Keys.observations) as? [String: Date] ?? [:]
        let observationKey = "\(update.version):\(update.sha512.lowercased())"
        if let firstSeen = observations[observationKey] {
            return firstSeen
        }
        let firstSeen = Date()
        observations[observationKey] = firstSeen
        defaults.set(observations, forKey: Keys.observations)
        return firstSeen
    }

    private func downloadAndVerify(_ update: UpdateManifest.Payload) async throws {
        status = "Downloading SSH Studio \(update.version)..."
        let (temporaryURL, response) = try await session.download(from: update.downloadURL)
        try validateHTTPSResponse(response)

        status = "Verifying installer SHA-512..."
        let actualHash = try sha512(of: temporaryURL)
        guard actualHash.caseInsensitiveCompare(update.sha512) == .orderedSame else {
            throw UpdateError.invalidInstaller("The downloaded installer SHA-512 hash does not match the signed manifest.")
        }

        let destination = try installerDestination(for: update)
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: temporaryURL, to: destination)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        downloadedInstaller = destination
        status = "Version \(update.version) was downloaded and verified. Open the installer when ready."
    }

    private func installerDestination(for update: UpdateManifest.Payload) throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let fileName = update.downloadURL.lastPathComponent.isEmpty
            ? "SSH-Studio-\(update.version).pkg"
            : update.downloadURL.lastPathComponent
        return directory
            .appendingPathComponent("SSH Studio", isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
            .appendingPathComponent(update.version, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    private func sha512(of url: URL) throws -> String {
        guard let stream = InputStream(url: url) else {
            throw UpdateError.invalidInstaller("The downloaded installer could not be read.")
        }
        stream.open()
        defer { stream.close() }

        var hasher = SHA512()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64 * 1024)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 64 * 1024)
            if count < 0 {
                throw stream.streamError ?? UpdateError.invalidInstaller("The downloaded installer could not be read.")
            }
            if count == 0 { break }
            hasher.update(data: Data(bytes: buffer, count: count))
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func isNewer(_ candidate: String, than installed: String) -> Bool {
        candidate.compare(installed, options: .numeric) == .orderedDescending
    }
}

private enum UpdateError: LocalizedError {
    case configuration(String)
    case invalidManifest(String)
    case invalidInstaller(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .configuration(let message),
             .invalidManifest(let message),
             .invalidInstaller(let message),
             .network(let message):
            return message
        }
    }
}

private extension JSONDecoder {
    static var updateDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension JSONEncoder {
    static var updateEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
