import Foundation

/// DocInfo 스트림에서 변환에 쓰는 것만: 글자모양·문단모양(HWPX와 같은 HeaderStyles로), 바이너리 데이터 목록.
struct HWPDocInfo {
    struct BinItem {
        /// CFB 경로. 예: "BinData/BIN0001.png"
        var path: String
        /// 항목별 압축 설정 (nil = 문서 기본값)
        var compressed: Bool?
    }

    var styles = HeaderStyles()
    /// 그림이 참조하는 번호(1부터) → 바이너리 항목. LINK(외부 파일)는 nil.
    var binItems: [Int: BinItem] = [:]

    static func parse(_ data: Data) throws -> HWPDocInfo {
        var info = HWPDocInfo()
        var charIndex = 0, paraIndex = 0, binIndex = 0

        for record in try HWPRecord.parse(data) {
            switch record.tag {
            case HWPTag.charShape:
                info.styles.charShapes[charIndex] = charShape(record.payload)
                charIndex += 1
            case HWPTag.paraShape:
                info.styles.paraShapes[paraIndex] = paraShape(record.payload)
                paraIndex += 1
            case HWPTag.binData:
                binIndex += 1
                info.binItems[binIndex] = try? binItem(record.payload)
            default:
                break
            }
        }
        return info
    }

    /// 표 33·35: 속성 UINT32 @46
    static func charShape(_ payload: [UInt8]) -> CharShape {
        guard let props = try? ByteReader(payload).u32(at: 46) else { return CharShape() }
        return CharShape(
            bold: props & (1 << 1) != 0,
            italic: props & 1 != 0,
            underline: (props >> 2) & 0x3 != 0,
            strike: (props >> 18) & 0x7 != 0
        )
    }

    /// 표 43·44: 속성1 UINT32 @0
    static func paraShape(_ payload: [UInt8]) -> ParaShape {
        guard let props = try? ByteReader(payload).u32(at: 0) else { return ParaShape() }
        var shape = ParaShape()
        switch (props >> 2) & 0x7 {
        case 0, 4, 5: shape.align = .justify
        case 1: shape.align = .left
        case 2: shape.align = .right
        case 3: shape.align = .center
        default: shape.align = nil
        }
        switch (props >> 23) & 0x3 {
        case 1: shape.heading = .outline
        case 2: shape.heading = .number
        case 3: shape.heading = .bullet
        default: shape.heading = .none
        }
        shape.level = Int((props >> 25) & 0x7)
        return shape
    }

    /// 표 17·18. EMBEDDING만 다룬다 (LINK는 파일 밖, STORAGE는 OLE).
    static func binItem(_ payload: [UInt8]) throws -> BinItem? {
        var reader = ByteReader(payload)
        let props = try reader.u16()
        guard props & 0xF == 1 else { return nil }
        let storageID = try reader.u16()
        let ext = try reader.lengthPrefixedString().lowercased()

        let compressed: Bool?
        switch props & 0x30 {
        case 0x10: compressed = true
        case 0x20: compressed = false
        default: compressed = nil
        }
        return BinItem(path: String(format: "BinData/BIN%04X.%@", storageID, ext), compressed: compressed)
    }
}
