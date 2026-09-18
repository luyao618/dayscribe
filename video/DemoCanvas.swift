import AppKit
final class Canvas: NSView {
 override var isFlipped: Bool { true }
 override func draw(_ dirtyRect: NSRect) {
  NSColor(calibratedRed:0.955,green:0.960,blue:0.978,alpha:1).setFill();bounds.fill()
  func text(_ s:String,_ x:CGFloat,_ y:CGFloat,_ size:CGFloat,_ weight:NSFont.Weight = .regular,_ color:NSColor = .labelColor) {
   (s as NSString).draw(at:NSPoint(x:x,y:y),withAttributes:[.font:NSFont.systemFont(ofSize:size,weight:weight),.foregroundColor:color])
  }
  let purple=NSColor(calibratedRed:0.44,green:0.40,blue:0.81,alpha:1)
  let green=NSColor(calibratedRed:0.22,green:0.60,blue:0.50,alpha:1)
  text("SCRIBER  /  产品讨论",48,38,16,.medium,purple)
  text("把这一段，留下来。",48,102,42,.semibold)
  text("会议里的想法，值得再听一次。",48,168,22,.regular,.secondaryLabelColor)
  let rows=[("01","确认今天的重点"),("02","记录讨论和决定"),("03","让后续行动更清楚")]
  for (i,row) in rows.enumerated() {
   let y:CGFloat=240+CGFloat(i)*88
   NSColor.white.setFill();NSBezierPath(roundedRect:NSRect(x:48,y:y,width:570,height:64),xRadius:15,yRadius:15).fill()
   text(row.0,68,y+20,16,.medium,green);text(row.1,118,y+17,23,.medium)
  }
  text("演示内容",48,540,15,.regular,.secondaryLabelColor)
  let heights:[CGFloat]=[28,55,86,122,94,64,106,144,97,55,24]
  for (i,h) in heights.enumerated() {
   (i<6 ? purple : green).setFill()
   NSBezierPath(roundedRect:NSRect(x:710+CGFloat(i)*20,y:320-h/2,width:8,height:h),xRadius:4,yRadius:4).fill()
  }
 }
}
let app=NSApplication.shared
app.setActivationPolicy(.regular)
let window=NSWindow(contentRect:NSRect(x:60,y:330,width:1040,height:610),styleMask:[.titled,.closable],backing:.buffered,defer:false)
window.title="Scriber · 演示内容"
window.contentView=Canvas()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps:true)
app.run()
