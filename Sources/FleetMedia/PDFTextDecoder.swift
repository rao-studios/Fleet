import FleetCore
import Foundation

#if canImport(PDFKit)
import PDFKit

/// Extracts text from PDFs. Apple-only (PDFKit); on Linux the `pdf` extension is
/// simply left unregistered and such files are skipped.
public struct PDFTextDecoder: MediaDecoder {
    public let maxChars: Int
    public init(maxChars: Int = 2000) { self.maxChars = maxChars }

    public var supportedExtensions: Set<String> { ["pdf"] }

    public func decode(_ url: URL) async throws -> [ContextFragment] {
        guard let document = PDFDocument(url: url) else { return [] }
        var text = ""
        for pageIndex in 0 ..< document.pageCount {
            if let page = document.page(at: pageIndex), let pageText = page.string {
                text += pageText + "\n\n"
            }
        }
        return TextChunker.chunk(text, maxChars: maxChars).enumerated().map { index, chunk in
            ContextFragment(
                id: fragmentID(url, index), source: url, mediaType: .text, text: chunk,
                metadata: ["source": "pdf"])
        }
    }
}

#endif
