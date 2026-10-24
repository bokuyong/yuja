import Foundation

/// MS-CFB (OLE2 Compound File) 읽기 전용 구현. HWP 5.0의 컨테이너.
///
/// 섹터 체인·디렉터리 트리는 손상된 파일에서 순환할 수 있으므로 방문 기록으로 끊는다.
struct CompoundFile {
    static let magic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]

    private static let endOfChain: UInt32 = 0xFFFF_FFFE
    private static let noStream: UInt32 = 0xFFFF_FFFF

    private struct Entry {
        var name: String
        var type: UInt8  // 1 스토리지, 2 스트림, 5 루트
        var left, right, child: UInt32
        var start: UInt32
        var size: Int
    }

    private let bytes: [UInt8]
    private let sectorSize: Int
    private let miniSectorSize: Int
    private let miniCutoff: Int
    private let fat: [UInt32]
    private let miniFat: [UInt32]
    private let miniStream: [UInt8]
    /// 소문자 경로 → (원래 경로, 엔트리). CFB 이름은 대소문자를 구분하지 않는다.
    private let streams: [String: (path: String, entry: Entry)]

    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        self.bytes = bytes
        guard bytes.count >= 512, Array(bytes[0..<8]) == Self.magic else {
            throw YujaError.unsupportedFormat("복합 문서(CFB) 형식이 아닙니다")
        }
        let header = ByteReader(bytes)
        let sectorShift = Int(try header.u16(at: 30))
        let miniShift = Int(try header.u16(at: 32))
        guard (7...16).contains(sectorShift), (1...sectorShift).contains(miniShift) else {
            throw YujaError.corrupted("CFB 섹터 크기가 잘못되었습니다")
        }
        sectorSize = 1 << sectorShift
        miniSectorSize = 1 << miniShift
        miniCutoff = Int(try header.u32(at: 56))

        let fatSectorCount = Int(try header.u32(at: 44))
        let directoryStart = try header.u32(at: 48)
        let miniFatStart = try header.u32(at: 60)
        var difatSector = try header.u32(at: 68)
        let difatCount = Int(try header.u32(at: 72))

        // DIFAT: 헤더의 109개 + 추가 DIFAT 섹터들
        var difat: [UInt32] = []
        for i in 0..<109 { difat.append(try header.u32(at: 76 + i * 4)) }
        var seenDifat = Set<UInt32>()
        var remainingDifat = difatCount
        while remainingDifat > 0, difatSector < Self.endOfChain, seenDifat.insert(difatSector).inserted {
            remainingDifat -= 1
            let sector = try Self.sector(bytes, difatSector, sectorSize)
            let perSector = sectorSize / 4 - 1
            for i in 0..<perSector { difat.append(try sector.u32(at: sector.offset + i * 4)) }
            difatSector = try sector.u32(at: sector.offset + perSector * 4)
        }

        var fat: [UInt32] = []
        for index in difat.prefix(fatSectorCount) where index < Self.endOfChain {
            let sector = try Self.sector(bytes, index, sectorSize)
            for i in 0..<(sectorSize / 4) { fat.append(try sector.u32(at: sector.offset + i * 4)) }
        }
        self.fat = fat

        let directory = try Self.readChain(bytes, start: directoryStart, table: fat, sectorSize: sectorSize)
        var entries: [Entry] = []
        for offset in stride(from: 0, to: directory.count - 127, by: 128) {
            let e = ByteReader(directory, offset: offset)
            let nameLength = Int(try e.u16(at: offset + 64))
            let units = Array(directory[offset..<(offset + min(max(nameLength - 2, 0), 64))]).utf16Units
            entries.append(Entry(
                name: String(decoding: units, as: UTF16.self),
                type: directory[offset + 66],
                left: try e.u32(at: offset + 68), right: try e.u32(at: offset + 72), child: try e.u32(at: offset + 76),
                start: try e.u32(at: offset + 116),
                size: Int(try e.u32(at: offset + 120))  // v3는 하위 32비트만 유효. 4GB 넘는 HWP는 없다
            ))
        }
        guard let root = entries.first else { throw YujaError.corrupted("CFB 디렉터리가 비어 있습니다") }

        miniStream = Array(try Self.readChain(bytes, start: root.start, table: fat, sectorSize: sectorSize).prefix(root.size))
        let miniFatBytes = try Self.readChain(bytes, start: miniFatStart, table: fat, sectorSize: sectorSize)
        miniFat = miniFatBytes.isEmpty ? [] : (0..<(miniFatBytes.count / 4)).map {
            UInt32(miniFatBytes[$0 * 4]) | UInt32(miniFatBytes[$0 * 4 + 1]) << 8
                | UInt32(miniFatBytes[$0 * 4 + 2]) << 16 | UInt32(miniFatBytes[$0 * 4 + 3]) << 24
        }

        // 디렉터리 트리를 경로로 펼친다 (형제는 red-black 트리의 left/right, 자식은 child)
        var streams: [String: (path: String, entry: Entry)] = [:]
        var stack: [(index: UInt32, prefix: String)] = [(root.child, "")]
        var visited = Set<UInt32>()
        while let (index, prefix) = stack.popLast() {
            guard index != Self.noStream, Int(index) < entries.count, visited.insert(index).inserted else { continue }
            let entry = entries[Int(index)]
            stack.append((entry.left, prefix))
            stack.append((entry.right, prefix))
            let path = prefix + entry.name
            if entry.type == 2 {
                streams[path.lowercased()] = (path, entry)
            } else if entry.type == 1 {
                stack.append((entry.child, path + "/"))
            }
        }
        self.streams = streams
    }

    /// 모든 스트림 경로 (예: "BodyText/Section0"), 정렬됨
    var streamPaths: [String] { streams.values.map(\.path).sorted() }

    func contains(_ path: String) -> Bool { streams[path.lowercased()] != nil }

    /// 스트림 내용. 없으면 nil.
    func stream(_ path: String) throws -> Data? {
        guard let entry = streams[path.lowercased()]?.entry else { return nil }
        let raw: [UInt8]
        if entry.size < miniCutoff {
            raw = try Self.readChain(miniStream, start: entry.start, table: miniFat, sectorSize: miniSectorSize, mini: true)
        } else {
            raw = try Self.readChain(bytes, start: entry.start, table: fat, sectorSize: sectorSize)
        }
        guard raw.count >= entry.size else { throw YujaError.corrupted("\(path) 스트림이 잘렸습니다") }
        return Data(raw.prefix(entry.size))
    }

    // MARK: -

    private static func sector(_ bytes: [UInt8], _ index: UInt32, _ size: Int) throws -> ByteReader {
        let start = (Int(index) + 1) * size  // 섹터 0은 헤더 다음 (v4는 헤더도 4096바이트)
        guard start + size <= bytes.count else { throw YujaError.corrupted("CFB 섹터 \(index)가 파일 밖을 가리킵니다") }
        return ByteReader(bytes, offset: start)
    }

    private static func readChain(_ bytes: [UInt8], start: UInt32, table: [UInt32], sectorSize: Int,
                                  mini: Bool = false) throws -> [UInt8] {
        var out: [UInt8] = []
        var index = start
        var visited = Set<UInt32>()
        while index < 0xFFFF_FFFA {  // 그 이상은 체인 끝·빈 섹터 등 특수값
            guard Int(index) < table.count else { throw YujaError.corrupted("CFB 섹터 체인이 할당표 밖을 가리킵니다") }
            guard visited.insert(index).inserted else { throw YujaError.corrupted("CFB 섹터 체인이 순환합니다") }
            let begin = mini ? Int(index) * sectorSize : (Int(index) + 1) * sectorSize
            guard begin < bytes.count else { throw YujaError.corrupted("CFB 섹터가 파일 밖을 가리킵니다") }
            // 마지막 섹터가 잘린 파일도 있으므로 파일 끝까지만 읽는다
            out.append(contentsOf: bytes[begin..<min(begin + sectorSize, bytes.count)])
            index = table[Int(index)]
        }
        return out
    }
}
