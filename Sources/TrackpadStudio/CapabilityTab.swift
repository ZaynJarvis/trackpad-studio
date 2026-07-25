import AppKit

final class CapabilityTabView: NSView {
    private enum Palette {
        static let background = NSColor(calibratedRed: 0.045, green: 0.055, blue: 0.075, alpha: 1)
        static let panel = NSColor(calibratedRed: 0.075, green: 0.090, blue: 0.120, alpha: 0.98)
        static let pad = NSColor(calibratedRed: 0.090, green: 0.108, blue: 0.140, alpha: 1)
        static let line = NSColor(calibratedWhite: 0.72, alpha: 0.18)
        static let faintLine = NSColor(calibratedWhite: 0.75, alpha: 0.075)
        static let primary = NSColor(calibratedWhite: 0.96, alpha: 1)
        static let secondary = NSColor(calibratedWhite: 0.72, alpha: 1)
        static let tertiary = NSColor(calibratedWhite: 0.48, alpha: 1)
        static let mint = NSColor(calibratedRed: 0.31, green: 0.91, blue: 0.73, alpha: 1)
        static let amber = NSColor(calibratedRed: 1.00, green: 0.70, blue: 0.30, alpha: 1)
        static let red = NSColor(calibratedRed: 1.00, green: 0.40, blue: 0.43, alpha: 1)
        static let fingerColors: [NSColor] = [
            NSColor(calibratedRed: 0.29, green: 0.87, blue: 0.77, alpha: 1),
            NSColor(calibratedRed: 0.48, green: 0.67, blue: 1.00, alpha: 1),
            NSColor(calibratedRed: 0.78, green: 0.51, blue: 1.00, alpha: 1),
            NSColor(calibratedRed: 1.00, green: 0.61, blue: 0.35, alpha: 1),
            NSColor(calibratedRed: 1.00, green: 0.43, blue: 0.67, alpha: 1)
        ]
    }

    private enum CapabilityState: Equatable {
        case seen
        case waiting
        case unavailable
    }

    private struct Columns {
        let left: CGRect
        let right: CGRect
    }

    private struct ReadoutLayout {
        let panel: CGRect
        let inner: CGRect
        let headerY: CGFloat
        let touchTop: CGFloat
        let forceTop: CGFloat
        let gesturesTop: CGFloat
        let weightTop: CGFloat
        let checklistTop: CGFloat
        let checklistRowsTop: CGFloat
        let checklistRowHeight: CGFloat
        let sliderFrame: CGRect
        let tareFrame: CGRect
    }

    private let captureView = TouchCaptureView()
    private let gramsSlider: NSSlider
    private let tareButton: NSButton

    private var touchSamples: [TouchSample] = []
    private var mtFingers: [MTFingerSample] = []
    private var lastDeviceSize = CGSize(width: 160, height: 100)

    private var pressure = 0.0
    private var pressureStage = 0
    private var lastPressureEventTime: TimeInterval = 0
    private var pinchScale = 1.0
    private var rotationDegrees = 0.0
    private var lastScroll = CGPoint.zero
    private var tareBaseline = 0.0

    private var sawMultitouch = false
    private var sawAbsolutePosition = false
    private var sawPrivateDetail = false
    private var sawPressure = false
    private var sawPinch = false
    private var sawRotate = false
    private var sawScroll = false
    private var sawRestingTouch = false

    private var redrawTimer: Timer?
    private var keyMonitor: Any?
    private var previousFrameHandler: (([MTFingerSample]) -> Void)?
    private var lastReaderAvailability: Bool

