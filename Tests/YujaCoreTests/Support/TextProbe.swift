import Foundation
import ZIPFoundation

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

    /// 출력에서 빠진 원본 조각 목록.
    static func missing(_ fragments: [String], in output: String, markdown: Bool) -> [String] {
        let haystack = markdown ? normalizeMarkdown(output) : normalize(output.replacingOccurrences(of: "|", with: " "))
        return fragments
            .map { normalize($0.replacingOccurrences(of: "|", with: " ")) }
            .filter { !haystack.contains($0) }
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
