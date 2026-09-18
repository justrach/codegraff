import CoreGraphics
import Foundation

/// Geometry for the right-edge observer. Inverse flares sit in the extra
/// height so the pill reads as welded to the bezel, not a floating card.
enum NotchLayout {
    static let cellWidth: CGFloat = 52
    static let cellHeight: CGFloat = 64
    static let hoverWidth: CGFloat = 220
    static let curl: CGFloat = 12
    static let corner: CGFloat = 24
    static let maxCells = 6
    static let identifier = "graff.observer-notch"

    static func cellCount(_ count: Int) -> Int {
        max(1, min(count, maxCells))
    }

    static func size(cells: Int, hovering: Bool) -> CGSize {
        let n = cellCount(cells)
        let width = cellWidth + (hovering ? hoverWidth : 0)
        let height = CGFloat(n) * cellHeight + curl * 2
        return CGSize(width: width, height: height)
    }

    /// Right edge of `screen`, vertically centred in `visible`.
    static func frame(screen: CGRect, visible: CGRect, cells: Int, hovering: Bool) -> CGRect {
        let size = size(cells: cells, hovering: hovering)
        let x = screen.maxX - size.width
        let minY = visible.minY + curl
        let maxY = visible.maxY - size.height - curl
        let y = min(max(visible.midY - size.height / 2, minY), max(minY, maxY))
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    static func contains(_ point: CGPoint, in bounds: CGRect, hovering: Bool) -> Bool {
        let pill = CGRect(
            x: bounds.maxX - cellWidth,
            y: bounds.minY + curl,
            width: cellWidth,
            height: max(0, bounds.height - curl * 2)
        )
        if pill.contains(point) { return true }
        if hovering {
            let card = CGRect(x: bounds.minX, y: bounds.minY + curl, width: hoverWidth, height: bounds.height - curl * 2)
            return card.contains(point)
        }
        return false
    }
}

@_cdecl("graff_notch_layout_json")
public func graffNotchLayoutJSON(_ cells: Int32, _ hovering: Int32) -> UnsafeMutablePointer<CChar>? {
    let size = NotchLayout.size(cells: Int(cells), hovering: hovering != 0)
    let payload: [String: Any] = [
        "width": size.width, "height": size.height,
        "cellWidth": NotchLayout.cellWidth, "curl": NotchLayout.curl,
        "maxCells": NotchLayout.maxCells, "identifier": NotchLayout.identifier,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
          let text = String(data: data, encoding: .utf8) else { return nil }
    return strdup(text)
}
