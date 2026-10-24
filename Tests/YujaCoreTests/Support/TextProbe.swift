import Foundation
import ZIPFoundation
@testable import YujaCore

/// "텍스트 유실 0" 검사. 파서와 독립적으로(정규식으로) 원본 hp:t 텍스트를 모아
/// 변환 결과에 모두 들어 있는지 본다.
enum TextProbe {
    static func fragments(ofHWPX url: URL) throws -> [String] {
        let archive = try Archive(url: url, accessMode: .read)
        let pattern = try NSRegularExpression(pattern: "<hp:t>(.*?)</hp:t>", options: [.dotMatchesLineSeparators])
        var out: [String] = []

        for entry in archive where entry.path.hasPrefix("Contents/section") && entry.path.hasSuffix(".xml") {
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            let xml = String(decoding: data, as: UTF8.self)
            let range = NSRange(xml.startIndex..., in: xml)
            for match in pattern.matches(in: xml, range: range) {
                guard let r = Range(match.range(at: 1), in: xml) else { continue }
                // 안쪽 태그(lineBreak, tab …)는 공백으로
                let inner = xml[r].replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                let text = normalize(unescapeXML(inner))
                if !text.isEmpty { out.append(text) }
            }
        }
        return out
    }

    /// HWP 5.0: 한컴이 저장해 둔 미리보기 텍스트(PrvText, 문서 앞부분)를 기준값으로 쓴다.
    /// 표 셀은 `<…>`로 감싸여 있으므로 꺾쇠·줄바꿈에서 자른다.
    static func fragments(ofHWP url: URL) throws -> [String] {
        let cfb = try CompoundFile(Data(contentsOf: url))
        guard let data = try cfb.stream("PrvText") else { return [] }
        let text = String(decoding: [UInt8](data).utf16Units, as: UTF16.self)
        return text.components(separatedBy: CharacterSet(charactersIn: "<>\r\n"))
            .map(normalize)
            .filter { !$0.isEmpty }
    }

    /// 출력에서 빠진 원본 조각 목록.
    ///
    /// wordsInOrder: 조각을 통째로 찾는 대신 낱말들이 순서대로 나오는지만 본다.
    /// HWP의 PrvText는 수식을 빼고 저장하므로 ("크기가 인 행렬") 통째 비교가 성립하지 않는다.
    static func missing(_ fragments: [String], in output: String, markdown: Bool, wordsInOrder: Bool = false) -> [String] {
        var haystack = markdown ? normalizeMarkdown(output) : normalize(output.replacingOccurrences(of: "|", with: " "))
        // 수식 코드 스팬의 백틱 (HWP 비교에서만 — HWPX 픽스처엔 본문에 백틱 글자가 있다)
        if markdown && wordsInOrder { haystack = haystack.replacingOccurrences(of: "`", with: " ") }
        return fragments
            .map { normalize($0.replacingOccurrences(of: "|", with: " ")) }
            .filter { fragment in
                guard wordsInOrder else { return !haystack.contains(fragment) }
                var rest = haystack[...]
                for word in fragment.split(separator: " ") {
                    guard let found = rest.range(of: word) else { return true }
                    rest = rest[found.upperBound...]
                }
                return false
            }
    }

    static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func normalizeMarkdown(_ markdown: String) -> String {
        var s = markdown
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "~~", with: "")
            .replacingOccurrences(of: "<br>", with: " ")
        s = s.replacingOccurrences(of: #"\\([\\`*_{}\[\]()#+\-.!|~<>])"#, with: "$1", options: .regularExpression)
        return normalize(s.replacingOccurrences(of: "|", with: " "))
    }

    private static func unescapeXML(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
