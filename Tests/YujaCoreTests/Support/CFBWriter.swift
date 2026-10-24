import Foundation

/// 테스트 픽스처용 최소 CFB(v3, 512B 섹터) 작성기. 4096바이트 미만 스트림은 mini stream에 넣는다.
/// 디렉터리 트리는 형제를 오른쪽으로만 잇는다 (읽기 쪽 검증용으로 충분).
enum CFBWriter {
    private static let sectorSize = 512
    private static let miniSectorSize = 64
    private static let cutoff = 4096
    private static let free: UInt32 = 0xFFFF_FFFF, endOfChain: UInt32 = 0xFFFF_FFFE, fatSect: UInt32 = 0xFFFF_FFFD

    private final class Node {
        var name: String
        var isStorage: Bool
        var data = Data()
        var children: [Node] = []
        var index = 0
        var start: UInt32 = 0xFFFF_FFFE
        init(_ name: String, storage: Bool) { self.name = name; self.isStorage = storage }
    }

    /// 경로("BodyText/Section0") → 내용
    static func build(_ streams: [String: Data]) -> Data {
        let root = Node("Root Entry", storage: true)
        for (path, data) in streams.sorted(by: { $0.key < $1.key }) {
            var parent = root
            let parts = path.split(separator: "/").map(String.init)
            for storage in parts.dropLast() {
                if let found = parent.children.first(where: { $0.isStorage && $0.name == storage }) {
                    parent = found
                } else {
                    let node = Node(storage, storage: true)
                    parent.children.append(node)
                    parent = node
                }
            }
            let leaf = Node(parts.last!, storage: false)
            leaf.data = data
            parent.children.append(leaf)
        }

        var nodes: [Node] = []
        func number(_ node: Node) {
            node.index = nodes.count
            nodes.append(node)
            node.children.forEach(number)
        }
        number(root)

        // mini stream
        var miniStream = Data()
        var miniFat: [UInt32] = []
        for node in nodes where !node.isStorage && node.data.count < cutoff && !node.data.isEmpty {
            let count = (node.data.count + miniSectorSize - 1) / miniSectorSize
            node.start = UInt32(miniFat.count)
            for i in 0..<count { miniFat.append(i == count - 1 ? endOfChain : UInt32(miniFat.count + 1)) }
            miniStream += node.data + Data(count: count * miniSectorSize - node.data.count)
        }

        func sectors(_ bytes: Int) -> Int { (bytes + sectorSize - 1) / sectorSize }
        let big = nodes.filter { !$0.isStorage && $0.data.count >= cutoff }
        let dirSectors = sectors(nodes.count * 128)
        let miniFatSectors = sectors(miniFat.count * 4)
        let miniStreamSectors = sectors(miniStream.count)
        let other = dirSectors + miniFatSectors + miniStreamSectors + big.map { sectors($0.data.count) }.reduce(0, +)
        var fatSectors = 1
        while (other + fatSectors) > fatSectors * (sectorSize / 4) { fatSectors += 1 }
        precondition(fatSectors <= 109, "픽스처가 너무 큼")

        var fat = [UInt32](repeating: free, count: fatSectors * (sectorSize / 4))
        var next = 0
        func allocate(_ count: Int) -> UInt32 {
            guard count > 0 else { return endOfChain }
            let start = next
            for i in 0..<count { fat[start + i] = i == count - 1 ? endOfChain : UInt32(start + i + 1) }
            next += count
            return UInt32(start)
        }
        for i in 0..<fatSectors { fat[i] = fatSect }
        next = fatSectors
        let dirStart = allocate(dirSectors)
        let miniFatStart = allocate(miniFatSectors)
        root.start = allocate(miniStreamSectors)
        for node in big { node.start = allocate(sectors(node.data.count)) }

        var out = Data()
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        func pad(to size: Int) { if out.count < size { out.append(Data(count: size - out.count)) } }

        // 헤더
        out.append(contentsOf: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        out.append(Data(count: 16))
        u16(0x3E); u16(3); u16(0xFFFE); u16(9); u16(6)
        out.append(Data(count: 6))
        u32(0); u32(UInt32(fatSectors)); u32(dirStart); u32(0); u32(UInt32(cutoff))
        u32(miniFatSectors > 0 ? miniFatStart : endOfChain); u32(UInt32(miniFatSectors)); u32(endOfChain); u32(0)
        for i in 0..<109 { u32(i < fatSectors ? UInt32(i) : free) }
        pad(to: 512)

        for v in fat { u32(v) }

        // 디렉터리
        let dirOffset = out.count
        for node in nodes {
            let entryStart = out.count
            let name = Array(node.name.utf16.prefix(31)) + [0]
            for unit in name { u16(unit) }
            pad(to: entryStart + 64)
            u16(UInt16(name.count * 2))
            out.append(node === root ? 5 : (node.isStorage ? 1 : 2))
            out.append(1)  // black
            // 형제 = 같은 부모의 다음 자식 (right), 자식 = 첫 자식 (child)
            let siblings = nodes.first { $0.children.contains { $0 === node } }?.children ?? []
            let position = siblings.firstIndex { $0 === node } ?? 0
            u32(free)
            u32(position + 1 < siblings.count ? UInt32(siblings[position + 1].index) : free)
            u32(node.children.first.map { UInt32($0.index) } ?? free)
            out.append(Data(count: 16 + 4 + 16))  // CLSID, state, 시간
            u32(node.isStorage && node !== root ? 0 : node.start)
            u32(UInt32(node === root ? miniStream.count : (node.isStorage ? 0 : node.data.count)))
            u32(0)
        }
        pad(to: dirOffset + dirSectors * sectorSize)

        for v in miniFat { u32(v) }
        pad(to: out.count + (miniFatSectors * sectorSize - miniFat.count * 4))
        out.append(miniStream)
        pad(to: out.count + (miniStreamSectors * sectorSize - miniStream.count))
        for node in big {
            out.append(node.data)
            pad(to: out.count + (sectors(node.data.count) * sectorSize - node.data.count))
        }
        return out
    }
}
