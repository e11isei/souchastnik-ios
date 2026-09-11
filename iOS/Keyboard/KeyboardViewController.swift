import UIKit

final class KeyboardViewController: UIInputViewController {
    private enum Page { case letters, numbers, symbols }
    private var language = KeyboardLanguage.russian
    private var shift = ShiftState.once
    private var page = Page.letters
    private var heldShift: ShiftState?
    private var lastShift = Date.distantPast
    private var lastSpace = Date.distantPast
    private var document: UUID?
    private var correction: (original: String, inserted: String)?
    private let surface = KeyboardSurface()
    private let toolbar = UIView()
    private let suggestions = UIStackView()
    private let analysisButton = UIButton(type: .system)
    private let languageButton = UIButton(type: .system)
    private let numericGlobe = UIButton(type: .system)
    private let status = UILabel()
    private var showingStatus = false
    private var height: NSLayoutConstraint?
    private let checker = UITextChecker()
    private var personalWords = Set<String>()
    private var acceptedWords = Set<String>()
    private var shortcuts: [String: String] = [:]
    private var suggestionWork: DispatchWorkItem?
    private var pack: DictionaryPack?
    private var triggerIndex: TriggerIndex?
    private var packError: String?
    private var enabled = true
    private var markings = true
    private var pendingAnalysis: DispatchWorkItem?
    private var defaults: UserDefaults { hasFullAccess ? SharedStore.preferences : .standard }
    private var palette: KeyboardPalette {
        KeyboardPalette(dark: textDocumentProxy.keyboardAppearance == .dark ||
                        (textDocumentProxy.keyboardAppearance != .light && traitCollection.userInterfaceStyle == .dark))
    }
    private var spellingLanguage: String { language == .russian ? "ru_RU" : "en_US" }
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private var numericField: Bool { [.numberPad, .decimalPad, .phonePad, .asciiCapableNumberPad].contains(textDocumentProxy.keyboardType ?? .default) }
    private var numeric: Bool { numericField && page == .letters }
    private var prose: Bool {
        ![.emailAddress, .URL, .numberPad, .decimalPad, .phonePad, .asciiCapableNumberPad].contains(textDocumentProxy.keyboardType ?? .default)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.clipsToBounds = true
        view.addSubview(toolbar)
        view.addSubview(surface)
        toolbar.addSubview(suggestions)
        toolbar.addSubview(analysisButton)
        toolbar.addSubview(languageButton)
        toolbar.addSubview(status)
        toolbar.addSubview(numericGlobe)
        numericGlobe.setImage(UIImage(systemName: "globe"), for: .normal)
        numericGlobe.accessibilityLabel = "Следующая клавиатура"
        numericGlobe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        suggestions.axis = .horizontal
        suggestions.distribution = .fillEqually
        suggestions.spacing = 1
        for index in 0..<3 {
            let button = UIButton(type: .system)
            button.titleLabel?.font = .systemFont(ofSize: 16)
            button.titleLabel?.adjustsFontSizeToFitWidth = true
            button.titleLabel?.minimumScaleFactor = 0.7
            button.accessibilityIdentifier = "keyboard.suggestion.\(index)"
            button.addTarget(self, action: #selector(acceptSuggestion(_:)), for: .touchUpInside)
            suggestions.addArrangedSubview(button)
        }
        analysisButton.setImage(UIImage(systemName: "checkmark.shield"), for: .normal)
        analysisButton.accessibilityIdentifier = "keyboard.analysis"
        analysisButton.addTarget(self, action: #selector(toggleStatus), for: .touchUpInside)
        analysisButton.menu = UIMenu(children: [UIAction(title: "Включить / выключить проверки", image: UIImage(systemName: "power")) { [weak self] _ in
            guard let self else { return }
            self.enabled.toggle()
            self.defaults.set(self.enabled, forKey: "analysisEnabled")
            self.analyze()
        }])
        languageButton.showsMenuAsPrimaryAction = true
        languageButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .medium)
        languageButton.accessibilityLabel = "Язык клавиатуры"
        languageButton.accessibilityIdentifier = "keyboard.language"
        status.font = .systemFont(ofSize: 12)
        status.numberOfLines = 2
        status.isHidden = true
        status.accessibilityIdentifier = "keyboard.status"
        surface.globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        surface.event = { [weak self] in self?.handle($0) }
        surface.alternatives = { [weak self] value in
            guard let self else { return [] }
            return KeyboardTyping.alternatives(for: self.display(value), language: self.language)
        }
        surface.configureKey = { [weak self] in self?.configure($0) }
        height = view.heightAnchor.constraint(equalToConstant: 260)
        height?.priority = .defaultHigh
        height?.isActive = true
        refreshSettings()
        refreshKeys()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: KeyboardViewController, _: UITraitCollection) in
            self.refreshKeys()
        }
        requestSupplementaryLexicon { [weak self] lexicon in
            self?.personalWords = Set(lexicon.entries.flatMap { [$0.userInput.lowercased(), $0.documentText.lowercased()] })
            for entry in lexicon.entries where entry.userInput != entry.documentText {
                self?.shortcuts[entry.userInput] = entry.documentText
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshSettings()
        synchronizeContext()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        surface.cancelTracking()
        pendingAnalysis?.cancel()
        suggestionWork?.cancel()
        pack = nil; triggerIndex = nil; status.text = nil
        correction = nil; lastSpace = .distantPast; heldShift = nil
        acceptedWords.removeAll()
        suggestions.arrangedSubviews.compactMap { $0 as? UIButton }.forEach { $0.setTitle(nil, for: .normal) }
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        synchronizeContext()
    }
    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        correction = nil
        lastSpace = .distantPast
        synchronizeContext()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        surface.cancelTracking()
        super.viewWillTransition(to: size, with: coordinator)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let landscape = view.window?.windowScene?.interfaceOrientation.isLandscape ?? false
        let contentHeight: CGFloat = isPad ? (landscape ? 300 : 310) : (landscape ? 206 : 260)
        let bottom = view.safeAreaInsets.bottom
        if height?.constant != contentHeight + bottom { height?.constant = contentHeight + bottom }
        let side = max(view.safeAreaInsets.left, view.safeAreaInsets.right, isPad ? 7 : 0)
        toolbar.frame = CGRect(x: side, y: 0, width: view.bounds.width - 2 * side, height: 44)
        analysisButton.frame = CGRect(x: 0, y: 0, width: 36, height: 44)
        languageButton.frame = CGRect(x: toolbar.bounds.width - 40, y: 0, width: 40, height: 44)
        suggestions.frame = CGRect(x: 36, y: 4, width: max(0, toolbar.bounds.width - 76), height: 36)
        numericGlobe.frame = CGRect(x: toolbar.bounds.midX - 22, y: 0, width: 44, height: 44)
        status.frame = suggestions.frame.insetBy(dx: 5, dy: 0)
        surface.frame = CGRect(x: side, y: 44, width: view.bounds.width - 2 * side,
                               height: max(0, view.bounds.height - bottom - 44))
    }

