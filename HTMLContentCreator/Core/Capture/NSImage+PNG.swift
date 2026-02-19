import AppKit

extension NSImage {
    var pngData: Data? {
        guard
            let tiffData = tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }
        guard bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else {
            return nil
        }
        guard let data = bitmap.representation(using: .png, properties: [:]), !data.isEmpty else {
            return nil
        }
        return data
    }
}
