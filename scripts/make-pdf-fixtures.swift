// Generates the PDFs the tests use. They are checked in, so this only needs running
// again if the test documents change.
// Usage: swift scripts/make-pdf-fixtures.swift Tests/PodcastReaderCoreTests/Fixtures
import AppKit
import CoreText
import PDFKit

guard CommandLine.arguments.count == 2 else {
    print("Usage: swift make-pdf-fixtures.swift <output-folder>")
    exit(1)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let font = CTFontCreateWithName("Times New Roman" as CFString, 12, nil)
let filler = "Spacing your study over several days works better than cramming it into one evening. "
    + "Close the book, write down what you remember, and check what you missed. "

func attributed(_ text: String) -> NSAttributedString {
    NSAttributedString(string: text, attributes: [.font: font])
}

func drawLine(_ text: String, x: CGFloat, y: CGFloat, in context: CGContext) {
    context.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(CTLineCreateWithAttributedString(attributed(text)), context)
}

func drawBlock(_ text: String, in rect: CGRect, context: CGContext) {
    let setter = CTFramesetterCreateWithAttributedString(attributed(text))
    let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
    CTFrameDraw(frame, context)
}

func makePDF(_ name: String, pages: Int, draw: (Int, CGContext) -> Void) {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = CGContext(output.appending(path: name) as CFURL, mediaBox: &box, nil)!
    for page in 0..<pages {
        context.beginPDFPage(nil)
        draw(page, context)
        context.endPDFPage()
    }
    context.closePDF()
}

let body = CGRect(x: 54, y: 100, width: 504, height: 580)

makePDF("document.pdf", pages: 5) { page, context in
    drawLine("Chapter 4: How memory works", x: 54, y: 760, in: context)
    drawLine("\(page + 1)", x: 300, y: 30, in: context)
    switch page {
    case 0: drawBlock("Memory is rebuilt every time you recall it. Testing yourself makes that path stronger. " + filler, in: body, context: context)
    case 4: drawBlock(filler + "That is the end of this chapter, and this is the last word", in: body, context: context)
    default: drawBlock(filler + filler, in: body, context: context)
    }
}

makePDF("two-columns.pdf", pages: 1) { _, context in
    drawBlock("Left column begins here. " + filler, in: CGRect(x: 54, y: 100, width: 240, height: 580), context: context)
    drawBlock("Right column begins here. " + filler, in: CGRect(x: 318, y: 100, width: 240, height: 580), context: context)
}

makePDF("hyphenated.pdf", pages: 1) { _, context in
    drawLine("The key act of re-", x: 54, y: 500, in: context)
    drawLine("building is what matters here.", x: 54, y: 484, in: context)
    drawLine("This is a well-", x: 54, y: 468, in: context)
    drawLine("Known idea in the field.", x: 54, y: 452, in: context)
}

makePDF("blank-page.pdf", pages: 3) { page, context in
    if page != 1 {
        drawLine("This page has words on it.", x: 54, y: 500, in: context)
    }
}

// A citation that links to the last page, as in a typical academic paper.
makePDF("linked.pdf", pages: 3) { page, context in
    drawLine(page == 0 ? "See reference [12] for more details on this." : "Another page of text here.", x: 54, y: 500, in: context)
}
let linked = PDFDocument(url: output.appending(path: "linked.pdf"))!
let firstPage = linked.page(at: 0)!
let citation = (firstPage.string! as NSString).range(of: "[12]")
let link = PDFAnnotation(bounds: firstPage.selection(for: citation)!.bounds(for: firstPage), forType: .link, withProperties: nil)
link.action = PDFActionGoTo(destination: PDFDestination(page: linked.page(at: 2)!, at: CGPoint(x: 0, y: 600)))
firstPage.addAnnotation(link)
linked.write(to: output.appending(path: "linked.pdf"))

let image = NSImage(size: NSSize(width: 612, height: 792))
image.lockFocus()
NSColor.white.setFill()
NSRect(x: 0, y: 0, width: 612, height: 792).fill()
("A scanned page" as NSString).draw(at: NSPoint(x: 100, y: 400), withAttributes: [.font: NSFont.systemFont(ofSize: 40)])
image.unlockFocus()
let scanned = PDFDocument()
scanned.insert(PDFPage(image: image)!, at: 0)
scanned.write(to: output.appending(path: "scanned.pdf"))

let locked = PDFDocument(url: output.appending(path: "document.pdf"))!
locked.write(to: output.appending(path: "locked.pdf"), withOptions: [
    .userPasswordOption: "secret",
    .ownerPasswordOption: "owner",
])

print("Wrote PDF fixtures to \(output.path)")