    private func synchronizeContext() {
        if document != textDocumentProxy.documentIdentifier {
            surface.cancelTracking()
            document = textDocumentProxy.documentIdentifier
            page = .letters; shift = .off; correction = nil; lastSpace = .distantPast
            acceptedWords.removeAll()
        }
        updateShift()
        refreshKeys()
        updateSuggestions()
        analyze()
    }

    private func refreshSettings() {
        enabled = defaults.object(forKey: "analysisEnabled") as? Bool ?? true
        markings = defaults.object(forKey: "markingsEnabled") as? Bool ?? true
        language = KeyboardLanguage(rawValue: defaults.string(forKey: "keyboardLanguage") ?? "") ?? .russian
        pack = nil; triggerIndex = nil; packError = nil
        if hasFullAccess {
            do { pack = try SharedStore.loadPack(); triggerIndex = pack.map(TriggerIndex.init) }
            catch { packError = "Не удалось прочитать словари. Откройте приложение." }
        }
    }

    private func display(_ value: String) -> String { page == .letters && shift.uppercase ? value.uppercased() : value }

    private func refreshKeys() {
        view.backgroundColor = palette.background
        surface.palette = palette
        surface.setRows(makeRows())
        numericGlobe.isHidden = !numeric || !needsInputModeSwitchKey || showingStatus
        numericGlobe.tintColor = palette.text
        languageButton.setTitle(language == .russian ? "RU⌄" : "EN⌄", for: .normal)
        languageButton.setTitleColor(palette.secondary, for: .normal)
        languageButton.menu = UIMenu(children: KeyboardLanguage.allCases.map { item in
            UIAction(title: item.title, state: language == item ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.surface.cancelTracking()
                self.language = item; self.page = .letters
                self.correction = nil; self.lastSpace = .distantPast
                self.defaults.set(item.rawValue, forKey: "keyboardLanguage")
                self.primaryLanguage = item == .russian ? "ru-RU" : "en-US"
                self.updateShift(); self.refreshKeys(); self.updateSuggestions()
            }
        })
        for button in suggestions.arrangedSubviews.compactMap({ $0 as? UIButton }) { button.setTitleColor(palette.text, for: .normal) }
        status.textColor = palette.secondary
    }