    init() {
        gramsSlider = NSSlider(value: 50, minValue: 5, maxValue: 120, target: nil, action: nil)
        tareButton = NSButton(title: "Tare", target: nil, action: nil)
        lastReaderAvailability = MultitouchReader.shared.isAvailable
        super.init(frame: .zero)

        wantsLayer = true
        layer?.masksToBounds = true

        captureView.frame = bounds
        captureView.autoresizingMask = [.width, .height]
        captureView.onEvent = { [weak self] event in
            self?.receive(event)
        }
        addSubview(captureView)

        gramsSlider.isContinuous = true
        gramsSlider.controlSize = .small
        gramsSlider.focusRingType = .none
        gramsSlider.target = self
        gramsSlider.action = #selector(gramsPerUnitChanged(_:))
        gramsSlider.setAccessibilityLabel("Grams per contact-size unit")
        addSubview(gramsSlider)

        tareButton.bezelStyle = .rounded
        tareButton.controlSize = .small
        tareButton.font = .systemFont(ofSize: 11, weight: .medium)
        tareButton.focusRingType = .none
        tareButton.target = self
        tareButton.action = #selector(tareWeight(_:))
        tareButton.setAccessibilityLabel("Tare weight estimate")
        addSubview(tareButton)

        installFrameHandler()
        installKeyMonitor()
        installRedrawTimer()
        syncControlAvailability()
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    deinit {
        redrawTimer?.invalidate()
        if let keyMonitor = keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        MultitouchReader.shared.onFrame = previousFrameHandler
    }

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        captureView.frame = bounds

        let readout = makeReadoutLayout()
        gramsSlider.frame = readout.sliderFrame
        tareButton.frame = readout.tareFrame
        syncControlAvailability()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        Palette.background.setFill()
        bounds.fill()

        let columns = makeColumns()
        drawTrackpad(in: columns.left)
        drawReadouts(makeReadoutLayout())
    }

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
            guard let self = self, event.window === self.window else { return event }
            guard !self.isHiddenOrHasHiddenAncestor else { return event }
            guard self.isResetKey(event.charactersIgnoringModifiers ?? "",
                                  modifiers: event.modifierFlags) else {
                return event
            }
            self.resetGestureReadouts()
            return nil
        }
    }

    private func installRedrawTimer() {
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.timerDidFire()
        }
        redrawTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func timerDidFire() {
        let available = MultitouchReader.shared.isAvailable
        if available != lastReaderAvailability {
            lastReaderAvailability = available
            syncControlAvailability()
            needsLayout = true
        }

        let idleFor = ProcessInfo.processInfo.systemUptime - lastPressureEventTime
        if pressure > 0, idleFor > 0.25 {
            pressure *= 0.84
            if pressure < 0.005 {
                pressure = 0
                pressureStage = 0
            }
        }
        needsDisplay = true
    }

    private func receive(_ event: InputEvent) {
        switch event {
        case .touches(let samples):
            touchSamples = samples
            if let size = samples.first?.deviceSize, size.width > 0, size.height > 0 {
                lastDeviceSize = size
            }
            if !samples.isEmpty {
                sawAbsolutePosition = true
            }
            if samples.count >= 2 {
                sawMultitouch = true
            }
            if samples.contains(where: { $0.resting }) {
                sawRestingTouch = true
            }

        case .pressure(let value, let stage):
            pressure = min(1, max(0, value))
            pressureStage = max(0, stage)
            lastPressureEventTime = ProcessInfo.processInfo.systemUptime
            sawPressure = true

        case .click(let down, _):
            if !down {
                pressure = 0
                pressureStage = 0
            }

        case .drag:
            break

        case .magnify(let delta):
            let step = 1 + delta
            if step > 0 {
                pinchScale *= step
                if !pinchScale.isFinite {
                    pinchScale = 1
                }
            }
            sawPinch = true

        case .rotate(let degrees):
            rotationDegrees += degrees
            sawRotate = true

        case .scroll(let dx, let dy, _, _):
            lastScroll = CGPoint(x: CGFloat(dx), y: CGFloat(dy))
            sawScroll = true

        case .key(let chars, _, let modifiers):
            if isResetKey(chars, modifiers: modifiers) {
                resetGestureReadouts()
                return
            }
        }
        needsDisplay = true
    }

    private func receive(_ fingers: [MTFingerSample]) {
        mtFingers = fingers
        if !fingers.isEmpty {
            sawPrivateDetail = true
            sawAbsolutePosition = true
        }
        if fingers.count >= 2 {
            sawMultitouch = true
        }
        needsDisplay = true
    }

    private func isResetKey(_ characters: String,
                            modifiers: NSEvent.ModifierFlags) -> Bool {
        let blockedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        return characters.lowercased() == "r"
            && modifiers.intersection(blockedModifiers).isEmpty
    }

    private func resetGestureReadouts() {
        pinchScale = 1
        rotationDegrees = 0
        lastScroll = .zero
        needsDisplay = true
    }

    @objc private func gramsPerUnitChanged(_ sender: NSSlider) {
        needsDisplay = true
    }

    @objc private func tareWeight(_ sender: NSButton) {
        tareBaseline = rawContactSize
        needsDisplay = true
        window?.makeFirstResponder(captureView)
    }

    private var rawContactSize: Double {
        mtFingers.reduce(0) { $0 + max(0, $1.size) }
    }

    private var netContactSize: Double {
        max(0, rawContactSize - tareBaseline)
    }

    private var displayedTouchCount: Int {
        MultitouchReader.shared.isAvailable ? mtFingers.count : touchSamples.count
    }

    private var restingTouchCount: Int {
        touchSamples.reduce(0) { $0 + ($1.resting ? 1 : 0) }
    }

    private func syncControlAvailability() {
        let unavailable = !MultitouchReader.shared.isAvailable
        gramsSlider.isHidden = unavailable
        tareButton.isHidden = unavailable
    }

    private func makeColumns() -> Columns {
        let content = bounds.insetBy(dx: 22, dy: 20)
        let gap: CGFloat = 20
        let distributableWidth = max(0, content.width - gap)
        let leftWidth = floor(distributableWidth * 0.65)
        let left = CGRect(x: content.minX, y: content.minY,
                          width: leftWidth, height: content.height)
        let right = CGRect(x: left.maxX + gap, y: content.minY,
                           width: max(0, content.maxX - left.maxX - gap),
                           height: content.height)
        return Columns(left: left, right: right)
    }

    private func makeReadoutLayout() -> ReadoutLayout {
        let panel = makeColumns().right
        let inner = panel.insetBy(dx: 16, dy: 0)
        let top = panel.maxY - 15
        let headerY = top - 10
        let touchTop = top - 25
        let forceTop = touchTop - 47
        let gesturesTop = forceTop - 58
        let weightTop = gesturesTop - 66
        let checklistTop = weightTop - 83
        let rowsTop = checklistTop - 22
        let availableRowsHeight = max(0, rowsTop - (panel.minY + 12))
        let rowHeight = min(22, max(15, availableRowsHeight / 8))

        let tareWidth: CGFloat = 52
        let controlGap: CGFloat = 10
        let sliderFrame = CGRect(x: inner.minX,
                                 y: weightTop - 72,
                                 width: max(70, inner.width - tareWidth - controlGap),
                                 height: 18)
        let tareFrame = CGRect(x: inner.maxX - tareWidth,
                               y: weightTop - 74,
                               width: tareWidth,
                               height: 22)
        return ReadoutLayout(panel: panel,
                             inner: inner,
                             headerY: headerY,
                             touchTop: touchTop,
                             forceTop: forceTop,
                             gesturesTop: gesturesTop,
                             weightTop: weightTop,
                             checklistTop: checklistTop,
                             checklistRowsTop: rowsTop,
                             checklistRowHeight: rowHeight,
                             sliderFrame: sliderFrame,
                             tareFrame: tareFrame)
    }

    private func drawTrackpad(in column: CGRect) {
        drawText("CAPABILITY", in: CGRect(x: column.minX, y: column.maxY - 22,
                                          width: column.width, height: 16),
                 font: .systemFont(ofSize: 11, weight: .semibold),
                 color: Palette.mint, tracking: 1.5)
        drawText("Live trackpad surface", in: CGRect(x: column.minX, y: column.maxY - 49,
                                                     width: column.width, height: 25),
                 font: .systemFont(ofSize: 22, weight: .semibold),
                 color: Palette.primary)

        let padArea = CGRect(x: column.minX + 5, y: column.minY + 34,
                             width: column.width - 10, height: column.height - 98)
        let padRect = TrackpadGeometry.padRect(in: padArea,
                                               deviceSize: lastDeviceSize,
                                               fraction: 0.94)
        let padPath = NSBezierPath(roundedRect: padRect, xRadius: 20, yRadius: 20)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.48)
        shadow.shadowBlurRadius = 24
        shadow.shadowOffset = CGSize(width: 0, height: -8)
        shadow.set()
        Palette.pad.setFill()
        padPath.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        padPath.addClip()
        drawPadGrid(in: padRect)
        NSGraphicsContext.restoreGraphicsState()

        Palette.line.setStroke()
        padPath.lineWidth = 1.2
        padPath.stroke()

        let innerHighlight = NSBezierPath(roundedRect: padRect.insetBy(dx: 4, dy: 4),
                                          xRadius: 17, yRadius: 17)
        NSColor(calibratedWhite: 1, alpha: 0.035).setStroke()
        innerHighlight.lineWidth = 1
        innerHighlight.stroke()

        if MultitouchReader.shared.isAvailable {
            drawMTFingers(in: padRect)
        } else {
            drawPublicTouches(in: padRect)
        }

        if displayedTouchCount == 0 {
            drawText("Touch the trackpad", in: CGRect(x: padRect.minX,
                                                      y: padRect.midY + 2,
                                                      width: padRect.width,
                                                      height: 22),
                     font: .systemFont(ofSize: 15, weight: .medium),
                     color: Palette.secondary, alignment: .center)
            drawText("Live contacts appear here", in: CGRect(x: padRect.minX,
                                                             y: padRect.midY - 21,
                                                             width: padRect.width,
                                                             height: 18),
                     font: .systemFont(ofSize: 11),
                     color: Palette.tertiary, alignment: .center)
        }

        let source = MultitouchReader.shared.isAvailable
            ? "MULTITOUCH DETAIL  •  SIZE + ELLIPSE"
            : "PUBLIC NSTOUCH FALLBACK  •  POSITION"
        drawText(source, in: CGRect(x: column.minX, y: column.minY + 3,
                                    width: column.width, height: 16),
                 font: .systemFont(ofSize: 9, weight: .medium),
                 color: Palette.tertiary, alignment: .center, tracking: 0.8)
    }

    private func drawPadGrid(in rect: CGRect) {
        Palette.faintLine.setStroke()
        for index in 1..<4 {
            let x = rect.minX + rect.width * CGFloat(index) / 4
            let vertical = NSBezierPath()
            vertical.move(to: CGPoint(x: x, y: rect.minY))
            vertical.line(to: CGPoint(x: x, y: rect.maxY))
            vertical.lineWidth = 0.7
            vertical.stroke()
        }
        for index in 1..<3 {
            let y = rect.minY + rect.height * CGFloat(index) / 3
            let horizontal = NSBezierPath()
            horizontal.move(to: CGPoint(x: rect.minX, y: y))
            horizontal.line(to: CGPoint(x: rect.maxX, y: y))
            horizontal.lineWidth = 0.7
            horizontal.stroke()
        }

        let center = NSBezierPath()
        center.move(to: CGPoint(x: rect.midX - 4, y: rect.midY))
        center.line(to: CGPoint(x: rect.midX + 4, y: rect.midY))
        center.move(to: CGPoint(x: rect.midX, y: rect.midY - 4))
        center.line(to: CGPoint(x: rect.midX, y: rect.midY + 4))
        center.lineWidth = 1
        center.stroke()
    }

    private func drawMTFingers(in padRect: CGRect) {
        let fingers = mtFingers.sorted { $0.id < $1.id }
        let physicalWidth = max(1, lastDeviceSize.width)
        let physicalHeight = max(1, lastDeviceSize.height)

        for (index, finger) in fingers.enumerated() {
            let normalized = clamped(finger.pos)
            let center = TrackpadGeometry.map(normalized, into: padRect)
            let color = Palette.fingerColors[index % Palette.fingerColors.count]

            let fallbackDiameter = CGFloat(18 + min(28, max(0, finger.size) * 18))
            let measuredWidth = CGFloat(finger.majorAxis) / physicalWidth * padRect.width
            let measuredHeight = CGFloat(finger.minorAxis) / physicalHeight * padRect.height
            let ellipseWidth = min(padRect.width * 0.28,
                                   max(12, measuredWidth > 1 ? measuredWidth : fallbackDiameter))
            let ellipseHeight = min(padRect.height * 0.32,
                                    max(12, measuredHeight > 1 ? measuredHeight : fallbackDiameter * 0.72))
            let alpha = CGFloat(min(0.85, max(0.12, finger.size / 1.5 * 0.85)))

            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: center.x, yBy: center.y)
            transform.rotate(byRadians: CGFloat(finger.angle))
            transform.concat()

            let ellipseRect = CGRect(x: -ellipseWidth / 2, y: -ellipseHeight / 2,
                                     width: ellipseWidth, height: ellipseHeight)
            let ellipse = NSBezierPath(ovalIn: ellipseRect)
            color.withAlphaComponent(alpha).setFill()
            ellipse.fill()
            color.withAlphaComponent(0.95).setStroke()
            ellipse.lineWidth = 1.5
            ellipse.stroke()
            NSGraphicsContext.restoreGraphicsState()

            let label = String(format: "%d  %.2f, %.2f",
                               index + 1, normalized.x, normalized.y)
            drawFingerLabel(label, near: center,
                            radius: max(ellipseWidth, ellipseHeight) / 2,
                            color: color, constrainedTo: padRect)
        }
    }

    private func drawPublicTouches(in padRect: CGRect) {
        let samples = touchSamples.sorted { $0.id < $1.id }
        for (index, sample) in samples.enumerated() {
            let normalized = clamped(sample.pos)
            let center = TrackpadGeometry.map(normalized, into: padRect)
            let color = Palette.fingerColors[index % Palette.fingerColors.count]
            let radius: CGFloat = sample.resting ? 12 : 17
            let circle = NSBezierPath(ovalIn: CGRect(x: center.x - radius,
                                                     y: center.y - radius,
                                                     width: radius * 2,
                                                     height: radius * 2))
            color.withAlphaComponent(sample.resting ? 0.18 : 0.34).setFill()
            circle.fill()
            color.withAlphaComponent(sample.resting ? 0.62 : 0.95).setStroke()
            circle.lineWidth = sample.resting ? 1 : 1.5
            circle.stroke()

            if sample.resting {
                let inner = NSBezierPath(ovalIn: CGRect(x: center.x - radius + 4,
                                                        y: center.y - radius + 4,
                                                        width: radius * 2 - 8,
                                                        height: radius * 2 - 8))
                color.withAlphaComponent(0.38).setStroke()
                inner.lineWidth = 1
                inner.stroke()
            }

            let label = String(format: "%d  %.2f, %.2f",
                               index + 1, normalized.x, normalized.y)
            drawFingerLabel(label, near: center, radius: radius,
                            color: color, constrainedTo: padRect)
        }
    }

    private func drawFingerLabel(_ text: String, near point: CGPoint,
                                 radius: CGFloat, color: NSColor,
                                 constrainedTo padRect: CGRect) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let width = textSize.width + 12
        let height: CGFloat = 18
        var x = point.x - width / 2
        x = min(padRect.maxX - width - 6, max(padRect.minX + 6, x))

        var y = point.y + radius + 7
        if y + height > padRect.maxY - 5 {
            y = point.y - radius - height - 7
        }
        y = min(padRect.maxY - height - 5, max(padRect.minY + 5, y))

        let chipRect = CGRect(x: x, y: y, width: width, height: height)
        let chip = NSBezierPath(roundedRect: chipRect, xRadius: 5, yRadius: 5)
        Palette.background.withAlphaComponent(0.86).setFill()
        chip.fill()
        color.withAlphaComponent(0.45).setStroke()
        chip.lineWidth = 0.8
        chip.stroke()

        drawText(text, in: CGRect(x: chipRect.minX + 6, y: chipRect.minY + 2,
                                  width: chipRect.width - 12, height: 14),
                 font: font, color: Palette.primary, alignment: .center)
    }

    private func drawReadouts(_ layout: ReadoutLayout) {
        let panelPath = NSBezierPath(roundedRect: layout.panel, xRadius: 16, yRadius: 16)
        Palette.panel.setFill()
        panelPath.fill()
        Palette.line.setStroke()
        panelPath.lineWidth = 1
        panelPath.stroke()

        drawText("SIGNAL MONITOR",
                 in: CGRect(x: layout.inner.minX, y: layout.headerY,
                            width: layout.inner.width * 0.55, height: 14),
                 font: .systemFont(ofSize: 10, weight: .semibold),
                 color: Palette.secondary, tracking: 1.1)
        drawText(MultitouchReader.shared.isAvailable ? "MT DETAIL" : "PUBLIC FALLBACK",
                 in: CGRect(x: layout.inner.midX, y: layout.headerY,
                            width: layout.inner.width / 2, height: 14),
                 font: .systemFont(ofSize: 9, weight: .semibold),
                 color: MultitouchReader.shared.isAvailable ? Palette.mint : Palette.amber,
                 alignment: .right, tracking: 0.5)

        drawTouchCount(layout)
        drawForce(layout)
        drawGestures(layout)
        drawWeight(layout)
        drawChecklist(layout)
    }

    private func drawTouchCount(_ layout: ReadoutLayout) {
        drawText("\(displayedTouchCount)",
                 in: CGRect(x: layout.inner.minX, y: layout.touchTop - 31,
                            width: 45, height: 34),
                 font: .monospacedDigitSystemFont(ofSize: 28, weight: .semibold),
                 color: Palette.primary)
        drawText(displayedTouchCount == 1 ? "TOUCH" : "TOUCHES",
                 in: CGRect(x: layout.inner.minX + 47, y: layout.touchTop - 24,
                            width: 80, height: 15),
                 font: .systemFont(ofSize: 10, weight: .semibold),
                 color: Palette.secondary, tracking: 0.8)
        drawText("\(restingTouchCount) resting",
                 in: CGRect(x: layout.inner.midX, y: layout.touchTop - 24,
                            width: layout.inner.width / 2, height: 16),
                 font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                 color: restingTouchCount > 0 ? Palette.mint : Palette.tertiary,
                 alignment: .right)
        drawDivider(y: layout.touchTop - 40, in: layout.inner)
    }

    private func drawForce(_ layout: ReadoutLayout) {
        drawSectionTitle("FORCE TOUCH", y: layout.forceTop - 10, in: layout.inner)
        drawText(String(format: "%.2f  ·  STAGE %d", pressure, pressureStage),
                 in: CGRect(x: layout.inner.midX - 10, y: layout.forceTop - 11,
                            width: layout.inner.width / 2 + 10, height: 14),
                 font: .monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                 color: pressureStage >= 2 ? Palette.amber : Palette.secondary,
                 alignment: .right)

        let barRect = CGRect(x: layout.inner.minX, y: layout.forceTop - 29,
                             width: layout.inner.width, height: 8)
        let bar = NSBezierPath(roundedRect: barRect, xRadius: 4, yRadius: 4)
        NSColor(calibratedWhite: 1, alpha: 0.08).setFill()
        bar.fill()

        if pressure > 0 {
            let fillRect = CGRect(x: barRect.minX, y: barRect.minY,
                                  width: max(8, barRect.width * CGFloat(pressure)),
                                  height: barRect.height)
            let fill = NSBezierPath(roundedRect: fillRect, xRadius: 4, yRadius: 4)
            (pressureStage >= 2 ? Palette.amber : Palette.mint).setFill()
            fill.fill()
        }

        drawText("press-click to measure",
                 in: CGRect(x: layout.inner.minX, y: layout.forceTop - 47,
                            width: layout.inner.width, height: 14),
                 font: .systemFont(ofSize: 10), color: Palette.tertiary)
        drawDivider(y: layout.forceTop - 51, in: layout.inner)
    }

    private func drawGestures(_ layout: ReadoutLayout) {
        drawSectionTitle("GESTURES", y: layout.gesturesTop - 10, in: layout.inner)
        drawText("R  RESET",
                 in: CGRect(x: layout.inner.midX, y: layout.gesturesTop - 10,
                            width: layout.inner.width / 2, height: 14),
                 font: .monospacedSystemFont(ofSize: 9, weight: .medium),
                 color: Palette.tertiary, alignment: .right)

        drawText("PINCH", in: CGRect(x: layout.inner.minX, y: layout.gesturesTop - 31,
                                     width: 45, height: 14),
                 font: .systemFont(ofSize: 9, weight: .semibold), color: Palette.tertiary)
        drawText(String(format: "%.3f×", pinchScale),
                 in: CGRect(x: layout.inner.minX + 47, y: layout.gesturesTop - 32,
                            width: layout.inner.width * 0.25, height: 15),
                 font: .monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                 color: Palette.primary)
        drawText("ROTATE", in: CGRect(x: layout.inner.midX + 3, y: layout.gesturesTop - 31,
                                      width: 52, height: 14),
                 font: .systemFont(ofSize: 9, weight: .semibold), color: Palette.tertiary)
        drawText(String(format: "%+.1f°", rotationDegrees),
                 in: CGRect(x: layout.inner.midX + 53, y: layout.gesturesTop - 32,
                            width: layout.inner.maxX - layout.inner.midX - 53, height: 15),
                 font: .monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                 color: Palette.primary, alignment: .right)

        drawText("SCROLL", in: CGRect(x: layout.inner.minX, y: layout.gesturesTop - 51,
                                      width: 50, height: 14),
                 font: .systemFont(ofSize: 9, weight: .semibold), color: Palette.tertiary)
        drawText(String(format: "dx %+.1f   dy %+.1f", lastScroll.x, lastScroll.y),
                 in: CGRect(x: layout.inner.minX + 52, y: layout.gesturesTop - 52,
                            width: layout.inner.width - 52, height: 15),
                 font: .monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                 color: Palette.secondary, alignment: .right)
        drawDivider(y: layout.gesturesTop - 59, in: layout.inner)
    }

    private func drawWeight(_ layout: ReadoutLayout) {
        drawSectionTitle("WEIGHT ESTIMATE", y: layout.weightTop - 10, in: layout.inner)

        guard MultitouchReader.shared.isAvailable else {
            drawText("per-finger size: unavailable (private framework blocked)",
                     in: CGRect(x: layout.inner.minX, y: layout.weightTop - 45,
                                width: layout.inner.width, height: 30),
                     font: .systemFont(ofSize: 10), color: Palette.tertiary)
            drawDivider(y: layout.weightTop - 76, in: layout.inner)
            return
        }

        let grams = netContactSize * gramsSlider.doubleValue
        drawText(String(format: "NET SIZE  %.3f", netContactSize),
                 in: CGRect(x: layout.inner.minX, y: layout.weightTop - 33,
                            width: layout.inner.width * 0.58, height: 16),
                 font: .monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                 color: Palette.secondary)
        drawText(String(format: "~ %.1f g", grams),
                 in: CGRect(x: layout.inner.midX, y: layout.weightTop - 34,
                            width: layout.inner.width / 2, height: 17),
                 font: .monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
                 color: Palette.mint, alignment: .right)
        drawText(String(format: "CALIBRATION  %.0f g / unit", gramsSlider.doubleValue),
                 in: CGRect(x: layout.inner.minX, y: layout.weightTop - 50,
                            width: layout.inner.width, height: 13),
                 font: .systemFont(ofSize: 9, weight: .medium),
                 color: Palette.tertiary, tracking: 0.4)
        drawDivider(y: layout.weightTop - 76, in: layout.inner)
    }

    private func drawChecklist(_ layout: ReadoutLayout) {
        drawSectionTitle("CAPABILITY CHECKLIST",
                         y: layout.checklistTop - 10, in: layout.inner)
        drawText("✓ SEEN   — WAIT   ✗ UNAVAILABLE",
                 in: CGRect(x: layout.inner.midX - 15, y: layout.checklistTop - 10,
                            width: layout.inner.width / 2 + 15, height: 13),
                 font: .monospacedSystemFont(ofSize: 7.5, weight: .medium),
                 color: Palette.tertiary, alignment: .right)

        let privateState: CapabilityState
        if !MultitouchReader.shared.isAvailable {
            privateState = .unavailable
        } else {
            privateState = sawPrivateDetail ? .seen : .waiting
        }

        let rows: [(String, CapabilityState)] = [
            ("Multi-touch tracking", sawMultitouch ? .seen : .waiting),
            ("Absolute position", sawAbsolutePosition ? .seen : .waiting),
            ("Per-finger size + ellipse", privateState),
            ("Force Touch pressure", sawPressure ? .seen : .waiting),
            ("Pinch", sawPinch ? .seen : .waiting),
            ("Rotate", sawRotate ? .seen : .waiting),
            ("Scroll", sawScroll ? .seen : .waiting),
            ("Resting-touch detection", sawRestingTouch ? .seen : .waiting)
        ]

        for (index, row) in rows.enumerated() {
            let top = layout.checklistRowsTop - CGFloat(index) * layout.checklistRowHeight
            let y = top - layout.checklistRowHeight + 3
            let symbol: String
            let color: NSColor
            switch row.1 {
            case .seen:
                symbol = "✓"
                color = Palette.mint
            case .waiting:
                symbol = "—"
                color = Palette.tertiary
            case .unavailable:
                symbol = "✗"
                color = Palette.red
            }

            drawText(symbol, in: CGRect(x: layout.inner.minX, y: y,
                                        width: 18, height: layout.checklistRowHeight - 2),
                     font: .systemFont(ofSize: 11, weight: .bold), color: color,
                     alignment: .center)
            drawText(row.0, in: CGRect(x: layout.inner.minX + 25, y: y,
                                       width: layout.inner.width - 25,
                                       height: layout.checklistRowHeight - 2),
                     font: .systemFont(ofSize: 10.5, weight: .regular),
                     color: row.1 == .unavailable ? Palette.tertiary : Palette.secondary)
        }
    }

    private func drawSectionTitle(_ title: String, y: CGFloat, in rect: CGRect) {
        drawText(title, in: CGRect(x: rect.minX, y: y, width: rect.width, height: 14),
                 font: .systemFont(ofSize: 9, weight: .semibold),
                 color: Palette.tertiary, tracking: 0.8)
    }

    private func drawDivider(y: CGFloat, in rect: CGRect) {
        let line = NSBezierPath()
        line.move(to: CGPoint(x: rect.minX, y: y))
        line.line(to: CGPoint(x: rect.maxX, y: y))
        Palette.faintLine.setStroke()
        line.lineWidth = 1
        line.stroke()
    }

    private func drawText(_ text: String, in rect: CGRect, font: NSFont,
                          color: NSColor, alignment: NSTextAlignment = .left,
                          tracking: CGFloat = 0) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
            .kern: tracking
        ]
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(1, max(0, point.x)),
                y: min(1, max(0, point.y)))
    }
}
