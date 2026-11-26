import Foundation
import ImageIO
import UniformTypeIdentifiers

enum IdeaArtwork {
    static let platforms = ["x", "linkedin", "reddit", "instagram", "tiktok"]

    static func draftImage(from url: URL, platform: String) throws -> Data {
        let size: (width: Int, height: Int) = switch platform {
        case "x": (1600, 900)
        case "instagram": (1080, 1350)
        case "tiktok": (1080, 1920)
        default: (1080, 1080)
        }
        guard let image = thumbnail(from: url, maxSize: max(size.width, size.height)),
              let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw WorkspaceError("The idea image couldn’t be opened. Replace it before drafting.")
        }
        let width = CGFloat(size.width), height = CGFloat(size.height)
        let scale = min(width / CGFloat(image.width), height / CGFloat(image.height))
        let fittedWidth = CGFloat(image.width) * scale, fittedHeight = CGFloat(image.height) * scale
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (width - fittedWidth) / 2, y: (height - fittedHeight) / 2,
                                       width: fittedWidth, height: fittedHeight))
        guard let rendered = context.makeImage(), let jpeg = jpeg(rendered, quality: 0.9) else {
            throw WorkspaceError("The idea image couldn’t be formatted for this draft.")
        }
        return jpeg
    }

    static func preview(from url: URL) -> Data? {
        guard let image = thumbnail(from: url, maxSize: 560) else { return nil }
        for quality in [0.68, 0.5, 0.35] {
            if let data = jpeg(image, quality: quality), data.count <= 120_000 { return data }
        }
        return nil
    }

    private static func thumbnail(from url: URL, maxSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: maxSize] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    private static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? bytes as Data : nil
    }
}
