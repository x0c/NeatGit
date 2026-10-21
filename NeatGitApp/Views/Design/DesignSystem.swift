import SwiftUI

/// 全局视觉常量。
///
/// 存在的意义是避免各个 View 里各写各的 padding / 圆角 / 颜色，
/// 导致同一层级的控件尺寸互相对不齐。所有颜色一律走语义色，
/// 不写死 `Color.white`，这样深色模式可以自动跟随系统。
enum Theme {
    /// 间距阶梯，统一按 4pt 栅格取值。
    enum Spacing {
        /// 4pt，紧邻元素之间，例如图标与它的角标。
        static let xxs: CGFloat = 4
        /// 6pt，同一行内图标与文字。
        static let xs: CGFloat = 6
        /// 8pt，行内控件默认间距。
        static let sm: CGFloat = 8
        /// 12pt，分区内部的块间距。
        static let md: CGFloat = 12
        /// 16pt，面板级内边距。
        static let lg: CGFloat = 16
        /// 24pt，空状态等大留白。
        static let xl: CGFloat = 24
    }

    /// 圆角阶梯。小控件用小圆角，容器用大圆角，层级才读得出来。
    enum Radius {
        /// 6pt，列表行等小尺寸元素。
        static let small: CGFloat = 6
        /// 8pt，分组头、按钮。
        static let medium: CGFloat = 8
        /// 10pt，输入框等容器。
        static let large: CGFloat = 10
    }

    /// 行高阶梯，保证列表节奏一致。
    enum RowHeight {
        /// 24pt，文件行这类高密度列表。
        static let compact: CGFloat = 24
        /// 28pt，仓库行。
        static let regular: CGFloat = 28
        /// 32pt，分组标题行。
        static let header: CGFloat = 32
    }

    /// 语义色。全部基于 AppKit 系统色，深浅色模式自动适配。
    enum Palette {
        /// 侧边栏背景，使用系统侧边栏材质对应的底色。
        static let sidebarBackground = Color(nsColor: .controlBackgroundColor)
        /// 主内容区背景。
        static let contentBackground = Color(nsColor: .textBackgroundColor)
        /// 面板顶部工具条背景，比内容区略深一档以压出层次。
        static let barBackground = Color(nsColor: .windowBackgroundColor)
        /// 分组头 / 次级容器的填充。
        static let groupFill = Color(nsColor: .quaternaryLabelColor).opacity(0.5)
        /// 更次一级的容器填充，用于子分组。
        static let subgroupFill = Color(nsColor: .quaternaryLabelColor).opacity(0.28)
        /// 通用描边。
        static let border = Color(nsColor: .separatorColor)
        /// 悬停态背景。
        static let hoverFill = Color(nsColor: .quaternaryLabelColor).opacity(0.35)

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
    enum Font {
        /// 面板标题。
        static let panelTitle = SwiftUI.Font.system(size: 12.5, weight: .semibold)
        /// 列表行主文本。
        static let rowTitle = SwiftUI.Font.system(size: 12.5)
        /// 列表行次要文本（路径等）。
        static let rowSubtitle = SwiftUI.Font.system(size: 11)
        /// 状态角标文字。
        static let badge = SwiftUI.Font.system(size: 9.5, weight: .bold)
        /// 计数数字，等宽避免跳动。
        static let count = SwiftUI.Font.system(size: 10.5, weight: .medium).monospacedDigit()
    }

    /// 统一的展开/折叠动画，保证各列表节奏一致。
    static let disclosureAnimation = Animation.easeInOut(duration: 0.18)
}
