import AppKit
import SwiftUI

private struct Snapshot: Decodable {
    let rssMiB: Int
    let cpuPercent: Double
    let processes: Int
    let browsers: Int
}

private struct ActivityView: View {
    let snapshot: Snapshot
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Activity", systemImage: "waveform.path.ecg")
                .font(.title2.bold())
            Text("Codegraff and its child processes")
                .foregroundStyle(.secondary)
            if #available(macOS 26, *) {
                GlassEffectContainer(spacing: 16) {
                    HStack(spacing: 16) {
                        metric("Memory", value: "\(snapshot.rssMiB) MiB", icon: "memorychip")
                            .glassEffect(.regular, in: .rect(cornerRadius: 16))
                        metric("CPU", value: String(format: "%.1f%%", snapshot.cpuPercent), icon: "cpu")
                            .glassEffect(.regular, in: .rect(cornerRadius: 16))
                    }
                }
            } else {
                HStack(spacing: 16) {
                    metric("Memory", value: "\(snapshot.rssMiB) MiB", icon: "memorychip")
                    metric("CPU", value: String(format: "%.1f%%", snapshot.cpuPercent), icon: "cpu")
                }
            }
            Form {
                LabeledContent("Live browser views", value: "\(snapshot.browsers)")
                LabeledContent("Processes", value: "\(snapshot.processes)")
                LabeledContent("Coding engine", value: "graff · ACP")
            }
            .formStyle(.grouped)
            .frame(height: 145)
            Text("Hidden pages suspend after a minute. Reopening reloads the page; unsaved forms are discarded.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Snapshot at opening · CPU lifetime average. RSS can count shared pages more than once.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if #available(macOS 26, *) {
                    Button("Done", action: close).buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Done", action: close).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(28)
        .frame(width: 470)
    }

    private func metric(_ title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.title.bold()).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
    }
}

// The sheet owns its hosting view; the parent owns the sheet for its lifetime.
// No timers, subprocesses, or global SwiftUI state are needed for this panel.
@_cdecl("graff_show_activity")
public func graffShowActivity(_ pointer: UnsafeMutableRawPointer?, _ json: UnsafePointer<CChar>?) {
    guard Thread.isMainThread, let pointer, let json,
          let snapshot = try? JSONDecoder().decode(Snapshot.self, from: Data(String(cString: json).utf8)) else { return }
    let parentView = Unmanaged<NSView>.fromOpaque(pointer).takeUnretainedValue()
    guard let parent = parentView.window, parent.attachedSheet == nil else { return }
    let panel = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    panel.title = "Activity"
    panel.isReleasedWhenClosed = false
    panel.contentView = NSHostingView(rootView: ActivityView(snapshot: snapshot) { [weak parent, weak panel] in
        if let panel { parent?.endSheet(panel) }
    })
    parent.beginSheet(panel) { _ in panel.orderOut(nil) }
}
