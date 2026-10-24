import CommonCrypto
import Foundation

/// HWP 레코드 태그 (HWPTAG_BEGIN = 0x10 기준)
enum HWPTag {
    static let binData: UInt16 = 0x10 + 2
    static let charShape: UInt16 = 0x10 + 5
    static let paraShape: UInt16 = 0x10 + 9
    static let distributeDocData: UInt16 = 0x10 + 12

    static let paraHeader: UInt16 = 0x10 + 50
    static let paraText: UInt16 = 0x10 + 51
    static let paraCharShape: UInt16 = 0x10 + 52
    static let ctrlHeader: UInt16 = 0x10 + 55
    static let listHeader: UInt16 = 0x10 + 56
    static let shapeComponent: UInt16 = 0x10 + 60
    static let table: UInt16 = 0x10 + 61
    static let shapeComponentPicture: UInt16 = 0x10 + 69
    static let eqEdit: UInt16 = 0x10 + 72
    static let formObject: UInt16 = 0x10 + 75
}

struct HWPRecord {
    let tag: UInt16
    let level: Int
    let payload: [UInt8]

    /// 레코드 헤더: TagID 10bit | Level 10bit | Size 12bit (0xFFF면 다음 DWORD가 크기)
    static func parse(_ data: Data) throws -> [HWPRecord] {
        let bytes = [UInt8](data)
        var reader = ByteReader(bytes)
        var out: [HWPRecord] = []
        while reader.remaining >= 4 {
            let header = try reader.u32()
            var size = Int(header >> 20)
            if size == 0xFFF { size = Int(try reader.u32()) }
            guard size <= reader.remaining else {
                throw YujaError.corrupted("레코드 크기(\(size))가 남은 데이터(\(reader.remaining))보다 큽니다")
            }
            out.append(HWPRecord(tag: UInt16(header & 0x3FF), level: Int((header >> 10) & 0x3FF),
                                 payload: Array(try reader.take(size))))
        }
        return out
    }
}

/// 레벨로 만든 레코드 트리. 자식 = 바로 뒤에 오는, 레벨이 더 큰 레코드들.
final class RecordNode {
    let record: HWPRecord
    var children: [RecordNode] = []

    init(_ record: HWPRecord) { self.record = record }

    var tag: UInt16 { record.tag }
    var payload: [UInt8] { record.payload }

    /// 컨트롤 ID (CTRL_HEADER 앞 4바이트, MAKE_4CHID 정수를 문자로) 예: "tbl ", "gso "
    var ctrlID: String {
        guard payload.count >= 4 else { return "" }
        return String(decoding: payload[0..<4].reversed(), as: UTF8.self)
    }

    static func tree(_ records: [HWPRecord]) -> [RecordNode] {
        var roots: [RecordNode] = []
        var stack: [RecordNode] = []
        for record in records {
            let node = RecordNode(record)
            while let last = stack.last, last.record.level >= record.level { stack.removeLast() }
            if let parent = stack.last { parent.children.append(node) } else { roots.append(node) }
            stack.append(node)
        }
        return roots
    }
}

enum HWPStream {
    /// raw deflate (zlib 헤더 없음) 해제
    static func inflate(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return data }
        do {
            return try (data as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw YujaError.corrupted("압축을 풀 수 없습니다")
        }
    }

    /// 배포용 문서의 ViewText/SectionN 스트림 복호화.
    ///
    /// 한컴 공개 스펙에는 없는 부분으로, hwp-rs(Apache-2.0, Han Lee)의 구현을 참고했다.
    /// 첫 레코드(DISTRIBUTE_DOC_DATA 256B)에서 MSVC rand() 마스크로 AES-128 키를 꺼내고,
    /// 나머지를 AES-128-ECB로 푼다.
    static func decryptDistributed(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        var reader = ByteReader(bytes)
        let header = try reader.u32()
        let size = Int(header >> 20)
        guard UInt16(header & 0x3FF) == HWPTag.distributeDocData, size == 256 else {
            throw YujaError.corrupted("배포용 문서 데이터 레코드가 없습니다")
        }
        let key = distributionKey(Array(try reader.take(256)))
        let encrypted = Array(bytes[reader.offset...])
        return try aes128ECBDecrypt(Array(encrypted.prefix(encrypted.count / 16 * 16)), key: key)
    }

    static func distributionKey(_ record: [UInt8]) -> [UInt8] {
        let seed = UInt32(record[0]) | UInt32(record[1]) << 8 | UInt32(record[2]) << 16 | UInt32(record[3]) << 24
        var mask = [UInt8]()
        mask.reserveCapacity(256)
        var random = MSVCRandom(seed: seed)
        while mask.count < 256 {
            let fill = UInt8(random.next() & 0xFF)
            let times = Int(random.next() & 0x0F) + 1
            mask += Array(repeating: fill, count: min(times, 256 - mask.count))
        }
        let decoded = zip(record, mask).map { $0 ^ $1 }
        let offset = 4 + Int(seed & 0xF)
        return Array(decoded[offset..<(offset + 16)])
    }

    static func aes128ECBDecrypt(_ input: [UInt8], key: [UInt8]) throws -> Data {
        guard !input.isEmpty else { return Data() }
        var output = [UInt8](repeating: 0, count: input.count)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                             key, key.count, nil, input, input.count, &output, output.count, &moved)
        guard status == kCCSuccess else { throw YujaError.corrupted("배포용 문서를 복호화할 수 없습니다") }
        return Data(output.prefix(moved))
    }
}

/// MSVC rand()와 같은 선형 합동 생성기 (배포용 문서 키 마스크 전용)
struct MSVCRandom {
    private var state: UInt32

    init(seed: UInt32) { state = seed }

    mutating func next() -> UInt32 {
        state = state &* 214_013 &+ 2_531_011
        return (state >> 16) & 0x7FFF
    }
}
