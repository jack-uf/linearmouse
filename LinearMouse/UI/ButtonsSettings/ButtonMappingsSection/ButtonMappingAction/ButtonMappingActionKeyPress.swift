// MIT License
// Copyright (c) 2021-2026 LinearMouse

import KeyKit
import ObservationToken
import SwiftUI

struct ButtonMappingActionKeyPress: View {
    @Binding var action: Scheme.Buttons.Mapping.Action

    var body: some View {
        KeyboardShortcutRecorder(keys: $action.keyPressKeys)
    }
}

struct KeyboardShortcutRecorder: View {
    @Binding var keys: [Key]

    @State private var recording = false {
        didSet {
            guard oldValue != recording else {
                return
            }
            recordingUpdated()
        }
    }

    @State private var recordingObservationToken: ObservationToken?

    @State private var recordingState = KeyboardShortcutRecordingState()

    var body: some View {
        Button {
            recording.toggle()
        } label: {
            Group {
                if recording {
                    Text("Recording")
                        .foregroundColor(.orange)
                } else {
                    if keys.isEmpty {
                        Text("Click to record")
                    } else {
                        Text(keys.map(\.description).joined())
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func recordingUpdated() {
        recordingObservationToken = nil

        if recording {
            recordingState = .init()

            recordingObservationToken = try? EventTap.observe([
                .flagsChanged,
                .keyDown
            ]) { _, event in
                eventReceived(event)
            }

            if recordingObservationToken == nil {
                recording = false
            }
        }
    }

    private func eventReceived(_ event: CGEvent) -> CGEvent? {
        switch event.type {
        case .flagsChanged:
            recordingState.modifierFlagsChanged(event.flags)

            // If all modifier keys are released without and other key pressed,
            // just record the modifier keys.
            if event.flags.isDisjoint(with: [.maskControl, .maskShift, .maskAlternate, .maskCommand]) {
                keys = recordingState.keys
                recording = false
            }

        case .keyDown:
            let keyCodeResolver = KeyCodeResolver()
            guard let key = keyCodeResolver.key(from: CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)))
            else {
                break
            }
            keys = recordingState.keyDown(key, modifierFlags: event.flags)
            recording = false

        default:
            break
        }

        return nil
    }
}

struct KeyboardShortcutRecordingState {
    private(set) var modifiers: CGEventFlags = []

    var keys: [Key] {
        Self.keys(for: modifiers)
    }

    mutating func modifierFlagsChanged(_ flags: CGEventFlags) {
        modifiers.formUnion(flags)
    }

    mutating func keyDown(_ key: Key, modifierFlags flags: CGEventFlags) -> [Key] {
        modifiers.formUnion(flags)
        return Self.keys(for: modifiers) + [key]
    }

    private static func keys(for flags: CGEventFlags) -> [Key] {
        var keys = [Key]()

        if flags.contains(.maskControl) {
            keys.append(flags.contains(.init(rawValue: UInt64(NX_DEVICERCTLKEYMASK))) ? .controlRight : .control)
        }
        if flags.contains(.maskShift) {
            keys.append(flags.contains(.init(rawValue: UInt64(NX_DEVICERSHIFTKEYMASK))) ? .shiftRight : .shift)
        }
        if flags.contains(.maskAlternate) {
            keys.append(flags.contains(.init(rawValue: UInt64(NX_DEVICERALTKEYMASK))) ? .optionRight : .option)
        }
        if flags.contains(.maskCommand) {
            keys.append(flags.contains(.init(rawValue: UInt64(NX_DEVICERCMDKEYMASK))) ? .commandRight : .command)
        }

        return keys
    }
}
