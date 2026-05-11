import SwiftUI

struct RepositoryPreviewPlaceholder: View {
    let repository: GitRepository?
    let selectedFiles: [RepositoryFileItem]

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)

            Text("右侧预留区暂未开发")
                .font(.title3.weight(.semibold))

            Text(descriptionText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(Color.white)
    }

    private var descriptionText: String {
        if selectedFiles.count == 1, let selectedFile = selectedFiles.first {
            return "已选中文件：\(selectedFile.path)\n后续这里接入 diff 和文件详情。"
        }

        if !selectedFiles.isEmpty {
            return "已选中 \(selectedFiles.count) 个文件\n后续这里补批量操作和多文件汇总。"
        }

        if let repository {
            return "当前仓库：\(repository.path)\n先从左边勾选或选择文件，后续这里补右侧内容。"
        }

        return "先从左侧选择一个本地仓库，后续这里补仓库详情和 diff。"
    }
}
