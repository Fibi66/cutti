import SwiftUI

/// Bottom-sheet sticker picker: tapping an emoji inserts it as a
/// subtitle-style overlay at the current playhead. Reuses the
/// subtitle render pipeline (PreviewPane already draws
/// `activeSubtitleText`) so stickers are rendered + burned into the
/// export for free.
struct StickerPickerSheet: View {
    @EnvironmentObject var document: ProjectDocument
    @Environment(\.dismiss) private var dismiss

    @State private var category: Category = .hot

    enum Category: String, CaseIterable, Identifiable {
        case hot = "热门"
        case faces = "表情"
        case gestures = "手势"
        case symbols = "图形"
        case nature = "自然"
        case food = "食物"
        case party = "庆祝"

        var id: String { rawValue }

        var emojis: [String] {
            switch self {
            case .hot:
                return ["🔥", "❤️", "😂", "✨", "👍", "🎉", "💯", "🥰",
                        "😍", "😭", "🙏", "💪", "👀", "🤣", "🤔", "😎"]
            case .faces:
                return ["😀","😃","😄","😁","😆","🥹","😅","🤣",
                        "😂","🙂","🙃","😉","😊","😇","🥰","😍",
                        "🤩","😘","😗","☺️","😚","😙","🥲","😋",
                        "😛","😜","🤪","😝","🤑","🤗","🤭","🫢",
                        "🫣","🤫","🤔","🫡","🤐","🤨","😐","😑",
                        "😶","😏","😒","🙄","😬","😮‍💨","🤥"]
            case .gestures:
                return ["👋","🤚","🖐","✋","🖖","👌","🤌","🤏",
                        "✌️","🤞","🫰","🤟","🤘","🤙","👈","👉",
                        "👆","🖕","👇","☝️","👍","👎","✊","👊",
                        "🤛","🤜","👏","🙌","🫶","👐","🤲","🙏"]
            case .symbols:
                return ["❤️","🧡","💛","💚","💙","💜","🖤","🤍",
                        "🤎","💔","❣️","💕","💞","💓","💗","💖",
                        "💘","💝","💟","☮️","✝️","☪️","🕉","☸️",
                        "✡️","☯️","🔯","🕎","☦️","🛐","⛎","♈️"]
            case .nature:
                return ["🐶","🐱","🐭","🐹","🐰","🦊","🐻","🐼",
                        "🐨","🐯","🦁","🐮","🐷","🐸","🐵","🙈",
                        "🐔","🐧","🐦","🐤","🦆","🦅","🦉","🦇",
                        "🐺","🐗","🐴","🦄","🐝","🪱","🐛","🦋"]
            case .food:
                return ["🍎","🍊","🍋","🍌","🍉","🍇","🍓","🫐",
                        "🍈","🍒","🍑","🥭","🍍","🥥","🥝","🍅",
                        "🍆","🥑","🥦","🥬","🥒","🌶","🫑","🌽",
                        "🥕","🫒","🧄","🧅","🥔","🍠","🥐","🥯"]
            case .party:
                return ["🎉","🎊","🎈","🎂","🎁","🎀","🎗","🪅",
                        "🪩","🎇","🎆","🧨","✨","🪄","⭐️","🌟",
                        "💫","🎐","🎑","🎏","🎎","🎍","🧧","🎄"]
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("贴纸").font(.headline).foregroundStyle(.white)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.white.opacity(0.15)))
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(Category.allCases) { cat in
                        Button { category = cat } label: {
                            Text(cat.rawValue)
                                .font(.system(size: 14,
                                              weight: category == cat ? .semibold : .regular))
                                .foregroundStyle(category == cat ? .white : .white.opacity(0.55))
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            let cols = [GridItem](repeating: GridItem(.flexible(), spacing: 8), count: 6)
            ScrollView {
                LazyVGrid(columns: cols, spacing: 10) {
                    ForEach(category.emojis, id: \.self) { e in
                        Button {
                            _ = document.insertTextAtPlayhead(e, duration: 2.0)
                            dismiss()
                        } label: {
                            Text(e)
                                .font(.system(size: 34))
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.white.opacity(0.08))
                                )
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black.ignoresSafeArea())
    }
}
