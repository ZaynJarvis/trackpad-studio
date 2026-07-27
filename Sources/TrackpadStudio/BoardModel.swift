import AppKit

/// Drawing tools only. Text is a one-shot action (`t`), not a mode — committing
/// text must leave the active tool untouched.
enum BoardTool: Int, CaseIterable {
    case pen = 1
    case line
    case rectangle
    case ellipse
    case arrow

    var name: String {
        switch self {
        case .pen: return "Pen"
        case .line: return "Line"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .arrow: return "Arrow"
        }
    }

    var statusName: String {
        name.lowercased()
    }
}

struct BoardStrokeSample {
    let point: CGPoint
    let width: CGFloat
}

enum BoardElement {
    case stroke(samples: [BoardStrokeSample], color: NSColor)
    case line(start: CGPoint, end: CGPoint, width: CGFloat, color: NSColor)
    case rectangle(rect: CGRect, width: CGFloat, color: NSColor)
    case ellipse(rect: CGRect, width: CGFloat, color: NSColor)
    case arrow(start: CGPoint, end: CGPoint, width: CGFloat, color: NSColor)
    case text(origin: CGPoint, string: String, fontSize: CGFloat, color: NSColor)
    case image(rect: CGRect, image: NSImage)
}

final class BoardModel {
    static let minimumZoom: CGFloat = 0.2
    static let maximumZoom: CGFloat = 8.0

    private static let panLimit: CGFloat = 1_000_000

    private(set) var elements: [BoardElement] = []
    private(set) var zoom: CGFloat = 1
    private(set) var pan: CGPoint = .zero
    private(set) var hasCreatedContent = false

    func canvasToView(_ point: CGPoint, in viewBounds: CGRect) -> CGPoint {
        let center = CGPoint(x: viewBounds.midX, y: viewBounds.midY)
        return CGPoint(
            x: center.x + (point.x - center.x) * zoom + pan.x,
            y: center.y + (point.y - center.y) * zoom + pan.y
        )
    }

    func viewToCanvas(_ point: CGPoint, in viewBounds: CGRect) -> CGPoint {
        let center = CGPoint(x: viewBounds.midX, y: viewBounds.midY)
        return CGPoint(
            x: center.x + (point.x - center.x - pan.x) / zoom,
            y: center.y + (point.y - center.y - pan.y) / zoom
        )
    }

    func canvasToView(_ rect: CGRect, in viewBounds: CGRect) -> CGRect {
        let a = canvasToView(rect.origin, in: viewBounds)
        let b = canvasToView(
            CGPoint(x: rect.maxX, y: rect.maxY),
            in: viewBounds
        )
        return CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
    }

    /// What each AI redraw replaced, so undoing the redraw restores it.
    private var replacedElementsStack: [[BoardElement]] = []

    func append(_ element: BoardElement) {
        elements.append(element)
        hasCreatedContent = true
    }

    /// AI redraw: swaps the whole board for one image element as a single
    /// operation — one ⌘Z brings the replaced drawing back.
    func replaceAll(with element: BoardElement) {
        replacedElementsStack.append(elements)
        elements = [element]
        hasCreatedContent = true
    }

    @discardableResult
    func undo() -> BoardElement? {
        guard let popped = elements.popLast() else { return nil }
        // An image at the bottom of the stack can only be an AI redraw;
        // undoing it restores everything it replaced.
        if case .image = popped, elements.isEmpty,
           let restored = replacedElementsStack.popLast() {
            elements = restored
        }
        return popped
    }

    func clear() {
        elements.removeAll(keepingCapacity: true)
        replacedElementsStack.removeAll()
    }

    /// Applies a scale step while keeping the canvas point under the view center fixed.
    func zoom(by factor: CGFloat, in viewBounds: CGRect) {
        guard factor.isFinite, factor > 0 else { return }

        let viewCenter = CGPoint(x: viewBounds.midX, y: viewBounds.midY)
        let anchoredCanvasPoint = viewToCanvas(viewCenter, in: viewBounds)
        let requestedZoom = zoom * factor
        zoom = min(Self.maximumZoom, max(Self.minimumZoom, requestedZoom))

        pan = clampedPan(
            CGPoint(
                x: -(anchoredCanvasPoint.x - viewCenter.x) * zoom,
                y: -(anchoredCanvasPoint.y - viewCenter.y) * zoom
            )
        )
    }

