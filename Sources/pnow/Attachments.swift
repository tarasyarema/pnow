import AppKit
import UniformTypeIdentifiers

/// An image the way dev-null.sh takes it: PNG, JPEG or WebP, up to 10 MB.
nonisolated struct UploadImage: Sendable {
    static let maxBytes = 10_240_000

    let data: Data
    let mimeType: String
    let fileExtension: String
}

struct Attachment: Identifiable {
    let id = UUID()
    let upload: UploadImage
    let thumbnail: NSImage
}

/// Images from the clipboard, a pasted file, or a dropped file.
enum Attachments {
    static let limit = 3

    private static let imageFiles: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true,
        .urlReadingContentsConformToTypes: [UTType.image.identifier],
    ]

    /// Looks at the clipboard's types only, so macOS shows no paste prompt. Text wins over an
    /// image, and other files (whose icons are images too) don't count.
    static func clipboardHasImage(_ pasteboard: NSPasteboard = .general) -> Bool {
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: imageFiles) { return true }
        if pasteboard.canReadObject(forClasses: [NSString.self], options: nil) { return false }
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return false }
        return pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    static func read(from pasteboard: NSPasteboard) throws -> [Attachment] {
        if let files = pasteboard.readObjects(forClasses: [NSURL.self], options: imageFiles) as? [URL], !files.isEmpty {
            return try files.map(attachment(fromFile:))
        }
        guard let image = NSImage(pasteboard: pasteboard) else { return [] }
        return [try attachment(from: image)]
    }

    static func attachment(fromFile url: URL) throws -> Attachment {
        guard let image = NSImage(contentsOf: url) else {
            throw PnowError("Could not read \(url.lastPathComponent) as an image.")
        }
        // PNG, JPEG and WebP files go up as they are.
        if let type = UTType(filenameExtension: url.pathExtension),
           let mimeType = type.preferredMIMEType,
           ["image/png", "image/jpeg", "image/webp"].contains(mimeType),
           let data = try? Data(contentsOf: url), data.count <= UploadImage.maxBytes {
            let upload = UploadImage(data: data, mimeType: mimeType, fileExtension: type.preferredFilenameExtension ?? url.pathExtension)
            return Attachment(upload: upload, thumbnail: image)
        }
        return try attachment(from: image)
    }

    /// PNG, or JPEG when the PNG is over 10 MB.
    static func attachment(from image: NSImage) throws -> Attachment {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else {
            throw PnowError("Could not read the image.")
        }
        if let png = bitmap.representation(using: .png, properties: [:]), png.count <= UploadImage.maxBytes {
            return Attachment(upload: UploadImage(data: png, mimeType: "image/png", fileExtension: "png"), thumbnail: image)
        }
        if let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]), jpeg.count <= UploadImage.maxBytes {
            return Attachment(upload: UploadImage(data: jpeg, mimeType: "image/jpeg", fileExtension: "jpg"), thumbnail: image)
        }
        throw PnowError("The image is larger than 10 MB.")
    }
}
