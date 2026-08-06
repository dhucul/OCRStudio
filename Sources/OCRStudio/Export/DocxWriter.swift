import Foundation

/// Builds a Word .docx (Office Open XML) with a real built-in **Heading 1**
/// paragraph style on each page's title line. Self-contained: it emits the OOXML
/// parts and packages them with the minimal ZIP writer below — no dependencies.
enum DocxWriter {

    enum DocxError: LocalizedError {
        case tooLarge

        var errorDescription: String? {
            "The document is too large to package as a .docx (4 GB ZIP limit)."
        }
    }

    static func data(pages: [String]) throws -> Data {
        var body = ""
        for (pageIndex, page) in pages.enumerated() {
            if pageIndex > 0 {
                body += #"<w:p><w:r><w:br w:type="page"/></w:r></w:p>"#
            }
            let lines = page.components(separatedBy: "\n")
            let titleIndex = RichTextExport.titleLineIndex(in: lines)
            for (idx, line) in lines.enumerated() {
                let isTitle = idx == titleIndex
                // pStyle gives Word the real Heading 1 style (outline/navigation);
                // the matching direct rPr makes it render bold/large in readers that
                // don't cascade style run-properties (Pages, Quick Look, …).
                let pPr = isTitle ? #"<w:pPr><w:pStyle w:val="Heading1"/></w:pPr>"# : ""
                let rPr = isTitle ? #"<w:rPr><w:b/><w:sz w:val="32"/></w:rPr>"# : ""
                let run = line.isEmpty ? "" : #"<w:r>\#(rPr)<w:t xml:space="preserve">\#(escape(line))</w:t></w:r>"#
                body += "<w:p>\(pPr)\(run)</w:p>"
            }
        }

        let documentXML = #"""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\#(body)<w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr></w:body></w:document>
        """#

        var zip = ZipArchive()
        zip.add("[Content_Types].xml", Self.contentTypes)
        zip.add("_rels/.rels", Self.rootRels)
        zip.add("word/_rels/document.xml.rels", Self.documentRels)
        zip.add("word/document.xml", documentXML)
        zip.add("word/styles.xml", Self.stylesXML)
        guard let data = zip.finish() else { throw DocxError.tooLarge }
        return data
    }

    private static func escape(_ s: String) -> String {
        // Drop characters not permitted in XML 1.0 (control chars other than
        // tab/newline/CR) so odd pasted input can't produce an unopenable file.
        let cleaned = String(String.UnicodeScalarView(
            s.unicodeScalars.filter { scalar in
                let value = scalar.value
                return value == 0x9 || value == 0xA || value == 0xD
                    || (0x20...0xD7FF).contains(value)
                    || (0xE000...0xFFFD).contains(value)
                    || (0x10000...0x10FFFF).contains(value)
            }
        ))
        return cleaned
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: Fixed package parts

    private static let contentTypes = #"""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>
    """#

    private static let rootRels = #"""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
    """#

    private static let documentRels = #"""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
    """#

    /// Defines Normal and the built-in Heading 1 (name "heading 1", outline level 0
    /// so it appears in Word's navigation/outline and adopts the template look).
    private static let stylesXML = #"""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri"/><w:sz w:val="24"/></w:rPr></w:rPrDefault></w:docDefaults><w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style><w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:uiPriority w:val="9"/><w:qFormat/><w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before="240" w:after="120"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="32"/></w:rPr></w:style></w:styles>
    """#
}

/// Minimal ZIP archive writer (STORED entries, no compression) — enough to
/// package an OOXML document that Word/Pages/Google Docs open.
struct ZipArchive {
    private struct Entry { let name: [UInt8]; let crc: UInt32; let size: Int; let offset: Int }

    private var buffer = Data()
    private var entries: [Entry] = []
    /// Set when an entry exceeds what ZIP32 can address. Every size/offset field
    /// below is a narrowing conversion that would otherwise trap at runtime.
    private var overflowed = false

    /// 1980-01-01 00:00 in MS-DOS format. A literal 0 encodes day 0 of month 0,
    /// which strict extractors flag as malformed.
    private static let dosTime: UInt16 = 0
    private static let dosDate: UInt16 = 0x0021

    private static let maxSize = Int(UInt32.max)

    mutating func add(_ name: String, _ string: String) {
        add(name, Data(string.utf8))
    }

    mutating func add(_ name: String, _ data: Data) {
        let crc = ZipArchive.crc32(data)
        let offset = buffer.count
        let nameBytes = Array(name.utf8)

        guard data.count <= Self.maxSize,
              offset <= Self.maxSize,
              nameBytes.count <= Int(UInt16.max) else {
            overflowed = true
            return
        }

        buffer.append(le32(0x0403_4b50))           // local file header signature
        buffer.append(le16(20))                     // version needed
        buffer.append(le16(0))                      // flags
        buffer.append(le16(0))                      // method: stored
        buffer.append(le16(Self.dosTime)); buffer.append(le16(Self.dosDate))
        buffer.append(le32(crc))
        buffer.append(le32(UInt32(data.count)))     // compressed size
        buffer.append(le32(UInt32(data.count)))     // uncompressed size
        buffer.append(le16(UInt16(nameBytes.count)))
        buffer.append(le16(0))                      // extra length
        buffer.append(contentsOf: nameBytes)
        buffer.append(data)

        entries.append(Entry(name: nameBytes, crc: crc, size: data.count, offset: offset))
    }

    /// Returns nil when the archive exceeded ZIP32 limits.
    mutating func finish() -> Data? {
        guard !overflowed, entries.count <= Int(UInt16.max) else { return nil }
        let cdStart = buffer.count
        var cd = Data()
        for e in entries {
            cd.append(le32(0x0201_4b50))            // central directory signature
            cd.append(le16(20)); cd.append(le16(20))     // version made by / needed
            cd.append(le16(0)); cd.append(le16(0))       // flags / method
            cd.append(le16(Self.dosTime)); cd.append(le16(Self.dosDate))
            cd.append(le32(e.crc))
            cd.append(le32(UInt32(e.size)))         // compressed
            cd.append(le32(UInt32(e.size)))         // uncompressed
            cd.append(le16(UInt16(e.name.count)))
            cd.append(le16(0)); cd.append(le16(0))       // extra / comment length
            cd.append(le16(0)); cd.append(le16(0))       // disk start / internal attrs
            cd.append(le32(0))                      // external attrs
            cd.append(le32(UInt32(e.offset)))
            cd.append(contentsOf: e.name)
        }
        buffer.append(cd)

        buffer.append(le32(0x0605_4b50))            // end of central directory
        buffer.append(le16(0)); buffer.append(le16(0))   // disk numbers
        buffer.append(le16(UInt16(entries.count)))
        buffer.append(le16(UInt16(entries.count)))
        guard cd.count <= Self.maxSize, cdStart <= Self.maxSize else { return nil }
        buffer.append(le32(UInt32(cd.count)))
        buffer.append(le32(UInt32(cdStart)))
        buffer.append(le16(0))                      // comment length
        return buffer
    }

    private func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xff), UInt8(v >> 8)]) }
    private func le32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)])
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
