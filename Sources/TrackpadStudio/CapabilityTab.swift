import AppKit

// MARK: - Design tokens

private enum Ink {
    static let background = NSColor(calibratedRed: 0.043, green: 0.051, blue: 0.070, alpha: 1)
    static let card = NSColor(calibratedRed: 0.086, green: 0.101, blue: 0.132, alpha: 1)
    static let cardActive = NSColor(calibratedRed: 0.075, green: 0.128, blue: 0.135, alpha: 1)
    static let pad = NSColor(calibratedRed: 0.076, green: 0.090, blue: 0.118, alpha: 1)
    static let hairline = NSColor(calibratedWhite: 1, alpha: 0.070)
    static let border = NSColor(calibratedWhite: 1, alpha: 0.115)
    static let track = NSColor(calibratedWhite: 1, alpha: 0.085)
    static let primary = NSColor(calibratedWhite: 0.97, alpha: 1)
    static let secondary = NSColor(calibratedWhite: 0.71, alpha: 1)
    static let tertiary = NSColor(calibratedWhite: 0.46, alpha: 1)
    static let mint = NSColor(calibratedRed: 0.34, green: 0.90, blue: 0.72, alpha: 1)
    static let amber = NSColor(calibratedRed: 1.00, green: 0.72, blue: 0.34, alpha: 1)
    static let rose = NSColor(calibratedRed: 1.00, green: 0.44, blue: 0.47, alpha: 1)
    static let fingers: [NSColor] = [
        NSColor(calibratedRed: 0.31, green: 0.88, blue: 0.78, alpha: 1),
        NSColor(calibratedRed: 0.49, green: 0.68, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 0.78, green: 0.53, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 1.00, green: 0.63, blue: 0.37, alpha: 1),
        NSColor(calibratedRed: 1.00, green: 0.45, blue: 0.68, alpha: 1)
    ]
}

private enum Metric {
    static let columnGap: CGFloat = 22
    static let cardRadius: CGFloat = 12
    static let cardPadding: CGFloat = 14
    static let cardGap: CGFloat = 9
    static let gutter: CGFloat = 18
    static let stripHeight: CGFloat = 76
    /// MultitouchSupport reports contact axes in millimetre-ish units while
    /// `NSTouch.deviceSize` is in points, so the two cannot be divided.
    /// ponytail: assume a 130 mm wide pad for ellipse scaling; tune here if
    /// contacts read too large or small on other hardware.
    static let assumedPadWidthMM: CGFloat = 130
}

// MARK: - Text helpers

private func textAttributes(font: NSFont,
                            color: NSColor,
                            alignment: NSTextAlignment = .left,
                            tracking: CGFloat = 0,
                            wraps: Bool = false) -> [NSAttributedString.Key: Any] {
    let style = NSMutableParagraphStyle()
    style.alignment = alignment
    style.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
    if wraps { style.lineSpacing = 2 }
    var attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: style
    ]
    if tracking != 0 { attributes[.kern] = tracking }
    return attributes
}

/// Line-fragment options shared by `wrappedHeight` and wrapped drawing — the
/// two must use the same layout path or measured heights clip real text.
private let wrappedTextOptions: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

private func drawText(_ text: String,
                      in rect: CGRect,
                      font: NSFont,
                      color: NSColor,
                      alignment: NSTextAlignment = .left,
                      tracking: CGFloat = 0,
                      wraps: Bool = false) {
    let attributes = textAttributes(font: font,
                                    color: color,
                                    alignment: alignment,
                                    tracking: tracking,
                                    wraps: wraps)
    if wraps {
        (text as NSString).draw(with: rect, options: wrappedTextOptions, attributes: attributes)
    } else {
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }
}

private func wrappedHeight(_ text: String,
                           font: NSFont,
                           width: CGFloat,
                           tracking: CGFloat = 0) -> CGFloat {
    let attributes = textAttributes(font: font, color: .white, tracking: tracking, wraps: true)
    let box = (text as NSString).boundingRect(
        with: CGSize(width: max(1, width), height: 600),
        options: wrappedTextOptions,
        attributes: attributes)
    return ceil(box.height) + 1
}

private func measuredWidth(_ text: String, font: NSFont, tracking: CGFloat = 0) -> CGFloat {
    let attributes = textAttributes(font: font, color: .white, tracking: tracking)
    return ceil((text as NSString).size(withAttributes: attributes).width)
}

private func fillRounded(_ rect: CGRect, radius: CGFloat, color: NSColor) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    color.setFill()
    path.fill()
}

private func strokeRounded(_ rect: CGRect, radius: CGFloat, color: NSColor, width: CGFloat = 1) {
    let path = NSBezierPath(roundedRect: rect.insetBy(dx: width / 2, dy: width / 2),
                            xRadius: radius, yRadius: radius)
    color.setStroke()
    path.lineWidth = width
    path.stroke()
}

private func drawHairline(from start: CGPoint, to end: CGPoint, color: NSColor = Ink.hairline) {
    let line = NSBezierPath()
    line.move(to: start)
    line.line(to: end)
    color.setStroke()
    line.lineWidth = 1
    line.stroke()
}

private func drawBar(in rect: CGRect, fraction: Double, color: NSColor, track: NSColor = Ink.track) {
    fillRounded(rect, radius: rect.height / 2, color: track)
    let clamped = min(1, max(0, fraction))
    guard clamped > 0.001 else { return }
    let width = max(rect.height, rect.width * CGFloat(clamped))
    fillRounded(CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height),
                radius: rect.height / 2, color: color)
}

// MARK: - Value smoothing

/// Exponential glide so readouts settle instead of snapping between frames.
private struct Eased {
    private(set) var value: Double
    var target: Double

    init(_ initial: Double = 0) {
        value = initial
        target = initial
    }

    var isSettled: Bool { value == target }

    mutating func step(_ rate: Double = 0.24) {
        let delta = target - value
        if abs(delta) < 0.0008 {
            value = target
        } else {
            value += delta * rate
        }
    }

    mutating func reset(to newValue: Double) {
        value = newValue
        target = newValue
    }
}

// MARK: - Sidebar plumbing

/// Document view for the tutorial column. Flipped so cards stack top-down and
/// the scroll view opens at the top.
private final class SidebarView: NSView {
    var render: ((CGRect) -> Void)?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        allowedTouchTypes = [.indirect]
        wantsRestingTouches = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        render?(bounds)
    }
}

