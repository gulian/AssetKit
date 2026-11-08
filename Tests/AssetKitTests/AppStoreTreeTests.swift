import Foundation
import PNG
import Testing
@testable import AssetKit

/// What App Store Connect needs from the BOM trees and from a single-size
/// app icon, checked against uploads: see the comments in BOMTree.swift.
@Suite("App Store Connect tree layout")
struct AppStoreTreeTests {
    private func singleSizeCatalog() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Single-\(UUID().uuidString).xcassets", isDirectory: true)
        let set = root.appendingPathComponent("AppIcon.appiconset", isDirectory: true)
        try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
        try icon1024().write(to: set.appendingPathComponent("icon.png"))
        let json = #"{ "images": [ { "filename": "icon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024" } ], "info": { "author": "xcode", "version": 1 } }"#
        try Data(json.utf8).write(to: set.appendingPathComponent("Contents.json"))
        return root
    }

    private func compile(_ options: OutputOptions = .actoolStructure) async throws -> (CARInspector, CompileResult) {
        let catalog = try singleSizeCatalog()
        defer { try? FileManager.default.removeItem(at: catalog) }
        let result = try await XCAssetCompiler(deploymentTarget: "17.0", options: options).compile(catalog: catalog)
        return (CARInspector(result.carData), result)
    }

    @Test("Tree headers carry the key length")
    func treeHeaderKeyLength() async throws {
        let (car, _) = try await compile()
        for (name, length) in [("RENDITIONS", 20), ("FACETKEYS", 7), ("APPEARANCEKEYS", 15)] {
            let tree = try #require(car.variable(name))
            #expect(tree.count == 29)
            #expect(be32(tree, 21) == UInt32(length), "\(name)")
            #expect(be32(tree, 25) == 0)
        }
    }

    @Test("Leaves copy every key after the entries")
    func leafKeyCopy() async throws {
        let (car, _) = try await compile()
        for name in ["RENDITIONS", "FACETKEYS", "APPEARANCEKEYS"] {
            let tree = try #require(car.variable(name))
            let leaf = car.block(Int(be32(tree, 8)))
            let entries = car.treeEntries(name)
            let start = 12 + 8 * entries.count
            #expect(leaf[leaf.startIndex + start..<leaf.startIndex + start + 4].allSatisfy { $0 == 0 })
            let copy = leaf[leaf.startIndex + start + 4..<leaf.startIndex + start + 4 + entries.reduce(0) { $0 + $1.key.count }]
            #expect(Data(copy) == entries.reduce(Data()) { $0 + $1.key }, "\(name)")
            #expect(leaf.count == 4096 + entries.reduce(0) { $0 + $1.key.count })
        }
    }

    @Test("Keys of different lengths: variable length, no key copy")
    func variableKeyLength() async throws {
        let catalog = try singleSizeCatalog()
        defer { try? FileManager.default.removeItem(at: catalog) }
        let set = catalog.appendingPathComponent("HeroBackgroundImageLarge.imageset", isDirectory: true)
        try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
        try icon1024().write(to: set.appendingPathComponent("hero.png"))
        let json = #"{ "images": [ { "filename": "hero.png", "idiom": "universal", "scale": "1x" } ], "info": { "author": "xcode", "version": 1 } }"#
        try Data(json.utf8).write(to: set.appendingPathComponent("Contents.json"))
        let result = try await XCAssetCompiler(deploymentTarget: "17.0").compile(catalog: catalog)
        let car = CARInspector(result.carData)

        let facets = try #require(car.variable("FACETKEYS"))
        #expect(be32(facets, 21) == 0xFFFF_FFFF)
        let leaf = car.block(Int(be32(facets, 8)))
        #expect(leaf.count == 4096)
        let entries = car.treeEntries("FACETKEYS")
        #expect(Set(entries.map { String(decoding: $0.key, as: UTF8.self) }) == ["AppIcon", "HeroBackgroundImageLarge"])
        let start = 12 + 8 * entries.count
        #expect(leaf[leaf.startIndex + start..<leaf.startIndex + 4096].allSatisfy { $0 == 0 })

        // the rendition keys still all have the same length
        let renditions = try #require(car.variable("RENDITIONS"))
        #expect(be32(renditions, 21) == 20)
    }

    @Test("A single-size icon stores only the master, for iPhone and iPad")
    func singleSizeMaster() async throws {
        let (car, result) = try await compile()
        let renditions = car.renditions
        // key = appearance, localization, scale, idiom, subtype, dim2, dim1, identifier, element, part
        let bitmaps = renditions.filter { $0.key[9] == 220 }
        #expect(bitmaps.count == 2)
        #expect(Set(bitmaps.map { $0.key[3] }) == [1, 2])
        #expect(bitmaps.allSatisfy { $0.width == 1024 && $0.key[2] == 1 && $0.key[5] == 1 })
        let records = renditions.filter { $0.key[9] == 218 }
        #expect(Set(records.map { $0.key[3] }) == [1, 2])
        // the smaller sizes are still in the bundle as loose files
        let loose = try #require(result.appIconBundle).looseFiles.map(\.name)
        #expect(loose.contains("AppIcon60x60@2x.png"))
        #expect(loose.contains("AppIcon76x76@2x.png"))
    }

    @Test("Without singleSizeMaster, the master is expanded into every size")
    func expandedWithoutOption() async throws {
        let (car, _) = try await compile(OutputOptions.actoolStructure.subtracting(.singleSizeMaster))
        #expect(car.renditions.filter { $0.key[9] == 220 }.count > 2)
    }
}

