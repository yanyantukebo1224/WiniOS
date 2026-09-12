import SwiftUI
import UIKit
import QuartzCore
import Metal
import os.log

// 2026-07-03 window-hosted Metal layer.
//
// The presenting CAMetalLayer must NOT be a SwiftUI-hosted view's backing
// layer: on iOS 26/27, SwiftUI's hosting intermittently routes such layers
// through an indirect/snapshot path where direct Metal presentations are
// silently dropped — presented drawables complete with presentedTime==0
// (measured), the screen freezes on stale content, and only full-tree
// re-renders (screenshots) reveal new frames. Which path a given run gets
// appeared random — the "sometimes rendering starts at present #9,
// sometimes never" lottery.
//
// So the layer now lives in MetalHostView, a raw UIView added directly to
// the UIWindow (classic game setup, no SwiftUI management). The SwiftUI-
// hosted MetalBackedView remains as a transparent layout placeholder that
// tracks geometry and handles touch input. The host view sits on top of
// the window but has interaction disabled, so touches fall through to the
// SwiftUI hierarchy (and thus to the placeholder's touch handlers).

/// Raw window-level host for the presenting CAMetalLayer.
final class MetalHostView: UIView {
    // Process-lifetime singleton. The CAMetalLayer is registered with DXMT's
    // swapchain exactly once; if the host were recreated on view teardown
    // (rotation, re-attach) DXMT would keep presenting to the DEAD layer —
    // black surface both ways (2026-07-05 landscape regression). One host,
    // one layer, forever; only its FRAME is re-parented/resized.
    static let shared = MetalHostView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))

    override class var layerClass: AnyClass { return CAMetalLayer.self }
    var metalLayer: CAMetalLayer { return layer as! CAMetalLayer }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false   // touches fall through to SwiftUI
        backgroundColor = .black
        contentScaleFactor = UIScreen.main.scale
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        // 2026-07-03 MeloNX trick: displaySyncEnabled is macOS-public but
        // exists as PRIVATE API on iOS. Disabling it takes our presents out
        // of the display-sync scheduling machinery — the thing that has been
        // silently dropping them (presentedTime==0 on all but occasional
        // frames) at our sub-1Hz game present cadence. MeloNX (shipping
        // Switch emulator) sets exactly this pair on its layer.
        let syncSel = NSSelectorFromString("setDisplaySyncEnabled:")
        if metalLayer.responds(to: syncSel) {
            metalLayer.perform(syncSel, with: NSNumber(value: false))
            LogStore.shared.log("MetalLayer: displaySyncEnabled=false (private API, MeloNX pattern)")
        }
        /* ml651: was hardcoded 60, which contradicted everything around it —
         * FPSOverlay asks the display link for CAFrameRateRange(preferred: 120)
         * while this declared the surface a 60Hz one. Track the screen instead.
         *
         * ⚠️ HYPOTHESIS, NOT A DIAGNOSIS. displaySyncEnabled=false directly above
         * takes our presents out of display-sync scheduling, so this nominal
         * value may well be inert. It is one line and it removes a genuine
         * contradiction; if the A/B shows nothing, the cap is elsewhere and we
         * have eliminated it rather than argued about it. */
        let fpsSel = NSSelectorFromString("setNominalFramesPerSecond:")
        if metalLayer.responds(to: fpsSel) {
            let hz = UIScreen.main.maximumFramesPerSecond
            metalLayer.perform(fpsSel, with: hz as NSNumber)
            LogStore.shared.log("MetalLayer: ml651 nominalFPS=\(hz) (was hardcoded 60; "
                                + "display link asks preferred=120)")
        }
        UIApplication.shared.isIdleTimerDisabled = true
        // Set once so DXMT's swapchain setup never blocks on a zero-sized
        // layer. After this, DXMT's setProps is the ONLY drawableSize
        // writer — per-layout rewrites from the app were a second writer
        // fighting it (pool churn on every SwiftUI layout pass).
        metalLayer.drawableSize = CGSize(width: 800, height: 600)
    }
    required init?(coder: NSCoder) { fatalError() }
}

// SwiftUI-hosted placeholder: geometry + touch input only.
final class MetalBackedView: UIView {
    private static var layerRegistered = false

    // Hardware keyboard bridge: the view becomes first responder so the iOS
    // software keyboard appears, and each typed character is forwarded to
    // Wine as a virtual-key sequence (winios_post_key → send_hardware_message
    // → WM_KEYDOWN/WM_CHAR). Lets the user type into Windows dialogs (e.g.
    // Run) directly instead of relying on the browse list.
    static weak var keyboardTarget: MetalBackedView?
    override var canBecomeFirstResponder: Bool { true }

    /// Whether the software keyboard is actually on screen, tracked from
    /// UIKit's notifications. `isFirstResponder` alone is not enough: the
    /// view can still be first responder with the keyboard gone (window
    /// changes, scene transitions), and then a "toggle" resigned an
    /// invisible keyboard — the button seemed dead every other press.
    private static var keyboardShown = false
    private static var keyboardObserved = false
    private static func observeKeyboard() {
        guard !keyboardObserved else { return }
        keyboardObserved = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIResponder.keyboardDidShowNotification, object: nil, queue: .main) { _ in
            keyboardShown = true
        }
        nc.addObserver(forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main) { _ in
            keyboardShown = false
        }
    }

    /// The surface view that is live on screen right now: the registered
    /// target if it is still in a window, else any attached instance.
    private static func liveTarget() -> MetalBackedView? {
        if let v = keyboardTarget, v.window != nil { return v }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for w in scene.windows {
                if let v = find(in: w) { return v }
            }
        }
        return nil
    }

    private static func find(in view: UIView) -> MetalBackedView? {
        if let v = view as? MetalBackedView, !v.isHidden { return v }
        for s in view.subviews { if let v = find(in: s) { return v } }
        return nil
    }

    static func toggleKeyboard() {
        observeKeyboard()
        guard let v = liveTarget() else {
            LogStore.shared.log("Keyboard: no live game surface to attach to", level: .error)
            return
        }
        if keyboardShown {
            v.resignFirstResponder()
            return
        }
        // Not visible: (re)raise it. The button lives in the touch-controls
        // window, so make sure the surface's own window is key first —
        // iOS only shows the keyboard for the key window's responder.
        v.window?.makeKey()
        if v.isFirstResponder { v.resignFirstResponder() }
        let ok = v.becomeFirstResponder()
        if !ok {
            LogStore.shared.log("Keyboard: becomeFirstResponder refused (window=\(v.window == nil ? "nil" : "ok"))",
                                level: .error)
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Multi-touch REQUIRED: with it off, a fast double-tap's second
        // touch (landing before the first lift is processed) is silently
        // swallowed — drag-arm never fired (2026-07-06). Two-finger
        // scroll/right-click need it too.
        self.isMultipleTouchEnabled = true
        self.isUserInteractionEnabled = true
        self.backgroundColor = .clear
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    // Visibility-stall postmortem (2026-07-03): the intermittent "presents
    // count but the screen stays black until a bg/fg or screenshot" state
    // was probed exhaustively — drawable leaks, present pacing, panel idle,
    // SwiftUI hosting, display-sync, CADisplayLink, transaction nudges and
    // view re-attach kicks were all eliminated (none changed it; only true
    // scene-level lifecycle events land pending frames, ~1-2 each). The one
    // robust correlate is present cadence: 60 FPS content always displays,
    // ~1 FPS content mostly doesn't. Resolution path: raise game FPS (perf
    // work), with a steady-rate re-present in DXMT as fallback insurance.

    /// Largest 4:3 rect (the 1024×768 logical surface's aspect) that fits
    /// centered in our bounds. The window-level host view gets THIS frame,
    /// not our full bounds — otherwise landscape stretches the game to the
    /// display edges (2026-07-05). Touch mapping uses the same rect so
    /// letterboxing never skews input.
    /// ml793: the logical screen is whatever MADEIRA_SCREEN_W/H say (the
    /// Settings resolution, applied to direct game launches as well as the
    /// desktop); 1024x768 only when the env is unset.
    static func logicalScreen() -> (CGFloat, CGFloat) {
        func env(_ name: String, _ def: CGFloat) -> CGFloat {
            guard let v = getenv(name), let i = Int(String(cString: v)), i > 0 else { return def }
            return CGFloat(i)
        }
        return (env("MADEIRA_SCREEN_W", 1024), env("MADEIRA_SCREEN_H", 768))
    }

    private func gameRect() -> CGRect {
        let (gw, gh) = Self.logicalScreen()
        let scale = min(bounds.width / gw, bounds.height / gh)
        let w = gw * scale, h = gh * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2,
                      width: max(w, 1), height: max(h, 1))
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let w = window else { return }   // detach: leave the host be
        MetalBackedView.keyboardTarget = self  // keyboard button targets the live view
        // SwiftUI ancestors attach gesture recognizers that can delay or
        // cancel raw touch delivery (double-tap timing is exactly what
        // they punish). Defuse them for our subtree.
        var v: UIView? = self
        while let s = v {
            s.gestureRecognizers?.forEach {
                $0.cancelsTouchesInView = false
                $0.delaysTouchesBegan = false
                $0.delaysTouchesEnded = false
            }
            v = s.superview
        }
        let host = MetalHostView.shared
        if host.superview !== w {
            host.removeFromSuperview()
            w.addSubview(host)
        }
        host.frame = convert(gameRect(), to: w)
        // S2 desktop mode: the winios compositor renders the wine virtual
        // desktop aspect-fit inside THIS placeholder's area, exactly like
        // the games' Metal layer — never over the whole phone screen.
        let full = convert(bounds, to: w)
        winios_set_compositor_frame(full.minX, full.minY, full.width, full.height)
        if !Self.layerRegistered {
            Self.layerRegistered = true
            madeira_display_set_layer(host.metalLayer)
            LogStore.shared.log("MetalLayer registered with DXMT shim (window-hosted singleton)", level: .success)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let w = window {
            MetalHostView.shared.frame = convert(gameRect(), to: w)
            let full = convert(bounds, to: w)
            winios_set_compositor_frame(full.minX, full.minY, full.width, full.height)
        }
    }

    // Map touch point in view-local UI points to the 1024×768 logical
    // surface DXMT swapchains use, then post to winios.drv. Coordinates
    // are relative to the aspect-fit gameRect (letterbox borders clamp).
    private func mapTouch(_ touch: UITouch) -> (Int32, Int32) {
        let p = touch.location(in: self)
        let r = gameRect()
        let (gw, gh) = Self.logicalScreen()
        let x = Int32(min(max((p.x - r.minX) * gw / r.width, 0), gw - 1))
        let y = Int32(min(max((p.y - r.minY) * gh / r.height, 0), gh - 1))
        return (x, y)
    }

    // ==================================================================
    // S2 desktop mode: trackpad-style pointer.
    //   one finger move       — cursor moves relative (like a laptop pad)
    //   single tap            — left click
    //   double tap            — double click (two rapid clicks)
    //   double tap + hold     — drag (button held while moving), lift = drop
    //   two-finger drag       — scroll wheel
    //   two-finger tap        — right click
    // Cursor position lives here (desktop px); wine + the rendered arrow
    // follow via winios_pointer / winios_cursor_move.
    // ==================================================================
    private static var cursor = CGPoint(x: 480, y: 270)
    private var lastPanPoint = CGPoint.zero
    private var touchStartPoint = CGPoint.zero
    private var touchStartTime: TimeInterval = 0
    private var movedBeyondSlop = false
    private var dragActive = false
    private var dragTouch: UITouch?          // the finger that owns the drag
    private var touchGeneration = 0          // invalidates pending long-press timers
    private var twoFingerActive = false
    private var twoFingerMoved = false
    private var twoFingerStartTime: TimeInterval = 0
    private var lastTwoFingerY: CGFloat = 0
    private var scrollAccum: CGFloat = 0
    // ml641: relative motion is scaled by a float sensitivity, so the integer
    // delta we hand to wine loses a fraction every event. At low sensitivity
    // that truncation is the whole signal — carry the remainder or slow drags
    // simply do nothing.
    private var relCarryX: CGFloat = 0
    private var relCarryY: CGFloat = 0

    private let F_MOVE: UInt32 = 0x1, F_LDOWN: UInt32 = 0x2, F_LUP: UInt32 = 0x4
    private let F_RDOWN: UInt32 = 0x8, F_RUP: UInt32 = 0x10
    private let F_WHEEL: UInt32 = 0x800, F_ABS: UInt32 = 0x8000

    private var desktopMode: Bool {
        guard let v = getenv("MADEIRA_DESKTOP") else { return false }
        return v.pointee == 49  // '1'
    }
    private func envInt(_ name: String, _ def: Int) -> Int {
        guard let v = getenv(name), let i = Int(String(cString: v)) else { return def }
        return i
    }
    private func postPointer(_ flags: UInt32, data: Int32 = 0) {
        winios_pointer(Int32(Self.cursor.x), Int32(Self.cursor.y), flags, UInt32(bitPattern: data))
    }
    private func avgPoint(_ touches: [UITouch]) -> CGPoint {
        var x: CGFloat = 0, y: CGFloat = 0
        for t in touches { let p = t.location(in: self); x += p.x; y += p.y }
        let n = CGFloat(max(touches.count, 1))
        return CGPoint(x: x / n, y: y / n)
    }
    private func activeTouches(_ event: UIEvent?) -> [UITouch] {
        (event?.allTouches ?? []).filter { $0.phase != .ended && $0.phase != .cancelled }
    }

    /// Quick-tap detection shared by both modes, purely for the full-screen
    /// chrome: a short, still touch on the surface posts .madeiraSurfaceTap
    /// so the auto-hidden toolbar can reappear. Game input is unaffected.
    private var chromeTapStart = CGPoint.zero
    private var chromeTapTime: TimeInterval = 0
    private var chromeTapCount = 0

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let t = touches.first {
            chromeTapCount = activeTouches(event).count
            chromeTapStart = t.location(in: self)
            chromeTapTime = Date().timeIntervalSinceReferenceDate
        }
        guard desktopMode else {
            guard let t = touches.first else { return }
            let (x, y) = mapTouch(t)
            winios_post_touch_down(x, y)
            return
        }
        let now = Date().timeIntervalSinceReferenceDate
        let active = activeTouches(event)
        touchGeneration += 1
        if active.count >= 2 {
            twoFingerActive = true
            twoFingerMoved = false
            twoFingerStartTime = now
            lastTwoFingerY = avgPoint(active).y
            scrollAccum = 0
            // a drag started by the first finger stays active; harmless
            return
        }
        guard let t = touches.first else { return }
        let p = t.location(in: self)
        touchStartPoint = p
        lastPanPoint = p
        touchStartTime = now
        movedBeyondSlop = false
        relCarryX = 0; relCarryY = 0   // ml641: never carry motion across a lift
        // long-press → drag: hold still for 0.5s, haptic confirms, then move
        // the window; release drops. (Replaced double-tap-hold — it raced
        // Windows' double-click detection: wine saw WM_LBUTTONDBLCLK.)
        let gen = touchGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.touchGeneration == gen, !self.dragActive,
                  !self.movedBeyondSlop, !self.twoFingerActive,
                  // ml643: in mouse-look the finger is the CAMERA, not a pointer.
                  // Holding still to line up a shot must not press the mouse.
                  !InputSettings.shared.relative else { return }
            self.dragActive = true
            self.dragTouch = t
            self.postPointer(self.F_LDOWN)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            fputs("[trackpad] long-press drag armed\n", stderr)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard desktopMode else {
            guard let t = touches.first else { return }
            let (x, y) = mapTouch(t)
            winios_post_touch_move(x, y)
            return
        }
        let active = activeTouches(event)
        if twoFingerActive {
            guard active.count >= 2 else { return }
            let avg = avgPoint(active)
            let dy = avg.y - lastTwoFingerY
            lastTwoFingerY = avg.y
            if abs(dy) > 2 { twoFingerMoved = true }
            scrollAccum += dy
            // 14pt of finger travel = one wheel notch. ml641 flipped the sign:
            // on a touchscreen the content follows the finger, so dragging UP
            // scrolls DOWN through the document. It was mouse-wheel sense before.
            while scrollAccum <= -14 { scrollAccum += 14; postPointer(F_WHEEL, data: -120) }
            while scrollAccum >= 14 { scrollAccum -= 14; postPointer(F_WHEEL, data: 120) }
            return
        }
        let t: UITouch
        if dragActive, let d = dragTouch {
            guard touches.contains(d) else { return }  // only the old tap finger moved
            t = d
        } else {
            guard let f = touches.first else { return }
            t = f
        }
        let p = t.location(in: self)
        let dx = p.x - lastPanPoint.x, dy = p.y - lastPanPoint.y
        lastPanPoint = p
        if hypot(p.x - touchStartPoint.x, p.y - touchStartPoint.y) > 10 { movedBeyondSlop = true }

        /* ml641 RELATIVE (mouse-look) MODE.
         *
         * Absolute input is what made the camera spin. We post a POSITION; wine
         * turns it into the delta the game reads as
         *     x - desktop_shm->cursor.x            (queue_ios.c:2290)
         * A game that locks the cursor calls ClipCursor, and update_desktop_cursor_pos
         * then CLAMPS desktop_shm->cursor into that rect, pinning it. Our own
         * Self.cursor keeps wandering across the full 1024x768, so the subtraction
         * yields (wandering - pinned): a huge delta that never converges and is
         * re-sent on every event. Spin rate depends on WHERE the finger is, not how
         * fast it moves.
         *
         * Posting device motion instead makes that impossible to reproduce: wine
         * computes cursor.x + dx, so the delta is exactly dx no matter what the
         * game does to the cursor. No F_ABS, and Self.cursor is deliberately not
         * touched — in this mode it has no meaning.
         *
         * Sign follows PUBG/Fortnite: drag right -> view turns right -> the world
         * slides left, so a target to the RIGHT of the crosshair is pulled onto it
         * by dragging RIGHT. That is the same sign as a mouse. Negate both terms
         * for content-drag (finger-follows-world) feel. */
        if InputSettings.shared.relative {
            let sens = CGFloat(InputSettings.shared.sensRel)
            relCarryX += dx * sens
            relCarryY += dy * sens
            let ix = Int32(max(-30000, min(30000, relCarryX)))
            let iy = Int32(max(-30000, min(30000, relCarryY)))
            relCarryX -= CGFloat(ix)
            relCarryY -= CGFloat(iy)
            if ix != 0 || iy != 0 { winios_pointer(ix, iy, F_MOVE, 0) }
            return
        }

        let sens = CGFloat(InputSettings.shared.sensAbs)   // desktop px per view pt
        let maxX = CGFloat(envInt("MADEIRA_SCREEN_W", 1024) - 1)
        let maxY = CGFloat(envInt("MADEIRA_SCREEN_H", 768) - 1)
        Self.cursor.x = min(max(Self.cursor.x + dx * sens, 0), maxX)
        Self.cursor.y = min(max(Self.cursor.y + dy * sens, 0), maxY)
        postPointer(F_MOVE | F_ABS)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let t = touches.first, chromeTapCount == 1 {
            let p = t.location(in: self)
            let dt = Date().timeIntervalSinceReferenceDate - chromeTapTime
            if dt < 0.3 && hypot(p.x - chromeTapStart.x, p.y - chromeTapStart.y) < 12 {
                NotificationCenter.default.post(name: .madeiraSurfaceTap, object: nil)
            }
        }
        guard desktopMode else {
            guard let t = touches.first else { return }
            let (x, y) = mapTouch(t)
            winios_post_touch_up(x, y)
            return
        }
        let now = Date().timeIntervalSinceReferenceDate
        if twoFingerActive {
            if activeTouches(event).isEmpty {
                if !twoFingerMoved && now - twoFingerStartTime < 0.40
                    && !InputSettings.shared.relative {   // ml643: see touchesBegan
                    postPointer(F_RDOWN)
                    postPointer(F_RUP)
                }
                twoFingerActive = false
            }
            return
        }
        touchGeneration += 1   // cancel any pending long-press
        if dragActive {
            if let d = dragTouch, !touches.contains(d) {
                fputs("[trackpad] ended: non-drag finger up (drag continues)\n", stderr)
                return
            }
            fputs("[trackpad] ended: drag drop\n", stderr)
            postPointer(F_LUP)
            dragActive = false
            dragTouch = nil
            return
        }
        // stationary release before the 0.5s drag threshold = click.
        // ml643: NOT in relative mode — every small aim adjustment would fire the
        // weapon. Left/right click are on-screen buttons there instead.
        if !movedBeyondSlop && now - touchStartTime < 0.5 && !InputSettings.shared.relative {
            fputs("[trackpad] ended: click\n", stderr)
            postPointer(F_LDOWN)
            postPointer(F_LUP)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard desktopMode else {
            guard let t = touches.first else { return }
            let (x, y) = mapTouch(t)
            winios_post_touch_up(x, y)
            return
        }
        fputs("[trackpad] CANCELLED (dragActive=\(dragActive))\n", stderr)
        touchGeneration += 1
        if dragActive { postPointer(F_LUP); dragActive = false }
        dragTouch = nil
        twoFingerActive = false
    }
}

/// Arrow-key button with press/hold/release semantics. DragGesture with
/// zero minimum distance fires onChanged at touch-down (key down once)
/// and onEnded at lift (key up) — unlike Button, which only taps.
struct HoldKeyView: View {
    let label: String
    let vk: Int32
    var big = false   // landscape D-pad: thumb-sized
    @State private var isDown = false

    var body: some View {
        Text(label)
            .font(.system(size: big ? 22 : 14, weight: .semibold, design: .monospaced))
            .foregroundColor(.white)
            .frame(minWidth: big ? 56 : 34, minHeight: big ? 56 : 30)
            .background(Color.white.opacity(isDown ? 0.35 : 0.15))
            .cornerRadius(big ? 12 : 6)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isDown {
                            isDown = true
                            winios_post_key(vk, 1)
                        }
                    }
                    .onEnded { _ in
                        isDown = false
                        winios_post_key(vk, 0)
                    }
            )
    }
}

