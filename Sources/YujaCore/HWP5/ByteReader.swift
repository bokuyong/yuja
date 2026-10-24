import Foundation

/// 리틀엔디언 바이트 읽기. 범위를 벗어나면 crash 대신 YujaError.corrupted를 던진다.
struct ByteReader {
    let bytes: [UInt8]
    var offset: Int

    init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    var remaining: Int { max(bytes.count - offset, 0) }

    mutating func u8() throws -> UInt8 {
        try need(1)
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u16() throws -> UInt16 {
        defer { offset += 2 }
        return try u16(at: offset)
    }

    mutating func u32() throws -> UInt32 {
        defer { offset += 4 }
        return try u32(at: offset)
    }

    mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        try need(count)
        defer { offset += count }
        return bytes[offset..<(offset + count)]
    }

    mutating func skip(_ count: Int) throws {
        try need(count)
        offset += count
    }

    /// WORD 길이 + WCHAR[길이] 문자열
    mutating func lengthPrefixedString() throws -> String {
        let length = Int(try u16())
        let raw = try take(length * 2)
        let units = stride(from: raw.startIndex, to: raw.endIndex, by: 2).map {
            UInt16(raw[$0]) | UInt16(raw[$0 + 1]) << 8
        }
        return String(decoding: units, as: UTF16.self)
    }

    func u16(at position: Int) throws -> UInt16 {
        try need(2, at: position)
        return UInt16(bytes[position]) | UInt16(bytes[position + 1]) << 8
    }

    func u32(at position: Int) throws -> UInt32 {
        try need(4, at: position)
        return UInt32(bytes[position]) | UInt32(bytes[position + 1]) << 8
            | UInt32(bytes[position + 2]) << 16 | UInt32(bytes[position + 3]) << 24
    }

    private func need(_ count: Int, at position: Int? = nil) throws {
        let start = position ?? offset
        guard count >= 0, start >= 0, start + count <= bytes.count else {
            throw YujaError.corrupted("데이터가 예상보다 짧습니다 (위치 \(start), \(count)바이트 필요)")
        }
    }
}

extension Array where Element == UInt8 {
    /// UTF-16LE 바이트 → WCHAR 배열
    var utf16Units: [UInt16] {
        stride(from: 0, to: count - 1, by: 2).map { UInt16(self[$0]) | UInt16(self[$0 + 1]) << 8 }
    }
}
