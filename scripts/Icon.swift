import AppKit
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
for size in [16,32,64,128,256,512,1024] {
    let s = CGFloat(size)
    let ctx = CGContext(data:nil,width:size,height:size,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red:0.075,green:0.08,blue:0.12,alpha:1))
    ctx.addPath(CGPath(roundedRect:CGRect(x:s*0.05,y:s*0.05,width:s*0.9,height:s*0.9),cornerWidth:s*0.2,cornerHeight:s*0.2,transform:nil));ctx.fillPath()
    for (i,height) in [CGFloat(0.2),0.37,0.56,0.37,0.2].enumerated() {
        ctx.setFillColor(CGColor(red:0.65,green:0.34,blue:0.93,alpha:1))
        ctx.addPath(CGPath(roundedRect:CGRect(x:s*(0.23+CGFloat(i)*0.115),y:s*(1-height)/2,width:s*0.08,height:s*height),cornerWidth:s*0.04,cornerHeight:s*0.04,transform:nil));ctx.fillPath()
    }
    let data=NSBitmapImageRep(cgImage:ctx.makeImage()!).representation(using:.png,properties:[:])!
    if size <= 512 { try data.write(to:folder.appendingPathComponent("icon_\(size)x\(size).png")) }
    if size >= 32 { try data.write(to:folder.appendingPathComponent("icon_\(size/2)x\(size/2)@2x.png")) }
}
