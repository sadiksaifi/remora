import Darwin

/// A best-effort, display-only label for the program that ran this command: the nearest ancestor
/// process that is not a shell, such as "codex", "claude" or "Terminal". Nil when none is found.
enum AgentName {
    private static let shells: Set = ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "login", "env", "sudo", "nohup", "timeout", "xargs"]

    static var current: String? {
        var pid = getppid()
        while pid > 1 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            if let name = commandName(pid), !shells.contains(name) { return name }
            pid = pid_t(info.pbi_ppid)
        }
        return nil
    }

    /// The last path component of argv[0]. The executable's own name can be a version number.
    private static func commandName(_ pid: pid_t) -> String? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return nil }
        // argc, the executable path, NUL padding, then argv[0].
        let arguments = buffer[4..<size].drop { $0 != 0 }.drop { $0 == 0 }
        let name = String(decoding: arguments.prefix { $0 != 0 }, as: UTF8.self)
            .split(separator: "/").last.map { $0.hasPrefix("-") ? String($0.dropFirst()) : String($0) }
        return name?.isEmpty == false ? name : nil
    }
}