/// Gestures land on the view under the pointer, and the pointer follows the
/// user's finger — so the tutorial column has to hand every signal it receives
/// back to the tab instead of swallowing it.
private final class GestureScrollView: NSScrollView {
    var onEvent: ((InputEvent) -> Void)?
    var onTouches: ((NSEvent) -> Void)?

    init() {
        super.init(frame: .zero)
        allowedTouchTypes = [.indirect]
        wantsRestingTouches = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func scrollWheel(with event: NSEvent) {
        onEvent?(.scroll(dx: Double(event.scrollingDeltaX),
                         dy: Double(event.scrollingDeltaY),
                         phase: event.phase,
                         momentum: event.momentumPhase))
        super.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        onEvent?(.magnify(delta: Double(event.magnification)))
    }

    override func rotate(with event: NSEvent) {
        onEvent?(.rotate(degrees: Double(event.rotation)))
    }

    override func pressureChange(with event: NSEvent) {
        onEvent?(.pressure(pressure: Double(event.pressure), stage: event.stage))
    }

    override func touchesBegan(with event: NSEvent) { onTouches?(event) }
    override func touchesMoved(with event: NSEvent) { onTouches?(event) }
    override func touchesEnded(with event: NSEvent) { onTouches?(event) }
    override func touchesCancelled(with event: NSEvent) { onTouches?(event) }
}

// MARK: - Capability tab

final class CapabilityTabView: NSView {

    private enum Status {
        case done
        case pending
        case blocked
    }

    private struct Lesson {
        let title: String
        let instruction: String
        let status: Status
        let detail: String
        let blockedHint: String
    }

    /// One live finger on the pad. `alpha` glides to 0 after a lift so contacts
    /// fade out instead of popping.
    private struct Contact {
        let slot: Int
        var pos: CGPoint
        var size: Double
        var major: Double
        var minor: Double
        var angle: Double
        var resting: Bool
        var alive: Bool
        var alpha: CGFloat
    }

    private struct ContactInput {
        let key: Int
        let pos: CGPoint
        let size: Double
        let major: Double
        let minor: Double
        let angle: Double
        let resting: Bool
    }

    private struct Columns {
        let left: CGRect
        let right: CGRect
    }

    // MARK: Views

    private let captureView = TouchCaptureView()
    private let sidebar = SidebarView()
    private let sidebarScroll = GestureScrollView()
    private let gramsSlider: NSSlider
    private let tareButton: NSButton

    // MARK: Live state

    private var contacts: [Int: Contact] = [:]
    private var restingCount = 0
    private var lastDeviceSize = CGSize(width: 160, height: 100)

    private var pressureLevel = Eased()
    private var pressureStage = 0
    private var lastPressureTime: TimeInterval = 0
    private var isClicking = false
    private var pinch = Eased(1)
    private var rotation = Eased()
    private var scrollX = Eased()
    private var scrollY = Eased()
    private var lastScrollTime: TimeInterval = 0
    private var grams = Eased()
    private var progress = Eased()

    private var tareBaseline = 0.0

    // MARK: Session discoveries

    private var maxSimultaneous = 0
    private var cornersVisited: Set<Int> = []
    private var peakContactSize = 0.0
    private var peakPressure = 0.0
    private var peakStage = 0
    private var sawPinch = false
    private var sawRotate = false
    private var sawScroll = false
    private var sawResting = false

    // MARK: Plumbing

    private var redrawTimer: Timer?
    private var keyMonitor: Any?
    private var previousFrameHandler: (([MTFingerSample]) -> Void)?
    private var readerWasAvailable: Bool

    // MARK: Lifecycle

    init() {
        gramsSlider = NSSlider(value: 50, minValue: 5, maxValue: 120, target: nil, action: nil)
        tareButton = NSButton(title: "Tare", target: nil, action: nil)
        readerWasAvailable = MultitouchReader.shared.isAvailable
        super.init(frame: .zero)

        wantsLayer = true
        layer?.masksToBounds = true
        allowedTouchTypes = [.indirect]
        wantsRestingTouches = true

        captureView.autoresizingMask = [.width, .height]
        captureView.onEvent = { [weak self] event in self?.receive(event) }
        addSubview(captureView)

        sidebar.render = { [weak self] bounds in
            self?.renderSidebar(width: bounds.width, drawing: true)
        }

        sidebarScroll.drawsBackground = false
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.autohidesScrollers = true
        sidebarScroll.scrollerStyle = .overlay
        sidebarScroll.verticalScroller?.knobStyle = .light
        sidebarScroll.horizontalScrollElasticity = .none
        sidebarScroll.contentView.drawsBackground = false
        sidebarScroll.documentView = sidebar
        sidebarScroll.onEvent = { [weak self] event in self?.receive(event) }
        sidebarScroll.onTouches = { [weak self] event in self?.ingest(event) }
        addSubview(sidebarScroll)

        gramsSlider.isContinuous = true
        gramsSlider.controlSize = .small
        gramsSlider.trackFillColor = Ink.mint
        gramsSlider.focusRingType = .none
        gramsSlider.refusesFirstResponder = true
        gramsSlider.target = self
        gramsSlider.action = #selector(gramsPerUnitChanged(_:))
        gramsSlider.setAccessibilityLabel("Grams per contact-size unit")
        sidebar.addSubview(gramsSlider)

        tareButton.bezelStyle = .rounded
        tareButton.controlSize = .small
        tareButton.font = .systemFont(ofSize: 11, weight: .medium)
        tareButton.focusRingType = .none
        tareButton.refusesFirstResponder = true
        tareButton.target = self
        tareButton.action = #selector(tareWeight(_:))
        tareButton.setAccessibilityLabel("Tare weight estimate")
        sidebar.addSubview(tareButton)

        installFrameHandler()
        installKeyMonitor()
        installRedrawTimer()
        syncControlAvailability()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        redrawTimer?.invalidate()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        MultitouchReader.shared.onFrame = previousFrameHandler
    }

    override var isFlipped: Bool { false }

    private func installFrameHandler() {
        let prior = MultitouchReader.shared.onFrame
        previousFrameHandler = prior
        MultitouchReader.shared.onFrame = { [weak self] fingers in
            prior?(fingers)
            self?.receive(fingers)
        }
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            guard !self.isHiddenOrHasHiddenAncestor else { return event }
            guard self.isResetKey(event.charactersIgnoringModifiers ?? "",
                                  modifiers: event.modifierFlags) else { return event }
            self.resetGestureReadouts()
            return nil
        }
    }

