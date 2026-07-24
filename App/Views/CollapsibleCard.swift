import SwiftUI

/// A titled, collapsible card whose collapsed state persists per-key across launches.
struct CollapsibleCard<Content: View>: View {
  var title: String
  var systemImage: String
  var stateKey: String
  @ViewBuilder var content: () -> Content

  @AppStorage private var collapsed: Bool

  init(title: String, systemImage: String, stateKey: String,
       @ViewBuilder content: @escaping () -> Content) {
    self.title = title
    self.systemImage = systemImage
    self.stateKey = stateKey
    self.content = content
    _collapsed = AppStorage(wrappedValue: false, "section.collapsed.\(stateKey)")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(.snappy) { collapsed.toggle() }
      } label: {
        HStack(spacing: 8) {
          Image(systemName: systemImage)
            .foregroundStyle(.tint)
            .frame(width: 18)
          Text(title)
            .font(.headline)
          Spacer()
          Image(systemName: "chevron.right")
            .rotationEffect(.degrees(collapsed ? 0 : 90))
            .foregroundStyle(.secondary)
            .font(.caption.weight(.semibold))
        }
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .padding(12)

      if !collapsed {
        Divider().padding(.horizontal, 12)
        content()
          .padding(12)
      }
    }
    .background(.background.secondary, in: .rect(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
  }
}
