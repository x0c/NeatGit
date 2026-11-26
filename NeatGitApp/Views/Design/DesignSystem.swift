import SwiftUI

/// 全局视觉常量。
///
/// 存在的意义是避免各个 View 里各写各的 padding / 圆角 / 颜色，
/// 导致同一层级的控件尺寸互相对不齐。所有颜色一律走语义色，
/// 不写死 `Color.white`，这样深色模式可以自动跟随系统。
///
/// 材质规则（liquid-glass-practices）：`.regularMaterial` 只用于浮在内容之上的功能层
///（loading 胶囊这类短浮层），正文/输入区保持实底；阴影仅表达前后层级，当前产品无阴影。
enum Theme {
    /// 间距阶梯，统一按 4pt 栅格取值。
    ///
    /// 唯一例外是 `textStack`（行内两行文本的紧凑间距）。
    /// 10 / 13 / 14 / 20 等散落数值一律向本表收敛，不新增台阶。
    enum Spacing {
        /// 2pt，同一行两行文本之间（文件名/路径），仅此一处允许小于 4pt 栅格。
        static let textStack: CGFloat = 2
        /// 6pt，同一行内图标与文字。
        static let xs: CGFloat = 6
    }

    /// 圆角。本产品唯一的常规曲率是 `standard` 8pt。
    /// 卡片、输入框、按钮、菜单、浮层统一引用它（UI_DESIGN_GUIDE「同一界面只允许一种常规曲率」）。
    /// 嵌套必须同心：内圆角 = 外圆角 − 间距，不抄同一个数。
    /// 短控件（loading 胶囊等）直接用 `Capsule` 形状，由半高自然收圆，不写固定圆角数值。
    enum Radius {
        /// 8pt，本产品唯一的常规曲率。
        static let standard: CGFloat = 8
        /// 4pt = standard 8 − 间距 4，同心派生，仅 `GitStatusBadge` 使用，不是第二种曲率。
        static let badge: CGFloat = 4
    }

    /// 语义色。全部基于 AppKit 系统色，深浅色模式自动适配。
    ///
    /// 状态色一律配文字/图标双通道（`badgeText` + 中文 `label` + 删除线），不只靠颜色区分。
    /// 注意 `gitConflicted` 与 `gitDeleted` 同为 systemRed：颜色通道不可区分，
    /// 靠 `!`/`D` 角标与提示文案区分；如需颜色亦可分，须由产品裁定后再改本表。
    /// 新增/修改/未跟踪/星标色与相邻正文的区分度须在深浅色下实机验证（绿/青/黄在暗色选中行上易糊）。
    enum Palette {
        /// Git 新增，绿色。
        static let gitAdded = Color(nsColor: .systemGreen)
        /// Git 修改，橙色。
        static let gitModified = Color(nsColor: .systemOrange)
        /// Git 删除，红色。
        static let gitDeleted = Color(nsColor: .systemRed)
        /// Git 重命名，紫色。
        static let gitRenamed = Color(nsColor: .systemPurple)
        /// Git 未跟踪，蓝灰。
        static let gitUntracked = Color(nsColor: .systemTeal)
        /// Git 冲突，警示红。
        static let gitConflicted = Color(nsColor: .systemRed)
        /// 已忽略 / 不提交，中性灰。
        static let gitInactive = Color(nsColor: .tertiaryLabelColor)
        /// 收藏星标。
        static let starred = Color(nsColor: .systemYellow)
    }

    /// 字体阶梯。桌面端高密度列表统一用固定字号，避免动态字体把行高撑乱。
    ///
    /// 代价是系统「大文字」不会放大这些行：桌面端可接受的取舍，
    /// VoiceOver 朗读与键盘导航不受影响。行内计数一律走 `count`（等宽），不散写 `.monospacedDigit()`。
    enum Font {
        /// 分组标题与行内星标（11pt semibold）。
        static let groupTitle = SwiftUI.Font.system(size: 11, weight: .semibold)
        /// 状态角标文字。
        static let badge = SwiftUI.Font.system(size: 9.5, weight: .bold)
        /// 收藏星标等 8pt 极小图标字形，只做图标辅助，不承载可读正文。
        static let micro = SwiftUI.Font.system(size: 8)
        /// 计数数字，等宽避免跳动。
        static let count = SwiftUI.Font.system(size: 10.5, weight: .medium).monospacedDigit()
    }

    /// 统一的展开/折叠动画，保证各列表节奏一致。
    /// 所有 `DisclosureGroup` / 分组切换的 `withAnimation` 一律引用它，不手写 `0.16` 等时长。
    static let disclosureAnimation = Animation.easeInOut(duration: 0.18)

    /// Reduced Motion 下的展开/折叠：状态仍由 chevron + 内容显隐传达，直接取瞬时值。
    /// 调用方读取 `@Environment(\.accessibilityReduceMotion)` 后传入：
    /// `withAnimation(Theme.disclosureAnimation(reduceMotion: reduceMotion)) { ... }`。
    static func disclosureAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : disclosureAnimation
    }
}
