import SwiftUI

enum NotchSessionState: String, Codable {
    case working, waiting, idle, error
}

struct NotchSession: Codable, Identifiable, Equatable {
    var id: Int
    var title: String
    var state: NotchSessionState
    var label: String
    var detail: String
}

final class NotchStore: ObservableObject {
    @Published var sessions: [NotchSession] = [
        NotchSession(id: 0, title: "Codegraff", state: .idle, label: "Idle", detail: ""),
    ]
    @Published var hovering: Int?
}

/// Emerald is the working ring; coral is errors only. Waiting is a warm sand
/// so it is not an error and not CodeNotch's yellow.
private let accent = Color(red: 5 / 255, green: 150 / 255, blue: 105 / 255)
private let waiting = Color(red: 196 / 255, green: 148 / 255, blue: 58 / 255)
private let fill = Color(red: 0.09, green: 0.09, blue: 0.09)

struct NotchRootView: View {
    @ObservedObject var store: NotchStore
    var onSelect: (Int) -> Void
    var onHover: (Bool) -> Void

    var body: some View {
        HStack(spacing: 0) {
            if let id = store.hovering, let session = store.sessions.first(where: { $0.id == id }) {
                hoverCard(session)
                    .frame(width: NotchLayout.hoverWidth)
            }
            VStack(spacing: 0) {
                ForEach(store.sessions.prefix(NotchLayout.maxCells)) { session in
                    cell(session)
                        .frame(width: NotchLayout.cellWidth, height: NotchLayout.cellHeight)
                        .onHover { inside in
                            store.hovering = inside ? session.id : (store.hovering == session.id ? nil : store.hovering)
                            onHover(store.hovering != nil)
                        }
                        .onTapGesture { onSelect(session.id) }
                        .accessibilityLabel("\(session.title), \(session.label)")
                }
            }
        }
        .padding(.vertical, NotchLayout.curl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .background(NotchShape().fill(fill))
    }

    private func cell(_ session: NotchSession) -> some View {
        VStack(spacing: 4) {
            NotchRing(state: session.state)
                .frame(width: 28, height: 28)
            Text(session.title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(width: 44)
        }
        .frame(maxHeight: .infinity)
    }

    private func hoverCard(_ session: NotchSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
            Text(session.label)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.72))
            if !session.detail.isEmpty {
                Text(session.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(3)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct NotchRing: View {
    let state: NotchSessionState

    var body: some View {
        Group {
            if state == .working || state == .waiting {
                TimelineView(.animation) { timeline in ring(at: timeline.date) }
            } else {
                ring(at: Date())
            }
        }
    }

    private func ring(at date: Date) -> some View {
        let t = date.timeIntervalSinceReferenceDate
        return ZStack {
            Circle().stroke(color.opacity(0.22), lineWidth: 2.5)
            if state == .working {
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 1) * 360))
            } else {
                Circle()
                    .trim(from: 0, to: state == .idle ? 0.08 : 1)
                    .stroke(color.opacity(state == .waiting ? 0.55 + 0.35 * sin(t * 3) : 1), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Image(systemName: glyph)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(state == .working ? 0.9 : 0.75))
        }
    }

    private var color: Color {
        switch state {
        case .working: return accent
        case .waiting: return waiting
        case .error: return Color(red: 0.82, green: 0.28, blue: 0.26)
        case .idle: return Color.white.opacity(0.45)
        }
    }

    private var glyph: String {
        switch state {
        case .working: return "arrow.clockwise"
        case .waiting: return "pause.fill"
        case .error: return "xmark"
        case .idle: return "checkmark"
        }
    }
}

struct NotchShape: Shape {
    func path(in rect: CGRect) -> Path {
        let curl = min(NotchLayout.curl, rect.height / 4, rect.width / 2)
        let corner = min(NotchLayout.corner, (rect.height - 2 * curl) / 2, rect.width / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        if curl > 0 {
            path.addArc(center: CGPoint(x: rect.maxX - curl, y: rect.minY), radius: curl,
                        startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        }
        path.addLine(to: CGPoint(x: rect.minX + corner, y: rect.minY + curl))
        path.addArc(center: CGPoint(x: rect.minX + corner, y: rect.minY + curl + corner), radius: corner,
                    startAngle: .degrees(270), endAngle: .degrees(180), clockwise: true)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - curl - corner))
        path.addArc(center: CGPoint(x: rect.minX + corner, y: rect.maxY - curl - corner), radius: corner,
                    startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
        path.addLine(to: CGPoint(x: rect.maxX - curl, y: rect.maxY - curl))
        if curl > 0 {
            path.addArc(center: CGPoint(x: rect.maxX - curl, y: rect.maxY), radius: curl,
                        startAngle: .degrees(270), endAngle: .degrees(360), clockwise: false)
        }
        path.closeSubpath()
        return path
    }
}