    private func installRedrawTimer() {
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        redrawTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        captureView.frame = bounds

        let columns = makeColumns()
        sidebarScroll.frame = columns.right

        let width = max(120, sidebarScroll.contentSize.width)
        let contentHeight = renderSidebar(width: width, drawing: false)
        sidebar.frame = CGRect(x: 0, y: 0,
                               width: width,
                               height: max(contentHeight, sidebarScroll.contentSize.height))
        sidebar.needsDisplay = true
        syncControlAvailability()
    }

    private func makeColumns() -> Columns {
        let content = bounds.insetBy(dx: Metric.gutter, dy: 16)
        guard content.width > 260 else { return Columns(left: content, right: .zero) }
        let rightWidth = min(430, max(278, content.width * 0.34))
        let leftWidth = max(0, content.width - rightWidth - Metric.columnGap)
        let left = CGRect(x: content.minX, y: content.minY,
                          width: leftWidth, height: content.height)
        let right = CGRect(x: content.maxX - rightWidth, y: content.minY,
                           width: rightWidth, height: content.height)
        return Columns(left: left, right: right)
    }

    // MARK: Drawing (left column lives here; the sidebar draws itself)

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        Ink.background.setFill()
        bounds.fill()

        let columns = makeColumns()
        guard columns.left.width > 80 else { return }

        drawHairline(from: CGPoint(x: columns.right.minX - Metric.columnGap / 2,
                                   y: columns.left.minY),
                     to: CGPoint(x: columns.right.minX - Metric.columnGap / 2,
                                 y: columns.left.maxY))

        drawSurfaceHeader(in: columns.left)

        let strip = CGRect(x: columns.left.minX, y: columns.left.minY,
                           width: columns.left.width, height: Metric.stripHeight)
        drawInstrumentStrip(in: strip)

