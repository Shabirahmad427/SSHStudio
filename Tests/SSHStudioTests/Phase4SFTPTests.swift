import Foundation
import Testing
@testable import SSHStudio

@Suite("SSH Studio Phase 4 SFTP")
@MainActor
struct Phase4SFTPTests {
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
}