    private func makeRows() -> [KeyboardRow] {
        func characters(_ value: String) -> [KeyboardKeySpec] { value.map { KeyboardKeySpec(key: .character(String($0))) } }
        if numeric {
            return [KeyboardRow(keys: characters("123")), KeyboardRow(keys: characters("456")), KeyboardRow(keys: characters("789")),
                    KeyboardRow(keys: [KeyboardKeySpec(key: textDocumentProxy.keyboardType == .decimalPad ? .character(Locale.current.decimalSeparator ?? ".") : .numbers),
                                       KeyboardKeySpec(key: .character("0")), KeyboardKeySpec(key: .delete)])]
        }
        var result: [KeyboardRow]
        switch page {
        case .letters:
            let text = language.rows
            let side: CGFloat = language == .english ? 1.16 : 1
            let gap = language == .english ? [KeyboardKeySpec(key: .spacer, weight: 0.34)] : []
            result = [KeyboardRow(keys: characters(text[0])),
                      KeyboardRow(keys: characters(text[1]), inset: language == .english ? 0.5 : 0),
                      KeyboardRow(keys: [KeyboardKeySpec(key: .shift, weight: side)] + gap + characters(text[2]) + gap + [KeyboardKeySpec(key: .delete, weight: side)])]
        case .numbers, .symbols:
            let rows = page == .numbers ? ["1234567890", language == .russian ? "-/:;()₽&@\"" : "-/:;()$&@\"", ".,?!'"]
                : ["[]{}#%^*+=", "_\\|~<>€£¥•", ".,?!'"]
            result = [KeyboardRow(keys: characters(rows[0])), KeyboardRow(keys: characters(rows[1])),
                      KeyboardRow(keys: [KeyboardKeySpec(key: .symbols, weight: 1.5)] + characters(rows[2]).map { KeyboardKeySpec(key: $0.key, weight: 1.4) } + [KeyboardKeySpec(key: .delete, weight: 1.5)])]
        }
        var bottom = [KeyboardKeySpec(key: .numbers, weight: 1.2)]
        if needsInputModeSwitchKey { bottom.append(KeyboardKeySpec(key: .globe, weight: 1)) }
        if textDocumentProxy.keyboardType == .emailAddress { bottom.append(KeyboardKeySpec(key: .character("@"))) }
        if textDocumentProxy.keyboardType == .URL { bottom.append(KeyboardKeySpec(key: .character("/"))) }
        let punctuation = textDocumentProxy.keyboardType == .emailAddress || textDocumentProxy.keyboardType == .URL
        bottom.append(KeyboardKeySpec(key: .space, weight: (needsInputModeSwitchKey ? 5.6 : 6.6) - (punctuation ? 2 : 0) - (isPad ? 1 : 0)))
        if punctuation { bottom.append(KeyboardKeySpec(key: .character("."))) }
        bottom.append(KeyboardKeySpec(key: .enter, weight: 2.2))
        if isPad { bottom.append(KeyboardKeySpec(key: .dismiss)) }
        result.append(KeyboardRow(keys: bottom))
        return result
    }

