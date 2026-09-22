import Foundation
import Darwin
import DockCore
import AppKit

// A native executable must remain inside the cloned bundle. A shell shortcut
// to the original app would restore the original Dock identity on launch.
do {
    let bundle = Bundle.main
    guard var info = bundle.infoDictionary, let executable = bundle.executableURL else { throw CocoaError(.fileReadCorruptFile) }
    if NativeDock.sourceChanged(info) {
        guard let manager = info[NativeDock.managerKey] as? String, let id = info[NativeDock.profileKey] as? String,
              FileManager.default.isExecutableFile(atPath: manager) else { throw CocoaError(.fileNoSuchFile) }
        let update = Process()
        update.executableURL = URL(fileURLWithPath: manager)
        update.arguments = ["--prepare-native-dock", id, String(getpid())]
        update.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "USER": NSUserName(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": NSTemporaryDirectory()]
        let errors = Pipe(); update.standardError = errors; update.standardOutput = errors
        try update.run()
        let detail = errors.fileHandleForReading.readDataToEndOfFile()
        update.waitUntilExit()
        guard update.terminationStatus == 0 else {
            throw NSError(domain: "ProfileDock", code: 1, userInfo: [NSLocalizedDescriptionKey: String(decoding: detail, as: UTF8.self)])
        }
        guard let refreshed = try PropertyListSerialization.propertyList(from: Data(contentsOf: bundle.bundleURL.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any], !NativeDock.sourceChanged(refreshed) else { throw CocoaError(.fileReadCorruptFile) }
        info = refreshed
    }
    let params = try NativeDock.launchParameters(info: info, arguments: Array(CommandLine.arguments.dropFirst()))
    let vendor = executable.appendingPathExtension("bin")
    guard FileManager.default.isExecutableFile(atPath: vendor.path),
          FileManager.default.fileExists(atPath: params.home) else { throw CocoaError(.fileNoSuchFile) }
    let environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "USER": NSUserName(),
                       "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin", "LANG": "en_US.UTF-8", "TMPDIR": NSTemporaryDirectory(),
                       "CODEX_HOME": params.home, "CODEX_ELECTRON_USER_DATA_PATH": params.data]
    let argv = ([vendor.path] + params.arguments).map { strdup($0) } + [nil]
    let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
    execve(vendor.path, argv, envp)
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
} catch {
    FileHandle.standardError.write(Data("ProfileDock could not launch this Dock app: \(error.localizedDescription)\n".utf8))
    let alert = NSAlert()
    alert.messageText = "This profile's Dock app could not be opened."
    alert.informativeText = "\(error.localizedDescription)\nOpen ProfileDock to retry or disable the experimental native Dock icon."
    alert.runModal()
    exit(1)
}
