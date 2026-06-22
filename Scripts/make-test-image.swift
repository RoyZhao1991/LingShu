import AppKit

// 测试/验证用:生成一张带指定文字的 PNG(给本机知识照片源做 live 验证)。
// 用法:swift Scripts/make-test-image.swift "文字" /输出/path.png
let args = CommandLine.arguments
guard args.count >= 3 else { FileHandle.standardError.write(Data("usage: make-test-image.swift <text> <out.png>\n".utf8)); exit(1) }
let text = args[1]
let out = args[2]
let size = NSSize(width: 820, height: 240)
let img = NSImage(size: size)
img.lockFocus()
NSColor.white.setFill()
NSRect(origin: .zero, size: size).fill()
(text as NSString).draw(at: NSPoint(x: 30, y: 100),
    withAttributes: [.font: NSFont.systemFont(ofSize: 54), .foregroundColor: NSColor.black])
img.unlockFocus()
guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(2) }
try? png.write(to: URL(fileURLWithPath: out))