/// Shared state for the expanded thumbstick pad. The pad cannot be drawn by
/// SwiftUI in place: the game surface is a raw window-level UIView
/// (MetalHostView.shared) sitting ABOVE the entire SwiftUI hierarchy, so a
/// SwiftUI pad centred on the key row gets sliced off wherever it overlaps —
/// no zIndex can fix that, because zIndex only orders siblings *within*
/// SwiftUI. So the pad is hosted in the window too, added after (and thus
/// above) the Metal view, and driven from the SwiftUI button through this.
final class JoystickPadState: ObservableObject {
    static let shared = JoystickPadState()
    @Published var held = false
    @Published var dir: Int = -1
    @Published var center: CGPoint = .zero      // window coordinates
    /// ml641: driven by the pointer panel. The pad is NOT a sibling of the key
    /// row — it lives in its own UIWindow one level up (that is the whole point
    /// of this class), so the row's .transition(.opacity) cannot reach it and it
    /// stayed visible while every other button faded. It has to fade itself.
    @Published var hidden = false
}

/// Window-level host for the pad. Transparent and non-interactive: the
/// SwiftUI button keeps the gesture, this only draws.
enum JoystickPadHost {
    /// Own UIWindow, one level above the app's. Being a sibling subview of
    /// MetalHostView is NOT enough: that view re-adds itself to the window on
    /// every didMoveToWindow (rotation, re-attach) and DXMT/CoreAnimation can
    /// reorder around it, so any subview ordering we impose is only true until
    /// the next layout. A higher windowLevel cannot be undone by anything
    /// inside the app window, so the pad is unconditionally on top.
    ///
    /// Deliberately NOT solved by changing the game surface: the CAMetalLayer
    /// is window-level precisely because SwiftUI hosting silently dropped
    /// presents on iOS 26/27 (see MetalHostView) — that is a rendering
    /// correctness fix and must not be traded away for z-ordering.
    private static var overlay: PassthroughWindow?

    static func attach(to scene: UIWindowScene) {
        if overlay == nil {
            let w = PassthroughWindow(windowScene: scene)
            w.windowLevel = .normal + 100
            w.backgroundColor = .clear
            w.isHidden = false                 // never becomes key: see PassthroughWindow
            let host = UIHostingController(rootView: JoystickPadOverlay())
            host.view.backgroundColor = .clear
            host.view.isUserInteractionEnabled = false
            w.rootViewController = host
            overlay = w
        }
        overlay?.frame = scene.coordinateSpace.bounds
    }
}

/// Transparent, fully click-through window: hitTest always returns nil, so
/// touches fall through to the app window underneath and the pad can never
/// steal input from the game surface or the SwiftUI controls.
final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

/// The expanded pad, drawn in window space at the button's location.
struct JoystickPadOverlay: View {
    @ObservedObject private var s = JoystickPadState.shared

    var body: some View {
        GeometryReader { _ in
            // THE one and only joystick face — idle ring and expanded pad are
            // the same view, never two that swap. That identity is what makes
            // it seamless: the diameter and the knob offset are plain animated
            // properties, so releasing lets the knob spring back to centre and
            // keep wiggling after the ring has already shrunk. Two faces
            // cross-fading (one in the button, one here) cannot do that — the
            // wiggle dies with the copy that gets faded out.
            //
            // Fixed-size box at a CONSTANT offset. Deliberately not
            // .position() + .transition(.scale): .position expands the view to
            // fill the parent (so a .center anchor means mid-screen), and an
            // offset that changes in the same transaction as `held` gets
            // animated too — which is what made the pad fly in from the top.
            // Here the only animatable quantities belong to the face itself.
            JoystickFace(held: s.held, dir: s.dir)
                .frame(width: JoystickFace.padRadius * 2,
                       height: JoystickFace.padRadius * 2)
                .offset(x: s.center.x - JoystickFace.padRadius,
                        y: s.center.y - JoystickFace.padRadius)
                .opacity(s.center == .zero ? 0 : 1)
        }
        // MUST ignore the safe area. s.center comes from the button's .global
        // frame, which is measured from the WINDOW origin; without this the
        // overlay's hosting view is inset by the safe area, the offset above
        // is measured from below the status bar, and the pad lands ~59pt too
        // low — roughly one pad radius, which is exactly why it appeared to
        // sit under the game strip instead of centred on the button.
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .opacity(s.hidden ? 0 : 1)
        .animation(.easeInOut(duration: 0.28), value: s.hidden)
        .animation(.spring(response: 0.32, dampingFraction: 0.62), value: s.held)
        .animation(.spring(response: 0.22, dampingFraction: 0.58), value: s.dir)
    }
}

/// The joystick face itself, shared by the in-row idle ring and the expanded
/// window-level pad so both look identical and animate the same way.
struct JoystickFace: View {
    var held: Bool
    var dir: Int
    /// ml646: the portrait pad grows out of a key-sized ring when you hold it.
    /// An overlay stick is a PERMANENT control — it must be full size at rest
    /// with only the knob moving, so size is decoupled from press here rather
    /// than faked by passing held:true (which would also kill the knob travel
    /// and the press styling).
    var alwaysExpanded = false
    private var expanded: Bool { held || alwaysExpanded }

    static let idleDiameter: CGFloat = 22
    static let padRadius: CGFloat = 58
    private var idleDiameter: CGFloat { Self.idleDiameter }
    private var padRadius: CGFloat { Self.padRadius }
    private let knobTravelRatio: CGFloat = 0.30

    @ViewBuilder private var interior: some View {
        if #available(iOS 26.0, *) {
            Circle().fill(.clear).glassEffect(.regular, in: Circle())
        } else {
            Circle().fill(.ultraThinMaterial)
        }
    }

    private func knobOffset(_ d: CGFloat) -> CGSize {
        guard dir >= 0, expanded else { return .zero }
        let travel = d * knobTravelRatio
        let a = Double(dir) * 45.0 * .pi / 180.0
        return CGSize(width: travel * CGFloat(sin(a)), height: -travel * CGFloat(cos(a)))
    }

    var body: some View {
        let d = expanded ? padRadius * 2 : idleDiameter
        return ZStack {
            interior
            Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: expanded ? 2 : 1.5)
            Circle()
                .fill(Color.white)
                .frame(width: d * 0.42, height: d * 0.42)
                .overlay(
                    // Roundness cue. It reads at key size but turns into a
                    // smudge on the big pad, so it fades out as the ring
                    // springs open rather than scaling up with it.
                    Circle()
                        .trim(from: 0.55, to: 0.70)
                        .stroke(Color.black.opacity(0.38),
                                style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                        .padding(d * 0.075)
                        .opacity(expanded ? 0 : 1)
                )
                .offset(knobOffset(d))
        }
        .frame(width: d, height: d)
    }
}

/// On-screen thumbstick. Idle it is a key-sized ring with a white knob;
/// press and hold and it expands into a pad you can steer. Travel snaps to
/// eight d-pad directions, each mapped to the arrow keys Windows games
/// already understand — diagonals simply hold two keys at once — so this
/// needs no new input path: it posts through the same winios_post_key queue
/// as the key buttons, and key state is edge-triggered (only the keys that
/// actually changed are sent on each snap).
///
/// The pad expands DOWNWARD. It must never grow up into the game strip:
/// that surface is a raw window-level UIView (MetalHostView.shared) drawn
/// over SwiftUI, so anything overlapping it is simply covered.
struct JoystickKeyView: View {
    @State private var held = false
    @State private var dir: Int = -1        // -1 = centred, else 0=up then clockwise
    @State private var center: CGPoint = .zero
    @State private var hosted = false       // overlay window up: it draws the face

    private let deadzone: CGFloat = 14      // pt of travel before a direction registers

    private let vkUp: Int32 = 0x26, vkRight: Int32 = 0x27
    private let vkDown: Int32 = 0x28, vkLeft: Int32 = 0x25

    private func keys(for d: Int) -> [Int32] {
        switch d {
        case 0: return [vkUp]
        case 1: return [vkUp, vkRight]
        case 2: return [vkRight]
        case 3: return [vkDown, vkRight]
        case 4: return [vkDown]
        case 5: return [vkDown, vkLeft]
        case 6: return [vkLeft]
        case 7: return [vkUp, vkLeft]
        default: return []
        }
    }

    /// Release what is no longer held, press what newly is — never a blanket
    /// release/re-press, which would make a held direction stutter as the
    /// thumb wanders inside one sector.
    private func apply(_ next: Int) {
        guard next != dir else { return }
        let old = Set(keys(for: dir)), new = Set(keys(for: next))
        for vk in old.subtracting(new) { winios_post_key(vk, 0) }
        for vk in new.subtracting(old) { winios_post_key(vk, 1) }
        dir = next
        JoystickPadState.shared.dir = next
    }

    private func snap(_ t: CGSize) -> Int {
        let d = (t.width * t.width + t.height * t.height).squareRoot()
        if d < deadzone { return -1 }
        // Screen y grows downward; measure clockwise from "up".
        var a = atan2(t.width, -t.height) * 180 / .pi
        if a < 0 { a += 360 }
        return Int((a + 22.5) / 45.0) % 8
    }

    var body: some View {
        // The idle ring lives in the row (inset inside the 34x30 button so it
        // has breathing room). The EXPANDED pad is drawn by the window-level
        // host at this same centre — see JoystickPadState — so it springs out
        // of the button in place and is never clipped by the game surface.
        Color.clear
            .frame(width: 34, height: 30)
            .background(Color.white.opacity(held ? 0.30 : 0.15))
            .cornerRadius(6)
            .overlay { if !hosted { JoystickFace(held: false, dir: -1) } }
            .background(
                GeometryReader { geo in
                    Color.clear.onAppear {
                        center = CGPoint(x: geo.frame(in: .global).midX,
                                         y: geo.frame(in: .global).midY)
                        JoystickPadState.shared.center = center
                        if let scene = UIApplication.shared.connectedScenes
                            .compactMap({ $0 as? UIWindowScene }).first {
                            JoystickPadHost.attach(to: scene)
                            hosted = true
                        }
                    }
                    .onChange(of: geo.frame(in: .global)) { _, f in
                        center = CGPoint(x: f.midX, y: f.midY)
                        JoystickPadState.shared.center = center
                    }
                }
            )
            .animation(.spring(response: 0.32, dampingFraction: 0.62), value: held)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !held {
                            held = true
                            if let scene = UIApplication.shared.connectedScenes
                                .compactMap({ $0 as? UIWindowScene }).first {
                                JoystickPadHost.attach(to: scene)
                            }
                            JoystickPadState.shared.center = center
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) {
                                JoystickPadState.shared.held = true
                            }
                        }
                        apply(snap(g.translation))
                    }
                    .onEnded { _ in
                        apply(-1)                        // releases every held arrow
                        held = false
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) {
                            JoystickPadState.shared.held = false
                        }
                    }
            )
    }
}

// SwiftUI wrapper around the placeholder view.
// iOS software-keyboard → Wine key events. Each character is mapped to a
// US-layout virtual-key (+ shift where needed) and posted as a down/up pair;
// the message queue's ToUnicode then produces the right WM_CHAR. Paths need
// the full symbol set (":" "\" "-" "." "_"), so the table is comprehensive.
extension MetalBackedView: UIKeyInput {
    var hasText: Bool { false }

    // US-keyboard VK + shift for a character. Returns nil for chars we can't map.
    private static func vkForChar(_ ch: Character) -> (Int32, Bool)? {
        if ch == "\n" || ch == "\r" { return (0x0D, false) }   // VK_RETURN
        if ch == "\t" { return (0x09, false) }                 // VK_TAB
        if ch == " " { return (0x20, false) }                  // VK_SPACE
        if ch.isLetter, let up = ch.uppercased().first?.asciiValue, up >= 0x41, up <= 0x5A {
            return (Int32(up), ch.isUppercase)                 // VK_A..VK_Z
        }
        if let a = ch.asciiValue, a >= 0x30, a <= 0x39 {
            return (Int32(a), false)                           // VK_0..VK_9 (unshifted)
        }
        let table: [Character: (Int32, Bool)] = [
            "!": (0x31, true), "@": (0x32, true), "#": (0x33, true), "$": (0x34, true),
            "%": (0x35, true), "^": (0x36, true), "&": (0x37, true), "*": (0x38, true),
            "(": (0x39, true), ")": (0x30, true),
            "-": (0xBD, false), "_": (0xBD, true),
            "=": (0xBB, false), "+": (0xBB, true),
            "[": (0xDB, false), "{": (0xDB, true),
            "]": (0xDD, false), "}": (0xDD, true),
            "\\": (0xDC, false), "|": (0xDC, true),
            ";": (0xBA, false), ":": (0xBA, true),
            "'": (0xDE, false), "\"": (0xDE, true),
            ",": (0xBC, false), "<": (0xBC, true),
            ".": (0xBE, false), ">": (0xBE, true),
            "/": (0xBF, false), "?": (0xBF, true),
            "`": (0xC0, false), "~": (0xC0, true),
        ]
        return table[ch]
    }

    func insertText(_ text: String) {
        for ch in text {
            guard let (vk, shift) = MetalBackedView.vkForChar(ch) else { continue }
            if shift { winios_post_key(0x10, 1) }   // VK_SHIFT down
            winios_post_key(vk, 1)
            winios_post_key(vk, 0)
            if shift { winios_post_key(0x10, 0) }    // VK_SHIFT up
        }
    }

    func deleteBackward() {
        winios_post_key(0x08, 1)   // VK_BACK down
        winios_post_key(0x08, 0)
    }

    // Traits: keep iOS from rewriting path characters.
    var keyboardType: UIKeyboardType { get { .asciiCapable } set {} }
    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
    var smartDashesType: UITextSmartDashesType { get { .no } set {} }
    var spellCheckingType: UITextSpellCheckingType { get { .no } set {} }
}

/// Pointer settings, persisted to the app container.
///
/// ml641. Two independent sensitivities, because the two modes mean different
/// things and a single slider would fight itself:
///   • absolute  — trackpad gain, desktop px per view pt. This IS the old
///     hardcoded `sens = 2.0`, so the default reproduces today's desktop feel
///     exactly.
///   • relative  — mouse counts per view pt for mouse-look. What the right value
///     is depends on the GAME's own sensitivity and FOV, which we cannot see, so
///     it has to be calibrated by hand once. See the comment in touchesMoved.
///
/// Stored as JSON in Documents/ rather than UserDefaults: that is the container
/// we already know survives reinstall (verified), and it can be pulled and
/// edited with the same devicectl command we use for the log.
final class InputSettings: ObservableObject {
    static let shared = InputSettings()

    @Published var relative: Bool  = false { didSet { save() } }
    @Published var sensAbs:  Double = 2.0  { didSet { save() } }
    @Published var sensRel:  Double = 2.0  { didSet { save() } }
    /// ml649: heavy diagnostics. Default OFF so the shipped default is the fast
    /// path; flip it on only when a run needs to be explainable.
    @Published var diagnostics = false { didSet { madeira_set_diag_enabled(diagnostics ? 1 : 0); save() } }

    /// didSet fires for assignments made in init() because the properties are
    /// already initialised by then; without this the first launch would write
    /// the defaults back over a file it had only half-read.
    private var loading = false

    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("madeira-input.json")
    }

    private init() {
        loading = true
        if let d = try? Data(contentsOf: Self.url),
           let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            relative = j["relative"] as? Bool   ?? false
            sensAbs  = j["sensAbs"]  as? Double ?? 2.0
            sensRel  = j["sensRel"]  as? Double ?? 2.0
            diagnostics = j["diagnostics"] as? Bool ?? false
        }
        loading = false
        madeira_set_diag_enabled(diagnostics ? 1 : 0)   // push the restored value down
    }

    private func save() {
        guard !loading else { return }
        let j: [String: Any] = ["relative": relative, "sensAbs": sensAbs, "sensRel": sensRel, "diagnostics": diagnostics]
        guard let d = try? JSONSerialization.data(withJSONObject: j) else { return }
        try? d.write(to: Self.url, options: .atomic)
    }
}

struct MadeiraMetalView: UIViewRepresentable {
    func makeUIView(context: Context) -> MetalBackedView {
        return MetalBackedView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    }
    func updateUIView(_ uiView: MetalBackedView, context: Context) {}
}

struct ContentView: View {
    @StateObject private var logStore = LogStore.shared
    @State private var jitStatus: JITStatus = .unknown
    @State private var entitlements: EntitlementStatus?
    @State private var debuggerAttached = isDebuggerAttached()
    @ObservedObject private var input = InputSettings.shared
    @ObservedObject private var touchControls = TouchControlsModel.shared
    @ObservedObject private var gamepad = GamepadBridge.shared
    @State private var pointerPanel = false
    @State private var selectedTab: MadeiraTab = .games
    @State private var desktopFullScreen = false
    /// ml790: Start -> "Exit desktop" has closed every program. The desktop
    /// (explorer, services) stays alive underneath — the runtime cannot be
    /// restarted in-process — but it is hidden and the Desktop tab offers
    /// Start Desktop again, which simply shows it (see resumeDesktop).
    @State private var desktopShutDown = false
    /// ml792: what the Games tab is doing with the one-shot runtime. Drives
    /// the launcher's status pill and gates a second launch (see playGame).
    @State private var launcherSession: LauncherSession = .idle
    /// ml796: the game behind the loading screen, and whether it has drawn.
    @State private var launchingGame: LauncherGame? = nil
    @State private var firstFrameSeen = false
    @State private var launchBarPhase = false
    @State private var playingPid: Int = 0
    /// A game already ran in this process and the runtime cannot be started
    /// again: offer to quit so the next game gets a fresh launch.
    @State private var showRelaunchAlert = false
    @State private var showActivityLogs = false
    @State private var showRuntimeStatus = false
    @State private var prefixSizeText = "Calculating…"
    @AppStorage("madeira.libraryCompatibilityMode") private var compatibilityMode = "Stability"
    @AppStorage("madeira.steamMinimalLayout") private var steamMinimalLayout = true
    @AppStorage(perfOverlayEnabledKey) private var perfOverlayEnabled = true
    /// Present pacing default (FrameCap raw value) and the thermal throttle.
    @AppStorage(FrameCap.key) private var frameCapSetting: Int = 1
    @AppStorage(FrameCap.autoCoolKey) private var autoCoolDown = true
    /// FEX_TSOENABLED=0: skip x86 memory-ordering emulation. Big CPU saving,
    /// not safe for every title. Applied by runWineFullSequence.
    @AppStorage("madeira.fexNoTSO") private var fexNoTSO = false
    /// MADEIRA_DEBUG_VERBOSE=1: full WINEDEBUG trace (WineProcessBridge.m).
    @AppStorage("madeira.wineVerbose") private var wineVerbose = false
    /// Screen size of the Wine Virtual Desktop launcher, as "WxH". This is
    /// the display games see: the win32u shim lists every standard mode up
    /// to this size, so it also bounds what a game's own resolution menu
    /// can offer.
    @AppStorage("madeira.desktopResolution") private var desktopResolution = "960x540"
    private static let desktopResolutions = [
        "960x540", "1280x720", "1600x900", "1920x1080", "2048x1084", "2796x1290",
        "1024x768", "1280x960",
    ]
    /// Version of the Wine Mono runtime CI placed in the bundle's mono/
    /// folder (mscoree finds it via WINEDATADIR = bundle), or nil.
    static var bundledMonoVersion: String? {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("mono"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        return names.first { $0.hasPrefix("wine-mono-") }.map { String($0.dropFirst("wine-mono-".count)) }
    }

    /// "0.1.<run> (<run>, <commit>)" as stamped by CI (Stamp version step);
    /// "0.1.0 (1)" for a local Xcode build.
    static var appVersionText: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        if let c = info?["MadeiraBuildCommit"] as? String, !c.isEmpty { return "\(v) (\(b), \(c))" }
        return "\(v) (\(b))"
    }

