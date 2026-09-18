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

    @Test func storageNamesRemainStableWithLocalizedDisplayTitles() {
        #expect(RecordingDestination.defaultURL(for: .audio).lastPathComponent == "录音")
        #expect(RecordingDestination.defaultURL(for: .video).lastPathComponent == "录屏")
        #expect(RecordingMode.audio.rawValue == "audio")
        #expect(RecordingMode.video.directoryPreferenceKey == "recordingDirectory.video")
    }

    @Test func translatedCatalogsKeepInterpolationArguments() throws {
        var catalogs: [AppLanguage: [String: String]] = [:]
        for language in AppLanguage.allCases {
            let folder = try #require(L10n.bundle(for: language)?.bundleURL)
            let data = try Data(contentsOf: folder.appendingPathComponent("Localizable.strings"))
            catalogs[language] = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        }
        let chinese = try #require(catalogs[.chinese])
        let english = try #require(catalogs[.english])
        #expect(Set(chinese.keys) == Set(english.keys))
        let pattern = try NSRegularExpression(pattern: #"\{[0-9]+\}|%[0-9.]*[dfs@]"#)
        func arguments(_ text: String) -> Set<String> {
            let source = text as NSString
            return Set(pattern.matches(in: text, range: NSRange(location: 0, length: source.length))
                .map { source.substring(with: $0.range) })
        }
        for (key, value) in english {
            #expect(!value.isEmpty)
            #expect(arguments(key) == arguments(value), "Translation must preserve arguments: \(key)")
        }
    }
}
