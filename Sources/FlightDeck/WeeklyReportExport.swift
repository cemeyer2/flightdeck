// Weekly Report export: "Copy as Text" (the digest's Markdown) and "Save as PDF…" (the page's panels on US Letter
// pages, light palette on white). Each panel is rendered with ImageRenderer and panels are packed onto pages whole, so
// a page break never cuts a line in half; only a panel taller than a whole page (none are, in practice) is sliced.
import SwiftUI
import UniformTypeIdentifiers
import FlightDeckCore

@MainActor
enum WeeklyReportExport {
    static func copy(_ d: WeeklyDigest) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(d.markdown, forType: .string)
    }

    static func savePDF(_ d: WeeklyDigest) {
        guard let data = pdf(d) else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = d.title.replacingOccurrences(of: ":", with: "") + ".pdf"
        if panel.runModal() == .OK, let u = panel.url {
            do { try data.write(to: u); NSWorkspace.shared.open(u) } catch { NSSound.beep() }
        }
    }

    static let page = CGSize(width: 612, height: 792)
    static let margin: CGFloat = 36
    static let gap: CGFloat = 10

    /// The PDF: header and sections packed onto pages. nil if nothing rendered.
    static func pdf(_ d: WeeklyDigest) -> Data? {
        let p = Palette.of(.light)
        let width = page.width - 2 * margin, usable = page.height - 2 * margin - 14   // 14 pt for the footer
        var blocks: [AnyView] = [AnyView(WeeklyPrintHeader(digest: d))]
        blocks += d.sections.map { AnyView(WeeklyPrintSection(section: $0)) }
        let renderers: [ImageRenderer<AnyView>] = blocks.map { b in
            let r = ImageRenderer(content: AnyView(b.frame(width: width, alignment: .leading)
                .environment(\.palette, p).environment(\.colorScheme, .light).environment(\.offscreen, true)))
            r.proposedSize = ProposedViewSize(width: width, height: nil)
            return r
        }
        let heights: [CGFloat] = renderers.map { r in var h: CGFloat = 0; r.render { size, _ in h = size.height }; return h }

        // Pages: lists of (block index, y offset from the top of the content area, slice start within the block).
        var pages: [[(Int, CGFloat, CGFloat)]] = [[]]
        var y: CGFloat = 0
        for (i, h) in heights.enumerated() {
            if h > usable {   // slice an over-tall block across whole pages
                if y > 0 { pages.append([]); y = 0 }
                var start: CGFloat = 0
                while start < h { pages[pages.count - 1].append((i, 0, start)); start += usable; if start < h { pages.append([]) } }
                pages.append([]); y = 0
                continue
            }
            if y > 0 && y + h > usable { pages.append([]); y = 0 }
            pages[pages.count - 1].append((i, y, 0)); y += h + gap
        }
        pages.removeAll { $0.isEmpty }

        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: page)
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        for (n, items) in pages.enumerated() {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(NSColor.white.cgColor); ctx.fill(box)
            for (i, top, slice) in items {
                renderers[i].render { size, draw in
                    ctx.saveGState()
                    ctx.clip(to: CGRect(x: margin, y: margin + 14, width: width, height: usable))
                    // CG's origin is bottom-left: place the block's top at the content area's top minus `top`, shifted up by the slice.
                    ctx.translateBy(x: margin, y: page.height - margin - top - size.height + slice)
                    draw(ctx)
                    ctx.restoreGState()
                }
            }
            footer(ctx, "FlightDeck · \(d.title) · page \(n + 1) of \(pages.count)")
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data.length > 0 ? data as Data : nil
    }

    static func footer(_ ctx: CGContext, _ text: String) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.gray]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        ctx.textPosition = CGPoint(x: margin, y: margin - 4)
        CTLineDraw(line, ctx)
    }
}

/// Print layout (no panel surfaces, which don't survive PDF rendering well): black text on white, a rule per section.
struct WeeklyPrintHeader: View {
    let digest: WeeklyDigest
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(digest.title.uppercased()).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(.gray)
            Text(digest.headline).font(.system(size: 20, weight: .semibold)).foregroundStyle(digest.rough ? Color.red : .black)
            Text(digest.subhead).font(.system(size: 10)).foregroundStyle(.gray)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 4)
    }
}

struct WeeklyPrintSection: View {
    let section: WeeklyDigest.Section
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Rectangle().fill(Color.gray.opacity(0.4)).frame(height: 0.5)
            Text(section.title.uppercased()).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(.gray).padding(.top, 2)
            ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle().fill(line.tone == .bad ? Color.orange : line.tone == .good ? .green : .gray.opacity(0.5)).frame(width: 5, height: 5)
                    Text(line.text).font(.system(size: 11)).foregroundStyle(.black)
                }
            }
            if let d = section.destination {
                Text("More in FlightDeck › \(d.replacingOccurrences(of: ":", with: " › "))").font(.system(size: 9)).foregroundStyle(.gray)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
