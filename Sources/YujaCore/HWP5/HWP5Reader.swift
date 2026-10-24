import Foundation

public enum HWP5Reader {
    static let signature = "HWP Document File"

    struct FileHeader {
        var version: (major: Int, minor: Int, build: Int, revision: Int)
        var compressed: Bool
        var distributed: Bool

        /// 표 3. 지원하지 않는 보호 방식이면 바로 에러.
        init(_ data: Data) throws {
            let bytes = [UInt8](data)
            guard bytes.count >= 40,
                  String(decoding: bytes[0..<17], as: UTF8.self) == HWP5Reader.signature else {
                throw YujaError.unsupportedFormat("HWP 문서가 아닌 복합 문서(CFB) 파일입니다")
            }
            let reader = ByteReader(bytes)
            let v = try reader.u32(at: 32)
            version = (Int(v >> 24), Int((v >> 16) & 0xFF), Int((v >> 8) & 0xFF), Int(v & 0xFF))
            guard version.major == 5 else {
                throw YujaError.unsupportedFormat("HWP \(version.major).x 문서는 지원하지 않습니다 (5.x만 지원)")
            }
            let flags = try reader.u32(at: 36)
            if flags & (1 << 1) != 0 { throw YujaError.encrypted }
            if flags & (1 << 4 | 1 << 8 | 1 << 10) != 0 { throw YujaError.drmProtected }
            compressed = flags & 1 != 0
            distributed = flags & (1 << 2) != 0
        }
    }

    public static func read(_ url: URL) throws -> LoadedDocument {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw YujaError.fileNotFound(url.path)
        }
        return try read(data)
    }

    static func read(_ data: Data) throws -> LoadedDocument {
        let cfb = try CompoundFile(data)
        guard let headerData = try cfb.stream("FileHeader") else {
            throw YujaError.unsupportedFormat("HWP 문서가 아닌 복합 문서(CFB) 파일입니다")
        }
        let header = try FileHeader(headerData)

        func decode(_ raw: Data) throws -> Data { header.compressed ? try HWPStream.inflate(raw) : raw }

        guard let docInfoRaw = try cfb.stream("DocInfo") else { throw YujaError.corrupted("DocInfo 스트림이 없습니다") }
        let docInfo = try HWPDocInfo.parse(decode(docInfoRaw))

        // 배포용 문서는 BodyText가 비어 있고 ViewText에 암호화된 본문이 있다
        let storage = header.distributed ? "ViewText" : "BodyText"
        let parser = HWPBodyParser(docInfo: docInfo)
        var sections: [Section] = []
        var index = 0
        while let raw = try cfb.stream("\(storage)/Section\(index)") {
            let plain = header.distributed ? try HWPStream.decryptDistributed(raw) : raw
            sections.append(parser.parse(try HWPRecord.parse(decode(plain))))
            index += 1
        }
        guard !sections.isEmpty else { throw YujaError.corrupted("본문(\(storage)/Section0)이 없습니다") }

        let resources = HWP5Resources(cfb: cfb, items: docInfo.binItems, compressedByDefault: header.compressed)
        return LoadedDocument(document: Document(meta: Meta(sourceFormat: .hwp5), sections: sections), resources: resources)
    }
}

/// BinData 스트림 제공. 항목별 압축 설정을 따르고, 풀리지 않으면 원본 바이트를 그대로 쓴다.
final class HWP5Resources: ResourceProvider {
    private let cfb: CompoundFile
    private let compression: [String: Bool]

    init(cfb: CompoundFile, items: [Int: HWPDocInfo.BinItem], compressedByDefault: Bool) {
        self.cfb = cfb
        var compression: [String: Bool] = [:]
        for item in items.values { compression[item.path.lowercased()] = item.compressed ?? compressedByDefault }
        self.compression = compression
    }

    func data(for sourceID: String) throws -> Data {
        guard let raw = try cfb.stream(sourceID) else {
            throw YujaError.corrupted("내장 파일이 없습니다: \(sourceID)")
        }
        guard compression[sourceID.lowercased()] == true else { return raw }
        return (try? HWPStream.inflate(raw)) ?? raw
    }
}