private func icon1024() -> Data {
    let rgba = [PNG.RGBA<UInt8>](repeating: PNG.RGBA<UInt8>(24, 92, 200, 255), count: 1024 * 1024)
    let image = PNG.Image(
        packing: rgba,
        size: (x: 1024, y: 1024),
        layout: PNG.Layout(format: .rgba8(palette: [], fill: nil))
    )
    var stream = MemoryBytestreamDestination()
    try! image.compress(stream: &stream)
    return Data(stream.bytes)
}

@Suite("Bitmap pixel mode")
struct PixelModeTests {
    @Test("Images are written with alpha (1), app icons as opaque (3)")
    func pixelMode() {
        let pixels = [UInt8](repeating: 0, count: 4 * 4 * 4)
        let image = MLECBody.encode(width: 4, height: 4, pixelsBGRA: pixels, pixelMode: .alpha)
        let icon = MLECBody.encode(width: 4, height: 4, pixelsBGRA: pixels, pixelMode: .opaque)
        #expect(Array(image[image.startIndex + 4..<image.startIndex + 12]) == [1, 0, 0, 0, 4, 0, 0, 0])
        #expect(Array(icon[icon.startIndex + 4..<icon.startIndex + 12]) == [3, 0, 0, 0, 4, 0, 0, 0])
    }
}

@Suite("Bitmap row padding")
struct RowPaddingTests {
    @Test("Rows are padded to 32 bytes, in the TLV and in the pixels")
    func rowPadding() throws {
        for (width, expected) in [(20, 96), (29, 128), (87, 352), (167, 672), (180, 736), (256, 1024)] {
            #expect(MLECBody.bytesPerRow(width: UInt32(width)) == expected, "\(width)")
        }
        // 29 px wide, 3 rows: each stored row is 128 bytes, the last 12 zero
        let width = 29, height = 3
        let pixels = [UInt8](repeating: 0xAB, count: width * 4 * height)
        let body = MLECBody.encode(width: UInt32(width), height: UInt32(height), pixelsBGRA: pixels)
        // one KCBC chunk per row (3 rows divide by 3): MLEC header 16 bytes, chunk header 20 bytes
        var offset = 16
        for _ in 0..<3 {
            let size = Int(u32(body, offset + 16))
            let raw = LZFSE.decode(Array(body[body.startIndex + offset + 20..<body.startIndex + offset + 20 + size]))
            #expect(raw.count == 128)
            #expect(raw.prefix(116).allSatisfy { $0 == 0xAB })
            #expect(raw.suffix(12).allSatisfy { $0 == 0 })
            offset += 20 + size
        }
    }
}
