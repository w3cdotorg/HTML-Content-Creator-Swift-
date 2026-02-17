import SwiftUI

struct StatusPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.green)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.green.opacity(0.16)))
            .overlay(
                Capsule()
                    .stroke(Color.green.opacity(0.35), lineWidth: 1)
            )
    }
}
