import AppKit
import SwiftUI

/// Non-activating so glancing at a chat never steals the key app.
final class ObserverPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    convenience init() {
        self.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        identifier = NSUserInterfaceItemIdentifier(NotchLayout.identifier)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        sharingType = .readOnly
    }
}

final class NotchHost: NSHostingView<NotchRootView> {
    var hovering: Bool = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        NotchLayout.contains(point, in: bounds, hovering: hovering) ? super.hitTest(point) : nil
    }
}

private struct Snapshot: Decodable {
    var sessions: [NotchSession]?
}

enum NotchController {
    private static var panel: ObserverPanel?
    private static var host: NotchHost?
    private static let store = NotchStore()
    private static var screenObserver: NSObjectProtocol?

    static func update(_ json: String) {
        let sessions: [NotchSession]
        if let data = json.data(using: .utf8), let parsed = try? JSONDecoder().decode(Snapshot.self, from: data) {
            sessions = Array((parsed.sessions ?? []).prefix(NotchLayout.maxCells))
        } else {
            sessions = []
        }
        store.sessions = sessions.isEmpty
            ? [NotchSession(id: 0, title: "Codegraff", state: .idle, label: "Idle", detail: "")]
            : sessions
        show()
    }

    static func hide() {
        panel?.orderOut(nil)
    }

    static func inspectJSON() -> String {
        let panel = panel
        let payload: [String: Any] = [
            "visible": panel?.isVisible ?? false,
            "key": panel?.isKeyWindow ?? false,
            "main": panel?.isMainWindow ?? false,
            "hidesOnDeactivate": panel?.hidesOnDeactivate ?? true,
            "level": panel?.level.rawValue ?? 0,
            "cells": store.sessions.count,
            "identifier": NotchLayout.identifier,
            "width": panel?.frame.width ?? 0,
            "height": panel?.frame.height ?? 0,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private static func show() {
        if panel == nil {
            let panel = ObserverPanel()
            let host = NotchHost(rootView: root())
            panel.contentView = host
            self.panel = panel
            self.host = host
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main
            ) { _ in NotchController.reposition() }
        }
        host?.rootView = root()
        reposition()
        panel?.orderFrontRegardless()
    }

    private static func root() -> NotchRootView {
        NotchRootView(store: store, onSelect: { id in graff_notch_emit_click(Int32(id)) }, onHover: { hovering in
            host?.hovering = hovering
            reposition()
        })
    }

    private static func reposition() {
        guard let panel else { return }
        let hovering = store.hovering != nil
        host?.hovering = hovering
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen.map {
            NotchLayout.frame(screen: $0.frame, visible: $0.visibleFrame, cells: store.sessions.count, hovering: hovering)
        } ?? .zero
        panel.setFrame(frame, display: true)
        host?.frame = CGRect(origin: .zero, size: frame.size)
    }
}

public typealias NotchClickFn = @convention(c) (Int32) -> Void
private var notchClick: NotchClickFn = { _ in }

@_cdecl("graff_notch_set_click")
public func graffNotchSetClick(_ handler: NotchClickFn?) {
    notchClick = handler ?? { _ in }
}

private func graff_notch_emit_click(_ id: Int32) {
    notchClick(id)
}

@_cdecl("graff_notch_update")
public func graffNotchUpdate(_ json: UnsafePointer<CChar>?) {
    guard Thread.isMainThread, let json else { return }
    NotchController.update(String(cString: json))
}

@_cdecl("graff_notch_hide")
public func graffNotchHide() {
    guard Thread.isMainThread else { return }
    NotchController.hide()
}

@_cdecl("graff_notch_inspect")
public func graffNotchInspect() -> UnsafeMutablePointer<CChar>? {
    guard Thread.isMainThread else { return nil }
    return strdup(NotchController.inspectJSON())
}
