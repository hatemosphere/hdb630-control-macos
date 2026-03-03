import SwiftUI

struct CardSection<Content: View>: View {
    let header: String?
    let content: Content

    init(_ header: String? = nil, @ViewBuilder content: () -> Content) {
        self.header = header
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header {
                Text(header)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)
            }
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
