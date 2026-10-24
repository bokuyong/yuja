import CommonCrypto
import Foundation
@testable import YujaCore

/// 테스트용 HWP 5.0 작성기. 문단 DSL → 레코드 → (압축·배포용 암호화) → CFB.
///
/// 글자모양·문단모양 번호는 HWPX 픽스처 `_common/Contents/header.xml`과 같게 맞췄다
/// (교차 테스트에서 같은 IR이 나와야 하므로).
///   글자모양 0 보통, 1 굵게, 2 기울임, 3 굵게+밑줄, 4 취소선
///   문단모양 0 바탕글, 1 개요1, 2 개요2, 3 글머리표1, 4 글머리표2, 5 번호1, 6 가운데
struct HWPFixture {
    struct Paragraph {
        var shape = 0
        var pageBreak = false
        var pieces: [Piece]

        init(shape: Int = 0, pageBreak: Bool = false, _ pieces: Piece...) {
            self.shape = shape
            self.pageBreak = pageBreak
            self.pieces = pieces
        }
    }

    struct CellSpec {
        var paragraphs: [Paragraph]
        var colSpan = 1, rowSpan = 1
        /// HWPUNIT
        var width: UInt32 = 0
    }

    indirect enum Piece {
        case text(String, charShape: Int = 0)
        case lineBreak
        case tab
        /// 행 → 셀. 주소는 병합을 고려해 자동 계산
        case table([[CellSpec]])
        case equation(String)
        /// BinData 번호들. 둘 이상이면 묶음 개체
        case pictures([Int], width: UInt32 = 0, height: UInt32 = 0)
        case checkbox(checked: Bool, caption: String)
        case footnote([Paragraph])
        case header([Paragraph])
        /// 누름틀 등 필드: 시작·끝 제어 문자 사이에 표시 텍스트
        case field(String)
    }

    var paragraphs: [Paragraph]
    /// (확장자, 내용)
    var binData: [(ext: String, data: Data)] = []
    var compressed = true
    var distributed = false
    /// FileHeader 속성 비트를 직접 지정 (암호·DRM 테스트용)
    var extraFlags: UInt32 = 0

    func build() -> Data {
        let header = fileHeader()
        let docInfo = encode(docInfoRecords())
        var section = encode(sectionRecords())
        if distributed { section = Self.distribute(section) }

        var streams: [String: Data] = [
            "FileHeader": header,
            "DocInfo": docInfo,
            (distributed ? "ViewText/Section0" : "BodyText/Section0"): section,
        ]
        if distributed { streams["BodyText/Section0"] = Data() }
        for (i, item) in binData.enumerated() {
            let name = String(format: "BinData/BIN%04X.%@", i + 1, item.ext)
            streams[name] = compressed ? Self.deflate(item.data) : item.data
        }
        return CFBWriter.build(streams)
    }

    // MARK: 스트림

