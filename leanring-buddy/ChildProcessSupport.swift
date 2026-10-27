//
//  ChildProcessSupport.swift
//  leanring-buddy
//
//  Small helpers for running other programs from Clicky: `claude` for answers
//  and background tasks, `say` for the voice. One runs a program to the end
//  and hands back everything it printed; the other streams a program's output
//  line by line while it's still running. Foundation only, so the standalone
//  tests can use it.
//

import Foundation

/// What a finished program printed and how it exited.
struct ChildProcessResult {
    let exitCode: Int32
    let standardOutput: Data
    let standardError: Data

    var standardOutputText: String { String(decoding: standardOutput, as: UTF8.self) }
    var standardErrorText: String { String(decoding: standardError, as: UTF8.self) }
}

enum ChildProcessRunner {
    /// Runs a program, optionally feeding it text on stdin, and waits for it to
    /// finish. Cancelling the calling task terminates the program. Programs that
    /// run longer than `timeLimitSeconds` are terminated too.
    static func runToCompletion(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil,
        standardInputText: String? = nil,
        timeLimitSeconds: TimeInterval = 60
    ) async throws -> ChildProcessResult {
        let childProcess = Process()
        childProcess.executableURL = executableURL
        childProcess.arguments = arguments
        if let environment { childProcess.environment = environment }
        if let currentDirectoryURL { childProcess.currentDirectoryURL = currentDirectoryURL }

        let standardInputPipe = Pipe()
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        childProcess.standardInput = standardInputText == nil ? FileHandle.nullDevice : standardInputPipe
        childProcess.standardOutput = standardOutputPipe
        childProcess.standardError = standardErrorPipe

        return try await withTaskCancellationHandler {
            try childProcess.run()

            let timeLimitWorkItem = DispatchWorkItem {
                if childProcess.isRunning { childProcess.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeLimitSeconds, execute: timeLimitWorkItem)

            // Both pipes are drained on their own threads: a program that fills
            // one pipe while we wait on the other would otherwise never finish.
            async let standardOutputData = readToEndOnBackgroundThread(standardOutputPipe.fileHandleForReading)
            async let standardErrorData = readToEndOnBackgroundThread(standardErrorPipe.fileHandleForReading)

            if let standardInputText {
                // Text goes in over stdin so nothing in it can be read as a flag
                writeAndCloseOnBackgroundThread(Data(standardInputText.utf8), to: standardInputPipe.fileHandleForWriting)
            }

            let (collectedStandardOutput, collectedStandardError) = await (standardOutputData, standardErrorData)

            await waitForExitOnBackgroundThread(childProcess)
            timeLimitWorkItem.cancel()
            try Task.checkCancellation()

            return ChildProcessResult(
                exitCode: childProcess.terminationStatus,
                standardOutput: collectedStandardOutput,
                standardError: collectedStandardError
            )
        } onCancel: {
            if childProcess.isRunning { childProcess.terminate() }
        }
    }

    static func readToEndOnBackgroundThread(_ fileHandle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: fileHandle.readDataToEndOfFile())
            }
        }
    }

    /// Writing to a pipe blocks until the program reads it, which can take a
    /// moment for a large screenshot, so it never happens on the calling thread.
    static func writeAndCloseOnBackgroundThread(_ dataToWrite: Data, to fileHandle: FileHandle) {
        DispatchQueue.global().async {
            // The program may already have exited (for example, cancelled). A
            // write to a closed pipe would raise SIGPIPE and kill Clicky, so the
            // pipe reports an error instead, which is expected and harmless.
            _ = fcntl(fileHandle.fileDescriptor, F_SETNOSIGPIPE, 1)
            try? fileHandle.write(contentsOf: dataToWrite)
            try? fileHandle.close()
        }
    }

    static func waitForExitOnBackgroundThread(_ childProcess: Process) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                childProcess.waitUntilExit()
                continuation.resume()
            }
        }
    }

    /// The lines a running program prints, as they arrive. The sequence ends
    /// when the program closes its output (normally when it exits). A last
    /// line without a trailing newline is still delivered.
    static func outputLines(from fileHandle: FileHandle) -> AsyncStream<String> {
        AsyncStream { continuation in
            let lineSplitter = OutputLineSplitter()
            fileHandle.readabilityHandler = { readableFileHandle in
                let newlyReadData = readableFileHandle.availableData
                if newlyReadData.isEmpty {
                    // End of output
                    readableFileHandle.readabilityHandler = nil
                    if let lastPartialLine = lineSplitter.finish() {
                        continuation.yield(lastPartialLine)
                    }
                    continuation.finish()
                    return
                }
                for completeLine in lineSplitter.append(newlyReadData) {
                    continuation.yield(completeLine)
                }
            }
            continuation.onTermination = { _ in
                fileHandle.readabilityHandler = nil
            }
        }
    }
}

/// Collects raw output and hands back whole lines. Bytes are kept until a
/// newline arrives, so a multi-byte character split across reads stays intact.
final class OutputLineSplitter {
    private var bufferedBytes = Data()

    /// Adds newly read output and returns every line it completed.
    func append(_ newlyReadData: Data) -> [String] {
        bufferedBytes.append(newlyReadData)
        var completedLines: [String] = []
        while let newlineIndex = bufferedBytes.firstIndex(of: UInt8(ascii: "\n")) {
            let lineBytes = bufferedBytes[bufferedBytes.startIndex..<newlineIndex]
            completedLines.append(String(decoding: lineBytes, as: UTF8.self))
            bufferedBytes.removeSubrange(bufferedBytes.startIndex...newlineIndex)
        }
        return completedLines
    }

    /// Whatever is left after the output ends, if it isn't empty.
    func finish() -> String? {
        defer { bufferedBytes.removeAll() }
        let remainingText = String(decoding: bufferedBytes, as: UTF8.self)
        return remainingText.isEmpty ? nil : remainingText
    }
}

/// Text a background reader appends to while another thread may read it.
final class LockedTextBuffer {
    private let lock = NSLock()
    private var collectedText = ""

    func append(_ newText: String) {
        lock.lock()
        collectedText += newText
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return collectedText
    }
}
