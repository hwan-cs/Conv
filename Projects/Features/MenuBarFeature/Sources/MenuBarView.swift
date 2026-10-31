import AppKit
import DesignSystem
import Platform
import SwiftUI

/// The menu bar item's popover: the clipboard on ⌘V, the recent conversions, and the way to the
/// main window.
struct MenuBarView: View {
    let close: () -> Void
    @State private var notice: String?
    private let history = ConversionHistory.shared
    private let quiet = QuietConversions.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let job = quiet.current {
                converting(job)
            }
            pasteCard
            if let notice {
                Text(notice)
                    .font(ConvFont.sans(12))
                    .foregroundStyle(ConvColor.errorText)
            }
            if !history.entries.isEmpty {
                recent
            }
            Divider().overlay(ConvColor.line)
            Button {
                showMainWindow()
            } label: {
                HStack {
                    Text("conv. 열기").font(ConvFont.sans(13, .semibold))
                    Spacer()
                    Text("⌘O").font(ConvFont.mono(11)).foregroundStyle(ConvColor.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("o")
        }
        .foregroundStyle(ConvColor.ink)
        .padding(14)
        .frame(width: 340)
        .background(ConvColor.paper)
        .background {
            Button("붙여넣기", action: paste)
                .keyboardShortcut("v")
                .hidden()
        }
    }

    /// Pasting is what the popover is for: a copied screenshot or file, converted without a window.
    private var pasteCard: some View {
        Button(action: paste) {
            RoundedRectangle(cornerRadius: 14)
                .fill(ConvColor.ink)
                .frame(height: 104)
                .overlay {
                    VStack(spacing: 10) {
                        HStack(spacing: 6) {
                            KeyHint("⌘V", onInk: true)
                            Text("붙여넣어 바꾸기")
                                .font(ConvFont.sans(18, .heavy))
                                .foregroundStyle(ConvColor.white)
                        }
                        Text("복사한 이미지나 Finder에서 복사한 파일")
                            .font(ConvFont.sans(11))
                            .foregroundStyle(ConvColor.onInkMuted)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    /// Finder's conversion running in the background.
    private func converting(_ job: QuietConversions.Job) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("바꾸는 중")
                    .font(ConvFont.sans(11, .semibold))
                    .foregroundStyle(ConvColor.muted)
                Text(job.files[min(quiet.fileIndex, job.files.count - 1)].lastPathComponent)
                    .font(ConvFont.mono(11, .bold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if job.files.count > 1 {
                    Text("\(quiet.fileIndex + 1)/\(job.files.count)")
                        .font(ConvFont.mono(11))
                        .foregroundStyle(ConvColor.muted)
                }
            }
            ProgressView(value: quiet.progress)
                .tint(ConvColor.ink)
        }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("최근")
                .font(ConvFont.sans(11, .semibold))
                .foregroundStyle(ConvColor.muted)
            ForEach(history.entries.prefix(5)) { entry in
                Button {
                    history.reveal(entry)
                } label: {
                    HStack(spacing: 6) {
                        FormatSticker(entry.inputExtension, size: .mini)
                        Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold))
                        FormatSticker(entry.outputExtension, size: .mini)
                        Text(entry.inputName)
                            .font(ConvFont.mono(11, .bold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(Self.relative(entry.date))
                            .font(ConvFont.sans(11))
                            .foregroundStyle(ConvColor.muted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Finder에서 보기")
            }
        }
    }

    // MARK: Actions

    private func showMainWindow() {
        close()
        MainWindow.show()
    }

    /// Files copied in Finder go the way of a drop. Only image data (a copied screenshot, an image
    /// copied in a browser) is pasted as an image; Finder also puts a file's icon on the clipboard,
    /// which must not be mistaken for the file.
    private func paste() {
        let pasteboard = NSPasteboard.general
        let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !files.isEmpty {
            notice = nil
            ConversionInbox.shared.send(files)
            showMainWindow()
            return
        }
        // The image as it was copied, without re-encoding.
        let types: [(NSPasteboard.PasteboardType, String)] = [
            (.png, "png"), (NSPasteboard.PasteboardType("public.jpeg"), "jpg"),
            (NSPasteboard.PasteboardType("public.heic"), "heic"), (.tiff, "tiff"),
        ]
        guard let (data, ext) = types.lazy.compactMap({ type, ext in pasteboard.data(forType: type).map { ($0, ext) } }).first else {
            notice = "클립보드에 이미지나 파일이 없어요."
            return
        }
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).dateTimeSeparator(.space).timeSeparator(.omitted))
        let url = FileManager.default.temporaryDirectory.appending(path: "클립보드 이미지 \(stamp).\(ext)")
        do {
            try data.write(to: url)
        } catch {
            notice = "이미지를 가져오지 못했어요."
            return
        }
        notice = nil
        ConversionInbox.shared.send([url], isPasted: true)
        showMainWindow()
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: .now)
    }
}