    private var desktopSize: (w: Int, h: Int) {
        let parts = desktopResolution.split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return (960, 540) }
        return (parts[0], parts[1])
    }
    @Namespace private var pointerNS
    /// .compact = iPhone landscape: game surface expands, arrow keys appear.
    @Environment(\.verticalSizeClass) private var vSizeClass
    @Environment(\.horizontalSizeClass) private var hSizeClass

    enum JITStatus {
        case unknown
        case testing
        case available
        case mappingOnly
        case unavailable
    }

    private enum MadeiraTab: Hashable {
        case games, containers, desktop, settings
    }

    var body: some View {
        Group {
            // Keep full screen inside the app's existing UIWindow. A
            // fullScreenCover creates a presentation host above the raw,
            // window-owned CAMetalLayer, so the cover is opaque black even
            // though DXMT continues presenting underneath it.
            if desktopFullScreen {
                fullScreenDesktop
            } else if vSizeClass == .compact && selectedTab == .desktop {
                landscapeBody
            } else {
                TabView(selection: $selectedTab) {
                    launcherScreen
                        .tabItem { Label("Games", systemImage: "gamecontroller.fill") }
                        .tag(MadeiraTab.games)
                    containersScreen
                        .tabItem { Label("Containers", systemImage: "shippingbox.fill") }
                        .tag(MadeiraTab.containers)
                    Group {
                        if selectedTab == .desktop {
                            activityScreen
                        } else {
                            Color.clear
                        }
                    }
                        .tabItem { Label("Desktop", systemImage: "desktopcomputer") }
                        .tag(MadeiraTab.desktop)
                    settingsScreen
                        .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                        .tag(MadeiraTab.settings)
                }
                .tint(.indigo)
            }
        }
        .alert("Reopen Madeira to play another game", isPresented: $showRelaunchAlert) {
            Button("Quit Madeira", role: .destructive) { quitApp() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A game already ran in this session and the Wine runtime can only be started once per launch. Quit and reopen Madeira, then pick the next game.")
        }
        .onAppear {
            jit_install_trap_handler()
            // First line of every session log: which build produced it.
            logStore.log("Madeira \(Self.appVersionText)")
            // 32-bit feasibility: can memory below 4GB be mapped in this build?
            logStore.log(String(cString: madeira_low_memory_probe()))
            entitlements = EntitlementStatus.check()
            logEntitlementStatus()
            GamepadBridge.shared.start()
            FrameCap.apply(FrameCap.saved, persist: false)
            applySurfaceVisibility(tab: selectedTab)
            // ml791: controller drives the Games grid while that tab shows.
            GamepadBridge.shared.onNavigate = { GamesFocus.shared.handle($0) }
            syncGamepadUIMode()
        }
        .onChange(of: selectedTab) { _, tab in
            // Both surfaces are window-level views above the whole SwiftUI
            // tree: the games' Metal host AND the desktop compositor. The
            // compositor used to stay visible on every tab.
            applySurfaceVisibility(tab: tab)
            syncGamepadUIMode()
        }
        .onChange(of: desktopShutDown) { _, _ in
            applySurfaceVisibility(tab: selectedTab)
        }
        .onChange(of: desktopFullScreen) { _, _ in
            syncGamepadUIMode()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name("MadeiraExitFullScreen"))) { _ in
            desktopFullScreen = false
            // ml796: leaving full screen during a game launched from the
            // Games tab lands back on that tab, not on the Desktop tab.
            switch launcherSession {
            case .launching, .playing, .enablingJIT: selectedTab = .games
            default: break
            }
            // The tab may not change (already on Games): re-apply anyway so
            // the window-level surfaces never linger over the UI.
            applySurfaceVisibility(tab: selectedTab)
        }
    }

    /// The games' Metal host and the desktop compositor are visible only on
    /// the Desktop tab, and not while the desktop is shut down (ml790).
    private func applySurfaceVisibility(tab: MadeiraTab) {
        // Full screen manages the surfaces itself (fullScreenDesktop).
        if desktopFullScreen { return }
        let hidden = tab != .desktop || desktopShutDown || showLaunchOverlay
        MetalHostView.shared.isHidden = hidden
        winios_set_compositor_hidden(hidden ? 1 : 0)
    }

    /// "Running" on the Start Desktop button: the runtime is up and the
    /// desktop is showing. After Exit desktop the runtime is still up but the
    /// button must offer Start Desktop again.
    private var desktopIsRunning: Bool {
        wineserver_is_running() != 0 && !desktopShutDown
    }

    /// ml791: the pad navigates the Games grid only while that tab is on
    /// screen and the desktop is not full screen over it.
    private func syncGamepadUIMode() {
        GamepadBridge.shared.uiMode = (selectedTab == .games && !desktopFullScreen)
    }

    /// Hyper-improved game launch router:
    /// If desktop session is already running, launches seamlessly inside it via SessionLauncher.
    /// Otherwise launches directly (playGame), guaranteeing fast, reliable start without agent timeout traps.
    private func playGameAdaptive(_ game: LauncherGame) {
        if wineserver_is_running() != 0 && wine_process_is_running() != 0 {
            playGameHosted(game)
        } else {
            playGame(game)
        }
    }

    /// ml791: the Games tab. A console-style grid of the game folders on
    /// C:, playable by tap or controller (LauncherView).
    private var launcherScreen: some View {
        var v = LauncherView(session: launcherSession, onPlay: playGameAdaptive, onOpenDesktop: openDesktopFromGames, onQuitApp: quitApp)
        v.onForceClose = forceCloseGame
        return v
    }

    /// ml798: kill the game the Games tab launched (agent TerminateProcess);
    /// the agent's exit report then returns the card to Play.
    private func forceCloseGame() {
        guard case .playing(let title) = launcherSession, playingPid > 0 else { return }
        logStore.log("Force closing \(title) (pid \(playingPid))")
        let pid = playingPid
        SessionLauncher.shared.kill(pid: pid) { ok in
            logStore.log(ok ? "\(title): close requested" : "\(title): force close failed", level: ok ? .info : .error)
        }
        // ml799: if no exit report ever arrives (a process that will not die
        // wedges this port), do not stay stuck in "playing" forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            if case .playing = launcherSession, playingPid == pid {
                logStore.log("\(title) did not report its exit after force close — treating it as ended", level: .error)
                launcherSession = .idle
                launchingGame = nil
                desktopFullScreen = false
                selectedTab = .games
            }
        }
    }

    /// ml797: Play from the Games tab runs the game INSIDE a hidden desktop
    /// session, so it can be played again after quitting: the runtime is
    /// one-shot, and a game launched as the root process could never be
    /// followed by another (that is what "Reopen Madeira" was). The desktop
    /// stays underneath, covered by the game; the loading screen covers the
    /// start; the agent reports the game's exit so Play comes back.
    private func playGameHosted(_ game: LauncherGame) {
        guard let exe = game.exe else {
            logStore.log("\(game.title): only 32-bit executables found — not supported on this port", level: .error)
            return
        }
        switch launcherSession {
        case .enablingJIT, .launching:
            return
        case .playing:
            selectedTab = .desktop
            desktopFullScreen = true
            return
        default:
            break
        }
        if wineserver_is_running() == 0 && wine_process_exit_code() != -1 {
            showRelaunchAlert = true      // the runtime already ran and died
            return
        }
        let exePath = GameLibrary.windowsPath(exe)
        if let aid = game.steamAppID, aid > 0 {
            setenv("MADEIRA_APPID", String(aid), 1)
        } else {
            unsetenv("MADEIRA_APPID")
        }
        launchingGame = game
        firstFrameSeen = false
        launcherSession = .launching(game.title)
        let startInSession: () -> Void = {
            logStore.log("Games: launching \(game.title) → \(exePath)")
            SessionLauncher.shared.launch(exe: exePath, dir: game.dirWindowsPath) { outcome in
                switch outcome {
                case .started(let pid):
                    logStore.log("\(game.title) started (pid \(pid))", level: .success)
                    GameLibrary.shared.markPlayed(game)
                    playingPid = pid
                    launcherSession = .playing(game.title)
                    watchHostedGame(pid: pid, title: game.title)
                    return
                case .failed(let code):
                    logStore.log("\(game.title) failed to start: Windows error \(code)", level: .error)
                case .agentNotReady:
                    logStore.log("\(game.title): the desktop did not become ready in time", level: .error)
                case .noAnswer:
                    logStore.log("\(game.title): no answer from the desktop agent (C:\\madeira\\agent.log)", level: .error)
                }
                launcherSession = .idle
                launchingGame = nil
                desktopFullScreen = false
                selectedTab = .games
            }
        }
        // ml800: the desktop stays OFF on the Desktop tab unless the user
        // turns it on there. A game session started here keeps
        // desktopShutDown set; full screen shows the game regardless.
        if wineserver_is_running() != 0 {
            selectedTab = .desktop
            desktopFullScreen = true
            startInSession()
        } else {
            ensureJIT { ok in
                guard ok else { launcherSession = .idle; launchingGame = nil; return }
                launcherSession = .launching(game.title)
                SessionLauncher.shared.clearReady()
                desktopFullScreen = true
                // Let the loading screen paint before the JIT pool freeze.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    launchVirtualDesktop()
                    desktopShutDown = true
                    startInSession()
                }
            }
        }
    }

    /// Loading screen until the game has presented, then wait for the
    /// agent's exit report so Play returns.
    private func watchHostedGame(pid: Int, title: String) {
        DispatchQueue.global(qos: .utility).async {
            let presents0 = madeira_get_present_count()
            var waited = 0.0
            while madeira_get_present_count() < presents0 + 2 && waited < 60 {
                Thread.sleep(forTimeInterval: 0.25)
                waited += 0.25
            }
            let drew = madeira_get_present_count() >= presents0 + 2
            DispatchQueue.main.async {
                self.firstFrameSeen = true
                // ml801: a game that never drew within 60 s died at startup
                // (0.1.52: an IL2CPP title failing to load GameAssembly.dll)
                // and the exit report may never come; do not leave the
                // loading screen up forever.
                if !drew, case .playing(let t) = self.launcherSession, t == title {
                    logStore.log("\(title) never drew a frame within 60 s — treating it as failed; check madeira-log.txt for a missing DLL or a crash", level: .error)
                    self.launcherSession = .idle
                    self.launchingGame = nil
                    self.desktopFullScreen = false
                    self.selectedTab = .games
                }
            }
        }
        SessionLauncher.shared.waitForExit(pid: pid) { code in
            logStore.log("\(title) ended (exit code \(code))")
            if case .playing = launcherSession {
                launcherSession = .idle
                launchingGame = nil
                desktopFullScreen = false
                selectedTab = .games
            }
        }
    }

    private var launcherScreenUnused: some View {
        LauncherView(session: launcherSession,
                     onPlay: playGame,
                     onOpenDesktop: openDesktopFromGames,
                     onQuitApp: quitApp)
    }

    /// ml792: make sure the debugger is attached before the runtime starts.
    /// Calls back on the main thread with true when JIT is usable. StikDebug
    /// polls forever, so a 90 s deadline turns "nothing happened" into a
    /// logged failure instead of a launcher stuck on "Enabling JIT".
    private func ensureJIT(_ completion: @escaping (Bool) -> Void) {
        if jit_check_debugged() {
            completion(true)
            return
        }
        launcherSession = .enablingJIT
        logStore.log("Enabling JIT through StikDebug…")
        var done = false
        StikJITHelper.enableJIT { ok in
            if done { return }
            done = true
            completion(ok)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
            if !done {
                done = true
                logStore.log("JIT was not enabled within 90 s — is StikDebug installed and paired?", level: .error)
                completion(false)
            }
        }
    }

    /// ml792: start a game from the Games tab like an app — as the root
    /// process of the one-shot runtime, no desktop in between.
    ///
    /// The runtime can be started once per app launch, so the second game
    /// needs a fresh Madeira (showRelaunchAlert). The only exception is a
    /// desktop session already started from the Desktop tab: while it runs,
    /// games are launched inside it through the session agent
    /// (SessionLauncher), exactly as a File Explorer double-click would.
    private func playGame(_ game: LauncherGame) {
        guard game.exe != nil else {
            logStore.log("\(game.title): only 32-bit executables found — not supported on this port", level: .error)
            return
        }
        if case .playing = launcherSession {
            selectedTab = .desktop
            desktopFullScreen = true
            return
        }
        if case .launching = launcherSession { return }
        if case .enablingJIT = launcherSession { return }
        if case .ended = launcherSession {
            showRelaunchAlert = true
            return
        }
        if wineserver_is_running() != 0 {
            // A desktop session was started from the Desktop tab: launch
            // inside it (the only option while it runs).
            logStore.log("Games: \(game.title) will start inside the running desktop")
            if desktopShutDown {
                resumeDesktop()
            } else {
                selectedTab = .desktop
            }
            GameLibrary.shared.markPlayed(game)
            SessionLauncher.shared.launch(exe: game.exeWindowsPath, dir: game.dirWindowsPath) { outcome in
                switch outcome {
                case .started(let pid):
                    logStore.log("\(game.title) started (pid \(pid))", level: .success)
                    desktopFullScreen = true
                case .failed(let code):
                    logStore.log("\(game.title) failed to start: Windows error \(code)", level: .error)
                case .agentNotReady:
                    logStore.log("\(game.title): the desktop did not become ready in time", level: .error)
                case .noAnswer:
                    logStore.log("\(game.title): no answer from the desktop agent (C:\\madeira\\agent.log has details)", level: .error)
                }
            }
            return
        }
        if wine_process_exit_code() != -1 {
            // The runtime already ran and ended.
            showRelaunchAlert = true
            return
        }
        launcherSession = .launching(game.title)
        ensureJIT { ok in
            guard ok else {
                launcherSession = .idle
                return
            }
            // ensureJIT switched the state to .enablingJIT while StikDebug
            // attached; go back to "Starting <title>…" for the runtime start.
            launcherSession = .launching(game.title)
            GameLibrary.shared.markPlayed(game)
            logStore.log("Games: launching \(game.title) → \(game.exeWindowsPath)")
            prepareDirectLaunch(game.title)
            // A Windows path here makes WineProcessBridge chdir to the exe's
            // folder and pick the arm64ec bundle; nothing else is needed.
            setenv("MADEIRA_EXE", game.exeWindowsPath, 1)
            if let aid = game.steamAppID, aid > 0 {
                setenv("MADEIRA_APPID", String(aid), 1)
            } else {
                unsetenv("MADEIRA_APPID")
            }
            unsetenv("MADEIRA_ARGS")
            unsetenv("MADEIRA_DESKTOP")
            // ml793: the Settings resolution is the game's screen too —
            // win32u reports it as SM_CXSCREEN and the mode list, so the
            // game defaults to it instead of the legacy 1024x768, and the
            // Metal host / touch mapping follow the same aspect
            // (MetalBackedView.logicalScreen).
            let (screenW, screenH) = desktopSize
            setenv("MADEIRA_SCREEN_W", String(screenW), 1)
            setenv("MADEIRA_SCREEN_H", String(screenH), 1)
            logStore.log("Games: screen \(screenW)x\(screenH) (Settings → Screen resolution)")
            launchingGame = game
            firstFrameSeen = false
            desktopFullScreen = true
            // Let the loading screen actually reach the display before the
            // JIT pool allocation freezes the process.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                runWineFullSequence()
                watchDirectGame(game.title)
            }
        }
    }

    /// ml792: follow a directly launched game's process for its whole life
    /// and keep launcherSession in step: .playing once the Wine process is
    /// up, .ended (with the exit code logged) once it is gone.
    private func watchDirectGame(_ title: String) {
        DispatchQueue.global(qos: .utility).async {
            var waited = 0.0
            while wine_process_is_running() == 0 && waited < 180.0 {
                Thread.sleep(forTimeInterval: 0.5)
                waited += 0.5
            }
            if wine_process_is_running() == 0 {
                DispatchQueue.main.async {
                    self.launcherSession = .idle
                    self.desktopFullScreen = false
                    logStore.log("\(title) did not start within 180 s", level: .error)
                }
                return
            }
            DispatchQueue.main.async {
                self.launcherSession = .playing(title)
            }
            // ml796: keep the loading screen up until the game has presented
            // a couple of frames (or it died first).
            let presents0 = madeira_get_present_count()
            var waitedPresents = 0.0
            while wine_process_is_running() != 0 && madeira_get_present_count() < presents0 + 2 && waitedPresents < 10.0 {
                Thread.sleep(forTimeInterval: 0.25)
                waitedPresents += 0.25
            }
            DispatchQueue.main.async {
                self.firstFrameSeen = true
            }
            while wine_process_is_running() != 0 {
                Thread.sleep(forTimeInterval: 0.5)
            }
            DispatchQueue.main.async {
                let code = Int(wine_process_exit_code())
                logStore.log("\(title) ended (exit code \(code))")
                self.launcherSession = .ended(title)
                self.desktopFullScreen = false
                self.selectedTab = .games
            }
        }
    }

    /// ml792: the Games tab's "Open desktop" action. Shows the desktop if
    /// one is up (or shut down with Exit desktop), starts one if the runtime
    /// is still unused, and otherwise offers to quit — the runtime ran
    /// already and cannot be started again in this process.
    private func openDesktopFromGames() {
        if desktopShutDown {
            resumeDesktop()
        } else if wineserver_is_running() != 0 {
            selectedTab = .desktop
        } else if wine_process_exit_code() != -1 {
            showRelaunchAlert = true
        } else {
            ensureJIT { ok in
                if ok {
                    launcherSession = .idle
                    launchVirtualDesktop()
                } else {
                    launcherSession = .idle
                }
            }
        }
    }

    /// ml792: quit at the user's request (the runtime is one-shot, so a
    /// second game needs a fresh process). A short delay lets the log line
    /// and the alert dismissal land first.
    private func quitApp() {
        logStore.log("Quitting Madeira at the user's request")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            _exit(0)
        }
    }

    /// Runtime status sheet: "Off" after Exit desktop — the runtime is still
    /// resident (it cannot be restarted in-process), but the desktop is not.
    private var desktopStatusText: String {
        if desktopIsRunning { return "Running" }
        if desktopShutDown { return "Off (runtime idle)" }
        return "Ready"
    }

    private var containersScreen: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top) {
                            Image(systemName: "shippingbox.fill")
                                .font(.title2)
                                .foregroundStyle(.indigo)
                                .frame(width: 52, height: 52)
                                .background(.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Default")
                                    .font(.title3.bold())
                                Text("Windows 64-bit · DXMT")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("READY")
                                .font(.caption2.bold())
                                .foregroundStyle(.green)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(.green.opacity(0.11), in: Capsule())
                        }
                        Divider()
                        containerDetail("Translation", value: "FEX · ARM64EC", icon: "arrow.triangle.2.circlepath")
                        containerDetail("Graphics", value: "DXMT · Metal", icon: "sparkles.rectangle.stack")
                        containerDetail("Storage", value: prefixSizeText, icon: "internaldrive")
                        containerDetail("Prefix", value: "Documents/wine", icon: "folder")
                        Button {
                            openDocumentsInFiles()
                        } label: {
                            Label("Open Madeira in Files", systemImage: "folder.badge.gearshape")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(18)
                    .background(Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Runtime components").font(.headline)
                        dependencyRow("Visual C++ runtime", detail: "Provided by the prefix", available: true)
                        Divider()
                        dependencyRow("Wine Mono",
                                      detail: Self.bundledMonoVersion.map { "Bundled runtime \($0) (.NET Framework games)" }
                                              ?? "Not in this build — .NET games cannot start",
                                      available: Self.bundledMonoVersion != nil)
                    }
                    .padding(18)
                    .background(Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Containers")
            .task { calculatePrefixSize() }
        }
    }

    private func dependencyRow(_ title: String, detail: String, available: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: available ? "checkmark.circle.fill" : "arrow.down.circle")
                .foregroundStyle(available ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func containerDetail(_ title: String, value: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }

    private var activityScreen: some View {
        NavigationStack {
            portraitBody
                .navigationTitle("Desktop")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    Menu {
                        Button("Runtime Status", systemImage: "gauge.with.dots.needle.50percent") {
                            showRuntimeStatus = true
                        }
                        Button("View Logs", systemImage: "text.alignleft") {
                            showActivityLogs = true
                        }
                        Button("Clear Log", systemImage: "trash", role: .destructive) {
                            logStore.clear()
                        }
                        // The full Wine log on disk (Documents/madeira-log.txt),
                        // for sending a crash trace without the Files app.
                        ShareLink(item: wineLogFileURL) {
                            Label("Export Log File", systemImage: "square.and.arrow.up")
                        }
                        Button("Runtime Settings", systemImage: "gearshape") {
                            selectedTab = .settings
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                .sheet(isPresented: $showActivityLogs) {
                    activityLogsSheet
                }
                .sheet(isPresented: $showRuntimeStatus) {
                    runtimeStatusSheet
                }
        }
    }

    private var activityLogsSheet: some View {
        NavigationStack {
            Group {
                if logStore.entries.isEmpty {
                    ContentUnavailableView("No log yet",
                                           systemImage: "text.alignleft",
                                           description: Text("Runtime messages will appear here."))
                } else {
                    logConsole
                }
            }
            .navigationTitle("Session Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear", role: .destructive) { logStore.clear() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showActivityLogs = false }
                }
            }
        }
    }

    private var runtimeStatusSheet: some View {
        NavigationStack {
            List {
                Section("Session") {
                    LabeledContent("Desktop", value: desktopStatusText)
                    LabeledContent("Architecture", value: "ARM64EC")
                    LabeledContent("Graphics", value: "DXMT · Metal")
                }
                Section("Runtime Pipeline") {
                    pipelineRow("wineserver", detail: "Single-process service thread",
                                state: wineserver_is_running() != 0 ? "Running" : "Idle",
                                color: wineserver_is_running() != 0 ? .green : .secondary)
                    pipelineRow("FEX", detail: "x86-64 translation and JIT",
                                state: debuggerAttached ? "Ready" : "Needs JIT",
                                color: debuggerAttached ? .green : .orange)
                    pipelineRow("DXMT", detail: "Direct3D 11 to Metal",
                                state: wineserver_is_running() != 0 ? "Attached" : "Standby",
                                color: wineserver_is_running() != 0 ? .green : .secondary)
                }
                Section("Diagnostics") {
                    LabeledContent("Frame pacing", value: "Visible during a session")
                    LabeledContent("Termination reports", value: "iPadOS Diagnostics")
                    Text("Pipeline states reflect real session availability. Detailed per-thread timing is not exposed by the current runtime.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Device Capabilities") {
                    if let ents = entitlements {
                        capabilityRow("JIT", enabled: debuggerAttached)
                        capabilityRow("Increased memory", enabled: ents.increasedMemory)
                        capabilityRow("64-bit address space", enabled: ents.extendedVA)
                    }
                }
            }
            .navigationTitle("Runtime Status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Done") { showRuntimeStatus = false }
            }
        }
    }

    private func pipelineRow(_ title: String, detail: String, state: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Circle().fill(color).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(state).font(.caption.bold()).foregroundStyle(color)
        }
    }

    /// ml796: what the screen shows from Play until the game's first frame.
    /// The JIT pool allocation suspends the whole process for a few seconds,
    /// so this must be on screen BEFORE runWineFullSequence starts.
    private var launchOverlay: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.06, green: 0.07, blue: 0.11), Color(red: 0.02, green: 0.02, blue: 0.04)],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: 22) {
                // GameHub-style: system ⇄ game icon.
                HStack(spacing: 28) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 52, weight: .regular))
                        .foregroundStyle(.white)
                        .shadow(color: .white.opacity(0.35), radius: 16)
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                    if let g = launchingGame, let icon = GameLibrary.shared.icons[g.id] {
                        Image(uiImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 84, height: 84)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .shadow(color: .black.opacity(0.5), radius: 12)
                    } else {
                        Image(systemName: "gamecontroller.fill")
                            .font(.system(size: 52))
                            .foregroundStyle(.white)
                    }
                }
                Text(launchingGame?.title ?? "")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(launchStatusText)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(Color(red: 0.10, green: 0.62, blue: 1.0))
                        .frame(width: 110)
                        .offset(x: launchBarPhase ? 150 : 0)
                }
                .frame(width: 260, height: 6)
                .clipShape(Capsule())
                .onAppear {
                    launchBarPhase = false
                    withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                        launchBarPhase = true
                    }
                }
            }
            .padding(32)
        }
    }

    private var launchStatusText: String {
        switch launcherSession {
        case .enablingJIT: return "Enabling JIT…"
        case .launching: return "Launching game…"
        default: return "Loading…"
        }
    }

    private var showLaunchOverlay: Bool {
        guard launchingGame != nil, !firstFrameSeen else { return false }
        switch launcherSession {
        case .enablingJIT, .launching, .playing: return true
        default: return false
        }
    }

    private var fullScreenDesktop: some View {
        ZStack {
            Color.black
            MadeiraMetalView()
            if showLaunchOverlay {
                launchOverlay
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: showLaunchOverlay)
        .ignoresSafeArea()
        .statusBarHidden(true)
        .perfMonitored()
        // ml797: the Metal host and the compositor are window-level views
        // ABOVE this SwiftUI tree, so they must stay hidden while the
        // loading screen is up or it is covered by a black surface.
        .onChange(of: showLaunchOverlay) { _, show in
            MetalHostView.shared.isHidden = show
            winios_set_compositor_hidden(show ? 1 : 0)
        }
        .onAppear {
            MetalHostView.shared.isHidden = showLaunchOverlay
            winios_set_compositor_hidden(showLaunchOverlay ? 1 : 0)
            touchControls.fullScreen = true
            if touchControls.visible { touchControls.ensureDefaultLayout() }
            TouchControlsHost.attach()
            requestOrientation(.landscape)
        }
        .onDisappear {
            touchControls.editing = false
            touchControls.fullScreen = false
            requestOrientation(MadeiraAppDelegate.normalOrientations)
        }
    }

    private func requestOrientation(_ orientations: UIInterfaceOrientationMask) {
        MadeiraAppDelegate.orientationLock = orientations
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        let root = scene.keyWindow?.rootViewController
        // UIKit caches supportedInterfaceOrientations. Invalidate it before
        // asking the scene for new geometry, then repeat on the next run-loop
        // turn after SwiftUI has completed its full-screen layout swap.
        root?.setNeedsUpdateOfSupportedInterfaceOrientations()
        if #available(iOS 16.0, *) {
            DispatchQueue.main.async {
                root?.setNeedsUpdateOfSupportedInterfaceOrientations()
                scene.requestGeometryUpdate(
                    UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: orientations)
                ) { error in
                    LogStore.shared.log("Orientation request failed: \(error.localizedDescription)",
                                        level: .error)
                }
                // The controller overlay lives in its own transparent UIWindow.
                // UIKit updates the app window when scene geometry changes, but
                // this manually framed auxiliary window can retain the old
                // portrait bounds. Re-attach on the next layout turns so its
                // safe-area toolbar follows the landscape scene instead of
                // landing in the middle of the display.
                TouchControlsHost.attach()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    TouchControlsHost.attach()
                }
            }
        }
    }

    private var settingsScreen: some View {
        NavigationStack {
            Form {
                Section("Input") {
                    Picker("Pointer mode", selection: $input.relative) {
                        Text("Absolute").tag(false)
                        Text("Relative").tag(true)
                    }
                    HStack {
                        Text("Sensitivity")
                        Slider(value: input.relative ? $input.sensRel : $input.sensAbs, in: 0.1...8.0)
                        Text(String(format: "%.1f", input.relative ? input.sensRel : input.sensAbs))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 28)
                    }
                    NavigationLink {
                        GamepadSettingsView()
                    } label: {
                        HStack {
                            Label("Physical controller", systemImage: "gamecontroller.fill")
                            Spacer()
                            Text(gamepad.controllerName ?? "None")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle(isOn: $touchControls.visible) {
                        Label("Touch controller overlay", systemImage: "gamecontroller")
                    }
                    Button {
                        touchControls.visible = true
                        touchControls.ensureDefaultLayout()
                        touchControls.editing = true
                        desktopFullScreen = true
                    } label: {
                        Label("Open layout editor", systemImage: "rectangle.and.hand.point.up.left")
                    }
                }

                Section("Performance") {
                    Picker("Frame rate cap", selection: $frameCapSetting) {
                        ForEach(FrameCap.allCases) { c in
                            Text(c.settingsLabel).tag(Int(c.rawValue))
                        }
                    }
                    .onChange(of: frameCapSetting) { _, v in
                        if let c = FrameCap(rawValue: Int32(v)) { FrameCap.apply(c, persist: true) }
                    }
                    Toggle("Cool down automatically", isOn: $autoCoolDown)
                    Text("A lower cap is the biggest heat saver: the game's frame loop waits on the display, so the CPU translation work per second falls with it. Auto cool-down drops to 30 fps while iOS reports the phone as hot and restores your cap once it is cool. The pill in the overlay changes the cap too.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("FEX Engine") {
                    Picker("Default profile", selection: $compatibilityMode) {
                        Text("Stability").tag("Stability")
                        Text("Performance").tag("Performance")
                    }
                    Toggle("Skip x86 memory-ordering emulation", isOn: $fexNoTSO)
                    Text("Experimental. Turns off FEX's TSO emulation for a large CPU saving in many games, but titles that rely on strict x86 memory ordering can glitch or crash. Applies on the next launch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    LabeledContent("Translation", value: "x86-64 → ARM64")
                    LabeledContent("JIT", value: statusText)
                    NavigationLink("Engine diagnostics") {
                        List {
                            Section("Capabilities") {
                                if let ents = entitlements {
                                    capabilityRow("JIT", enabled: debuggerAttached)
                                    capabilityRow("Increased memory", enabled: ents.increasedMemory)
                                    capabilityRow("64-bit address space", enabled: ents.extendedVA)
                                }
                            }
                            Section("Diagnostics") {
                                Toggle("Detailed runtime diagnostics", isOn: $input.diagnostics)
                                Toggle("Verbose Wine trace (slow)", isOn: $wineVerbose)
                                Text("Logs every file open, module load, exception dispatch and process event to madeira-log.txt. Use it to capture a crash, then turn it off. Applies on the next launch.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .navigationTitle("FEX Engine")
                    }
                }

                Section("DXMT Renderer") {
                    LabeledContent("API", value: "Direct3D 11")
                    LabeledContent("Backend", value: "Metal")
                    LabeledContent("Build", value: "Bundled")
                    Text("Per-title DXMT overrides can be supplied through madeira-dxmt.txt in Files.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Screen") {
                    Picker("Resolution", selection: $desktopResolution) {
                        ForEach(Self.desktopResolutions, id: \.self) { r in
                            Text(r).tag(r)
                        }
                    }
                    Text("Screen size games see when launched from the Games tab (they default to it and can pick smaller modes), and the size of the Wine desktop. Bigger screens look sharper but cost GPU time and shrink the Explorer UI. Takes effect on the next launch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Performance Overlay") {
                    Toggle(isOn: $perfOverlayEnabled) {
                        Label("Show FPS, memory and thermal readout", systemImage: "gauge.with.dots.needle.67percent")
                    }
                    Text("Shown beside the game surface and in full screen. Memory and thermal changes are always written to the session log, whether or not the readout is on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Help") {
                    NavigationLink {
                        SetupGuideView()
                    } label: {
                        Label("Setup guide", systemImage: "book.closed")
                    }
                }

                Section("Developer") {
                    NavigationLink {
                        developerScreen
                    } label: {
                        Label("Developer launchers", systemImage: "hammer.fill")
                    }
                }

                Section("About") {
                    LabeledContent("Madeira", value: Self.appVersionText)
                    LabeledContent("Device", value: deviceInfo)
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func capabilityRow(_ title: String, enabled: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            Image(systemName: enabled ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(enabled ? .green : .orange)
        }
    }

    /// Portrait session overview. Detailed capabilities and logs deliberately
    /// live in sheets so the primary surface stays focused on the desktop.
    private var portraitBody: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .font(.title3.bold())
                    .foregroundStyle(.indigo)
                    .frame(width: 46, height: 46)
                    .background(.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Windows Desktop")
                        .font(.headline)
                    Label(desktopIsRunning ? "Session running"
                          : desktopShutDown ? "Desktop off (runtime idle)" : "Ready to launch",
                          systemImage: "circle.fill")
                        .font(.caption)
                        .foregroundStyle(desktopIsRunning ? .green : .secondary)
                }
                Spacer()
                Button {
                    showRuntimeStatus = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.title3)
                }
            }
            .padding(.horizontal)

            MadeiraMetalView()
                .frame(maxWidth: .infinity)
                .frame(height: hSizeClass == .regular ? 520 : 360)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(.horizontal)

            if perfOverlayEnabled {
                FPSOverlay()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal)
            }

            activityControls

            Button {
                showActivityLogs = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "text.alignleft")
                        .foregroundStyle(.indigo)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Session Log")
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                        Text(logStore.entries.isEmpty
                             ? "No runtime messages"
                             : "\(logStore.entries.count) recent events")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)
                }
                .padding(15)
                .background(Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal)

            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .background(Color(uiColor: .systemGroupedBackground))
        .perfMonitored()
    }

    private var activityControls: some View {
        HStack(spacing: 10) {
            // Same launch as Settings → Developer launchers → Wine Virtual
            // Desktop, reachable from the tab where the desktop is shown.
            Button {
                if desktopShutDown {
                    resumeDesktop()
                } else {
                    ensureJIT { ok in
                        // The desktop is not a "game": the launcher goes back
                        // to idle either way.
                        launcherSession = .idle
                        if ok { launchVirtualDesktop() }
                    }
                }
            } label: {
                Label(desktopIsRunning ? "Running" : "Start Desktop",
                      systemImage: desktopIsRunning ? "desktopcomputer.and.arrow.down" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.mint)
            .disabled(desktopIsRunning)

            // The touch-controller toggle lives in the full-screen toolbar
            // and Settings → Input; it was redundant here.
            Button {
                desktopFullScreen = true
            } label: {
                Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
        }
        .controlSize(.large)
        .padding(.horizontal)
        .padding(.bottom, 10)
    }

    /// Landscape: game mode. Full-height 4:3 surface centered (aspect-fit
    /// happens in MetalBackedView); ALL controls live in the pillarbox
    /// bars left/right of the game — the window-level surface would cover
    /// anything drawn over the game area itself. No header/log/nav chrome.
    private var landscapeBody: some View {
        GeometryReader { geo in
            let gameW = min(geo.size.width, geo.size.height * 4.0 / 3.0)
            let barW = max((geo.size.width - gameW) / 2.0, 44)
            ZStack {
                Color.black
                MadeiraMetalView()
                // Controls removed for now (ml586): game-only landscape.
                // The FPS readout stays, pinned in the right pillarbox bar —
                // the window-level surface covers anything drawn over the
                // game area itself, so it cannot ride on the game view.
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    VStack {
                        FPSOverlay(compact: true)
                        Spacer()
                    }
                    .frame(width: barW)
                }
            }
        }
        .ignoresSafeArea()
        .background(Color.black)
        .perfMonitored()
    }

    /// Hold-to-press key: VK down on touch, VK up on release — for keys
    /// games treat as held (arrows). Same winios queue as keyButton.
    private func holdKeyButton(_ label: String, vk: Int32, big: Bool = false) -> some View {
        HoldKeyView(label: label, vk: vk, big: big)
    }

    /// Small on-screen key: posts VK down, then up 60ms later, through the
    /// winios input queue (same path as touch→mouse).
    // ml641 pointer panel ------------------------------------------------
    private var pointerToggleButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.28)) { pointerPanel.toggle() }
            // The window-level pad fades itself; see JoystickPadState.hidden.
            JoystickPadState.shared.hidden = pointerPanel
        } label: {
            Image(systemName: pointerPanel ? "xmark" : "cursorarrow")
                .font(.system(size: 17, weight: .medium))
                .frame(minWidth: 40, minHeight: 32)
                .background(Color.secondary.opacity(0.25))
                .cornerRadius(6)
        }
        .matchedGeometryEffect(id: "pointerBtn", in: pointerNS)
    }

    /// ml649: heavy diagnostics on/off, live. Stroke icon, dimmed when quiet —
    /// same visual language as the controls-visibility button.
    private var diagToggleButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            input.diagnostics.toggle()
        } label: {
            Image(systemName: "ladybug")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(.white.opacity(input.diagnostics ? 1.0 : 0.35))
                .frame(minWidth: 40, minHeight: 32)
                .background(Color.secondary.opacity(0.25))
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    private var pointerModeToggle: some View {
        Button {
            input.relative.toggle()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Text(input.relative ? "Relative" : "Absolute")
                .font(.system(size: 13, weight: .semibold))
                .frame(minWidth: 82, minHeight: 32)
                .background((input.relative ? Color.accentColor : Color.secondary).opacity(0.28))
                .cornerRadius(6)
        }
        .transition(.opacity)
    }

    /// One slider bound to whichever mode is live, so the two values are edited
    /// independently and both persist.
    private var pointerSensSlider: some View {
        HStack(spacing: 8) {
            Slider(value: input.relative ? $input.sensRel : $input.sensAbs, in: 0.10...8.0)
            Text(String(format: "%.2f", input.relative ? input.sensRel : input.sensAbs))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
        .transition(.opacity)
    }

    private func keyButton(_ label: String, vk: Int32) -> some View {
        Button(action: {
            winios_post_key(vk, 1)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.06) {
                winios_post_key(vk, 0)
            }
        }) {
            Text(label)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .frame(minWidth: 34, minHeight: 30)
                .background(Color.white.opacity(0.15))
                .cornerRadius(6)
        }
    }

    private func entitlementBadges(_ ents: EntitlementStatus) -> some View {
        HStack(spacing: 8) {
            // Live debugger/JIT state, not the (macOS-only, never granted on
            // iOS) allow-jit entitlement the old badge checked.
            entitlementBadge("JIT", granted: debuggerAttached)
            entitlementBadge("Memory+", granted: ents.increasedMemory)
            entitlementBadge("64-bit VA", granted: ents.extendedVA)
            Spacer()
            // Device model rides in this row (the old standalone statusHeader
            // row above it spent ~50pt of vertical space on nothing else).
            VStack(alignment: .trailing, spacing: 0) {
                Text("Device")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(deviceInfo)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            debuggerAttached = isDebuggerAttached()
        }
    }

    private func entitlementBadge(_ label: String, granted: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundColor(granted ? .green : .orange)
                .font(.caption2)
            Text(label)
                .font(.caption2)
                .foregroundColor(granted ? .primary : .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(granted ? Color.green.opacity(0.1) : Color.orange.opacity(0.1))
        )
    }

    private func logEntitlementStatus() {
        guard let ents = entitlements else { return }
        logStore.log("Checking entitlements...")
        logStore.log("  allow-jit: \(ents.jitAllowed)", level: ents.jitAllowed ? .success : .error)
        logStore.log("  increased-memory-limit: \(ents.increasedMemory)", level: ents.increasedMemory ? .success : .debug)
        logStore.log("  extended-virtual-addressing: \(ents.extendedVA)", level: ents.extendedVA ? .success : .debug)
        if !ents.extendedVA {
            logStore.log("  Tip: Use GetMoreRam to inject extended-virtual-addressing", level: .info)
        }
    }

    private func openDocumentsInFiles() {
        guard let url = URL(string: "shareddocuments://") else { return }
        UIApplication.shared.open(url) { opened in
            if !opened {
                logStore.log("Files could not be opened. Madeira Documents remains available under On My iPad.", level: .error)
            }
        }
    }

    private func calculatePrefixSize() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let prefix = documents.appendingPathComponent("wine", isDirectory: true)
        DispatchQueue.global(qos: .utility).async {
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
            let enumerator = FileManager.default.enumerator(at: prefix,
                                                            includingPropertiesForKeys: Array(keys),
                                                            options: [.skipsHiddenFiles])
            var bytes: Int64 = 0
            while let file = enumerator?.nextObject() as? URL {
                guard let values = try? file.resourceValues(forKeys: keys),
                      values.isRegularFile == true else { continue }
                bytes += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            }
            let text = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            DispatchQueue.main.async { prefixSizeText = text }
        }
    }

    private func prepareDirectLaunch(_ title: String) {
        selectedTab = .desktop
        logStore.log("\(title): \(compatibilityMode) launch profile selected")
        if compatibilityMode == "Performance" {
            // The production path's tested FEX defaults remain the performance
            // profile. Stability is intentionally metadata-only until a
            // conservative flag set has been validated on real titles.
            unsetenv("FEX_O0")
        }
    }

    /// Documents/madeira-log.txt, written by wine_log_set_file in
    /// WineProcessBridge.m. Survives a crash, unlike the in-memory session log.
    private var wineLogFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("madeira-log.txt")
    }

    /// Explorer shell desktop with services.exe as its child.
    ///
    /// S3-pre R2v2: raw rpcss.exe CANNOT run standalone — its wmain
    /// unconditionally StartServiceCtrlDispatcherW's (rpcss_main.c:282),
    /// which RPCs back to the SCM; without services.exe it raised + wedged
    /// in service_run_main_thread, and explorer's CoRegisterClassObject
    /// wedged behind it (seq-3680 run). Proper bootstrap: explorer's
    /// cmdline child = services.exe (SCM host, windows-subsystem = no
    /// console). It creates \pipe\svcctl early, runs auto-start services
    /// (MountMgr/Eventlog/NDIS/nsiproxy/PlugPlay — winedevice/plugplay are
    /// bundled; failures tolerated), and combase's start_rpcss then
    /// demand-starts RpcSs through the SCM with a 30s start-pending wait →
    /// rpcss runs as services' child (3-deep tree, proven depth) with a
    /// proper dispatcher connection → epmapper up → real COM. Known risk:
    /// if shellwindows_init beats services.exe's RPC_Init, OpenSCManager
    /// fails → watch whether that fails fast or hits the
    /// RaiseException→CS wedge again.
    ///
    /// Desktop size comes from Settings → Virtual Desktop (default
    /// 960x540). Games launched from this desktop get a mode list capped
    /// at this size.
    private func launchVirtualDesktop() {
        selectedTab = .desktop
        let (deskW, deskH) = desktopSize
        logStore.log("Virtual desktop: \(deskW)x\(deskH)")
        setenv("MADEIRA_EXE", "explorer.exe", 1)
        // ml791: explorer runs ONE command after creating the desktop. It
        // is now the session agent, which starts services.exe itself and
        // then launches whatever the Games tab asks for (build/agent).
        setenv("MADEIRA_ARGS",
               "/desktop=shell,\(deskW)x\(deskH) C:\\windows\\system32\\madeira-agent.exe C:\\windows\\system32\\services.exe", 1)
        setenv("MADEIRA_DESKTOP", "1", 1)
        setenv("MADEIRA_SCREEN_W", String(deskW), 1)
        setenv("MADEIRA_SCREEN_H", String(deskH), 1)
        runWineFullSequence()
    }

    /// ml790: Start -> "Exit desktop" finished. explorer asked for
    /// confirmation, ExitWindows() ran `wineboot --end-session --shutdown`,
    /// wineboot sent WM_QUERYENDSESSION/WM_ENDSESSION to every program and
    /// TerminateProcess()ed the ones still alive, and exited 0 (stage 2).
    /// On this port that is the end of the chain: the fork's server keeps
    /// the desktop open (auto-close suppressed), so explorer and the service
    /// processes stay alive underneath. The user wants the desktop gone, not
    /// the app (ml788/ml789 ended the app here), so: leave full screen, hide
    /// the compositor, and let Start Desktop show the now-empty desktop
    /// again. Nothing is torn down — the runtime cannot be re-initialised in
    /// this process, and the live session is exactly what makes "start" fast.
    private func desktopShutDownNow() {
        logStore.log("Exit desktop: all programs closed — desktop shut down. Start Desktop shows it again.", level: .success)
        DispatchQueue.main.async {
            self.desktopFullScreen = false
            self.desktopShutDown = true
        }
    }

    /// Start Desktop after an Exit desktop: the session is still there, so
    /// showing it again is all it takes.
    private func resumeDesktop() {
        logStore.log("Desktop resumed")
        desktopShutDown = false
        selectedTab = .desktop
    }

    /// The desktop's root process (explorer.exe /desktop) itself ended, which
    /// Exit desktop never does on this port: explorer crashed or was killed.
    /// wine_process_thread has stopped the wineserver with it and the runtime
    /// cannot be restarted in this process, so hide the dead surface and say
    /// what to do instead of sitting on a black desktop.
    private func desktopProcessDied(exitCode: Int) {
        logStore.log("Desktop process ended (exit code \(exitCode)) — the Wine runtime is stopped; relaunch Madeira to start a new desktop", level: .error)
        DispatchQueue.main.async {
            self.desktopFullScreen = false
            self.desktopShutDown = true
        }
    }

    private func launchThumper() {
        prepareDirectLaunch("Thumper")
        setenv("MADEIRA_EXE", "C:\\Program Files\\Thumper\\THUMPER_win10.exe", 1)
        unsetenv("MADEIRA_ARGS")
        unsetenv("MADEIRA_DESKTOP")
        runWineFullSequence()
    }

    /// Settings → Developer: the former Library "Developer launchers" row
    /// (Wine launch targets, JIT setup, low-level runtime tests) and the
    /// Steam handoff preference.
    private var developerScreen: some View {
        List {
            Section("Steam handoff") {
                Toggle(isOn: $steamMinimalLayout) {
                    Label("Game-first layout", systemImage: "rectangle.grid.2x2")
                }
                Text("Saves the preferred presentation for CEF handoff. The current Steam test launcher remains in Developer tools.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Launchers") {
                Button("Enable JIT") {
                    enableJITViaStikDebug()
                }

                Button("Steam Testing") {
                    // Steam S3 first boot: virtual desktop (Steam needs a
                    // window manager) + services.exe (SCM → rpcss for Steam's
                    // COM, the chain proven in the rpcss milestone) + steam.exe
                    // itself, all launched by C:\steam-launch.bat (pushed to
                    // the prefix). Batch avoids quote-escaping hell; combase's
                    // 5s OpenSCManager retry covers the services-vs-steam race.
                    // Steam install = CrossOver copy at C:\Program Files (x86)\
                    // Steam (all boot binaries verified x86-64; steamwebhelper
                    // /libcef = 209MB → watch pool: first webhelper may fit,
                    // multiples need .text sharing). Flags: -no-cef-sandbox
                    // (sandbox can't work in Wine), -cef-disable-gpu (software
                    // render), -console (Steam's own log → our stderr). Steam
                    // WILL try to self-update through our GnuTLS stack — that
                    // attempt is itself an informative S0 re-test.
                    let deskW = 1024, deskH = 768
                    // ml589: find Steam and (re)write the launch batch. Returns
                    // false — having logged why — when there is nothing to run.
                    guard prepareSteamLaunch() else { return }
                    // ml590 STEP 1 (one-run phase check, NOT a timing measurement):
                    // arm the ml578 sock-wire probe. It answers exactly one
                    // question — does today's ~1s CM failure reach the same TLS
                    // phase ml578 did (ServerHello -> client Finished -> server
                    // encrypted records), or does it die earlier?
                    //
                    // Its numbers are NOT trustworthy as timings: no monotonic
                    // clock, a getpeername() before EVERY send/recv even after the
                    // 12-line budget is spent, and synchronous dprintf() on a path
                    // whose whole ping budget is 1000ms — it perturbs what it
                    // measures, which is why ml579 gated it off. Step 2 replaces it
                    // with a per-socket timeline (cached peer, generation counter,
                    // one line at close) that can be trusted for timing.
                    //
                    // COLD LAUNCH REQUIRED: ios_sock_wire() latches this env into a
                    // static on its FIRST call (socket.c:842), so if any earlier
                    // Wine session in this app process already touched a socket the
                    // flag is stuck off. Force-quit, launch, press this first.
                    // ml591: the phase question is ANSWERED, so the per-event
                    // probe goes back off — it distorts the very budget step 2
                    // measures. [sock-tl] replaces it and needs no env var.
                    unsetenv("MADEIRA_SOCK_WIRE")
                    // ml594 A/B: post-login hang = FEX optimizer NONTERMINATION.
                    // Chrome_InProcRendererThread (wtid 0208) sampled 9x at
                    // 97-100% CPU (cpu=277 -> 918, run=1) inside
                    // DeadFlagCalculationEliminination::ProcessBlock while EVERY
                    // other thread sat at cpu=0 and Steam presented ZERO further
                    // frames. One CompileBlock entered that pass and never came
                    // back, and the thread holds a fexlock read ref, so it can
                    // stall other FEX threads too. NOT a network/cryptnet/wineserver
                    // wait — our new guards never fired.
                    //
                    // FEX_O0 disables the default x87 + dead-flag passes
                    // (FEXCore/Source/Interface/IR/PassManager.cpp:70). Slower, but
                    // if the hang disappears the pass is convicted and the next step
                    // is disabling ONLY CreateDeadFlagCalculationEliminination().
                    // ml596: FEX_O0 has NEVER ACTUALLY BEEN TESTED, and my earlier
                    // comment here blaming it for an execute fault was WRONG.
                    // ml595 died because the JIT pool never existed: all three
                    // placement attempts returned 0x7000000000 (the forbidden guest
                    // 64G window), we logged "continuing without it", and Wine then
                    // ran with `pool not initialised` -- so LdrInitializeThunk stayed
                    // at its PE address 0x71ffd77654 instead of being redirected into
                    // the pool (a healthy run logs `redirected PC 0x71ffd77654 ->
                    // 0x12078f654`). The execute fault was the guaranteed consequence
                    // of launching without the execution substrate, and pool placement
                    // happens HERE in Swift before FEX reads any env var -- FEX_O0
                    // cannot influence it. (Caught by Sol.)
                    //
                    // Convict the dead-flag pass with a targeted FEX build that
                    // disables ONLY CreateDeadFlagCalculationEliminination(); broad O0
                    // also drops the x87 pass and proves less. unsetenv keeps a stale
                    // value from a previous launch out of play.
                    unsetenv("FEX_O0")
                    // ml597 A/B: remove ONLY DeadFlagCalculationEliminination, the pass
                    // the renderer thread was pinned inside during the ml594 hang.
                    // Everything else in the pipeline (incl. x87) stays exactly as in a
                    // known-good run, so a result here implicates or clears this one pass.
                    // The [dfe-guard] bounds ship active in BOTH arms — if the pass is
                    // exonerated and the hang recurs, they still name the failure mode.
                    // ml598 ISOLATION RUN: gate OFF, same rebuilt FEX.
                    // ml597 crashed with c000001d (ILLEGAL INSTRUCTION) after the
                    // desktop came up, but that run changed TWO things at once: my
                    // DFE gate AND ~107 lines of FEX source committed today that had
                    // never been built — the shipped xtajit64.dll dated Aug 6 while
                    // Core.cpp/IosJitAlias.cpp/TSOHandlerConfig.h and a net rewrite of
                    // WinAPI/IO.cpp were newer. Any of those can produce a
                    // miscompilation-shaped fault, so ml597 convicts nothing.
                    //   crashes again -> the REBUILD is at fault, DFE still untested
                    //   runs fine     -> disabling DFE is what breaks it
                    unsetenv("MADEIRA_NO_DFE")
                    // ml599: name the pass that corrupts the IR list.
                    //
                    // ml598 settled the mechanism: FEX hangs walking a block
                    // BACKWARDS because the intrusive Previous chain never reaches
                    // CodeBegin. Two passes make that assumption —
                    // DeadFlagCalculationEliminination::ProcessBlock and
                    // ConstrainedRAPass::Run — and the store-page freeze was the
                    // second one (PC pinned inside libarm64ecfex.dll RVA
                    // 0x100b0c-0x100cdc, all within ConstrainedRAPass::Run, for
                    // minutes at ~100% CPU while frames stayed at 4,114).
                    //
                    // Both now validate the block BEFORE touching it and repair the
                    // Previous chain from the forward chain when that is intact, so
                    // the hang should be gone either way. This var adds the sweep
                    // that reports WHICH pass first breaks the list, so the run also
                    // produces the root cause and not just the containment.
                    // ml601: SWEEP OFF. Two runs checked 118M and 47M blocks and found
                    // corruption exactly once (block 260, ml599b) — the after-every-pass
                    // sweep is not earning its cost, and it taxes every large compile.
                    // The unconditional parts STAY ON regardless of this variable: the
                    // cheap backward check at DFE and RA entry, the repair, and the
                    // bounded-walk guards. Only the attribution sweep is disabled.
                    // Set it again for a run that is specifically hunting the corrupter.
                    unsetenv("MADEIRA_IR_TOPO")
                    // ml623: TARGETED IR/RA CAPTURE for the ULTRAKILL Mono wall.
                    //
                    // FEX miscompiles ONE instruction in Mono's x86-64 emitter:
                    //   mono-2.0-bdwgc.dll+0x4db25b   mov byte ptr [rcx+2], al
                    // With RCX=0x7040140010 (valid, a fresh RWX code buffer) and AL=0x4c,
                    // it emitted `movz w6,#0x44 ; orr x8,x8,x6 ; dmb ish ; strb w8,[x6,xzr]`
                    // -- the address register still held the IMMEDIATE because the
                    // `add x6, x0, #2` that BOTH sibling branches emit was never generated,
                    // so the store landed on 0x44.
                    //
                    // This prints that instruction's IR after the frontend and after every
                    // pass, plus the emitted host bytes. The last stage at which the address
                    // computation still exists names the culprit: frontend/decoder, a named
                    // pass, RA liveness, or the ARM emitter.
                    //
                    // Compile-time only, capped at 4 captures. Unset it for a normal run.
                    setenv("MADEIRA_IRCAP_RVA", "0x4db25b", 1)
                    setenv("MADEIRA_IRCAP_MODULE", "mono-2.0-bdwgc.dll", 1)
                    setenv("MADEIRA_EXE", "explorer.exe", 1)
                    setenv("MADEIRA_ARGS",
                           "/desktop=shell,\(deskW)x\(deskH) cmd /c C:\\steam-launch.bat", 1)
                    setenv("MADEIRA_DESKTOP", "1", 1)
                    setenv("MADEIRA_SCREEN_W", String(deskW), 1)
                    setenv("MADEIRA_SCREEN_H", String(deskH), 1)
                    // ml371: surfdump ground truth — the "frozen desktop"
                    // question (fresh pixels never presented vs nothing
                    // painting upstream) is undecidable from the log alone
                    // because the [winios] present line caps at 12.
                    // ml556: surface PNG dumping also off for the clean baseline —
                    // it encodes a PNG on the present path. Restore "1" to re-enable.
                    unsetenv("MADEIRA_DUMP_SURFACES")
                    // ml493: bursts of N CONSECUTIVE frames per window. The
                    // login window's black regions change every frame, which
                    // the 2s-throttled first/latest dump can never show —
                    // adjacent frames are the only way to measure what moves.
                    setenv("MADEIRA_SURF_SEQ", "10", 1)
                    // ml515: SRCWATCH RE-ENABLED, now hooked in the MACH
                    // exception handler (where guest faults are actually
                    // delivered) instead of segv_handler. It consumes its own
                    // faults BEFORE every other classification and marks them
                    // handled via the canonical thread_set_state path, so a
                    // protection fault can no longer reach the guest as an AV.
                    // ml514 hooked the wrong path: 0 faults, black window 2/2.
                    /* ml530 (#78): srcwatch subject = the assembled steamui JS buffer, not the
                     // render bitmap. "1" would mean the legacy render subject, and the
                     // watch arms only ONCE — so with both call sites live, whichever ran
                     // first would silently win and the other would never arm at all.
                     //
                     // Target: V8 reports `SyntaxError: Invalid or unexpected token` on
                     // steamui JS that our file reads deliver byte-perfect (ml489: 73/73
                     // MATCH, the failing file 100% verified through NtReadFile). That is
                     // the DOMINANT Steam variance — 27 of 45 attempts stall right after
                     // BrowserReady because the UI script never parses — and the same
                     // corrupter family as the render glitch, so it buys both. */
                    /* ml533: back to the RENDER subject — the js subject is structurally
                    // blocked (the failing steamui files are read through a reused 64KB
                    // chunk buffer, so no assembled buffer exists in our view). The render
                    // watch now names the CALLER via the guest return address at [RSP],
                    // which is what the block-granular RIP could never do. */
                    // ml556 CLEAN-BASELINE TEST: srcwatch OFF.
                    //
                    // It write-protects the render bitmap and takes a Mach fault
                    // per page ON THE RENDER HOT PATH, and the correlation across
                    // this session is stark:
                    //     attributions 1824/2370/426/2721 -> run dies at 36-52 s
                    //     attributions 0/0/0              -> run reaches 94-106 s
                    // Runs carrying our instrumentation die in roughly half the
                    // time. Before attributing the crash to Steam or to FEX we owe
                    // ourselves the one-variable control: does it still crash with
                    // the probe off? Re-enable by restoring "render".
                    // ml574: arm the dead-release detector in wineserver.
                    // O(n) walk of object_list on every release_object — slow by
                    // design, diagnostic only. Set to "0" to disarm.
                    // ml579: DISABLED. It walks the global wineserver object list on
                    // EVERY release_object() — O(n) in the single-threaded server. It
                    // already caught the free_async_queue over-release (ml574) and that
                    // fix is shipped; leaving the detector armed just starves the server,
                    // and Steam allows each CM ping only 1000 ms. Set to "1" to re-arm.
                    setenv("MADEIRA_DEAD_RELEASE", "0", 1)
                    setenv("MADEIRA_SRCWATCH", "off", 1)
                    // ml548: restrict srcwatch to the row band where displacement
                    // was actually MEASURED, so the 400-attribution budget is not
                    // spent on the full-frame clear (which touches every page
                    // first and made the content painters invisible in ml517).
                    // Band from ml543 frame 009: the Steam logo core landed at
                    // (96,188) instead of (350,188) — exactly -254 px, one tile
                    // pitch — so rows 150..230 bracket the displaced element.
                    // ml550: was "150,230" — chosen for the SPLASH logo. On a
                    // login-window run that band produced ZERO attributions
                    // (426 on the splash run), because nothing painted there.
                    // Widen to most of the surface so the watch follows whatever
                    // the frame actually draws; the per-page budget still bounds
                    // the fault cost.
                    setenv("MADEIRA_SRCWATCH_ROWS", "0,400", 1)
                    // ml527 (#82 RETEST, ONE VARIABLE): run V8 with its JIT on.
                    //
                    // ml526's phase timeline made the case concrete — of ~39s to
                    // the login window, the single biggest block is 13.0s of
                    // BrowserReady -> GetDesiredSteamUIWindows, i.e. Steam's UI
                    // JavaScript booting, and interpreted V8 costs 5-20x there.
                    //
                    // #82 convicted jitless-off because both trial runs parked
                    // CrBrowserMain shortly after BrowserReady (ml474b +104s,
                    // ml475 +4s). ⚠️ Both ran with StikDebug attached and
                    // spinning, when every trap was a round-trip to a starved
                    // debugger — the overhead that made webhelper bring-up 89s
                    // instead of 9s (b439be6). V8's JIT emits runtime x86, the
                    // heaviest trap/compile workload in the process, so it is
                    // exactly what that overhead punished worst. The verdict may
                    // not survive early detach.
                    //
                    // ⛔ VERDICT (ml527, 2 runs): #82 SURVIVES early detach — jitless
                    // stays ON. Both jitless-off runs died in the SAME window ml474b
                    // and ml475 died in: right after BrowserReady, before
                    // GetDesiredSteamUIWindows was ever reached (13:20:19 and
                    // 13:22:45), so 4/4 across two completely different debugger
                    // regimes. The failure MODE changed — a c0000005 ->
                    // chrome_elf.dll+0xd4153 -> ffff7001 Crashpad termination rather
                    // than #82's park in NtWaitForAlertByThreadId — but the window is
                    // identical, and jitless-ON reaches the login window repeatedly
                    // through that same window.
                    //
                    // No consolation prize either: BrowserReady took 12s and 10s with
                    // the JIT on vs 8-11s (median 9s) with it off, because V8's JIT
                    // emits runtime x86 that FEX must then compile. So the debugger
                    // overhead was NOT what convicted jitless-off, and the 13s of
                    // Steam UI JavaScript stays unmeasured — neither run survived to
                    // reach it.
                    //
                    // Flip to "0" only alongside a fix for the post-BrowserReady death.
                    setenv("MADEIRA_JITLESS", "1", 1)
                    // ml514 note (kept for the record): The ml514 watch
                    // armed correctly (76 pages protected) but logged ZERO
                    // faults and produced an all-black window on two runs: the
                    // hook went in the BSD segv_handler, while guest faults in
                    // this port are handled IN-MACH by the exception server, so
                    // the protection fault was delivered to the guest as an AV
                    // and killed Chromium's paint. A probe must never break the
                    // path it measures. To revive it, hook the Mach exception
                    // server (where ios_emulate_unaligned_guest_access already
                    // runs), not segv_handler, and re-enable this env var.
                    // ml502 sentinel: DELIBERATELY NOT ENABLED. It stamps
                    // magenta into currently-black pixels, and on windows
                    // Chromium does not fully rewrite it SURVIVES and reaches
                    // the screen (console 0x200bc hit untouched=177891 in one
                    // round). It answered its question in ml503/ml504 —
                    // untouched=0 on the login window proved Chromium writes
                    // every pixel — so it must not ship enabled. Re-enable
                    // with MADEIRA_SURF_SENTINEL=1 if the question returns.
                    runWineFullSequence()
                }

                Button("Wine Virtual Desktop") {
                    launchVirtualDesktop()
                }

                // ml741: Stray (UE4). Launch the shipping binary DIRECTLY rather
                // than Stray.exe -- the launcher builds its child's command line
                // itself and passed only "Hk_project", so Unreal picked its
                // default RHI. That default is DX12 for this title and we only
                // implement D3D11, which is why the first run sat on an
                // unsignalled event for 97s at startup instead of failing loudly.
                //
                // Args are overridable at runtime from Documents/madeira-args.txt
                // so UE4 flags can be tried without a rebuild; the string below is
                // the default when that file is absent.
                Button("Stray (UE4, -dx11)") {
                    setenv("MADEIRA_EXE",
                           "C:\\Program Files\\Stray\\Hk_project\\Binaries\\Win64\\Stray-Win64-Shipping.exe", 1)
                    var args = "Hk_project -dx11 -windowed"
                    if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
                       let txt = try? String(contentsOf: d.appendingPathComponent("madeira-args.txt"), encoding: .utf8) {
                        let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !v.isEmpty { args = v }
                    }
                    setenv("MADEIRA_ARGS", args, 1)
                    unsetenv("MADEIRA_DESKTOP")
                    logStore.log("Stray: args = \(args)")
                    runWineFullSequence()
                }

                Button("Thumper (standalone)") {
                    launchThumper()
                }

                Button("x64 DX11 cube") {
                    setenv("MADEIRA_EXE", "cube-x64.exe", 1)
                    unsetenv("MADEIRA_ARGS")
                    runWineFullSequence()
                }

                // ml731c: one-second check of the Windows clock contract
                // (GetTickCount64 / system time / unbiased interrupt time /
                // QueryPerformanceCounter). Verifying this by hand previously
                // cost a five-minute game run plus a control-log comparison,
                // and the game is too unstable to serve as a measuring tool.
                // Each clock is checked separately so a partial failure names
                // itself: QPC passing alone is the shared-page signature.
                Button("x64 clock test") {
                    setenv("MADEIRA_EXE", "clocktest-x64.exe", 1)
                    unsetenv("MADEIRA_ARGS")
                    unsetenv("MADEIRA_DESKTOP")
                    runWineFullSequence()
                }

                Button("arm64 DX11 cube") {
                    runTriangleTest()
                }
            }

            Section("Log") {
                Button("Clear Log", role: .destructive) {
                    logStore.clear()
                }
            }
        }
        .navigationTitle("Developer")
    }

    private func runTriangleTest() {
        logStore.log("D3D11 triangle test: full sequence", level: .info)
        setenv("MADEIRA_EXE", "cube.exe", 1)
        unsetenv("MADEIRA_USE_ARM64EC")
        unsetenv("MADEIRA_DESKTOP")
#if MADEIRA_SIMULATOR_REAL_RUNTIME
        // The simulator and cube.exe are both ARM64, so this path needs Wine
        // and DXMT but no FEX translation or executable JIT pool.
        selectedTab = .desktop
        logStore.log("Simulator ARM64 path: starting Wine without FEX/JIT", level: .success)
        DispatchQueue.global(qos: .userInitiated).async {
            self.startWineserver()
            Thread.sleep(forTimeInterval: 1.0)
            self.startWineProcess()
        }
#else
        runWineFullSequence()
#endif
    }

    private var logConsole: some View {
        let entries = logStore.entries.sorted(by: { $0.lastTimestamp > $1.lastTimestamp })
        return List(entries) { entry in
            HStack(alignment: .top, spacing: 8) {
                // Timestamp of LAST occurrence
                Text(timeString(entry.lastTimestamp))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 64, alignment: .leading)
                // Level chip
                Text(entry.level.rawValue)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(colorForLevel(entry.level))
                    .frame(width: 28, alignment: .leading)
                // Last raw message (the most recent line that matched this signature)
                Text(entry.lastRaw)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                // Count badge (only if count > 1)
                if entry.count > 1 {
                    Text("×\(entry.count)")
                        .font(.system(.caption2, design: .monospaced).weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(4)
                        .foregroundColor(.secondary)
                }
            }
            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
        }
        .listStyle(.plain)
    }

    // ml540: ONE formatter for the whole app, built once on first use.
    //
    // This used to construct a fresh DateFormatter on every call — once per log
    // row per body evaluation — and each new instance opens ICU underneath
    // (udat_open -> SimpleDateFormat::initialize). That is not just wasteful,
    // it is where ml539 died: after Wine's main thread exited, ICU ran
    // _platform_strcmp on a pointer into that dead thread's stack (x0 sat 0x68C
    // below its recorded tsd_base) and took the whole app down. A single
    // long-lived formatter does the ICU open ONCE, at first log render, long
    // before Wine exists.
    private static let hhmmss: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // Main-thread only (SwiftUI body evaluation) — DateFormatter is not safe to
    // share across threads.
    private func timeString(_ date: Date) -> String {
        ContentView.hhmmss.string(from: date)
    }

    private var statusColor: Color {
        switch jitStatus {
        case .unknown: return .gray
        case .testing: return .yellow
        case .available: return .green
        case .mappingOnly: return .orange
        case .unavailable: return .red
        }
    }

    private var statusText: String {
        switch jitStatus {
        case .unknown: return "Not tested"
        case .testing: return "Testing..."
        case .available: return "Available"
        case .mappingOnly: return "Needs debugger"
        case .unavailable: return "Unavailable"
        }
    }

    private var deviceInfo: String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
        return machine
    }

    private func colorForLevel(_ level: LogStore.LogEntry.Level) -> Color {
        switch level {
        case .info: return .blue
        case .success: return .green
        case .error: return .red
        case .debug: return .gray
        }
    }

    private func runJITTest() {
        jitStatus = .testing
        logStore.log("Starting JIT test...")

        DispatchQueue.global(qos: .userInitiated).async {
            let result = jit_test_execute()

            DispatchQueue.main.async {
                switch result {
                case 42:
                    jitStatus = .available
                    logStore.log("JIT is fully functional!", level: .success)
                case -2:
                    jitStatus = .unavailable
                    logStore.log("CS_DEBUGGED not set. Use StikDebug to enable JIT for this app.", level: .error)
                    DispatchQueue.global(qos: .userInitiated).async {
                        let mappingOk = jit_test_mapping()
                        DispatchQueue.main.async {
                            if mappingOk {
                                jitStatus = .mappingOnly
                                logStore.log("Dual mapping works. Enable JIT via StikDebug to unlock execution.", level: .success)
                            }
                        }
                    }
                case -3:
                    jitStatus = .unavailable
                    logStore.log("Fault loop detected — try 'Test JIT (Alt)' for debugger-allocated memory", level: .error)
                default:
                    jitStatus = .unavailable
                    logStore.log("JIT test failed with result: \(result)", level: .error)
                }
            }
        }
    }

    private func runJITTestStrategy2() {
        jitStatus = .testing
        logStore.log("Starting JIT test (Strategy 2: debugger-allocated RX)...")

        DispatchQueue.global(qos: .userInitiated).async {
            let result = jit_test_execute_strategy2()

            DispatchQueue.main.async {
                switch result {
                case 42:
                    jitStatus = .available
                    logStore.log("JIT is fully functional (strategy 2)!", level: .success)
                case -2:
                    jitStatus = .unavailable
                    logStore.log("CS_DEBUGGED not set. Use StikDebug to enable JIT.", level: .error)
                case -3:
                    jitStatus = .unavailable
                    logStore.log("Fault loop — debugger-allocated pages also rejected", level: .error)
                default:
                    jitStatus = .unavailable
                    logStore.log("Strategy 2 failed with result: \(result)", level: .error)
                }
            }
        }
    }

    private func runFEXTest() {
        logStore.log("Starting FEX-Emu integration test...")
        jitStatus = .testing

        // Set up FEX log callback
        fex_set_log_callback { msg in
            if let msg = msg {
                let str = String(cString: msg)
                DispatchQueue.main.async {
                    LogStore.shared.log(str, level: .debug)
                }
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let result = fex_test_execute()

            DispatchQueue.main.async {
                switch result {
                case 42:
                    jitStatus = .available
                    logStore.log("FEX-Emu test PASSED: x86-64 code returned 42!", level: .success)
                case -1:
                    jitStatus = .unavailable
                    logStore.log("FEX-Emu test FAILED (init/setup error)", level: .error)
                default:
                    jitStatus = .unavailable
                    logStore.log("FEX-Emu test returned \(result)", level: .error)
                }
            }
        }
    }

    private func enableJITViaStikDebug() {
        jitStatus = .testing
        logStore.log("Requesting JIT via StikDebug URL scheme...")

        StikJITHelper.enableJIT { success in
            if success {
                jitStatus = .available
                logStore.log("JIT enabled! Debugger attached.", level: .success)
            } else {
                jitStatus = .unavailable
                logStore.log("Failed to enable JIT via StikDebug", level: .error)
            }
        }
    }

    /// Full sequence: allocate JIT pool, start wineserver, start Wine.
    /// Debugger stays attached during PE loading so mprotect_exec can use BRK
    /// to prepare code pages. Detach happens after Wine finishes + recovery.
    private func runWineFullSequence() {
        guard jit_check_debugged() else {
            logStore.log("JIT not enabled. Press 'Enable JIT' first.", level: .error)
            return
        }

        logStore.log("Running full Wine sequence...")

        // FEX reads FEX_* from the process environment (ARM64EC Module.cpp
        // passes _environ to FEX::Config::LoadConfig), and Wine imports the
        // unix env, so this reaches the game-side translator.
        if fexNoTSO {
            setenv("FEX_TSOENABLED", "0", 1)
            logStore.log("FEX: TSO emulation OFF (experimental, Settings → FEX Engine)")
        } else {
            unsetenv("FEX_TSOENABLED")
        }
        if wineVerbose {
            setenv("MADEIRA_DEBUG_VERBOSE", "1", 1)
            logStore.log("Wine: verbose trace ON (Settings → FEX Engine → Engine diagnostics)")
        } else {
            unsetenv("MADEIRA_DEBUG_VERBOSE")
        }

        // Start a main thread heartbeat to diagnose hang
        var heartbeatCount = 0
        let heartbeat = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            heartbeatCount += 1
            os_log("[HEARTBEAT] main thread alive #%d", heartbeatCount)
        }

        // Pause UI flushing — prevents ALL SwiftUI re-renders during Wine execution,
        // so zero main thread hang time accumulates while debugger is attached
        logStore.uiPaused = true

        // Suppress os_log from wineserver — hundreds of messages/sec cause os_log buffer
        // contention that blocks the main thread RunLoop, triggering iOS hang detection
        ws_log_quiet = 1

        DispatchQueue.global(qos: .userInitiated).async {
            // Step 1: Allocate JIT pool (BRK suspends entire process)
            // 128 MB was enough for cube but Thumper exhausts it (more PE
            // copies + larger FEX block cache). Desktop mode holds the
            // session's aarch64 image set AND every child's x64 set AND the
            // FEX code buffers in ONE pool: Thumper-under-desktop hit 199MB
            // of image copies alone (2026-07-06), leaving the FEX tail carve
            // colliding with the head. 384 MB fits both plus slack; the pool
            // is dual-map + NO_FOOTPRINT so unwritten pages cost nothing.
            //
            // 2026-07-10 (Steam S3): 384 MB is VIRTUAL-exhausted by Steam's
            // pseudo-process fan-out — steam.exe + services + rpcss + cmd +
            // conhost + steamerrorreporter64 each copy their whole DLL set
            // (owner-keyed, no .text sharing yet) → 138 image copies hit
            // ~365 MB and the crash reporter's ntdll can't fit → the load
            // fails and execution BUS-faults on the un-committed image. Since
            // the pool is jetsam-exempt + demand-committed (unwritten pages
            // cost nothing), raising the VIRTUAL cap is a cheap, safe unblock.
            // 640 MB clears the current fan-out with headroom to reach the
            // ole32 delay-load (FEX riprel probe) and beyond. The real fix for
            // the PHYSICAL duplication is .text sharing (deferred project).
            //
            // 2026-07-10 pm (task #34 / CEF): 896 MB — libcef.dll's 212MB
            // pool copy EXHAUSTED 640 (bump 412MB + no contiguous 212MB →
            // libcef load degraded → init CHECK). Pure-x64 skip-copy was
            // trialed and reverted (broke x18-trampoline layout, ml68);
            // until skip-copy or .text sharing lands, buy headroom. Virtual
            // is jetsam-exempt; the copy itself is ~212MB real RSS when
            // written.
            // 2026-08-01 (ml364): 1152 MB — ml363 died at MSM depth on pool
            // EXHAUSTION (bump 858MB, freelist 0, tail-reserve 64MB) when
            // Chrome's in-proc GPU thread requested a doubled 32MB EC code
            // buffer; the fallback landed non-executable in the guest band and
            // FEX scribbled through a garbage CodeBuffer. NOTE the jetsam
            // ledger note above is STALE: the pool was never exempt and
            // arrives FULLY DIRTY from StikDebug's TXM blessing writes, so
            // this +256MB costs +256MB of the 4096MB budget up front. The
            // ml362/ml363 footprint work (peak 3804→3190) is what pays for
            // it. The real fix for both sides is still .text sharing.
            // 2026-08-01 (ml367): back to 896 MB. ml364 needed 1152 because the
            // shipped PE DLLs carried DWARF debug sections (llvm-mingw links
            // -Wl,-debug:dwarf) and the pool copies the ENTIRE image, so 42% of
            // every copy was debug info with no runtime purpose. Stripping them
            // (llvm-strip --strip-debug over the bundle) drops projected peak
            // pool use 894 -> ~653 MB, so 896 restores the ml364-equivalent
            // headroom (~243 MB) while returning 256 MB of footprint — the pool
            // is dirty from birth, so its SIZE is what costs, not its usage.
            // KEEP ios_usable_va_floor PAIRED: 896MB -> 0x7038000000.
            // 2026-08-02 (ml421): 1024 MB. ml420 (post-#69-fix, deepest run yet:
            // cycle 41) refilled the stripped 896 pool anyway — head 768MB of
            // copies + 176MB tail of EC code buffers collided; the doubled 32MB
            // GPU-thread buffer was refused and the ml361/ml363 ClearCache
            // wild-write returned (now also honestly REFUSED unix-side,
            // rev=ml421). +128MB is the depth lever that fits under jetsam:
            // ml420 peaked 3837 phys; 3837+128=3965 < 4096. Tight — if jetsam
            // returns, the durable fix is .text sharing, not more pool.
            // 2026-08-02 (ml423): BACK to 896. Jetsam DID return — ml422 died a
            // silent EXC_RESOURCE kill at 2.5min (peak 3904, log stops mid-line),
            // exactly the predicted cost of the +128MB dirty-at-birth pool.
            // ml421's honest EC_CODE refusal makes pool exhaustion GRACEFUL now
            // (ctor halving, worst case one thread's 0xdead fault) while jetsam
            // kills the whole app — 896 + graceful degradation strictly beats
            // 1024 + jetsam roulette. Durable fix remains .text sharing.
            // KEEP ios_usable_va_floor PAIRED: 896MB -> 0x7038000000.
            // 2026-08-03 (ml458): STAY at 896 — growth is closed for good.
            // jetsam killed 1024 twice (ml422 peak 3904) and the no-footprint
            // exemption is unreachable: all four (entry-flags, owner) variants
            // return kr=4, and the plain ones expose why — the named entry
            // covers 16KB of the 896MB object, i.e. the kernel wants an entry
            // naming the WHOLE object, which we can never build over memory
            // whose object StikDebug created. Pool stays dirty-from-birth and
            // jetsam-counted, so SIZE is the cost and 896 is the ceiling.
            // ⛔ ml457 re-trialed pure-x64 skip-copy (already dead per ml68
            // above) and it failed again for a different reason: x64 guest
            // RIPs ARE pool-copy aliases, so the copy is the execution
            // substrate — steam.exe died in seconds. Do not try a third time.
            // The remaining levers are USE-side: the 276MB of duplicate copies
            // (.text sharing) and the 214MB tail of EC code buffers.
            // ml668: RUNTIME-SELECTABLE. 896 stays the default and the only
            // value proven for Steam/CEF. 384 is the direct-game experiment:
            // the last good Book of the Dead run used ~139MB of head + ~48MB
            // of tail, so 384 leaves ~197MB of observed slack while returning
            // ~512MB of footprint -- and the pool is dirty from birth, so its
            // SIZE is the cost, not its usage. The VA floor is no longer a
            // hand-paired constant (ml668 derives it from the pool actually
            // allocated), so changing this is now a one-line change.
            // Override lives in Documents/madeira-pool.txt (a bare number of MB)
            // so it can be swapped between runs without a rebuild, and deleting
            // the file reverts to the proven default. Clamped to sane values --
            // a typo here would otherwise move the VA floor with it.
            // Dynamic pool size based on device physical memory (5~6GB+ RAM support)
            let totalRAM_MB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024))
            var poolSizeMB = (totalRAM_MB >= 7500) ? 1024 : 896
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-pool.txt"), encoding: .utf8),
               let mb = Int(txt.trimmingCharacters(in: .whitespacesAndNewlines)),
               mb >= 256, mb <= 3072 {
                poolSizeMB = mb
                logStore.log("JIT pool overridden to \(mb)MB via madeira-pool.txt")
            }

            // Always enable Large Address Aware (no 4GB patch required)
            setenv("WINE_LARGE_ADDRESS_AWARE", "1", 1)

            // ml694: W^X A/B switch. Documents/madeira-wx.txt containing "0"
            // disables page demotion for the SAME binary, so the on/off
            // comparison needs one rebuild, not two. The previous gate read
            // container paths that can never exist, so it silently forced
            // ENABLED and no A/B was actually possible.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-wx.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                setenv("MADEIRA_WX", v, 1)
                logStore.log("W^X override: MADEIRA_WX=\(v) via madeira-wx.txt")
            }

            // ml727: wine-mono backpatcher bridge. Enabled by default for full Unity/Mono compatibility.
            setenv("MADEIRA_WINEMONO_BRIDGE", "1", 1)
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-mono-bridge.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MADEIRA_WINEMONO_BRIDGE", v, 1)
                    logStore.log("Mono bridge: MADEIRA_WINEMONO_BRIDGE=\(v) via madeira-mono-bridge.txt")
                }
            }

            // ml716: syscall-frame context A/B. Documents/madeira-ctx-frame.txt == "1"
            // makes ios_fill_thread_context() report a thread parked inside a syscall
            // using its saved Wine syscall frame (TEB+0x378) instead of the Mach-O
            // registers it happens to be executing. Off by default; native code reads
            // only the environment variable.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-ctx-frame.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MADEIRA_CTX_FRAME", v, 1)
                    logStore.log("Context source: MADEIRA_CTX_FRAME=\(v) via madeira-ctx-frame.txt")
                }
            }

            // ml744: DXMT options passthrough. Documents/madeira-dxmt.txt is copied
            // verbatim into DXMT_CONFIG, which the renderer's config parser reads as
            // inline "key=value" lines, so options can be tried without a rebuild.
            // d3d11.mipClampBC=N is the one that matters for memory: this GPU cannot
            // sample BC, so those textures are expanded to uncompressed and cost 2-8x
            // their shipped size.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-dxmt.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("DXMT_CONFIG", v, 1)
                    logStore.log("DXMT config: \(v) via madeira-dxmt.txt")
                }
            }

            // ml734: Theorafile call tracer. Documents/madeira-tf-trace.txt == "1"
            // redirects libtheorafile's tf_* exports through wrappers in
            // tftrace-x64.dll that call the original and report the RETURN
            // value.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-tf-trace.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MADEIRA_TF_TRACE", v, 1)
                    logStore.log("Theorafile tracer: MADEIRA_TF_TRACE=\(v) via madeira-tf-trace.txt")
                }
            }

            // ml731: Windows shared-data clock. Enabled by default so GetTickCount,
            // Environment.TickCount and DateTime.UtcNow advance and managed/Unity games
            // never freeze in endless initialization loops.
            setenv("MADEIRA_USD_TIME", "1", 1)
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-usd-time.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MADEIRA_USD_TIME", v, 1)
                    logStore.log("Shared-data clock: MADEIRA_USD_TIME=\(v) via madeira-usd-time.txt")
                }
            }

            // ml730: REAL thread suspension A/B. Documents/madeira-real-suspend.txt == "1"
            // makes a Wine suspend actually stop the Mach thread and keep it stopped
            // until the matching resume, instead of only snapshotting its registers
            // and bumping a counter while the target keeps running.
            //
            // Off by default and reversible on purpose: wineserver is a thread inside
            // this same Mach process and shares the allocator with the guest, so truly
            // freezing a thread that holds the malloc lock or FEX's CodeInvalidationMutex
            // can deadlock whoever suspended it. Windows apps tolerate preemptive suspend
            // because the suspender does not share their heap; here it does.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-real-suspend.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MADEIRA_REAL_SUSPEND", v, 1)
                    logStore.log("Thread suspension: MADEIRA_REAL_SUSPEND=\(v) via madeira-real-suspend.txt")
                }
            }

            // ml713: Mono suspend-policy A/B. Documents/madeira-mono-suspend.txt
            // containing "preemptive" (or "coop"/"hybrid") sets MONO_THREADS_SUSPEND
            // for wine-mono, so the comparison needs no rebuild.
            //
            // EXPERIMENT, NOT A FIX, and deliberately not a default. Marvel Cosmic
            // Invasion deadlocks with one thread owning a Mono critical section while
            // looping on mono_lls_find/usleep waiting for a thread-info record, and six
            // threads queued behind that section. Preemptive suspend would sidestep the
            // handshake -- but it needs SuspendThread + GetThreadContext to yield a
            // coherent x86-64 context for a guest thread stopped anywhere, including
            // mid-JIT-block, and that path has never been exercised under FEX. It may
            // trade a deadlock for a worse failure. If it does get in-game, that is NOT
            // evidence for any particular theory of the deadlock.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-mono-suspend.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MONO_THREADS_SUSPEND", v, 1)
                    logStore.log("Mono suspend policy: MONO_THREADS_SUSPEND=\(v) via madeira-mono-suspend.txt")
                }
            }

            winios_phase("pool-alloc-begin")
            logStore.log("Allocating \(poolSizeMB)MB JIT pool (BRK will suspend process)...")
            let t0 = CFAbsoluteTimeGetCurrent()
            let pool = StikJITHelper.allocatePool(poolSize: poolSizeMB * 1024 * 1024)
            let elapsed = CFAbsoluteTimeGetCurrent() - t0
            winios_phase("pool-ready")
            logStore.log("BRK suspension lasted \(String(format: "%.2f", elapsed))s")

            // ml762: remote Metal backend. Documents/madeira-remote.txt holds
            // "<host-ip> <token>" and routes winemetal to a Metal daemon on that
            // host instead of the local device. The mode is decided ONCE per
            // process: flipping it later would leave handles from two address
            // spaces alive at the same time, which is precisely what the handle
            // tag exists to make impossible.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-remote.txt"), encoding: .utf8) {
                let parts = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                                .split(separator: " ", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    setenv("DXMT_REMOTE_METAL", parts[0], 1)
                    setenv("RMETAL_TOKEN", parts[1], 1)
                    logStore.log("remote Metal: host=\(parts[0]) via madeira-remote.txt", level: .success)
                } else if !parts.isEmpty {
                    logStore.log("madeira-remote.txt needs '<host-ip> <token>'", level: .error)
                }
            }

            // ml761: top-level API census. Documents/madeira-apicensus.txt == "1"
            // counts every call across the PE->unix winemetal boundary and
            // classifies each as producer, consumer, lifetime, query, sync,
            // presentation or bulk-memory. Needed because a packed command
            // batch carries GUEST handles -- raw pointer casts, meaningless on
            // another machine -- so every handle producer and consumer has to
            // be redirected together.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-apicensus.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                setenv("DXMT_API_CENSUS", v, 1)
                logStore.log("API census: DXMT_API_CENSUS=\(v) via madeira-apicensus.txt")
            }

            // ml760: shadow-pack mode. Documents/madeira-shadow.txt == "1" packs
            // and validates every real render batch into the remote wire format,
            // then discards it and renders locally as normal. Exercises the
            // packer against live traffic where being wrong costs nothing. The
            // check that matters is packed counts equalling census counts: a
            // silently skipped command would otherwise surface as a subtly wrong
            // frame on another machine.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-shadow.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                setenv("DXMT_SHADOW_PACK", v, 1)
                logStore.log("shadow pack: DXMT_SHADOW_PACK=\(v) via madeira-shadow.txt")
            }

            // ml758: wmtcmd census. Documents/madeira-census.txt == "1" counts
            // which of the 59 render/compute/blit command types a workload
            // actually emits, and how large their sidecar data gets. Needed
            // before serialising wmtcmd_* for the remote Metal transport --
            // building a schema for all 59 on speculation would be weeks of
            // work for commands no title may ever issue.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-census.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                setenv("DXMT_CMD_CENSUS", v, 1)
                logStore.log("wmtcmd census: DXMT_CMD_CENSUS=\(v) via madeira-census.txt")
            }

            // ml757: FEX arena placeholder. Documents/madeira-arena.txt == "1"
            // makes Wine reserve FEX's host arena before any PE loads. OFF by
            // default: FEX still selects its own band, and on hardware that
            // band IS the reservation, so enabling it starves FEX and kills
            // x64 before the first window. Proven correct on the research VM
            // (8GB held, 0 of 123 guest images inside it) -- turn on only once
            // FEX consumes WINE_IOS_FEX_ARENA_BASE/SIZE instead of choosing.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-arena.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                setenv("MADEIRA_FEX_ARENA", v, 1)
                logStore.log("FEX arena placeholder: MADEIRA_FEX_ARENA=\(v) via madeira-arena.txt")
            }

            // ml748: W^X A/B probe. Documents/madeira-wxprobe.txt == "1" runs it.
            // Loading xtajit64.dll faults writing its .rdata on the jailbroken
            // research VM and not on this phone, with CS_DEBUGGED live in both,
            // so attachment is not the variable. Either the VM is stricter than
            // real hardware (its patchVmMapProtect() was removed, and that is
            // what forces W to stick on file-backed pages), or hardware masks a
            // genuine bug and the loader must stop holding RWX over image pages.
            // Reasoning cannot separate those; the SAME build reporting on both
            // machines can. Runs here because it needs the real container, the
            // real sandbox and a live cs_wx_enabled map -- a standalone binary
            // over SSH already answered this wrongly once.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-wxprobe.txt"), encoding: .utf8),
               txt.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
                logStore.log("W^X probe armed via madeira-wxprobe.txt", level: .success)
                jit_wx_probe()
            }

            if let pool = pool {
                logStore.log("JIT pool: RX=\(String(format: "%p", Int(bitPattern: pool.rx))), RW=\(String(format: "%p", Int(bitPattern: pool.rw))), size=\(pool.size / 1024 / 1024)MB", level: .success)
                setenv("WINE_IOS_JIT_RX", String(format: "%lx", Int(bitPattern: pool.rx)), 1)
                setenv("WINE_IOS_JIT_RW", String(format: "%lx", Int(bitPattern: pool.rw)), 1)
                setenv("WINE_IOS_JIT_SIZE", String(format: "%lx", pool.size), 1)
            } else {
                // ml596: ABORT. "Continuing without it" produced ml595 — a run that
                // looked like an ARM64EC/optimizer regression but was only Wine
                // executing with no JIT pool, and it cost a diagnostic cycle plus a
                // wrong conclusion I wrote into the source. A run without the pool can
                // only manufacture misleading secondary crashes, so refuse to start one.
                logStore.log("JIT pool allocation FAILED — not starting Wine.", level: .error)
                logStore.log("  All placements landed in the forbidden guest 64G window.", level: .info)
                logStore.log("  Force-quit and relaunch: placement is chosen by the kernel", level: .info)
                logStore.log("  and depends on current memory layout, so a fresh process", level: .info)
                logStore.log("  usually lands somewhere valid.", level: .info)
                logStore.uiPaused = false
                return
            }

            // Step 1b (ml524, #67): DETACH THE DEBUGGER NOW, while the VM map is small.
            //
            // Every ~54s whole-app stall coincides with StikDebug DEPARTING — clean
            // exit(0) and jetsam-kill alike (12:07:43 exit(0) -> GAP 54.0s at 12:07:49;
            // 12:13:58 cpulimit kill -> GAP 53.8s starting 64ms BEFORE the kill log).
            // Departure is the trigger; the manner of death is irrelevant. StikDebug
            // burns its 48s-CPU-per-60s budget in ~52s every single run, so an
            // UNCONTROLLED departure mid-game is guaranteed. Detaching here pays the
            // cost ONCE, at a moment we choose, before anything is on screen.
            //
            // Why it may also be CHEAPER here: on attach the kernel unnests the DYLD
            // shared region in OUR map ("increases system memory footprint until the
            // target exits"), so teardown plausibly scales with VM-map complexity —
            // and right now the map is a fraction of what it becomes under Steam
            // (91 threads / 2512MB). The [early-detach] timing below tests exactly that.
            //
            // Safe NOW and not before: ml522/ml523 made US the task-level Mach handler
            // for bad-access + bad-instruction + breakpoint, so the fault backstop that
            // used to require a live debugger (madeira-jit.js: "NEVER detach here ... every
            // later escalated fault parks its thread forever", the ml345 wedge) is ours.
            // And all executable memory already comes from the pool granted above —
            // virtual_ios.c copies every PE .text into it rather than mprotecting,
            // because iOS/TXM blocks mprotect(PROT_EXEC) outright.
            //
            // ORDERING MATTERS: our task-port claim installs at wine's first thread
            // setup, which is AFTER this point, so this BRK still reaches StikDebug.
            // Flip to false to A/B against the old attached-for-the-whole-run behaviour.
            let earlyDetach = true
            if earlyDetach, pool != nil {
                let dt0 = CFAbsoluteTimeGetCurrent()
                StikJITHelper.detachDebugger()
                let dms = (CFAbsoluteTimeGetCurrent() - dt0) * 1000.0
                logStore.log(String(format: "[early-detach] rev=ml524 took %.0f ms", dms),
                             level: dms > 5000 ? .error : .success)
            } else if !earlyDetach {
                logStore.log("[early-detach] rev=ml524 DISABLED — debugger stays attached all run")
            }

            winios_phase("detach-done")

            // Step 2: Start wineserver
            self.startWineserver()
            winios_phase("wineserver-up")

            // Step 3: Start Wine (debugger still attached for PE loading BRK calls)
            Thread.sleep(forTimeInterval: 2.0)
            winios_phase("wine-start")
            self.startWineProcess()

            // ml788: watch the desktop's root process for its whole life, not
            // just during the detach wait below (which gives up after its cap
            // while the desktop keeps running). Start -> "Exit desktop" ends
            // with explorer.exe leaving __wine_main; that is the only signal
            // the app gets, and it has to act on it (see desktopSessionEnded).
            let desktopSession = getenv("MADEIRA_DESKTOP").map { $0.pointee == 49 } ?? false
            if desktopSession && wine_process_is_running() != 0 {
                DispatchQueue.global(qos: .utility).async {
                    while wine_process_is_running() != 0 {
                        Thread.sleep(forTimeInterval: 0.5)
                        // ml789: Start -> Exit desktop. ntdll reports the
                        // `wineboot --end-session` child's spawn and exit;
                        // when it exited with 0 every program is closed and
                        // the desktop is shut down here (hidden, Start
                        // Desktop re-shows it), without waiting for the
                        // server to close the desktop (it never does on
                        // this port — 0.1.34 log).
                        let stage = winios_session_shutdown_stage()
                        if stage == 2 {
                            winios_session_shutdown_note(0, 0)
                            self.desktopShutDownNow()
                        } else if stage == 3 {
                            winios_session_shutdown_note(0, 0)
                            logStore.log("Exit desktop cancelled: a program refused to close (wineboot exit non-zero)", level: .error)
                        }
                    }
                    self.desktopProcessDied(exitCode: Int(wine_process_exit_code()))
                }
            }

            // Step 4: Wait for Wine to finish instead of fixed timer
            // Poll wine_process_is_running() — it clears when __wine_main returns
            // For real games this never returns (message loop runs forever), so
            // the cap is what matters. After detach, the dual-mapped JIT pool
            // keeps existing blocks executable; only NEW BRK-based compiles
            // fail.
            //
            // 2026-05-13 first-frame: Thumper splash renders at ~50s but JIT is
            // STILL compiling new FMOD blocks 3M log lines later — audio init
            // is huge (~14k unique RIPs in fmod64.dll alone). Bumped to 300s
            // to let FMOD finish init before debugger detach; otherwise main
            // game loop never engages because Present is gated on audio ready.
            logStore.log("Waiting for Wine to finish PE loading...")
            // 2026-07-03 early detach: attached-mode runs the whole guest
            // ~2x slower (measured 1.2s → 0.74s per present at detach) and
            // on iOS 27 presented frames only reliably reach glass after
            // detach. Post-detach is safe now: trap-mode JIT writes go via
            // the Mach emulator (no debugger), pool pages are pre-executable
            // (dual map), page0 runs once on the first thread, and a
            // post-detach compile was observed working (real_compiles
            // 7093→7094, no faults). So: detach once the game is actually
            // presenting (present #2 = first post-splash frame) plus a
            // settle window, instead of waiting out the full 1200s cap.
            let maxWait = 1200.0  // hard safety cap (unchanged)
            // 2026-07-03 second iteration: detach on present #1 (splash shown)
            // instead of #2. The 3-minute splash-hold is the game loading —
            // running it detached should roughly halve it. Riskier than #2
            // (thousands of load-time compiles + worker-thread spawns happen
            // post-detach) but all known dependencies are covered: trap-mode
            // writes, pre-executable pool, page0 once-guard.
            let settleAfterFirstPresent = 20.0
            var presentingSince: CFAbsoluteTime? = nil
            let pollStart = CFAbsoluteTimeGetCurrent()
            var lastHeartbeat = CFAbsoluteTimeGetCurrent()
            while wine_process_is_running() != 0 {
                Thread.sleep(forTimeInterval: 0.25)
                let now = CFAbsoluteTimeGetCurrent()
                // Diagnostic heartbeat: 2026-07-03's detach-at-#1 run never
                // triggered despite presents visibly counting — log what this
                // loop actually observes so that can't happen silently again.
                if now - lastHeartbeat > 30 {
                    lastHeartbeat = now
                    logStore.log("detach-wait: presents=\(madeira_get_present_count()) running=\(wine_process_is_running()) elapsed=\(Int(now - pollStart))s")
                }
                // Task #25: the present heuristic is meaningless in desktop
                // mode — ANY child presenting (cube, a game window) trips it
                // mid-session, and later program launches still need the
                // attached-debugger facilities. Desktop sessions stay
                // attached until the desktop exits (or the safety cap).
                let isDesktopSession = getenv("MADEIRA_DESKTOP").map { $0.pointee == 49 } ?? false
                if !isDesktopSession {
                    if presentingSince == nil && madeira_get_present_count() >= 1 {
                        presentingSince = now
                        logStore.log("Game is presenting (#1, splash) — early detach in \(Int(settleAfterFirstPresent))s")
                    }
                    if let t = presentingSince, now - t > settleAfterFirstPresent {
                        logStore.log("Early detach: game presenting and settled", level: .success)
                        break
                    }
                }
                if now - pollStart > maxWait {
                    logStore.log("Wine still running after \(Int(maxWait))s, proceeding with detach", level: .error)
                    break
                }
            }
            let wineElapsed = CFAbsoluteTimeGetCurrent() - pollStart
            logStore.log("Wine finished after \(String(format: "%.1f", wineElapsed))s")

            // Step 5: Resume UI + os_log, give main thread time to recover before detach
            DispatchQueue.main.async {
                ws_log_quiet = 0
                logStore.uiPaused = false
            }
            Thread.sleep(forTimeInterval: 2.0)

            // Step 6: Detach debugger — main thread should have zero accumulated hang time
            logStore.log("Detaching debugger...")
            StikJITHelper.detachDebugger()

            DispatchQueue.main.async { heartbeat.invalidate() }
        }
    }

    /// ml589: locate an installed Steam inside the prefix and (re)generate
    /// C:\steam-launch.bat to match. Returns false, having logged the reason,
    /// when there is nothing runnable.
    ///
    /// Generating the batch here fixes a gap that only showed on FRESH prefixes:
    /// steam-launch.bat was never part of prefix-template.tar.gz, it had only
    /// ever been hand-pushed to the dev device, so a new install ran
    /// `cmd /c C:\steam-launch.bat` against a file that did not exist.
    ///
    /// The generated batch launches steam.exe DIRECTLY rather than through
    /// start.exe. That wrapper's teardown is what killed services.exe's RPC
    /// listener in every broken run (ml579/580/584/585) and took the Start menu
    /// with it; launching directly also keeps cmd+conhost alive for the session.
    private func prepareSteamLaunch() -> Bool {
        let fm = FileManager.default
        let prefix = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("wine").path

        // (windows dir, unix dir) — Steam installs to Program Files (x86) by
        // default, but honour a 64-bit-tree install too.
        let candidates = [
            ("C:\\Program Files (x86)\\Steam", "\(prefix)/drive_c/Program Files (x86)/Steam"),
            ("C:\\Program Files\\Steam",       "\(prefix)/drive_c/Program Files/Steam"),
        ]

        guard let (winDir, _) = candidates.first(where: {
            fm.fileExists(atPath: "\($0.1)/steam.exe")
        }) else {
            logStore.log("Steam is not installed in this prefix.", level: .error)
            logStore.log("  Searched: Program Files (x86)\\Steam and Program Files\\Steam", level: .info)
            logStore.log("  Valve's SteamSetup.exe cannot be used to install it here: the", level: .info)
            logStore.log("  installer AND the Steam.exe it lays down are 32-bit x86, and this", level: .info)
            logStore.log("  build runs x86-64 only (ARM64EC + FEX, no 32-bit emulator).", level: .info)
            logStore.log("  Copy an existing 64-bit Steam folder into the prefix instead.", level: .info)
            return false
        }

        let bat = """
        @echo off\r
        rem Generated by Madeira (ml589) — do not hand-edit; rewritten every launch.\r
        start "" "C:\\windows\\system32\\services.exe"\r
        cd /d "\(winDir)"\r
        "\(winDir)\\steam.exe" -no-cef-sandbox -cef-disable-gpu -console -nocrashmonitor -cef-disable-features=SegmentationPlatform,OptimizationTargetPrediction,OptimizationHints\r
        """

        let batPath = "\(prefix)/drive_c/steam-launch.bat"
        do {
            try bat.write(toFile: batPath, atomically: true, encoding: .utf8)
        } catch {
            logStore.log("Could not write steam-launch.bat: \(error.localizedDescription)", level: .error)
            return false
        }
        logStore.log("Steam found at \(winDir)", level: .success)
        return true
    }

    private func startWineserver() {
        logStore.log("Starting wineserver...")

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let winePrefixPath = documentsPath.appendingPathComponent("wine").path

        logStore.log("Wine prefix: \(winePrefixPath)")

        let result = wineserver_start(winePrefixPath)
        if result == 0 {
            logStore.log("Wineserver thread launched successfully", level: .success)
        } else {
            logStore.log("Failed to start wineserver (error: \(result))", level: .error)
        }
    }

    private func startWineProcess() {
        logStore.log("Starting Wine process...")

        if wineserver_is_running() == 0 {
            logStore.log("Wineserver not running! Start it first.", level: .error)
            return
        }

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let winePrefixPath = documentsPath.appendingPathComponent("wine").path

        // Call synchronously — caller already waited for wineserver to be ready
        let result = wine_process_start(winePrefixPath)
        if result == 0 {
            logStore.log("Wine process thread launched", level: .success)
        } else {
            logStore.log("Failed to start Wine process (error: \(result))", level: .error)
        }
    }

    private func testDualMapping() {
        logStore.log("Testing dual-mapped memory properties...")

        DispatchQueue.global(qos: .userInitiated).async {
            testDualMappingImpl()
        }
    }

    private func testDualMappingImpl() {
        logStore.log("Creating 64KB dual-mapped region...")

        guard let region = jit_region_create(65536) else {
            logStore.log("Failed to create dual-mapped region", level: .error)
            return
        }

        let rwPtr = jit_region_rw_ptr(region)
        let rxPtr = jit_region_rx_ptr(region)
        let size = jit_region_size(region)

        logStore.log("Region created: size=\(size)")
        logStore.log("  RW ptr: \(String(format: "%p", Int(bitPattern: rwPtr)))")
        logStore.log("  RX ptr: \(String(format: "%p", Int(bitPattern: rxPtr)))")

        // Test 1: Write to RW, verify readable from RX
        let testPattern: UInt32 = 0xDEADBEEF
        rwPtr?.assumingMemoryBound(to: UInt32.self).pointee = testPattern
        let readBack = rxPtr?.assumingMemoryBound(to: UInt32.self).pointee

        if readBack == testPattern {
            logStore.log("Dual mapping verified: write to RW visible from RX", level: .success)
        } else {
            logStore.log("Dual mapping FAILED: wrote \(String(format: "0x%X", testPattern)), read \(String(format: "0x%X", readBack ?? 0))", level: .error)
        }

        // Test 2: Verify RW and RX are at different virtual addresses
        if rwPtr != rxPtr {
            logStore.log("Distinct virtual addresses confirmed (RW != RX)", level: .success)
        } else {
            logStore.log("WARNING: RW and RX are at the same address", level: .error)
        }

        jit_region_destroy(region)
        logStore.log("Region destroyed. Dual mapping test complete.")
    }
}

