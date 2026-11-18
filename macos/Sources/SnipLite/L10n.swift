import Foundation

/// The texts of the app. English and Simplified / Traditional Chinese; the language follows
/// the system unless one is picked in Settings.
enum L {
    enum Lang: String, CaseIterable { case system, en, zhHans = "zh-Hans", zhHant = "zh-Hant" }

    static var current: Lang {
        let pick = Lang(rawValue: Prefs.shared.language) ?? .system
        if pick != .system { return pick }
        let pref = Locale.preferredLanguages.first ?? "en"
        if pref.hasPrefix("zh-Hant") || pref.hasPrefix("zh-TW") || pref.hasPrefix("zh-HK") { return .zhHant }
        if pref.hasPrefix("zh") { return .zhHans }
        return .en
    }

    static func t(_ key: String) -> String {
        let table: [String: String]
        switch current {
        case .zhHans: table = zhHans
        case .zhHant: table = zhHant
        default: return en[key] ?? key
        }
        return table[key] ?? en[key] ?? key
    }

    static let en: [String: String] = [
        "capture": "Capture", "pinClipboard": "Pin from clipboard", "togglePins": "Hide / show pins",
        "ocrCapture": "Capture and read text", "ocrCopyCapture": "Capture and copy text",
        "settings": "Settings…", "about": "About sniplite", "quit": "Quit sniplite",
        "rect": "Rectangle", "mosaicRect": "Mosaic: drag a box", "mosaicBrush": "Mosaic: brush", "mosaicFill": "Cover with color", "ellipse": "Ellipse", "line": "Line", "arrow": "Arrow", "pen": "Pen",
        "marker": "Marker", "mosaic": "Mosaic (wheel: size)", "text": "Text", "number": "Number",
        "undo": "Undo (⌘Z)", "redo": "Redo (⇧⌘Z)", "pin": "Pin to screen (⌘T)", "save": "Save (⌘S)",
        "close": "Cancel (Esc)", "ok": "Copy (Enter)", "ocr": "Read text (⌘O)", "ocrCopy": "Copy text (⇧⌘C)",
        "copy": "Copy", "close.pin": "Close", "closeAll": "Close all pins", "onTop": "Always on top",
        "readText": "Read text", "copied": "Copied", "textCopied": "Text copied", "noText": "No text found",
        "permTitle": "sniplite needs Screen Recording permission",
        "permBody": "Drag sniplite into the list that opens in System Settings and turn it on, then quit and reopen sniplite.",
        "openSettings": "Open System Settings", "later": "Later",
        "hotkeys": "Shortcuts", "general": "General", "language": "Language", "langSystem": "Same as system",
        "launchAtLogin": "Open at login", "pinTop": "Pins stay on top",
        "recordHint": "Click, then press keys", "none": "None", "clear": "Clear",
        "langRestart": "The new language is used from the next capture; restart for the menu.",
        "hkConflict": "This shortcut could not be registered; another app may be using it.",
        "copyColor": "C: copy color", "ocrTitle": "Text", "copyAll": "Copy all", "copyMarkdown": "Copy as Markdown",
        "reading": "Reading text…", "ocrEnable": "Text recognition (F4 / ⇧F4, buttons on the toolbar)",
        "permissions": "Permissions", "manage": "Manage…", "permStatus": "Status", "permAllOK": "All allowed", "permMissing": "%d missing", "ocrTitle2": "Text recognition", "ocrDetail": "F4 / ⇧F4 and the toolbar buttons; runs on this Mac.", "screenRecording": "Screen Recording", "granted": "Allowed", "grant": "Allow…",
        "accessibility": "Accessibility", "deviceControl": "Device Control and Data Access",
        "whyScreen": "Lets sniplite read the screen; capturing needs it.", "whyAX": "Makes the F1–F12 shortcuts work, and picks buttons and fields inside windows.",
        "notGranted": "Not allowed", "optional": "Optional", "openPane": "Allow…",
        "permIntro": "sniplite needs these permissions. Click a button: System Settings opens with sniplite's icon below it; drag the icon into the list and turn it on.",
        "permDrag": "After “Allow…”, drag the sniplite icon under System Settings into the list and turn it on.",
        "permTitle2": "Welcome to sniplite", "permSubtitle": "Allow the permissions below once, and press F1 to capture.",
        "required": "Required", "done": "Done",
        "permDone": "All set.", "permRestart": "All set. Restarting sniplite to use Screen Recording…",
        "dragTitle": "Drag into the list above, then turn it on", "dragBig": "Drag sniplite into the list", "step1": "Hold this row", "stepUp": "Drag to the list above", "stepLeft": "Drag to the list on the left", "stepRight": "Drag to the list on the right", "step3": "Turn it on", "dragTitleLeft": "Drag into the list on the left, then turn it on", "dragTitleRight": "Drag into the list on the right, then turn it on",
    ]