    private func configure(_ key: KeyboardKeyView) {
        key.available = key.key != .enter || textDocumentProxy.enablesReturnKeyAutomatically != true || textDocumentProxy.hasText
        var title = "", image: String?
        var special = true
        switch key.key {
        case .character(let value): title = display(value); special = false
        case .shift: title = "Shift"; image = shift == .locked ? "capslock.fill" : shift.uppercase ? "shift.fill" : "shift"
        case .delete: title = "Удалить"; image = "delete.left"
        case .numbers:
            title = numericField ? (numeric ? "#+=" : "123") : page == .letters ? "123" : language == .russian ? "АБВ" : "ABC"
        case .symbols: title = page == .symbols ? "123" : "#+="
        case .space: title = language == .russian ? "пробел" : "space"; special = false
        case .enter: title = returnTitle
        case .globe, .spacer: break
        case .dismiss: title = "Скрыть клавиатуру"; image = "keyboard.chevron.compact.down"
        }
        key.configure(title: title, image: image, palette: palette, special: special,
                      activeShift: key.key == .shift && shift.uppercase, actionReturn: key.key == .enter && actionReturn)
        if key.key == .shift { key.accessibilityValue = shift == .locked ? "Caps Lock" : shift.uppercase ? "Включён" : "Выключен" }
        if key.key == .space { key.accessibilityHint = "Удерживайте, затем двигайте палец для перемещения курсора" }
        if case .character(let value) = key.key {
            let variants = KeyboardTyping.alternatives(for: display(value), language: language)
            key.accessibilityHint = variants.isEmpty ? nil : "Удерживайте: " + variants.joined(separator: ", ")
            key.accessibilityCustomActions = variants.dropFirst().map { variant in
                UIAccessibilityCustomAction(name: variant) { [weak self] _ in self?.insert(variant); return true }
            }
        }
    }

    private var actionReturn: Bool { ![UIReturnKeyType.default, .next].contains(textDocumentProxy.returnKeyType ?? .default) }
    private var returnTitle: String {
        let ru = language == .russian
        switch textDocumentProxy.returnKeyType {
        case .send: return ru ? "отправить" : "send"
        case .search, .google, .yahoo: return ru ? "поиск" : "search"
        case .go: return ru ? "перейти" : "go"
        case .done: return ru ? "готово" : "done"
        case .next: return ru ? "далее" : "next"
        case .join: return ru ? "подключить" : "join"
        case .route: return ru ? "маршрут" : "route"
        case .continue: return ru ? "продолжить" : "continue"
        default: return ru ? "ввод" : "return"
        }
    }

    private func handle(_ event: KeyboardEvent) {
        switch event {
        case .shiftBegan:
            heldShift = shift
            if Date().timeIntervalSince(lastShift) < 0.33 && shift != .locked { shift = .locked }
            else { shift = shift == .off ? .once : .off }
            refreshKeys()
        case .shiftEnded(let used):
            if used { shift = heldShift == .locked ? .locked : .off; lastShift = .distantPast }
            else { lastShift = Date() }
            heldShift = nil
            refreshKeys()
        case .cursor(let steps):
            correction = nil; lastSpace = .distantPast
            textDocumentProxy.adjustTextPosition(byCharacterOffset: steps)
        case .deleteWord: delete(word: true)
        case .restoreLetters: page = .letters; updateShift(); refreshKeys()
        case .press(let key):
            switch key {
            case .character(let value): insert(display(value))
            case .space: insert(" ")
            case .enter:
                if textDocumentProxy.enablesReturnKeyAutomatically != true || textDocumentProxy.hasText { insert("\n") }
            case .delete: delete(word: false)
            case .numbers: page = page == .letters ? .numbers : .letters; refreshKeys()
            case .symbols: page = page == .symbols ? .numbers : .symbols; refreshKeys()
            case .dismiss: dismissKeyboard()
            case .globe: advanceToNextInputMode()
            case .shift, .spacer: break
            }
        }
    }

