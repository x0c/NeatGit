import SwiftUI

struct SidebarToggleButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 17))
        }
        .buttonStyle(.plain)
        .help("显示或隐藏项目栏")
        .accessibilityLabel("显示或隐藏项目栏")
    }
}
