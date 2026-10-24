import Foundation

/// DOCX의 고정 부품(OOXML). 본문(document.xml)은 DocxExporter가 만든다.
enum DocxTemplates {
    static let wordNS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    static let relNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    /// A4, 여백 1인치 (twip = 1/20 pt)
    static let pageWidth = 11906, pageHeight = 16838, margin = 1440
    static var contentWidth: Int { pageWidth - 2 * margin }

    static let fontEastAsia = "맑은 고딕"
    static let fontLatin = "맑은 고딕"

    static func contentTypes(imageExtensions: Set<String>) -> String {
        let mime = ["png": "image/png", "jpg": "image/jpeg", "gif": "image/gif", "bmp": "image/bmp"]
        let images = imageExtensions.sorted().map { ext in
            "<Default Extension=\"\(ext)\" ContentType=\"\(mime[ext] ?? "application/octet-stream")\"/>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        \(images)\
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
        <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
        <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>\
        <Override PartName="/word/settings.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/>\
        <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
        </Types>
        """
    }

    static let packageRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
    </Relationships>
    """

    static func documentRels(images: [(id: String, target: String)]) -> String {
        let imageRels = images.map {
            "<Relationship Id=\"\($0.id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"\($0.target)\"/>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>\
        <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings" Target="settings.xml"/>\
        \(imageRels)\
        </Relationships>
        """
    }

    static func core(title: String?, creator: String?) -> String {
        let title = title.map { "<dc:title>\(DocxXML.escape($0))</dc:title>" } ?? ""
        let creator = creator.map { "<dc:creator>\(DocxXML.escape($0))</dc:creator>" } ?? ""
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\(title)\(creator)</cp:coreProperties>
        """
    }

    /// compatibilityMode 15 = Word 2013 이후. 없으면 Word가 "호환성 모드"로 연다.
    static let settings = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:settings xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
    <w:defaultTabStop w:val="800"/><w:characterSpacingControl w:val="doNotCompress"/>\
    <w:compat><w:compatSetting w:name="compatibilityMode" w:uri="http://schemas.microsoft.com/office/word" w:val="15"/></w:compat>\
    </w:settings>
    """

    static var styles: String {
        // 제목 크기 (반 pt 단위): 16, 14, 13, 12, 11, 10pt
        let headingSizes = [32, 28, 26, 24, 22, 20]
        let headings = headingSizes.enumerated().map { i, size in
            """
            <w:style w:type="paragraph" w:styleId="Heading\(i + 1)"><w:name w:val="heading \(i + 1)"/>\
            <w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:uiPriority w:val="9"/><w:qFormat/>\
            <w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before="240" w:after="120"/><w:outlineLvl w:val="\(i)"/></w:pPr>\
            <w:rPr><w:b/><w:bCs/><w:sz w:val="\(size)"/><w:szCs w:val="\(size)"/></w:rPr></w:style>
            """
        }.joined()

        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="\(wordNS)">\
        <w:docDefaults><w:rPrDefault><w:rPr>\
        <w:rFonts w:ascii="\(fontLatin)" w:hAnsi="\(fontLatin)" w:eastAsia="\(fontEastAsia)" w:cs="\(fontLatin)"/>\
        <w:sz w:val="20"/><w:szCs w:val="20"/><w:lang w:val="en-US" w:eastAsia="ko-KR" w:bidi="ar-SA"/>\
        </w:rPr></w:rPrDefault>\
        <w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault>\
        </w:docDefaults>\
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>\
        \(headings)\
        <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/>\
        <w:basedOn w:val="Normal"/><w:uiPriority w:val="34"/><w:qFormat/>\
        <w:pPr><w:spacing w:after="40"/><w:contextualSpacing/></w:pPr></w:style>\
        <w:style w:type="character" w:default="1" w:styleId="DefaultParagraphFont"><w:name w:val="Default Paragraph Font"/>\
        <w:uiPriority w:val="1"/><w:semiHidden/></w:style>\
        <w:style w:type="table" w:default="1" w:styleId="TableNormal"><w:name w:val="Normal Table"/><w:semiHidden/>\
        <w:tblPr><w:tblInd w:w="0" w:type="dxa"/><w:tblCellMar><w:top w:w="0" w:type="dxa"/>\
        <w:left w:w="108" w:type="dxa"/><w:bottom w:w="0" w:type="dxa"/><w:right w:w="108" w:type="dxa"/>\
        </w:tblCellMar></w:tblPr></w:style>\
        <w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:basedOn w:val="TableNormal"/>\
        <w:pPr><w:spacing w:before="40" w:after="40" w:line="240" w:lineRule="auto"/></w:pPr>\
        <w:tblPr><w:tblBorders>\
        <w:top w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:left w:val="single" w:sz="4" w:space="0" w:color="auto"/>\
        <w:bottom w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:right w:val="single" w:sz="4" w:space="0" w:color="auto"/>\
        <w:insideH w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:insideV w:val="single" w:sz="4" w:space="0" w:color="auto"/>\
        </w:tblBorders></w:tblPr></w:style>\
        </w:styles>
        """
    }

    /// abstractNum 0 = 글머리표, 1 = 번호. numId 1 = 글머리표(공용), 2부터 번호 목록마다 새로 (번호 다시 시작).
    static func numbering(orderedLists: [(numId: Int, level: Int)]) -> String {
        let bullets = ["•", "◦", "▪"]
        func levels(_ ordered: Bool) -> String {
            (0..<9).map { i in
                let fmt = ordered ? "decimal" : "bullet"
                let text = ordered ? "%\(i + 1)." : bullets[i % bullets.count]
                return """
                <w:lvl w:ilvl="\(i)"><w:start w:val="1"/><w:numFmt w:val="\(fmt)"/><w:lvlText w:val="\(text)"/>\
                <w:lvlJc w:val="left"/><w:pPr><w:ind w:left="\(400 * (i + 1))" w:hanging="400"/></w:pPr></w:lvl>
                """
            }.joined()
        }
        let nums = orderedLists.map {
            """
            <w:num w:numId="\($0.numId)"><w:abstractNumId w:val="1"/>\
            <w:lvlOverride w:ilvl="\($0.level)"><w:startOverride w:val="1"/></w:lvlOverride></w:num>
            """
        }.joined()

        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:numbering xmlns:w="\(wordNS)">\
        <w:abstractNum w:abstractNumId="0"><w:multiLevelType w:val="hybridMultilevel"/>\(levels(false))</w:abstractNum>\
        <w:abstractNum w:abstractNumId="1"><w:multiLevelType w:val="hybridMultilevel"/>\(levels(true))</w:abstractNum>\
        <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>\
        \(nums)\
        </w:numbering>
        """
    }
}

enum DocxXML {
    /// XML 특수문자 이스케이프 + XML 1.0에서 허용하지 않는 제어문자 제거
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            default:
                let v = scalar.value
                if v < 0x20 || v == 0xFFFE || v == 0xFFFF { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
