import AppKit

private let glassIdentifier = NSUserInterfaceItemIdentifier("graff.pane-glass")

/// Window-backed Liquid Glass (macOS 26 `NSGlassEffectView`, otherwise
/// `NSVisualEffectView`). The web UI punches holes in unselected splits;
/// this view stays behind Chromium and samples the desktop.
@_cdecl("graff_install_pane_glass")
public func graffInstallPaneGlass(_ pointer: UnsafeMutableRawPointer?) -> Int32 {
    guard Thread.isMainThread, let pointer else { return -1 }
    let host = Unmanaged<NSView>.fromOpaque(pointer).takeUnretainedValue()
    guard let content = host.window?.contentView else { return -1 }
    if let existing = content.subviews.first(where: { $0.identifier == glassIdentifier }) {
        existing.removeFromSuperview()
        if let front = content.subviews.first {
            content.addSubview(existing, positioned: .below, relativeTo: front)
        } else {
            content.addSubview(existing)
        }
        if #available(macOS 26, *) { return existing is NSGlassEffectView ? 1 : 0 }
        return 0
    }
    if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency { return -1 }

    let pane: NSView
    let kind: Int32
    if #available(macOS 26, *) {
        let glass = NSGlassEffectView(frame: content.bounds)
        glass.cornerRadius = 0
        glass.style = .regular
        pane = glass
        kind = 1
    } else {
        let effect = NSVisualEffectView(frame: content.bounds)
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        pane = effect
        kind = 0
    }
    pane.identifier = glassIdentifier
    pane.autoresizingMask = [.width, .height]
    if let front = content.subviews.first {
        content.addSubview(pane, positioned: .below, relativeTo: front)
    } else {
        content.addSubview(pane)
    }
    return kind
}