    private func updateShift() {
        guard shift != .locked, heldShift == nil else { return }
        let mode: KeyboardTyping.Capitalization
        switch textDocumentProxy.autocapitalizationType ?? (prose ? .sentences : .none) {
        case .none: mode = .none
        case .words: mode = .words
        case .allCharacters: mode = .allCharacters
        default: mode = prose ? .sentences : .none
        }
        shift = KeyboardTyping.capitalize(before: textDocumentProxy.documentContextBeforeInput, mode: mode) ? .once : .off
    }

    private func insert(_ text: String) {
        let proxy = textDocumentProxy
        let before = proxy.documentContextBeforeInput ?? ""
        let selection = proxy.selectedText?.isEmpty == false
        correction = nil
        if prose && text == " " && KeyboardTyping.canInsertPeriod(before: before, elapsed: Date().timeIntervalSince(lastSpace), hasSelection: selection) {
            proxy.deleteBackward(); proxy.insertText(". "); lastSpace = .distantPast
        } else {
            var replacement: (String, String)?
            if text == " ", !selection, let suggestion = automaticCorrection(before: before) {
                let word = KeyboardTyping.currentWord(before: before)
                for _ in word { proxy.deleteBackward() }
                proxy.insertText(suggestion)
                replacement = (word, suggestion)
            }
            var insertedMarker = false
            if enabled && markings && !selection && (text == " " || text == "\n" || ",.!?;:)".contains(text)),
               let marker = pack?.marker(before: proxy.documentContextBeforeInput ?? "") {
                proxy.insertText(" (\(marker))"); insertedMarker = true
            }
            proxy.insertText(text)
            if let replacement, !insertedMarker { correction = (replacement.0, replacement.1 + text) }
            lastSpace = text == " " ? Date() : .distantPast
        }
        if text == " " || text == "\n" { page = .letters }
        if heldShift == nil { shift.consumed(); updateShift() }
        refreshKeys(); updateSuggestions(); analyze()
    }

    private func delete(word: Bool) {
        let proxy = textDocumentProxy
        if !word, proxy.selectedText?.isEmpty != false, let correction,
           proxy.documentContextBeforeInput?.hasSuffix(correction.inserted) == true {
            for _ in correction.inserted { proxy.deleteBackward() }
            proxy.insertText(correction.original)
        } else if word, proxy.selectedText?.isEmpty != false, let before = proxy.documentContextBeforeInput {
            for _ in 0..<KeyboardTyping.deletionCount(before: before) { proxy.deleteBackward() }
        } else { proxy.deleteBackward() }
        correction = nil; lastSpace = .distantPast
        updateShift(); refreshKeys(); updateSuggestions(); analyze()
    }

