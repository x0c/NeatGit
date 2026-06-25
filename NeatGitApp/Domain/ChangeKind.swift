import Foundation

enum ChangeKind: Sendable {
    case sourceCode
    case testCode
    case configuration
    case documentation
    case resource
    case other

    var label: String {
        switch self {
        case .sourceCode:
            return "代码"
        case .testCode:
            return "测试"
        case .configuration:
            return "配置"
        case .documentation:
            return "文档"
        case .resource:
            return "资源"
        case .other:
            return "其他"
        }
    }

    var analysisWeight: Int {
        switch self {
        case .sourceCode:
            return 48
        case .testCode:
            return -22
        case .configuration:
            return 18
        case .documentation:
            return -36
        case .resource:
            return -18
        case .other:
            return 0
        }
    }

    var detailWeight: Int {
        switch self {
        case .sourceCode:
            return 40
        case .testCode:
            return -18
        case .configuration:
            return 14
        case .documentation:
            return -32
        case .resource:
            return -14
        case .other:
            return 0
        }
    }

    static func classify(for path: String) -> ChangeKind {
        let fileURL = URL(fileURLWithPath: path)
        let normalizedPath = path.lowercased()
        let fileName = fileURL.lastPathComponent.lowercased()
        let fileExtension = fileURL.pathExtension.lowercased()

        if isTestLikePath(normalizedPath, fileName: fileName) {
            return .testCode
        }

        if [
            "swift", "m", "mm", "h", "c", "cc", "cpp", "cxx",
            "js", "jsx", "ts", "tsx",
            "py", "rb", "php", "java", "kt", "kts",
            "go", "rs", "scala", "sql", "sh", "zsh", "bash"
        ].contains(fileExtension) {
            return .sourceCode
        }

        if ["md", "markdown", "rst", "adoc", "txt"].contains(fileExtension) {
            return .documentation
        }

        if [
            "json", "yml", "yaml", "toml", "plist", "xcconfig",
            "pbxproj", "xcscheme", "entitlements", "strings"
        ].contains(fileExtension) || fileName == "project.yml" {
            return .configuration
        }

        if [
            "png", "jpg", "jpeg", "gif", "svg", "pdf",
            "ttf", "otf", "html", "css"
        ].contains(fileExtension) || normalizedPath.contains("/resources/") || normalizedPath.contains("/assets/") {
            return .resource
        }

        return .other
    }

    private static func isTestLikePath(_ normalizedPath: String, fileName: String) -> Bool {
        if normalizedPath.contains("/tests/") || normalizedPath.contains("/test/") || normalizedPath.contains("/spec/") || normalizedPath.contains("/__tests__/") {
            return true
        }

        let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent.lowercased()
        return stem.hasSuffix("tests") || stem.hasSuffix("test") || stem.hasSuffix("spec")
    }
}
