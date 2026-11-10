import SwiftUI

struct WorkspaceFeedback: Identifiable {
    let id = UUID()
    let message: String
    let failed: Bool
}

struct WorkspaceFeedbackView: View {
    let feedback: WorkspaceFeedback
    let dismiss: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: feedback.failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(feedback.failed ? Color.orange : Color.green)
            Text(feedback.message).font(.system(size: 12)).textSelection(.enabled)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .demandButtonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}