    private func automaticCorrection(before: String) -> String? {
        guard prose, textDocumentProxy.autocorrectionType != .no, shift != .locked else { return nil }
        let word = KeyboardTyping.currentWord(before: before)
        guard !acceptedWords.contains(word.lowercased()) else { return nil }
        if let replacement = shortcuts[word] { return replacement }
        guard word.count >= 3, word.count < 25, word == word.lowercased(), !personalWords.contains(word),
              UITextChecker.availableLanguages.contains(spellingLanguage) else { return nil }
        let range = NSRange(word.startIndex..., in: word)
        guard checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false, language: spellingLanguage).location != NSNotFound else { return nil }
        guard let guess = checker.guesses(forWordRange: range, in: word, language: spellingLanguage)?.first,
              !guess.contains(" "), KeyboardTyping.isNearbyCorrection(word, guess) else { return nil }
        return guess
    }

    private func updateSuggestions() {
        suggestionWork?.cancel()
        let word = KeyboardTyping.currentWord(before: textDocumentProxy.documentContextBeforeInput ?? "")
        guard prose, textDocumentProxy.autocorrectionType != .no, !word.isEmpty, word.count < 40,
              textDocumentProxy.selectedText?.isEmpty != false else { showSuggestions([]); return }
        showSuggestions([word])
        let document = textDocumentProxy.documentIdentifier
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.textDocumentProxy.documentIdentifier == document,
                  KeyboardTyping.currentWord(before: self.textDocumentProxy.documentContextBeforeInput ?? "") == word,
                  UITextChecker.availableLanguages.contains(self.spellingLanguage) else { return }
            var values = [word]
            if let shortcut = self.shortcuts[word] { values.append(shortcut) }
            let range = NSRange(word.startIndex..., in: word)
            let guesses = self.checker.guesses(forWordRange: range, in: word, language: self.spellingLanguage) ?? []
            let completions = self.checker.completions(forPartialWordRange: range, in: word, language: self.spellingLanguage) ?? []
            for candidate in guesses + completions where !values.contains(candidate) {
                values.append(candidate)
                if values.count == 3 { break }
            }
            self.showSuggestions(values)
        }
        suggestionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.075, execute: work)
    }

    private func showSuggestions(_ values: [String]) {
        let buttons = suggestions.arrangedSubviews.compactMap { $0 as? UIButton }
        for (index, button) in buttons.enumerated() {
            let value = index < values.count ? values[index] : nil
            button.setTitle(value, for: .normal)
            button.accessibilityLabel = value.map { "Вставить \($0)" }
            button.isEnabled = value != nil
        }
    }

    @objc private func acceptSuggestion(_ sender: UIButton) {
        guard let value = sender.currentTitle, textDocumentProxy.selectedText?.isEmpty != false else { return }
        let word = KeyboardTyping.currentWord(before: textDocumentProxy.documentContextBeforeInput ?? "")
        guard !word.isEmpty else { return }
        for _ in word { textDocumentProxy.deleteBackward() }
        textDocumentProxy.insertText(value)
        acceptedWords.insert(value.lowercased())
        insert(" ")
    }

    @objc private func toggleStatus() {
        showingStatus.toggle()
        status.isHidden = !showingStatus
        suggestions.isHidden = showingStatus
        numericGlobe.isHidden = !numeric || !needsInputModeSwitchKey || showingStatus
    }

    private func analyze() {
        pendingAnalysis?.cancel()
        analysisButton.tintColor = palette.secondary
        func show(_ text: String) {
            status.text = text
            analysisButton.accessibilityLabel = text
            analysisButton.accessibilityHint = "Показать подробности. Удерживайте для настройки проверок."
        }
        guard enabled else { show("Словарные проверки выключены"); return }
        guard hasFullAccess else { show("Для словарей включите полный доступ в настройках клавиатуры"); return }
        guard let triggerIndex else { show(packError ?? "Откройте приложение для установки словарей"); return }
        guard textDocumentProxy.documentContextBeforeInput != nil else { show("Поле не предоставляет контекст"); return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let match = triggerIndex.match(String((self.textDocumentProxy.documentContextBeforeInput ?? "").suffix(400)))
            let text = match.codes.isEmpty ? "Совпадений нет · ИИ-разбор в приложении"
                : "Триггеры: \(match.codes.joined(separator: ", ")) · ИИ-разбор в приложении"
            self.status.text = text
            self.analysisButton.accessibilityLabel = text
            self.analysisButton.tintColor = match.codes.isEmpty ? self.palette.secondary : .systemOrange
            self.analysisButton.setImage(UIImage(systemName: match.codes.isEmpty ? "checkmark.shield" : "exclamationmark.shield"), for: .normal)
        }
        pendingAnalysis = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}