struct SetupGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {   /* ml658: see the note on the main body */
            List {
                Section("Requirements") {
                    guideRow(
                        icon: "cpu",
                        title: "JIT Compilation",
                        detail: "Required for x86 code translation. On iOS 26, StikDebug must stay attached — assign the 'universal' or 'MeloNX' JIT script to Madeira in StikDebug."
                    )
                    guideRow(
                        icon: "memorychip",
                        title: "Increased Memory Limit",
                        detail: "Raises the Jetsam memory threshold. Included in the app entitlements. If not detected, use GetMoreRam to inject it."
                    )
                    guideRow(
                        icon: "arrow.up.left.and.arrow.down.right",
                        title: "Extended Virtual Addressing",
                        detail: "Expands virtual address space to ~64GB. Required for large games. Must be injected via GetMoreRam (free accounts can't provision this)."
                    )
                }

                Section("Setup Steps") {
                    stepRow(number: 1, text: "Install Madeira via SideStore or Xcode")
                    stepRow(number: 2, text: "Install GetMoreRam and run it to inject memory entitlements into your App ID")
                    stepRow(number: 3, text: "Reinstall Madeira with the same IPA to apply injected entitlements")
                    stepRow(number: 4, text: "In StikDebug, assign the 'universal' JIT script to Madeira and launch it")
                    stepRow(number: 5, text: "Launch Madeira and tap 'Test JIT' to verify")
                }

                Section("About") {
                    Text("Madeira is a proof-of-concept for running x86 Windows games on iOS using FEX-Emu, Wine, and Metal-based graphics translation.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Setup Guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func guideRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).fontWeight(.medium)
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func stepRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption).fontWeight(.bold)
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .font(.subheadline)
        }
        .padding(.vertical, 2)
    }
}

