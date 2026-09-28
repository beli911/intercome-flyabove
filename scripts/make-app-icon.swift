#!/usr/bin/env swift
//
// Renders the Flycom app icon from the "1b" logo direction: a level meter of
// four bars, which is the sound itself rather than a picture of a microphone.
//
// The proportions come straight from the design's 96pt master, so the icon and
// the in-app mark are the same drawing at different sizes. The icon inverts the
// colours — yellow bars on black — because a phone lives on a dark home screen
// and in a dark gallery, which is what the design asks for.
//
// Usage: swift scripts/make-app-icon.swift <output.png> [size]

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The 96pt master, as fractions so any size renders identically.
enum Mark {
    static let barWidth = 9.0 / 96
    static let barGap = 7.0 / 96
    static let bottomInset = 22.0 / 96
    /// 24, 40, 56, 32 at the master size: a meter caught mid-syllable, not a
    /// tidy ramp. A symmetric shape would read as a chart.
    static let barHeights = [24.0 / 96, 40.0 / 96, 56.0 / 96, 32.0 / 96]

    static var blockWidth: Double {
        Double(barHeights.count) * barWidth + Double(barHeights.count - 1) * barGap
    }
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("Használat: make-app-icon.swift <kimenet.png> [méret]\n".utf8))
    exit(1)
}
let outputPath = arguments[1]
let size = arguments.count > 2 ? (Int(arguments[2]) ?? 1024) : 1024

let black = CGColor(red: 0x0B / 255, green: 0x0B / 255, blue: 0x0C / 255, alpha: 1)
let yellow = CGColor(red: 0xFF / 255, green: 0xD4 / 255, blue: 0x00 / 255, alpha: 1)

guard let context = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    // No alpha: an app icon must be fully opaque.
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    FileHandle.standardError.write(Data("Nem sikerült a rajzfelület.\n".utf8))
    exit(1)
}

let canvas = Double(size)
context.setFillColor(black)
context.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))

context.setFillColor(yellow)
let barWidth = Mark.barWidth * canvas
let gap = Mark.barGap * canvas
let bottom = Mark.bottomInset * canvas
var x = (canvas - Mark.blockWidth * canvas) / 2

for height in Mark.barHeights {
    context.fill(CGRect(x: x, y: bottom, width: barWidth, height: height * canvas))
    x += barWidth + gap
}

guard let image = context.makeImage() else {
    FileHandle.standardError.write(Data("Nem sikerült a kép.\n".utf8))
    exit(1)
}

let url = URL(fileURLWithPath: outputPath)
guard let destination = CGImageDestinationCreateWithURL(
    url as CFURL,
    UTType.png.identifier as CFString,
    1,
    nil
) else {
    FileHandle.standardError.write(Data("Nem sikerült a fájl megnyitása.\n".utf8))
    exit(1)
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("Nem sikerült a mentés.\n".utf8))
    exit(1)
}

print("\(outputPath) — \(size)×\(size)")
