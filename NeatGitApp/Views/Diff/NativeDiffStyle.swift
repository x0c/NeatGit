import AppKit

/// 原生差异视图的配色。
///
/// 每个颜色都按当前外观动态解析：浅色 / 深色 / 高对比切换时不需要重建富文本，重新绘制即可。
/// 这些颜色对象创建后不再修改，允许在后台构建富文本时读取。
enum NativeDiffColors {
    private static func dynamic(
        light: NSColor,
        dark: NSColor,
        highContrastLight: NSColor,
        highContrastDark: NSColor
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let isHighContrast = Self.isHighContrast(appearance)
            switch (isDark, isHighContrast) {
            case (false, false): return light
            case (true, false): return dark
            case (false, true): return highContrastLight
            case (true, true): return highContrastDark
            }
        }
    }

    /// 系统是否按高对比外观解析这个外观对象。
    ///
    /// 用名称判断而不是固定的常量：高对比外观的名称随系统版本增加，写死一份清单容易漏。
    private static func isHighContrast(_ appearance: NSAppearance) -> Bool {
        appearance.name.rawValue.localizedCaseInsensitiveContains("HighContrast")
    }

    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    /// 新增行整行底色（绿）。
    static let addedRow = dynamic(
        light: rgb(0.89, 0.98, 0.92),
        dark: rgb(0.16, 0.32, 0.21),
        highContrastLight: rgb(0.72, 0.95, 0.78),
        highContrastDark: rgb(0.08, 0.44, 0.25)
    )
    /// 删除行整行底色（红）。
    static let removedRow = dynamic(
        light: rgb(1.00, 0.93, 0.94),
        dark: rgb(0.36, 0.17, 0.19),
        highContrastLight: rgb(1.00, 0.82, 0.84),
        highContrastDark: rgb(0.58, 0.18, 0.21)
    )
    /// 行内变化区间：在新增行底色上再加深（绿）。
    static let addedInline = dynamic(
        light: rgb(0.66, 0.95, 0.74),
        dark: rgb(0.24, 0.58, 0.35),
        highContrastLight: rgb(0.36, 0.86, 0.50),
        highContrastDark: rgb(0.10, 0.72, 0.38)
    )
    /// 行内变化区间：在删除行底色上再加深（红）。
    static let removedInline = dynamic(
        light: rgb(1.00, 0.76, 0.77),
        dark: rgb(0.68, 0.28, 0.31),
        highContrastLight: rgb(1.00, 0.56, 0.59),
        highContrastDark: rgb(0.88, 0.32, 0.35)
    )
    /// 并排时另一侧没有对应内容的填充行。
    static let fillerRow = dynamic(
        light: rgb(0, 0, 0, alpha: 0.025),
        dark: rgb(1, 1, 1, alpha: 0.03),
        highContrastLight: rgb(0, 0, 0, alpha: 0.07),
        highContrastDark: rgb(1, 1, 1, alpha: 0.09)
    )
    /// 折叠未变更内容的展开行底色。
    static let expanderRow = dynamic(
        light: rgb(0.0, 0.48, 1.0, alpha: 0.10),
        dark: rgb(0.35, 0.62, 1.0, alpha: 0.16),
        highContrastLight: rgb(0.0, 0.48, 1.0, alpha: 0.22),
        highContrastDark: rgb(0.35, 0.62, 1.0, alpha: 0.30)
    )
    static let expanderText = dynamic(
        light: rgb(0.0, 0.33, 0.80),
        dark: rgb(0.55, 0.75, 1.0),
        highContrastLight: rgb(0.0, 0.24, 0.72),
        highContrastDark: rgb(0.78, 0.89, 1.0)
    )
    /// 行号与正文用系统色，浅色 / 深色 / 高对比由系统负责。
    static let lineNumber = NSColor.secondaryLabelColor
    static let text = NSColor.textColor
    /// 彩色行上的选择高亮：系统选择色叠一层，保留整行底色。
    static let selectionOnRow = dynamic(
        light: rgb(0.0, 0.0, 0.0, alpha: 0.12),
        dark: rgb(1.0, 1.0, 1.0, alpha: 0.16),
        highContrastLight: rgb(0.0, 0.0, 0.0, alpha: 0.22),
        highContrastDark: rgb(1.0, 1.0, 1.0, alpha: 0.28)
    )
}

/// 文本视图的字体与几何参数。所有行使用同一个固定行高，左右两栏才能逐行对齐。
struct NativeDiffStyle: @unchecked Sendable {
    let font: NSFont
    let numberFont: NSFont
    /// 固定行高：取等宽字体与中文回退字体中较高的那个，再加一点余量。
    let rowHeight: CGFloat
    /// 等宽字体每个字符的宽度（用于估算内容宽度与选择高亮的位置）。
    let advance: CGFloat
    /// 行号栏宽度。
    let gutterWidth: CGFloat = 64
    /// 内容区上下留白。
    let verticalInset: CGFloat = 8

    static func make() -> NativeDiffStyle {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        // 含中文的字符串实际排版后的高度，才是这一行真正需要的高度。
        let measured = NSAttributedString(string: "中文字形Agjq|", attributes: [.font: font]).size().height
        let fallback = NSFont.systemFont(ofSize: 12).boundingRectForFont.height
        let latin = font.boundingRectForFont.height
        let rowHeight = ceil(max(measured, fallback, latin)) + 1
        let advance = font.maximumAdvancement.width
        return NativeDiffStyle(font: font, numberFont: numberFont, rowHeight: rowHeight, advance: advance)
    }
}
