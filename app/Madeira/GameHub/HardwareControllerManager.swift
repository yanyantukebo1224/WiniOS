import Foundation
import GameController
import SwiftUI

/// Bridges physical gamepads (Xbox, PlayStation, MFi, Backbone One) to WiniOS input queue.
public final class HardwareControllerManager: ObservableObject {
    public static let shared = HardwareControllerManager()
    
    @Published public var connectedControllerCount: Int = 0
    @Published public var latestControllerName: String = ""
    @Published public var isEnabled: Bool = true
    
    // Deadzone for analog sticks
    private let stickDeadzone: Float = 0.25
    
    // State tracking for held keys to prevent repeating storms
    private var heldKeys: Set<Int32> = []
    
    private init() {
        setupObservers()
    }
    
    private func setupObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(controllerDidConnect),
            name: .GCControllerDidConnect,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(controllerDidDisconnect),
            name: .GCControllerDidDisconnect,
            object: nil
        )
        
        // Setup any already-connected controllers
        for controller in GCController.controllers() {
            configureController(controller)
        }
    }
    
    @objc private func controllerDidConnect(_ notification: Notification) {
        guard let controller = notification.object as? GCController else { return }
        DispatchQueue.main.async {
            self.connectedControllerCount = GCController.controllers().count
            self.latestControllerName = controller.vendorName ?? "Game Controller"
        }
        configureController(controller)
    }
    
    @objc private func controllerDidDisconnect(_ notification: Notification) {
        DispatchQueue.main.async {
            self.connectedControllerCount = GCController.controllers().count
            if self.connectedControllerCount == 0 {
                self.latestControllerName = ""
            }
        }
    }
    
    private func configureController(_ controller: GCController) {
        guard let gamepad = controller.extendedGamepad else { return }
        
        // D-Pad / Left Thumbstick -> W/A/S/D movement
        gamepad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            self?.handleStickMovement(x: x, y: y)
        }
        
        gamepad.dpad.valueChangedHandler = { [weak self] _, x, y in
            self?.handleStickMovement(x: x, y: y)
        }
        
        // Right Thumbstick -> Mouse Pointer (for FPS / camera)
        gamepad.rightThumbstick.valueChangedHandler = { _, x, y in
            if abs(x) > 0.15 || abs(y) > 0.15 {
                let dx = Int(x * 12.0)
                let dy = Int(-y * 12.0)
                // Post relative mouse move (flags 0x0001 = MOUSEEVENTF_MOVE)
                winios_pointer(Int32(dx), Int32(dy), 0x0001, 0)
            }
        }
        
        // Button A (Cross) -> Space (Jump / Confirm)
        gamepad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.postKey(vk: 0x20, down: pressed) // VK_SPACE
        }
        
        // Button B (Circle) -> Esc / Back
        gamepad.buttonB.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.postKey(vk: 0x1B, down: pressed) // VK_ESCAPE
        }
        
        // Button X (Square) -> E (Interact)
        gamepad.buttonX.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.postKey(vk: 0x45, down: pressed) // VK_E
        }
        
        // Button Y (Triangle) -> Shift (Sprint / Alt)
        gamepad.buttonY.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.postKey(vk: 0x10, down: pressed) // VK_SHIFT
        }
        
        // Right Trigger (RT) -> Left Mouse Click (Attack / Primary)
        gamepad.rightTrigger.pressedChangedHandler = { _, _, pressed in
            winios_pointer(0, 0, pressed ? 0x0002 : 0x0004, 0) // LEFTDOWN / LEFTUP
        }
        
        // Left Trigger (LT) -> Right Mouse Click (Aim / Secondary)
        gamepad.leftTrigger.pressedChangedHandler = { _, _, pressed in
            winios_pointer(0, 0, pressed ? 0x0008 : 0x0010, 0) // RIGHTDOWN / RIGHTUP
        }
        
        // Right Shoulder (RB) -> Return (Enter)
        gamepad.rightShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.postKey(vk: 0x0D, down: pressed) // VK_RETURN
        }
        
        // Menu / Options button -> Esc (Pause Menu)
        gamepad.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.postKey(vk: 0x1B, down: pressed)
        }
    }
    
    private func handleStickMovement(x: Float, y: Float) {
        guard isEnabled else { return }
        
        let vkW: Int32 = 0x57 // 'W'
        let vkS: Int32 = 0x53 // 'S'
        let vkA: Int32 = 0x41 // 'A'
        let vkD: Int32 = 0x44 // 'D'
        
        // Up / Down
        if y > stickDeadzone {
            postKey(vk: vkW, down: true)
            postKey(vk: vkS, down: false)
        } else if y < -stickDeadzone {
            postKey(vk: vkS, down: true)
            postKey(vk: vkW, down: false)
        } else {
            postKey(vk: vkW, down: false)
            postKey(vk: vkS, down: false)
        }
        
        // Left / Right
        if x > stickDeadzone {
            postKey(vk: vkD, down: true)
            postKey(vk: vkA, down: false)
        } else if x < -stickDeadzone {
            postKey(vk: vkA, down: true)
            postKey(vk: vkD, down: false)
        } else {
            postKey(vk: vkD, down: false)
            postKey(vk: vkA, down: false)
        }
    }
    
    private func postKey(vk: Int32, down: Bool) {
        guard isEnabled else { return }
        if down {
            if !heldKeys.contains(vk) {
                heldKeys.insert(vk)
                winios_post_key(vk, 1)
            }
        } else {
            if heldKeys.contains(vk) {
                heldKeys.remove(vk)
                winios_post_key(vk, 0)
            }
        }
    }
}
