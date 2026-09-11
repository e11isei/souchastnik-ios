import XCTest
@testable import SouchastnikCore

final class KeyboardTypingTests: XCTestCase {
    func testCorrectionAllowsSingleTyposButRejectsUnrelatedWords() {
        XCTAssertTrue(KeyboardTyping.isNearbyCorrection("teh", "the"))
        XCTAssertTrue(KeyboardTyping.isNearbyCorrection("hellp", "hello"))
        XCTAssertTrue(KeyboardTyping.isNearbyCorrection("helo", "hello"))
        XCTAssertTrue(KeyboardTyping.isNearbyCorrection("helllo", "hello"))
        XCTAssertFalse(KeyboardTyping.isNearbyCorrection("world", "hello"))
        XCTAssertFalse(KeyboardTyping.isNearbyCorrection("tihs", "that"))
    }

    func testCapitalizationRespectsFieldTraitsAndSentenceClosers() {
        XCTAssertFalse(KeyboardTyping.capitalize(before: "", mode: .none))
        XCTAssertTrue(KeyboardTyping.capitalize(before: nil, mode: .sentences))
        XCTAssertTrue(KeyboardTyping.capitalize(before: "«Привет!» ", mode: .sentences))
        XCTAssertFalse(KeyboardTyping.capitalize(before: "Привет ", mode: .sentences))
        XCTAssertTrue(KeyboardTyping.capitalize(before: "Привет\n", mode: .sentences))
        XCTAssertTrue(KeyboardTyping.capitalize(before: "hello ", mode: .words))
        XCTAssertFalse(KeyboardTyping.capitalize(before: "hello", mode: .words))
        XCTAssertTrue(KeyboardTyping.capitalize(before: "hello", mode: .allCharacters))
    }

    func testDoubleSpaceDoesNotCorruptPunctuationSelectionsOrIndentation() {
        XCTAssertTrue(KeyboardTyping.canInsertPeriod(before: "Привет ", elapsed: 0.2, hasSelection: false))
        for text in [" ", "  ", "Привет! ", "\n "] {
            XCTAssertFalse(KeyboardTyping.canInsertPeriod(before: text, elapsed: 0.2, hasSelection: false))
        }
        XCTAssertFalse(KeyboardTyping.canInsertPeriod(before: "hello ", elapsed: 1, hasSelection: false))
        XCTAssertFalse(KeyboardTyping.canInsertPeriod(before: "hello ", elapsed: 0.2, hasSelection: true))
    }

    func testWordDeletionUsesGraphemesAndTrailingSpaces() {
        XCTAssertEqual(KeyboardTyping.deletionCount(before: "один два  "), 5)
        XCTAssertEqual(KeyboardTyping.deletionCount(before: "hi 👨‍👩‍👧‍👦"), 1)
        XCTAssertEqual(KeyboardTyping.currentWord(before: "Привет, мир"), "мир")
        XCTAssertEqual(KeyboardTyping.currentWord(before: "don't"), "don't")
        XCTAssertEqual(KeyboardTyping.currentWord(before: "word "), "")
    }

    func testAlternatesKeepCaseAndIncludeRussianMissingLetters() {
        XCTAssertEqual(KeyboardTyping.alternatives(for: "Е", language: .russian), ["Е", "Ё"])
        XCTAssertEqual(KeyboardTyping.alternatives(for: "ь", language: .russian), ["ь", "ъ"])
        XCTAssertTrue(KeyboardTyping.alternatives(for: "e", language: .english).contains("é"))
        XCTAssertEqual(KeyboardTyping.alternatives(for: "q", language: .english), [])
    }
}