// ============================================================================
// ml643 — LANDSCAPE TOUCH CONTROLS (pass 1: overlay, editor, persistence)
//
// This is the L2 layer from reference_swiftui_liquid_glass_ux_layers.md: glass
// elements composited over the game canvas, repositionable.
//
// 🔑 Everything here MUST live in its own UIWindow. MetalHostView is a raw
// window-level UIView above the whole SwiftUI hierarchy, so a control drawn in
// the normal content tree gets sliced off wherever it overlaps the game surface
// — and zIndex cannot fix that, because zIndex only orders siblings *within*
// SwiftUI. Same reason JoystickPadHost exists; see its comment.
// ============================================================================

/// What a control does when pressed. Codable with associated values so the
/// whole layout round-trips through JSON.
enum ControlAction: Codable, Equatable, Hashable {
    case none
    case key(Int32)          // Windows virtual-key code
    case mouseLeft
    case mouseRight
    case joystickWASD        // renders as a stick, posts W/A/S/D
    case joystickArrows      // renders as a stick, posts the arrow keys
    case keyboardToggle      // raises the iOS keyboard, as in portrait
    case pad(String)         // ml645: Xbox button. NOT WIRED — see the panel.

    /// The four keys a stick drives, up/right/down/left. nil for non-sticks.
    var stickKeys: [Int32]? {
        switch self {
        case .joystickWASD:   return [0x57, 0x44, 0x53, 0x41]   // W D S A
        case .joystickArrows: return [0x26, 0x27, 0x28, 0x25]   // up right down left
        default: return nil
        }
    }
    var isPad: Bool { if case .pad = self { return true }; return false }

