import AppKit
import Carbon
import Darwin
import DockCore

/// Launch Services can retain PID -1 after the native shim execs the vendor
/// binary. Keep the AppKit application for window activation, but address the
/// verified kernel process for profile identity, reopen and graceful quit.
@MainActor struct RunningProfileApplication {
    let application: NSRunningApplication
    let processIdentifier: pid_t
    private let executable: String

    init?(_ application: NSRunningApplication, processIdentifier: pid_t? = nil) {
        let pid = processIdentifier ?? application.processIdentifier
        guard pid > 0, let executable = Self.executablePath(pid: pid),
              application.executableURL?.resolvingSymlinksInPath().path == executable else { return nil }
        self.application = application
        self.processIdentifier = pid
        self.executable = executable
    }

    var bundleURL: URL? { application.bundleURL }
    var bundleIdentifier: String? { application.bundleIdentifier }
    var launchDate: Date? { application.launchDate }
    var isTerminated: Bool { Self.executablePath(pid: processIdentifier) != executable }
    var isActive: Bool { application.isActive && !isTerminated }

    @discardableResult func unhide() -> Bool { !isTerminated && application.unhide() }
    func activate(options: NSApplication.ActivationOptions) -> Bool {
        !isTerminated && application.activate(options: options)
    }
    func terminate() -> Bool {
        guard !isTerminated else { return true }
        if application.processIdentifier > 0 { return application.terminate() }
        // A normal quit request lets ChatGPT defer closing or show confirmation.
        // Never signal or force-quit a user's process to work around AppKit.
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEQuitApplication),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: processIdentifier),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        do { _ = try event.sendEvent(options: [.noReply], timeout: 1); return true }
        catch { return false }
    }

    static func executablePath(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path
    }

    static func kernelProcesses() -> [String: [pid_t]] {
        let capacity = max(1024, Int(proc_listallpids(nil, 0)) + 128)
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.stride))
        var result: [String: [pid_t]] = [:]
        for pid in pids.prefix(max(0, Int(count))) where pid > 0 {
            if let path = executablePath(pid: pid) { result[path, default: []].append(pid) }
        }
        return result
    }

    static func snapshot(applications: [NSRunningApplication] = NSWorkspace.shared.runningApplications) -> (applications: [RunningProfileApplication], unresolved: Bool) {
        var result: [RunningProfileApplication] = [], unresolved = false
        var kernel: [String: [pid_t]]?
        for app in applications where app.bundleIdentifier == "com.openai.codex" || app.bundleIdentifier?.hasPrefix(NativeDock.prefix) == true {
            if app.isTerminated { continue }
            if app.processIdentifier > 0 {
                if let resolved = Self(app) { result.append(resolved) }
                else { unresolved = true }
            } else if app.bundleIdentifier?.hasPrefix(NativeDock.prefix) == true {
                if kernel == nil { kernel = kernelProcesses() }
                let matches = recover(app, kernel: kernel ?? [:])
                if matches.isEmpty { unresolved = true }
                result.append(contentsOf: matches)
            } else { unresolved = true }
        }
        // Profile ownership, bundle path and --user-data-dir are verified by the
        // model before any recovered process is assigned to a profile.
        var seen: Set<pid_t> = []
        return (result.filter { seen.insert($0.processIdentifier).inserted }, unresolved)
    }

    static func recover(_ application: NSRunningApplication, kernel: [String: [pid_t]]) -> [RunningProfileApplication] {
        guard application.bundleIdentifier?.hasPrefix(NativeDock.prefix) == true,
              let executable = application.executableURL?.resolvingSymlinksInPath().path else { return [] }
        return (kernel[executable] ?? []).compactMap { Self(application, processIdentifier: $0) }
    }
}
