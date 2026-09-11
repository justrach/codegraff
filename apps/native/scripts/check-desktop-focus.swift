// macOS acceptance observer for #832. Does not activate apps or inject input.
// Usage: compiled-observer /absolute/test-root command [arguments...]
import AppKit
import CoreGraphics
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else { fputs("Expected test root and command\n", stderr); exit(2) }
let root = URL(fileURLWithPath: args[0]).standardizedFileURL.path + "/"
let allowVisible = ProcessInfo.processInfo.environment["GRAFF_ELECTRON_VISIBLE"] == "1"
let child = Process()
child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
child.arguments = Array(args.dropFirst())
var testPids = Set<pid_t>()
var activations = 0
var visibleSamples = 0
var samples = 0
var otherAppSwitches = 0
var previousFront = NSWorkspace.shared.frontmostApplication?.processIdentifier
func isTestApp(_ app: NSRunningApplication) -> Bool {
    if app.executableURL?.standardizedFileURL.path.hasPrefix(root) == true {
        testPids.insert(app.processIdentifier)
        return true
    }
    return false
}
let observer = NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
) { event in
    if let app = event.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
        if isTestApp(app) { activations += 1 }
        else if app.processIdentifier != previousFront { otherAppSwitches += 1 }
        previousFront = app.processIdentifier
    }
}
do { try child.run() } catch { fputs("Failed to launch test: \(error)\n", stderr); exit(2) }
func sample() {
    samples += 1
    for app in NSWorkspace.shared.runningApplications { _ = isTestApp(app) }
    if let front = NSWorkspace.shared.frontmostApplication, isTestApp(front) { activations += 1 }
    guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        fputs("Could not inspect on-screen windows; focus acceptance is unverified.\n", stderr)
        child.terminate()
        exit(2)
    }
    if windows.contains(where: { row in
        guard let pid = row[kCGWindowOwnerPID as String] as? Int32 else { return false }
        return testPids.contains(pid)
    }) { visibleSamples += 1 }
}
while child.isRunning {
    sample()
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
}
// Include shutdown and delayed activation notifications.
for _ in 0..<25 { sample(); RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02)) }
NSWorkspace.shared.notificationCenter.removeObserver(observer)
let remaining = NSWorkspace.shared.runningApplications.filter { isTestApp($0) }.count
print("Desktop focus check: \(samples) samples, \(testPids.count) test apps, \(activations) test activations, \(visibleSamples) visible-window samples, \(remaining) remaining test apps, \(otherAppSwitches) other-app switches.")
if testPids.isEmpty { fputs("No Electron app observed; focus acceptance is unverified.\n", stderr); exit(2) }
exit(activations == 0 && (allowVisible || visibleSamples == 0) && remaining == 0 ? child.terminationStatus : 1)
