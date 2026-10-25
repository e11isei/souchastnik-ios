import UIKit

enum KeyboardKey: Hashable {
    case character(String), shift, delete, numbers, symbols, space, enter, globe, dismiss, spacer
}

struct KeyboardKeySpec: Equatable {
    let key: KeyboardKey
    var weight: CGFloat = 1
}

struct KeyboardRow: Equatable {
    let keys: [KeyboardKeySpec]
    var inset: CGFloat = 0
}

struct KeyboardPalette {
    let dark: Bool
    var background: UIColor { dark ? UIColor(white: 0.16, alpha: 1) : UIColor(red: 0.82, green: 0.83, blue: 0.85, alpha: 1) }
    var key: UIColor { dark ? UIColor(white: 0.42, alpha: 1) : .white }
    var special: UIColor { dark ? UIColor(white: 0.27, alpha: 1) : UIColor(red: 0.67, green: 0.69, blue: 0.73, alpha: 1) }
    var text: UIColor { dark ? .white : .black }
    var secondary: UIColor { text.withAlphaComponent(0.55) }
}

/// The visible cap is smaller than its hit target, so the gutters remain tappable.
final class KeyboardKeyView: UIView {
    let key: KeyboardKey
    let cap = UIView()
    private let label = UILabel()
    private let icon = UIImageView()
    var activate: (() -> Void)?
    var available = true {
        didSet {
            alpha = available ? 1 : 0.45
            accessibilityTraits = available ? [.keyboardKey] : [.keyboardKey, .notEnabled]
        }
    }
    var pressed = false { didSet { updateColor() } }
    var trackpad = false { didSet { label.alpha = trackpad ? 0 : 1; icon.alpha = trackpad ? 0 : 1 } }
    private var palette = KeyboardPalette(dark: false)
    private var special = false
    private var activeShift = false
    private var actionReturn = false

    init(key: KeyboardKey) {
        self.key = key
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = [.keyboardKey]
        cap.isUserInteractionEnabled = false
        cap.layer.cornerRadius = 7
        cap.layer.shadowOffset = CGSize(width: 0, height: 1)
        cap.layer.shadowRadius = 0
        cap.layer.shadowOpacity = 0.28
        addSubview(cap)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.65
        cap.addSubview(label)
        icon.contentMode = .scaleAspectFit
        cap.addSubview(icon)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        cap.frame = bounds.insetBy(dx: 3, dy: bounds.height < 45 ? 3 : 6)
        label.frame = cap.bounds.insetBy(dx: 2, dy: 0)
        icon.frame = CGRect(x: (cap.bounds.width - 23) / 2, y: (cap.bounds.height - 23) / 2, width: 23, height: 23)
        cap.layer.shadowPath = UIBezierPath(roundedRect: cap.bounds, cornerRadius: 7).cgPath
    }

    func configure(title: String, image: String? = nil, palette: KeyboardPalette,
                   special: Bool = false, activeShift: Bool = false, actionReturn: Bool = false) {
        self.palette = palette
        self.special = special
        self.activeShift = activeShift
        self.actionReturn = actionReturn
        label.text = title
        label.isHidden = image != nil
        icon.image = image.flatMap { UIImage(systemName: $0, withConfiguration: UIImage.SymbolConfiguration(pointSize: 21, weight: .regular)) }
        icon.isHidden = image == nil
        let letter: Bool = { if case .character = key { return title.count == 1 }; return false }()
        label.font = .systemFont(ofSize: letter ? (title == title.lowercased() ? 25 : 23) : 16)
        accessibilityLabel = title
        updateColor()
    }

    private func updateColor() {
        let base = actionReturn ? UIColor.systemBlue : activeShift ? UIColor.white : special ? palette.special : palette.key
        cap.backgroundColor = pressed ? (special ? palette.key : palette.special) : base
        let text = actionReturn ? UIColor.white : activeShift ? UIColor.black : palette.text
        label.textColor = text
        icon.tintColor = text
        cap.layer.shadowColor = UIColor.black.cgColor
    }

    override func accessibilityActivate() -> Bool {
        guard available else { return false }
        activate?(); return true
    }
}

/// Popovers live inside the extension's bounds; no private keyboard views are used.
final class KeyboardPopover: UIView {
    private var labels: [UILabel] = []
    private let shape = CAShapeLayer()
    private var palette = KeyboardPalette(dark: false)
    private(set) var values: [String] = []
    private(set) var selection = 0
    private var anchorX: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.insertSublayer(shape, at: 0)
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 2)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(values: [String], keyFrame: CGRect, in surface: UIView, palette: KeyboardPalette) {
        self.values = values
        self.palette = palette
        selection = 0
        labels.forEach { $0.removeFromSuperview() }
        let cell = min(42, (surface.bounds.width - 12) / CGFloat(max(1, values.count)))
        let width = values.count == 1 ? max(52, keyFrame.width + 22) : cell * CGFloat(values.count) + 8
        let x = max(3, min(surface.bounds.width - width - 3, keyFrame.midX - (values.count == 1 ? width / 2 : cell / 2 + 4)))
        frame = CGRect(x: x, y: keyFrame.minY - 43, width: width, height: 56)
        anchorX = keyFrame.midX - x
        labels = values.map { value in
            let label = UILabel()
            label.text = value
            label.textAlignment = .center
            label.font = .systemFont(ofSize: values.count == 1 ? 34 : 27)
            label.layer.cornerRadius = 5
            label.clipsToBounds = true
            addSubview(label)
            return label
        }
        if values.count > 1 {
            // The original key stays under the finger even when the menu opens leftward.
            selection = max(0, min(values.count - 1, Int((anchorX - 4) / cell)))
            let original = self.values.removeFirst()
            self.values.insert(original, at: selection)
            for (index, label) in labels.enumerated() { label.text = self.values[index] }
        }
        isHidden = false
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let path = UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: bounds.width, height: 43), cornerRadius: 10)
        path.move(to: CGPoint(x: max(8, anchorX - 13), y: 40))
        path.addLine(to: CGPoint(x: anchorX - 9, y: 56))
        path.addLine(to: CGPoint(x: anchorX + 9, y: 56))
        path.addLine(to: CGPoint(x: min(bounds.width - 8, anchorX + 13), y: 40))
        path.close()
        shape.path = path.cgPath
        shape.fillColor = palette.key.cgColor
        layer.shadowPath = path.cgPath
        let cell = (bounds.width - 8) / CGFloat(max(1, labels.count))
        for (index, label) in labels.enumerated() {
            label.frame = CGRect(x: 4 + CGFloat(index) * cell, y: 2, width: cell, height: 39)
            let selected = labels.count > 1 && index == selection
            label.backgroundColor = selected ? .systemBlue : .clear
            label.textColor = selected ? .white : palette.text
        }
    }

    func select(at point: CGPoint) {
        selection = max(0, min(values.count - 1, Int((point.x - frame.minX - 4) / ((bounds.width - 8) / CGFloat(values.count)))))
        setNeedsLayout()
    }
}
