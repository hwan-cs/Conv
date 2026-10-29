import ConversionKit
import DesignSystem
import SwiftUI
import UniformTypeIdentifiers

/// Main window: empty → drag over → pick format → converting → done.
public struct DropView: View {
    @State private var model = DropModel()
    @State private var isTargeted = false
    @State private var isImporting = false

    public init() {}

    public var body: some View {
        content
            .padding(20)
            .frame(minWidth: 720, minHeight: 456)
            .background(ConvColor.paper)
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                loadURLs(from: providers)
                return true
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { model.accept(urls) }
            }
            .background {
                // ⌘O opens the panel from any screen but the one converting.
                Button("파일 열기") { isImporting = true }
                    .keyboardShortcut("o")
                    .disabled(model.phase == .converting)
                    .hidden()
            }
            .animation(ConvMotion.dragEnter, value: isTargeted)
    }

    @ViewBuilder
    private var content: some View {
        if isTargeted && model.phase != .converting {
            DragOverScreen()
        } else {
            switch model.phase {
            case .empty: EmptyScreen(notice: model.notice) { isImporting = true }
            case .picking: PickScreen(model: model)
            case .converting: ConvertingScreen(model: model)
            case .done: DoneScreen(model: model)
            }
        }
    }

    private func loadURLs(from providers: [NSItemProvider]) {
        let group = DispatchGroup()
        let collected = URLCollector()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { collected.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated { model.accept(collected.urls) }
        }
    }
}

private final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [URL] = []

    func append(_ url: URL) { lock.withLock { collected.append(url) } }
    var urls: [URL] { lock.withLock { collected } }
}

// MARK: Screens

private struct EmptyScreen: View {
    let notice: String?
    let open: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Button(action: open) {
                RoundedRectangle(cornerRadius: 20)
                    .fill(ConvColor.ink)
                    .overlay {
                        VStack(spacing: 12) {
                            Text("여기로 던지세요")
                                .font(ConvFont.sans(34, .heavy))
                                .tracking(-1)
                                .foregroundStyle(ConvColor.white)
                            HStack(spacing: 6) {
                                KeyHint("⌘O", onInk: true)
                                Text("로 직접 고르기")
                                    .font(ConvFont.sans(13))
                                    .foregroundStyle(ConvColor.onInkMuted)
                            }
                        }
                    }
            }
            .buttonStyle(.plain)
            if let notice {
                Text(notice)
                    .font(ConvFont.sans(13))
                    .foregroundStyle(ConvColor.errorText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct DragOverScreen: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 20)
            .fill(ConvColor.signal)
            .overlay {
                RoundedRectangle(cornerRadius: 20).strokeBorder(ConvColor.ink, lineWidth: 1.5)
            }
            .overlay {
                VStack(spacing: 18) {
                    Capsule().fill(ConvColor.ink).frame(width: 220, height: 16)
                    Text("놓으세요!")
                        .font(ConvFont.sans(40, .heavy))
                        .tracking(-1)
                        .foregroundStyle(ConvColor.ink)
                }
            }
    }
}

private struct PickScreen: View {
    let model: DropModel
    /// Picking a format only selects it; converting waits for the confirmation below.
    @State private var selected: Formats.Output?

