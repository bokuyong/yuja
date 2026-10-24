import Foundation

struct CharShape: Equatable {
    var bold = false
    var italic = false
    var underline = false
    var strike = false
}

struct ParaShape: Equatable {
    enum Heading: Equatable { case none, outline, number, bullet }

    var align: Align?
    var heading: Heading = .none
    var level = 0
}

/// Contents/header.xml에서 변환에 필요한 글자모양·문단모양만 뽑는다.
struct HeaderStyles {
    var charShapes: [Int: CharShape] = [:]
    var paraShapes: [Int: ParaShape] = [:]

    func charShape(_ id: Int) -> CharShape { charShapes[id] ?? CharShape() }
    func paraShape(_ id: Int) -> ParaShape { paraShapes[id] ?? ParaShape() }

    static func parse(_ data: Data) throws -> HeaderStyles {
        let delegate = HeaderDelegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse() else {
            throw YujaError.corrupted("header.xml을 해석할 수 없습니다")
        }
        return delegate.styles
    }
}

private final class HeaderDelegate: NSObject, XMLParserDelegate {
    var styles = HeaderStyles()
    private var charID: Int?
    private var char = CharShape()
    private var paraID: Int?
    private var para = ParaShape()

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        switch name {
        case "charPr":
            charID = attributes["id"].flatMap(Int.init)
            char = CharShape()
        case "bold" where charID != nil:
            char.bold = true
        case "italic" where charID != nil:
            char.italic = true
        case "underline" where charID != nil:
            char.underline = (attributes["type"] ?? "NONE") != "NONE"
        case "strikeout" where charID != nil:
            char.strike = (attributes["shape"] ?? "NONE") != "NONE"

        case "paraPr":
            paraID = attributes["id"].flatMap(Int.init)
            para = ParaShape()
        case "align" where paraID != nil:
            para.align = Self.align(attributes["horizontal"])
        case "heading" where paraID != nil:
            switch attributes["type"] {
            case "OUTLINE": para.heading = .outline
            case "NUMBER": para.heading = .number
            case "BULLET": para.heading = .bullet
            default: para.heading = .none
            }
            para.level = attributes["level"].flatMap(Int.init) ?? 0
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "charPr":
            if let id = charID { styles.charShapes[id] = char }
            charID = nil
        case "paraPr":
            if let id = paraID { styles.paraShapes[id] = para }
            paraID = nil
        default:
            break
        }
    }

    private static func align(_ value: String?) -> Align? {
        switch value {
        case "LEFT": return .left
        case "CENTER": return .center
        case "RIGHT": return .right
        case "JUSTIFY", "DISTRIBUTE", "DISTRIBUTE_SPACE": return .justify
        default: return nil
        }
    }
}
