import Foundation

/// Third-party code and fonts that ship inside Conv, with the notices their licenses require.
/// Each `file` is a license text in Resources/Licenses.
struct OpenSourceLicense: Identifiable, Sendable {
    let name: String
    /// What Conv uses it for.
    let usage: String
    let license: String
    let source: URL
    let file: String
    /// Further terms the license asks to be stated, such as how to replace an LGPL library.
    var note: String?

    var id: String { name }

    var text: String {
        guard let url = Bundle.module.url(forResource: file, withExtension: "txt", subdirectory: "Licenses")
            ?? Bundle.module.url(forResource: file, withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return text
    }

    static let all: [OpenSourceLicense] = [
        OpenSourceLicense(
            name: "LAME 3.100",
            usage: "MP3로 저장",
            license: "GNU LGPL 2",
            source: URL(string: "https://lame.sourceforge.io")!,
            file: "LAME",
            note: """
            LAME은 동적 라이브러리(libmp3lame.dylib)로 연결되어 있으며, 수정하지 않은 3.100 공식 소스로 \
            빌드했습니다. 앱 안의 Contents/XPCServices/ConversionXPC.xpc/Contents/Frameworks에 있고, \
            같은 이름의 호환 빌드로 바꿔 넣을 수 있습니다. 소스: \
            https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz
            """
        ),
        OpenSourceLicense(
            name: "나눔고딕, 나눔명조",
            usage: "HWP 문서를 바꿀 때 한글 글꼴 대신",
            license: "SIL Open Font License 1.1",
            source: URL(string: "https://hangeul.naver.com/font")!,
            file: "Nanum"
        ),
        OpenSourceLicense(
            name: "ZIPFoundation",
            usage: "DOCX, HWPX 파일 읽기",
            license: "MIT",
            source: URL(string: "https://github.com/weichsel/ZIPFoundation")!,
            file: "ZIPFoundation"
        ),
        OpenSourceLicense(
            name: "Pretendard",
            usage: "화면 글꼴",
            license: "SIL Open Font License 1.1",
            source: URL(string: "https://github.com/orioncactus/pretendard")!,
            file: "Pretendard"
        ),
        OpenSourceLicense(
            name: "JetBrains Mono",
            usage: "확장자·파일 이름 글꼴",
            license: "SIL Open Font License 1.1",
            source: URL(string: "https://github.com/JetBrains/JetBrainsMono")!,
            file: "JetBrainsMono"
        ),
    ]
}
