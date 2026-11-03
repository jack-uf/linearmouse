// MIT License
// Copyright (c) 2021-2026 LinearMouse

import CoreGraphics
import Foundation

struct ButtonMappingRecordingEngine {
    typealias Mapping = Scheme.Buttons.Mapping
    typealias Button = Mapping.Button

    enum Recognition: Equatable {
        case shortPress
        case longPress
        case swipe(ButtonMappingEngine.SwipeDirection)
        case wheel(Mapping.ScrollDirection)
    }

    struct Snapshot: Equatable {
        var mapping: Mapping?
        var pressedButtons: [Button] = []
        var modifierFlags: CGEventFlags = []
        var movementDirection: ButtonMappingEngine.SwipeDirection?
        var recognition: Recognition?
        var isComplete = false
        var isReadyForOrderedInput = false

        var isChord: Bool {
            guard let trigger = mapping?.trigger,
                  case .button = trigger.input else {
                return false
            }
            return trigger.simultaneous?.isEmpty == false
        }

        var isOrdered: Bool {
            guard let trigger = mapping?.trigger,
                  case .button = trigger.input else {
                return false
            }
            return trigger.whileHeld?.isEmpty == false
        }
    }

    private let policy: ButtonMappingPolicy
    private let recordsClickSequences: Bool
    private var pressedButtons = [Button]()
    private var heldPrefixButtons = [Button]()
    private var triggerButtons = [Button]()
    private var pressedAt = [Button: UInt64]()
    private var triggerStartedAt: UInt64?
    private var clickCount = 1
    private var lastTimestamp: UInt64 = 0
    private var modifierFlags: CGEventFlags = []
    private var deltaX = 0.0
    private var deltaY = 0.0
    private var recognition: Recognition?
    private var wheelMapping: Mapping?
    private var completed = false
    private var completionDeadline: UInt64?

    init(
        policy: ButtonMappingPolicy = .default,
        recordsClickSequences: Bool = false
    ) {
        self.policy = policy
        self.recordsClickSequences = recordsClickSequences
    }

    var snapshot: Snapshot {
        .init(
            mapping: currentMapping,
            pressedButtons: pressedButtons,
            modifierFlags: modifierFlags,
            movementDirection: movementDirection,
            recognition: recognition,
            isComplete: completed,
            isReadyForOrderedInput: isReadyForOrderedInput
        )
    }

    mutating func modifierFlagsChanged(_ flags: CGEventFlags) {
        guard pressedButtons.isEmpty,
              wheelMapping == nil,
              recognition == nil else {
            return
        }
        modifierFlags = ModifierState.generic(from: flags)
    }

    mutating func buttonDown(
        _ button: Button,
        modifierFlags: CGEventFlags,
        clickCount: Int = 1,
        at timestamp: UInt64
    ) {
        advance(to: timestamp)
        let isClickSequenceContinuation = recordsClickSequences &&
            pressedButtons.isEmpty &&
            clickCount > 1
        let replacesProvisionalLongPress = recognition == .longPress && !pressedButtons.isEmpty
        guard wheelMapping == nil,
              recognition == nil || replacesProvisionalLongPress || isClickSequenceContinuation,
              !pressedButtons.contains(button) else {
            return
        }

        if replacesProvisionalLongPress {
            recognition = nil
        }

        if pressedButtons.isEmpty {
            self.modifierFlags = ModifierState.generic(from: modifierFlags)
            self.clickCount = min(max(clickCount, 1), 3)
            completionDeadline = nil
            if recordsClickSequences, self.clickCount > 1 {
                triggerButtons = [button]
                heldPrefixButtons = []
                triggerStartedAt = timestamp
                recognition = nil
                completed = false
            }
        }

        pressedButtons.append(button)
        pressedAt[button] = timestamp

        if triggerButtons.isEmpty {
            triggerButtons = [button]
            triggerStartedAt = timestamp
        } else if belongsToCurrentTriggerGroup(at: timestamp) {
            triggerButtons.append(button)
        } else {
            heldPrefixButtons.append(contentsOf: triggerButtons)
            triggerButtons = [button]
            triggerStartedAt = timestamp
            deltaX = 0
            deltaY = 0
        }
    }

    mutating func buttonUp(_ button: Button, at timestamp: UInt64) {
        advance(to: timestamp)
        guard pressedButtons.contains(button) else {
            return
        }

        if wheelMapping == nil,
           recognition == nil,
           triggerButtons.contains(button) || heldPrefixButtons.contains(button) {
            recognition = .shortPress
        }

        pressedButtons.removeAll { $0 == button }
        if pressedButtons.isEmpty {
            if recordsClickSequences {
                completionDeadline = timestamp &+ 300_000_000
            } else {
                completed = currentMapping != nil
            }
        }
    }

    mutating func pointerMoved(deltaX: Double, deltaY: Double, at timestamp: UInt64) {
        advance(to: timestamp)
        // Long press is only a preview while every participating button is
        // held. After any release, movement must not change the outcome.
        guard !pressedButtons.isEmpty,
              triggerButtons.allSatisfy(pressedButtons.contains),
              heldPrefixButtons.allSatisfy(pressedButtons.contains),
              wheelMapping == nil,
              recognition == nil || recognition == .longPress else {
            return
        }

        self.deltaX += deltaX
        self.deltaY += deltaY
        if let direction = swipeDirection(deltaX: self.deltaX, deltaY: self.deltaY) {
            recognition = .swipe(direction)
        }
    }

