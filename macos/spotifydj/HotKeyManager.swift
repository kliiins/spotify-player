import AppKit
import Carbon
import Combine

final class HotKeyManager: ObservableObject {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    var onHotKey: (() -> Void)?

    func start() {
        let hotKeyID = EventHotKeyID(
            signature: OSType(
                (Character("D").asciiValue ?? 68) << 24 |
                (Character("J").asciiValue ?? 74) << 16 |
                (Character("D").asciiValue ?? 68) << 8 |
                (Character("J").asciiValue ?? 74)
            ),
            id: 1
        )

        // Shift + Space
        let modifiers = UInt32(shiftKey)

        // Space
        let keyCode: UInt32 = 49

        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        print(
            "Hotkey registration status:",
            status
        )

        let eventSpec = EventTypeSpec(
            eventClass: OSType(
                kEventClassKeyboard
            ),
            eventKind: UInt32(
                kEventHotKeyPressed
            )
        )

        let callback: EventHandlerUPP = {
            (_, _, userData) -> OSStatus in

            guard let userData else {
                return noErr
            }

            let manager =
                Unmanaged<HotKeyManager>
                    .fromOpaque(userData)
                    .takeUnretainedValue()

            DispatchQueue.main.async {
                manager.onHotKey?()
            }

            return noErr
        }

        let result = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            [eventSpec],
            Unmanaged
                .passUnretained(self)
                .toOpaque(),
            &eventHandlerRef
        )

        print(
            "Event handler status:",
            result
        )

        print(
            "Global hotkey registered: Shift + Space"
        )
    }

    func stop() {
        if let hotKeyRef {
            UnregisterEventHotKey(
                hotKeyRef
            )

            self.hotKeyRef = nil
        }

        if let eventHandlerRef {
            RemoveEventHandler(
                eventHandlerRef
            )

            self.eventHandlerRef = nil
        }
    }

    deinit {
        stop()
    }
}
