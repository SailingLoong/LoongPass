import Foundation
import Darwin

/// Finds native auth writers before a desktop session is replaced.
enum DesktopClientProcesses {
    enum Failure: Error { case busy }
    struct Command {
        let executable: String
        let arguments: [String]
    }

    // KERN_PROCARGS2 retains the executed path even when an updater removes the
    // executable's vnode path. Never interpret or expose environment entries.
    static func command(_ bytes: [UInt8]) throws -> Command {
        guard bytes.count > 4, bytes.count <= 1_048_576 else { throw Failure.busy }
        let count = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0, count < 16384 else { throw Failure.busy }
        var offset = 4
        while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
        guard offset < bytes.count,
            let executable = String(bytes: bytes[4..<offset], encoding: .utf8),
            executable.hasPrefix("/") else { throw Failure.busy }
        // Only generic script runtimes need argv to identify a bundled daemon.
        guard ["node", "bun", "workbuddy"].contains(URL(fileURLWithPath: executable).lastPathComponent.lowercased()) else {
            return Command(executable: executable, arguments: [])
        }
        while offset < bytes.count, bytes[offset] == 0 { offset += 1 }
        var arguments: [String] = []
        for _ in 0..<count {
            let start = offset
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            guard offset < bytes.count,
                let value = String(bytes: bytes[start..<offset], encoding: .utf8) else {
                throw Failure.busy
            }
            arguments.append(value)
            offset += 1
        }
        return Command(executable: executable, arguments: arguments)
    }

    private static func command(of pid: pid_t) throws -> Command? {
        var query: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&query, 3, nil, &size, nil, 0) == 0 else {
            if try liveInfo(pid) == nil { return nil }
            throw Failure.busy
        }
        guard size > 4, size <= 1_048_576 else { throw Failure.busy }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&query, 3, &bytes, &size, nil, 0) == 0 else {
            if try liveInfo(pid) == nil { return nil }
            throw Failure.busy
        }
        guard size <= bytes.count else { throw Failure.busy }
        return try command(Array(bytes.prefix(size)))
    }

    private static func liveInfo(_ pid: pid_t) throws -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let returned = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size))
        let code = errno
        guard returned == size else {
            // arg=0 excludes zombies. kill(pid, 0) still succeeds for a zombie,
            // so it cannot serve as this API's "still able to write" check.
            if returned == 0 && code == ESRCH { return nil }
            throw Failure.busy
        }
        return info.pbi_status == UInt32(SZOMB) ? nil : info
    }

    static func writers(in bundle: URL) throws -> [pid_t] {
        try writers { command in
            command.executable.hasPrefix(bundle.path + "/") ||
                command.arguments.contains(where: { $0.contains(bundle.path + "/") })
        }
    }

    static func writers(matching: (Command) -> Bool) throws -> [pid_t] {
        let stride = MemoryLayout<pid_t>.stride
        let bytes = proc_listpids(UInt32(PROC_UID_ONLY), geteuid(), nil, 0)
        guard bytes > 0, bytes < 131072 * stride else { throw Failure.busy }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / stride + 256)
        let actual = Int(proc_listpids(UInt32(PROC_UID_ONLY), geteuid(), &pids, Int32(pids.count * stride)))
        guard actual > 0, actual % stride == 0, actual < pids.count * stride,
            pids.prefix(actual / stride).contains(getpid()) else {
            throw Failure.busy
        }
        var result: [pid_t] = []
        for pid in pids.prefix(actual / stride) where pid > 0 && pid != getpid() {
            guard let info = try liveInfo(pid), info.pbi_uid == geteuid() else { continue }
            guard let command = try command(of: pid) else { continue }
            if matching(command) { result.append(pid) }
        }
        return result
    }
}
