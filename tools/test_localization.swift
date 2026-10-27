// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). See LICENSE and NOTICE.
import Foundation

@main struct LocalizationTests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let en = Bundle(path: root.appendingPathComponent("en.lproj").path)!
        let zh = Bundle(path: root.appendingPathComponent("zh-Hans.lproj").path)!
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message); checks += 1; print("PASS: \(message)")
        }
        func english(_ message: LocalizedMessage) -> String { L10n.render(message, language: .english, bundle: en) }
        func chinese(_ message: LocalizedMessage) -> String { L10n.render(message, language: .simplifiedChinese, bundle: zh) }
        check(AppLanguage.resolve(nil) == .simplifiedChinese, "first launch defaults to Simplified Chinese")
        check(AppLanguage.resolve("unsupported") == .simplifiedChinese, "unknown preferences fall back to Chinese")
        check(AppLanguage.allCases.map(\.rawValue) == ["zh-Hans", "en"], "only Simplified Chinese and English are selectable")
        check(AppLanguage.simplifiedChinese.nativeName == "简体中文", "Chinese option names its script correctly")
        check(AppLanguage.resolve("zh-Hant") == .simplifiedChinese, "legacy Traditional Chinese resolves to Simplified Chinese")
        check(chinese("使用已有影片") == "使用已有视频", "video terminology is localized for Simplified Chinese")
        check(chinese("從檔案選擇影片") == "从文件选择视频", "file picker terminology is localized")
        check(AppLanguage.resolve("en") == .english, "saved English preference is respected")
        let tableURL = root.appendingPathComponent("zh-Hans.lproj/Localizable.strings")
        let table = try PropertyListSerialization.propertyList(from: Data(contentsOf: tableURL), format: nil) as! [String: String]
        check(table.values.allSatisfy { $0 == $0.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) },
              "all Chinese resource values are Simplified Chinese")
        check(zh.localizedString(forKey: "NSCameraUsageDescription", value: nil, table: "InfoPlist")
              == "需要使用相机采集 3DGS 训练所需的图像与相机姿态。", "camera permission text is Simplified Chinese")
        check(chinese("掃描紀錄") == "扫描记录", "Simplified Chinese lookup")
        check(english("掃描紀錄") == "Scan history", "English lookup")
        check(english("\(12) 張影像") == "12 images", "dynamic count translates before interpolation")
        check(chinese("\(12) 張影像") == "12 张图像", "Simplified Chinese dynamic count")
        check(english("逐張匹配拍攝影像… \(50)%") == "Matching captured images… 50%", "literal percent survives interpolation")
        let filename = "my%photo中文.jpg"
        check(english("找不到訓練影像：\(filename)") == "Training image not found: " + filename,
              "user filenames remain verbatim and are not interpreted as format strings")
        check(String(format: english("拍攝時間 +%02d:%02d"), 1, 9) == "Capture time +01:09", "printf templates retain numeric argument types")
        check(english("尚未翻譯的備援文字") == "尚未翻譯的備援文字", "unknown key has readable source fallback")
        check(english("\(3) 張拍攝時的運動估計偏高；這不代表照片已模糊，也不單獨要求補拍。")
              .contains("does not confirm blur"), "risk message does not assert blur")
        check(english("\(2) 張視角細節偏弱，建議檢查或補拍（影格 \("7, 9")）。")
              == "2 views have weak detail. Review or recapture them (frames 7, 9).", "weak-detail warning keeps frame IDs")
        let defaults = UserDefaults.standard
        let oldPreference = defaults.object(forKey: AppLanguage.preferenceKey)
        defer {
            if let oldPreference { defaults.set(oldPreference, forKey: AppLanguage.preferenceKey) }
            else { defaults.removeObject(forKey: AppLanguage.preferenceKey) }
        }
        defaults.set("zh-Hant", forKey: AppLanguage.preferenceKey)
        AppLanguage.migratePreference()
        check(defaults.string(forKey: AppLanguage.preferenceKey) == "zh-Hans", "legacy preference migrates to the selectable Simplified Chinese value")
        defaults.set("en", forKey: AppLanguage.preferenceKey)
        AppLanguage.migratePreference()
        check(defaults.string(forKey: AppLanguage.preferenceKey) == "en", "migration preserves an existing English selection")
        check(AppLanguage.current == .english, "runtime reads persisted preference")
        var room = FloorPlanRoom(label: "livingRoom", polygon2D: [], areaM2: 0, labelAt: [0, 0])
        // Custom labels are user content and are never looked up in localization resources.
        room.customLabel = "My room 客廳"
        check(room.displayName == "My room 客廳", "custom room names are preserved")
        defaults.removeObject(forKey: AppLanguage.preferenceKey)
        check(AppLanguage.current == .simplifiedChinese, "removed preference returns to Chinese")
        print("\(checks) localization checks passed")
    }
}
