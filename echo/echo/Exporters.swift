import AppKit
import Foundation

enum Exporters {

    // A4 at 72 dpi (points)
    private static let pageWidth: CGFloat = 595.2   // 210 mm
    private static let pageHeight: CGFloat = 841.8  // 297 mm
    private static let margin: CGFloat = 64          // ~22 mm

    // Explicit print colors (never use dynamic system colors — they invert in dark mode)
    private static let inkColor   = NSColor(red: 0.11, green: 0.12, blue: 0.15, alpha: 1)
    private static let metaColor  = NSColor(red: 0.45, green: 0.47, blue: 0.52, alpha: 1)
    private static let ruleColor  = NSColor(red: 0.85, green: 0.86, blue: 0.89, alpha: 1)

    // MARK: - Plain text

    static func exportTXT(_ response: TranscriptionResponse, baseName: String = "transcript") {
        save(plainText(response).data(using: .utf8)!, ext: "txt", baseName: baseName)
    }

    static func copyText(_ response: TranscriptionResponse) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(plainText(response), forType: .string)
    }

    // MARK: - Word (.docx) — A4 with margins

    static func exportDocx(_ response: TranscriptionResponse, baseName: String = "transcript") {
        let attributed = buildDocument(response)
        let docAttributes: [NSAttributedString.DocumentAttributeKey: Any] = [
            .documentType: NSAttributedString.DocumentType.officeOpenXML,
            .paperSize: NSValue(size: NSSize(width: pageWidth, height: pageHeight)),
            .leftMargin: margin, .rightMargin: margin,
            .topMargin: margin, .bottomMargin: margin,
        ]
        guard let data = try? attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: docAttributes
        ) else { return }
        save(data, ext: "docx", baseName: baseName)
    }

    // MARK: - PDF — multi-page A4

    static func exportPDF(_ response: TranscriptionResponse, baseName: String = "transcript") {
        save(makeA4PDF(buildDocument(response)), ext: "pdf", baseName: baseName)
    }

    // MARK: - Document body (shared by PDF + Word)

    private static func buildDocument(_ response: TranscriptionResponse) -> NSAttributedString {
        let doc = NSMutableAttributedString()
        let palette = speakerPalette()

        // Title
        let titlePara = NSMutableParagraphStyle()
        titlePara.paragraphSpacing = 2
        doc.append(NSAttributedString(string: "Transcript\n", attributes: [
            .font: NSFont.systemFont(ofSize: 26, weight: .bold),
            .foregroundColor: inkColor,
            .paragraphStyle: titlePara,
        ]))

        // Metadata line
        let metaPara = NSMutableParagraphStyle()
        metaPara.paragraphSpacing = 16
        let speakerLabel = response.speakerCount == 1 ? "speaker" : "speakers"
        doc.append(NSAttributedString(
            string: "\(formattedToday())   ·   \(response.speakerCount) \(speakerLabel)   ·   \(response.formattedDuration) duration\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .regular),
                .foregroundColor: metaColor,
                .paragraphStyle: metaPara,
            ]))

        // Horizontal rule (a thin underlined blank line)
        let rulePara = NSMutableParagraphStyle()
        rulePara.paragraphSpacing = 18
        doc.append(NSAttributedString(string: "\u{00A0}\n", attributes: [
            .font: NSFont.systemFont(ofSize: 2),
            .paragraphStyle: rulePara,
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .strikethroughColor: ruleColor,
        ]))

        // Speaker blocks
        for block in response.speakerBlocks {
            let color = palette[(block.displayNumber - 1) % palette.count]

            let headPara = NSMutableParagraphStyle()
            headPara.paragraphSpacingBefore = 6
            headPara.paragraphSpacing = 5
            doc.append(NSAttributedString(
                string: "Speaker \(block.displayNumber)   ·   \(formatMs(block.startMs))   ·   \(block.language.lowercased())\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: color,
                    .paragraphStyle: headPara,
                ]))

            let bodyPara = NSMutableParagraphStyle()
            bodyPara.lineSpacing = 3.5
            bodyPara.paragraphSpacing = 16
            bodyPara.alignment = .left
            doc.append(NSAttributedString(string: "\(block.text)\n", attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .regular),
                .foregroundColor: inkColor,
                .paragraphStyle: bodyPara,
            ]))
        }
        return doc
    }

    // MARK: - PDF pagination

    private static func makeA4PDF(_ attributed: NSAttributedString) -> Data {
        let contentW = pageWidth - margin * 2
        let contentH = pageHeight - margin * 2

        let textStorage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        // One text container per page; text flows across them automatically.
        var containers: [NSTextContainer] = []
        repeat {
            let c = NSTextContainer(size: CGSize(width: contentW, height: contentH))
            c.lineFragmentPadding = 0
            layoutManager.addTextContainer(c)
            layoutManager.ensureLayout(for: c)
            containers.append(c)
        } while NSMaxRange(layoutManager.glyphRange(for: containers.last!)) < layoutManager.numberOfGlyphs

        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return Data() }

        // flipped: true tells AppKit the context uses a top-left origin, so
        // glyphs render upright once we flip the CTM to match.
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
        let total = containers.count

        for (i, container) in containers.enumerated() {
            ctx.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsCtx

            // PDF origin is bottom-left; flip the whole page to a top-left origin.
            ctx.saveGState()
            ctx.translateBy(x: 0, y: pageHeight)
            ctx.scaleBy(x: 1, y: -1)

            let origin = CGPoint(x: margin, y: margin)
            let glyphRange = layoutManager.glyphRange(for: container)
            layoutManager.drawBackground(forGlyphRange: glyphRange, at: origin)
            layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: origin)

            drawFooter(page: i + 1, total: total)

            ctx.restoreGState()
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    /// Draws "Page X of Y" centered near the bottom (top-left origin, y increases downward).
    private static func drawFooter(page: Int, total: Int) {
        let text = "Page \(page) of \(total)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .regular),
            .foregroundColor: metaColor,
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: (pageWidth - size.width) / 2, y: pageHeight - margin * 0.7),
                  withAttributes: attrs)
    }

    // MARK: - Plain text helper

    private static func plainText(_ response: TranscriptionResponse) -> String {
        var out = "TRANSCRIPT\n"
        out += "\(formattedToday()) · \(response.speakerCount) speaker(s) · \(response.formattedDuration)\n"
        out += String(repeating: "—", count: 40) + "\n\n"
        out += response.speakerBlocks.map { block in
            "Speaker \(block.displayNumber) · \(formatMs(block.startMs)) · \(block.language.lowercased())\n\(block.text)"
        }.joined(separator: "\n\n")
        return out + "\n"
    }

    private static func formattedToday() -> String {
        let df = DateFormatter()
        df.dateStyle = .long
        df.timeStyle = .short
        return df.string(from: Date())
    }

    private static func speakerPalette() -> [NSColor] {
        [
            NSColor(red: 0.27, green: 0.40, blue: 0.85, alpha: 1),
            NSColor(red: 0.13, green: 0.59, blue: 0.50, alpha: 1),
            NSColor(red: 0.82, green: 0.42, blue: 0.24, alpha: 1),
            NSColor(red: 0.60, green: 0.28, blue: 0.70, alpha: 1),
            NSColor(red: 0.72, green: 0.55, blue: 0.10, alpha: 1),
        ]
    }

    // MARK: - Save panel

    private static func save(_ data: Data, ext: String, baseName: String = "transcript") {
        let trimmed = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(trimmed.isEmpty ? "transcript" : trimmed).\(ext)"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }
}
