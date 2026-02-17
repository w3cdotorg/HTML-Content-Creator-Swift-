import SwiftUI

struct FeedbackBanner: View {
    let feedback: AppState.InlineFeedback
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(feedback.message)
                .font(.subheadline)
            Spacer()
            Button("Dismiss") {
                onDismiss()
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(color(for: feedback.kind).opacity(0.16))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(color(for: feedback.kind).opacity(0.5), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func color(for kind: AppState.InlineFeedback.Kind) -> Color {
        switch kind {
        case .success:
            return .green
        case .error:
            return .red
        case .info:
            return .blue
        }
    }
}
