import Foundation
import SwiftUI
import UIKit
import os

@_silgen_name("os_proc_available_memory")
private func os_proc_available_memory() -> size_t

/// DXMT present pacing (g_madeira_vsync_mode). Raw values are the mode
/// numbers the unix side switches on; 3 and 4 come from
/// build/dxmt-ios/patch_present_cap.py.
enum FrameCap: Int32, CaseIterable, Identifiable {
    case locked60 = 1
    case cap40 = 4
    case cap30 = 3
    case max = 0
    case raw = 2

    static let key = "madeira.frameCap"
    static let autoCoolKey = "madeira.autoCoolDown"

    var id: Int32 { rawValue }

    var label: String {
        switch self {
        case .locked60: return "60"
        case .cap40:    return "40"
        case .cap30:    return "30"
        case .max:      return "MAX(\(UIScreen.main.maximumFramesPerSecond))"
        case .raw:      return "RAW"
        }
    }

    var settingsLabel: String {
        switch self {
        case .locked60: return "60 fps"
        case .cap40:    return "40 fps (cooler)"
        case .cap30:    return "30 fps (coolest)"
        case .max:      return "Display max (\(UIScreen.main.maximumFramesPerSecond) Hz)"
        case .raw:      return "Unthrottled (benchmark)"
        }
    }

    var color: Color {
        switch self {
        case .locked60: return .cyan
        case .cap40:    return .mint
        case .cap30:    return .green
        case .max:      return .pink
        case .raw:      return .orange
        }
    }

    /// Pill tap order: 60 → 40 → 30 → MAX → RAW → 60.
    var next: FrameCap {
        switch self {
        case .locked60: return .cap40
        case .cap40:    return .cap30
        case .cap30:    return .max
        case .max:      return .raw
        case .raw:      return .locked60
        }
    }

    static var current: FrameCap {
        FrameCap(rawValue: madeira_get_vsync_locked()) ?? .locked60
    }

    /// The user's chosen cap (Settings / pill), independent of any
    /// temporary thermal throttle.
    static var saved: FrameCap {
        let v = UserDefaults.standard.object(forKey: key) as? Int
        return v.flatMap { FrameCap(rawValue: Int32($0)) } ?? .locked60
    }

    static func apply(_ cap: FrameCap, persist: Bool) {
        madeira_set_vsync_locked(cap.rawValue)
        ProMotionIntent.shared.setActive(cap == .max || cap == .raw)
        if persist { UserDefaults.standard.set(Int(cap.rawValue), forKey: key) }
    }

    static var autoCoolDown: Bool {
        UserDefaults.standard.object(forKey: autoCoolKey) as? Bool ?? true
    }
}

/// Process-wide performance sampler shared by every overlay variant.
///
/// One set of timers feeds FPS, memory footprint, thermal state and low-power
/// mode to the portrait Activity screen, the landscape pillarbox readout and
/// the full-screen HUD, so switching layouts never resets the FPS window and
/// the cost stays at one task_info per 250ms no matter how many views show it.
///
/// Warnings are edge-triggered: each transition into a worse tier is logged
/// once to LogStore (so a jetsam kill leaves "memory critical" in the log a
/// few seconds before the process vanishes) and surfaced as a banner that the
/// user can dismiss until the tier changes again.
final class PerfMonitor: ObservableObject {
    static let shared = PerfMonitor()

    // MARK: Published readouts

    @Published private(set) var presentCount: UInt64 = 0
    @Published private(set) var fps: Double = 0
    /// phys_footprint in MB — the SAME counter jetsam judges the process on.
    @Published private(set) var memMB: Int = 0
    @Published private(set) var thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    @Published private(set) var lowPower: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled

