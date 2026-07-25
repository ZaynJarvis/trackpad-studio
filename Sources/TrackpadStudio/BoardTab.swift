import AppKit
import CoreGraphics

final class BoardTabView: NSView, NSTextFieldDelegate {
    private struct Draft {
        let tool: BoardTool
        let start: CGPoint
        var current: CGPoint
        var points: [CGPoint]
        var width: CGFloat
        var widthSampleCount: Int
        let color: NSColor
    }

    private let model = BoardModel()
    private let captureView = TouchCaptureView()
    private let inkColor = NSColor(
        calibratedRed: 0.55,
        green: 0.78,
        blue: 1.0,
        alpha: 1
    )

    private var currentTool: BoardTool = .pen
    private var currentTouches: [TouchSample] = []
    private var currentDeviceSize = CGSize(width: 1.6, height: 1)
    private var matchedFinger: MTFingerSample?
    private var currentCursorViewPoint: CGPoint?
    private var lastCursorViewPoint: CGPoint?

    private var activeDraft: Draft?
    private var isMouseDown = false
    private var currentPressure: CGFloat = 0
    private var deepForceLatched = false
    private var drawingSuppressedUntilRelease = false
    private var textTriggerLatched = false

    private var paletteAnchor: CGPoint?
    private var textEditor: NSTextField?
    private var textEditorCanvasOrigin: CGPoint?
    private var isEndingTextEdit = false

    private var captureEnabled = true
    private var cursorFrozen = false
    private var pollTimer: Timer?
    private var resignKeyObserver: NSObjectProtocol?
    private weak var observedWindow: NSWindow?

    private let drawThreshold: Double = 0.35
    private let statusHeight: CGFloat = 34

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    init() {
        super.init(frame: .zero)

        wantsLayer = true
        captureView.frame = bounds
        captureView.autoresizingMask = [.width, .height]
        captureView.onEvent = { [weak self] event in
            self?.handle(event)
        }
        addSubview(captureView)

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) {
            [weak self] _ in
            self?.pollMultitouch()
        }
        pollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    required init?(coder: NSCoder) {
        fatalError("BoardTabView does not support NSCoder initialization")
    }

    deinit {
        pollTimer?.invalidate()
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
        }
        restoreCursorAssociation(force: true)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateWindowObservation()

