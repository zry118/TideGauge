//
//  潮汐表图标：深海底 + 两道潮汐波 + 浪尖光点 + 顶部仪表刻度
//  用法: makeicon out.png
//

import AppKit
import CoreGraphics
import Foundation

let args = CommandLine.arguments
let out = args.count > 1 ? args[1] : "/tmp/tide-icon.png"
let S: CGFloat = 1024
let space = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: Int(S), height: Int(S),
                    bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

let R: CGFloat = 229
let bgPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: S, height: S),
                    cornerWidth: R, cornerHeight: R, transform: nil)

// 背景
ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()
let bgGrad = CGGradient(colorsSpace: space,
                        colors: [CGColor(red: 0.10, green: 0.19, blue: 0.28, alpha: 1),
                                 CGColor(red: 0.035, green: 0.065, blue: 0.10, alpha: 1)] as CFArray,
                        locations: [0, 1])!
ctx.drawLinearGradient(bgGrad, start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0), options: [])
// 顶部微光
let glow = CGGradient(colorsSpace: space,
                      colors: [CGColor(gray: 1, alpha: 0.10), CGColor(gray: 1, alpha: 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow,
                       startCenter: CGPoint(x: S / 2, y: S * 0.16), startRadius: 0,
                       endCenter: CGPoint(x: S / 2, y: S * 0.16), endRadius: S * 0.72, options: [])
ctx.restoreGState()

// 顶部仪表刻度
ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()
ctx.setStrokeColor(CGColor(red: 0.55, green: 0.75, blue: 0.88, alpha: 0.45))
ctx.setLineWidth(10)
ctx.setLineCap(.round)
for k in 0..<5 {
    let x = S * (0.28 + 0.11 * CGFloat(k))
    let len: CGFloat = k == 2 ? 56 : 34
    ctx.move(to: CGPoint(x: x, y: 225))
    ctx.addLine(to: CGPoint(x: x, y: 225 + len))
}
ctx.strokePath()
ctx.restoreGState()

// 潮汐波：主浪青色 + 副浪玉色，相位错开
func wave(_ amp: CGFloat, _ yBase: CGFloat, _ phase: CGFloat,
          _ color: CGColor, _ width: CGFloat) {
    let p = CGMutablePath()
    var first = true
    var x: CGFloat = 120
    while x <= S - 120 {
        let t = (x - 120) / (S - 240)
        let y = yBase + amp * sin(t * .pi * 2.0 + phase)
        if first { p.move(to: CGPoint(x: x, y: y)); first = false }
        else { p.addLine(to: CGPoint(x: x, y: y)) }
        x += 6
    }
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    ctx.addPath(p)
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.strokePath()
    ctx.restoreGState()
}

wave(70, 540, 0.0, CGColor(red: 0.35, green: 0.80, blue: 0.98, alpha: 1), 26)
wave(50, 465, 1.2, CGColor(red: 0.36, green: 0.86, blue: 0.62, alpha: 0.75), 15)

// 主浪浪尖（t=0.25 处 sin 取最大值）的光点
let dot = CGPoint(x: 120 + 0.25 * (S - 240), y: 540 - 70)
let halo = CGGradient(colorsSpace: space,
                      colors: [CGColor(red: 0.50, green: 0.85, blue: 1, alpha: 0.55),
                               CGColor(red: 0.50, green: 0.85, blue: 1, alpha: 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(halo, startCenter: dot, startRadius: 0,
                       endCenter: dot, endRadius: 170, options: [])
ctx.setFillColor(CGColor(red: 0.85, green: 0.97, blue: 1, alpha: 1))
ctx.fillEllipse(in: CGRect(x: dot.x - 27, y: dot.y - 27, width: 54, height: 54))

// 内描边
ctx.saveGState()
ctx.addPath(bgPath)
ctx.setStrokeColor(CGColor(red: 0.55, green: 0.78, blue: 0.92, alpha: 0.30))
ctx.setLineWidth(3)
ctx.strokePath()
ctx.restoreGState()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
let png = rep.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: out))
print("icon -> \(out)")
