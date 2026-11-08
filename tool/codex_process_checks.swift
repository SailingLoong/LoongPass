import Foundation
import Darwin

@main struct CodexProcessChecks {
    static func main() throws {
        if CommandLine.arguments.dropFirst().first == "--fixture" {
            FileHandle.standardOutput.write(Data([1])); sleep(30); return
        }
        let bundle = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        let cases: [(String, [String], Bool)] = [
            ("/opt/bin/codex", [], true),
            ("/Applications/ChatGPT.app/Contents/MacOS/ChatGPT", [], true),
            ("/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex", [], true),
            ("/usr/local/bin/node", ["node", "/tmp/node_modules/@openai/codex/bin/codex.js"], true),
            ("/usr/local/bin/node", ["node", "/tmp/unrelated.js"], false),
            ("/opt/bin/code", [], false),
        ]
        for (executable, args, expected) in cases {
            let command = DesktopClientProcesses.Command(executable: executable, arguments: args)
            precondition(CodexDesktopClient.isWriter(command, bundle: bundle) == expected)
        }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("loongpass-codex-process-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("codex")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[0]), to: executable)
        let child = Process(), ready = Pipe()
        child.executableURL = executable; child.arguments = ["--fixture"]; child.standardOutput = ready
        try child.run()
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        let signal = try ready.fileHandleForReading.read(upToCount: 1)
        precondition(signal == Data([1]))
        let writers = try DesktopClientProcesses.writers { CodexDesktopClient.isWriter($0, bundle: bundle) }
        precondition(writers.contains(child.processIdentifier), "External CLI writer was ignored")
        print("Codex process checks passed: installed desktop, separate CLI, Node wrapper and live external writer")
    }
}
