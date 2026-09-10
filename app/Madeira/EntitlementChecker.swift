import Foundation
import Security

private typealias SecTaskRef = OpaquePointer
private typealias SecTaskCreateFromSelfFn = @convention(c) (CFAllocator?) -> SecTaskRef?
private typealias SecTaskCopyValueForEntitlementFn = @convention(c) (SecTaskRef, CFString, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> CFTypeRef?

func checkAppEntitlement(_ ent: String) -> Bool {
    guard let createSym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecTaskCreateFromSelf"),
          let copySym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecTaskCopyValueForEntitlement") else {
        return false
    }

    let createFn = unsafeBitCast(createSym, to: SecTaskCreateFromSelfFn.self)
    let copyFn = unsafeBitCast(copySym, to: SecTaskCopyValueForEntitlementFn.self)

    guard let task = createFn(nil) else { return false }
    guard let value = copyFn(task, ent as CFString, nil) else {
        return false
    }

    if let number = value as? NSNumber {
        return number.boolValue
    }

    return false
}

struct EntitlementStatus {
    let jitAllowed: Bool
    let increasedMemory: Bool
    let extendedVA: Bool

    static func check() -> EntitlementStatus {
        EntitlementStatus(
            jitAllowed: checkAppEntitlement("com.apple.security.cs.allow-jit"),
            increasedMemory: checkAppEntitlement("com.apple.developer.kernel.increased-memory-limit"),
            extendedVA: checkAppEntitlement("com.apple.developer.kernel.extended-virtual-addressing")
        )
    }
}

/* Runtime check: is a debugger attached to this process (P_TRACED)?
 * This is the signal StikDebug JIT actually rides on — CS_DEBUGGED gets
 * set while traced, enabling JIT-region execution. The allow-jit
 * ENTITLEMENT is macOS-only and never granted on iOS, so the old badge
 * built on it was permanently ✗ no matter what StikDebug did. */
func isDebuggerAttached() -> Bool {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    let ret = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
    guard ret == 0 else { return false }
    return (info.kp_proc.p_flag & P_TRACED) != 0
}