    mutating func wheel(
        _ direction: Mapping.ScrollDirection,
        modifierFlags: CGEventFlags,
        at timestamp: UInt64
    ) {
        advance(to: timestamp)
        let replacesProvisionalLongPress = recognition == .longPress && !pressedButtons.isEmpty
        guard recognition == nil || replacesProvisionalLongPress,
              wheelMapping == nil else {
            return
        }

        if replacesProvisionalLongPress {
            recognition = nil
        }

        let heldButtons = pressedButtons
        let flags = heldButtons.isEmpty ? ModifierState.generic(from: modifierFlags) : self.modifierFlags
        wheelMapping = .init(
            trigger: .init(
                input: .wheel(direction),
                whileHeld: heldButtons,
                modifiers: modifiers(from: flags)
            ),
            action: .arg0(.auto)
        )
        recognition = .wheel(direction)
        completed = heldButtons.isEmpty
    }

    mutating func advance(to timestamp: UInt64) {
        lastTimestamp = max(lastTimestamp, timestamp)
        if !pressedButtons.isEmpty,
           wheelMapping == nil,
           recognition == nil,
           let activatedAt = triggerButtons.compactMap({ pressedAt[$0] }).max(),
           timestamp >= activatedAt &+ policy.longPressNanoseconds {
            recognition = .longPress
        }
        if pressedButtons.isEmpty,
           let completionDeadline,
           timestamp >= completionDeadline {
            completed = currentMapping != nil
            self.completionDeadline = nil
        }
    }

    mutating func reset() {
        self = .init(policy: policy, recordsClickSequences: recordsClickSequences)
    }

    private var isReadyForOrderedInput: Bool {
        guard recognition == nil,
              wheelMapping == nil,
              let triggerStartedAt,
              !triggerButtons.isEmpty,
              triggerButtons.allSatisfy(pressedButtons.contains) else {
            return false
        }
        return lastTimestamp >= triggerStartedAt &+ policy.chordWindowNanoseconds
    }

    private func belongsToCurrentTriggerGroup(at timestamp: UInt64) -> Bool {
        guard let triggerStartedAt else {
            return false
        }
        return timestamp &- triggerStartedAt <= policy.chordWindowNanoseconds
    }

    private var currentMapping: Mapping? {
        if let wheelMapping {
            return wheelMapping
        }

        let buttons = triggerButtons
        guard let primaryButton = buttons.first else {
            return nil
        }

        let recognized = recognition ?? .shortPress
        let action: Mapping.Action = .arg0(.auto)
        let outcomes: Mapping.Outcomes
        switch recognized {
        case .shortPress:
            outcomes = .init(shortPress: action)
        case .longPress:
            outcomes = .init(longPress: action)
        case let .swipe(direction):
            var swipe = Mapping.SwipeActions()
            switch direction {
            case .up:
                swipe.up = action
            case .down:
                swipe.down = action
            case .left:
                swipe.left = action
            case .right:
                swipe.right = action
            }
            outcomes = .init(swipe: swipe)
        case .wheel:
            return wheelMapping
        }

        return .init(
            trigger: .init(
                input: .button(primaryButton),
                clickCount: clickCount == 1 ? nil : clickCount,
                simultaneous: Array(buttons.dropFirst()),
                whileHeld: heldPrefixButtons,
                modifiers: modifiers(from: modifierFlags)
            ),
            outcomes: outcomes
        )
    }

    private var movementDirection: ButtonMappingEngine.SwipeDirection? {
        guard sqrt(deltaX * deltaX + deltaY * deltaY) >= 4 else {
            return nil
        }
        if abs(deltaX) > abs(deltaY) {
            return deltaX > 0 ? .right : .left
        }
        return deltaY > 0 ? .down : .up
    }

    private func modifiers(from flags: CGEventFlags) -> [Mapping.Modifier] {
        Mapping.Modifier.allCases.filter { modifier in
            switch modifier {
            case .command:
                return flags.contains(.maskCommand)
            case .shift:
                return flags.contains(.maskShift)
            case .option:
                return flags.contains(.maskAlternate)
            case .control:
                return flags.contains(.maskControl)
            }
        }
    }

    private func swipeDirection(
        deltaX: Double,
        deltaY: Double
    ) -> ButtonMappingEngine.SwipeDirection? {
        let absX = abs(deltaX)
        let absY = abs(deltaY)
        let magnitude = sqrt(deltaX * deltaX + deltaY * deltaY)
        guard magnitude >= policy.swipeThreshold else {
            return nil
        }

        if absX > absY {
            guard absY < policy.swipeDeadZone else {
                return nil
            }
            return deltaX > 0 ? .right : .left
        }

        guard absX < policy.swipeDeadZone else {
            return nil
        }
        return deltaY > 0 ? .down : .up
    }
}
