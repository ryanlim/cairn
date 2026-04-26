import Foundation
import CoreGraphics

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public enum ThumbHashDecoder {

    public static func decode(_ data: Data) -> Data? {
        let bytes = Array(data)
        guard bytes.count >= 5 else { return nil }

        let header1 = Int(bytes[0]) | (Int(bytes[1]) << 8) | (Int(bytes[2]) << 16)
        let header2 = Int(bytes[3]) | (Int(bytes[4]) << 8)

        let lDC = Double(header1 & 63) / 63.0
        let pDC = Double((header1 >> 6) & 63) / 63.0
        let qDC = Double((header1 >> 12) & 63) / 63.0
        let lScale = Double((header1 >> 18) & 31) / 31.0
        let hasAlpha = (header1 >> 23) != 0

        let pScale = Double(header2 & 63) / 63.0
        let qScale = Double((header2 >> 6) & 63) / 63.0
        let isLandscape = (header2 >> 12) & 1 != 0

        let lx: Int
        let ly: Int
        if hasAlpha {
            lx = isLandscape ? 5 : 3
            ly = isLandscape ? 3 : 5
        } else {
            lx = max(3, isLandscape ? 7 : 5)
            ly = max(3, isLandscape ? 5 : 7)
        }

        let aDC: Double
        let aScale: Double
        if hasAlpha {
            guard bytes.count >= 6 else { return nil }
            let header3 = Int(bytes[5])
            aDC = Double(header3 & 15) / 15.0
            aScale = Double((header3 >> 4) & 15) / 15.0
        } else {
            aDC = 1.0
            aScale = 0
        }

        let ratio = Double(lx) / Double(ly)
        let w: Int
        let h: Int
        if isLandscape {
            w = max(1, Int((32.0 * ratio).rounded()))
            h = 32
        } else {
            w = 32
            h = max(1, Int((32.0 / ratio).rounded()))
        }

        let headerBits = hasAlpha ? 48 : 40
        var bitIndex = headerBits

        func readAC(nx: Int, ny: Int, scale: Double) -> [Double] {
            var ac: [Double] = []
            for cy in 0..<ny {
                for _ in 0..<(cy == 0 ? nx - 1 : nx) {
                    let byteIdx = bitIndex / 8
                    let bitOff = bitIndex % 8
                    guard byteIdx < bytes.count else {
                        ac.append(0)
                        bitIndex += 4
                        continue
                    }
                    var val = Int(bytes[byteIdx]) >> bitOff
                    if byteIdx + 1 < bytes.count {
                        val |= Int(bytes[byteIdx + 1]) << (8 - bitOff)
                    }
                    val &= 0xF
                    bitIndex += 4
                    ac.append((Double(val) / 7.5 - 1.0) * scale)
                }
            }
            return ac
        }

        let lAC = readAC(nx: lx, ny: ly, scale: lScale)
        let pAC = readAC(nx: 3, ny: 3, scale: pScale)
        let qAC = readAC(nx: 3, ny: 3, scale: qScale)
        let aAC: [Double]
        let ax: Int
        let ay: Int
        if hasAlpha {
            ax = isLandscape ? 5 : 3
            ay = isLandscape ? 3 : 5
            aAC = readAC(nx: ax, ny: ay, scale: aScale)
        } else {
            ax = 0
            ay = 0
            aAC = []
        }

        var rgba = [UInt8](repeating: 255, count: w * h * 4)

        let cosLx = makeCosines(size: w, n: lx)
        let cosLy = makeCosines(size: h, n: ly)
        let cosPx = makeCosines(size: w, n: 3)
        let cosPy = makeCosines(size: h, n: 3)
        let cosAx = hasAlpha ? makeCosines(size: w, n: ax) : []
        let cosAy = hasAlpha ? makeCosines(size: h, n: ay) : []

        for y in 0..<h {
            for x in 0..<w {
                var l = lDC
                var p = pDC
                var q = qDC
                var a = aDC

                var lIdx = 0
                for cy in 0..<ly {
                    let cxStart = cy == 0 ? 1 : 0
                    for cx in cxStart..<lx {
                        l += lAC[lIdx] * cosLx[x][cx] * cosLy[y][cy]
                        lIdx += 1
                    }
                }

                var pIdx = 0
                for cy in 0..<3 {
                    let cxStart = cy == 0 ? 1 : 0
                    for cx in cxStart..<3 {
                        p += pAC[pIdx] * cosPx[x][cx] * cosPy[y][cy]
                        pIdx += 1
                    }
                }

                var qIdx = 0
                for cy in 0..<3 {
                    let cxStart = cy == 0 ? 1 : 0
                    for cx in cxStart..<3 {
                        q += qAC[qIdx] * cosPx[x][cx] * cosPy[y][cy]
                        qIdx += 1
                    }
                }

                if hasAlpha {
                    var aIdx = 0
                    for cy in 0..<ay {
                        let cxStart = cy == 0 ? 1 : 0
                        for cx in cxStart..<ax {
                            a += aAC[aIdx] * cosAx[x][cx] * cosAy[y][cy]
                            aIdx += 1
                        }
                    }
                }

                let b = l - 2.0 / 3.0 * p
                let r = (3.0 * l - b + q) / 2.0
                let g = r - q

                let pixelIdx = (y * w + x) * 4
                rgba[pixelIdx + 0] = clampByte(r * 255.0)
                rgba[pixelIdx + 1] = clampByte(g * 255.0)
                rgba[pixelIdx + 2] = clampByte(b * 255.0)
                rgba[pixelIdx + 3] = clampByte(a * 255.0)
            }
        }

        return rgbaToPNG(rgba: rgba, width: w, height: h)
    }

    #if canImport(UIKit)
    public static func decodeToUIImage(_ data: Data) -> UIImage? {
        guard let pngData = decode(data) else { return nil }
        return UIImage(data: pngData)
    }
    #endif

    private static func clampByte(_ v: Double) -> UInt8 {
        UInt8(max(0, min(255, Int(v.rounded()))))
    }

    private static func makeCosines(size: Int, n: Int) -> [[Double]] {
        (0..<size).map { pos in
            let fx = Double.pi * Double(pos) / Double(size)
            return (0..<n).map { i in
                cos(fx * (Double(i) + 0.5))
            }
        }
    }

    private static func rgbaToPNG(rgba: [UInt8], width: Int, height: Int) -> Data? {
        let bytesPerRow = width * 4
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else { return nil }

        #if canImport(UIKit)
        return UIImage(cgImage: cgImage).pngData()
        #elseif canImport(AppKit)
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:])
        #else
        return nil
        #endif
    }
}