    static let zhHans: [String: String] = [
        "capture": "截图", "pinClipboard": "贴图（剪贴板）", "togglePins": "隐藏 / 显示贴图",
        "ocrCapture": "截图并识别文字", "ocrCopyCapture": "截图并复制文字",
        "settings": "设置…", "about": "关于 sniplite", "quit": "退出 sniplite",
        "rect": "矩形", "mosaicRect": "马赛克：框选", "mosaicBrush": "马赛克：画笔", "mosaicFill": "色块遮挡", "ellipse": "椭圆", "line": "直线", "arrow": "箭头", "pen": "画笔",
        "marker": "记号笔", "mosaic": "马赛克（滚轮调大小）", "text": "文字", "number": "序号",
        "undo": "撤销 (⌘Z)", "redo": "重做 (⇧⌘Z)", "pin": "贴到屏幕 (⌘T)", "save": "保存 (⌘S)",
        "close": "取消 (Esc)", "ok": "复制 (Enter)", "ocr": "识别文字 (⌘O)", "ocrCopy": "复制文字 (⇧⌘C)",
        "copy": "复制", "close.pin": "关闭", "closeAll": "关闭所有贴图", "onTop": "置顶",
        "readText": "识别文字", "copied": "已复制", "textCopied": "文字已复制", "noText": "没有识别到文字",
        "permTitle": "sniplite 需要“屏幕录制”权限",
        "permBody": "把 sniplite 拖进系统设置里打开的列表并打开开关，然后退出并重新打开 sniplite。",
        "openSettings": "打开系统设置", "later": "稍后",
        "hotkeys": "快捷键", "general": "通用", "language": "语言", "langSystem": "跟随系统",
        "launchAtLogin": "登录时打开", "pinTop": "贴图置顶",
        "recordHint": "点击后按下按键", "none": "无", "clear": "清除",
        "langRestart": "新语言从下次截图开始生效；菜单需重启后更新。",
        "hkConflict": "无法注册这个快捷键，可能已被其他应用占用。",
        "copyColor": "C：复制颜色", "ocrTitle": "文字", "copyAll": "全部复制", "copyMarkdown": "复制为 Markdown",
        "reading": "正在识别文字…", "ocrEnable": "文字识别（F4 / ⇧F4，以及工具栏按钮）",
        "permissions": "权限", "manage": "管理…", "permStatus": "授权状态", "permAllOK": "全部已允许", "permMissing": "缺少 %d 项", "ocrTitle2": "文字识别", "ocrDetail": "F4 / ⇧F4 和工具栏按钮，在本机运行。", "screenRecording": "屏幕录制", "granted": "已允许", "grant": "去授权…",
        "accessibility": "辅助功能", "deviceControl": "设备控制和数据访问",
        "whyScreen": "用来读取屏幕画面，截图离不开它。", "whyAX": "让 F1–F12 快捷键生效，并识别窗口里的按钮、输入框等元素。",
        "notGranted": "未允许", "optional": "可选", "openPane": "去开启…",
        "permIntro": "sniplite 需要下面这些权限。点按钮会打开系统设置，下方出现 sniplite 图标，把图标拖进列表并打开开关即可。",
        "permDrag": "点“去开启”后，把系统设置下方的 sniplite 图标拖进列表，再打开开关。",
        "permTitle2": "欢迎使用 sniplite", "permSubtitle": "授予下面的权限后，按 F1 即可截图。只需设置一次。",
        "required": "必需", "done": "完成",
        "permDone": "全部完成。", "permRestart": "全部完成，sniplite 将重新启动以启用屏幕录制。",
        "dragTitle": "拖到上方列表，再打开开关", "dragBig": "把 sniplite 拖进列表", "step1": "按住下面这一行", "stepUp": "拖到上方列表", "stepLeft": "拖到左侧列表", "stepRight": "拖到右侧列表", "step3": "打开开关", "dragTitleLeft": "拖到左侧列表，再打开开关", "dragTitleRight": "拖到右侧列表，再打开开关",
    ]

