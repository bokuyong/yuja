import Foundation

/// BodyText/SectionN 레코드 → IR Section.
///
/// 문단(PARA_HEADER)의 텍스트에서 확장 제어 문자를 만날 때마다 그 문단의 CTRL_HEADER 자식을
/// 순서대로 하나씩 꺼내 처리한다 (표·그림은 인라인 블록, 수식은 수식 런, 머리말·각주·글상자는 문단 뒤에).
struct HWPBodyParser {
    let docInfo: HWPDocInfo

    func parse(_ records: [HWPRecord]) -> Section {
        let roots = RecordNode.tree(records).filter { $0.tag == HWPTag.paraHeader }
        return Section(blocks: blocks(of: roots))
    }

    // MARK: 문단

    private func blocks(of paragraphs: [RecordNode]) -> [Block] {
        BlockBuilder.fold(paragraphs.flatMap(items))
    }

    private func items(_ node: RecordNode) -> [Item] {
        let header = ByteReader(node.payload)
        let shapeID = Int((try? header.u16(at: 8)) ?? 0)
        let breakType = node.payload.count > 11 ? node.payload[11] : 0
        let paragraph = ParagraphBuilder(
            shape: docInfo.styles.paraShape(shapeID),
            pageBreak: breakType & (0x01 | 0x04) != 0  // 구역 나누기·쪽 나누기
        )

        let text = node.children.first { $0.tag == HWPTag.paraText }?.payload.utf16Units ?? []
        var controls = node.children.filter { $0.tag == HWPTag.ctrlHeader }[...]
        let shapes = charShapePositions(node)

        var buffer: [UInt16] = []
        var nextShape = 0
        func flush() {
            guard !buffer.isEmpty else { return }
            paragraph.appendText(String(decoding: buffer, as: UTF16.self))
            buffer.removeAll(keepingCapacity: true)
        }

        var i = 0
        while i < text.count {
            // 글자 모양이 바뀌는 위치 (WCHAR 단위, 제어 문자 8칸 포함)
            while nextShape < shapes.count && shapes[nextShape].position <= i {
                flush()
                paragraph.charShape = docInfo.styles.charShape(shapes[nextShape].id)
                nextShape += 1
            }

            let unit = text[i]
            guard unit < 32 else {
                buffer.append(unit)
                i += 1
                continue
            }
            switch unit {
            case 10:  // 줄 바꿈
                buffer.append(10)
                i += 1
            case 24:  // 하이픈
                buffer.append(UInt16(UInt8(ascii: "-")))
                i += 1
            case 30, 31:  // 묶음 빈칸, 고정폭 빈칸
                buffer.append(0x20)
                i += 1
            case 9:  // 탭 (inline, 8칸)
                buffer.append(9)
                i += 8
            case 4...8, 19, 20:  // 기타 inline
                i += 8
            case 1...3, 11, 12, 14...18, 21...23:  // extended: 컨트롤 객체를 하나 소비
                flush()
                if let control = controls.popFirst() { handle(control, in: paragraph) }
                i += 8
            default:  // 13 문단 끝, 0·25–29 예약
                i += 1
            }
        }
        flush()
        // 텍스트에서 짝을 못 찾은 컨트롤도 내용은 버리지 않는다
        for control in controls { handle(control, in: paragraph) }
        return paragraph.items()
    }

    private func charShapePositions(_ node: RecordNode) -> [(position: Int, id: Int)] {
        guard let record = node.children.first(where: { $0.tag == HWPTag.paraCharShape }) else { return [] }
        let reader = ByteReader(record.payload)
        return stride(from: 0, to: record.payload.count - 7, by: 8).compactMap { offset in
            guard let position = try? reader.u32(at: offset), let id = try? reader.u32(at: offset + 4) else { return nil }
            return (Int(position), Int(id))
        }.sorted { $0.position < $1.position }
    }

    // MARK: 컨트롤

    private func handle(_ control: RecordNode, in paragraph: ParagraphBuilder) {
        switch control.ctrlID {
        case "tbl ":
            let (table, caption) = self.table(control)
            paragraph.segments.append(.block(.table(table)))
            paragraph.trailing += caption
        case "gso ":
            let (images, text) = shape(control)
            paragraph.segments += images.map(Segment.block)
            paragraph.trailing += text
        case "eqed":
            if let script = equationScript(control) { paragraph.appendEquation(script) }
        case "form":
            if let text = formText(control) { paragraph.appendText(text) }
        default:
            // 머리말·꼬리말·각주·미주·숨은 설명 등: 안의 문단 리스트를 문단 뒤에 붙인다.
            // 구역·단 정의, 필드, 쪽 번호 같은 컨트롤은 문단 리스트가 없어 아무것도 나오지 않는다.
            paragraph.trailing += paragraphLists(control.children).flatMap(blocks(of:))
        }
    }

    /// LIST_HEADER로 시작해 이어지는 PARA_HEADER 묶음들
    private func paragraphLists(_ nodes: [RecordNode]) -> [[RecordNode]] {
        var lists: [[RecordNode]] = []
        for node in nodes {
            if node.tag == HWPTag.listHeader {
                lists.append([])
            } else if node.tag == HWPTag.paraHeader {
                if lists.isEmpty { lists.append([]) }
                lists[lists.count - 1].append(node)
            }
        }
        return lists
    }