    var label: String {
        switch self {
        case .none:            return "—"
        case .mouseLeft:       return "L"
        case .mouseRight:      return "R"
        case .keyboardToggle:  return "⌨"
        case .joystickWASD:    return "WASD"
        case .joystickArrows:  return "↕"
        case .pad(let n):      return n
        case .key(let vk):     return ControlAction.keyLabel(vk)
        }
    }

    /// Minimal for pass 1 — the full VK table arrives with the mapping panel.
    static func keyLabel(_ vk: Int32) -> String {
        switch vk {
        case 0x0D: return "⏎"
        case 0x20: return "␣"
        case 0x1B: return "Esc"
        case 0x09: return "⇥"
        case 0x10: return "⇧"
        case 0x11: return "Ctl"
        case 0x12: return "Alt"
        case 0x25: return "←"
        case 0x26: return "↑"
        case 0x27: return "→"
        case 0x28: return "↓"
        default:
            if vk >= 0x30, vk <= 0x5A, let u = UnicodeScalar(UInt32(vk)) {
                return String(Character(u))
            }
            return String(format: "%02X", vk)
        }
    }
}

/// One on-screen control.
///
/// Position is NORMALISED (0–1 of the screen), never points: the device gets
/// rotated and the logical surface can change size, and a layout stored in
/// absolute coordinates scatters the first time either happens.
struct TouchControl: Codable, Identifiable, Equatable {
    var id = UUID()
    var nx: Double = 0.5
    var ny: Double = 0.5
    var scale: Double = 1.0
    var action: ControlAction = .mouseLeft   // usable the moment it is created
}

