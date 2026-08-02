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

    @Test func directoryParserHandlesLongListingFixtures() throws {
        let output = """
        drwxr-xr-x  2 user group      4096 Jul 23 20:00 Project Files
        -rw-r--r--  1 user group       128 Jul 23 20:01 report 'draft'.txt
        lrwxr-xr-x  1 user group        12 Jul 23 20:02 latest -> Project Files
        """

        let entries = try SFTPDirectoryParser.parseListing(output)

        #expect(entries.count == 3)
        #expect(entries[0].name == "Project Files")
        #expect(entries[0].isDirectory == true)
        #expect(entries[1].name == "report 'draft'.txt")
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
}
