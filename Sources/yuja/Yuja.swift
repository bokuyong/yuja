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

enum OutputFormat: String, ExpressibleByArgument, CaseIterable {
    case md, txt, docx, pdf
}

struct Convert: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "문서를 변환합니다.")

    @Argument(help: "입력 파일 (.hwp / .hwpx)")
    var input: String

    @Option(name: .long, help: "출력 형식")
    var to: OutputFormat = .md

    @Option(name: .long, help: "출력 경로 (기본: 원본 옆)")
    var out: String?

    func run() throws {
        let url = URL(fileURLWithPath: input)
        _ = try Detect.format(of: url)
        throw YujaError.notImplemented("\(to.rawValue) 변환 (Phase 1 예정)")
    }
}

struct Inspect: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "문서 구조를 출력합니다.")

    @Argument(help: "입력 파일 (.hwp / .hwpx)")
    var input: String

    func run() throws {
        let url = URL(fileURLWithPath: input)
        let format = try Detect.format(of: url)
        print("format: \(format.rawValue)")
    }
}
