import Foundation
import Darwin

@main struct WorkBuddyProcessChecks {
    enum Failure: Error { case environmentConsumed, writerMissing, unrelatedWriter }
    static func main() {
        if CommandLine.arguments.dropFirst().first == "--fixture" {
            FileHandle.standardOutput.write(Data([1]))
            sleep(60)
            return
        }
        do { try run() }
        catch { print("FAIL process inspection regression"); exit(1) }
    }

    static func run() throws {
        var argumentCount: Int32 = 2
        let arguments = withUnsafeBytes(of: &argumentCount) { Array($0) } +
            Array("/usr/local/bin/node\0\0node\0/Applications/WorkBuddy.app/daemon.js\0SECRET=synthetic\0".utf8)
        let command = try DesktopClientProcesses.command(arguments)
        guard command.executable == "/usr/local/bin/node",
            command.arguments == ["node", "/Applications/WorkBuddy.app/daemon.js"] else {
            throw Failure.environmentConsumed
        }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("loongpass-process-checks-\(UUID())")
        let bundle = root.appendingPathComponent("WorkBuddy.app")
        let executable = bundle.appendingPathComponent("Contents/MacOS/Electron")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[0]), to: executable)
        let child = Process()
        child.executableURL = executable
        child.arguments = ["--fixture"]
        let ready = Pipe()
        child.standardOutput = ready
        try child.run()
        defer {
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }
        // Unlink only after exec/dyld/code-signature validation has completed.
        // Removing a newly spawned binary sooner can make macOS kill it (9).
        guard try ready.fileHandleForReading.read(upToCount: 1) == Data([1]) else {
            throw Failure.writerMissing
        }
        try FileManager.default.removeItem(at: executable)
        // An unlinked executable is still an active writer. Looking up its
        // vnode path fails, but the kernel retains the executed path/argv.
        let active = try DesktopClientProcesses.writers(in: bundle)
        guard active.contains(child.processIdentifier) else { throw Failure.writerMissing }
        child.terminate()
        child.waitUntilExit()
        guard try DesktopClientProcesses.writers(in: bundle).isEmpty else { throw Failure.unrelatedWriter }
        print("PASS unlinked executable remains a writer; unrelated processes do not block stopped-client detection")
    }
}
