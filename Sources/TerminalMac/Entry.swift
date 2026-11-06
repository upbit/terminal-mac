import AppKit
import TerminalMacCore
import Darwin

@main
struct Entry {
    @MainActor static func main() {
        let command = CommandLine.arguments.dropFirst().first
        let guestMode = command == "guest" || (command == nil && Bundle.main.bundleIdentifier == "dev.terminal-mac.guest")
        if guestMode {
            do { try GuestGuard.requireVirtualMac() }
            catch { stderr("terminal-mac: \(error.localizedDescription)"); exit(1) }
        }
        if command == "__run" { _ = setsid() }
        let needsApplication = command == "__run" || guestMode
        if needsApplication { NSApplication.shared.setActivationPolicy(.accessory) }
        let cli = CLI()
        Task { @MainActor in
            do { try await cli.run(Array(CommandLine.arguments.dropFirst())); exit(0) }
            catch {
                stderr("terminal-mac: \(error.localizedDescription)")
                if guestMode {
                    let alert = NSAlert(); alert.messageText = "terminal-mac guest setup"
                    alert.informativeText = error.localizedDescription; alert.runModal()
                }
                exit(1)
            }
        }
        if needsApplication { NSApplication.shared.run() }
        else { CFRunLoopRun() }
    }
}
