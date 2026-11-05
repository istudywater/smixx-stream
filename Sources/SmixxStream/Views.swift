import SwiftUI
import AppKit
import AVFoundation
import StreamCore
import SmixxCore

private let accent = Color(red: 0.64, green: 0.35, blue: 0.92)
private let panel = Color(red: 0.12, green: 0.13, blue: 0.17)

struct ProgramCanvas: View {
    @ObservedObject var store: StreamStore
    var output = false
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if (!output || store.presenting) && !store.paused, let frame = store.frames[store.state.active] {
                    let source = store.state.sources[store.state.active]
                    let canvas = Routing.videoRect(width: 16,height: 9,canvasWidth: geo.size.width,canvasHeight: geo.size.height,scaling: .fit)
                    let image = Routing.videoRect(width: Double(frame.image.width), height: Double(frame.image.height), canvasWidth: canvas.width, canvasHeight: canvas.height, scaling: source.scaling)
                    Image(decorative: frame.image, scale: 1).resizable()
                        .frame(width: image.width, height: image.height)
                        .scaleEffect(source.kind == .pdf ? source.zoom : 1)
                        .frame(width: canvas.width, height: canvas.height).clipped()
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: store.paused ? "pause.circle" : "rectangle.on.rectangle").font(.system(size: 40, weight: .ultraLight)).foregroundStyle(accent)
                        Text(store.paused ? "Presentation paused" : output ? "Ready for the lesson" : "Your lesson starts here").font(.title2.weight(.medium))
                        if !output { Text("Add a camera, a document, or a browser window.").font(.subheadline).foregroundStyle(.secondary) }
                    }.foregroundStyle(.white)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
        }.background(.black).accessibilityLabel(output ? "Student-facing Program" : "Program preview")
    }
}
struct ContentView: View {
    @ObservedObject var store: StreamStore
    @State private var destinations = false
    var body: some View {
        VStack(spacing: 18) {
            header
            if store.state.horizontal {
                program
                HStack(spacing: 12) { ForEach(0..<4) { sourceTile($0) } }.frame(height: 130)
            } else {
                HStack(alignment: .top, spacing: 20) {
                    VStack(spacing: 12) { ForEach(0..<4) { sourceTile($0) } }.frame(width: 220)
                    program
                }
            }
            MixerView(store: store, audio: store.audio)
            HStack {
                Circle().fill(store.presenting ? (store.paused ? .orange : .green) : .gray).frame(width: 7,height: 7)
                Text(store.presenting ? (store.paused ? "Presentation paused" : "Program window open · receiver unverified") : "Not presenting").font(.caption.weight(.medium))
                Spacer()
                Text("LOCAL FIRST  ·  SMIXX STREAM").font(.system(size: 10,weight: .medium,design: .monospaced)).foregroundStyle(.secondary)
            }
            Text(store.message).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity,alignment: .leading).lineLimit(3)
        }
        .padding(24).frame(minWidth: 1080,minHeight: 820)
        .background(Color(red: 0.075,green: 0.08,blue: 0.11)).preferredColorScheme(.dark).tint(accent)
        .sheet(isPresented: Binding(get: { store.configuring != nil }, set: { if !$0 { store.configuring = nil } })) { if let index = store.configuring { SourcePicker(store: store,index: index) } }
        .sheet(isPresented: $store.setup) { SetupView(store: store,audio: store.audio) }
    }
    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 3) { ForEach(Array([12.0,22,32,22,12].enumerated()),id: \.offset) { _,h in Capsule().fill(accent).frame(width: 5,height: h) } }.accessibilityHidden(true)
            Text("Smixx").font(.title2.bold()) + Text(" Stream").font(.title2.bold()).foregroundColor(accent)
            Text("TEACHING STUDIO").font(.system(size: 10,weight: .semibold,design: .monospaced)).foregroundStyle(.secondary).padding(.leading,12)
            Spacer()
            if store.presenting {
                Button { store.togglePause() } label: { Label(store.paused ? "Resume" : "Pause",systemImage: store.paused ? "play.fill" : "pause.fill") }
                Button("Stop") { store.stopPresentation() }
            }
            Button { destinations = true } label: { Label("Present",systemImage: "display") }
                .buttonStyle(.borderedProminent).tint(accent)
                .popover(isPresented: $destinations) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Present your lesson").font(.headline)
                        Button("Open clean Program window") { destinations = false; store.openProgram() }
                        ForEach(Array(NSScreen.screens.enumerated()),id: \.offset) { index,screen in
                            if index > 0 { Button("Present on \(screen.localizedName)") { destinations = false; store.openProgram(screen: screen) } }
                        }
                        Divider()
                        Button("Conference / audio setup…") { destinations = false; store.setup = true }
                    }.padding(20)
                }
            Button { store.setup = true } label: { Image(systemName: "slider.horizontal.3").font(.title3) }.buttonStyle(.plain).help("Audio, output and layout settings").accessibilityLabel("Settings")
        }
    }
    private var program: some View {
        VStack(alignment: .leading,spacing: 10) {
            HStack { Text("PROGRAM").font(.system(size: 11,weight: .bold,design: .monospaced)).foregroundStyle(accent); Spacer(); Text("16:9  /  1080p target").font(.caption2).foregroundStyle(.secondary) }
            ProgramCanvas(store: store).aspectRatio(16/9,contentMode: .fit).frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(accent.opacity(0.5),lineWidth: 1))
            HStack(spacing: 14) {
                Text(store.state.sources[store.state.active].name).font(.headline).lineLimit(1)
                Spacer()
                Picker("Scale",selection: Binding(get: { store.state.sources[store.state.active].scaling },set: { store.state.sources[store.state.active].scaling = $0; store.changed() })) { Text("Fit").tag(Scaling.fit); Text("Fill").tag(Scaling.fill) }.pickerStyle(.segmented).labelsHidden().frame(width: 110)
            }
            sourceControls
            Text(store.sourceStatus[store.state.active]).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 0)
        }
    }
    @ViewBuilder private var sourceControls: some View {
        let source = store.state.sources[store.state.active]
        if source.kind == .pdf {
            HStack {
                Button { store.turnPage(-1) } label: { Image(systemName: "chevron.left") }.disabled(source.page == 0).help("Previous page")
                Text("Page \(source.page+1) of \(store.pageCount)").monospacedDigit().font(.caption)
                Button { store.turnPage(1) } label: { Image(systemName: "chevron.right") }.disabled(source.page+1 >= store.pageCount).help("Next page")
                Spacer()
                Text("Zoom").font(.caption)
                Slider(value: Binding(get: { source.zoom },set: { store.state.sources[store.state.active].zoom = $0; store.changed() }),in: 1...3).frame(width: 140)
                Text("\(Int(source.zoom*100))%").font(.caption).monospacedDigit()
            }
        } else if source.kind == .media {
            HStack {
                Button { store.togglePlay() } label: { Label(store.playing ? "Pause" : "Play",systemImage: store.playing ? "pause.fill" : "play.fill") }
                Slider(value: Binding(get: { min(store.playhead,max(store.duration,1)) },set: { store.seek($0) }),in: 0...max(store.duration,1)).disabled(store.duration <= 0)
                Text("\(Int(store.playhead)) / \(Int(store.duration)) s").font(.caption.monospacedDigit())
            }
        } else if source.kind != .empty {
            HStack { Image(systemName: "info.circle"); Text("Interact with browser pages in their original window.") }.font(.caption).foregroundStyle(.secondary)
        }
    }
    private func sourceTile(_ index: Int) -> some View {
        let source = store.state.sources[index]
        return VStack(spacing: 5) {
            Button { store.select(index) } label: {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8).fill(panel)
                    if let frame = store.frames[index] { Image(decorative: frame.image,scale: 1).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 8)) }
                    else { VStack(spacing: 6) { Image(systemName: source.kind == .empty ? "plus" : "arrow.clockwise").font(.title2); Text(source.kind == .empty ? "Add source" : "Reconnect source").font(.caption) }.frame(maxWidth: .infinity,maxHeight: .infinity).foregroundStyle(.secondary) }
                    Text("\(index+1)").font(.caption.bold()).padding(5).background(store.state.active == index ? accent : .black.opacity(0.6),in: RoundedRectangle(cornerRadius: 4)).padding(7)
                }.aspectRatio(16/9,contentMode: .fit).overlay(RoundedRectangle(cornerRadius: 8).stroke(store.state.active == index ? accent : .white.opacity(0.08),lineWidth: store.state.active == index ? 2 : 1))
            }.buttonStyle(.plain).keyboardShortcut(KeyEquivalent(Character(String(index+1))),modifiers: [.command]).accessibilityLabel("Source \(index+1): \(source.name)")
            HStack {
                Text(source.kind == .empty ? "Source \(index+1)" : source.name).font(.caption.weight(.medium)).lineLimit(1)
                Spacer()
                if source.kind != .empty { Button { store.reconnect(index) } label: { Image(systemName: "arrow.clockwise") }.help("Reconnect source") }
                Button { store.configuring = index } label: { Image(systemName: "ellipsis") }.help("Configure source \(index+1)")
            }.buttonStyle(.plain)
        }
    }
}

