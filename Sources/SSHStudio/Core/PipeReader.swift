import Foundation

final class PipeReader: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private let condition = NSCondition()
    private var chunks: [Data] = []
    private var started = false
    private var finished = false

    init(pipe: Pipe) {
        self.handle = pipe.fileHandleForReading
    }

    init(fileHandle: FileHandle) {
        self.handle = fileHandle
    }

    func start(onData: (@Sendable (Data) -> Void)? = nil) {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        Thread.detachNewThread { [weak self] in
            self?.readLoop(onData: onData)
        }
    }

    func collectedData() -> Data {
        waitUntilFinished()
        lock.lock()
        defer { lock.unlock() }
        var data = Data()
        for chunk in chunks {
            data.append(chunk)
        }
        return data
    }

    func waitUntilFinished() {
        condition.lock()
        while started && !finished {
            condition.wait()
        }
        condition.unlock()
    }

    @discardableResult
    func waitUntilFinished(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        while started && !finished {
            if !condition.wait(until: deadline) {
                break
            }
        }
        let completed = !started || finished
        condition.unlock()
        return completed
    }

    private func readLoop(onData: (@Sendable (Data) -> Void)?) {
        while true {
            let data = handle.readData(ofLength: 4096)
            guard !data.isEmpty else { break }
            lock.lock()
            chunks.append(data)
            lock.unlock()
            onData?(data)
        }
        try? handle.close()
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
    }
}