final class TouchControlsModel: ObservableObject {
    static let shared = TouchControlsModel()
    static let baseDiameter: CGFloat = 64

    @Published var controls: [TouchControl] = [] { didSet { save() } }
    @Published var visible = false              { didSet { save() } }
    @Published var fullScreen = false           // transient; overlay belongs to the desktop
    @Published var editing = false              // transient, never persisted
    @Published var selected: UUID?              // transient

    private var loading = false
    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("madeira-controls.json")
    }

    private struct Saved: Codable { var controls: [TouchControl]; var visible: Bool }

    private init() {
        loading = true
        if let d = try? Data(contentsOf: Self.url),
           let s = try? JSONDecoder().decode(Saved.self, from: d) {
            controls = s.controls
            visible  = s.visible
        }
        loading = false
    }

    private func save() {
        guard !loading else { return }
        guard let d = try? JSONEncoder().encode(Saved(controls: controls, visible: visible))
        else { return }
        try? d.write(to: Self.url, options: .atomic)
    }

    func index(of id: UUID?) -> Int? {
        guard let id else { return nil }
        return controls.firstIndex { $0.id == id }
    }

    func ensureDefaultLayout() {
        guard controls.isEmpty else { return }
        controls = [
            TouchControl(nx: 0.16, ny: 0.72, scale: 1.35, action: .joystickWASD),
            TouchControl(nx: 0.84, ny: 0.72, scale: 1.05, action: .mouseLeft),
            TouchControl(nx: 0.73, ny: 0.60, scale: 0.88, action: .key(0x20)),
            TouchControl(nx: 0.90, ny: 0.55, scale: 0.78, action: .key(0x1B)),
        ]
    }

    /// ml644: does this WINDOW point land on something interactive?
    ///
    /// Hit-test geometrically, never by walking the UIView hierarchy. SwiftUI
    /// does not back each Button with its own UIView — the entire overlay is one
    /// _UIHostingView and taps are routed by SwiftUI's own gesture machinery. So
    /// `super.hitTest` returns that same hosting view for EVERY point, buttons
    /// included, and ml643's "is it the root view?" test therefore rejected every
    /// touch in the window. Nothing responded, and edit mode — whose branch
    /// captured everything — could never be entered to mask it.
    func hitsInteractive(_ p: CGPoint, in bounds: CGRect) -> Bool {
        // The full-screen toolbar is safe-area-aligned at the top trailing
        // edge. Reserve its shallow row for the controls window; below it,
        // empty overlay space remains click-through to the Windows surface.
        if p.y < 100 { return true }
        guard visible else { return false }
        for c in controls {
            let r = Self.baseDiameter * CGFloat(c.scale) / 2
            let cx = CGFloat(c.nx) * bounds.width
            let cy = CGFloat(c.ny) * bounds.height
            if hypot(p.x - cx, p.y - cy) <= r { return true }
        }
        return false
    }
}

