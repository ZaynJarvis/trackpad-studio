import AppKit
import CoreGraphics

final class BoardTabView: NSView, NSTextFieldDelegate {
    /// Zen mode = distraction-free drawing: trackpad touches drive the app
    /// cursor, the system pointer is frozen (and hidden) so the finger owns the
    /// board. Pointer mode hands the machine back to macOS.
    private enum InteractionMode {
        case zen
        case pointer

        var badge: String {
            switch self {
            case .zen: return "ZEN"
            case .pointer: return "POINTER"
            }
        }
    }

    private struct Draft {
        let tool: BoardTool
        let start: CGPoint
        var current: CGPoint
        var strokeSamples: [BoardStrokeSample]
        var width: CGFloat
        let color: NSColor
    }

    /// Previous-frame state of a raw two-finger gesture, kept in NORMALIZED pad
    /// coordinates. Storing view-space points here would silently corrupt the
    /// gesture whenever the pad rect changed mid-gesture (device-size discovery,
    /// window resize) — the baseline would be expressed in a rect that no
    /// longer exists.
    private struct TwoFingerBaseline {
        var centroid: CGPoint
        var spread: CGFloat
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
    /// Active touches only — every gesture rule counts off this array, so a
    /// resting thumb or palm can never reach the state machine.
    private var currentTouches: [TouchSample] = []
    /// Resting touches, render-only.
    private var restingTouches: [TouchSample] = []
    // Seeded from the last device we saw, so the pad rect is already the right
    // shape at launch instead of snapping on the first touch.
    private var currentDeviceSize = DeviceSizeStore.recalled
        ?? CGSize(width: 1.6, height: 1)
    private var matchedFinger: MTFingerSample?
    private var currentCursorViewPoint: CGPoint?
    private var lastCursorViewPoint: CGPoint?

    private var activeDraft: Draft?
    private var isMouseDown = false
    private var currentPressure: CGFloat = 0
    private var drawingSuppressedUntilRelease = false

    private var textEditor: NSTextField?
    private var textEditorCanvasOrigin: CGPoint?
    private var isEndingTextEdit = false

    private var twoFingerBaseline: TwoFingerBaseline?
    private var isTwoFingerNavigating = false
    private var isThreeFingerDrawing = false
    /// Identity of the finger acting as the pen for the current 3-finger
    /// gesture. Locked at gesture start, never re-elected mid-gesture.
    private var penFingerID: Int?

    private var interactionMode: InteractionMode = .zen
    private var cursorFrozen = false
    private var cursorTrackingArea: NSTrackingArea?
    private lazy var transparentCursor = Self.makeTransparentCursor()
    private var pollTimer: Timer?
    private var windowObservers: [NSObjectProtocol] = []
    private weak var observedWindow: NSWindow?
    /// Set when zen was interrupted by losing key focus, so it can be restored.
    private var resumeZenOnKey = false

    private let drawThreshold: Double = 0.35
    private let statusHeight: CGFloat = 34
    private let toolbarWidth: CGFloat = 56
    private let toolbarItemHeight: CGFloat = 46
    private let textButtonGap: CGFloat = 14
    private let edgeInset: CGFloat = 12
    /// On-screen point size of text at the moment it is typed.
    private let textBaseFontSize: CGFloat = 16
    /// Offset from the text editor's frame origin to where its glyphs actually sit.
    private let textEditorTextInset = CGSize(width: 2, height: 5)

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
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        restoreCursorAssociation(force: true)
        NSCursor.arrow.set()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateWindowObservation()