        if window == nil {
            restoreCursorAssociation(force: true)
        } else {
            window?.makeFirstResponder(captureView)
        }
    }

    override func layout() {
        super.layout()
        positionTextEditor()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor(calibratedWhite: 0.075, alpha: 1).setFill()
        NSBezierPath(rect: bounds).fill()

        drawGrid()
        model.elements.forEach { draw(element: $0) }
        drawActiveDraft()
        drawTrackpadOverlay()
        drawCursor()
        drawPalette()
        drawStatusStrip()
    }

    // MARK: - Input

    private func handle(_ event: InputEvent) {
        switch event {
        case let .touches(touches):
            handleTouches(touches)

        case let .pressure(pressure, stage):
            currentPressure = min(1, max(0, CGFloat(pressure)))
            if stage >= 2, !deepForceLatched {
                deepForceLatched = true
                showPalette(at: preferredCursorPoint)
            } else if stage < 2 {
                deepForceLatched = false
            }
            updateSingleTouchInteraction()
            needsDisplay = true

        case let .click(down, locationInView):
            handleClick(down: down, location: locationInView)

        case .drag:
            // Raw touch position, rather than the relative system pointer, drives the board.
            break

        case let .magnify(delta):
            guard currentTouches.count >= 2 else { return }
            cancelActiveDraft()
            model.zoom(by: max(0.01, 1 + CGFloat(delta)), in: bounds)
            positionTextEditor()
            needsDisplay = true

        case let .scroll(dx, dy, _, _):
            guard currentTouches.count >= 2 else { return }
            cancelActiveDraft()
            model.pan(by: CGPoint(x: CGFloat(dx), y: CGFloat(dy)))
            positionTextEditor()
            needsDisplay = true

        case .rotate:
            break

        case let .key(chars, keyCode, modifiers):
            handleKey(chars: chars, keyCode: keyCode, modifiers: modifiers)
        }
    }

    private func handleTouches(_ touches: [TouchSample]) {
        let previousCount = currentTouches.count
        currentTouches = touches

        if let sample = touches.first,
           sample.deviceSize.width > 0,
           sample.deviceSize.height > 0 {
            currentDeviceSize = sample.deviceSize
        }

        if previousCount == 0, !touches.isEmpty {
            freezeCursorIfNeeded()
        }

        switch touches.count {
        case 0:
            finishActiveDraft()
            matchedFinger = nil
            currentCursorViewPoint = nil
            isMouseDown = false
            currentPressure = 0
            deepForceLatched = false
            drawingSuppressedUntilRelease = false
            textTriggerLatched = false
            restoreCursorAssociation(force: true)

        case 1:
            refreshMatchedFinger()
            updateCursorPoint()
            updateSingleTouchInteraction()

        default:
            cancelActiveDraft()
            matchedFinger = nil
            currentCursorViewPoint = nil
            textTriggerLatched = false
        }

        needsDisplay = true
    }

    private func handleClick(down: Bool, location: CGPoint) {
        if down, paletteAnchor != nil {
            if let tool = paletteTool(at: location) {
                selectTool(tool)
            } else {
                paletteAnchor = nil
            }
            needsDisplay = true
            return
        }

        isMouseDown = down
        if !down {
            currentPressure = 0
            deepForceLatched = false
        }
        updateSingleTouchInteraction()
        needsDisplay = true
    }

    private func handleKey(
        chars: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) {
        let significantModifiers = modifiers.intersection(.deviceIndependentFlagsMask)
        let lowercased = chars.lowercased()

        if significantModifiers.contains(.command) {
            if lowercased == "z" {
                cancelActiveDraft()
                _ = model.undo()
                needsDisplay = true
                return
            }

            if keyCode == 51 || keyCode == 117 ||
                chars.unicodeScalars.contains(where: { $0.value == 0x7f }) {
                cancelActiveDraft()
                model.clear()
                needsDisplay = true
                return
            }
        }

        if keyCode == 53 || chars == "\u{1b}" {
            handleEscape()
            return
        }

        if chars == " " {
            captureEnabled.toggle()
            if !captureEnabled {
                restoreCursorAssociation(force: true)
            }
            needsDisplay = true
            return
        }

        if lowercased == "s" {
            if paletteAnchor == nil {
                showPalette(at: preferredCursorPoint)
            } else {
                paletteAnchor = nil
            }
            needsDisplay = true
            return
        }

        if lowercased == "t" {
            selectTool(.text)
            let point = model.viewToCanvas(preferredCursorPoint, in: bounds)
            beginTextEditing(at: point)
            return
        }

        if chars.count == 1,
           let value = Int(chars),
           let tool = BoardTool(rawValue: value) {
            selectTool(tool)
        }
    }

    private func handleEscape() {
        paletteAnchor = nil
        cancelActiveDraft()
        cancelTextEditing()
        captureEnabled = false
        restoreCursorAssociation(force: true)
        needsDisplay = true
    }

    // MARK: - Touch-to-canvas drawing

    private func pollMultitouch() {
        guard currentTouches.count == 1 else {
            matchedFinger = nil
            return
        }

        refreshMatchedFinger()
        updateCursorPoint()
        updateSingleTouchInteraction()
        needsDisplay = true
    }

    private func refreshMatchedFinger() {
        guard MultitouchReader.shared.isAvailable,
              let touch = currentTouches.first else {
            matchedFinger = nil
            return
        }

        matchedFinger = MultitouchReader.shared.fingers.min { lhs, rhs in
            squaredDistance(lhs.pos, touch.pos) < squaredDistance(rhs.pos, touch.pos)
        }
    }

    private func squaredDistance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return dx * dx + dy * dy
    }

    private func updateCursorPoint() {
        guard let touch = currentTouches.first else {
            currentCursorViewPoint = nil
            return
        }

        let point = TrackpadGeometry.map(touch.pos, into: trackpadRect)
        currentCursorViewPoint = point
        lastCursorViewPoint = point
    }

    private var isDrawingRequested: Bool {
        isMouseDown ||
            (MultitouchReader.shared.isAvailable &&
             (matchedFinger?.size ?? 0) >= drawThreshold)
    }

    private var forceAdjustedWidth: CGFloat {
        let forceNorm: CGFloat
        if isMouseDown {
            forceNorm = currentPressure
        } else {
            forceNorm = min(1, CGFloat((matchedFinger?.size ?? 0) / 1.5))
        }
        return 2 + 6 * forceNorm
    }

    private func updateSingleTouchInteraction() {
        guard currentTouches.count == 1,
              let cursorPoint = currentCursorViewPoint else { return }

        guard paletteAnchor == nil, textEditor == nil else {
            cancelActiveDraft()
            return
        }

        guard isDrawingRequested else {
            finishActiveDraft()
            drawingSuppressedUntilRelease = false
            textTriggerLatched = false
            return
        }

        guard !drawingSuppressedUntilRelease else { return }

        let canvasPoint = model.viewToCanvas(cursorPoint, in: bounds)
        if currentTool == .text {
            guard !textTriggerLatched else { return }
            textTriggerLatched = true
            beginTextEditing(at: canvasPoint)
            return
        }

        let width = forceAdjustedWidth
        if activeDraft == nil {
            activeDraft = Draft(
                tool: currentTool,
                start: canvasPoint,
                current: canvasPoint,
                points: [canvasPoint],
                width: width,
                widthSampleCount: 1,
                color: inkColor
            )
            needsDisplay = true
            return
        }

        guard var draft = activeDraft else { return }
        guard draft.tool == currentTool else {
            cancelActiveDraft()
            return
        }

        draft.current = canvasPoint
        if draft.tool == .pen {
            let minimumStep = 0.6 / model.zoom
            if let last = draft.points.last,
               hypot(last.x - canvasPoint.x, last.y - canvasPoint.y) >= minimumStep {
                draft.points.append(canvasPoint)
                let count = CGFloat(draft.widthSampleCount)
                draft.width = (draft.width * count + width) / (count + 1)
                draft.widthSampleCount += 1
            }
        } else {
            draft.width = width
        }
        activeDraft = draft
        needsDisplay = true
    }

    private func finishActiveDraft() {
        guard let draft = activeDraft else { return }
        activeDraft = nil

        switch draft.tool {
        case .pen:
            model.append(
                .stroke(
                    points: draft.points,
                    width: draft.width,
                    color: draft.color
                )
            )
        case .line:
            model.append(
                .line(
                    start: draft.start,
                    end: draft.current,
                    width: draft.width,
                    color: draft.color
                )
            )
        case .rectangle:
            model.append(
                .rectangle(
                    rect: rect(from: draft.start, to: draft.current),
                    width: draft.width,
                    color: draft.color
                )
            )
        case .ellipse:
            model.append(
                .ellipse(
                    rect: rect(from: draft.start, to: draft.current),
                    width: draft.width,
                    color: draft.color
                )
            )
        case .arrow:
            model.append(
                .arrow(
                    start: draft.start,
                    end: draft.current,
                    width: draft.width,
                    color: draft.color
                )
            )
        case .text:
            break
        }
    }

    private func cancelActiveDraft() {
        activeDraft = nil
        needsDisplay = true
    }

    private func selectTool(_ tool: BoardTool) {
        cancelActiveDraft()
        currentTool = tool
        paletteAnchor = nil
        if isDrawingRequested {
            drawingSuppressedUntilRelease = true
        }
        needsDisplay = true
    }

    // MARK: - Text

    private func beginTextEditing(at canvasPoint: CGPoint) {
        if textEditor != nil {
            commitTextEditing()
        }

        let editor = NSTextField()
        editor.isBordered = false
        editor.isBezeled = false
        editor.drawsBackground = true
        editor.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.96)
        editor.textColor = inkColor
        editor.focusRingType = .none
        editor.placeholderString = "Type…"
        editor.delegate = self
        editor.cell?.isScrollable = true
        editor.cell?.wraps = false
        editor.cell?.lineBreakMode = .byClipping

        textEditor = editor
        textEditorCanvasOrigin = canvasPoint
        drawingSuppressedUntilRelease = true
        addSubview(editor)
        positionTextEditor()
        window?.makeFirstResponder(editor)
        needsDisplay = true
    }

    private func positionTextEditor() {
        guard let editor = textEditor,
              let origin = textEditorCanvasOrigin else { return }

        let viewPoint = model.canvasToView(origin, in: bounds)
        let fontSize = max(3, 16 * model.zoom)
        let font = NSFont.systemFont(ofSize: fontSize)
        editor.font = font

        let editorHeight = max(26, ceil(font.ascender - font.descender + 10))
        let editorWidth = min(360, max(140, bounds.width * 0.34))
        let x = min(
            max(10, viewPoint.x),
            max(10, bounds.maxX - editorWidth - 10)
        )
        let y = min(
            max(statusHeight + 8, viewPoint.y - 4),
            max(statusHeight + 8, bounds.maxY - editorHeight - 8)
        )
        editor.frame = CGRect(
            x: x,
            y: y,
            width: editorWidth,
            height: editorHeight
        )
    }

    private func commitTextEditing() {
        guard !isEndingTextEdit,
              let editor = textEditor,
              let origin = textEditorCanvasOrigin else { return }

        isEndingTextEdit = true
        let string = editor.stringValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        textEditor = nil
        textEditorCanvasOrigin = nil
        editor.delegate = nil
        editor.removeFromSuperview()

        if !string.isEmpty {
            model.append(
                .text(
                    origin: origin,
                    string: string,
                    fontSize: 16,
                    color: inkColor
                )
            )
        }
        window?.makeFirstResponder(captureView)
        isEndingTextEdit = false
        needsDisplay = true
    }

    private func cancelTextEditing() {
        guard !isEndingTextEdit, let editor = textEditor else { return }

        isEndingTextEdit = true
        textEditor = nil
        textEditorCanvasOrigin = nil
        editor.delegate = nil
        editor.removeFromSuperview()
        window?.makeFirstResponder(captureView)
        isEndingTextEdit = false
        needsDisplay = true
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitTextEditing()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            handleEscape()
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === textEditor else { return }
        commitTextEditing()
    }

    // MARK: - Capture safety

    private func freezeCursorIfNeeded() {
        guard captureEnabled,
              window?.isKeyWindow == true,
              !cursorFrozen else { return }

        _ = CGAssociateMouseAndMouseCursorPosition(0)
        cursorFrozen = true
    }

    private func restoreCursorAssociation(force: Bool) {
        guard force || cursorFrozen else { return }
        _ = CGAssociateMouseAndMouseCursorPosition(1)
        cursorFrozen = false
    }

    private func updateWindowObservation() {
        guard observedWindow !== window else { return }

        restoreCursorAssociation(force: true)
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
            self.resignKeyObserver = nil
        }

        observedWindow = window
        guard let window else { return }
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.restoreCursorAssociation(force: true)
        }
    }

    // MARK: - Palette

    private var preferredCursorPoint: CGPoint {
        currentCursorViewPoint ??
            lastCursorViewPoint ??
            CGPoint(x: bounds.midX, y: bounds.midY)
    }

    private func showPalette(at point: CGPoint) {
        cancelActiveDraft()
        paletteAnchor = point
        drawingSuppressedUntilRelease = isDrawingRequested
        needsDisplay = true
    }

    private var paletteRect: CGRect? {
        guard let anchor = paletteAnchor else { return nil }

        let itemWidth: CGFloat = 74
        let width = itemWidth * CGFloat(BoardTool.allCases.count) + 12
        let height: CGFloat = 52
        var x = anchor.x - width / 2
        var y = anchor.y + 18

        x = min(max(12, x), max(12, bounds.maxX - width - 12))
        if y + height > bounds.maxY - 12 {
            y = anchor.y - height - 18
        }
        y = min(
            max(statusHeight + 12, y),
            max(statusHeight + 12, bounds.maxY - height - 12)
        )
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func paletteItemRects() -> [(BoardTool, CGRect)] {
        guard let paletteRect else { return [] }
        let itemWidth: CGFloat = 74
        return BoardTool.allCases.map { tool in
            let rect = CGRect(
                x: paletteRect.minX + 6 + CGFloat(tool.rawValue - 1) * itemWidth,
                y: paletteRect.minY + 6,
                width: itemWidth,
                height: paletteRect.height - 12
            )
            return (tool, rect)
        }
    }

    private func paletteTool(at point: CGPoint) -> BoardTool? {
        paletteItemRects().first(where: { $0.1.contains(point) })?.0
    }

    // MARK: - Rendering

    private var trackpadRect: CGRect {
        TrackpadGeometry.padRect(
            in: bounds,
            deviceSize: currentDeviceSize,
            fraction: 0.7
        )
    }

    private func drawGrid() {
        guard bounds.width > 0, bounds.height > 0 else { return }

        let corners = [
            CGPoint(x: bounds.minX, y: bounds.minY),
            CGPoint(x: bounds.maxX, y: bounds.minY),
            CGPoint(x: bounds.minX, y: bounds.maxY),
            CGPoint(x: bounds.maxX, y: bounds.maxY),
        ].map { model.viewToCanvas($0, in: bounds) }

        let minimumX = corners.map(\.x).min() ?? 0
        let maximumX = corners.map(\.x).max() ?? 0
        let minimumY = corners.map(\.y).min() ?? 0
        let maximumY = corners.map(\.y).max() ?? 0
        let spacing: CGFloat = 40
        let path = NSBezierPath()

        var x = floor(minimumX / spacing) * spacing
        while x <= maximumX {
            let a = model.canvasToView(
                CGPoint(x: x, y: minimumY),
                in: bounds
            )
            let b = model.canvasToView(
                CGPoint(x: x, y: maximumY),
                in: bounds
            )
            path.move(to: a)
            path.line(to: b)
            x += spacing
        }

        var y = floor(minimumY / spacing) * spacing
        while y <= maximumY {
            let a = model.canvasToView(
                CGPoint(x: minimumX, y: y),
                in: bounds
            )
            let b = model.canvasToView(
                CGPoint(x: maximumX, y: y),
                in: bounds
            )
            path.move(to: a)
            path.line(to: b)
            y += spacing
        }

        NSColor(calibratedWhite: 1, alpha: 0.035).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func draw(element: BoardElement, alpha: CGFloat = 1) {
        switch element {
        case let .stroke(points, width, color):
            drawStroke(
                points: points,
                width: width,
                color: color.withAlphaComponent(alpha)
            )

        case let .line(start, end, width, color):
            drawLine(
                start: start,
                end: end,
                width: width,
                color: color.withAlphaComponent(alpha)
            )

        case let .rectangle(rect, width, color):
            let path = NSBezierPath(
                roundedRect: model.canvasToView(rect, in: bounds),
                xRadius: 3 * model.zoom,
                yRadius: 3 * model.zoom
            )
            stroke(
                path,
                width: width,
                color: color.withAlphaComponent(alpha)
            )

        case let .ellipse(rect, width, color):
            let path = NSBezierPath(
                ovalIn: model.canvasToView(rect, in: bounds)
            )
            stroke(
                path,
                width: width,
                color: color.withAlphaComponent(alpha)
            )

        case let .arrow(start, end, width, color):
            drawArrow(
                start: start,
                end: end,
                width: width,
                color: color.withAlphaComponent(alpha)
            )

        case let .text(origin, string, fontSize, color):
            let point = model.canvasToView(origin, in: bounds)
            let font = NSFont.systemFont(
                ofSize: max(1, fontSize * model.zoom),
                weight: .medium
            )
            (string as NSString).draw(
                at: point,
                withAttributes: [
                    .font: font,
                    .foregroundColor: color.withAlphaComponent(alpha),
                ]
            )
        }
    }

    private func drawActiveDraft() {
        guard let draft = activeDraft else { return }

        let element: BoardElement
        switch draft.tool {
        case .pen:
            element = .stroke(
                points: draft.points,
                width: draft.width,
                color: draft.color
            )
        case .line:
            element = .line(
                start: draft.start,
                end: draft.current,
                width: draft.width,
                color: draft.color
            )
        case .rectangle:
            element = .rectangle(
                rect: rect(from: draft.start, to: draft.current),
                width: draft.width,
                color: draft.color
            )
        case .ellipse:
            element = .ellipse(
                rect: rect(from: draft.start, to: draft.current),
                width: draft.width,
                color: draft.color
            )
        case .arrow:
            element = .arrow(
                start: draft.start,
                end: draft.current,
                width: draft.width,
                color: draft.color
            )
        case .text:
            return
        }
        draw(element: element, alpha: 0.72)
    }

    private func drawStroke(
        points: [CGPoint],
        width: CGFloat,
        color: NSColor
    ) {
        guard let first = points.first else { return }

        if points.count == 1 {
            let point = model.canvasToView(first, in: bounds)
            let diameter = max(1, width * model.zoom)
            color.setFill()
            NSBezierPath(
                ovalIn: CGRect(
                    x: point.x - diameter / 2,
                    y: point.y - diameter / 2,
                    width: diameter,
                    height: diameter
                )
            ).fill()
            return
        }

        let path = NSBezierPath()
        path.move(to: model.canvasToView(first, in: bounds))
        for point in points.dropFirst() {
            path.line(to: model.canvasToView(point, in: bounds))
        }
        stroke(path, width: width, color: color)
    }

    private func drawLine(
        start: CGPoint,
        end: CGPoint,
        width: CGFloat,
        color: NSColor
    ) {
        let path = NSBezierPath()
        path.move(to: model.canvasToView(start, in: bounds))
        path.line(to: model.canvasToView(end, in: bounds))
        stroke(path, width: width, color: color)
    }

    private func drawArrow(
        start: CGPoint,
        end: CGPoint,
        width: CGFloat,
        color: NSColor
    ) {
        let viewStart = model.canvasToView(start, in: bounds)
        let viewEnd = model.canvasToView(end, in: bounds)
        let dx = viewEnd.x - viewStart.x
        let dy = viewEnd.y - viewStart.y
        let length = hypot(dx, dy)

        let path = NSBezierPath()
        path.move(to: viewStart)
        path.line(to: viewEnd)

        if length > .ulpOfOne {
            let angle = atan2(dy, dx)
            let headLength = min(14 * model.zoom, length * 0.45)
            let spread = CGFloat.pi / 6
            path.move(to: viewEnd)
            path.line(
                to: CGPoint(
                    x: viewEnd.x - cos(angle - spread) * headLength,
                    y: viewEnd.y - sin(angle - spread) * headLength
                )
            )
            path.move(to: viewEnd)
            path.line(
                to: CGPoint(
                    x: viewEnd.x - cos(angle + spread) * headLength,
                    y: viewEnd.y - sin(angle + spread) * headLength
                )
            )
        }
        stroke(path, width: width, color: color)
    }

    private func stroke(
        _ path: NSBezierPath,
        width: CGFloat,
        color: NSColor
    ) {
        color.setStroke()
        path.lineWidth = max(0.2, width * model.zoom)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private func drawTrackpadOverlay() {
        let rect = trackpadRect
        let path = NSBezierPath(
            roundedRect: rect,
            xRadius: 18,
            yRadius: 18
        )

        NSColor(calibratedWhite: 0.75, alpha: 0.025).setFill()
        path.fill()
        NSColor(calibratedWhite: 0.88, alpha: 0.26).setStroke()
        path.lineWidth = 1.2
        path.stroke()

        drawLabel(
            "trackpad",
            at: CGPoint(x: rect.minX + 13, y: rect.maxY - 24),
            font: .systemFont(ofSize: 11, weight: .medium),
            color: NSColor(calibratedWhite: 0.88, alpha: 0.48)
        )
    }

    private func drawCursor() {
        guard let point = currentCursorViewPoint,
              currentTouches.count == 1 else { return }

        let drawing = isDrawingRequested
        let outerDiameter: CGFloat = drawing ? 18 : 14
        let outerRect = CGRect(
            x: point.x - outerDiameter / 2,
            y: point.y - outerDiameter / 2,
            width: outerDiameter,
            height: outerDiameter
        )

        (drawing ? inkColor : NSColor.white)
            .withAlphaComponent(drawing ? 0.20 : 0.12)
            .setFill()
        NSBezierPath(ovalIn: outerRect).fill()

        let innerDiameter: CGFloat = drawing ? 7 : 5
        let innerRect = CGRect(
            x: point.x - innerDiameter / 2,
            y: point.y - innerDiameter / 2,
            width: innerDiameter,
            height: innerDiameter
        )
        (drawing ? inkColor : NSColor.white)
            .withAlphaComponent(0.92)
            .setFill()
        NSBezierPath(ovalIn: innerRect).fill()
    }

    private func drawPalette() {
        guard let rect = paletteRect else { return }

        let shadow = NSShadow()
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = CGSize(width: 0, height: -5)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.48)

        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        let background = NSBezierPath(
            roundedRect: rect,
            xRadius: 11,
            yRadius: 11
        )
        NSColor(calibratedWhite: 0.12, alpha: 0.98).setFill()
        background.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor(calibratedWhite: 1, alpha: 0.12).setStroke()
        background.lineWidth = 1
        background.stroke()

        for (tool, itemRect) in paletteItemRects() {
            if tool == currentTool {
                inkColor.withAlphaComponent(0.15).setFill()
                NSBezierPath(
                    roundedRect: itemRect.insetBy(dx: 2, dy: 2),
                    xRadius: 7,
                    yRadius: 7
                ).fill()
            }

            drawLabel(
                "\(tool.rawValue)",
                at: CGPoint(x: itemRect.midX - 3, y: itemRect.minY + 22),
                font: .monospacedDigitSystemFont(ofSize: 11, weight: .bold),
                color: tool == currentTool
                    ? inkColor
                    : NSColor(calibratedWhite: 0.92, alpha: 0.75)
            )

            let nameSize = (tool.name as NSString).size(
                withAttributes: [.font: NSFont.systemFont(ofSize: 9)]
            )
            drawLabel(
                tool.name,
                at: CGPoint(
                    x: itemRect.midX - nameSize.width / 2,
                    y: itemRect.minY + 7
                ),
                font: .systemFont(ofSize: 9),
                color: NSColor(calibratedWhite: 0.88, alpha: 0.72)
            )
        }
    }

    private func drawStatusStrip() {
        let rect = CGRect(
            x: bounds.minX,
            y: bounds.minY,
            width: bounds.width,
            height: statusHeight
        )
        NSColor(calibratedWhite: 0.055, alpha: 0.97).setFill()
        NSBezierPath(rect: rect).fill()

        NSColor(calibratedWhite: 1, alpha: 0.08).setStroke()
        let separator = NSBezierPath()
        separator.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        separator.line(to: CGPoint(x: rect.maxX, y: rect.maxY))
        separator.lineWidth = 1
        separator.stroke()

        let captureText = captureEnabled ? "capture on" : "capture off"
        let left = "\(currentTool.name)   \(Int((model.zoom * 100).rounded()))%   \(captureText)"
        drawLabel(
            left,
            at: CGPoint(x: 14, y: 10),
            font: .systemFont(ofSize: 11, weight: .medium),
            color: captureEnabled
                ? NSColor(calibratedWhite: 0.9, alpha: 0.82)
                : NSColor.systemOrange.withAlphaComponent(0.9)
        )

        let hints = "1–6 tools   S palette   T text   ⌘Z undo   ⌘⌫ clear   Space capture   Esc release"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
        ]
        let hintWidth = (hints as NSString).size(withAttributes: attributes).width
        drawLabel(
            hints,
            at: CGPoint(x: max(220, rect.maxX - hintWidth - 14), y: 10),
            font: .systemFont(ofSize: 10),
            color: NSColor(calibratedWhite: 0.82, alpha: 0.58)
        )
    }

    private func drawLabel(
        _ string: String,
        at point: CGPoint,
        font: NSFont,
        color: NSColor
    ) {
        (string as NSString).draw(
            at: point,
            withAttributes: [
                .font: font,
                .foregroundColor: color,
            ]
        )
    }

    private func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }
}