/// Click-through EXCEPT where a control actually is.
///
/// PassthroughWindow (the joystick pad's) returns nil unconditionally because it
/// only ever draws. This one has to take input, so it discriminates: a hit that
/// lands on the hosting root view means empty space, and empty space belongs to
/// the game underneath — mouse-look must keep working between the buttons.
final class ControlsWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let m = TouchControlsModel.shared
        // Edit mode owns the whole screen: drags and the scale pinch must not
        // leak through and swing the camera while you are arranging buttons.
        if m.editing { return super.hitTest(point, with: event) }
        guard m.fullScreen else { return nil }
        guard m.hitsInteractive(point, in: bounds) else { return nil }
        return super.hitTest(point, with: event)
    }
}

enum TouchControlsHost {
    private static var window: ControlsWindow?

    static func attach() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
                        ?? scenes.first else { return }
        if window == nil {
            // ml644: orientationDidChangeNotification is NOT posted unless
            // generation has been switched on, so without this the overlay would
            // keep a portrait-sized frame after the first rotation.
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            let w = ControlsWindow(windowScene: scene)
            // Above the joystick pad's +100. A higher windowLevel is the only
            // ordering nothing inside the app window can undo.
            w.windowLevel = .normal + 101
            w.backgroundColor = .clear
            w.isHidden = false        // deliberately never made key
            let host = UIHostingController(rootView: TouchControlsOverlay())
            host.view.backgroundColor = .clear
            w.rootViewController = host
            window = w
        }
        window?.frame = scene.coordinateSpace.bounds
        fputs("[controls] ml644 overlay attached frame=\(window?.frame ?? .zero) " +
              "controls=\(TouchControlsModel.shared.controls.count)\n", stderr)
    }
}

extension Notification.Name {
    /// Posted by MetalBackedView on a quick, still tap of the game surface.
    static let madeiraSurfaceTap = Notification.Name("MadeiraSurfaceTap")
}

struct TouchControlsOverlay: View {
    @ObservedObject private var m = TouchControlsModel.shared
    @AppStorage(perfOverlayEnabledKey) private var perfOverlayEnabled = true
    @State private var pinchBase: Double?
    /// Auto-hiding toolbar: shown on entry, on a quick tap of the surface,
    /// on a tap along the top edge, and while the layout editor is open;
    /// fades a few seconds after the last interaction.
    @State private var chromeVisible = true
    @State private var chromeHideWork: DispatchWorkItem?
    private var chromeShown: Bool { chromeVisible || m.editing }

    private func showChrome() {
        withAnimation(.easeInOut(duration: 0.2)) { chromeVisible = true }
        chromeHideWork?.cancel()
        let work = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.35)) { chromeVisible = false }
        }
        chromeHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                if m.fullScreen {
                    if m.visible || m.editing {
                        ForEach(m.controls) { c in
                            TouchControlButton(control: c, screen: geo.size)
                        }
                    }
                    // Tap catcher along the top edge while the toolbar is
                    // hidden (the band ControlsWindow.hitTest reserves), so
                    // there is always an obvious way to bring it back.
                    if !chromeShown {
                        Color.clear
                            .frame(height: 100)
                            .contentShape(Rectangle())
                            .frame(maxWidth: .infinity, alignment: .top)
                            .onTapGesture { showChrome() }
                    }
                    // Performance HUD: this window is the only thing that
                    // draws above the window-level Metal host, so the full
                    // screen readout has to live here. Kept inside the top
                    // 100pt band that ControlsWindow.hitTest reserves for
                    // the toolbar, so the pacing pill stays tappable.
                    if perfOverlayEnabled {
                        FPSOverlay()
                            .padding(.top, geo.safeAreaInsets.top + 10)
                            .padding(.leading, geo.safeAreaInsets.leading + 12)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    topBar
                        .padding(.top, geo.safeAreaInsets.top + 10)
                        .padding(.trailing, geo.safeAreaInsets.trailing + 12)
                        .opacity(chromeShown ? 1 : 0)
                        .allowsHitTesting(chromeShown)
                    if m.editing, let i = m.index(of: m.selected) {
                        MappingPanel(control: m.controls[i], screen: geo.size)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height,
                   alignment: .topTrailing)
            .contentShape(Rectangle())
            .gesture(scalePinch)
        }
        .ignoresSafeArea()
        .onAppear { showChrome() }
        .onChange(of: m.fullScreen) { _, on in if on { showChrome() } }
        .onReceive(NotificationCenter.default.publisher(for: .madeiraSurfaceTap)) { _ in
            showChrome()
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            glassButton("xmark") {
                m.editing = false
                NotificationCenter.default.post(
                    name: Notification.Name("MadeiraExitFullScreen"), object: nil)
            }
            glassButton("gamecontroller", dim: !m.visible) {
                m.visible.toggle()
                if m.visible { m.ensureDefaultLayout() }
            }
            // Performance overlay on/off. Same UserDefaults key as the
            // Settings toggle, so the two stay in sync.
            glassButton("gauge.with.dots.needle.67percent", dim: !perfOverlayEnabled) {
                perfOverlayEnabled.toggle()
            }
            // iOS keyboard → Wine key events (same path as the portrait
            // pointer panel's ⌨ button and the touch-overlay action).
            glassButton("keyboard") {
                MetalBackedView.toggleKeyboard()
            }
            if m.visible {
                glassButton(m.editing ? "checkmark" : "pencil") {
                    m.editing.toggle()
                    if !m.editing { m.selected = nil }
                }
                if m.editing {
                    glassButton("plus") {
                        var c = TouchControl()
                        // Stagger, so repeated adds do not stack invisibly.
                        c.nx = 0.5 + Double(m.controls.count % 3) * 0.06
                        c.ny = 0.5 + Double(m.controls.count % 2) * 0.06
                        m.controls.append(c)
                        m.selected = c.id
                    }
                    .transition(.opacity.combined(with: .scale))
                }
            }
        }
        // ml796: Big Picture style toolbar — one dark panel instead of
        // floating glass circles. ml798: mirrored so the X sits at the far
        // right (no directional icons in here, so nothing else flips).
        .environment(\.layoutDirection, .rightToLeft)
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color(red: 0.09, green: 0.11, blue: 0.15).opacity(0.88)))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1))
        .animation(.easeInOut(duration: 0.22), value: m.editing)
    }

    /// Pinch anywhere scales the SELECTED control. With nothing selected it does
    /// nothing rather than guessing which one you meant.
    private var scalePinch: some Gesture {
        MagnificationGesture()
            .onChanged { v in
                guard m.editing, let i = m.index(of: m.selected) else { return }
                if pinchBase == nil { pinchBase = m.controls[i].scale }
                m.controls[i].scale = min(max((pinchBase ?? 1) * Double(v), 0.5), 3.0)
            }
            .onEnded { _ in pinchBase = nil }
    }

    private func glassButton(_ system: String, dim: Bool = false,
                             _ action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showChrome()                       // any toolbar use restarts the hide timer
            withAnimation(.easeInOut(duration: 0.22)) { action() }
        } label: {
            // Stroke only — never a .fill variant.
            Image(systemName: system)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(dim ? Color.white.opacity(0.35) : Color(red: 0.10, green: 0.62, blue: 1.0))
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color(red: 0.12, green: 0.15, blue: 0.20)))
                .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Shared glass backing, with the pre-26 fallback the codebase already uses.
struct GlassShape: View {
    var circle = false
    var body: some View {
        if #available(iOS 26.0, *) {
            if circle { Circle().fill(.clear).glassEffect(.regular, in: Circle()) }
            else { RoundedRectangle(cornerRadius: 18).fill(.clear)
                     .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18)) }
        } else {
            if circle { Circle().fill(.ultraThinMaterial) }
            else { RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial) }
        }
    }
}

struct TouchControlButton: View {
    let control: TouchControl
    let screen: CGSize
    @ObservedObject private var m = TouchControlsModel.shared
    @State private var isDown = false
    @State private var dragBase: CGPoint?
    @State private var stickDir: Int = -1

    private var diameter: CGFloat { TouchControlsModel.baseDiameter * CGFloat(control.scale) }
    private var isStick: Bool { control.action.stickKeys != nil }
    private var isSelected: Bool { m.editing && m.selected == control.id }

    var body: some View {
        ZStack {
            if control.action.stickKeys != nil {
                // Reuse the portrait pad's face so both look and animate the
                // same; scale it to whatever size this control was pinched to.
                JoystickFace(held: isDown, dir: stickDir, alwaysExpanded: true)
                    .frame(width: JoystickFace.padRadius * 2,
                           height: JoystickFace.padRadius * 2)
                    .scaleEffect(diameter / (JoystickFace.padRadius * 2))
            } else {
                GlassShape(circle: true)
                Text(control.action.label)
                    .font(.system(size: diameter * (control.action.label.count > 2 ? 0.22 : 0.34),
                                  weight: .medium))
                    .foregroundStyle(.white.opacity(control.action.isPad ? 0.45
                                                    : (isDown ? 1.0 : 0.85)))
            }
        }
        .frame(width: diameter, height: diameter)
        .overlay(Circle().stroke(.white.opacity(isSelected ? 0.95
                                                : (isStick ? 0 : 0.28)),
                                 lineWidth: isSelected ? 2 : 1))
        // A stick must not shrink under the thumb; only round buttons do that.
        .scaleEffect(!isStick && isDown ? 0.92 : 1.0)
        .animation(.easeOut(duration: 0.08), value: isDown)
        // ml646: the springy knob, same curve as the portrait pad overlay.
        .animation(.spring(response: 0.22, dampingFraction: 0.58), value: stickDir)
        .overlay(alignment: .topTrailing) {
            if isSelected {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    m.controls.removeAll { $0.id == control.id }
                    m.selected = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(.red.opacity(0.85)))
                }
                .buttonStyle(.plain)
                .offset(x: 8, y: -8)
            }
        }
        .position(x: CGFloat(control.nx) * screen.width,
                  y: CGFloat(control.ny) * screen.height)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if m.editing {
                        m.selected = control.id
                        guard let i = m.index(of: control.id) else { return }
                        if dragBase == nil { dragBase = CGPoint(x: control.nx, y: control.ny) }
                        let b = dragBase ?? .zero
                        m.controls[i].nx = min(max(b.x + Double(v.translation.width  / screen.width),  0.03), 0.97)
                        m.controls[i].ny = min(max(b.y + Double(v.translation.height / screen.height), 0.03), 0.97)
                    } else if let q = control.action.stickKeys {
                        isDown = true
                        applyStick(snap(v.translation), q)
                    } else if !isDown {
                        isDown = true
                        press(true)
                    }
                }
                .onEnded { _ in
                    dragBase = nil
                    if let q = control.action.stickKeys {
                        applyStick(-1, q)          // release every held direction
                        isDown = false
                    } else if isDown {
                        isDown = false
                        press(false)
                    }
                }
        )
    }

    /// 8-way snap. Screen y grows downward, so measure clockwise from "up".
    private func snap(_ t: CGSize) -> Int {
        let d = (t.width * t.width + t.height * t.height).squareRoot()
        if d < diameter * 0.22 { return -1 }        // deadzone scales with the control
        var a = atan2(t.width, -t.height) * 180 / .pi
        if a < 0 { a += 360 }
        return Int((a + 22.5) / 45.0) % 8
    }

    private func stickKeys(_ d: Int, _ q: [Int32]) -> [Int32] {
        switch d {
        case 0: return [q[0]]
        case 1: return [q[0], q[1]]
        case 2: return [q[1]]
        case 3: return [q[2], q[1]]
        case 4: return [q[2]]
        case 5: return [q[2], q[3]]
        case 6: return [q[3]]
        case 7: return [q[0], q[3]]
        default: return []
        }
    }

    /// Release what is no longer held, press what newly is. A blanket
    /// release/re-press would make a held direction stutter as the thumb
    /// wanders inside one sector.
    private func applyStick(_ next: Int, _ q: [Int32]) {
        guard next != stickDir else { return }
        let old = Set(stickKeys(stickDir, q)), new = Set(stickKeys(next, q))
        for vk in old.subtracting(new) { winios_post_key(vk, 0) }
        for vk in new.subtracting(old) { winios_post_key(vk, 1) }
        if stickDir == -1, next != -1 { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        stickDir = next
    }

    /// Haptic on the DOWN edge only — a held movement key would otherwise buzz
    /// continuously for as long as you walk.
    private func press(_ down: Bool) {
        if down { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        switch control.action {
        case .key(let vk):
            winios_post_key(vk, down ? 1 : 0)
        case .mouseLeft:
            winios_pointer(0, 0, down ? 0x0002 : 0x0004, 0)   // LEFTDOWN / LEFTUP
        case .mouseRight:
            winios_pointer(0, 0, down ? 0x0008 : 0x0010, 0)   // RIGHTDOWN / RIGHTUP
        case .keyboardToggle:
            if down { MetalBackedView.toggleKeyboard() }
        case .none, .joystickWASD, .joystickArrows:
            break                                              // sticks drive themselves
        case .pad:
            break     // ml645: no XInput yet — deliberately inert, and labelled so
        }
    }
}

/// ml645 — the mapping panel. Shown for the selected control in edit mode.
struct MappingPanel: View {
    let control: TouchControl
    let screen: CGSize
    @ObservedObject private var m = TouchControlsModel.shared
    @State private var tab = 0                    // 0 keyboard, 1 controller


    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tabButton(0, "keyboard")
                tabButton(1, "gamecontroller")
            }
            Rectangle().fill(.white.opacity(0.15)).frame(height: 1)
            ScrollView {
                (tab == 0 ? AnyView(keyboardTab) : AnyView(controllerTab))
                    .padding(10)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .background(GlassShape())
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.18), lineWidth: 1))
        .position(layout.center)
    }

    private struct Placement { var center: CGPoint; var size: CGSize }

    /// ml646: the panel must NEVER sit under the control it is editing.
    ///
    /// The old version only tried below/above and then clamped, which on a
    /// 390pt-tall landscape phone silently put the panel right on top of any
    /// control near the middle: 240 of panel + 64 of control + gaps does not fit
    /// in 390 either way, so the clamp was the only thing deciding placement.
    ///
    /// Try each side in turn, at shrinking sizes, and take the first that fits
    /// on the screen along the axis it separates on. Clamping the OTHER axis is
    /// then always safe — below/above are separated vertically, so no horizontal
    /// clamp can reintroduce an overlap, and vice versa.
    private var layout: Placement {
        let cx = CGFloat(control.nx) * screen.width
        let cy = CGFloat(control.ny) * screen.height
        let r  = TouchControlsModel.baseDiameter * CGFloat(control.scale) / 2
        let gap: CGFloat = 14, edge: CGFloat = 8

        for size in [CGSize(width: 340, height: 236),
                     CGSize(width: 300, height: 196),
                     CGSize(width: 264, height: 164)] {
            let clampX = min(max(cx, size.width  / 2 + edge), screen.width  - size.width  / 2 - edge)
            let clampY = min(max(cy, size.height / 2 + edge), screen.height - size.height / 2 - edge)
            if cy + r + gap + size.height <= screen.height - edge {
                return Placement(center: CGPoint(x: clampX, y: cy + r + gap + size.height / 2), size: size)
            }
            if cy - r - gap - size.height >= edge {
                return Placement(center: CGPoint(x: clampX, y: cy - r - gap - size.height / 2), size: size)
            }
            if cx + r + gap + size.width <= screen.width - edge {
                return Placement(center: CGPoint(x: cx + r + gap + size.width / 2, y: clampY), size: size)
            }
            if cx - r - gap - size.width >= edge {
                return Placement(center: CGPoint(x: cx - r - gap - size.width / 2, y: clampY), size: size)
            }
        }
        // Nothing fits alongside — smallest panel, corner furthest from the
        // control, so it still cannot cover it.
        let size = CGSize(width: 264, height: 164)
        return Placement(
            center: CGPoint(x: cx < screen.width  / 2 ? screen.width  - size.width  / 2 - edge
                                                      : size.width  / 2 + edge,
                            y: cy < screen.height / 2 ? screen.height - size.height / 2 - edge
                                                      : size.height / 2 + edge),
            size: size)
    }

    private func tabButton(_ i: Int, _ icon: String) -> some View {
        Button { tab = i } label: {
            Image(systemName: icon)                       // stroke, not filled
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.white.opacity(tab == i ? 1.0 : 0.38))
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.plain)
    }

    // ---- catalogues ----
    private var letters: [(String, ControlAction)] {
        (0x41...0x5A).map { (String(UnicodeScalar(UInt8($0))), ControlAction.key(Int32($0))) }
    }
    private var digits: [(String, ControlAction)] {
        (0x30...0x39).map { (String(UnicodeScalar(UInt8($0))), ControlAction.key(Int32($0))) }
    }
    private var fkeys: [(String, ControlAction)] {
        (0...11).map { ("F\($0 + 1)", ControlAction.key(Int32(0x70 + $0))) }
    }
    private var numpad: [(String, ControlAction)] {
        (0...9).map { ("N\($0)", ControlAction.key(Int32(0x60 + $0))) }
        + [("N*", .key(0x6A)), ("N+", .key(0x6B)), ("N−", .key(0x6D)),
           ("N.", .key(0x6E)), ("N/", .key(0x6F))]
    }

    private var keyboardTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            section("Pointer, sticks & special", [
                ("L click", .mouseLeft), ("R click", .mouseRight),
                ("WASD", .joystickWASD), ("Arrows", .joystickArrows),
                ("Keyboard", .keyboardToggle), ("None", .none),
            ])
            section("Letters", letters)
            section("Numbers", digits)
            section("Function", fkeys)
            section("Modifiers & editing", [
                ("Esc", .key(0x1B)), ("Tab", .key(0x09)), ("Caps", .key(0x14)),
                ("Shift", .key(0x10)), ("Ctrl", .key(0x11)), ("Alt", .key(0x12)),
                ("Space", .key(0x20)), ("Enter", .key(0x0D)), ("Bksp", .key(0x08)),
                ("Win", .key(0x5B)),
            ])
            section("Navigation", [
                ("←", .key(0x25)), ("↑", .key(0x26)), ("→", .key(0x27)), ("↓", .key(0x28)),
                ("Ins", .key(0x2D)), ("Del", .key(0x2E)), ("Home", .key(0x24)),
                ("End", .key(0x23)), ("PgUp", .key(0x21)), ("PgDn", .key(0x22)),
            ])
            section("Symbols", [
                ("-", .key(0xBD)), ("=", .key(0xBB)), ("[", .key(0xDB)), ("]", .key(0xDD)),
                ("\\", .key(0xDC)), (";", .key(0xBA)), ("'", .key(0xDE)), (",", .key(0xBC)),
                (".", .key(0xBE)), ("/", .key(0xBF)), ("`", .key(0xC0)),
            ])
            section("Numpad", numpad)
        }
    }

    private var controllerTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("These chips are placeholders for XInput, which needs the Wine HID stack "
                 + "and isn't wired up yet. A physical controller works today: bind its "
                 + "buttons to keys in Settings → Physical controller.")
                .font(.system(size: 11))
                .foregroundStyle(.orange.opacity(0.95))
                .fixedSize(horizontal: false, vertical: true)
            section("Face", [("A", .pad("A")), ("B", .pad("B")), ("X", .pad("X")), ("Y", .pad("Y"))])
            section("D-pad", [("D↑", .pad("D↑")), ("D↓", .pad("D↓")),
                              ("D←", .pad("D←")), ("D→", .pad("D→"))])
            section("Bumpers & triggers", [("LB", .pad("LB")), ("RB", .pad("RB")),
                                           ("LT", .pad("LT")), ("RT", .pad("RT"))])
            section("Sticks", [("LS", .pad("LS")), ("RS", .pad("RS")),
                               ("L3", .pad("L3")), ("R3", .pad("R3"))])
            section("System", [("Menu", .pad("Menu")), ("View", .pad("View")),
                               ("Guide", .pad("Guide"))])
        }
    }

    private func section(_ title: String, _ items: [(String, ControlAction)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: 6)], spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    chip(it.0, it.1)
                }
            }
        }
    }

    private func chip(_ label: String, _ action: ControlAction) -> some View {
        let on = control.action == action
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if let i = m.index(of: control.id) { m.controls[i].action = action }
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .foregroundStyle(.white.opacity(action.isPad ? 0.55 : 1.0))
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(.white.opacity(on ? 0.36 : 0.12)))
        }
        .buttonStyle(.plain)
    }
}