struct MixerView: View {
    @ObservedObject var store: StreamStore
    @ObservedObject var audio: AudioEngine
    var body: some View {
        VStack(alignment: .leading,spacing: 12) {
            HStack { Text("AUDIO MIX").font(.system(size: 11,weight: .bold,design: .monospaced)); Spacer(); Text("Video switching keeps your audio mix unchanged").font(.caption).foregroundStyle(.secondary) }
            HStack(alignment: .top,spacing: 10) {
                ForEach(0..<6) { i in strip(i) }
                Divider().frame(height: 165)
                master("MON",index: 6,color: .teal,value: Binding(get: { store.state.monitorGain },set: { store.state.monitorGain = $0; store.changed() }))
                master("PGM",index: 7,color: .teal,value: Binding(get: { store.state.programGain },set: { store.state.programGain = $0; store.changed() }))
            }
        }.padding(16).background(panel,in: RoundedRectangle(cornerRadius: 12))
    }
    private func strip(_ i: Int) -> some View {
        let color: Color = i < 4 ? .orange : .pink
        return VStack(spacing: 8) {
            HStack { Text(i < 4 ? "S\(i+1)" : "A\(i-3)").font(.caption.bold()); Spacer(); Menu { audioChoices(i) } label: { Image(systemName: "cable.connector") }.menuStyle(.borderlessButton).fixedSize().help("Assign audio") }.foregroundStyle(color)
            HStack(spacing: 6) {
                Meter(level: audio.levels[i],color: color).frame(width: 7,height: 80)
                Slider(value: Binding(get: { store.state.channels[i].gain },set: { store.state.channels[i].gain = $0; store.changed() }),in: 0...1).rotationEffect(.degrees(-90)).frame(width: 80,height: 80).accessibilityLabel("Channel gain")
            }.frame(maxWidth: .infinity)
            HStack {
                Button(store.state.channels[i].muted ? "Muted" : "On") { store.state.channels[i].muted.toggle(); store.changed() }.tint(store.state.channels[i].muted ? .gray : color)
                Toggle(isOn: Binding(get: { store.state.channels[i].monitor },set: { store.state.channels[i].monitor = $0; store.changed() })) { Image(systemName: "headphones") }.toggleStyle(.button).accessibilityLabel("Monitor channel \(i+1)").help("Include in local Monitor")
            }.controlSize(.small)
            Text(audio.status[i]).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2).frame(height: 25).help(audio.status[i])
        }.padding(9).frame(maxWidth: .infinity).background(color.opacity(0.06),in: RoundedRectangle(cornerRadius: 8))
    }
    @ViewBuilder private func audioChoices(_ i: Int) -> some View {
        if i < 4 && store.state.sources[i].kind == .media { Text("Audio follows this media file") }
        else {
            Button("No audio") { store.state.channels[i].sourceIdentity = ""; store.changed() }
            ForEach(audio.availableInputs,id: \.identity) { source in
                Button(source.name) { store.state.channels[i].sourceIdentity = source.identity; if source.kind == .device { store.requestMicrophone() }; store.changed() }
            }
            Divider(); Button("Refresh audio devices") { audio.refresh() }
        }
    }
    private func master(_ title: String,index: Int,color: Color,value: Binding<Double>) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.caption.bold()).foregroundStyle(color)
            HStack(spacing: 6) { Meter(level: audio.levels[index],color: color).frame(width: 7,height: 80); Slider(value: value,in: 0...1).rotationEffect(.degrees(-90)).frame(width: 80,height: 80) }
            if index == 6 { Button(audio.monitorEnabled ? "Monitor on" : "Monitor off") { audio.monitorEnabled.toggle(); store.changed() }.controlSize(.small) }
            else { Text(store.presenting && !store.paused ? "Sending" : "Off").font(.caption).foregroundStyle(.secondary).frame(height: 20) }
            Text(index == 6 ? "Local listening" : "Student audio").font(.system(size: 9)).foregroundStyle(.secondary).frame(height: 25)
        }.padding(9).frame(maxWidth: .infinity).background(color.opacity(0.06),in: RoundedRectangle(cornerRadius: 8))
    }
}
struct Meter: View {
    let level: Float
    let color: Color
    var body: some View {
        GeometryReader { geo in ZStack(alignment: .bottom) {
            Capsule().fill(.white.opacity(0.08))
            Capsule().fill(level >= 0.98 ? .red : color).frame(height: max(0,geo.size.height * min(1,Double(level).squareRoot())))
        } }.accessibilityLabel("Signal level").accessibilityValue("\(Int(min(1,max(0,level))*100)) percent")
    }
}
