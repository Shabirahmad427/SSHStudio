import Foundation
import Testing
@testable import SSHStudio

@Suite("SSH Studio Phase 4 Terminal")
@MainActor
struct Phase4TerminalTests {
    @Test func terminalControllerPreventsDuplicateStart() {
        let controller = TerminalSessionController()

        #expect(controller.beginStart() == true)
        #expect(controller.beginStart() == false)

        controller.processStarted()
        #expect(controller.beginStart() == false)
    }

    @Test func userDisconnectTargetsOwnedProcess() {
        let controller = TerminalSessionController()
        let process = FakeTerminalProcess()
        controller.attach(processHandle: process)
        #expect(controller.beginStart() == true)
        controller.processStarted()

        controller.disconnect(gracePeriod: 10)

        #expect(process.gracefulTerminateCount == 1)
        guard case .disconnecting(_, forced: false) = controller.state else {
            Issue.record("Expected disconnecting state")
            return
        }
    }

    @Test func forcedTerminationAfterTimeoutUsesExactProcess() async throws {
        let controller = TerminalSessionController()
        let process = FakeTerminalProcess()
        controller.attach(processHandle: process)
        _ = controller.beginStart()
        controller.processStarted()

        controller.disconnect(gracePeriod: 0.01)
        try await Task.sleep(for: .milliseconds(30))

        #expect(process.forceTerminateCount == 1)
        #expect(process.processIdentifier == 4242)
    }

    @Test func unexpectedExitIsNotUserRequested() {
        let controller = TerminalSessionController()
        _ = controller.beginStart()
        controller.processStarted()
        controller.processExited(exitStatus: 255, message: "network error")

        if case .exited(_, let status, let userRequested) = controller.state {
            #expect(status == 255)
            #expect(userRequested == false)
        } else {
            Issue.record("Expected exited state")
        }
    }

    @Test func closePolicyRequiresConfirmationForRunningSession() {
        let controller = TerminalSessionController()
        _ = controller.beginStart()
        controller.processStarted()

        #expect(controller.closePolicy(transferCount: 2, tunnelCount: 1) == .confirmDisconnect(transferCount: 2, tunnelCount: 1, reconnecting: false))

        controller.processExited(exitStatus: 0)
        #expect(controller.closePolicy(transferCount: 0, tunnelCount: 0) == .closeImmediately)
    }

    @Test func terminalFindRoutesToAttachedProcess() {
        let controller = TerminalSessionController()
        let process = FakeTerminalProcess()
        controller.attach(processHandle: process)
        controller.findText = "needle"

        #expect(controller.findNext() == true)
        #expect(controller.findPrevious() == true)
        controller.closeFind()

        #expect(process.findNextTerms == ["needle"])
        #expect(process.findPreviousTerms == ["needle"])
        #expect(process.clearFindCount == 1)
    }
}

@MainActor
private final class FakeTerminalProcess: TerminalProcessControlling {
    var isRunning = true
    let processIdentifier: pid_t = 4242
    var gracefulTerminateCount = 0
    var forceTerminateCount = 0
    var focusCount = 0
    var clearFindCount = 0
    var findNextTerms: [String] = []
    var findPreviousTerms: [String] = []

    func terminateGracefully() {
        gracefulTerminateCount += 1
    }

    func forceTerminate() {
        forceTerminateCount += 1
    }

    func focusTerminal() {
        focusCount += 1
    }

    func findNext(_ term: String) -> Bool {
        findNextTerms.append(term)
        return true
    }

    func findPrevious(_ term: String) -> Bool {
        findPreviousTerms.append(term)
        return true
    }

    func clearFind() {
        clearFindCount += 1
    }
}
