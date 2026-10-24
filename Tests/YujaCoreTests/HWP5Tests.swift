import XCTest
@testable import YujaCore

final class HWP5Tests: XCTestCase {
    typealias P = HWPFixture.Paragraph
    typealias C = HWPFixture.CellSpec

    private var tmp: URL!

    override func setUpWithError() throws { tmp = try Fixtures.temporaryDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func write(_ fixture: HWPFixture, _ name: String) throws -> URL {
        let url = tmp.appendingPathComponent("\(name).hwp")
        try fixture.build().write(to: url)
        return url
    }

    private func convert(_ fixture: HWPFixture, _ name: String, _ format: OutputFormat = .md) throws -> String {
        let input = try write(fixture, name)
        let output = tmp.appendingPathComponent("\(name).\(format.fileExtension)")
        try Converter.convert(input: input, output: output, options: ConvertOptions(format: format))
        return try String(contentsOf: output, encoding: .utf8)
    }

    // MARK: HWPX 픽스처와 같은 내용 → 같은 출력 (Phase 3 교차 테스트)

    static var lists: HWPFixture {
        HWPFixture(paragraphs: [
            P(shape: 1, .text("제출 서류")),
            P(shape: 3, .text("사업자등록증")),
            P(shape: 3, .text("재무제표")),
            P(shape: 4, .text("최근 3년 손익계산서")),
            P(shape: 4, .text("감사보고서", charShape: 1), .text(" (해당 시)")),
            P(shape: 3, .text("대표자 신분증 사본")),
            P(.text("평가 절차는 다음과 같다.")),
            P(shape: 5, .text("서류 평가")),
            P(shape: 5, .text("발표 평가")),
            P(shape: 4, .text("10분 발표, 5분 질의")),
            P(shape: 5, .text("최종 선정")),
            P(.text("참고:")),
            P(shape: 4, .text("들여쓴 항목만 있는 목록")),
        ])
    }

    static var tables: HWPFixture {
        let bold = { (t: String) in P(shape: 6, .text(t, charShape: 1)) }
        let plain = { (t: String) in P(.text(t)) }
        let empty = P()
        let nested = HWPFixture.Piece.table([
            [C(paragraphs: [plain("내부1")]), C(paragraphs: [plain("내부2")])],
            [C(paragraphs: [plain("내부3")]), C(paragraphs: [plain("내부4")])],
        ])
        return HWPFixture(paragraphs: [
            P(.table([[C(paragraphs: [bold("- 2026년 창업지원 사업 -"), bold("사업 신청서")])]])),
            P(.table([
                [C(paragraphs: [bold("구분")], rowSpan: 2, width: 10000),
                 C(paragraphs: [bold("항목")], colSpan: 2, width: 30000),
                 C(paragraphs: [bold("비고")], width: 10000)],
                [C(paragraphs: [plain("금액")], width: 15000), C(paragraphs: [plain("부가세")], width: 15000),
                 C(paragraphs: [empty], width: 10000)],
                [C(paragraphs: [plain("재료비")]), C(paragraphs: [plain("1,000")]), C(paragraphs: [plain("100")]),
                 C(paragraphs: [plain("예시")])],
                [C(paragraphs: [P(.text("합계", charShape: 1))], colSpan: 2), C(paragraphs: [plain("100")]),
                 C(paragraphs: [empty])],
            ])),
            P(.text("표 앞 문장."),
              .table([
                  [C(paragraphs: [P(.text("항목", charShape: 1))]), C(paragraphs: [P(.text("내용", charShape: 1))])],
                  [C(paragraphs: [plain("세부 내역")]),
                   C(paragraphs: [P(.text("첫 문단"), .lineBreak, .text("같은 문단 둘째 줄")), plain("A | B 구분"), P(nested)])],
              ]),
              .text("표 뒤 문장.")),
        ])
    }

    static func images() throws -> HWPFixture {
        let bin = Fixtures.hwpxRoot.appendingPathComponent("images/BinData")
        let png = try Data(contentsOf: bin.appendingPathComponent("image1.png"))
        let bmp = try Data(contentsOf: bin.appendingPathComponent("image2.bmp"))
        return HWPFixture(paragraphs: [
            P(.text("PNG 그림(그대로 복사):")),
            P(shape: 6, .pictures([1], width: 3600, height: 2400)),
            P(.text("BMP 그림(PNG로 변환), 표 안·묶음 개체 안:")),
            P(.table([[
                C(paragraphs: [P(.text("예시 1")), P(.pictures([2, 1]))]),
                C(paragraphs: [P(.text("같은 그림을 두 번 써도 파일은 하나"))]),
            ]])),
        ], binData: [("png", png), ("bmp", bmp)])
    }

    func testSameContentAsHWPXFixturesGivesSameMarkdownAndText() throws {
        for (name, fixture) in [("lists", Self.lists), ("tables", Self.tables), ("images", try Self.images())] {
            for format in [OutputFormat.md, .txt] {
                let expected = try String(contentsOf: Fixtures.expectedURL(name, format.fileExtension), encoding: .utf8)
                XCTAssertEqual(try convert(fixture, name, format), expected, "\(name).\(format.rawValue): HWP와 HWPX 출력이 다름")
            }
        }
    }

    func testUncompressedAndDistributedDocumentsDecodeTheSame() throws {
        let expected = try String(contentsOf: Fixtures.expectedURL("tables", "md"), encoding: .utf8)
        for (compressed, distributed) in [(false, false), (true, true), (false, true)] {
            var fixture = Self.tables
            fixture.compressed = compressed
            fixture.distributed = distributed
            XCTAssertEqual(try convert(fixture, "tables"), expected, "compressed=\(compressed) distributed=\(distributed)")
        }
    }

    func testImagesFromBinDataAreExtracted() throws {
        let input = try write(try Self.images(), "images")
        let result = try Converter.convert(input: input, output: tmp.appendingPathComponent("images.md"))
        XCTAssertEqual(result.assets.map(\.lastPathComponent), ["img_1.png", "img_2.png"])
        // 그림 하나짜리 개체는 개체 크기(HWPUNIT/100 = pt)를 그림 크기로
        let document = try Converter.load(input).document
        guard case .image(let ref)? = document.sections[0].blocks.dropFirst().first else { return XCTFail() }
        XCTAssertEqual(ref.size, ImageSize(width: 36, height: 24))
    }

    // MARK: HWP 전용 컨트롤

    static var controls: HWPFixture {
        HWPFixture(paragraphs: [
            P(shape: 1, .text("컨트롤 모음")),
            P(.text("크기가 "), .equation("3 TIMES 3"), .text("인 행렬 "), .equation("A"), .text("는 정방행렬이다.")),
            P(.text("굵게", charShape: 1), .text(" 기울임", charShape: 2), .text(" 취소", charShape: 4), .text(" 보통")),
            P(.text("앞"), .tab, .text("탭 뒤"), .lineBreak, .text("다음 줄")),
            P(.text("대표자: "), .field("홍길동"), .text(" (서명)")),
            P(.checkbox(checked: true, caption: ""), .text(" 동의함 "), .checkbox(checked: false, caption: " 동의 안 함")),
            P(.text("본문"), .footnote([P(.text("각주 내용"))]), .text(" 이어짐.")),
            P(pageBreak: true, .header([P(.text("머리말 문구"))]), .text("둘째 쪽")),
        ])
    }

    func testControlsGolden() throws {
        let url = Fixtures.root.appendingPathComponent("hwp5/controls.expected.md")
        let actual = try convert(Self.controls, "controls")
        if GoldenTests.update {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try actual.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        XCTAssertEqual(actual, try String(contentsOf: url, encoding: .utf8))
    }

    func testEquationsStayInline() throws {
        let document = try Converter.load(write(Self.controls, "eq")).document
        guard case .paragraph(let runs, _) = document.sections[0].blocks[1] else { return XCTFail() }
        XCTAssertEqual(runs.filter(\.equation).map(\.text), ["3 TIMES 3", "A"])
        XCTAssertEqual(runs.map(\.text).joined(), "크기가 3 TIMES 3인 행렬 A는 정방행렬이다.")
    }

    // MARK: 에러 (crash 대신 YujaError)

    func testProtectedDocumentsAreRejectedClearly() throws {
        var encrypted = Self.lists
        encrypted.extraFlags = 1 << 1
        XCTAssertThrowsError(try Converter.load(write(encrypted, "enc"))) { XCTAssertEqual($0 as? YujaError, .encrypted) }

        var drm = Self.lists
        drm.extraFlags = 1 << 4
        XCTAssertThrowsError(try Converter.load(write(drm, "drm"))) { XCTAssertEqual($0 as? YujaError, .drmProtected) }
    }

    func testNonHWPCompoundFileIsRejected() throws {
        let url = tmp.appendingPathComponent("excel.hwp")
        try CFBWriter.build(["Workbook": Data(count: 100)]).write(to: url)
        XCTAssertThrowsError(try Converter.load(url)) { error in
            guard case .unsupportedFormat = error as? YujaError else { return XCTFail("\(error)") }
        }
    }

    /// 잘리거나 깨진 파일: 성공하든 실패하든 crash만 없으면 된다.
    func testCorruptedInputNeverCrashes() throws {
        for compressed in [true, false] {
            var fixture = Self.tables
            fixture.compressed = compressed
            let good = [UInt8](fixture.build())
            var generator = MSVCRandom(seed: compressed ? 7 : 11)

            for length in stride(from: 0, to: good.count, by: max(good.count / 97, 1)) {
                _ = try? HWP5Reader.read(Data(good.prefix(length)))
            }
            for _ in 0..<400 {
                var bytes = good
                for _ in 0..<(1 + Int(generator.next() % 4)) {
                    let position = Int(generator.next()) * 32_768 % bytes.count + Int(generator.next()) % 32_768
                    bytes[position % bytes.count] = UInt8(truncatingIfNeeded: generator.next())
                }
                _ = try? HWP5Reader.read(Data(bytes))
            }
        }
    }

    // MARK: 구성 요소

    func testCompoundFileRoundTrip() throws {
        let streams: [String: Data] = [
            "FileHeader": Data(repeating: 1, count: 256),
            "Empty": Data(),
            "Edge": Data(repeating: 2, count: 4095),
            "BodyText/Section0": Data(repeating: 3, count: 4096),
            "BodyText/Section1": Data((0..<10_000).map { UInt8($0 % 251) }),
            "BinData/BIN0001.png": Data(repeating: 4, count: 65),
        ]
        let cfb = try CompoundFile(CFBWriter.build(streams))
        for (path, data) in streams {
            XCTAssertEqual(try cfb.stream(path), data, path)
            XCTAssertEqual(try cfb.stream(path.uppercased()), data, "대소문자 무시: \(path)")
        }
        XCTAssertNil(try cfb.stream("BodyText/Section2"))
    }

    func testMSVCRandMatchesKnownSequence() {
        var r = MSVCRandom(seed: 1)
        XCTAssertEqual([r.next(), r.next(), r.next()], [41, 18467, 6334])
    }

    func testDistributedStreamDecryptsToOriginal() throws {
        let section = Data((0..<100).map { UInt8($0) })
        let decrypted = try HWPStream.decryptDistributed(HWPFixture.distribute(section))
        XCTAssertEqual(decrypted.prefix(100), section)
        XCTAssertEqual(decrypted.count, 112)  // 16바이트 배수로 채운 0
    }

    func testRecordWithExtendedSize() throws {
        // 크기 필드 0xFFF → 다음 DWORD가 실제 크기
        var data = Data()
        withUnsafeBytes(of: (UInt32(HWPTag.paraText) | 0xFFF << 20).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(5000).littleEndian) { data.append(contentsOf: $0) }
        data.append(Data(count: 5000))
        let records = try HWPRecord.parse(data)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].payload.count, 5000)
    }
}