    /// Dynamic Jetsam limit based on device physical RAM (5~6GB+ supported with increased-memory-limit).
    /// On 8GB devices (iPhone 15 Pro, 16, 16 Pro) allows up to ~6144MB.
    /// On 6GB devices (iPhone 13 Pro, 14, 15) allows up to ~5120MB.
    static let jetsamLimitMB: Int = {
        let totalRAM_MB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024))
        if totalRAM_MB >= 12000 {
            return 9216   // 9GB on 12GB+ iPads
        } else if totalRAM_MB >= 7500 {
            return 6144   // 6GB on 8GB devices
        } else if totalRAM_MB >= 5500 {
            return 5120   // 5GB on 6GB devices
        } else {
            return 4096   // 4GB baseline
        }
    }()

    /// Exact remaining memory in MB before Jetsam kill, queried from the iOS kernel.
    static func availableHeadroomMB(currentFootprintMB: Int) -> Int {
        let avail = os_proc_available_memory()
        if avail > 0 {
            return Int(avail / (1024 * 1024))
        }
        return max(jetsamLimitMB - currentFootprintMB, 0)
    }

    enum MemoryTier: Int, Comparable {
        case ok = 0, elevated, high, critical
        static func < (a: MemoryTier, b: MemoryTier) -> Bool { a.rawValue < b.rawValue }
    }

    enum Warning: Equatable {
        case memory(MemoryTier)
        case thermal(ProcessInfo.ThermalState)

        var title: String {
            switch self {
            case .memory(.critical): return "Memory critical"
            case .memory(.high):     return "Memory high"
            case .memory:            return "Memory elevated"
            case .thermal(.critical): return "Device overheating"
            case .thermal(.serious):  return "Device hot"
            case .thermal:            return "Device warm"
            }
        }

        var detail: String {
            switch self {
            case .memory(.critical):
                return "Under 128 MB before iOS kills the app. Save now."
            case .memory(.high):
                return "Under 384 MB of headroom. Expect a crash if usage keeps climbing."
            case .memory:
                return "Under 768 MB of headroom left."
            case .thermal(.critical):
                return "iOS is throttling hard. Frame rate will drop until the phone cools."
            case .thermal(.serious):
                return "ProMotion is capped and the CPU is being throttled."
            case .thermal:
                return "Performance may dip. Consider the 60 Hz pacing mode."
            }
        }

        var color: Color {
            switch self {
            case .memory(.critical), .thermal(.critical): return .red
            case .memory(.high), .thermal(.serious):      return .orange
            default:                                      return .yellow
            }
        }

        var symbol: String {
            switch self {
            case .memory:  return "memorychip"
            case .thermal: return "thermometer.high"
            }
        }
    }

    // MARK: Derived helpers

    var memoryTier: MemoryTier { Self.tier(forFootprintMB: memMB) }

    /// Headroom-based, because the absolute number means nothing without the
    /// ceiling: green >768MB free, yellow >384MB, orange >128MB, red below.
    static func tier(forFootprintMB mb: Int) -> MemoryTier {
        guard mb > 0 else { return .ok }
        let free = availableHeadroomMB(currentFootprintMB: mb)
        if free > 768 { return .ok }
        if free > 384 { return .elevated }
        if free > 128 { return .high }
        return .critical
    }

    var memColor: Color {
        if memMB == 0 { return .secondary }
        switch memoryTier {
        case .ok:       return .green
        case .elevated: return .yellow
        case .high:     return .orange
        case .critical: return .red
        }
    }

    var thermalColor: Color {
        switch thermal {
        case .nominal:  return .green
        case .fair:     return .yellow
        case .serious:  return .orange
        case .critical: return .red
        @unknown default: return .secondary
        }
    }

    var thermalLabel: String {
        switch thermal {
        case .nominal:  return "COOL"
        case .fair:     return "WARM"
        case .serious:  return "HOT"
        case .critical: return "CRIT"
        @unknown default: return "?"
        }
    }

    var thermalSymbol: String {
        switch thermal {
        case .nominal:  return "thermometer.low"
        case .fair:     return "thermometer.medium"
        default:        return "thermometer.high"
        }
    }

    // MARK: Sampling

    private var sampleTimer: Timer?
    private var displayTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var refCount = 0

    /// Ring buffer of (timestamp, count) pairs, 100ms cadence, 5s window.
    private var samples: [(t: CFAbsoluteTime, c: UInt64)] = []
    private let bufferCapacity = 50  // 5s @ 100ms

    private var lastMemoryTier: MemoryTier = .ok
    private var lastThermal: ProcessInfo.ThermalState = .nominal

    /// Thermal throttle: cap dropped to 30 while the state is serious or
    /// worse, and the user's cap restored once it is nominal again. The
    /// gap between the two thresholds is the hysteresis.
    @Published private(set) var thermalThrottled = false

    private init() {}

    /// Reference-counted so multiple overlays can be on screen at once and the
    /// timers only stop when the last one goes away.
    func start() {
        refCount += 1
        guard refCount == 1 else { return }

        let now = CFAbsoluteTimeGetCurrent()
        let c = madeira_get_present_count()
        samples = [(now, c)]
        presentCount = c
        memMB = readFootprintMB()
        thermal = ProcessInfo.processInfo.thermalState
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        lastMemoryTier = memoryTier
        lastThermal = thermal
        evaluateWarnings()

        // 100ms sampling keeps the FPS buffer fresh.
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let t = CFAbsoluteTimeGetCurrent()
            let cur = madeira_get_present_count()
            self.samples.append((t, cur))
            if self.samples.count > self.bufferCapacity { self.samples.removeFirst() }
            self.presentCount = cur
        }

        // 250ms display refresh: adaptive-window FPS plus one task_info call.
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.fps = self.computeAdaptiveFPS()
            self.memMB = self.readFootprintMB()
            self.evaluateWarnings()
        }

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.thermal = ProcessInfo.processInfo.thermalState
            self.evaluateWarnings()
        })
        observers.append(nc.addObserver(forName: .NSProcessInfoPowerStateDidChange,
                                        object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let lp = ProcessInfo.processInfo.isLowPowerModeEnabled
            guard lp != self.lowPower else { return }
            self.lowPower = lp
            LogStore.shared.log(lp ? "Low Power Mode enabled: display capped at 60 Hz, CPU throttled"
                                   : "Low Power Mode disabled")
        })
    }

    func stop() {
        refCount = max(refCount - 1, 0)
        guard refCount == 0 else { return }
        sampleTimer?.invalidate(); sampleTimer = nil
        displayTimer?.invalidate(); displayTimer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    // MARK: Warnings

    private func evaluateWarnings() {
        let tier = memoryTier
        if tier != lastMemoryTier {
            if tier > lastMemoryTier {
                let free = Self.availableHeadroomMB(currentFootprintMB: memMB)
                LogStore.shared.log("Memory \(Warning.memory(tier).title.lowercased()): \(memMB)MB used, \(free)MB before jetsam",
                                    level: tier >= .high ? .error : .info)
            } else if tier == .ok {
                LogStore.shared.log("Memory back to normal: \(memMB)MB used", level: .success)
            }
            lastMemoryTier = tier
        }

        if thermal != lastThermal {
            let worse = thermal.rawValue > lastThermal.rawValue
            if worse {
                LogStore.shared.log("Thermal state \(thermalLabel.lowercased()): \(Warning.thermal(thermal).detail)",
                                    level: thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue ? .error : .info)
            } else if thermal == .nominal {
                LogStore.shared.log("Thermal state back to nominal", level: .success)
            }
            lastThermal = thermal
        }
        applyThermalThrottle()
    }

    private func applyThermalThrottle() {
        let hot = thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        if hot && !thermalThrottled && FrameCap.autoCoolDown {
            let current = FrameCap.current
            // Nothing to gain below 30; leave RAW alone too, it is a benchmark.
            guard current != .cap30, current != .raw else { return }
            thermalThrottled = true
            FrameCap.apply(.cap30, persist: false)
            LogStore.shared.log("Auto cool-down: frame cap \(current.label) → 30 until the phone is cool")
        } else if thermalThrottled && (thermal == .nominal || !FrameCap.autoCoolDown) {
            thermalThrottled = false
            let saved = FrameCap.saved
            FrameCap.apply(saved, persist: false)
            LogStore.shared.log("Auto cool-down over: frame cap back to \(saved.label)", level: .success)
        }
    }

    // MARK: Readers

    /// task_info(TASK_VM_INFO).phys_footprint is the very same counter the
    /// kernel judges the process on, so this is the real number and not an
    /// approximation from resident size.
    private func readFootprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Int(info.phys_footprint / (1024 * 1024))
    }

    /// Compute FPS over an adaptive window: starting from the newest sample,
    /// walk backwards until the window holds ≥3 presents AND spans ≥1s (or we
    /// hit buffer start). The 1s minimum matters: with 100ms sampling, a
    /// short window quantizes the readout to presents/0.2s = multiples of
    /// 5.0 — at a true ~19 FPS it displayed a rock-steady "20.0" (4 presents
    /// per 0.2s) with "dips" to 15.0, which read as an artificial frame lock
    /// (2026-07-04, cost a day of pacing-hunt confusion). ≥1s gives 1-FPS
    /// resolution; still responsive for a debug readout.
    private func computeAdaptiveFPS() -> Double {
        guard samples.count >= 2 else { return 0 }
        let latest = samples.last!
        var oldest = samples[0]
        for i in (0..<samples.count).reversed() {
            let candidate = samples[i]
            let delta = latest.c &- candidate.c
            let span = latest.t - candidate.t
            if delta >= 3 && span >= 1.0 {
                oldest = candidate
                break
            }
            oldest = candidate
        }
        let dt = latest.t - oldest.t
        let dc = latest.c &- oldest.c
        guard dt > 0.0001 else { return 0 }
        return Double(dc) / dt
    }
}

/// Keeps PerfMonitor sampling for as long as a game surface is on screen,
/// independent of whether the readout overlay is enabled — memory and
/// thermal warnings must still reach the log and the banner when the user
/// has hidden the numbers.
private struct PerfMonitored: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear { PerfMonitor.shared.start() }
            .onDisappear { PerfMonitor.shared.stop() }
    }
}

extension View {
    func perfMonitored() -> some View { modifier(PerfMonitored()) }
}
