import AppKit
import Foundation
import PDFKit
import XCTest
@testable import HTMLContentCreator

final class VisualRegressionSnapshotTests: XCTestCase {
    private var tempRoot: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("html-content-creator-visual-regression-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot, fileManager.fileExists(atPath: tempRoot.path) {
            try fileManager.removeItem(at: tempRoot)
        }
    }

    func testReferenceSlidePNGBaselines() throws {
        let slideA = try XCTUnwrap(makeReferenceSlideImage(fill: .systemBlue, accent: .white, title: "ALPHA", textColor: .white))
        let slideB = try XCTUnwrap(makeReferenceSlideImage(fill: .systemOrange, accent: .black, title: "BETA", textColor: .black))

        let hashA = try XCTUnwrap(perceptualHashHex(for: slideA))
        let hashB = try XCTUnwrap(perceptualHashHex(for: slideB))
        let colorA = try XCTUnwrap(averageRGB(for: slideA))
        let colorB = try XCTUnwrap(averageRGB(for: slideB))

        XCTAssertNotEqual(hashA, hashB)
        XCTAssertGreaterThanOrEqual(hammingDistanceHex(lhs: hashA, rhs: hashB), 12)
        XCTAssertGreaterThan(colorDistance(lhs: colorA, rhs: colorB), 0.08)
        XCTAssertFalse(isLikelyFlatHash(hashA))
        XCTAssertFalse(isLikelyFlatHash(hashB))
    }

    func testExportedPDFPageHashesRemainStable() async throws {
        let paths = WorkspacePaths(root: tempRoot)
        try paths.ensureBaseDirectories(fileManager: fileManager)
        let store = LegacyFileStore(paths: paths, fileManager: fileManager)
        let htmlGenerator = HTMLDeckGenerator(paths: paths, store: store, fileManager: fileManager)
        let exporter = PDFDeckExporter(paths: paths, htmlGenerator: htmlGenerator, fileManager: fileManager)

        let first = CaptureRecord(
            filename: "001_reference-a_20260221_1100.png",
            url: URL(string: "https://reference.local/alpha")!,
            capturedAt: Date(timeIntervalSince1970: 1_771_671_000)
        )
        let second = CaptureRecord(
            filename: "002_reference-b_20260221_1101.png",
            url: URL(string: "https://reference.local/beta")!,
            capturedAt: Date(timeIntervalSince1970: 1_771_671_060)
        )

        let slideA = try XCTUnwrap(makeReferenceSlideImage(fill: .systemBlue, accent: .white, title: "ALPHA", textColor: .white))
        let slideB = try XCTUnwrap(makeReferenceSlideImage(fill: .systemOrange, accent: .black, title: "BETA", textColor: .black))
        let pngA = try XCTUnwrap(slideA.pngData)
        let pngB = try XCTUnwrap(slideB.pngData)

        _ = try await store.writeCaptureImage(projectName: WorkspacePaths.defaultProjectName, filename: first.filename, pngData: pngA)
        _ = try await store.writeCaptureImage(projectName: WorkspacePaths.defaultProjectName, filename: second.filename, pngData: pngB)
        try await store.appendCaptureLog(projectName: WorkspacePaths.defaultProjectName, capture: first)
        try await store.appendCaptureLog(projectName: WorkspacePaths.defaultProjectName, capture: second)

        let output = try await exporter.export(projectName: WorkspacePaths.defaultProjectName, requestedTitle: "Visual Baseline")
        let document = try XCTUnwrap(PDFDocument(url: output.fileURL))
        XCTAssertEqual(document.pageCount, 3)

        let pageFingerprints: [(hash: String, color: (Double, Double, Double))] = try (0..<document.pageCount).map { pageIndex in
            let page = try XCTUnwrap(document.page(at: pageIndex))
            let image = try XCTUnwrap(rasterizedImage(for: page))
            let hash = try XCTUnwrap(perceptualHashHex(for: image))
            let color = try XCTUnwrap(averageRGB(for: image))
            return (hash, color)
        }
        let hashes = pageFingerprints.map(\.hash)

        XCTAssertGreaterThanOrEqual(Set(hashes).count, 2)
        XCTAssertGreaterThanOrEqual(hammingDistanceHex(lhs: hashes[0], rhs: hashes[1]), 4)
        XCTAssertGreaterThanOrEqual(hammingDistanceHex(lhs: hashes[1], rhs: hashes[2]), 4)
        XCTAssertGreaterThan(colorDistance(lhs: pageFingerprints[1].color, rhs: pageFingerprints[2].color), 0.05)
        XCTAssertFalse(isLikelyFlatHash(hashes[0]))
        XCTAssertFalse(isLikelyFlatHash(hashes[1]))
        XCTAssertFalse(isLikelyFlatHash(hashes[2]))
    }

    private func makeReferenceSlideImage(fill: NSColor, accent: NSColor, title: String, textColor: NSColor) -> NSImage? {
        let size = WebKitCaptureEngine.viewport
        let image = NSImage(size: size)

        image.lockFocus()
        defer { image.unlockFocus() }

        fill.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        accent.withAlphaComponent(0.24).setFill()
        NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 1760, height: 920), xRadius: 40, yRadius: 40).fill()

        accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: 140, y: 160, width: 820, height: 100), xRadius: 16, yRadius: 16).fill()
        NSBezierPath(roundedRect: NSRect(x: 140, y: 300, width: 1420, height: 58), xRadius: 14, yRadius: 14).fill()
        NSBezierPath(roundedRect: NSRect(x: 140, y: 390, width: 1120, height: 58), xRadius: 14, yRadius: 14).fill()

        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 72, weight: .bold),
            .foregroundColor: textColor
        ]

        let attributed = NSAttributedString(string: title, attributes: textAttributes)
        attributed.draw(at: NSPoint(x: 150, y: 170))

        return image
    }

    private func rasterizedImage(for page: PDFPage) -> NSImage? {
        let mediaBox = page.bounds(for: .mediaBox)
        guard mediaBox.width > 1, mediaBox.height > 1 else { return nil }

        let image = NSImage(size: mediaBox.size)
        image.lockFocus()
        defer { image.unlockFocus() }

        guard let context = NSGraphicsContext.current?.cgContext else { return nil }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(mediaBox)
        page.draw(with: .mediaBox, to: context)

        return image
    }

    private func perceptualHashHex(for image: NSImage, dimension: Int = 16) -> String? {
        guard
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let colorSpace = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
            let context = CGContext(
                data: nil,
                width: dimension,
                height: dimension,
                bitsPerComponent: 8,
                bytesPerRow: dimension,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: dimension, height: dimension))

        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: dimension * dimension)

        var values: [UInt8] = []
        values.reserveCapacity(dimension * dimension)
        for index in 0..<(dimension * dimension) {
            values.append(bytes[index])
        }

        let sum = values.reduce(0, { $0 + Int($1) })
        let average = Double(sum) / Double(values.count)

        var bits = [UInt8](repeating: 0, count: values.count)
        for index in values.indices {
            bits[index] = Double(values[index]) >= average ? 1 : 0
        }

        var output = ""
        output.reserveCapacity((bits.count + 3) / 4)

        var nibble = 0
        var nibbleCount = 0
        for bit in bits {
            nibble = (nibble << 1) | Int(bit)
            nibbleCount += 1
            if nibbleCount == 4 {
                output.append(String(format: "%1x", nibble))
                nibble = 0
                nibbleCount = 0
            }
        }

        if nibbleCount > 0 {
            nibble <<= (4 - nibbleCount)
            output.append(String(format: "%1x", nibble))
        }

        return output
    }

    private func hammingDistanceHex(lhs: String, rhs: String) -> Int {
        let left = hexToBytes(lhs)
        let right = hexToBytes(rhs)
        guard !left.isEmpty, left.count == right.count else {
            return Int.max
        }
        return zip(left, right).reduce(0) { partial, pair in
            partial + (pair.0 ^ pair.1).nonzeroBitCount
        }
    }

    private func isLikelyFlatHash(_ hash: String) -> Bool {
        hash.allSatisfy { $0 == "0" } || hash.allSatisfy { $0 == "f" || $0 == "F" }
    }

    private func averageRGB(for image: NSImage, sampleDimension: Int = 24) -> (Double, Double, Double)? {
        guard
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: sampleDimension,
                height: sampleDimension,
                bitsPerComponent: 8,
                bytesPerRow: sampleDimension * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleDimension, height: sampleDimension))

        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: sampleDimension * sampleDimension * 4)

        var sumR = 0.0
        var sumG = 0.0
        var sumB = 0.0
        let pixelCount = Double(sampleDimension * sampleDimension)

        for index in stride(from: 0, to: sampleDimension * sampleDimension * 4, by: 4) {
            sumR += Double(bytes[index]) / 255.0
            sumG += Double(bytes[index + 1]) / 255.0
            sumB += Double(bytes[index + 2]) / 255.0
        }

        return (sumR / pixelCount, sumG / pixelCount, sumB / pixelCount)
    }

    private func colorDistance(lhs: (Double, Double, Double), rhs: (Double, Double, Double)) -> Double {
        let dr = lhs.0 - rhs.0
        let dg = lhs.1 - rhs.1
        let db = lhs.2 - rhs.2
        return sqrt((dr * dr) + (dg * dg) + (db * db))
    }

    private func hexToBytes(_ value: String) -> [UInt8] {
        guard value.count.isMultiple(of: 2) else { return [] }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(value.count / 2)

        var cursor = value.startIndex
        while cursor < value.endIndex {
            let next = value.index(cursor, offsetBy: 2)
            let token = value[cursor..<next]
            guard let byte = UInt8(token, radix: 16) else { return [] }
            bytes.append(byte)
            cursor = next
        }

        return bytes
    }
}
