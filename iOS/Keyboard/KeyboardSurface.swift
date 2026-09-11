import UIKit

enum KeyboardEvent {
    case press(KeyboardKey), shiftBegan, shiftEnded(used: Bool), deleteWord, cursor(Int), restoreLetters
}

/// Stable key views and per-finger tracking support slide-to-select and Shift chords.
final class KeyboardSurface: UIView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
    var event: ((KeyboardEvent) -> Void)?
    var alternatives: ((String) -> [String])?
    var configureKey: ((KeyboardKeyView) -> Void)?
    let globe = UIButton(type: .custom)
    private(set) var keys: [KeyboardKeyView] = []
    private var rows: [KeyboardRow] = []
    var palette = KeyboardPalette(dark: false)
    private let popover = KeyboardPopover()
    private var popupOwner: ObjectIdentifier?
    private var sessions: [ObjectIdentifier: TouchSession] = [:]
    private var hidePopup: DispatchWorkItem?
    var tracking: Bool { !sessions.isEmpty }

    private final class TouchSession {
        let origin: KeyboardKeyView
        var current: KeyboardKeyView?
        var point: CGPoint
        var timer: Timer?
        var trackpad = false
        var choosing = false
        var shiftUsed = false
        var dragged = false
        let began = Date()
        init(key: KeyboardKeyView, point: CGPoint) { origin = key; current = key; self.point = point }
        deinit { timer?.invalidate() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        clipsToBounds = false
        globe.accessibilityLabel = "Следующая клавиатура"
        globe.accessibilityIdentifier = "keyboard.globe"
        globe.setImage(UIImage(systemName: "globe"), for: .normal)
        addSubview(globe)
        popover.isHidden = true
        addSubview(popover)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setRows(_ newRows: [KeyboardRow]) {
        if rows != newRows {
            // Keep any fingers already down alive across a numeric-page switch.
            keys.forEach { $0.removeFromSuperview() }
            rows = newRows
            keys = rows.flatMap(\.keys).map { spec in
                let key = KeyboardKeyView(key: spec.key)
                key.accessibilityIdentifier = "keyboard.key.\(spec.key)"
                key.activate = { [weak self] in self?.accessiblePress(spec.key) }
                insertSubview(key, belowSubview: globe)
                return key
            }
        }
        for key in keys {
            configureKey?(key)
            key.isAccessibilityElement = key.key != .globe && key.key != .spacer
            key.isHidden = key.key == .spacer
        }
        globe.isHidden = !keys.contains { $0.key == .globe }
        globe.tintColor = palette.text
        setNeedsLayout()
        layoutIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !rows.isEmpty else { return }
        let rowHeight = bounds.height / CGFloat(rows.count)
        var offset = 0
        for (index, row) in rows.enumerated() {
            let total = row.keys.reduce(CGFloat(0)) { $0 + $1.weight } + 2 * row.inset
            let unit = bounds.width / total
            var x = row.inset * unit
            for spec in row.keys {
                let key = keys[offset]
                key.frame = CGRect(x: x, y: CGFloat(index) * rowHeight, width: spec.weight * unit, height: rowHeight)
                if key.key == .globe { globe.frame = key.frame.insetBy(dx: 3, dy: 5) }
                x += spec.weight * unit
                offset += 1
            }
        }
    }

    private func nearestKey(to point: CGPoint) -> KeyboardKeyView? {
        guard bounds.insetBy(dx: -10, dy: -6).contains(point) else { return nil }
        if keys.contains(where: { !$0.available && $0.frame.contains(point) }) { return nil }
        return keys.filter { $0.key != .globe && $0.key != .spacer }.min {
            distance(point, to: $0.frame) < distance(point, to: $1.frame)
        }
    }

    private func distance(_ p: CGPoint, to frame: CGRect) -> CGFloat {
        let dx = max(frame.minX - p.x, 0, p.x - frame.maxX)
        let dy = max(frame.minY - p.y, 0, p.y - frame.maxY)
        return dx * dx + dy * dy
    }

    private func accessiblePress(_ key: KeyboardKey) {
        if key == .shift { event?(.shiftBegan); event?(.shiftEnded(used: false)) }
        else { event?(.press(key)) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard !sessions.values.contains(where: \.trackpad) else { continue }
            let point = touch.location(in: self)
            guard let key = nearestKey(to: point) else { continue }
            let id = ObjectIdentifier(touch)
            let session = TouchSession(key: key, point: point)
            sessions[id] = session
            key.pressed = true
            UIDevice.current.playInputClick()
            switch key.key {
            case .shift: self.event?(.shiftBegan)
            case .numbers, .symbols: self.event?(.press(key.key))
            case .delete:
                self.event?(.press(.delete))
                schedule(session, after: 0.42) { [weak self, weak session] in
                    guard let self, let session else { return }
                    self.repeatDelete(session)
                    session.timer = Timer.scheduledTimer(withTimeInterval: 0.085, repeats: true) { [weak self, weak session] _ in
                        guard let session else { return }
                        self?.repeatDelete(session)
                    }
                }
            case .space:
                schedule(session, after: 0.35) { [weak self, weak session] in
                    guard let self, let session else { return }
                    session.trackpad = true
                    session.current?.pressed = false
                    self.setTrackpad(true)
                }
            case .character:
                showPreview(key, owner: id)
                scheduleAlternates(session, id: id)
            default: break
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            guard let session = sessions[id] else { continue }
            let point = touch.location(in: self)
            if session.trackpad {
                let steps = Int((point.x - session.point.x) / 9)
                if steps != 0 { self.event?(.cursor(steps)); session.point.x += CGFloat(steps) * 9 }
                continue
            }
            session.point = point
            if session.choosing {
                popover.select(at: point)
                continue
            }
            if session.origin.key == .space { continue }
            if session.origin.key == .delete {
                if !session.origin.frame.insetBy(dx: 18, dy: 18).contains(point) {
                    session.timer?.invalidate(); session.current?.pressed = false
                }
                continue
            }
            let next = nearestKey(to: point)
            guard next !== session.current else { continue }
            session.dragged = true
            session.timer?.invalidate()
            session.current?.pressed = false
            session.current = next
            next?.pressed = true
            if let next, case .character = next.key {
                showPreview(next, owner: id)
                scheduleAlternates(session, id: id)
            } else { dismissPreview(owner: id) }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { finish(touch, cancelled: false) }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { finish(touch, cancelled: true) }
    }

    private func finish(_ touch: UITouch, cancelled: Bool) {
        let id = ObjectIdentifier(touch)
        guard let session = sessions.removeValue(forKey: id) else { return }
        session.timer?.invalidate()
        session.current?.pressed = false
        session.origin.pressed = false
        if session.trackpad { setTrackpad(false) }
        let origin = session.origin.key
        if !cancelled && !session.trackpad {
            var selected = session.current?.key
            if session.choosing {
                let point = touch.location(in: self)
                selected = point.y < session.origin.frame.maxY + 30
                    ? .character(popover.values[popover.selection]) : nil
            }
            if origin == .space && !session.origin.frame.insetBy(dx: 10, dy: 10).contains(touch.location(in: self)) { selected = nil }
            if let selected, selected != .shift, selected != .delete, selected != .numbers, selected != .symbols,
               !sessions.values.contains(where: \.trackpad) {
                for held in sessions.values where held.origin.key == .shift { held.shiftUsed = true }
                if origin == .shift { session.shiftUsed = true }
                self.event?(.press(selected))
                if origin == .numbers { self.event?(.restoreLetters) }
            }
        }
        if origin == .shift { self.event?(.shiftEnded(used: session.shiftUsed || cancelled)) }
        dismissPreview(owner: id)
    }

    private func schedule(_ session: TouchSession, after delay: TimeInterval, action: @escaping () -> Void) {
        session.timer?.invalidate()
        session.timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in action() }
    }

    private func repeatDelete(_ session: TouchSession) {
        if Date().timeIntervalSince(session.began) > 2 { event?(.deleteWord) }
        else { event?(.press(.delete)) }
        UIDevice.current.playInputClick()
    }

    private func scheduleAlternates(_ session: TouchSession, id: ObjectIdentifier) {
        guard let key = session.current, case .character(let value) = key.key else { return }
        schedule(session, after: 0.42) { [weak self, weak session] in
            guard let self, let session, self.popupOwner == id else { return }
            let options = self.alternatives?(value) ?? []
            guard !options.isEmpty else { return }
            session.choosing = true
            self.popover.show(values: options, keyFrame: key.frame, in: self, palette: self.palette)
        }
    }

    private func showPreview(_ key: KeyboardKeyView, owner: ObjectIdentifier) {
        guard case .character = key.key else { return }
        hidePopup?.cancel()
        popupOwner = owner
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        popover.show(values: [key.accessibilityLabel ?? ""], keyFrame: key.frame, in: self, palette: palette)
        bringSubviewToFront(popover)
    }

    private func dismissPreview(owner: ObjectIdentifier) {
        guard popupOwner == owner else { return }
        popupOwner = nil
        let work = DispatchWorkItem { [weak self] in self?.popover.isHidden = true }
        hidePopup?.cancel()
        hidePopup = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.045, execute: work)
    }

    private func setTrackpad(_ active: Bool) {
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.12) {
            self.keys.forEach { $0.trackpad = active }
        }
    }

    func cancelTracking() {
        let hadShift = sessions.values.contains { $0.origin.key == .shift }
        sessions.values.forEach { $0.timer?.invalidate(); $0.current?.pressed = false; $0.origin.pressed = false }
        sessions.removeAll()
        hidePopup?.cancel()
        popupOwner = nil
        popover.isHidden = true
        setTrackpad(false)
        if hadShift { event?(.shiftEnded(used: true)) }
    }
}
