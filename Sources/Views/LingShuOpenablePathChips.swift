import SwiftUI

struct LingShuOpenablePathChips: View {
    let paths: [String]
    var onPreview: ((URL) -> Void)?

    init(text: String, onPreview: ((URL) -> Void)?) {
        self.paths = LingShuLocalPathDetector.existingFilePaths(in: text)
        self.onPreview = onPreview
    }

    init(paths: [String], onPreview: ((URL) -> Void)?) {
        self.paths = paths
        self.onPreview = onPreview
    }

    var body: some View {
        if let onPreview, !paths.isEmpty {
            HStack(spacing: 6) {
                ForEach(Array(paths.enumerated()), id: \.element) { index, path in
                    let url = URL(fileURLWithPath: path)
                    Button { onPreview(url) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "eye")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(Color.lingHolo)
                            Text(paths.count == 1
                                 ? LingShuLanguagePreferenceStore.localized("预览", "Preview")
                                 : LingShuLanguagePreferenceStore.localized("预览 \(index + 1)", "Preview \(index + 1)"))
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Color.lingFg.opacity(0.86))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.lingHolo.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Color.lingHolo.opacity(0.18), lineWidth: 0.8)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(LingShuLanguagePreferenceStore.localized("点击预览 \(path)", "Preview \(path)"))
                }
            }
        }
    }
}