    private var primaries: [Formats.Output] { model.outputs.filter(\.isPrimary) }
    private var others: [Formats.Output] { model.outputs.filter { !$0.isPrimary } }

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .center, spacing: 28) {
                FileCard(items: model.items)
                    .frame(width: 200)
                Image(systemName: "arrow.right")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(ConvColor.ink)
                VStack(alignment: .leading, spacing: 14) {
                    Text("무엇으로 바꿀까요?")
                        .font(ConvFont.sans(24, .heavy))
                        .tracking(-0.5)
                        .foregroundStyle(ConvColor.ink)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 18) {
                        ForEach(Array(primaries.enumerated()), id: \.element.id) { index, output in
                            Keycap(
                                ext: output.ext,
                                caption: output.caption,
                                key: Character(String(index + 1)),
                                isSelected: selected == output
                            ) {
                                selected = output
                            }
                        }
                    }
                    if !others.isEmpty {
                        HStack(spacing: 8) {
                            Text("더 보기")
                                .font(ConvFont.sans(12, .semibold))
                                .foregroundStyle(ConvColor.ink)
                            ForEach(others) { output in
                                Button {
                                    selected = output
                                } label: {
                                    Text(StickerStyle.label(for: output.ext))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(
                                            RoundedRectangle(cornerRadius: 5)
                                                .fill(selected == output ? StickerStyle.forExtension("jpg").fill : .clear)
                                        )
                                }
                                .buttonStyle(.plain)
                                .font(ConvFont.mono(12, .bold))
                                .foregroundStyle(selected == output ? ConvColor.ink : ConvColor.muted)
                                .help(output.caption)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)
            ConfirmBar(model: model, selected: selected) {
                if let selected { model.choose(selected) }
            } cancel: {
                // Esc first drops the selection, then leaves the screen.
                if selected != nil { selected = nil } else { model.reset() }
            }
        }
        .animation(ConvMotion.keyPress, value: selected)
    }
}

/// "photo.heic를 .JPG로 바꿀까요?" with the buttons that start or back out of it.
private struct ConfirmBar: View {
    let model: DropModel
    let selected: Formats.Output?
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(question)
                    .font(ConvFont.sans(14, .semibold))
                    .foregroundStyle(ConvColor.ink)
                Text(detail)
                    .font(ConvFont.sans(12))
                    .foregroundStyle(ConvColor.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button(action: cancel) {
                Text(selected == nil ? "취소" : "다시 고르기")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(ConvColor.white))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ConvColor.ink, lineWidth: 1.5))
                    .foregroundStyle(ConvColor.ink)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            Button(action: confirm) {
                HStack(spacing: 6) {
                    Text("바꾸기")
                    KeyHint("⏎", onInk: true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(selected == nil ? ConvColor.muted : ConvColor.ink))
                .foregroundStyle(ConvColor.white)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(selected == nil)
        }
        .font(ConvFont.sans(13, .semibold))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(selected == nil ? ConvColor.paper2 : ConvColor.white))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected == nil ? ConvColor.line : ConvColor.ink, lineWidth: 1.5))
    }

    private var subject: String {
        guard let first = model.items.first else { return "" }
        return model.items.count == 1 ? first.name : "\(model.items.count)개 파일"
    }

    private var question: String {
        guard let selected else { return "바꿀 형식을 고르세요" }
        // File names end in Latin letters, so the sentence avoids a particle after them.
        return "\(subject) → \(StickerStyle.label(for: selected.ext)), 이대로 바꿀까요?"
    }

    private var detail: String {
        guard let selected else { return "숫자 키나 클릭으로 고른 뒤, 한 번 더 확인해요." }
        if model.items.count == 1, let first = model.items.first {
            let name = first.url.deletingPathExtension().appendingPathExtension(selected.ext).lastPathComponent
            return "원본은 그대로 두고, 옆에 저장돼요: \(name)"
        }
        return "원본은 그대로 두고, 각 파일 옆에 저장돼요."
    }
}

private struct FileCard: View {
    let items: [DropModel.Item]

    private var title: String {
        guard let first = items.first else { return "" }
        return items.count == 1 ? first.name : "\(first.name) 외 \(items.count - 1)개"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(ConvColor.paper2)
                    .frame(height: 150)
                    .overlay {
                        if let thumbnail = items.first?.thumbnail {
                            Image(decorative: thumbnail, scale: 2)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: "doc.text")
                                .font(.system(size: 44, weight: .light))
                                .foregroundStyle(ConvColor.muted)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                if let first = items.first {
                    FormatSticker(first.ext, size: .mini)
                        .rotationEffect(.degrees(-6))
                        .offset(x: 8, y: 10)
                }
            }
            // The card can be drawn once more while the model empties on cancel.
            Text(title)
                .font(ConvFont.mono(12, .bold))
                .foregroundStyle(ConvColor.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            if items.count == 1, let size = items.first?.size {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .font(ConvFont.mono(11))
                    .foregroundStyle(ConvColor.muted)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(ConvColor.white))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(ConvColor.ink, lineWidth: 1.5))
    }
}

