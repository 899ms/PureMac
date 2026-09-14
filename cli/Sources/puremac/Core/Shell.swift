import Darwin
import Foundation

enum Shell {
    struct Result {
        let status: Int32
        let out: String
        let err: String
    }

    static let outputLimit = 1_048_576

    @discardableResult
    static func run(
        _ launchPath: String,
        _ args: [String],
        timeout: TimeInterval = 15
    ) -> Result {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else {
            return Result(status: 127, out: "", err: "not found: \(launchPath)")
        }

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let output = OutputBuffer(limit: outputLimit)
        let errors = OutputBuffer(limit: outputLimit)
        let readers = DispatchGroup()
        let exitSignal = DispatchSemaphore(value: 0)

        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { _ in exitSignal.signal() }

        do {
            try process.run()
        } catch {
            return Result(status: 126, out: "", err: "failed to launch: \(launchPath)")
        }

        drain(outputPipe.fileHandleForReading, into: output, group: readers)
        drain(errorPipe.fileHandleForReading, into: errors, group: readers)

        let didExit = exitSignal.wait(timeout: .now() + max(timeout, 0)) == .success
        let timedOut = !didExit && process.isRunning
        if timedOut {
            stop(process, exitSignal: exitSignal)
        }

        finishReaders(
            readers,
            handles: [outputPipe.fileHandleForReading, errorPipe.fileHandleForReading]
        )

        let stdout = output.string()
        let stderr = errors.string()
        if timedOut {
            return Result(status: 124, out: stdout, err: "command timed out")
        }

        let status = process.terminationStatus
        let error = status != 0 && stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "command exited with status \(status)"
            : stderr
        return Result(status: status, out: stdout, err: error)
    }

    private static func stop(_ process: Process, exitSignal: DispatchSemaphore) {
        guard process.isRunning else { return }
        process.terminate()
        if exitSignal.wait(timeout: .now() + 0.25) == .success { return }
        guard process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
        _ = exitSignal.wait(timeout: .now() + 0.75)
    }

    private static func drain(
        _ handle: FileHandle,
        into buffer: OutputBuffer,
        group: DispatchGroup
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            while true {
                do {
                    guard let data = try handle.read(upToCount: 65_536), !data.isEmpty else { return }
                    buffer.append(data)
                } catch {
                    return
                }
            }
        }
    }

    private static func finishReaders(_ readers: DispatchGroup, handles: [FileHandle]) {
        if readers.wait(timeout: .now() + 0.25) == .success { return }
        for handle in handles {
            try? handle.close()
        }
        _ = readers.wait(timeout: .now() + 0.25)
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private static let marker = "\n[output truncated]"
    private let lock = NSLock()
    private let capacity: Int
    private var data = Data()
    private var truncated = false

    init(limit: Int) {
        capacity = max(0, limit - Self.marker.utf8.count)
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, capacity - data.count)
        data.append(chunk.prefix(remaining))
        if chunk.count > remaining {
            truncated = true
        }
    }

    func string() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self) + (truncated ? Self.marker : "")
    }
}