    /// Simultaneous zoom + pan: scales by `factor`, then translates so `anchor`
    /// (a canvas point) lands exactly on `viewPoint`. Because the pan is derived
    /// from the post-clamp zoom, a clamped zoom cannot accumulate drift.
    func navigate(
        scale factor: CGFloat,
        anchor: CGPoint,
        to viewPoint: CGPoint,
        in viewBounds: CGRect
    ) {
        guard factor.isFinite, factor > 0,
              anchor.x.isFinite, anchor.y.isFinite,
              viewPoint.x.isFinite, viewPoint.y.isFinite else { return }

        zoom = min(Self.maximumZoom, max(Self.minimumZoom, zoom * factor))

        let center = CGPoint(x: viewBounds.midX, y: viewBounds.midY)
        pan = clampedPan(
            CGPoint(
                x: viewPoint.x - center.x - (anchor.x - center.x) * zoom,
                y: viewPoint.y - center.y - (anchor.y - center.y) * zoom
            )
        )
    }

    func pan(by delta: CGPoint) {
        guard delta.x.isFinite, delta.y.isFinite else { return }
        pan = clampedPan(
            CGPoint(x: pan.x + delta.x, y: pan.y + delta.y)
        )
    }

    func hitTest(_ canvasPoint: CGPoint, tolerance: CGFloat = 6) -> Int? {
        let safeTolerance = max(0, tolerance)

        for index in elements.indices.reversed() {
            if Self.hits(elements[index], point: canvasPoint, tolerance: safeTolerance) {
                return index
            }
        }
        return nil
    }

    private func clampedPan(_ proposed: CGPoint) -> CGPoint {
        CGPoint(
            x: min(Self.panLimit, max(-Self.panLimit, proposed.x)),
            y: min(Self.panLimit, max(-Self.panLimit, proposed.y))
        )
    }

    private static func hits(
        _ element: BoardElement,
        point: CGPoint,
        tolerance: CGFloat
    ) -> Bool {
        switch element {
        case let .stroke(samples, _):
            guard let first = samples.first else { return false }
            if samples.count == 1 {
                return distance(first.point, point)
                    <= tolerance + max(0, first.width) / 2
            }
            return zip(samples, samples.dropFirst()).contains { pair in
                let radius = tolerance
                    + max(0, max(pair.0.width, pair.1.width)) / 2
                return distanceFromSegment(
                    point,
                    start: pair.0.point,
                    end: pair.1.point
                ) <= radius
            }

        case let .line(start, end, width, _),
             let .arrow(start, end, width, _):
            return distanceFromSegment(point, start: start, end: end)
                <= tolerance + width / 2

        case let .rectangle(rect, width, _):
            let expanded = rect.standardized.insetBy(
                dx: -(tolerance + width / 2),
                dy: -(tolerance + width / 2)
            )
            return expanded.contains(point)

        case let .ellipse(rect, width, _):
            let expanded = rect.standardized.insetBy(
                dx: -(tolerance + width / 2),
                dy: -(tolerance + width / 2)
            )
            guard expanded.width > 0, expanded.height > 0 else {
                return distance(expanded.origin, point) <= tolerance + width / 2
            }
            let nx = (point.x - expanded.midX) / (expanded.width / 2)
            let ny = (point.y - expanded.midY) / (expanded.height / 2)
            return nx * nx + ny * ny <= 1

        case let .text(origin, string, fontSize, _):
            let font = NSFont.systemFont(ofSize: fontSize)
            let size = (string as NSString).size(withAttributes: [.font: font])
            return CGRect(origin: origin, size: size)
                .insetBy(dx: -tolerance, dy: -tolerance)
                .contains(point)

        case let .image(rect, _):
            return rect.standardized
                .insetBy(dx: -tolerance, dy: -tolerance)
                .contains(point)
        }
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private static func distanceFromSegment(
        _ point: CGPoint,
        start: CGPoint,
        end: CGPoint
    ) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > .ulpOfOne else { return distance(point, start) }

        let projection = ((point.x - start.x) * dx + (point.y - start.y) * dy)
            / lengthSquared
        let t = min(1, max(0, projection))
        let nearest = CGPoint(x: start.x + t * dx, y: start.y + t * dy)
        return distance(point, nearest)
    }
}