private struct ConvertingScreen: View {
    let model: DropModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("\(model.items.count)개 바꾸는 중")
                    .font(ConvFont.sans(24, .heavy))
                    .tracking(-0.5)
                Spacer()
                Text("\(model.settledCount) / \(model.items.count)")
                    .font(ConvFont.mono(13, .bold))
            }
            .foregroundStyle(ConvColor.ink)
            ProgressBar(value: model.overallProgress)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(model.items) { item in
                        ConversionRow(item: item, output: model.output?.ext ?? "")
                    }
                }
            }
        }
    }
}

private struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(ConvColor.paper2)
                Capsule().fill(ConvColor.signal).frame(width: geometry.size.width * value)
            }
            .overlay(Capsule().strokeBorder(ConvColor.ink, lineWidth: 1.5))
        }
        .frame(height: 10)
        .animation(.easeOut(duration: 0.2), value: value)
    }
}

private struct ConversionRow: View {
    let item: DropModel.Item
    let output: String

    var body: some View {
        HStack(spacing: 10) {
            FormatSticker(item.ext, size: .mini)
            Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold))
            FormatSticker(output, size: .mini)
            Text(item.name)
                .font(ConvFont.mono(12, .bold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            status
        }
        .foregroundStyle(ConvColor.ink)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(isFailed ? ConvColor.errorFill : ConvColor.white))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isFailed ? ConvColor.errorText : ConvColor.line, lineWidth: 1.5))
    }

    private var isFailed: Bool {
        if case .failed = item.status { true } else { false }
    }

    @ViewBuilder
    private var status: some View {
        switch item.status {
        case .waiting:
            Text("대기 중").font(ConvFont.sans(12)).foregroundStyle(ConvColor.muted)
        case .converting(let fraction?):
            HStack(spacing: 8) {
                ProgressBar(value: fraction)
                    .frame(width: 70)
                Text("\(Int(fraction * 100))%")
                    .font(ConvFont.mono(11, .bold))
                    .frame(width: 34, alignment: .trailing)
            }
        case .converting(nil):
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle").foregroundStyle(ConvColor.success)
        case .failed(let message):
            Text(message)
                .font(ConvFont.sans(12))
                .foregroundStyle(ConvColor.errorText)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct DoneScreen: View {
    let model: DropModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                HStack(spacing: 12) {
                    ForEach(Array(Set(model.items.map(\.ext))).sorted().prefix(3), id: \.self) { _ in
                        FormatSticker(model.output?.ext ?? "pdf", size: .large)
                            .rotationEffect(.degrees(Double.random(in: -8...8)))
                    }
                }
                Spacer()
                ConvStamp(subtitle: "\(model.finishedCount) OF \(model.items.count)")
            }
            Spacer()
            Text(model.finishedCount > 0 ? "\(model.finishedCount)개 바꿨어요" : "바꾸지 못했어요")
                .font(ConvFont.sans(30, .heavy))
                .tracking(-1)
                .foregroundStyle(ConvColor.ink)
            VStack(alignment: .leading, spacing: 4) {
                if model.finishedCount > 0 {
                    Text("원본은 그대로 두고, 바뀐 파일은 원본 옆에 놓았어요.")
                }
                ForEach(model.failedItems) { item in
                    if case .failed(let message) = item.status {
                        Text("\(item.name): \(message)").foregroundStyle(ConvColor.errorText)
                    }
                }
            }
            .font(ConvFont.sans(13))
            .foregroundStyle(ConvColor.muted)
            HStack(spacing: 10) {
                if model.finishedCount > 0 {
                    Button {
                        model.revealOutputs()
                    } label: {
                        Label("Finder에서 보기", systemImage: "folder")
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 10).fill(ConvColor.ink))
                            .foregroundStyle(ConvColor.white)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                }
                Button {
                    model.reset()
                } label: {
                    Text("하나 더 던지기")
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 10).fill(ConvColor.white))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ConvColor.ink, lineWidth: 1.5))
                        .foregroundStyle(ConvColor.ink)
                }
                .buttonStyle(.plain)
            }
            .font(ConvFont.sans(13, .semibold))
        }
        .padding(8)
    }
}
