import AppKit
import ServiceManagement
import TerminalMacCore

@MainActor
enum GuestBootstrap {
    static func installAndRelaunchIfNeeded() async throws -> Bool {
        try GuestGuard.requireVirtualMac()
        guard Bundle.main.bundleIdentifier == "dev.terminal-mac.guest" else { return false }
        let source = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let identity = try CodeIdentity()
        try identity.validate(source)
        let applications = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        let destination = applications.appendingPathComponent("TerminalMacGuest.app")
        if source == destination.resolvingSymlinksInPath() { return false }
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let installed = Bundle(url: destination)
        let exists = FileManager.default.fileExists(atPath: destination.path)
        if exists, installed?.bundleIdentifier != "dev.terminal-mac.guest" {
            throw Failure("The guest install location is occupied by a different app: \(destination.path)")
        }
        let keys = ["CFBundleVersion", "CFBundleShortVersionString"]
        let needsUpdate = keys.contains { installed?.object(forInfoDictionaryKey: $0) as? String != Bundle.main.object(forInfoDictionaryKey: $0) as? String }
        if !exists || needsUpdate {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.terminal-mac.guest")
                .filter { $0.bundleURL?.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath() }
            for application in running { _ = application.terminate() }
            for _ in 0..<60 {
                if running.allSatisfy({ $0.isTerminated }) { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            guard running.allSatisfy({ $0.isTerminated }) else { throw Failure("Quit the installed guest helper, then reopen this copy to update it") }
            let staging = applications.appendingPathComponent(".TerminalMacGuest-\(UUID().uuidString).app")
            defer { try? FileManager.default.removeItem(at: staging) }
            try FileManager.default.copyItem(at: source, to: staging)
            try identity.validate(staging)
            let backup = applications.appendingPathComponent(".TerminalMacGuest-backup-\(UUID().uuidString).app")
            if exists { try FileManager.default.moveItem(at: destination, to: backup) }
            do { try FileManager.default.moveItem(at: staging, to: destination) }
            catch {
                if exists { try? FileManager.default.moveItem(at: backup, to: destination) }
                throw error
            }
            if exists { try? FileManager.default.removeItem(at: backup) }
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        _ = try await NSWorkspace.shared.openApplication(at: destination, configuration: configuration)
        return true
    }
    /// The installed helper hands over to a newer copy in the shared tools folder, which installs
    /// itself over this one and relaunches. Rebuilding terminal-mac on the host is enough to update the guest.
    static func updateFromSharedTools(_ tools: URL) {
        guard Bundle.main.bundleIdentifier == "dev.terminal-mac.guest" else { return }
        let shared = tools.appendingPathComponent("TerminalMacGuest.app")
        guard Bundle.main.bundleURL.resolvingSymlinksInPath() != shared.resolvingSymlinksInPath(),
              let available = Bundle(url: shared)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String, let newer = Int(available),
              let running = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""), newer > running else { return }
        do { try CodeIdentity().validate(shared) }
        catch { stderr("Guest helper update refused: \(error.localizedDescription)"); return }
        stderr("Updating the guest helper from build \(running) to \(newer)…")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: shared, configuration: configuration) { _, error in
            if let error { stderr("Guest helper update: \(error.localizedDescription)") }
        }
    }
    static func registerForGuestLogin() {
        guard Bundle.main.bundleIdentifier == "dev.terminal-mac.guest" else { return }
        let preferences = UserDefaults.standard
        guard !preferences.bool(forKey: "requestedGuestLoginItem") else { return }
        do {
            try SMAppService.mainApp.register()
            preferences.set(true, forKey: "requestedGuestLoginItem")
        } catch { stderr("Guest login item: \(error.localizedDescription). You can enable it in the guest's Login Items settings.") }
    }
}