    static let zhHant: [String: String] = [
        "capture": "截圖", "pinClipboard": "貼圖（剪貼簿）", "togglePins": "隱藏 / 顯示貼圖",
        "ocrCapture": "截圖並辨識文字", "ocrCopyCapture": "截圖並複製文字",
        "settings": "設定…", "about": "關於 sniplite", "quit": "結束 sniplite",
        "rect": "矩形", "mosaicRect": "馬賽克：框選", "mosaicBrush": "馬賽克：畫筆", "mosaicFill": "色塊遮擋", "ellipse": "橢圓", "line": "直線", "arrow": "箭頭", "pen": "畫筆",
        "marker": "螢光筆", "mosaic": "馬賽克（滾輪調大小）", "text": "文字", "number": "序號",
        "undo": "復原 (⌘Z)", "redo": "重做 (⇧⌘Z)", "pin": "貼到螢幕 (⌘T)", "save": "儲存 (⌘S)",
        "close": "取消 (Esc)", "ok": "複製 (Enter)", "ocr": "辨識文字 (⌘O)", "ocrCopy": "複製文字 (⇧⌘C)",
        "copy": "複製", "close.pin": "關閉", "closeAll": "關閉所有貼圖", "onTop": "置頂",
        "readText": "辨識文字", "copied": "已複製", "textCopied": "文字已複製", "noText": "沒有辨識到文字",
        "permTitle": "sniplite 需要「螢幕錄製」權限",
        "permBody": "把 sniplite 拖進系統設定裡打開的列表並打開開關，然後結束並重新打開 sniplite。",
        "openSettings": "打開系統設定", "later": "稍後",
        "hotkeys": "快速鍵", "general": "一般", "language": "語言", "langSystem": "跟隨系統",
        "launchAtLogin": "登入時打開", "pinTop": "貼圖置頂",
        "recordHint": "點一下再按下按鍵", "none": "無", "clear": "清除",
        "langRestart": "新語言從下次截圖開始生效；選單需重新啟動後更新。",
        "hkConflict": "無法註冊這個快速鍵，可能已被其他 App 佔用。",
        "copyColor": "C：複製顏色", "ocrTitle": "文字", "copyAll": "全部複製", "copyMarkdown": "複製為 Markdown",
        "reading": "正在辨識文字…", "ocrEnable": "文字辨識（F4 / ⇧F4，以及工具列按鈕）",
        "permissions": "權限", "manage": "管理…", "permStatus": "授權狀態", "permAllOK": "全部已允許", "permMissing": "缺少 %d 項", "ocrTitle2": "文字辨識", "ocrDetail": "F4 / ⇧F4 和工具列按鈕，在本機執行。", "screenRecording": "螢幕錄製", "granted": "已允許", "grant": "去授權…",
        "accessibility": "輔助使用", "deviceControl": "裝置控制和資料取用",
        "whyScreen": "截圖一定要有。", "whyAX": "讓 F1–F12 快速鍵生效，並辨識視窗裡的按鈕、輸入框等元素。",
        "notGranted": "未允許", "optional": "可選", "openPane": "去開啟…",
        "permIntro": "sniplite 需要下面這些權限。點按鈕會打開系統設定，下方出現 sniplite 圖示，把圖示拖進列表並打開開關即可。",
        "permDrag": "點「去開啟」後，把系統設定下方的 sniplite 圖示拖進列表，再打開開關。",
        "permTitle2": "歡迎使用 sniplite", "permSubtitle": "授予下面的權限後，按 F1 即可截圖。只需設定一次。",
        "required": "必需", "done": "完成",
        "permDone": "全部完成。", "permRestart": "全部完成，正在重新啟動 sniplite 以啟用螢幕錄製…",
        "dragTitle": "拖到上方列表，再打開開關", "dragBig": "把 sniplite 拖進列表", "step1": "按住下面這一行", "stepUp": "拖到上方列表", "stepLeft": "拖到左側列表", "stepRight": "拖到右側列表", "step3": "打開開關", "dragTitleLeft": "拖到左側列表，再打開開關", "dragTitleRight": "拖到右側列表，再打開開關",
    ]
}