    /// 표: TABLE 레코드 뒤의 LIST_HEADER(셀 속성 포함) + 문단들. TABLE 앞의 리스트는 캡션.
    private func table(_ control: RecordNode) -> (Table, caption: [Block]) {
        var cells: [(row: Int, col: Int, cell: Cell)] = []
        var caption: [RecordNode] = []
        var seenTable = false
        var current: (row: Int, col: Int, cell: Cell, paragraphs: [RecordNode])?

        func finishCell() {
            guard let c = current else { return }
            var cell = c.cell
            cell.blocks = blocks(of: c.paragraphs)
            cells.append((c.row, c.col, cell))
            current = nil
        }

        for node in control.children {
            switch node.tag {
            case HWPTag.table:
                seenTable = true
            case HWPTag.listHeader where seenTable:
                finishCell()
                // ⚠ 문단 수가 실제로는 4바이트라 셀 속성은 @8부터 (표 80)
                let r = ByteReader(node.payload)
                let col = Int((try? r.u16(at: 8)) ?? 0)
                let row = Int((try? r.u16(at: 10)) ?? 0)
                let colSpan = max(Int((try? r.u16(at: 12)) ?? 1), 1)
                let rowSpan = max(Int((try? r.u16(at: 14)) ?? 1), 1)
                let width = (try? r.u32(at: 16)).map { Double($0) / 100 }
                current = (row, col, Cell(colSpan: colSpan, rowSpan: rowSpan, width: width), [])
            case HWPTag.paraHeader:
                if current != nil { current?.paragraphs.append(node) } else if !seenTable { caption.append(node) }
            default:
                break
            }
        }
        finishCell()

        let rows = Dictionary(grouping: cells, by: \.row)
            .sorted { $0.key < $1.key }
            .map { $0.value.sorted { $0.col < $1.col }.map(\.cell) }
        return (Table(rows: rows), blocks(of: caption))
    }

    /// 그리기 개체: 그림은 인라인 블록, 글상자 문단은 문단 뒤로. 묶음 개체는 재귀.
    private func shape(_ control: RecordNode) -> (images: [Block], text: [Block]) {
        var pictures: [RecordNode] = []
        var text: [Block] = []

        func walk(_ nodes: [RecordNode]) {
            for list in paragraphLists(nodes) { text += blocks(of: list) }
            for node in nodes where node.tag != HWPTag.paraHeader {
                if node.tag == HWPTag.shapeComponentPicture { pictures.append(node) }
                walk(node.children)
            }
        }
        walk(control.children)

        // 그림이 하나뿐이면 개체 크기(공통 속성 폭 @16, 높이 @20, HWPUNIT)를 그림 크기로 쓴다
        var size: ImageSize?
        let header = ByteReader(control.payload)
        if pictures.count == 1, let w = try? header.u32(at: 16), let h = try? header.u32(at: 20), w > 0, h > 0 {
            size = ImageSize(width: Double(w) / 100, height: Double(h) / 100)
        }

        let images = pictures.compactMap { picture -> Block? in
            guard let id = try? ByteReader(picture.payload).u16(at: 71),
                  let item = docInfo.binItems[Int(id)] else { return nil }
            return .image(ImageRef(sourceID: item.path, size: size))
        }
        return (images, text)
    }

    private func equationScript(_ control: RecordNode) -> String? {
        guard let record = control.children.first(where: { $0.tag == HWPTag.eqEdit }) else { return nil }
        var reader = ByteReader(record.payload, offset: 4)
        let script = (try? reader.lengthPrefixedString())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return script.isEmpty ? nil : script
    }

    /// 양식 개체: 체크박스·라디오는 ☑/☐ + 캡션, 그 밖에는 입력된 텍스트나 캡션.
    private func formText(_ control: RecordNode) -> String? {
        guard let record = control.children.first(where: { $0.tag == HWPTag.formObject }),
              record.payload.count > 12 else { return nil }
        let type = String(decoding: record.payload[0..<4].reversed(), as: UTF8.self)
        let props = String(decoding: Array(record.payload[12...]).utf16Units, as: UTF16.self)

        let caption = Self.formString(props, key: "Caption") ?? ""
        switch type {
        case "+cbt", "+rbt":
            let checked = props.contains("Value:int:1")
            return (checked ? "☑" : "☐") + caption
        default:
            let value = Self.formString(props, key: "Text") ?? caption
            return value.isEmpty ? nil : value
        }
    }

    /// "Key:wstring:길이:값" 에서 값
    static func formString(_ props: String, key: String) -> String? {
        guard let range = props.range(of: "\(key):wstring:") else { return nil }
        let rest = props[range.upperBound...]
        guard let colon = rest.firstIndex(of: ":"), let length = Int(rest[..<colon]) else { return nil }
        return String(rest[rest.index(after: colon)...].prefix(length))
    }
}
