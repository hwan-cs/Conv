import SwiftUI

/// Every component on one page, for previews and the snapshot test.
struct DesignSystemGallery: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            section("STICKERS") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        ForEach(["heic", "jpg", "png", "webp", "pdf"], id: \.self) { FormatSticker($0) }
                    }
                    HStack(spacing: 12) {
                        ForEach(["docx", "hwp", "md", "mov", "mp4", "mp3"], id: \.self) { FormatSticker($0) }
                    }
                    HStack(alignment: .center, spacing: 12) {
                        FormatSticker("heic", size: .mini)
                        FormatSticker("jpg", size: .large)
                    }
                }
            }
            section("KEYCAPS") {
                HStack(spacing: 12) {
                    Keycap(ext: "jpg", caption: "추천 · 어디서나 열려요", key: "1", isRecommended: true) {}
                    Keycap(ext: "png", caption: "화질 손실 없음", key: "2") {}
                }
                .frame(width: 440)
            }
            section("TYPE") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("3개 바꿨어요").font(ConvFont.sans(40, .heavy)).tracking(-1.5)
                    Text("원본은 그대로 두고, 바뀐 파일은 원본 옆에.").font(ConvFont.sans(15))
                    Text(".heic → .jpg").font(ConvFont.mono(22, .bold))
                }
                .foregroundStyle(ConvColor.ink)
            }
            section("STAMP · KEYS") {
                HStack(spacing: 40) {
                    ConvStamp(subtitle: "3 OF 4 · 2026.10.26", animated: false)
                    KeyHint("⌘O")
                    KeyHint("⌘Z")
                }
            }
        }
        .padding(32)
        .background(ConvColor.paper)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(ConvFont.mono(12, .bold))
                .tracking(1)
                .foregroundStyle(ConvColor.muted)
            content()
        }
    }
}

#Preview {
    DesignSystemGallery()
}