        if window == nil {
            enterPointerMode()
        } else {
            enterZenMode()
            window?.makeFirstResponder(captureView)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTrackingArea {
            removeTrackingArea(cursorTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [
                .activeInKeyWindow,
                .inVisibleRect,
                .cursorUpdate,
                .mouseEnteredAndExited,
            ],
            owner: self,
            userInfo: nil
        )
        cursorTrackingArea = trackingArea
        addTrackingArea(trackingArea)
    }

    override func cursorUpdate(with event: NSEvent) {
        if interactionMode == .zen, window?.isKeyWindow == true {
            transparentCursor.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        applySystemCursorForCurrentMode()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
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
        drawEmptyStateHint()
        drawTrackpadOverlay()
        drawTouchMarkers()
        drawToolbar()
        drawCursor()
        drawStatusStrip()
    }

    // MARK: - Input

    private func handle(_ event: InputEvent) {
        switch event {
        case let .touches(touches):
            handleTouches(touches)

        case let .pressure(pressure, _):
            // Pressure only drives stroke width now — deep press does nothing.
            currentPressure = min(1, max(0, CGFloat(pressure)))
            if interactionMode == .zen {
                updateSingleTouchInteraction()
            }
            needsDisplay = true

        case let .click(down, locationInView):
            handleClick(down: down, location: locationInView)

        case .drag:
            break

        case let .magnify(delta):
            // Zen mode navigates from raw two-finger touches instead — applying
            // the system gesture too would double-count it.
            guard interactionMode == .pointer else { return }
            model.zoom(by: max(0.01, 1 + CGFloat(delta)), in: bounds)
            positionTextEditor()
            needsDisplay = true

        case let .scroll(dx, dy, _, _):
            guard interactionMode == .pointer else { return }
            // scrollingDelta is expressed for a y-DOWN content system and
            // already carries the user's natural-scroll preference. This view
            // is y-up, so Y (and only Y) needs negating for the content to
            // follow the fingers. X is already correct.
            model.pan(by: CGPoint(x: CGFloat(dx), y: -CGFloat(dy)))
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
        currentTouches = touches.filter { !$0.resting }
        restingTouches = touches.filter(\.resting)

        // Device size still comes from the raw set: a resting-only frame
        // carries a perfectly good deviceSize. Persist it so the next launch
        // starts with the pad rect already correct.
        if let sample = touches.first,
           sample.deviceSize.width > 0,
           sample.deviceSize.height > 0,
           sample.deviceSize != currentDeviceSize {
            currentDeviceSize = sample.deviceSize
            DeviceSizeStore.remember(sample.deviceSize)
        }

        // Every count transition below is in terms of ACTIVE touches only.
        let activeCount = currentTouches.count

        if activeCount != 2 {
            endTwoFingerNavigation()
        }
        if previousCount == 3, activeCount != 3 {
            endThreeFingerDraw()
        }

        if interactionMode == .zen,
           previousCount == 0,
           activeCount > 0 {
            freezeCursorIfNeeded()
        }

        switch activeCount {
        case 0:
            if interactionMode == .zen {
                finishActiveDraft()
            } else {
                cancelActiveDraft()
            }

            matchedFinger = nil
            currentCursorViewPoint = nil
            isMouseDown = false
            resetPressureState()
            drawingSuppressedUntilRelease = false
            restoreCursorAssociation(force: true)

        case 1:
            guard interactionMode == .zen else {
                cancelActiveDraft()
                matchedFinger = nil
                currentCursorViewPoint = nil
                restoreCursorAssociation(force: true)
                needsDisplay = true
                return
            }

            refreshMatchedFinger()
            updateCursorPoint()
            updateSingleTouchInteraction()

        case 2:
            resetMultiTouchState()
            if previousCount != 2 {
                twoFingerBaseline = nil
            }
            if interactionMode == .zen {
                updateTwoFingerNavigation()
            }

        case 3:
            matchedFinger = nil
            if previousCount != 3 {
                // A draft from a different gesture must not bleed into this one.
                cancelActiveDraft()
                penFingerID = nil
            }
            // Once a 3-finger gesture has ended (the pen finger lifted while a
            // replacement kept the count at 3), don't silently start a new one
            // until the count leaves 3.
            if interactionMode == .zen,
               textEditor == nil,
               previousCount != 3 || isThreeFingerDrawing {
                updateThreeFingerDraw()
            } else if textEditor != nil {
                cancelActiveDraft()
                currentCursorViewPoint = nil
            }

        default:
            resetMultiTouchState()
        }

        needsDisplay = true
    }

    private func resetMultiTouchState() {
        cancelActiveDraft()
        matchedFinger = nil
        currentCursorViewPoint = nil
    }

    private func handleClick(down: Bool, location: CGPoint) {
        guard interactionMode == .zen else {
            isMouseDown = false
            resetPressureState()
            if down { handleToolbarClick(at: location) }
            return
        }

        // In zen mode the system pointer is frozen, so hit-testing must use the
        // finger-driven app cursor whenever a touch is present.
        let hitPoint = currentTouches.isEmpty ? location : preferredCursorPoint

        if down {
            isMouseDown = true
            if handleToolbarClick(at: hitPoint) {
                needsDisplay = true
                return
            }
            updateSingleTouchInteraction()
            needsDisplay = true
            return
        }

        isMouseDown = false
        resetPressureState()
        updateSingleTouchInteraction()
        needsDisplay = true
    }

    /// Left toolbar hit: a drawing tool, or the separated one-shot text button.
    @discardableResult
    private func handleToolbarClick(at point: CGPoint) -> Bool {
        if textButtonRect.contains(point) {
            beginTextEditing(atViewPoint: preferredCursorPoint)
            return true
        }
        if let tool = toolbarTool(at: point) {
            selectTool(tool)
            return true
        }
        return false
    }

    private func handleKey(
        chars: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) {
        // While the text field owns the keyboard, every key is literal input —
        // Esc/Enter reach us through the NSControl command selectors instead.
        guard textEditor == nil else { return }

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

        if lowercased == "t" {
            guard interactionMode == .zen else { return }
            // One-shot action: the active drawing tool is untouched.
            beginTextEditing(atViewPoint: preferredCursorPoint)
            return
        }

        if chars.count == 1,
           let value = Int(chars),
           let tool = BoardTool(rawValue: value) {
            selectTool(tool)
        }
    }

    /// Esc is the only mode key: it peels off the text editor, and otherwise
    /// toggles zen ⇄ pointer.
    private func handleEscape() {
        if textEditor != nil {
            cancelTextEditing()
            return
        }

        if interactionMode == .zen {
            enterPointerMode()
        } else {
            enterZenMode()
        }
    }

    // MARK: - Touch-to-canvas drawing

    private func pollMultitouch() {
        guard interactionMode == .zen,
              currentTouches.count == 1 else {
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
        interactionMode == .zen &&
            (isMouseDown ||
            (MultitouchReader.shared.isAvailable &&
             (matchedFinger?.size ?? 0) >= drawThreshold))
    }

    private var currentForceNorm: CGFloat {
        if isMouseDown {
            return currentPressure
        }
        return min(1, CGFloat((matchedFinger?.size ?? 0) / 1.5))
    }

    private func strokeWidth(forForce force: CGFloat) -> CGFloat {
        2 + 6 * min(1, max(0, force))
    }

    private var forceAdjustedWidth: CGFloat {
        strokeWidth(forForce: currentForceNorm)
    }

    private var fullForceWidth: CGFloat {
        strokeWidth(forForce: 1)
    }

    private func updateSingleTouchInteraction() {
        guard interactionMode == .zen,
              currentTouches.count == 1,
              let cursorPoint = currentCursorViewPoint else { return }

        guard textEditor == nil else {
            cancelActiveDraft()
            return
        }

        guard isDrawingRequested else {
            finishActiveDraft()
            drawingSuppressedUntilRelease = false
            return
        }

        guard !drawingSuppressedUntilRelease else { return }

        let canvasPoint = model.viewToCanvas(cursorPoint, in: bounds)
        let width = forceAdjustedWidth
        if activeDraft == nil {
            activeDraft = Draft(
                tool: currentTool,
                start: canvasPoint,
                current: canvasPoint,
                strokeSamples: [
                    BoardStrokeSample(point: canvasPoint, width: width),
                ],
                width: width,
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
            if let last = draft.strokeSamples.last,
               hypot(
                   last.point.x - canvasPoint.x,
                   last.point.y - canvasPoint.y
               ) >= minimumStep {
                // Light EMA on position and width: the raw stream is noisy at
                // sub-point spacing and shows up as visible chatter.
                let smoothedPoint = CGPoint(
                    x: last.point.x * 0.35 + canvasPoint.x * 0.65,
                    y: last.point.y * 0.35 + canvasPoint.y * 0.65
                )
                draft.strokeSamples.append(
                    BoardStrokeSample(
                        point: smoothedPoint,
                        width: last.width * 0.7 + width * 0.3
                    )
                )
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
                    samples: draft.strokeSamples,
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
        }
    }

    private func cancelActiveDraft() {
        activeDraft = nil
        needsDisplay = true
    }

    private func selectTool(_ tool: BoardTool) {
        cancelActiveDraft()
        currentTool = tool
        if isDrawingRequested {
            drawingSuppressedUntilRelease = true
        }
        needsDisplay = true
    }

    // MARK: - Two-finger navigation (raw touches)

    /// Derives pan and zoom from the same pair of raw touches every frame, so
    /// both apply simultaneously — unlike the system gestures, where a
    /// recognized pinch stops the scroll stream. There is deliberately NO
    /// dominant-axis test, no gesture classification and no threshold that
    /// latches one component: every frame applies whatever translation and
    /// whatever scale the fingers actually show.
    private func updateTwoFingerNavigation() {
        guard currentTouches.count == 2 else {
            endTwoFingerNavigation()
            return
        }

        // Normalized pad space — see TwoFingerBaseline.
        let p0 = currentTouches[0].pos
        let p1 = currentTouches[1].pos
        let centroid = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
        let spread = hypot(p1.x - p0.x, p1.y - p0.y)

        defer {
            twoFingerBaseline = TwoFingerBaseline(centroid: centroid, spread: spread)
            isTwoFingerNavigating = true
        }

        // No baseline yet (1→2, 3→2, gesture start): adopt it without moving.
        guard let baseline = twoFingerBaseline else { return }

        let rect = trackpadRect
        // Both baseline and current are mapped through the SAME current rect,
        // so a rect change between frames can't inject a phantom pan.
        let previousCentroid = TrackpadGeometry.map(baseline.centroid, into: rect)
        let currentCentroid = TrackpadGeometry.map(centroid, into: rect)

        let factor: CGFloat = (baseline.spread > 0.01 && spread > 0.01)
            ? min(2, max(0.5, spread / baseline.spread))
            : 1
        let anchor = model.viewToCanvas(previousCentroid, in: bounds)
        model.navigate(scale: factor, anchor: anchor, to: currentCentroid, in: bounds)
        positionTextEditor()
    }

    private func endTwoFingerNavigation() {
        twoFingerBaseline = nil
        isTwoFingerNavigating = false
    }

    // MARK: - Three-finger force draw

    /// Three fingers draw with the active tool at full force, no click and no
    /// per-finger size threshold. The pen is the LEFTMOST finger at gesture
    /// start and stays locked to that identity until release — a finger drifting
    /// further left mid-stroke must not steal the pen.
    private func updateThreeFingerDraw() {
        guard currentTouches.count == 3 else { return }

        if penFingerID == nil {
            penFingerID = currentTouches.min(by: { $0.pos.x < $1.pos.x })?.id
        }
        guard let penID = penFingerID,
              let pen = currentTouches.first(where: { $0.id == penID }) else {
            // The pen finger lifted (replaced by another) — that ends the
            // gesture and commits, exactly like dropping below three.
            endThreeFingerDraw()
            return
        }

        let penPoint = TrackpadGeometry.map(pen.pos, into: trackpadRect)
        currentCursorViewPoint = penPoint
        lastCursorViewPoint = penPoint
        isThreeFingerDrawing = true

        let canvasPoint = model.viewToCanvas(penPoint, in: bounds)
        let width = fullForceWidth

        guard var draft = activeDraft, draft.tool == currentTool else {
            activeDraft = Draft(
                tool: currentTool,
                start: canvasPoint,
                current: canvasPoint,
                strokeSamples: [BoardStrokeSample(point: canvasPoint, width: width)],
                width: width,
                color: inkColor
            )
            return
        }

        draft.current = canvasPoint
        if draft.tool == .pen {
            let minimumStep = 0.6 / model.zoom
            if let last = draft.strokeSamples.last,
               hypot(
                   last.point.x - canvasPoint.x,
                   last.point.y - canvasPoint.y
               ) >= minimumStep {
                draft.strokeSamples.append(
                    BoardStrokeSample(
                        point: CGPoint(
                            x: last.point.x * 0.35 + canvasPoint.x * 0.65,
                            y: last.point.y * 0.35 + canvasPoint.y * 0.65
                        ),
                        width: width
                    )
                )
            }
        } else {
            draft.width = width
        }
        activeDraft = draft
    }

    /// Dropping below three fingers commits the element rather than discarding it.
    private func endThreeFingerDraw() {
        penFingerID = nil
        guard isThreeFingerDrawing else { return }
        isThreeFingerDrawing = false
        currentCursorViewPoint = nil
        guard interactionMode == .zen else {
            cancelActiveDraft()
            return
        }
        finishActiveDraft()
        // Fingers lift one at a time; don't let the survivor restart a stroke.
        drawingSuppressedUntilRelease = true
    }

    // MARK: - Text

    private func beginTextEditing(atViewPoint viewPoint: CGPoint) {
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
        textEditorCanvasOrigin = model.viewToCanvas(viewPoint, in: bounds)
        drawingSuppressedUntilRelease = true
        addSubview(editor)
        positionTextEditor()
        window?.makeFirstResponder(editor)
        needsDisplay = true
    }

    /// The editor lives in view space, so it always renders at the base point
    /// size; only its anchor follows the canvas.
    private func positionTextEditor() {
        guard let editor = textEditor,
              let origin = textEditorCanvasOrigin else { return }

        let viewPoint = model.canvasToView(origin, in: bounds)
        let font = NSFont.systemFont(ofSize: textBaseFontSize, weight: .medium)
        editor.font = font

        let editorHeight = max(26, ceil(font.ascender - font.descender + 10))
        let editorWidth = min(360, max(160, bounds.width * 0.32))
        let minimumX = contentRect.minX
        let x = min(
            max(minimumX, viewPoint.x - textEditorTextInset.width),
            max(minimumX, bounds.maxX - editorWidth - edgeInset)
        )
        let minimumY = statusHeight + 8
        let y = min(
            max(minimumY, viewPoint.y - textEditorTextInset.height),
            max(minimumY, bounds.maxY - editorHeight - 8)
        )
        editor.frame = CGRect(
            x: x,
            y: y,
            width: editorWidth,
            height: editorHeight
        )
    }

    private func commitTextEditing() {
        guard !isEndingTextEdit, let editor = textEditor else { return }

        isEndingTextEdit = true
        let string = editor.stringValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let editorFrame = editor.frame
        textEditor = nil
        textEditorCanvasOrigin = nil
        editor.delegate = nil
        editor.removeFromSuperview()

        if !string.isEmpty {
            // Commit where the glyphs actually sat (the editor may have been
            // clamped into the view), at the size they were shown.
            let glyphOrigin = CGPoint(
                x: editorFrame.minX + textEditorTextInset.width,
                y: editorFrame.minY + textEditorTextInset.height
            )
            model.append(
                .text(
                    origin: model.viewToCanvas(glyphOrigin, in: bounds),
                    string: string,
                    fontSize: textBaseFontSize / model.zoom,
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

    // MARK: - Zen / pointer mode and cursor safety

    private func freezeCursorIfNeeded() {
        guard interactionMode == .zen,
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

    private func enterZenMode() {
        interactionMode = .zen
        if !currentTouches.isEmpty {
            drawingSuppressedUntilRelease = true
            freezeCursorIfNeeded()
        }
        window?.makeFirstResponder(captureView)
        applySystemCursorForCurrentMode()
        needsDisplay = true
    }

    private func enterPointerMode() {
        interactionMode = .pointer
        cancelActiveDraft()
        cancelTextEditing()
        endTwoFingerNavigation()
        isThreeFingerDrawing = false
        penFingerID = nil
        currentTouches.removeAll(keepingCapacity: true)
        restingTouches.removeAll(keepingCapacity: true)
        matchedFinger = nil
        currentCursorViewPoint = nil
        isMouseDown = false
        resetPressureState()
        drawingSuppressedUntilRelease = false
        restoreCursorAssociation(force: true)
        NSCursor.arrow.set()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    private func applySystemCursorForCurrentMode() {
        window?.invalidateCursorRects(for: self)
        guard interactionMode == .zen,
              let window,
              window.isKeyWindow else {
            NSCursor.arrow.set()
            return
        }

        let mousePoint = convert(
            window.mouseLocationOutsideOfEventStream,
            from: nil
        )
        if bounds.contains(mousePoint) {
            transparentCursor.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private static func makeTransparentCursor() -> NSCursor {
        let image = NSImage(size: CGSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.clear.setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: 1, height: 1)).fill()
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: .zero)
    }

    private func resetPressureState() {
        currentPressure = 0
    }

    private func updateWindowObservation() {
        guard observedWindow !== window else { return }

        restoreCursorAssociation(force: true)
        NSCursor.arrow.set()
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers.removeAll()

        observedWindow = window
        guard let window else { return }

        // Losing key must always release the cursor (hard safety rule) — but
        // dropping to pointer mode silently is how a user ends up testing
        // gestures in the mode where the OS makes them exclusive. Remember that
        // we were in zen and restore it when the window comes back.
        windowObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.resumeZenOnKey = self.interactionMode == .zen
                self.enterPointerMode()
            }
        )
        windowObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                guard let self, self.resumeZenOnKey else { return }
                self.resumeZenOnKey = false
                self.enterZenMode()
            }
        )
    }

    // MARK: - Layout

    /// Drawing area left over once the docked toolbar and status strip are out.
    private var contentRect: CGRect {
        let left = edgeInset * 2 + toolbarWidth
        return CGRect(
            x: left,
            y: statusHeight,
            width: max(1, bounds.width - left - edgeInset),
            height: max(1, bounds.height - statusHeight - edgeInset)
        )
    }

    private var trackpadRect: CGRect {
        TrackpadGeometry.padRect(
            in: contentRect,
            deviceSize: currentDeviceSize,
            fraction: 0.78
        )
    }

    /// Tools, then a divider, then the one-shot text button.
    private var toolbarRect: CGRect {
        let height = toolbarItemHeight * CGFloat(BoardTool.allCases.count)
            + textButtonGap + toolbarItemHeight + 12
        let y = min(
            max(statusHeight + edgeInset, bounds.midY - height / 2),
            max(statusHeight + edgeInset, bounds.maxY - height - edgeInset)
        )
        return CGRect(x: edgeInset, y: y, width: toolbarWidth, height: height)
    }

    private func toolbarItemRects() -> [(BoardTool, CGRect)] {
        let rect = toolbarRect
        return BoardTool.allCases.map { tool in
            let index = CGFloat(tool.rawValue - 1)
            return (
                tool,
                CGRect(
                    x: rect.minX + 6,
                    y: rect.maxY - 6 - (index + 1) * toolbarItemHeight,
                    width: rect.width - 12,
                    height: toolbarItemHeight
                )
            )
        }
    }

    /// Below the tools and visually detached — text is an action, never a mode,
    /// so this button never renders as "selected".
    private var textButtonRect: CGRect {
        let rect = toolbarRect
        let toolsHeight = toolbarItemHeight * CGFloat(BoardTool.allCases.count)
        return CGRect(
            x: rect.minX + 6,
            y: rect.maxY - 6 - toolsHeight - textButtonGap - toolbarItemHeight,
            width: rect.width - 12,
            height: toolbarItemHeight
        )
    }

    private func toolbarTool(at point: CGPoint) -> BoardTool? {
        guard toolbarRect.contains(point) else { return nil }
        return toolbarItemRects().first(where: { $0.1.contains(point) })?.0
    }

    private var preferredCursorPoint: CGPoint {
        currentCursorViewPoint ??
            lastCursorViewPoint ??
            CGPoint(x: contentRect.midX, y: contentRect.midY)
    }

    // MARK: - Rendering

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
        // Keep the on-screen grid density stable across the whole zoom range.
        var spacing: CGFloat = 40
        while spacing * model.zoom < 22 { spacing *= 2 }
        while spacing * model.zoom > 90 { spacing /= 2 }
        let path = NSBezierPath()

        var x = floor(minimumX / spacing) * spacing
        while x <= maximumX {
            path.move(to: model.canvasToView(CGPoint(x: x, y: minimumY), in: bounds))
            path.line(to: model.canvasToView(CGPoint(x: x, y: maximumY), in: bounds))
            x += spacing
        }

        var y = floor(minimumY / spacing) * spacing
        while y <= maximumY {
            path.move(to: model.canvasToView(CGPoint(x: minimumX, y: y), in: bounds))
            path.line(to: model.canvasToView(CGPoint(x: maximumX, y: y), in: bounds))
            y += spacing
        }

        NSColor(calibratedWhite: 1, alpha: 0.035).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func draw(element: BoardElement, alpha: CGFloat = 1) {
        switch element {
        case let .stroke(samples, color):
            drawStroke(
                samples: samples,
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
            stroke(path, width: width, color: color.withAlphaComponent(alpha))

        case let .ellipse(rect, width, color):
            let path = NSBezierPath(ovalIn: model.canvasToView(rect, in: bounds))
            stroke(path, width: width, color: color.withAlphaComponent(alpha))

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
            element = .stroke(samples: draft.strokeSamples, color: draft.color)
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
        }
        draw(element: element, alpha: 0.72)
    }

    /// Strokes are filled as a variable-width ribbon: one fill per stroke, and
    /// no visible seams between segments of differing width.
    // ponytail: smoothing is recomputed each frame; cache per element if a
    // board with thousands of samples starts dropping frames.
    private func drawStroke(samples: [BoardStrokeSample], color: NSColor) {
        guard !samples.isEmpty else { return }

        var points: [(point: CGPoint, radius: CGFloat)] = []
        points.reserveCapacity(samples.count * 2)
        for sample in smoothedStrokeSamples(samples) {
            let viewPoint = model.canvasToView(sample.point, in: bounds)
            let radius = max(0.35, sample.width * model.zoom / 2)
            if let last = points.last,
               hypot(last.point.x - viewPoint.x, last.point.y - viewPoint.y) < 0.05,
               abs(last.radius - radius) < 0.05 {
                continue
            }
            points.append((viewPoint, radius))
        }

        color.setFill()
        guard points.count > 1 else {
            if let only = points.first {
                fillDot(at: only.point, radius: only.radius)
            }
            return
        }

        var leftEdge: [CGPoint] = []
        var rightEdge: [CGPoint] = []
        leftEdge.reserveCapacity(points.count)
        rightEdge.reserveCapacity(points.count)

        for index in points.indices {
            let previous = points[max(0, index - 1)].point
            let next = points[min(points.count - 1, index + 1)].point
            var dx = next.x - previous.x
            var dy = next.y - previous.y
            let length = hypot(dx, dy)
            if length < 1e-6 {
                dx = 1
                dy = 0
            } else {
                dx /= length
                dy /= length
            }
            let radius = points[index].radius
            let offset = CGPoint(x: -dy * radius, y: dx * radius)
            let center = points[index].point
            leftEdge.append(CGPoint(x: center.x + offset.x, y: center.y + offset.y))
            rightEdge.append(CGPoint(x: center.x - offset.x, y: center.y - offset.y))
        }

        let path = NSBezierPath()
        path.move(to: leftEdge[0])
        for point in leftEdge.dropFirst() { path.line(to: point) }
        for point in rightEdge.reversed() { path.line(to: point) }
        path.close()
        path.windingRule = .nonZero
        path.fill()

        // Round caps.
        if let first = points.first { fillDot(at: first.point, radius: first.radius) }
        if let last = points.last { fillDot(at: last.point, radius: last.radius) }
    }

    private func fillDot(at point: CGPoint, radius: CGFloat) {
        let diameter = max(0.7, radius * 2)
        NSBezierPath(
            ovalIn: CGRect(
                x: point.x - diameter / 2,
                y: point.y - diameter / 2,
                width: diameter,
                height: diameter
            )
        ).fill()
    }

    private func smoothedStrokeSamples(
        _ samples: [BoardStrokeSample]
    ) -> [BoardStrokeSample] {
        guard samples.count > 1 else { return samples }

        var result = [samples[0]]
        result.reserveCapacity(samples.count * 2)
        for index in 0..<(samples.count - 1) {
            let p0 = samples[max(0, index - 1)].point
            let p1 = samples[index].point
            let p2 = samples[index + 1].point
            let p3 = samples[min(samples.count - 1, index + 2)].point
            let width1 = samples[index].width
            let width2 = samples[index + 1].width
            let screenDistance = hypot(p2.x - p1.x, p2.y - p1.y) * model.zoom
            // Int(ceil(nan)) traps, and a trap inside draw() kills the app.
            let stepCount = screenDistance.isFinite
                ? max(1, min(16, Int(ceil(min(1000, screenDistance) / 2.5))))
                : 1

            for step in 1...stepCount {
                let t = CGFloat(step) / CGFloat(stepCount)
                result.append(
                    BoardStrokeSample(
                        point: catmullRom(p0: p0, p1: p1, p2: p2, p3: p3, t: t),
                        width: max(0.2, width1 + (width2 - width1) * t)
                    )
                )
            }
        }
        return result
    }

    private func catmullRom(
        p0: CGPoint,
        p1: CGPoint,
        p2: CGPoint,
        p3: CGPoint,
        t: CGFloat
    ) -> CGPoint {
        let t2 = t * t
        let t3 = t2 * t

        func component(
            _ a: CGFloat,
            _ b: CGFloat,
            _ c: CGFloat,
            _ d: CGFloat
        ) -> CGFloat {
            0.5 * (
                2 * b
                    + (-a + c) * t
                    + (2 * a - 5 * b + 4 * c - d) * t2
                    + (-a + 3 * b - 3 * c + d) * t3
            )
        }

        return CGPoint(
            x: component(p0.x, p1.x, p2.x, p3.x),
            y: component(p0.y, p1.y, p2.y, p3.y)
        )
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

    /// Four corner brackets — a whisper of where the pad maps to, with no frame
    /// around the artwork.
    private func drawTrackpadOverlay() {
        let rect = trackpadRect
        let arm = min(22, min(rect.width, rect.height) * 0.09)
        guard arm > 2 else { return }

        let path = NSBezierPath()
        for (corner, dx, dy) in [
            (CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0),
            (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
            (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0),
            (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0),
        ] {
            path.move(to: CGPoint(x: corner.x + arm * CGFloat(dx), y: corner.y))
            path.line(to: corner)
            path.line(to: CGPoint(x: corner.x, y: corner.y + arm * CGFloat(dy)))
        }

        NSColor(calibratedWhite: 0.95, alpha: 0.14).setStroke()
        path.lineWidth = 1
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private func drawEmptyStateHint() {
        guard !model.hasCreatedContent, activeDraft == nil else { return }

        let text = "Touch the trackpad to draw · pick a tool on the left · three fingers force-draw · Esc toggles zen / pointer"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.95, alpha: 0.34),
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let pad = trackpadRect
        let y = max(statusHeight + 18, pad.minY - 34)
        (text as NSString).draw(
            at: CGPoint(x: pad.midX - size.width / 2, y: y),
            withAttributes: attributes
        )
    }

    private func drawTouchMarkers() {
        guard interactionMode == .zen else { return }

        // Ghosts: visible, but deliberately not part of any gesture.
        drawTouchRings(restingTouches, alpha: 0.11)

        guard currentTouches.count >= 2 else { return }
        let points = drawTouchRings(currentTouches, alpha: 1)

        if points.count == 2 {
            let link = NSBezierPath()
            link.move(to: points[0])
            link.line(to: points[1])
            link.lineWidth = 1
            NSColor(calibratedWhite: 1, alpha: 0.16).setStroke()
            link.stroke()
        }
    }

    @discardableResult
    private func drawTouchRings(
        _ touches: [TouchSample],
        alpha: CGFloat
    ) -> [CGPoint] {
        guard !touches.isEmpty else { return [] }

        let points = touches.map { TrackpadGeometry.map($0.pos, into: trackpadRect) }
        for point in points {
            let ring = NSBezierPath(
                ovalIn: CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)
            )
            NSColor(calibratedWhite: 1, alpha: 0.08 * alpha).setFill()
            ring.fill()
            NSColor(calibratedWhite: 1, alpha: 0.34 * alpha).setStroke()
            ring.lineWidth = 1
            ring.stroke()
        }
        return points
    }

    private func drawCursor() {
        guard let point = currentCursorViewPoint,
              currentTouches.count == 1 || isThreeFingerDrawing else { return }

        let drawing = isDrawingRequested || isThreeFingerDrawing
        let force = isThreeFingerDrawing ? 1 : min(1, max(0, currentForceNorm))
        let radius = (drawing ? 8.0 : 6.5) + 6 * force
        let tint = drawing ? inkColor : NSColor.white
        let ring = NSBezierPath(
            ovalIn: CGRect(
                x: point.x - radius,
                y: point.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        )

        NSGraphicsContext.saveGraphicsState()
        applySoftShadow(blur: 7, offsetY: -1, alpha: 0.55)
        tint.withAlphaComponent(drawing ? 0.14 + 0.18 * force : 0.09).setFill()
        ring.fill()
        NSGraphicsContext.restoreGraphicsState()

        tint.withAlphaComponent(drawing ? 0.5 + 0.4 * force : 0.4).setStroke()
        ring.lineWidth = drawing ? 1.6 : 1
        ring.stroke()

        let dot = drawing ? 3.4 + 2.4 * force : 2.6
        tint.withAlphaComponent(drawing ? 1 : 0.85).setFill()
        fillDot(at: point, radius: dot / 2)
    }

    private func drawToolbar() {
        let rect = toolbarRect
        let card = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)

        NSGraphicsContext.saveGraphicsState()
        applySoftShadow(blur: 16, offsetY: -4, alpha: 0.45)
        NSColor(calibratedWhite: 0.11, alpha: 0.95).setFill()
        card.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor(calibratedWhite: 1, alpha: 0.1).setStroke()
        card.lineWidth = 1
        card.stroke()

        for (tool, itemRect) in toolbarItemRects() {
            let active = tool == currentTool
            if active {
                let highlight = NSBezierPath(
                    roundedRect: itemRect.insetBy(dx: 0, dy: 3),
                    xRadius: 9,
                    yRadius: 9
                )
                inkColor.withAlphaComponent(0.2).setFill()
                highlight.fill()
                inkColor.withAlphaComponent(0.42).setStroke()
                highlight.lineWidth = 1
                highlight.stroke()
            }

            let tint = active
                ? inkColor
                : NSColor(calibratedWhite: 0.92, alpha: 0.62)
            drawGlyph(
                for: tool,
                in: CGRect(
                    x: itemRect.minX,
                    y: itemRect.minY + 14,
                    width: itemRect.width,
                    height: itemRect.height - 18
                ),
                color: tint
            )
            drawCenteredLabel(
                "\(tool.rawValue)",
                centeredAtX: itemRect.midX,
                y: itemRect.minY + 5,
                font: .monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
                color: active
                    ? inkColor.withAlphaComponent(0.9)
                    : NSColor(calibratedWhite: 0.9, alpha: 0.38)
            )
        }

        drawTextButton()
    }

    /// One-shot action, never "selected": a divider then a plain T.
    private func drawTextButton() {
        let itemRect = textButtonRect
        let divider = NSBezierPath()
        let y = itemRect.maxY + textButtonGap / 2
        divider.move(to: CGPoint(x: itemRect.minX + 6, y: y))
        divider.line(to: CGPoint(x: itemRect.maxX - 6, y: y))
        divider.lineWidth = 1
        NSColor(calibratedWhite: 1, alpha: 0.1).setStroke()
        divider.stroke()

        let tint = NSColor(calibratedWhite: 0.92, alpha: 0.62)
        let font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        drawCenteredLabel(
            "T",
            centeredAtX: itemRect.midX,
            y: itemRect.minY + 16,
            font: font,
            color: tint
        )
        drawCenteredLabel(
            "text",
            centeredAtX: itemRect.midX,
            y: itemRect.minY + 5,
            font: .systemFont(ofSize: 8, weight: .medium),
            color: NSColor(calibratedWhite: 0.9, alpha: 0.38)
        )
    }

    /// Small vector icon for a tool, drawn to fit `rect`.
    private func drawGlyph(for tool: BoardTool, in rect: CGRect, color: NSColor) {
        let side = min(rect.width, rect.height) * 0.72
        let box = CGRect(
            x: rect.midX - side / 2,
            y: rect.midY - side / 2,
            width: side,
            height: side
        )
        guard side > 2 else { return }

        let path = NSBezierPath()
        switch tool {
        case .pen:
            path.move(to: CGPoint(x: box.minX, y: box.minY + box.height * 0.32))
            path.curve(
                to: CGPoint(x: box.midX, y: box.minY + box.height * 0.58),
                controlPoint1: CGPoint(x: box.minX + box.width * 0.18, y: box.maxY),
                controlPoint2: CGPoint(x: box.midX - box.width * 0.14, y: box.minY)
            )
            path.curve(
                to: CGPoint(x: box.maxX, y: box.minY + box.height * 0.86),
                controlPoint1: CGPoint(x: box.midX + box.width * 0.16, y: box.maxY),
                controlPoint2: CGPoint(x: box.maxX - box.width * 0.16, y: box.minY + box.height * 0.2)
            )
        case .line:
            path.move(to: CGPoint(x: box.minX, y: box.minY))
            path.line(to: CGPoint(x: box.maxX, y: box.maxY))
        case .rectangle:
            path.appendRoundedRect(
                box.insetBy(dx: 0, dy: box.height * 0.12),
                xRadius: 2.5,
                yRadius: 2.5
            )
        case .ellipse:
            path.appendOval(in: box.insetBy(dx: 0, dy: box.height * 0.1))
        case .arrow:
            let start = CGPoint(x: box.minX, y: box.minY)
            let end = CGPoint(x: box.maxX, y: box.maxY)
            path.move(to: start)
            path.line(to: end)
            let head = side * 0.34
            path.move(to: end)
            path.line(to: CGPoint(x: end.x - head, y: end.y))
            path.move(to: end)
            path.line(to: CGPoint(x: end.x, y: end.y - head))
        }

        color.setStroke()
        path.lineWidth = max(1.2, side * 0.11)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
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

        let zen = interactionMode == .zen
        let accent = zen ? inkColor : NSColor.systemOrange
        let badgeFont = NSFont.systemFont(ofSize: 9.5, weight: .heavy)
        let badge = interactionMode.badge
        let badgeWidth = textWidth(badge, font: badgeFont) + 16
        let badgeRect = CGRect(
            x: 14,
            y: (statusHeight - 17) / 2,
            width: badgeWidth,
            height: 17
        )
        // Solid, not tinted: the mode decides whether two-finger pinch+pan is
        // simultaneous (zen) or OS-exclusive (pointer), so it must be
        // impossible to misread at a glance.
        accent.setFill()
        NSBezierPath(roundedRect: badgeRect, xRadius: 5, yRadius: 5).fill()
        drawLabel(
            badge,
            at: CGPoint(x: badgeRect.minX + 8, y: badgeRect.minY + 4),
            font: badgeFont,
            color: NSColor(calibratedWhite: 0.06, alpha: 1)
        )

        var x = badgeRect.maxX + 12
        let baseline: CGFloat = 11
        let bodyFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        let mutedColor = NSColor(calibratedWhite: 0.92, alpha: 0.78)

        drawLabel(
            currentTool.statusName,
            at: CGPoint(x: x, y: baseline),
            font: bodyFont,
            color: mutedColor
        )
        x += textWidth(currentTool.statusName, font: bodyFont) + 10

        drawLabel(
            "·",
            at: CGPoint(x: x, y: baseline),
            font: bodyFont,
            color: NSColor(calibratedWhite: 0.92, alpha: 0.3)
        )
        x += 10

        let zoomFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let zoomText = "\(Int((model.zoom * 100).rounded()))%"
        drawLabel(
            zoomText,
            at: CGPoint(x: x, y: baseline),
            font: zoomFont,
            color: isTwoFingerNavigating ? inkColor : mutedColor
        )
        x += textWidth(zoomText, font: zoomFont) + 10

        if let live = isTwoFingerNavigating
            ? "pinch + pan"
            : (isThreeFingerDrawing ? "3-finger force draw" : nil) {
            drawLabel(
                live,
                at: CGPoint(x: x, y: baseline),
                font: bodyFont,
                color: inkColor.withAlphaComponent(0.8)
            )
        }

        let hints = zen
            ? "1–5 tools · T text · 3 fingers force-draw · ⌘Z undo · Esc pointer"
            : "system gestures — Esc back to zen for pinch + pan together"
        let hintFont = NSFont.systemFont(ofSize: 10)
        let hintWidth = textWidth(hints, font: hintFont)
        drawLabel(
            hints,
            at: CGPoint(x: max(x + 16, rect.maxX - hintWidth - 14), y: baseline + 0.5),
            font: hintFont,
            color: NSColor(calibratedWhite: 0.82, alpha: 0.55)
        )
    }

    // MARK: - Drawing helpers

    private func applySoftShadow(blur: CGFloat, offsetY: CGFloat, alpha: CGFloat) {
        let shadow = NSShadow()
        shadow.shadowBlurRadius = blur
        shadow.shadowOffset = CGSize(width: 0, height: offsetY)
        shadow.shadowColor = NSColor.black.withAlphaComponent(alpha)
        shadow.set()
    }

    private func textWidth(_ string: String, font: NSFont) -> CGFloat {
        (string as NSString).size(withAttributes: [.font: font]).width
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

    private func drawCenteredLabel(
        _ string: String,
        centeredAtX x: CGFloat,
        y: CGFloat,
        font: NSFont,
        color: NSColor
    ) {
        drawLabel(
            string,
            at: CGPoint(x: x - textWidth(string, font: font) / 2, y: y),
            font: font,
            color: color
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
