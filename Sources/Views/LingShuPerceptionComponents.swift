import SwiftUI

struct PerceptionActionButton: View {
    let title: String
    let icon: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(isActive ? Color.lingVoid : Color.lingFg.opacity(0.82))
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(
                    isActive ? Color.lingHolo : Color.lingFg.opacity(0.075),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.lingHolo.opacity(isActive ? 0 : 0.16))
                }
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

struct PerceptionDetailRow: View {
    let label: String
    let value: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isActive ? Color.green : Color.gray.opacity(0.62))
                .frame(width: 8, height: 8)

            Text(label)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.lingFg.opacity(0.58))
                .frame(width: 36, alignment: .leading)

            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.lingFg.opacity(0.82))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
    }
}
