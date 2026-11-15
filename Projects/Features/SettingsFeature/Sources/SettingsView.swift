import AppKit
import FinderSync
import Platform
import SwiftUI

public struct SettingsView: View {
    @State private var shown: OpenSourceLicense?

    public init() {}

    public var body: some View {
        Form {
            LabeledContent("버전", value: AppInfo.version)
            FinderMenuSection()
            Section("오픈소스 라이선스") {
                ForEach(OpenSourceLicense.all) { license in
                    Button {
                        shown = license
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(license.name)
                                Text(license.usage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(license.license)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .sheet(item: $shown) { license in
            LicenseSheet(license: license)
        }
    }
}

private struct LicenseSheet: View {
    let license: OpenSourceLicense
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(license.name)
                    .font(.headline)
                Text(license.license)
                    .foregroundStyle(.secondary)
                Spacer()
                Link("웹사이트", destination: license.source)
            }
            if let note = license.note {
                Text(note)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                Text(license.text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.background.secondary)
            HStack {
                Spacer()
                Button("닫기") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
    }
}

/// Finder's "conv로 바꾸기": off until the user turns the extension on, and it works only in
/// folders allowed here, since a sandboxed app can't read files Finder merely names.
private struct FinderMenuSection: View {
    @State private var access = FolderAccess.shared
    @State private var isEnabled = FIFinderSyncController.isExtensionEnabled

    var body: some View {
        Section {
            LabeledContent("Finder 확장") {
                HStack(spacing: 8) {
                    Text(isEnabled ? String(localized: "켜짐") : String(localized: "꺼짐"))
                        .foregroundStyle(isEnabled ? .primary : .secondary)
                    Button(isEnabled ? String(localized: "관리…") : String(localized: "켜기…")) {
                        FIFinderSyncController.showExtensionManagementInterface()
                    }
                }
            }
            ForEach(access.folders, id: \.self) { folder in
                HStack {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(folder.path(percentEncoded: false))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("빼기") { access.remove(folder) }
                }
            }
            HStack {
                Text(access.folders.isEmpty ? String(localized: "허용한 폴더가 없어요") : String(localized: "다른 폴더도 허용할 수 있어요"))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("폴더 허용...") {
                    access.grant()
                }
            }
        } header: {
            Text("Finder 우클릭 메뉴")
        } footer: {
            Text("""
            1. Finder 확장을 켜요. 시스템 설정에서 Conv를 체크하면 돼요.
            2. 바꿀 파일이 있는 폴더를 허용해요. 홈 폴더를 고르면 그 안 어디서든 쓸 수 있어요.
            3. Finder에서 파일을 우클릭하고 "conv로 바꾸기"에서 포맷을 골라요.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isEnabled = FIFinderSyncController.isExtensionEnabled
        }
    }
}
