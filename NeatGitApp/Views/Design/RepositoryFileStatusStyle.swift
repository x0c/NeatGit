import SwiftUI

/// 文件在 Git 里的状态所对应的视觉呈现。
///
/// 把「状态码 -> 颜色 + 角标字符」的映射集中到一处，
/// 避免列表行里散落一堆 if/else 判断颜色。
enum RepositoryFileStatusStyle {
    case added
    case modified
    case deleted
    case renamed
    case untracked
    case conflicted
    case inactive

    /// 角标里显示的单字符，沿用 Git 自身的字母语义（A/M/D/R/U），一眼可认。
    var badgeText: String {
        switch self {
        case .added:
            return "A"
        case .modified:
            return "M"
        case .deleted:
            return "D"
        case .renamed:
            return "R"
        case .untracked:
            return "U"
        case .conflicted:
            return "!"
        case .inactive:
            return "–"
        }
    }

    /// 角标与文件图标的主色。
    var tint: Color {
        switch self {
        case .added:
            return Theme.Palette.gitAdded
        case .modified:
            return Theme.Palette.gitModified
        case .deleted:
            return Theme.Palette.gitDeleted
        case .renamed:
            return Theme.Palette.gitRenamed
        case .untracked:
            return Theme.Palette.gitUntracked
        case .conflicted:
            return Theme.Palette.gitConflicted
        case .inactive:
            return Theme.Palette.gitInactive
        }
    }

    /// 悬停提示里用的中文说明。
    var label: String {
        switch self {
        case .added:
            return "新增"
        case .modified:
            return "修改"
        case .deleted:
            return "删除"
        case .renamed:
            return "重命名"
        case .untracked:
            return "未跟踪"
        case .conflicted:
            return "冲突"
        case .inactive:
            return "不参与提交"
        }
    }
}

extension RepositoryFileItem {
    /// 从 Git 状态码推导视觉样式。
    ///
    /// 判定顺序刻意按「严重程度」排：冲突优先于一切，
    /// 其次是删除/重命名这类结构性变化，最后才落到普通修改。
    var statusStyle: RepositoryFileStatusStyle {
        if hasConflict {
            return .conflicted
        }

        switch section {
        case .skipped, .ignored:
            return .inactive
        case .changed:
            break
        }

        if isUntracked {
            return .untracked
        }

        let codes = [indexStatusCode, workTreeStatusCode]

        if codes.contains("D") {
            return .deleted
        }

        if codes.contains("R") {
            return .renamed
        }

        if codes.contains("A") {
            return .added
        }

        return .modified
    }

    /// 是否存在未暂存的改动。用来在行尾画一个"未暂存"小圆点。
    var showsUnstagedIndicator: Bool {
        guard section == .changed, !isUntracked else { return false }
        return hasUnstagedChanges
    }
}

/// 文件状态角标。固定尺寸的圆角方块 + 单字母，列表里可以竖直对齐成一列。
struct GitStatusBadge: View {
    let style: RepositoryFileStatusStyle

    private enum Layout {
        static let size: CGFloat = 15
    }

    var body: some View {
        Text(style.badgeText)
            .font(Theme.Font.badge)
            .foregroundStyle(style.tint)
            .frame(width: Layout.size, height: Layout.size)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(style.tint.opacity(0.16))
            )
            // 角标三通道：颜色 + 字母 + 中文说明。help 覆盖鼠标悬停，
            // accessibilityLabel 覆盖 VoiceOver（否则只会读出 "M" 这类单字母）。
            .help(style.label)
            .accessibilityLabel(style.label)
    }
}
