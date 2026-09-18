import Foundation
import Testing
@testable import Scriber

struct LocalizationTests {
    @Test(arguments: ["en", "en-US", "en-GB", "en-CN", "en_001", "EN_us"])
    func englishPrimaryLanguage(tag: String) {
        #expect(AppLanguage.resolve([tag, "zh-Hans"]) == .english)
    }

    @Test(arguments: [[], ["zh-Hans-CN"], ["zh-Hant-TW"], ["fr-FR", "en-US"], ["de"], ["enough"], [""]])
    func chineseDefault(languages: [String]) {
        #expect(AppLanguage.resolve(languages) == .chinese)
    }

    @Test func resourcesAndMissingKeys() {
        #expect(L10n.text("录音", language: .english) == "Audio")
        #expect(L10n.text("录音", language: .chinese) == "录音")
        let title = "会议 {1} %@ 🎙️"
        #expect(L10n.text("查看录制：\(title)", language: .english) == "Open recording: \(title)")
        #expect(L10n.text("未收录：\(title)", language: .english) == "未收录：\(title)")
    }

    @Test func reorderedPlaceholdersPreserveUserData() {
        #expect(L10n.render("{1}: {0}; {1}", arguments: ["{1} %@", "会🎙️议"]) == "会🎙️议: {1} %@; 会🎙️议")
        #expect(L10n.render("literal {9}", arguments: []) == "literal {9}")
    }
}
