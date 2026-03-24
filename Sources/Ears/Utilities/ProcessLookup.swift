#if canImport(AppKit)
import AppKit
#endif
import Foundation

enum ProcessLookup {
    /// Find a running application's PID by display name (case-insensitive).
    /// Only matches regular apps (not background agents/helpers).
    static func findPID(appName: String) -> pid_t? {
        #if canImport(AppKit)
        let apps = NSWorkspace.shared.runningApplications
        let match = apps.first { app in
            app.activationPolicy == .regular &&
            app.localizedName?.lowercased() == appName.lowercased()
        }
        return match?.processIdentifier
        #else
        // Fallback for non-macOS: use pgrep
        return pgrepFallback(appName: appName)
        #endif
    }

    /// List all regular running app names (for error messages).
    static func listRunningApps() -> [String] {
        #if canImport(AppKit)
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.localizedName }
            .sorted()
        #else
        return []
        #endif
    }

    private static func pgrepFallback(appName: String) -> pid_t? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-ix", appName]

        let pipe = Pipe()
        process.standardOutput = pipe

        try? process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(output.components(separatedBy: "\n").first ?? "") else {
            return nil
        }
        return pid
    }
}
