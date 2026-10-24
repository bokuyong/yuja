import ArgumentParser
import Foundation
import YujaCore

@main
struct Yuja: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "yuja",
        abstract: "HWP/HWPX 문서를 Markdown·TXT·DOCX·PDF로 변환합니다.",
        version: "0.1.0",
        subcommands: [Convert.self, Inspect.self]
    )
}

extension OutputFormat: ExpressibleByArgument {}
extension MarkdownOptions.TableStyle: ExpressibleByArgument {}

struct Convert: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "문서를 변환합니다.")

    @Argument(help: "입력 파일 (.hwp / .hwpx)")
    var input: String

    @Option(name: .long, help: "출력 형식 (md, txt, docx, pdf)")
    var to: OutputFormat = .md

    @Option(name: .long, help: "출력 파일 경로. '-'이면 표준 출력 (기본: 원본 옆)")
    var out: String?

    @Option(name: .long, help: "이미지 저장 폴더 (기본: <출력파일명>_assets)")
    var assetsDir: String?

    @Flag(name: .long, help: "이미지를 추출하지 않습니다.")
    var noImages = false

    @Option(name: .long, help: "Markdown 표 형식: gfm(병합 평탄화) 또는 html(병합 보존)")
    var tableStyle: MarkdownOptions.TableStyle = .gfm

    @Flag(name: .long, help: "GFM 표의 병합 셀에 (↔2) (↕3) 표기를 붙입니다.")
    var spanMarks = false

    func run() throws {
        let inputURL = URL(fileURLWithPath: input)
        let options = ConvertOptions(
            format: to,
            markdown: MarkdownOptions(tableStyle: tableStyle, spanMarks: spanMarks),
            extractImages: !noImages && out != "-"
        )

        if out == "-" {
            let document = try Converter.load(inputURL).document
            switch to {
            case .md: print(MarkdownExporter(options: options.markdown).export(document), terminator: "")
            case .txt: print(TextExporter().export(document), terminator: "")
            case .docx, .pdf: throw ValidationError("\(to.rawValue)는 표준 출력으로 낼 수 없습니다.")
            }
            return
        }

        let result = try Converter.convert(
            input: inputURL,
            output: out.map { URL(fileURLWithPath: $0) },
            assetsDirectory: assetsDir.map { URL(fileURLWithPath: $0, isDirectory: true) },
            options: options
        )
        print(result.output.path)
        if !result.assets.isEmpty {
            print("이미지 \(result.assets.count)개 → \(result.assets[0].deletingLastPathComponent().path)")
        }
    }
}

struct Inspect: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "문서 구조(IR)를 출력합니다.")

    @Argument(help: "입력 파일 (.hwp / .hwpx)")
    var input: String

    @Option(name: .long, help: "텍스트 미리보기 글자 수")
    var preview: Int = 40

    func run() throws {
        let document = try Converter.load(URL(fileURLWithPath: input)).document
        print(IRDump.dump(document, previewLength: preview), terminator: "")
    }
}