    private func fileHeader() -> Data {
        var out = Data("HWP Document File".utf8)
        out.append(Data(count: 32 - out.count))
        var flags: UInt32 = (compressed ? 1 : 0) | (distributed ? 1 << 2 : 0) | extraFlags
        var version: UInt32 = 0x0501_0001
        withUnsafeBytes(of: &version) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &flags) { out.append(contentsOf: $0) }
        out.append(Data(count: 256 - out.count))
        return out
    }

    private func encode(_ records: [Rec]) -> Data {
        var out = Data()
        for r in records {
            let size = r.payload.count
            let header = UInt32(r.tag) | UInt32(r.level) << 10 | UInt32(min(size, 0xFFF)) << 20
            out.append(le32(header))
            if size >= 0xFFF { out.append(le32(UInt32(size))) }
            out.append(r.payload)
        }
        return compressed ? Self.deflate(out) : out
    }

    private struct Rec {
        var tag: UInt16
        var level: Int
        var payload: Data
    }

    private func docInfoRecords() -> [Rec] {
        var records: [Rec] = []
        for (i, item) in binData.enumerated() {
            var p = Data()
            p.append(le16(0x0001))  // EMBEDDING, 압축은 문서 기본값
            p.append(le16(UInt16(i + 1)))
            p.append(wstring(item.ext))
            records.append(Rec(tag: HWPTag.binData, level: 1, payload: p))
        }
        // 글자모양: 속성 @46 (bit0 기울임, bit1 진하게, bit2-3 밑줄, bit18-20 취소선)
        for props: UInt32 in [0, 1 << 1, 1, 1 << 1 | 1 << 2, 1 << 18] {
            var p = Data(count: 46)
            p.append(le32(props))
            p.append(Data(count: 72 - p.count))
            records.append(Rec(tag: HWPTag.charShape, level: 1, payload: p))
        }
        // 문단모양: 속성1 @0 (bit2-4 정렬, bit23-24 머리 모양, bit25-27 수준)
        let shapes: [(align: UInt32, head: UInt32, level: UInt32)] = [
            (0, 0, 0), (1, 1, 0), (1, 1, 1), (1, 3, 0), (1, 3, 1), (1, 2, 0), (3, 0, 0),
        ]
        for s in shapes {
            var p = le32(s.align << 2 | s.head << 23 | s.level << 25)
            p.append(Data(count: 54 - p.count))
            records.append(Rec(tag: HWPTag.paraShape, level: 1, payload: p))
        }
        return records
    }

    private func sectionRecords() -> [Rec] {
        paragraphs.flatMap { paragraphRecords($0, level: 0) }
    }

    // MARK: 문단

    private func paragraphRecords(_ paragraph: Paragraph, level: Int) -> [Rec] {
        var units: [UInt16] = []
        var shapes: [(pos: UInt32, id: UInt32)] = []
        var controls: [[Rec]] = []

        func setShape(_ id: Int) {
            if shapes.last?.id != UInt32(id) { shapes.append((UInt32(units.count), UInt32(id))) }
        }
        func control(_ code: UInt16, _ id: String) {
            let v = fourCC(id)
            units += [code, UInt16(v & 0xFFFF), UInt16(v >> 16), 0, 0, 0, 0, code]
        }

        setShape(0)
        for piece in paragraph.pieces {
            switch piece {
            case .text(let text, let charShape):
                setShape(charShape)
                units += Array(text.utf16)
            case .lineBreak:
                units.append(10)
            case .tab:
                units += [9, 0, 0, 0, 0, 0, 0, 9]
            case .field(let text):
                control(3, "%clk")
                controls.append([Rec(tag: HWPTag.ctrlHeader, level: level + 1, payload: le32(fourCC("%clk")) + Data(count: 11))])
                units += Array(text.utf16)
                units += [4, 0, 0, 0, 0, 0, 0, 4]
            case .table(let rows):
                control(11, "tbl ")
                controls.append(tableRecords(rows, level: level + 1))
            case .equation(let script):
                control(11, "eqed")
                var eq = le32(0)
                eq.append(wstring(script))
                eq.append(Data(count: 10))
                controls.append([
                    Rec(tag: HWPTag.ctrlHeader, level: level + 1, payload: commonProps("eqed", 1000, 500)),
                    Rec(tag: HWPTag.eqEdit, level: level + 2, payload: eq),
                ])
            case .pictures(let ids, let width, let height):
                control(11, "gso ")
                var recs = [Rec(tag: HWPTag.ctrlHeader, level: level + 1, payload: commonProps("gso ", width, height))]
                let pictureLevel = ids.count > 1 ? level + 3 : level + 2
                if ids.count > 1 {
                    recs.append(Rec(tag: HWPTag.shapeComponent, level: level + 2, payload: le32(fourCC("$con")) + le32(fourCC("$con"))))
                }
                for id in ids {
                    recs.append(Rec(tag: HWPTag.shapeComponent, level: pictureLevel, payload: le32(fourCC("$pic")) + le32(fourCC("$pic"))))
                    var pic = Data(count: 71)
                    pic.append(le16(UInt16(id)))
                    pic.append(Data(count: 91 - pic.count))
                    recs.append(Rec(tag: HWPTag.shapeComponentPicture, level: pictureLevel + 1, payload: pic))
                }
                controls.append(recs)
            case .checkbox(let checked, let caption):
                control(11, "form")
                var form = Data([0x74, 0x62, 0x63, 0x2B, 0x74, 0x62, 0x63, 0x2B])  // "+cbt" 두 번 (리틀엔디언)
                let props = "CommonSet:set:10:Name:wstring:9:CheckBox1  ButtonSet:set:63:Caption:wstring:\(caption.utf16.count):\(caption) Value:int:\(checked ? 1 : 0) TriState:bool:0 "
                form.append(le32(UInt32(props.utf16.count * 2 + 2)))
                form.append(wstring(props))
                controls.append([
                    Rec(tag: HWPTag.ctrlHeader, level: level + 1, payload: commonProps("form", 1060, 1193)),
                    Rec(tag: HWPTag.formObject, level: level + 2, payload: form),
                ])
            case .footnote(let paragraphs), .header(let paragraphs):
                let isFootnote: Bool = { if case .footnote = piece { return true } else { return false } }()
                let id = isFootnote ? "fn  " : "head"
                control(isFootnote ? 17 : 16, id)
                var recs = [Rec(tag: HWPTag.ctrlHeader, level: level + 1, payload: le32(fourCC(id)) + Data(count: 8))]
                recs.append(Rec(tag: HWPTag.listHeader, level: level + 1 + 1, payload: le32(UInt32(paragraphs.count)) + le32(0) + Data(count: 8)))
                recs += paragraphs.flatMap { paragraphRecords($0, level: level + 2) }
                controls.append(recs)
            }
        }
        units.append(13)

        var header = le32(UInt32(units.count))
        header.append(le32(0))
        header.append(le16(UInt16(paragraph.shape)))
        header.append(Data([0, paragraph.pageBreak ? 0x04 : 0]))
        header.append(le16(UInt16(shapes.count)))
        header.append(Data(count: 24 - header.count))

        var shapePayload = Data()
        for s in shapes { shapePayload.append(le32(s.pos)); shapePayload.append(le32(s.id)) }

        return [
            Rec(tag: HWPTag.paraHeader, level: level, payload: header),
            Rec(tag: HWPTag.paraText, level: level + 1, payload: Data(units.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })),
            Rec(tag: HWPTag.paraCharShape, level: level + 1, payload: shapePayload),
        ] + controls.flatMap { $0 }
    }

    private func tableRecords(_ rows: [[CellSpec]], level: Int) -> [Rec] {
        // 병합을 고려한 셀 주소 계산 (TableGrid와 같은 규칙)
        var occupied = Set<[Int]>()
        var placed: [(row: Int, col: Int, cell: CellSpec)] = []
        for (r, row) in rows.enumerated() {
            var c = 0
            for cell in row {
                while occupied.contains([r, c]) { c += 1 }
                placed.append((r, c, cell))
                for dr in 0..<cell.rowSpan { for dc in 0..<cell.colSpan { occupied.insert([r + dr, c + dc]) } }
                c += cell.colSpan
            }
        }
        let cols = (occupied.map { $0[1] }.max() ?? 0) + 1

        var table = le32(0)
        table.append(le16(UInt16(rows.count)))
        table.append(le16(UInt16(cols)))
        table.append(Data(count: 28 - table.count))

        var recs = [
            Rec(tag: HWPTag.ctrlHeader, level: level, payload: commonProps("tbl ", 40000, 10000)),
            Rec(tag: HWPTag.table, level: level + 1, payload: table),
        ]
        for p in placed {
            var list = le32(UInt32(p.cell.paragraphs.count))
            list.append(le32(0))
            list.append(le16(UInt16(p.col)))
            list.append(le16(UInt16(p.row)))
            list.append(le16(UInt16(p.cell.colSpan)))
            list.append(le16(UInt16(p.cell.rowSpan)))
            list.append(le32(p.cell.width))
            list.append(le32(1000))
            list.append(Data(count: 47 - list.count))
            recs.append(Rec(tag: HWPTag.listHeader, level: level + 1, payload: list))
            recs += p.cell.paragraphs.flatMap { paragraphRecords($0, level: level + 1) }
        }
        return recs
    }

    // MARK: 도우미

    /// 개체 공통 속성 (표 69): ctrl ID, 속성, 오프셋 2개, 폭 @16, 높이 @20 …
    private func commonProps(_ id: String, _ width: UInt32, _ height: UInt32) -> Data {
        var p = le32(fourCC(id))
        p.append(le32(1))  // 글자처럼 취급
        p.append(le32(0)); p.append(le32(0))
        p.append(le32(width)); p.append(le32(height))
        p.append(Data(count: 46 - p.count))
        return p
    }

    /// MAKE_4CHID("tbl ") = 't'<<24 | 'b'<<16 | 'l'<<8 | ' '
    private func fourCC(_ s: String) -> UInt32 {
        s.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    private func wstring(_ s: String) -> Data {
        var d = le16(UInt16(s.utf16.count))
        for u in s.utf16 { d.append(le16(u)) }
        return d
    }

    static func deflate(_ data: Data) -> Data {
        (try? (data as NSData).compressed(using: .zlib) as Data) ?? data
    }

    /// 배포용 암호화 (리더의 역연산). 키를 심은 256B 레코드 + AES-128-ECB(0으로 16배수 채움).
    static func distribute(_ section: Data, seed: UInt32 = 0x1234_5679) -> Data {
        let key: [UInt8] = Array(0..<16).map { UInt8($0 * 7 + 3) }
        var mask: [UInt8] = []
        var random = MSVCRandom(seed: seed)
        while mask.count < 256 {
            let fill = UInt8(random.next() & 0xFF)
            let times = Int(random.next() & 0x0F) + 1
            mask += Array(repeating: fill, count: min(times, 256 - mask.count))
        }
        var plainRecord = [UInt8](repeating: 0xAB, count: 256)
        let offset = 4 + Int(seed & 0xF)
        plainRecord.replaceSubrange(offset..<(offset + 16), with: key)
        var record = zip(plainRecord, mask).map { $0 ^ $1 }
        withUnsafeBytes(of: seed.littleEndian) { record.replaceSubrange(0..<4, with: $0) }

        var plain = [UInt8](section)
        plain += [UInt8](repeating: 0, count: (16 - plain.count % 16) % 16)
        var encrypted = [UInt8](repeating: 0, count: plain.count)
        var moved = 0
        _ = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                    key, 16, nil, plain, plain.count, &encrypted, encrypted.count, &moved)

        var out = Data()
        out.append(le32(UInt32(HWPTag.distributeDocData) | 256 << 20))
        out.append(contentsOf: record)
        out.append(contentsOf: encrypted)
        return out
    }
}

private func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
private func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
