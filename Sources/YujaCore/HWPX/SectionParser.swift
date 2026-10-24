import Foundation

/// Contents/sectionN.xml → IR Section. XMLParser(SAX)로 한 번 훑으면서 만든다.
///
/// 표·그림·글상자 같은 개체는 hp:run 안에 인라인으로 들어 있으므로,
/// 문단은 "텍스트 조각"과 "블록"이 섞인 순서열로 모았다가 문단이 끝날 때 펼친다.
struct SectionParser {
    let styles: HeaderStyles
    /// manifest id → 패키지 안 경로 (hc:img binaryItemIDRef 해석용)
    let binaryItems: [String: String]

    func parse(_ data: Data) throws -> Section {
        let delegate = SectionDelegate(styles: styles, binaryItems: binaryItems)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse() else {
            let reason = parser.parserError?.localizedDescription ?? "알 수 없는 오류"
            throw YujaError.corrupted("본문 XML을 해석할 수 없습니다 (\(reason))")
        }
        return Section(blocks: delegate.finish())
    }
}


private final class TableBuilder {
    var rows: [[Cell]] = []
    var cell = Cell()
}

private final class SectionDelegate: NSObject, XMLParserDelegate {
    let styles: HeaderStyles
    let binaryItems: [String: String]

    private var elements: [String] = []
    private var containers: [[Item]] = [[]]
    private var paragraphs: [ParagraphBuilder] = []
    private var tables: [TableBuilder] = []
    private var textDepth = 0
    private var script: String?
    /// hp:pic 안에서 hc:img보다 먼저 나오는 표시 크기(curSz)를 모았다가 그림 끝에서 블록을 만든다.
    private var pictures: [(image: ImageRef?, size: ImageSize?)] = []
    /// hp:switch 안의 hp:default는 hp:case와 같은 내용의 대체 표기라 건너뛴다.
    private var skipDepth = 0

    init(styles: HeaderStyles, binaryItems: [String: String]) {
        self.styles = styles
        self.binaryItems = binaryItems
    }

    func finish() -> [Block] {
        BlockBuilder.fold(containers.first ?? [])
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        if skipDepth > 0 { skipDepth += 1; return }
        if name == "default" && elements.last == "switch" { skipDepth = 1; return }
        elements.append(name)

        switch name {
        case "p":
            let shape = styles.paraShape(attributes["paraPrIDRef"].flatMap(Int.init) ?? 0)
            paragraphs.append(ParagraphBuilder(shape: shape, pageBreak: attributes["pageBreak"] == "1"))
        case "run":
            paragraphs.last?.charShape = styles.charShape(attributes["charPrIDRef"].flatMap(Int.init) ?? 0)
        case "t":
            textDepth += 1
        case "lineBreak":
            paragraphs.last?.appendText("\n")
        case "tab":
            paragraphs.last?.appendText("\t")
        case "nbSpace", "fwSpace":
            paragraphs.last?.appendText(" ")
        case "hyphen":
            paragraphs.last?.appendText("-")
        case "checkBtn", "radioBtn":
            let mark = attributes["value"] == "CHECKED" ? "☑" : "☐"
            paragraphs.last?.appendText(mark + (attributes["caption"] ?? ""))

        case "tbl":
            tables.append(TableBuilder())
        case "tr":
            tables.last?.rows.append([])
        case "tc":
            tables.last?.cell = Cell()
        case "cellSpan":
            tables.last?.cell.colSpan = max(1, attributes["colSpan"].flatMap(Int.init) ?? 1)
            tables.last?.cell.rowSpan = max(1, attributes["rowSpan"].flatMap(Int.init) ?? 1)
        case "cellSz":
            if let w = attributes["width"].flatMap(Double.init), w > 0 { tables.last?.cell.width = w / 100 }
        case "subList":
            containers.append([])

        case "pic":
            pictures.append((nil, nil))
        case "curSz", "sz":
            // 그림 안에서만. curSz(현재 크기)를 우선하고, 없을 때만 sz를 쓴다. 단위 HWPUNIT = 1/7200 inch = 0.01pt
            guard !pictures.isEmpty, name == "curSz" || pictures[pictures.count - 1].size == nil,
                  let w = attributes["width"].flatMap(Double.init), let h = attributes["height"].flatMap(Double.init),
                  w > 0, h > 0 else { break }
            pictures[pictures.count - 1].size = ImageSize(width: w / 100, height: h / 100)
        case "img":
            if let id = attributes["binaryItemIDRef"] {
                let ref = ImageRef(sourceID: binaryItems[id] ?? id)
                if pictures.isEmpty {
                    appendBlock(.image(ref))
                } else {
                    pictures[pictures.count - 1].image = ref
                }
            }
        case "script":
            script = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard skipDepth == 0 else { return }
        if textDepth > 0 {
            paragraphs.last?.appendText(string)
        } else if script != nil {
            script? += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if skipDepth > 0 { skipDepth -= 1; return }

        switch name {
        case "t":
            textDepth -= 1
        case "script":
            let text = (script ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let paragraph = paragraphs.last {
                paragraph.appendEquation(text)
            } else if !text.isEmpty {
                appendBlock(.raw(text))
            }
            script = nil
        case "pic":
            if let picture = pictures.popLast(), var image = picture.image {
                image.size = picture.size
                appendBlock(.image(image))
            }

        case "subList":
            let blocks = BlockBuilder.fold(containers.removeLast())
            let parent = elements.count >= 2 ? elements[elements.count - 2] : nil
            if parent == "tc" {
                tables.last?.cell.blocks += blocks
            } else if let paragraph = paragraphs.last {
                paragraph.trailing += blocks
            } else {
                containers[containers.count - 1] += blocks.map(Item.block)
            }
        case "tc":
            if let table = tables.last {
                if table.rows.isEmpty { table.rows.append([]) }
                table.rows[table.rows.count - 1].append(table.cell)
            }
        case "tbl":
            if let table = tables.popLast() {
                appendBlock(.table(Table(rows: table.rows.filter { !$0.isEmpty })))
            }
        case "p":
            if let paragraph = paragraphs.popLast() {
                containers[containers.count - 1] += paragraph.items()
            }
        default:
            break
        }

        elements.removeLast()
    }

    // MARK: -

    private func appendBlock(_ block: Block) {
        if let paragraph = paragraphs.last {
            paragraph.segments.append(.block(block))
        } else {
            containers[containers.count - 1].append(.block(block))
        }
    }
}
