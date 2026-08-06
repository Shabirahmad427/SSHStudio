import Foundation
import CryptoKit
import Testing
@testable import SSHStudio

@Suite("SSH Studio Phase 4 SFTP")
@MainActor
struct Phase4SFTPTests {

    @Test func transferPlannerCoversEverySupportedMatrixCell() throws {
        let localID = UUID()
        let remoteID = UUID()
        let otherRemoteID = UUID()
        let cells: [(TransferEndpoint, TransferEndpoint, TransferItemType, TransferOperation, TransferEngine)] = [
            (.remote(profileID: remoteID), .local, .file, .copy, .sftpGet),
            (.remote(profileID: remoteID), .local, .directory, .copy, .recursiveSFTPGet),
            (.local, .remote(profileID: remoteID), .file, .copy, .sftpPut),
            (.local, .remote(profileID: remoteID), .directory, .copy, .recursiveSFTPPut),
            (.remote(profileID: remoteID), .remote(profileID: remoteID), .file, .move, .sftpRename),
            (.remote(profileID: remoteID), .remote(profileID: remoteID), .directory, .copy, .localRelay),
            (.remote(profileID: remoteID), .remote(profileID: otherRemoteID), .file, .copy, .localRelay),
            (.local, .local, .file, .copy, .localCopy)
        ]

        for (source, destination, type, operation, expected) in cells {
            let request = TransferRequest(
                sourceEndpoint: source,
                destinationEndpoint: destination,
                itemType: type,
                operation: operation,
                sourcePath: source == .local ? "/tmp/ssh studio source.txt" : "~/folder/source.txt",
                destinationDirectory: destination == .local ? "/tmp/ssh studio target" : "~/folder/target"
            )
            #expect(try TransferPlanner.plan(for: request).engine == expected)
        }

        let unsupportedMove = TransferRequest(
            sourceEndpoint: .local,
            destinationEndpoint: .local,
            itemType: .file,
            operation: .move,
            sourcePath: "/tmp/source",
            destinationDirectory: "/tmp/target"
        )
        #expect(throws: TransferFailureCause.unsupportedCapability) {
            _ = try TransferPlanner.plan(for: unsupportedMove)
        }
        let crossServerMove = TransferRequest(sourceEndpoint: .remote(profileID: remoteID), destinationEndpoint: .remote(profileID: otherRemoteID),
                                              itemType: .file, operation: .move, sourcePath: "/tmp/source", destinationDirectory: "/tmp/target")
        #expect(throws: TransferFailureCause.unsupportedCapability) {
            _ = try TransferPlanner.plan(for: crossServerMove)
        }
        _ = localID
    }

    @Test func transferPlannerAppendsBasenameExactlyOnceAndPreservesRemoteHome() throws {
        let remote = TransferRequest(
            sourceEndpoint: .remote(profileID: UUID()),
            destinationEndpoint: .remote(profileID: UUID()),
            itemType: .directory,
            sourcePath: "~/A Folder/MDDF",
            destinationDirectory: "~/target"
        )
        #expect(try TransferPlanner.finalDestination(for: remote) == "~/target/MDDF")

        let local = TransferRequest(
            sourceEndpoint: .remote(profileID: UUID()),
            destinationEndpoint: .local,
            itemType: .file,
            sourcePath: "/remote/--quoted \"file\" é.txt",
            destinationDirectory: "/tmp/target"
        )
        #expect(try TransferPlanner.finalDestination(for: local).hasSuffix("/--quoted \"file\" é.txt"))

        let saveAs = TransferRequest(
            sourceEndpoint: .remote(profileID: UUID()),
            destinationEndpoint: .local,
            itemType: .file,
            sourcePath: "/remote/original.txt",
            destinationDirectory: "/tmp/target",
            destinationName: "exact name.txt"
        )
        #expect(try TransferPlanner.finalDestination(for: saveAs) == "/tmp/target/exact name.txt")
    }

    @Test func transferFailureClassifierKeepsNonFallbackFailuresTyped() {
        #expect(TransferFailureClassifier.classify("Permission denied") == .permissionDenied)
        #expect(TransferFailureClassifier.classify("Read-only file system") == .readOnlyFilesystem)
        #expect(TransferFailureClassifier.classify("Disk quota exceeded") == .quotaExceeded)
        #expect(TransferFailureClassifier.classify("No space left on device") == .noSpace)
        #expect(TransferFailureClassifier.classify("Host key verification failed") == .hostKeyRejected)
        #expect(TransferFailureClassifier.classify("Authentication failed") == .authenticationFailed)
        #expect(TransferFailureClassifier.classify("Connection closed") == .connectionLost)
    }

    @Test func localPipelineConflictPoliciesAreExecutable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sshstudio-conflicts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("target", isDirectory: true)
        try Data("new".utf8).write(to: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appendingPathComponent("source.txt"))

        func run(_ policy: TransferConflictPolicy) async -> TransferResult {
            let request = TransferRequest(sourceEndpoint: .local, destinationEndpoint: .local, itemType: .file,
                                          sourcePath: source.path, destinationDirectory: destination.path,
                                          conflictPolicy: policy)
            return await Self.submit(request, name: source.lastPathComponent)
        }

        #expect(await run(.fail) == .failed(.destinationExists))
        #expect(await run(.overwrite) == .success)
        #expect(String(data: try Data(contentsOf: destination.appendingPathComponent("source.txt")), encoding: .utf8) == "new")
        #expect(await run(.keepBoth) == .success)
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("source copy 2.txt").path))
    }
    private static let clauberhRealDownloadFlag = "SSHSTUDIO_REAL_CLAUBERH_DOWNLOAD"
    private static let clauberhRemoteFile = "/home/users/clauberh/13-shabir-GH39/01-mec-shabir-pdynamo2/PM6_new/02_mec2Dscan_1Ac-1C/02-pes2/01-30.29/00-rs-ps-cons-con-lg-improve2/0-pmf2/00_PMF_CRD-distance-WAT.py"
    private static let clauberhFileName = "00_PMF_CRD-distance-WAT.py"

    @Test func realUnifiedTransferMatrixOnDocinhoAndCoaraciWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["SSHSTUDIO_REAL_TRANSFER_MATRIX"] == "1" else { return }

        let docinho = Session(name: "docinho", host: "docinho", username: "shabir",
                              authentication: .privateKey(path: "~/.ssh/id_ed25519", useAgent: true, addKeysToAgent: false, useKeychain: false),
                              privateKeyPath: "~/.ssh/id_ed25519", sshConfigAlias: "docinho")
        let coaraci = Session(name: "sahmaddo", host: "sahmaddo", username: "sahmaddo",
                              authentication: .privateKey(path: "~/.ssh/id_ed25519", useAgent: true, addKeysToAgent: false, useKeychain: false),
                              privateKeyPath: "~/.ssh/id_ed25519", sshConfigAlias: "sahmaddo")
        let docManager = SFTPManager()
        let coaManager = SFTPManager()
        let localRoot = FileManager.default.temporaryDirectory.appendingPathComponent("sshstudio-matrix-\(UUID().uuidString)", isDirectory: true)
        let docRoot = "/tmp/sshstudio-transfer-matrix-\(UUID().uuidString)"
        let coaRoot = "/tmp/sshstudio-transfer-matrix-\(UUID().uuidString)"
        try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localRoot) }

        let sourceFile = localRoot.appendingPathComponent("file with spaces --.txt")
        let sourceDirectory = localRoot.appendingPathComponent("folder with spaces", isDirectory: true)
        let nestedFile = sourceDirectory.appendingPathComponent("nested/--leading.txt")
        try FileManager.default.createDirectory(at: nestedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("unified transfer matrix\n".utf8).write(to: sourceFile)
        try Data("nested content\n".utf8).write(to: nestedFile)

        _ = try await Self.runRemote(docinho, command: "mkdir -p -- \(SSHSecurity.remoteShellPath(docRoot))")
        _ = try await Self.runRemote(coaraci, command: "mkdir -p -- \(SSHSecurity.remoteShellPath(coaRoot))")
        docManager.setActiveSessionForTesting(docinho, currentPath: docRoot)
        coaManager.setActiveSessionForTesting(coaraci, currentPath: coaRoot)

        let uploadFile = TransferRequest(sourceEndpoint: .local, destinationEndpoint: .remote(profileID: docinho.id),
                                         itemType: .file, sourcePath: sourceFile.path, destinationDirectory: docRoot)
        let uploadFileResult = await Self.submit(uploadFile, name: sourceFile.lastPathComponent, destinationSession: docinho, destinationManager: docManager)
        if uploadFileResult != .success {
            let item = TransferQueue.shared.items.first
            Issue.record("file upload: \(uploadFileResult.description) details=\(item?.detailLines.joined(separator: " | ") ?? "")")
        }
        let uploadedHash = try? await Self.remoteHash(docinho, path: "\(docRoot)/\(sourceFile.lastPathComponent)")
        #expect(uploadedHash == Self.localHash(sourceFile))

        let uploadDirectory = TransferRequest(sourceEndpoint: .local, destinationEndpoint: .remote(profileID: docinho.id),
                                              itemType: .directory, sourcePath: sourceDirectory.path, destinationDirectory: docRoot)
        #expect(await Self.submit(uploadDirectory, name: sourceDirectory.lastPathComponent, destinationSession: docinho, destinationManager: docManager) == .success)
        let sameServerDirectoryCopy = TransferRequest(sourceEndpoint: .remote(profileID: docinho.id), destinationEndpoint: .remote(profileID: docinho.id),
                                                       itemType: .directory, sourcePath: "\(docRoot)/\(sourceDirectory.lastPathComponent)",
                                                       destinationDirectory: docRoot, destinationName: "folder copy")
        #expect(await Self.submit(sameServerDirectoryCopy, name: "folder copy", sourceSession: docinho,
                                  destinationSession: docinho, sourceManager: docManager, destinationManager: docManager) == .success)
        #expect(try await Self.remoteHash(docinho, path: "\(docRoot)/folder copy/nested/--leading.txt") == Self.localHash(nestedFile))

        let downloads = localRoot.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let downloadFile = TransferRequest(sourceEndpoint: .remote(profileID: docinho.id), destinationEndpoint: .local,
                                            itemType: .file, sourcePath: "\(docRoot)/\(sourceFile.lastPathComponent)", destinationDirectory: downloads.path)
        #expect(await Self.submit(downloadFile, name: sourceFile.lastPathComponent, sourceSession: docinho, sourceManager: docManager) == .success)
        #expect(try Data(contentsOf: downloads.appendingPathComponent(sourceFile.lastPathComponent)) == Data(contentsOf: sourceFile))

        let downloadDirectory = TransferRequest(sourceEndpoint: .remote(profileID: docinho.id), destinationEndpoint: .local,
                                                itemType: .directory, sourcePath: "\(docRoot)/\(sourceDirectory.lastPathComponent)", destinationDirectory: downloads.path)
        #expect(await Self.submit(downloadDirectory, name: sourceDirectory.lastPathComponent, sourceSession: docinho, sourceManager: docManager) == .success)
        #expect(try Data(contentsOf: downloads.appendingPathComponent(sourceDirectory.lastPathComponent).appendingPathComponent("nested/--leading.txt")) == Data(contentsOf: nestedFile))

        let movedName = "moved file.txt"
        let move = TransferRequest(sourceEndpoint: .remote(profileID: docinho.id), destinationEndpoint: .remote(profileID: docinho.id),
                                   itemType: .file, operation: .move, sourcePath: "\(docRoot)/\(sourceFile.lastPathComponent)", destinationDirectory: docRoot, destinationName: movedName)
        #expect(await Self.submit(move, name: movedName, sourceSession: docinho, sourceManager: docManager, destinationManager: docManager) == .success)
        let copy = TransferRequest(sourceEndpoint: .remote(profileID: docinho.id), destinationEndpoint: .remote(profileID: docinho.id),
                                   itemType: .file, sourcePath: "\(docRoot)/\(movedName)", destinationDirectory: docRoot, destinationName: "copy.txt")
        let copyResult = await Self.submit(copy, name: "copy.txt", sourceSession: docinho, destinationSession: docinho, sourceManager: docManager, destinationManager: docManager)
        if copyResult != .success {
            let item = TransferQueue.shared.items.first
            Issue.record("same-server copy: \(copyResult.description) details=\(item?.detailLines.joined(separator: " | ") ?? "")")
        }

        let stagedFromDoc = localRoot.appendingPathComponent("staged-from-doc", isDirectory: true)
        try FileManager.default.createDirectory(at: stagedFromDoc, withIntermediateDirectories: true)
        let crossDown = TransferRequest(sourceEndpoint: .remote(profileID: docinho.id), destinationEndpoint: .local,
                                        itemType: .file, sourcePath: "\(docRoot)/\(movedName)", destinationDirectory: stagedFromDoc.path)
        let crossDownResult = await Self.submit(crossDown, name: movedName, sourceSession: docinho, sourceManager: docManager)
        if crossDownResult != .success { Issue.record("docinho to local staged transfer: \(crossDownResult.description)") }
        let crossUp = TransferRequest(sourceEndpoint: .local, destinationEndpoint: .remote(profileID: coaraci.id),
                                      itemType: .file, sourcePath: stagedFromDoc.appendingPathComponent(movedName).path, destinationDirectory: coaRoot)
        let crossUpResult = await Self.submit(crossUp, name: movedName, destinationSession: coaraci, destinationManager: coaManager)
        if crossUpResult != .success { Issue.record("local staged to Coaraci transfer: \(crossUpResult.description)") }
        #expect(try await Self.remoteHash(coaraci, path: "\(coaRoot)/\(movedName)") == Self.localHash(stagedFromDoc.appendingPathComponent(movedName)))

        let crossDirectory = TransferRequest(sourceEndpoint: .remote(profileID: docinho.id), destinationEndpoint: .remote(profileID: coaraci.id),
                                             itemType: .directory, sourcePath: "\(docRoot)/\(sourceDirectory.lastPathComponent)", destinationDirectory: coaRoot)
        #expect(await Self.submit(crossDirectory, name: sourceDirectory.lastPathComponent, sourceSession: docinho,
                                  destinationSession: coaraci, sourceManager: docManager, destinationManager: coaManager) == .success)

        let stagedFromCoa = localRoot.appendingPathComponent("staged-from-coa", isDirectory: true)
        try FileManager.default.createDirectory(at: stagedFromCoa, withIntermediateDirectories: true)
        let reverseDown = TransferRequest(sourceEndpoint: .remote(profileID: coaraci.id), destinationEndpoint: .local,
                                          itemType: .file, sourcePath: "\(coaRoot)/\(movedName)", destinationDirectory: stagedFromCoa.path)
        let reverseDownResult = await Self.submit(reverseDown, name: movedName, sourceSession: coaraci, sourceManager: coaManager)
        if reverseDownResult != .success { Issue.record("Coaraci to local staged transfer: \(reverseDownResult.description)") }
        let reverseUp = TransferRequest(sourceEndpoint: .local, destinationEndpoint: .remote(profileID: docinho.id),
                                        itemType: .file, sourcePath: stagedFromCoa.appendingPathComponent(movedName).path, destinationDirectory: docRoot, destinationName: "roundtrip.txt")
        let reverseUpResult = await Self.submit(reverseUp, name: "roundtrip.txt", destinationSession: docinho, destinationManager: docManager)
        if reverseUpResult != .success { Issue.record("local staged to docinho transfer: \(reverseUpResult.description)") }
        #expect(try await Self.remoteHash(docinho, path: "\(docRoot)/roundtrip.txt") == Self.localHash(stagedFromCoa.appendingPathComponent(movedName)))

        let reverseDirectory = TransferRequest(sourceEndpoint: .remote(profileID: coaraci.id), destinationEndpoint: .remote(profileID: docinho.id),
                                               itemType: .directory, sourcePath: "\(coaRoot)/\(sourceDirectory.lastPathComponent)", destinationDirectory: docRoot)
        #expect(await Self.submit(reverseDirectory, name: sourceDirectory.lastPathComponent, sourceSession: coaraci,
                                  destinationSession: docinho, sourceManager: coaManager, destinationManager: docManager) == .success)

        let localCopy = TransferRequest(sourceEndpoint: .local, destinationEndpoint: .local, itemType: .file,
                                        sourcePath: sourceFile.path, destinationDirectory: localRoot.appendingPathComponent("local-copy").path)
        #expect(await Self.submit(localCopy, name: sourceFile.lastPathComponent) == .success)
        _ = try await Self.runRemote(docinho, command: "rm -rf -- \(SSHSecurity.remoteShellPath(docRoot))")
        _ = try await Self.runRemote(coaraci, command: "rm -rf -- \(SSHSecurity.remoteShellPath(coaRoot))")
    }

    /// Exercises the real binary SFTP protocol path (SFTPManager.listFiles ->
    /// getBinarySFTP -> SFTPBinaryClient.realPath/listDirectory) against the
    /// real docinho home directory, which has hundreds of entries including
    /// unicode filenames — the exact listing that used to hang under the old
    /// PTY/text-scraping PersistentSFTPSession implementation.
    @Test func realBinarySFTPListingOnDocinhoWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["SSHSTUDIO_REAL_TRANSFER_MATRIX"] == "1" else { return }

        let docinho = Session(name: "docinho", host: "docinho", username: "shabir",
                              authentication: .privateKey(path: "~/.ssh/id_ed25519", useAgent: true, addKeysToAgent: false, useKeychain: false),
                              privateKeyPath: "~/.ssh/id_ed25519", sshConfigAlias: "docinho")
        let manager = SFTPManager()
        manager.connect(to: docinho)

        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while manager.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        #expect(manager.isLoading == false, "listing never completed within 20s — session is wedged")
        #expect(manager.error == nil, "listing failed: \(manager.error ?? "")")
        #expect(!manager.files.isEmpty, "expected docinho home directory to list at least one entry")
        #expect(manager.files.contains { $0.name == ".bashrc" })
    }

    /// Same as above but through the `ifi` ProxyJump path, to confirm the
    /// binary protocol client's `ssh -s sftp` invocation transparently
    /// tunnels through the jump host the same way the interactive CLI did.
    @Test func realBinarySFTPListingOnCoaraciThroughProxyJumpWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["SSHSTUDIO_REAL_TRANSFER_MATRIX"] == "1" else { return }

        let coaraci = Session(name: "sahmaddo", host: "sahmaddo", username: "sahmaddo",
                              authentication: .privateKey(path: "~/.ssh/id_ed25519", useAgent: true, addKeysToAgent: false, useKeychain: false),
                              privateKeyPath: "~/.ssh/id_ed25519", sshConfigAlias: "sahmaddo")
        let manager = SFTPManager()
        manager.connect(to: coaraci)

        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while manager.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        #expect(manager.isLoading == false, "listing never completed within 20s — session is wedged")
        #expect(manager.error == nil, "listing failed: \(manager.error ?? "")")
        #expect(!manager.files.isEmpty, "expected coaraci home directory to list at least one entry")
    }

    private static func submit(_ request: TransferRequest, name: String,
                               sourceSession: Session? = nil, destinationSession: Session? = nil,
                               sourceManager: SFTPManager? = nil, destinationManager: SFTPManager? = nil) async -> TransferResult {
        await withCheckedContinuation { continuation in
            TransferService.shared.submit(request, name: name, sourceSession: sourceSession,
                                          destinationSession: destinationSession, sourceManager: sourceManager,
                                          destinationManager: destinationManager) { result in
                continuation.resume(returning: result)
            }
        }
    }

    private static func runRemote(_ session: Session, command: String) async throws -> String {
        let invocation = try SSHCommandBuilder.remoteCommandInvocation(for: session, command: command, purpose: .sftp)
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = invocation.executableURL
            process.arguments = invocation.arguments
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { process in
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if process.terminationStatus == 0 { continuation.resume(returning: output) }
                else { continuation.resume(throwing: SFTPError.operationFailed(output)) }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    private static func remoteHash(_ session: Session, path: String) async throws -> String {
        let output = try await runRemote(session, command: "sha256sum -- \(SSHSecurity.remoteShellPath(path))")
        return output.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
    }

    private static func localHash(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test func schemaTwoProfilesMigrateRemoteStartDirectoryToSchemaThree() throws {
        var session = Session(name: "Legacy", host: "example.com", username: "legacy", remoteDirectory: "~/work")
        session.schemaVersion = 2
        let profile = PersistedSessionProfile(session: session, schemaVersion: 2)
        let data = try JSONEncoder().encode([profile])

        let result = try SessionPersistenceMigrator.decode(data)

        #expect(result.needsWrite == true)
        #expect(result.sessions[0].schemaVersion == PersistedSessionProfile.currentSchemaVersion)
        #expect(result.sessions[0].remoteStartDirectory == "~/work")
    }

    @Test func remoteStartDirectoryDefaultsToHomeWithoutPersonalHostFallback() {
        let session = Session(name: "Any Host", host: "example.com", username: "user")

        #expect(SFTPManager.startDirectory(for: session) == "~")
    }

    @Test func remotePathPreservesRemoteSemanticsAndEscapesSafely() throws {
        let paths = [
            "~/Project Files",
            "/srv/data/quoted ' name",
            "/srv/data/--leading-dash",
            "/srv//data///nested",
            "/srv/data/.hidden",
            "/srv/data/unicode-é"
        ]

        for raw in paths {
            let path = try SFTPPath(raw)
            #expect(!path.rawValue.isEmpty)
            #expect(!path.remoteShellEscaped.isEmpty)
            #expect(!path.rawValue.contains("//"))
        }

        #expect(throws: SFTPError.invalidRemotePath) {
            try SFTPPath("/tmp/bad\npath")
        }
    }

    @Test func sftpPathAppendsWithoutLocalNormalization() throws {
        let parent = try SFTPPath("~/folder")
        let child = try parent.appending(component: "name with spaces.txt")

        #expect(child.rawValue == "~/folder/name with spaces.txt")
        #expect(throws: SFTPError.invalidRemotePath) {
            try parent.appending(component: "../escape")
        }
    }

    @Test func sftpListingCommandUsesPortableLongHiddenFlagAndEscapesPaths() throws {
        let cases = [
            ("/", [
                #"cd "/""#,
                "pwd",
                "ls -la ."
            ].joined(separator: "\n")),
            ("/srv/Project Files", [
                #"cd "/srv/Project Files""#,
                "pwd",
                "ls -la ."
            ].joined(separator: "\n")),
            ("/srv/unicode-é", [
                #"cd "/srv/unicode-é""#,
                "pwd",
                "ls -la ."
            ].joined(separator: "\n")),
            (#"/srv/quoted "name""#, [
                #"cd "/srv/quoted \"name\"""#,
                "pwd",
                "ls -la ."
            ].joined(separator: "\n")),
            ("/media/shabir", [
                #"cd "/media/shabir""#,
                "pwd",
                "ls -la ."
            ].joined(separator: "\n")),
            ("~", [
                "cd",
                "pwd",
                "ls -la ."
            ].joined(separator: "\n")),
            ("~/Project Files", [
                "cd",
                #"cd "Project Files""#,
                "pwd",
                "ls -la ."
            ].joined(separator: "\n"))
        ]

        for (path, expected) in cases {
            let command = try SFTPManager.sftpListCommand(path: path)
            #expect(command == expected)
            #expect(!command.contains("-A"))
            #expect(!command.contains("lA"))
        }

        #expect(throws: SFTPError.invalidRemotePath) {
            try SFTPManager.sftpListCommand(path: "/tmp/bad\npath")
        }
    }

    @Test func sftpPwdOutputResolvesDisplayedDirectoryPerProfile() {
        let homeOutput = """
        sftp> cd
        sftp> pwd
        Remote working directory: /home/remote-account
        sftp> ls -la .
        """
        let rootOutput = """
        Remote working directory: /
        """
        let mediaOutput = """
        Remote working directory: /media/shabir
        """

        #expect(SFTPManager.resolvedPath(from: homeOutput) == "/home/remote-account")
        #expect(SFTPManager.resolvedPath(from: rootOutput) == "/")
        #expect(SFTPManager.resolvedPath(from: mediaOutput) == "/media/shabir")
        #expect(SFTPManager.resolvedPath(from: "Remote working directory: /home/other") == "/home/other")
    }

    @Test func directoryParserHandlesLongListingFixtures() throws {
        let output = """
        Remote working directory: /home/remote-account
        drwxr-xr-x  8 user group      4096 Jul 23 19:58 .
        drwxr-xr-x 18 user group      4096 Jul 23 19:57 ..
        drwxr-xr-x  2 user group      4096 Jul 23 19:59 .config
        drwxr-xr-x  2 user group      4096 Jul 23 20:00 Project Files
        -rw-r--r--  1 user group       128 Jul 23 20:01 report 'draft'.txt
        lrwxr-xr-x  1 user group        12 Jul 23 20:02 latest -> Project Files
        """

        let entries = try SFTPDirectoryParser.parseListing(output)

        #expect(entries.count == 4)
        #expect(entries.map(\.name).contains(".") == false)
        #expect(entries.map(\.name).contains("..") == false)
        #expect(entries[0].name == ".config")
        #expect(entries[0].isDirectory == true)
        #expect(entries[1].name == "Project Files")
        #expect(entries[2].name == "report 'draft'.txt")
    }

    @Test func directoryParserHandlesDocinhoMediaListingWithUnknownLinkCounts() throws {
        let output = """
        Remote working directory: /media/shabir
        drwxr-x---    ? root     root         4096 Jul 23 15:15 ./.
        drwxr-xr-x    ? root     root         4096 Feb 20  2025 ./..
        drwxr-xr-x    ? shabir   shabir       4096 Aug  2 12:41 ./Coaraci
        drwxr-xr-x    ? shabir   shabir     262144 Aug  2 12:42 ./Expansion
        """

        let entries = try SFTPDirectoryParser.parseListing(output)

        #expect(entries.map(\.name) == ["Coaraci", "Expansion"])
        #expect(entries.map(\.isDirectory) == [true, true])
    }

    @Test func sftpInvocationBuilderUsesSharedSecurityPolicy() throws {
        let session = Session(
            name: "Fixture",
            host: "example.com",
            username: "fixture",
            authMethod: .privateKey,
            privateKeyPath: "/tmp/fixture-key"
        )
        let invocation = try SFTPInvocationBuilder.invocation(for: session)

        #expect(invocation.purpose == .sftp)
        #expect(invocation.redactedDescription.contains("sftp"))
        #expect(!invocation.arguments.contains("-oStrictHostKeyChecking=no"))
    }

    @Test func editableRemotePathInputTrimsAndRejectsEmptyDrafts() {
        #expect(EditableRemotePathInput.committedPath(from: "  ~/work/project  ") == "~/work/project")
        #expect(EditableRemotePathInput.committedPath(from: "\n\t  ") == nil)
    }

    @Test func finderStyleSelectionSupportsSingleCommandShiftAndPreserve() {
        let ids = ["a", "b", "c", "d"]
        var selection = SFTPSelectionReducer()

        selection.apply(.single("b"), orderedIDs: ids)
        #expect(selection.selectedIDs == ["b"])

        selection.apply(.command("d"), orderedIDs: ids)
        #expect(selection.selectedIDs == ["b", "d"])

        selection.apply(.shift("a"), orderedIDs: ids)
        #expect(selection.selectedIDs == ["a", "b", "c", "d"])

        selection.apply(.preserve(availableIDs: ["a", "d"]), orderedIDs: ["a", "d"])
        #expect(selection.selectedIDs == ["a", "d"])

        selection.apply(.empty, orderedIDs: ids)
        #expect(selection.selectedIDs.isEmpty)
    }

    @Test func sftpSingleClickNavigatesDirectoriesAndModifierClicksSelect() {
        #expect(SFTPRemoteClickPolicy.singleClickAction(
            id: "dir",
            isDirectory: true,
            commandKey: false,
            shiftKey: false
        ) == .navigate)
        #expect(SFTPRemoteClickPolicy.singleClickAction(
            id: "dir",
            isDirectory: true,
            commandKey: true,
            shiftKey: false
        ) == .select(.command("dir")))
        #expect(SFTPRemoteClickPolicy.singleClickAction(
            id: "dir",
            isDirectory: true,
            commandKey: false,
            shiftKey: true
        ) == .select(.shift("dir")))
        #expect(SFTPRemoteClickPolicy.singleClickAction(
            id: "file",
            isDirectory: false,
            commandKey: false,
            shiftKey: false
        ) == .select(.single("file")))
    }

    @Test func sftpKeyboardShortcutsRequireSFTPFocusAndAvoidTerminalFocus() {
        #expect(SFTPKeyboardRouter.command(
            key: "c",
            modifiers: ["command"],
            sftpHasFocus: true,
            terminalHasFocus: false
        ) == .copy)
        #expect(SFTPKeyboardRouter.command(
            key: "c",
            modifiers: ["command"],
            sftpHasFocus: true,
            terminalHasFocus: true
        ) == nil)
        #expect(SFTPKeyboardRouter.command(
            key: "[",
            modifiers: ["command"],
            sftpHasFocus: true,
            terminalHasFocus: false
        ) == .back)
        #expect(SFTPKeyboardRouter.command(
            key: "up",
            modifiers: ["command"],
            sftpHasFocus: true,
            terminalHasFocus: false
        ) == .parent)
    }

    @Test func navigationHistorySupportsBackForwardParentInputs() throws {
        let history = NavigationHistory<String>(initial: "/")
        history.navigate(to: "/media")
        history.navigate(to: "/media/shabir")

        #expect(history.current == "/media/shabir")
        #expect(history.canGoBack)
        history.goBack()
        #expect(history.current == "/media")
        #expect(history.canGoForward)
        history.goForward()
        #expect(history.current == "/media/shabir")

        #expect(try SFTPPath("/media/shabir").parent().rawValue == "/media")
    }

    @Test func typedSFTPClipboardPayloadRoundTripsCopyAndCutState() throws {
        let profileID = UUID()
        let item = SFTPClipboardItem(
            path: "/media/shabir/Project Files/quoted ' name",
            name: "quoted ' name",
            isDirectory: false
        )
        let payload = SFTPClipboardPayload(
            sourceProfileID: profileID,
            items: [item],
            operation: .move,
            timestamp: Date(timeIntervalSince1970: 42)
        )

        let decoded = try JSONDecoder().decode(SFTPClipboardPayload.self, from: JSONEncoder().encode(payload))

        #expect(decoded == payload)
        #expect(decoded.operation == .move)
        #expect(decoded.sourceProfileID == profileID)
    }

    @Test func sameServerMoveBuildsSFTPRenameCommandsForDifficultPaths() throws {
        let items = [
            SFTPClipboardItem(
                path: #"/media/shabir/Project Files/--leading "quote".txt"#,
                name: #"--leading "quote".txt"#,
                isDirectory: false
            ),
            SFTPClipboardItem(
                path: "/media/shabir/unicode-é",
                name: "unicode-é",
                isDirectory: true
            )
        ]

        let commands = try SFTPMutationBatchBuilder.renameCommands(
            items: items,
            destinationPath: "/media/shabir/Destination Folder",
            overwrite: false
        )

        #expect(commands == [
            #"rename "/media/shabir/Project Files/--leading \"quote\".txt" "/media/shabir/Destination Folder/--leading \"quote\".txt""#,
            #"rename "/media/shabir/unicode-é" "/media/shabir/Destination Folder/unicode-é""#
        ])
        #expect(commands.joined(separator: "\n").contains("-A") == false)
    }

    @Test func copyConflictDetectionFindsDestinationNameCollisions() {
        let conflicts = SFTPConflictPolicy.conflictingNames(
            sourceNames: ["alpha", "Project Files", "unicode-é"],
            destinationNames: ["Project Files", "other", "unicode-é"]
        )

        #expect(conflicts == ["Project Files", "unicode-é"])
    }

    @Test func transferCancellationTransitionsToCancelled() {
        let item = TransferItem(name: "copy", direction: .serverToServer)
        item.status = .inProgress

        item.cancel()

        guard case .cancelled? = item.finishCancellationIfNeeded() else {
            Issue.record("Expected transfer cancellation state")
            return
        }
    }

    @Test func directoryCacheInvalidatesMutatedPathsOnly() {
        var cache = SFTPDirectoryCache(ttl: 60, capacity: 10)
        let profileID = UUID()
        let otherProfileID = UUID()
        let key = SFTPListingCacheKey(
            profileID: profileID,
            normalizedPath: "/media/shabir",
            options: SFTPListingOptions(showHiddenFiles: true)
        )
        let otherKey = SFTPListingCacheKey(
            profileID: otherProfileID,
            normalizedPath: "/media/shabir",
            options: SFTPListingOptions(showHiddenFiles: true)
        )
        let file = RemoteFile(name: "Project Files", isDirectory: true, size: "Folder", permissions: "drwxr-xr-x", modified: "Aug 2", modifiedDate: nil)

        cache.set([file], for: key)
        cache.set([file], for: otherKey)
        cache.invalidate(profileID: profileID, path: "/media/shabir")

        #expect(cache.value(for: key) == nil)
        #expect(cache.value(for: otherKey)?.files == [file])
    }

    @Test func rightClickUnselectedRowSelectionUsesSingleSelectionRule() {
        let ids = ["first", "second", "third"]
        var selection = SFTPSelectionReducer()
        selection.apply(.single("first"), orderedIDs: ids)

        selection.apply(.single("third"), orderedIDs: ids)

        #expect(selection.selectedIDs == ["third"])
    }

    @Test func recursiveDirectoryDownloadCommandUsesGetR() throws {
        let command = try SFTPRecursiveDownloadBuilder.command(
            remotePath: "/remote/pontos_xyz",
            localPartialPath: "/tmp/.pontos_xyz.partial"
        )

        #expect(command == #"get -a -R "/remote/pontos_xyz" "/tmp/.pontos_xyz.partial""#)
        #expect(command.contains("find ") == false)
    }

    @Test func recursiveDirectoryDownloadSupportsEmptyAndNestedDirectoriesByUsingServerRecursion() throws {
        let empty = try SFTPRecursiveDownloadBuilder.command(
            remotePath: "/remote/empty",
            localPartialPath: "/tmp/.empty.partial"
        )
        let nested = try SFTPRecursiveDownloadBuilder.command(
            remotePath: "/remote/a/b/c",
            localPartialPath: "/tmp/.c.partial"
        )

        #expect(empty.contains("get -a -R"))
        #expect(nested.contains(#""/remote/a/b/c""#))
    }

    @Test func recursiveDirectoryDownloadQuotesSpacesUnicodeQuotesAndLeadingDashes() throws {
        let command = try SFTPRecursiveDownloadBuilder.command(
            remotePath: #"/remote/Project Files/unicode-é/--leading "quote"/pontos_xyz"#,
            localPartialPath: #"/tmp/.unicode-é "quote".partial"#
        )

        #expect(command == #"get -a -R "/remote/Project Files/unicode-é/--leading \"quote\"/pontos_xyz" "/tmp/.unicode-é \"quote\".partial""#)
    }

    @Test func recursiveDirectoryDownloadRejectsInvalidRemotePaths() {
        #expect(throws: SFTPError.invalidRemotePath) {
            try SFTPRecursiveDownloadBuilder.command(
                remotePath: "/remote/bad\npath",
                localPartialPath: "/tmp/partial"
            )
        }
    }

    @Test func typedDownloadErrorsClassifyPermissionConnectionAuthAndUnsupportedRecursiveTransfer() {
        #expect(SFTPDownloadDiagnostics.classify("Permission denied") == .permissionDenied)
        #expect(SFTPDownloadDiagnostics.classify("No such file or directory") == .remoteDirectoryNotFound)
        #expect(SFTPDownloadDiagnostics.classify("Connection closed") == .connectionClosed)
        #expect(SFTPDownloadDiagnostics.classify("Authentication failed") == .authenticationFailed)
        #expect(SFTPDownloadDiagnostics.classify("Invalid flag -R") == .recursiveTransferUnsupported)
    }

    @Test func localConflictActionsCoverReplaceMergeKeepBothAndCancel() {
        let keepBothURL = URL(fileURLWithPath: "/tmp/pontos_xyz copy")
        let actions: [SFTPLocalConflictAction] = [
            .replace,
            .merge,
            .keepBoth(keepBothURL),
            .cancel
        ]

        #expect(actions.count == 4)
        #expect(actions.contains(.keepBoth(keepBothURL)))
    }

    @Test func symlinkPolicyDoesNotAddFollowSymlinkFlagsByDefault() throws {
        let command = try SFTPRecursiveDownloadBuilder.command(
            remotePath: "/remote/tree",
            localPartialPath: "/tmp/.tree.partial"
        )

        #expect(!command.contains(" -L "))
        #expect(!command.contains("--copy-links"))
    }

    @Test func proxyJumpSFTPInvocationStillUsesSSHConfigAlias() throws {
        let session = Session(
            name: "Proxy Fixture",
            host: "ignored.example",
            username: "fixture",
            authentication: .sshConfigManaged,
            sshConfigAlias: "docinho"
        )

        let invocation = try SFTPInvocationBuilder.invocation(for: session)

        #expect(invocation.arguments.contains("fixture@docinho"))
        #expect(invocation.arguments.contains("-P"))
    }

    @Test func fallbackSFTPModeUsesBatchFileAndNoShellFindForDirectoryDownload() throws {
        let batch = URL(fileURLWithPath: "/tmp/sshstudio batch")
        let session = Session(
            name: "Fallback Fixture",
            host: "example.com",
            username: "fixture",
            authentication: .sshConfigManaged
        )

        let invocation = try SSHCommandBuilder.sftpInvocation(for: session, batchURL: batch)
        let command = try SFTPRecursiveDownloadBuilder.command(
            remotePath: "/remote/pontos_xyz",
            localPartialPath: "/tmp/.pontos_xyz.partial"
        )

        #expect(invocation.arguments.contains("-b"))
        #expect(command.contains("find ") == false)
        #expect(command.contains("get -a -R"))
    }

    @Test func singleFileDownloadRsyncFallbackPreservesProxyJumpAliasAndDifficultPaths() {
        let session = Session(
            name: "clauberh",
            host: "clauberh",
            username: "clauberh",
            authentication: .sshConfigManaged,
            sshConfigAlias: "clauberh"
        )
        let remotePath = #"/home/users/clauberh/project dir/unicode-é/quoted "name"/--leading/00_PMF_CRD-distance-WAT.py"#

        let location = SFTPManager.rsyncRemoteLocation(session: session, path: remotePath)

        #expect(location.hasPrefix("clauberh@clauberh:"))
        #expect(location.contains(#"project\ dir"#))
        #expect(location.contains(#"quoted\ \"#))
        #expect(location.contains(#"--leading"#))
        #expect(location.contains("00_PMF_CRD-distance-WAT.py"))
    }

    @Test func uploadDirectoryPreflightDoesNotRequireShellWritableProbe() {
        let command = SFTPManager.remoteUploadDirectoryPreflightCommand(
            path: "/media/shabir/Expansion/00_Doctorate/01_Simulations/01_HiCel6a"
        )

        #expect(command.contains("mkdir -p --"))
        #expect(command.contains("[ -d "))
        #expect(command.contains("[ -w ") == false)
    }

    @Test func singleFileBatchDownloadsUseFallbackCapablePipeline() {
        #expect(SFTPManager.shouldUseSingleFileDownloadPipeline(remoteItems: [
            (
                remotePath: "/remote/0-pmf2/00_PMF_CRD-distance-WAT.py",
                name: "00_PMF_CRD-distance-WAT.py",
                isDirectory: false
            )
        ]))
        #expect(!SFTPManager.shouldUseSingleFileDownloadPipeline(remoteItems: [
            (remotePath: "/remote/a.py", name: "a.py", isDirectory: false),
            (remotePath: "/remote/b.py", name: "b.py", isDirectory: false)
        ]))
        #expect(!SFTPManager.shouldUseSingleFileDownloadPipeline(remoteItems: [
            (remotePath: "/remote/folder", name: "folder", isDirectory: true)
        ]))
    }

    @Test func singleFileDestinationSemanticsSeparateDirectoryFromSaveAs() {
        let directory = URL(fileURLWithPath: "/tmp/download target", isDirectory: true)
        let saveAs = URL(fileURLWithPath: "/tmp/custom.py")

        #expect(SFTPManager.singleFileFinalDestination(
            name: "00_PMF_CRD-distance-WAT.py",
            destination: .directory(directory)
        ).path == "/tmp/download target/00_PMF_CRD-distance-WAT.py")
        #expect(SFTPManager.singleFileFinalDestination(
            name: "00_PMF_CRD-distance-WAT.py",
            destination: .saveAs(saveAs)
        ).path == "/tmp/custom.py")
    }

    @Test func rsyncFallbackUsesSystemSSHAndRetriesTransientJumpFailures() {
        let session = Session(
            name: "clauberh",
            host: "clauberh",
            username: "clauberh",
            authentication: .sshConfigManaged,
            sshConfigAlias: "clauberh"
        )
        let args = SSHCommandBuilder.rsyncSSHArgs(for: session)

        #expect(args.first == "/usr/bin/ssh")
        #expect(args.contains("ConnectTimeout=10"))
        #expect(SFTPManager.isRetryableTransferFailure("Connection timed out during banner exchange"))
        #expect(SFTPManager.isRetryableTransferFailure("ssh: Could not resolve hostname gate.example"))
        #expect(SFTPManager.isRetryableTransferFailure("Connection closed by UNKNOWN port 65535"))
    }

    @Test func realClauberhSingleFileDownloadThroughAppServiceWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment[Self.clauberhRealDownloadFlag] == "1" else { return }

        let session = Session(
            name: "clauberh",
            host: "clauberh",
            username: "clauberh",
            authentication: .privateKey(path: "~/.ssh/id_ed25519", useAgent: true, addKeysToAgent: false, useKeychain: false),
            privateKeyPath: "~/.ssh/id_ed25519",
            sshConfigAlias: "clauberh",
            remoteStartDirectory: (Self.clauberhRemoteFile as NSString).deletingLastPathComponent
        )
        let manager = SFTPManager()
        manager.setActiveSessionForTesting(
            session,
            currentPath: (Self.clauberhRemoteFile as NSString).deletingLastPathComponent
        )
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("sshstudio-real-clauberh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        await withCheckedContinuation { continuation in
            manager.downloadBatch(
                remoteItems: [(
                    remotePath: Self.clauberhRemoteFile,
                    name: Self.clauberhFileName,
                    isDirectory: false
                )],
                to: destination,
                session: session
            ) {
                continuation.resume()
            }
        }

        let downloaded = destination.appendingPathComponent(Self.clauberhFileName)
        if !FileManager.default.fileExists(atPath: downloaded.path) {
            let item = TransferQueue.shared.items.first
            let status = item?.statusLabel ?? "missing transfer item"
            let details = item?.detailLines.joined(separator: " | ") ?? ""
            Issue.record("Real clauberh app-service download missing local file. status=\(status) details=\(details)")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: downloaded.path)
        let size = try #require(attributes[.size] as? NSNumber).intValue
        #expect(size > 0)
    }
}
