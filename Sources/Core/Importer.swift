import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum Importer {
    enum ImportError: LocalizedError, Equatable {
        case unreadableImage
        case unreadablePDF
        case lockedPDF
        case emptyPDF
        case tooLarge(Int)

        var errorDescription: String? {
            switch self {
            case .unreadableImage: return "That file isn’t an image Strokebook can read."
            case .unreadablePDF: return "That file isn’t a readable PDF."
            case .lockedPDF: return "That PDF is password-protected. Unlock it (e.g. in Preview) and import it again."
            case .emptyPDF: return "That PDF has no pages."
            case .tooLarge(let mb): return "That file is too large to import (\(mb) MB; the limit is 1 GB)."
            }
        }
    }

    static let maxFileBytes = 1 << 30

    struct ImageAsset {
        var data: Data
        /// Pixel size after downsampling.
        var pixelSize: CGSize
    }

    /// Downsamples to at most `maxPixel` on the long side, applies EXIF orientation, and re-encodes:
    /// JPEG for photos, PNG when the image has transparency.
    static func imageAsset(from data: Data, maxPixel: Int = 2400) throws -> ImageAsset {
        guard data.count <= maxFileBytes else { throw ImportError.tooLarge(data.count >> 20) }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0 else {
            throw ImportError.unreadableImage
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(16, maxPixel),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary), img.width > 0, img.height > 0 else {
            throw ImportError.unreadableImage
        }
        let alpha = img.alphaInfo
        let hasAlpha = !(alpha == .none || alpha == .noneSkipFirst || alpha == .noneSkipLast)
        let type = hasAlpha ? UTType.png : UTType.jpeg
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { throw ImportError.unreadableImage }
        CGImageDestinationAddImage(dest, img, hasAlpha ? nil : [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ImportError.unreadableImage }
        return ImageAsset(data: out as Data, pixelSize: CGSize(width: img.width, height: img.height))
    }

    /// A frame for an image placed on a page: fits within `maxFraction` of the page, centred on `center`,
    /// and kept fully on the page.
    static func placement(for pixelSize: CGSize, on page: Page, center: CGPoint, maxFraction: CGFloat = 0.6) -> CGRect {
        let pr = page.rect
        let w0 = max(pixelSize.width, 1), h0 = max(pixelSize.height, 1)
        let scale = min(pr.width * maxFraction / w0, pr.height * maxFraction / h0, 1)
        let size = CGSize(width: max(24, w0 * scale), height: max(24, h0 * scale))
        var origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        origin.x = origin.x.clamped(pr.minX, max(pr.minX, pr.maxX - size.width))
        origin.y = origin.y.clamped(pr.minY, max(pr.minY, pr.maxY - size.height))
        return CGRect(origin: origin, size: size)
    }

    /// Creates a notebook whose pages are the PDF's pages, ready to write on. The PDF is embedded once
    /// and each page draws from it, so text in the PDF stays vector-sharp at any zoom and in export.
    static func notebook(fromPDF data: Data, title: String) throws -> Notebook {
        guard data.count <= maxFileBytes else { throw ImportError.tooLarge(data.count >> 20) }
        guard let provider = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(provider) else {
            throw ImportError.unreadablePDF
        }
        if doc.isEncrypted && !doc.isUnlocked && !doc.unlockWithPassword("") { throw ImportError.lockedPDF }
        guard doc.numberOfPages > 0 else { throw ImportError.emptyPDF }
        let asset = UUID()
        var pages: [Page] = []
        for i in 0..<min(doc.numberOfPages, Notebook.maxPages) {
            guard let pg = doc.page(at: i + 1) else { continue }
            var size = PageRenderer.displaySize(of: pg)
            if !(size.width.isFinite && size.height.isFinite) || size.width < 1 || size.height < 1 { size = PageSize.a4.size }
            var p = Page(style: .blank, paper: .white, size: .a4)
            p.customSize = CGSize(width: size.width.clamped(Page.sizeRange.lowerBound, Page.sizeRange.upperBound),
                                  height: size.height.clamped(Page.sizeRange.lowerBound, Page.sizeRange.upperBound))
            p.background = .pdf(asset: asset, index: i)
            pages.append(p)
        }
        guard !pages.isEmpty else { throw ImportError.emptyPDF }
        var nb = Notebook(title: title, cover: RGBA(0.85, 0.33, 0.28), firstPage: pages[0])
        nb.pages = pages
        nb.assets[asset] = data
        return nb
    }
}
