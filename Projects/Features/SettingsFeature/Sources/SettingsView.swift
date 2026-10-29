import Platform
import SwiftUI

public struct SettingsView: View {
    @State private var shown: OpenSourceLicense?

    public init() {}

    public var body: some View {
        Form {
            LabeledContent("버전", value: AppInfo.version)
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
                Text(license.name).font(.headline)
                Text(license.license).foregroundStyle(.secondary)
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
                Button("닫기") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
    }
}
