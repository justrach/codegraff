// Read-only test observer. No activation, input injection, screenshots or AX permissions.
import AppKit
import CoreGraphics

let allowVisible = ProcessInfo.processInfo.environment["GRAFF_ELECTRON_VISIBLE"] == "1"
var target: pid_t?
var activations: [pid_t] = []
var visibleSamples: [pid_t: Int] = [:]
var finished = false
func sample() {
    if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
       activations.last != pid { activations.append(pid) }
    if let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
        let owners = Set(windows.compactMap { row -> pid_t? in
            guard (row[kCGWindowLayer as String] as? Int) == 0,
                  (row[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return nil }
            return (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
        })
        for pid in owners { visibleSamples[pid, default: 0] += 1 }
    }
}
func finish() {
    guard !finished else { return }
    finished = true; sample()
    let activated = target.map { pid in activations.filter { $0 == pid }.count } ?? 0
    let visible = target.flatMap { visibleSamples[$0] } ?? 0
    let report: [String: Any] = ["foregroundActivations": activated, "visibleWindowSamples": visible, "observed": target != nil]
    let data = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!); fflush(stdout)
    exit(target != nil && activated == 0 && (allowVisible || visible == 0) ? 0 : 1)
}
let token = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { notification in
    if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
        activations.append(app.processIdentifier)
    }
}
let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in sample() }
sample()
print("ready"); fflush(stdout)
DispatchQueue.global().async {
    while let line = readLine() {
        DispatchQueue.main.async {
            if line == "stop" { finish() }
            else if let pid = pid_t(line) { target = pid; sample() }
        }
    }
    DispatchQueue.main.async { finish() }
}
RunLoop.main.run()