        let padArea = CGRect(x: columns.left.minX,
                             y: strip.maxY + 16,
                             width: columns.left.width,
                             height: max(60, columns.left.maxY - 62 - strip.maxY - 16))
        drawPad(in: padArea)
    }

    private func drawSurfaceHeader(in column: CGRect) {
        let available = MultitouchReader.shared.isAvailable
        let badge = available ? "PER-FINGER DETAIL" : "PUBLIC NSTOUCH ONLY"
        let color = available ? Ink.mint : Ink.amber
        let font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        let width = min(column.width * 0.5, measuredWidth(badge, font: font, tracking: 0.9) + 20)
        let titleWidth = max(60, column.width - width - 12)

        drawText("TRACKPAD TUTORIAL",
                 in: CGRect(x: column.minX, y: column.maxY - 18, width: titleWidth, height: 14),
                 font: .systemFont(ofSize: 9.5, weight: .semibold),
                 color: Ink.mint, tracking: 1.4)
        drawText("Live surface",
                 in: CGRect(x: column.minX, y: column.maxY - 48, width: titleWidth, height: 26),
                 font: .systemFont(ofSize: 21, weight: .semibold),
                 color: Ink.primary)

        let pill = CGRect(x: column.maxX - width, y: column.maxY - 40, width: width, height: 20)
        fillRounded(pill, radius: 10, color: color.withAlphaComponent(0.13))
        drawText(badge,
                 in: CGRect(x: pill.minX, y: pill.minY + 4, width: pill.width, height: 14),
                 font: font, color: color, alignment: .center, tracking: 0.9)
    }

    // MARK: Pad

    private func drawPad(in area: CGRect) {
        let padRect = TrackpadGeometry.padRect(in: area, deviceSize: lastDeviceSize, fraction: 0.98)
        let padPath = NSBezierPath(roundedRect: padRect, xRadius: 18, yRadius: 18)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.5)
        shadow.shadowBlurRadius = 26
        shadow.shadowOffset = CGSize(width: 0, height: -8)
        shadow.set()
        Ink.pad.setFill()
        padPath.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        padPath.addClip()
        drawPadGrid(in: padRect)
        drawContacts(in: padRect)
        NSGraphicsContext.restoreGraphicsState()

        Ink.border.setStroke()
        padPath.lineWidth = 1
        padPath.stroke()

        if contacts.isEmpty {
            drawText("Rest a finger on the trackpad",
                     in: CGRect(x: padRect.minX, y: padRect.midY - 2,
                                width: padRect.width, height: 22),
                     font: .systemFont(ofSize: 14, weight: .medium),
                     color: Ink.secondary, alignment: .center)
            drawText("Every contact shows up here, live",
                     in: CGRect(x: padRect.minX, y: padRect.midY - 24,
                                width: padRect.width, height: 18),
                     font: .systemFont(ofSize: 11),
                     color: Ink.tertiary, alignment: .center)
        }
    }

    private func drawPadGrid(in rect: CGRect) {
        for index in 1..<4 {
            let x = rect.minX + rect.width * CGFloat(index) / 4
            drawHairline(from: CGPoint(x: x, y: rect.minY), to: CGPoint(x: x, y: rect.maxY),
                         color: Ink.hairline.withAlphaComponent(0.05))
        }
        for index in 1..<3 {
            let y = rect.minY + rect.height * CGFloat(index) / 3
            drawHairline(from: CGPoint(x: rect.minX, y: y), to: CGPoint(x: rect.maxX, y: y),
                         color: Ink.hairline.withAlphaComponent(0.05))
        }

        // Corner targets for the "absolute position" lesson.
        let inset: CGFloat = 0.18
        let radius: CGFloat = 5
        for corner in 0..<4 {
            let nx: CGFloat = corner % 2 == 0 ? inset / 2 : 1 - inset / 2
            let ny: CGFloat = corner < 2 ? inset / 2 : 1 - inset / 2
            let point = TrackpadGeometry.map(CGPoint(x: nx, y: ny), into: rect)
            let dot = NSBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius,
                                                  width: radius * 2, height: radius * 2))
            let hit = cornersVisited.contains(corner)
            (hit ? Ink.mint.withAlphaComponent(0.55) : Ink.tertiary.withAlphaComponent(0.30)).setStroke()
            dot.lineWidth = 1
            dot.stroke()
        }
    }

    private func drawContacts(in padRect: CGRect) {
        let ordered = contacts.values.sorted { $0.slot < $1.slot }
        let scale = padRect.width / Metric.assumedPadWidthMM
        var placedLabels: [CGRect] = []

        for contact in ordered {
            let normalized = clamp01(contact.pos)
            let center = TrackpadGeometry.map(normalized, into: padRect)
            let color = Ink.fingers[contact.slot % Ink.fingers.count]

            var width = CGFloat(contact.major) * scale
            var height = CGFloat(contact.minor) * scale
            if width < 10 || height < 8 {
                // Axes not reported (public fallback, or a device that omits them).
                let diameter = 20 + min(30, CGFloat(contact.size) * 20)
                width = diameter
                height = diameter * (contact.resting ? 0.72 : 0.82)
            }
            width = min(padRect.width * 0.30, max(14, width))
            height = min(padRect.height * 0.34, max(12, height))

            let intensity = CGFloat(min(1, max(0.12, contact.size / 1.4)))
            let fade = contact.alpha

            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: center.x, yBy: center.y)
            transform.rotate(byRadians: CGFloat(contact.angle))
            transform.concat()

            let ellipseRect = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
            let ellipse = NSBezierPath(ovalIn: ellipseRect)
            color.withAlphaComponent(0.10 + 0.28 * intensity * fade).setFill()
            ellipse.fill()
            color.withAlphaComponent((contact.resting ? 0.45 : 0.85) * fade).setStroke()
            ellipse.lineWidth = 1
            ellipse.stroke()

            if contact.resting {
                let inner = NSBezierPath(ovalIn: ellipseRect.insetBy(dx: width * 0.22,
                                                                     dy: height * 0.22))
                color.withAlphaComponent(0.35 * fade).setStroke()
                inner.lineWidth = 1
                inner.stroke()
            } else {
                let core = NSBezierPath(ovalIn: CGRect(x: -1.6, y: -1.6, width: 3.2, height: 3.2))
                color.withAlphaComponent(0.9 * fade).setFill()
                core.fill()
            }
            NSGraphicsContext.restoreGraphicsState()

            let label = String(format: "%d · %.2f, %.2f", contact.slot + 1, normalized.x, normalized.y)
            let rect = labelRect(for: label, near: center,
                                 clearance: max(width, height) / 2 + 7,
                                 in: padRect, avoiding: placedLabels)
            placedLabels.append(rect)
            drawContactLabel(label, in: rect, color: color, fade: fade)
        }
    }

    private func labelRect(for text: String,
                           near point: CGPoint,
                           clearance: CGFloat,
                           in padRect: CGRect,
                           avoiding placed: [CGRect]) -> CGRect {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let size = CGSize(width: measuredWidth(text, font: font) + 12, height: 17)
        let candidates: [CGPoint] = [
            CGPoint(x: point.x - size.width / 2, y: point.y + clearance),
            CGPoint(x: point.x - size.width / 2, y: point.y - clearance - size.height),
            CGPoint(x: point.x + clearance, y: point.y - size.height / 2),
            CGPoint(x: point.x - clearance - size.width, y: point.y - size.height / 2)
        ]

        var fallback: CGRect?
        for origin in candidates {
            let rect = CGRect(origin: origin, size: size)
            let fitted = CGRect(
                x: min(padRect.maxX - size.width - 5, max(padRect.minX + 5, rect.minX)),
                y: min(padRect.maxY - size.height - 5, max(padRect.minY + 5, rect.minY)),
                width: size.width, height: size.height)
            if fallback == nil { fallback = fitted }
            if !placed.contains(where: { $0.intersects(fitted.insetBy(dx: -2, dy: -2)) }) {
                return fitted
            }
        }
        return fallback ?? CGRect(origin: point, size: size)
    }

    private func drawContactLabel(_ text: String, in rect: CGRect, color: NSColor, fade: CGFloat) {
        fillRounded(rect, radius: 5, color: Ink.background.withAlphaComponent(0.85 * fade))
        strokeRounded(rect, radius: 5, color: color.withAlphaComponent(0.40 * fade), width: 1)
        drawText(text,
                 in: CGRect(x: rect.minX + 6, y: rect.minY + 2, width: rect.width - 12, height: 13),
                 font: .monospacedDigitSystemFont(ofSize: 9, weight: .medium),
                 color: Ink.primary.withAlphaComponent(fade),
                 alignment: .center)
    }

    // MARK: Instrument strip

    private func drawInstrumentStrip(in strip: CGRect) {
        let count = 5
        let tileWidth = strip.width / CGFloat(count)
        for index in 0..<count {
            let tile = CGRect(x: strip.minX + CGFloat(index) * tileWidth, y: strip.minY,
                              width: tileWidth, height: strip.height)
            if index > 0 {
                drawHairline(from: CGPoint(x: tile.minX, y: tile.minY + 10),
                             to: CGPoint(x: tile.minX, y: tile.maxY - 6))
            }
            drawTile(index: index, in: tile.insetBy(dx: min(14, tileWidth * 0.11), dy: 0))
        }
        drawHairline(from: CGPoint(x: strip.minX, y: strip.maxY),
                     to: CGPoint(x: strip.maxX, y: strip.maxY))
    }

    private func drawTile(index: Int, in tile: CGRect) {
        let labelRect = CGRect(x: tile.minX, y: tile.maxY - 16, width: tile.width, height: 13)
        let valueRect = CGRect(x: tile.minX, y: tile.maxY - 44, width: tile.width, height: 26)
        let footRect = CGRect(x: tile.minX, y: tile.minY + 8, width: tile.width, height: 14)
        let labelFont = NSFont.systemFont(ofSize: 9, weight: .semibold)
        // Shrink the big numbers rather than truncating them in a narrow panel.
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: tile.width < 76 ? 16 : 19,
                                                         weight: .medium)
        let footFont = NSFont.systemFont(ofSize: 9.5, weight: .regular)

        switch index {
        case 0:
            drawText("TOUCHES", in: labelRect, font: labelFont, color: Ink.tertiary, tracking: 1)
            drawText("\(liveContactCount)", in: valueRect, font: valueFont, color: Ink.primary)
            drawText("\(restingCount) resting", in: footRect, font: footFont,
                     color: restingCount > 0 ? Ink.mint : Ink.tertiary)
        case 1:
            drawText("FORCE", in: labelRect, font: labelFont, color: Ink.tertiary, tracking: 1)
            drawText(String(format: "%.2f", pressureLevel.value),
                     in: valueRect, font: valueFont,
                     color: pressureStage >= 2 ? Ink.amber : Ink.primary)
            drawBar(in: CGRect(x: tile.minX, y: tile.minY + 20, width: tile.width, height: 4),
                    fraction: pressureLevel.value,
                    color: pressureStage >= 2 ? Ink.amber : Ink.mint)
            drawText(pressureStage >= 2 ? "stage 2 deep" : "stage \(pressureStage)",
                     in: CGRect(x: tile.minX, y: tile.minY + 3, width: tile.width, height: 13),
                     font: footFont, color: pressureStage >= 2 ? Ink.amber : Ink.tertiary)
        case 2:
            drawText("PINCH", in: labelRect, font: labelFont, color: Ink.tertiary, tracking: 1)
            drawText(String(format: "%.3f×", pinch.value), in: valueRect, font: valueFont,
                     color: Ink.primary)
            drawText("scale", in: footRect, font: footFont, color: Ink.tertiary)
        case 3:
            drawText("ROTATE", in: labelRect, font: labelFont, color: Ink.tertiary, tracking: 1)
            drawText(String(format: "%+.1f°", rotation.value), in: valueRect, font: valueFont,
                     color: Ink.primary)
            drawText("degrees", in: footRect, font: footFont, color: Ink.tertiary)
        default:
            drawText("SCROLL", in: labelRect, font: labelFont, color: Ink.tertiary, tracking: 1)
            let mono = NSFont.monospacedDigitSystemFont(ofSize: tile.width < 76 ? 11.5 : 13,
                                                        weight: .medium)
            drawText(String(format: "dx %+.1f", scrollX.value),
                     in: CGRect(x: tile.minX, y: tile.maxY - 38, width: tile.width, height: 18),
                     font: mono, color: Ink.primary)
            drawText(String(format: "dy %+.1f", scrollY.value),
                     in: CGRect(x: tile.minX, y: tile.maxY - 55, width: tile.width, height: 18),
                     font: mono, color: Ink.primary)
            drawText("delta", in: footRect, font: footFont, color: Ink.tertiary)
        }
    }

    // MARK: Sidebar — the guided tutorial

    private func lessons() -> [Lesson] {
        let mtAvailable = MultitouchReader.shared.isAvailable
        let ellipseStatus: Status = mtAvailable ? (peakContactSize >= 0.45 ? .done : .pending) : .blocked

        return [
            Lesson(title: "Multi-touch tracking",
                   instruction: "Rest 1–5 fingers anywhere on the pad",
                   status: maxSimultaneous >= 1 ? .done : .pending,
                   detail: maxSimultaneous > 0 ? "max \(maxSimultaneous) at once" : "",
                   blockedHint: ""),
            Lesson(title: "Absolute position",
                   instruction: "Slide one finger to a corner; the dot mirrors it",
                   status: cornersVisited.isEmpty ? .pending : .done,
                   detail: "\(cornersVisited.count) of 4 corners",
                   blockedHint: ""),
            Lesson(title: "Per-finger size + ellipse",
                   instruction: "Press flat with your thumb; watch the ellipse grow",
                   status: ellipseStatus,
                   detail: peakContactSize > 0 ? String(format: "peak %.2f", peakContactSize) : "",
                   blockedHint: "Grant Input Monitoring, relaunch"),
            Lesson(title: "Force Touch pressure",
                   instruction: "Click and keep pressing — feel the second click",
                   status: peakPressure > 0 ? .done : .pending,
                   detail: peakPressure > 0 ? String(format: "peak %.2f · stage %d",
                                                     peakPressure, peakStage) : "",
                   blockedHint: ""),
            Lesson(title: "Pinch",
                   instruction: "Two fingers, spread apart / pinch together",
                   status: sawPinch ? .done : .pending,
                   detail: sawPinch ? String(format: "%.3f×", pinch.target) : "",
                   blockedHint: ""),
            Lesson(title: "Rotate",
                   instruction: "Two fingers, twist like turning a knob",
                   status: sawRotate ? .done : .pending,
                   detail: sawRotate ? String(format: "%+.1f°", rotation.target) : "",
                   blockedHint: ""),
            Lesson(title: "Scroll",
                   instruction: "Two fingers, slide together in any direction",
                   status: sawScroll ? .done : .pending,
                   detail: sawScroll ? "registered" : "",
                   blockedHint: ""),
            Lesson(title: "Resting touch",
                   instruction: "Rest your palm/thumb at the bottom edge without moving",
                   status: sawResting ? .done : .pending,
                   detail: restingCount > 0 ? "\(restingCount) resting now" : "",
                   blockedHint: "")
        ]
    }

    /// Single source of truth for the tutorial column: measures when
    /// `drawing` is false (and positions the weight controls), paints when true.
    @discardableResult
    private func renderSidebar(width: CGFloat, drawing: Bool) -> CGFloat {
        let cardWidth = max(160, width - 12)
        let cardX: CGFloat = 0
        var y: CGFloat = 2

        let all = lessons()
        let doneCount = all.filter { $0.status == .done }.count
        let activeIndex = all.firstIndex { $0.status == .pending }

        if drawing {
            drawText("GUIDED TOUR",
                     in: CGRect(x: cardX, y: y, width: cardWidth, height: 14),
                     font: .systemFont(ofSize: 9.5, weight: .semibold),
                     color: Ink.mint, tracking: 1.4)
            drawText("Capabilities",
                     in: CGRect(x: cardX, y: y + 18, width: cardWidth, height: 22),
                     font: .systemFont(ofSize: 17, weight: .semibold),
                     color: Ink.primary)
            drawText("\(doneCount) of \(all.count) discovered",
                     in: CGRect(x: cardX, y: y + 44, width: cardWidth, height: 15),
                     font: .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular),
                     color: Ink.secondary)
            drawBar(in: CGRect(x: cardX, y: y + 63, width: cardWidth, height: 4),
                    fraction: progress.value, color: Ink.mint)
        }
        y += 79

        // Weight is the app's headline capability — keep it above the fold.
        let weightHeight = weightCardHeight(cardWidth: cardWidth)
        let weightRect = CGRect(x: cardX, y: y, width: cardWidth, height: weightHeight)
        if drawing {
            drawWeightCard(in: weightRect)
        } else {
            positionWeightControls(in: weightRect)
        }
        y += weightHeight + Metric.cardGap + 6

        for (index, lesson) in all.enumerated() {
            let height = lessonCardHeight(lesson, cardWidth: cardWidth)
            if drawing {
                drawLessonCard(lesson,
                               in: CGRect(x: cardX, y: y, width: cardWidth, height: height),
                               isActive: index == activeIndex)
            }
            y += height + Metric.cardGap
        }
        y += 4

        if drawing {
            drawText("Press R to reset pinch · rotate · scroll",
                     in: CGRect(x: cardX + 2, y: y, width: cardWidth, height: 15),
                     font: .systemFont(ofSize: 10), color: Ink.tertiary)
        }
        y += 22

        return y
    }

    /// Must mirror `drawLessonCard`'s geometry exactly, or cards clip.
    private func lessonInstructionWidth(cardWidth: CGFloat) -> CGFloat {
        max(40, cardWidth - Metric.cardPadding * 2 - 24 - 26)
    }

    private func lessonCardHeight(_ lesson: Lesson, cardWidth: CGFloat) -> CGFloat {
        var height = Metric.cardPadding * 2 + 19
        height += wrappedHeight(lesson.instruction,
                                font: .systemFont(ofSize: 11.5),
                                width: lessonInstructionWidth(cardWidth: cardWidth))
        if lesson.status == .blocked {
            height += 16
        }
        return height
    }

    private func drawLessonCard(_ lesson: Lesson, in rect: CGRect, isActive: Bool) {
        fillRounded(rect, radius: Metric.cardRadius,
                    color: isActive ? Ink.cardActive : Ink.card)
        strokeRounded(rect, radius: Metric.cardRadius,
                      color: isActive ? Ink.mint.withAlphaComponent(0.55) : Ink.border,
                      width: isActive ? 1.2 : 1)

        let left = rect.minX + Metric.cardPadding
        let textLeft = left + 24
        let right = rect.maxX - Metric.cardPadding
        var y = rect.minY + Metric.cardPadding

        let glyph: String
        let glyphColor: NSColor
        switch lesson.status {
        case .done:
            glyph = "✓"
            glyphColor = Ink.mint
        case .pending:
            glyph = "—"
            glyphColor = isActive ? Ink.mint.withAlphaComponent(0.8) : Ink.tertiary
        case .blocked:
            glyph = "✗"
            glyphColor = Ink.rose
        }
        drawText(glyph,
                 in: CGRect(x: left, y: y + 1, width: 18, height: 16),
                 font: .systemFont(ofSize: 12, weight: .bold),
                 color: glyphColor, alignment: .left)

        let titleFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        var titleRight = right
        if isActive {
            let font = NSFont.systemFont(ofSize: 8.5, weight: .semibold)
            // Shrink the badge before letting it truncate the capability name.
            let room = right - textLeft - measuredWidth(lesson.title, font: titleFont) - 10
            let badge = room >= measuredWidth("TRY THIS NEXT", font: font, tracking: 0.9) + 14
                ? "TRY THIS NEXT" : "NEXT"
            let width = measuredWidth(badge, font: font, tracking: 0.9) + 14
            let pill = CGRect(x: right - width, y: y - 1, width: width, height: 17)
            fillRounded(pill, radius: 8, color: Ink.mint.withAlphaComponent(0.16))
            drawText(badge,
                     in: CGRect(x: pill.minX, y: pill.minY + 3.5, width: pill.width, height: 12),
                     font: font, color: Ink.mint, alignment: .center, tracking: 0.9)
            titleRight = pill.minX - 8
        } else if !lesson.detail.isEmpty, lesson.status == .done {
            let font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
            let width = min(rect.width * 0.5, measuredWidth(lesson.detail, font: font) + 2)
            drawText(lesson.detail,
                     in: CGRect(x: right - width, y: y + 2, width: width, height: 14),
                     font: font, color: Ink.mint.withAlphaComponent(0.85), alignment: .right)
            titleRight = right - width - 8
        }

        drawText(lesson.title,
                 in: CGRect(x: textLeft, y: y, width: max(40, titleRight - textLeft), height: 18),
                 font: titleFont,
                 color: lesson.status == .blocked ? Ink.secondary : Ink.primary)
        y += 19

        let tryFont = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
        drawText("TRY",
                 in: CGRect(x: textLeft, y: y + 1.5, width: 24, height: 13),
                 font: tryFont, color: Ink.mint.withAlphaComponent(0.75), tracking: 0.7)

        let instructionWidth = lessonInstructionWidth(cardWidth: rect.width)
        let instructionHeight = wrappedHeight(lesson.instruction,
                                              font: .systemFont(ofSize: 11.5),
                                              width: instructionWidth)
        drawText(lesson.instruction,
                 in: CGRect(x: textLeft + 26, y: y, width: instructionWidth, height: instructionHeight),
                 font: .systemFont(ofSize: 11.5),
                 color: lesson.status == .blocked ? Ink.tertiary : Ink.secondary,
                 wraps: true)
        y += instructionHeight

        if lesson.status == .blocked {
            drawText(lesson.blockedHint,
                     in: CGRect(x: textLeft, y: y + 1, width: right - textLeft, height: 15),
                     font: .systemFont(ofSize: 10.5, weight: .medium),
                     color: Ink.rose)
        }
    }

    // MARK: Weight card

    private let weightSteps = [
        "Clear the pad",
        "Tare",
        "Place an object (a spoon, not a hand)",
        "Slide grams/unit until a known weight reads true"
    ]

    /// Must mirror `drawWeightCard`'s geometry exactly, or the card clips.
    private func weightStepWidth(cardWidth: CGFloat) -> CGFloat {
        max(40, cardWidth - Metric.cardPadding * 2 - 22)
    }

    private func weightStepHeight(_ step: String, cardWidth: CGFloat) -> CGFloat {
        max(17, wrappedHeight(step, font: .systemFont(ofSize: 11),
                              width: weightStepWidth(cardWidth: cardWidth)))
    }

    private func weightCardHeight(cardWidth: CGFloat) -> CGFloat {
        guard MultitouchReader.shared.isAvailable else {
            return Metric.cardPadding * 2 + 21 + 34
        }
        var height = Metric.cardPadding * 2 + 19
        for step in weightSteps {
            height += weightStepHeight(step, cardWidth: cardWidth) + 4
        }
        height += 12 + 30 + 12 + 24   // separator + readout + gap + controls
        return height
    }

    private func weightControlsRect(in card: CGRect) -> CGRect {
        CGRect(x: card.minX + Metric.cardPadding,
               y: card.maxY - Metric.cardPadding - 22,
               width: card.width - Metric.cardPadding * 2,
               height: 22)
    }

    private func positionWeightControls(in card: CGRect) {
        let row = weightControlsRect(in: card)
        let tareWidth: CGFloat = 56
        gramsSlider.frame = CGRect(x: row.minX, y: row.minY + 3,
                                   width: max(60, row.width - tareWidth - 12), height: 18)
        tareButton.frame = CGRect(x: row.maxX - tareWidth, y: row.minY,
                                  width: tareWidth, height: 22)
    }

    private func drawWeightCard(in rect: CGRect) {
        fillRounded(rect, radius: Metric.cardRadius, color: Ink.card)
        strokeRounded(rect, radius: Metric.cardRadius, color: Ink.border, width: 1)

        let left = rect.minX + Metric.cardPadding
        let right = rect.maxX - Metric.cardPadding
        var y = rect.minY + Metric.cardPadding

        drawText("Weight estimate",
                 in: CGRect(x: left, y: y, width: rect.width - Metric.cardPadding * 2 - 60, height: 18),
                 font: .systemFont(ofSize: 12.5, weight: .semibold),
                 color: Ink.primary)

        guard MultitouchReader.shared.isAvailable else {
            drawText("✗",
                     in: CGRect(x: right - 16, y: y + 1, width: 16, height: 16),
                     font: .systemFont(ofSize: 12, weight: .bold),
                     color: Ink.rose, alignment: .right)
            drawText("Per-finger size unavailable — the private framework is blocked.",
                     in: CGRect(x: left, y: y + 21, width: right - left, height: 34),
                     font: .systemFont(ofSize: 10.5), color: Ink.tertiary, wraps: true)
            return
        }

        drawText(String(format: "%.0f g / unit", gramsSlider.doubleValue),
                 in: CGRect(x: right - 100, y: y + 2, width: 100, height: 14),
                 font: .monospacedDigitSystemFont(ofSize: 9.5, weight: .medium),
                 color: Ink.tertiary, alignment: .right)
        y += 19

        for (index, step) in weightSteps.enumerated() {
            let stepWidth = weightStepWidth(cardWidth: rect.width)
            let height = weightStepHeight(step, cardWidth: rect.width)
            let chip = CGRect(x: left, y: y + 1, width: 15, height: 15)
            fillRounded(chip, radius: 7.5, color: Ink.mint.withAlphaComponent(0.16))
            drawText("\(index + 1)",
                     in: CGRect(x: chip.minX, y: chip.minY + 2, width: chip.width, height: 12),
                     font: .systemFont(ofSize: 9, weight: .bold),
                     color: Ink.mint, alignment: .center)
            drawText(step,
                     in: CGRect(x: left + 22, y: y, width: stepWidth, height: height),
                     font: .systemFont(ofSize: 11), color: Ink.secondary, wraps: true)
            y += height + 4
        }

        y += 6
        drawHairline(from: CGPoint(x: left, y: y), to: CGPoint(x: right, y: y))
        y += 6

        drawText(String(format: "%.1f g", grams.value),
                 in: CGRect(x: left, y: y, width: (right - left) * 0.55, height: 26),
                 font: .monospacedDigitSystemFont(ofSize: 20, weight: .medium),
                 color: Ink.mint)
        drawText(String(format: "net size %.3f", netContactSize),
                 in: CGRect(x: rect.midX, y: y + 8, width: right - rect.midX, height: 15),
                 font: .monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                 color: Ink.tertiary, alignment: .right)
    }

    // MARK: Event intake

    private func ingest(_ event: NSEvent) {
        let samples = event.touches(matching: .touching, in: nil).map {
            TouchSample(id: $0.identity.hash,
                        pos: $0.normalizedPosition,
                        deviceSize: $0.deviceSize,
                        resting: $0.isResting)
        }
        receive(.touches(samples))
    }

    private func receive(_ event: InputEvent) {
        switch event {
        case .touches(let samples):
            handle(samples)

        case .pressure(let value, let stage):
            let clamped = min(1, max(0, value))
            pressureLevel.target = clamped
            pressureStage = max(0, stage)
            peakPressure = max(peakPressure, clamped)
            peakStage = max(peakStage, pressureStage)
            lastPressureTime = ProcessInfo.processInfo.systemUptime

        case .click(let down, _):
            isClicking = down
            if !down {
                pressureLevel.target = 0
                pressureStage = 0
            }

        case .drag:
            break

        case .magnify(let delta):
            let step = 1 + delta
            if step > 0 {
                pinch.target *= step
                if !pinch.target.isFinite || pinch.target > 1e6 || pinch.target < 1e-6 {
                    pinch.reset(to: 1)
                }
            }
            sawPinch = true

        case .rotate(let degrees):
            rotation.target += degrees
            sawRotate = true

        case .scroll(let dx, let dy, _, _):
            scrollX.target = dx
            scrollY.target = dy
            lastScrollTime = ProcessInfo.processInfo.systemUptime
            sawScroll = true

        case .key(let chars, _, let modifiers):
            if isResetKey(chars, modifiers: modifiers) {
                resetGestureReadouts()
            }
        }
        invalidate()
    }

    private func handle(_ samples: [TouchSample]) {
        if let size = samples.first?.deviceSize, size.width > 0, size.height > 0 {
            lastDeviceSize = size
        }
        restingCount = samples.reduce(0) { $0 + ($1.resting ? 1 : 0) }
        if restingCount > 0 { sawResting = true }
        maxSimultaneous = max(maxSimultaneous, samples.count)
        noteCorners(samples.map(\.pos))

        guard !MultitouchReader.shared.isAvailable else { return }
        merge(samples.map {
            ContactInput(key: $0.id, pos: $0.pos, size: $0.resting ? 0.35 : 0.6,
                         major: 0, minor: 0, angle: 0, resting: $0.resting)
        })
    }

    private func receive(_ fingers: [MTFingerSample]) {
        maxSimultaneous = max(maxSimultaneous, fingers.count)
        peakContactSize = max(peakContactSize, fingers.map(\.size).max() ?? 0)
        noteCorners(fingers.map(\.pos))
        merge(fingers.map {
            ContactInput(key: $0.id, pos: $0.pos, size: $0.size,
                         major: $0.majorAxis, minor: $0.minorAxis, angle: $0.angle,
                         resting: false)
        })
        invalidate()
    }

    private func noteCorners(_ positions: [CGPoint]) {
        let margin: CGFloat = 0.18
        for point in positions {
            let nearLeft = point.x <= margin
            let nearRight = point.x >= 1 - margin
            let nearBottom = point.y <= margin
            let nearTop = point.y >= 1 - margin
            guard nearLeft || nearRight, nearBottom || nearTop else { continue }
            cornersVisited.insert((nearRight ? 1 : 0) + (nearTop ? 2 : 0))
        }
    }

    // MARK: Contact bookkeeping

    private func merge(_ inputs: [ContactInput]) {
        var seen = Set<Int>()
        for input in inputs {
            seen.insert(input.key)
            if var contact = contacts[input.key] {
                contact.pos = input.pos
                contact.size = input.size
                contact.major = input.major
                contact.minor = input.minor
                contact.angle = input.angle
                contact.resting = input.resting
                contact.alive = true
                contacts[input.key] = contact
            } else {
                contacts[input.key] = Contact(slot: freeSlot(),
                                              pos: input.pos,
                                              size: input.size,
                                              major: input.major,
                                              minor: input.minor,
                                              angle: input.angle,
                                              resting: input.resting,
                                              alive: true,
                                              alpha: 0)
            }
        }
        for key in Array(contacts.keys) where !seen.contains(key) {
            contacts[key]?.alive = false
        }
    }

    /// Lowest unused slot keeps a finger's colour and number stable for its whole life.
    private func freeSlot() -> Int {
        let used = Set(contacts.values.map(\.slot))
        var slot = 0
        while used.contains(slot) { slot += 1 }
        return slot
    }

    private var liveContactCount: Int {
        contacts.values.reduce(0) { $0 + ($1.alive ? 1 : 0) }
    }

    private var rawContactSize: Double {
        contacts.values.reduce(0) { $0 + ($1.alive ? max(0, $1.size) : 0) }
    }

    private var netContactSize: Double {
        max(0, rawContactSize - tareBaseline)
    }

    // MARK: Animation tick

    private func tick() {
        let available = MultitouchReader.shared.isAvailable
        if available != readerWasAvailable {
            readerWasAvailable = available
            syncControlAvailability()
            needsLayout = true
            invalidate()
        }

        // A held press stops emitting events, so only release the bar once the
        // click is known to be over (or the click was never seen at all).
        let now = ProcessInfo.processInfo.systemUptime
        if pressureLevel.target > 0, !isClicking, now - lastPressureTime > 0.35 {
            pressureLevel.target = 0
        }
        if pressureLevel.target == 0, pressureLevel.value == 0 {
            pressureStage = 0
        }
        if now - lastScrollTime > 0.15 {
            scrollX.target = 0
            scrollY.target = 0
        }

        grams.target = MultitouchReader.shared.isAvailable
            ? netContactSize * gramsSlider.doubleValue : 0
        let lessonList = lessons()
        progress.target = Double(lessonList.filter { $0.status == .done }.count)
            / Double(max(1, lessonList.count))

        pressureLevel.step(0.28)
        pinch.step()
        rotation.step()
        scrollX.step(0.3)
        scrollY.step(0.3)
        grams.step(0.18)
        progress.step(0.15)

        var fading = false
        for key in Array(contacts.keys) {
            guard var contact = contacts[key] else { continue }
            let target: CGFloat = contact.alive ? 1 : 0
            let delta = target - contact.alpha
            if abs(delta) < 0.01 {
                contact.alpha = target
            } else {
                contact.alpha += delta * 0.30
                fading = true
            }
            if !contact.alive, contact.alpha <= 0 {
                contacts[key] = nil
                fading = true
            } else {
                contacts[key] = contact
            }
        }

        let settled = pressureLevel.isSettled && pinch.isSettled && rotation.isSettled
            && scrollX.isSettled && scrollY.isSettled && grams.isSettled && progress.isSettled
        if !settled || fading || !contacts.isEmpty {
            invalidate()
        }
    }

    private func invalidate() {
        needsDisplay = true
        sidebar.needsDisplay = true
    }

    // MARK: Controls

    @objc private func gramsPerUnitChanged(_ sender: NSSlider) {
        invalidate()
    }

    @objc private func tareWeight(_ sender: NSButton) {
        tareBaseline = rawContactSize
        grams.reset(to: 0)
        invalidate()
        window?.makeFirstResponder(captureView)
    }

    private func syncControlAvailability() {
        let hidden = !MultitouchReader.shared.isAvailable
        gramsSlider.isHidden = hidden
        tareButton.isHidden = hidden
    }

    private func isResetKey(_ characters: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        let blocked: NSEvent.ModifierFlags = [.command, .control, .option]
        return characters.lowercased() == "r" && modifiers.intersection(blocked).isEmpty
    }

    private func resetGestureReadouts() {
        pinch.reset(to: 1)
        rotation.reset(to: 0)
        scrollX.reset(to: 0)
        scrollY.reset(to: 0)
        invalidate()
    }

    private func clamp01(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
    }

    // MARK: Touch fallback
    // Touch events follow the view under the pointer; the pointer rides along
    // with the finger, so it regularly leaves the capture view. Catch what
    // bubbles up here so tracking never stalls mid-gesture.

    override func touchesBegan(with event: NSEvent) { ingest(event) }
    override func touchesMoved(with event: NSEvent) { ingest(event) }
    override func touchesEnded(with event: NSEvent) { ingest(event) }
    override func touchesCancelled(with event: NSEvent) { ingest(event) }

    override func pressureChange(with event: NSEvent) {
        receive(.pressure(pressure: Double(event.pressure), stage: event.stage))
    }

    override func magnify(with event: NSEvent) {
        receive(.magnify(delta: Double(event.magnification)))
    }

    override func rotate(with event: NSEvent) {
        receive(.rotate(degrees: Double(event.rotation)))
    }
}
