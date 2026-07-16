import AppKit
import SwiftUI

struct LingShuInitialLanguageSelectionView: View {
    @ObservedObject var state: LingShuState

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 72)

                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 112, height: 112)
                    .accessibilityHidden(true)

                Text("灵枢 · LingShu")
                    .font(.system(size: 34, weight: .semibold))
                    .padding(.top, 22)

                Text("选择语言 · Choose a language")
                    .font(.system(size: 20, weight: .medium))
                    .padding(.top, 34)

                Text("此选择将用于界面、回复与语音。\nThis choice controls the interface, replies, and voice.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(5)
                    .padding(.top, 12)

                HStack(spacing: 16) {
                    languageButton(
                        .chinese,
                        title: "中文",
                        detail: "使用中文界面与回复",
                        symbol: "character.book.closed"
                    )
                    languageButton(
                        .english,
                        title: "English",
                        detail: "Use English for the app and replies",
                        symbol: "textformat.abc"
                    )
                }
                .padding(.top, 34)

                Text("稍后可在设置中更改 · You can change this later in Settings")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 22)

                Spacer(minLength: 72)
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 48)
        }
        .frame(minWidth: 900, minHeight: 640)
    }

    private func languageButton(
        _ language: LingShuVoiceLanguage,
        title: String,
        detail: String,
        symbol: String
    ) -> some View {
        Button {
            state.completeInitialLanguageSelection(language)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 10)

                Image(systemName: "arrow.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .frame(width: 300, height: 84)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(detail)")
    }
}
