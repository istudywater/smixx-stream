import SwiftUI
import AVFoundation
import StreamCore

struct SourcePicker: View {
    @ObservedObject var store: StreamStore
    let index: Int
    @State private var tab = 0
    var body: some View {
        VStack(alignment: .leading,spacing: 18) {
            HStack { Text("Source \(index+1)").font(.title2.bold()); Spacer(); Button("Done") { store.configuring = nil }.keyboardShortcut(.cancelAction) }
            Text("Choose what students see. Audio stays muted until you enable its channel.").foregroundStyle(.secondary)
            Picker("Source type",selection: $tab) { Text("Camera").tag(0); Text("Window / browser").tag(1); Text("Display").tag(2); Text("PDF / media").tag(3) }.pickerStyle(.segmented)
            Group {
                if tab == 0 {
                    let cameras = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera,.external,.continuityCamera],mediaType: .video,position: .unspecified).devices
                    if cameras.isEmpty { Text("No camera found. Connect one, then reopen this picker.").foregroundStyle(.secondary) }
                    List(cameras,id: \.uniqueID) { device in Button { store.configure(index,kind: .camera,name: device.localizedName,identifier: device.uniqueID) } label: { Label(device.localizedName,systemImage: "video") } }
                } else if tab == 1 || tab == 2 {
                    VStack(alignment: .leading) {
                        HStack { Button("Load available screens and windows") { Task { await store.loadPicker() } }; if store.loadingPicker { ProgressView().controlSize(.small) } }
                        Text("macOS may request screen-recording access. Browser audio is application-wide, not isolated by tab.").font(.caption).foregroundStyle(.secondary)
                        if !store.pickerError.isEmpty { Text(store.pickerError).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                        if tab == 1 {
                            List(store.windows,id: \.windowID) { window in
                                Button { store.configure(index,kind: .window,name: window.title?.isEmpty == false ? window.title! : window.owningApplication?.applicationName ?? "Window",identifier: String(window.windowID),appBundle: window.owningApplication?.bundleIdentifier) } label: {
                                    VStack(alignment: .leading) { Text(window.title?.isEmpty == false ? window.title! : "Untitled window"); Text(window.owningApplication?.applicationName ?? "Application").font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        } else {
                            Text("A display source can expose unrelated windows and notifications.").font(.caption).foregroundStyle(.orange)
                            List(store.displays,id: \.displayID) { display in Button("Display \(display.displayID) · \(display.width) × \(display.height)") { store.configure(index,kind: .display,name: "Display \(display.displayID)",identifier: String(display.displayID)) } }
                        }
                    }
                } else {
                    VStack(alignment: .leading,spacing: 18) {
                        Button { store.chooseFile(index,pdf: true) } label: { Label("Open PDF document…",systemImage: "doc.richtext") }
                        Text("Turn pages and zoom inside Stream. Controls stay off the student display.").foregroundStyle(.secondary)
                        Button { store.chooseFile(index,pdf: false) } label: { Label("Open video or audio file…",systemImage: "play.rectangle") }
                        Text("Use Play, Pause and Seek below Program. Audio continues when you switch to another visual source.").foregroundStyle(.secondary)
                        Spacer()
                    }.padding(.top,12)
                }
            }.frame(height: 300)
            HStack { if store.state.sources[index].kind != .empty { Button("Remove source",role: .destructive) { store.clear(index) }; Button("Reconnect saved source") { store.reconnect(index); store.configuring = nil } }; Spacer() }
        }.padding(24).frame(width: 640).preferredColorScheme(.dark)
    }
}
struct SetupView: View {
    @ObservedObject var store: StreamStore
    @ObservedObject var audio: AudioEngine
    var body: some View {
        VStack(alignment: .leading,spacing: 16) {
            HStack { Text("Presentation setup").font(.title2.bold()); Spacer(); Button("Done") { store.setup = false }.keyboardShortcut(.cancelAction) }
            Form {
                Section("Audio destinations") {
                    Picker("Program audio",selection: Binding(get: { store.state.programUID },set: { store.state.programUID = $0; store.changed() })) {
                        Text("None — video only").tag("")
                        ForEach(audio.outputs) { device in Text(device.name).tag(device.uid) }
                    }
                    Text(audio.programStatus).font(.caption).foregroundStyle(.secondary)
                    Picker("Monitor headphones",selection: Binding(get: { store.state.monitorUID },set: { store.state.monitorUID = $0; store.changed() })) {
                        Text("Choose headphones").tag("")
                        ForEach(audio.outputs.filter { !$0.uid.hasPrefix("org.smixx.audio.") }) { device in Text(device.name).tag(device.uid) }
                    }
                    Text(audio.monitorStatus).font(.caption).foregroundStyle(.secondary)
                    HStack { Button("Refresh devices") { audio.refresh(); store.changed() }; Button("Allow microphone access") { store.requestMicrophone() } }
                }
                Section("Teach through a video meeting") {
                    Text("1. Open the clean Program window and share that window in your meeting.\n2. Choose a compatible Smixx Bus as Program audio here and as the meeting microphone.\n3. Send meeting speakers directly to headphones. Keep meeting return out of Stream.\n4. Disable the meeting's separate share-audio option to avoid duplicate media.").font(.callout)
                    Text("The existing Desktop-only driver cannot accept Stream. This build includes upgraded driver source; installation is separate. Quit Desktop before Stream uses a shared virtual bus. A real remote-listener test is still required.").font(.caption).foregroundStyle(.orange)
                    Text("Do not capture a browser that also hosts your meeting; its audio can include remote participants. Use separate applications.").font(.caption).foregroundStyle(.orange)
                }
                Section("Displays and wireless output") {
                    Text("Use Present to open Program on a wired secondary display. For AirPlay, connect an extended display through macOS first, then select it here. Audio routing and delay need validation on your receiver.").font(.callout)
                    Text("Integrated Google Cast, direct AirPlay streaming and virtual camera are not available in this engineering alpha.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Layout and synchronization") {
                    Toggle("Horizontal source strip",isOn: Binding(get: { store.state.horizontal },set: { store.state.horizontal = $0; store.changed() }))
                    HStack { Text("Video delay"); Slider(value: Binding(get: { store.state.videoDelayMS },set: { store.state.videoDelayMS = $0; store.changed() }),in: 0...500,step: 10); Text("\(Int(store.state.videoDelayMS)) ms").monospacedDigit().frame(width: 60) }
                    Text("Manual compensation for audio pipeline delay. Check lip/instrument sync at the destination; automatic A/V synchronization is not certified.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Local settings and diagnostics") {
                    HStack { Button("Export diagnostics…") { store.exportDiagnostics() }; Button("Reset settings…",role: .destructive) {
                        let alert = NSAlert(); alert.messageText = "Reset Stream settings?"; alert.informativeText = "A copy of the current settings will be preserved. Presentation will stop."; alert.addButton(withTitle: "Reset"); alert.addButton(withTitle: "Cancel")
                        if alert.runModal() == .alertFirstButtonReturn { store.resetSettings() }
                    } }
                    Text("Diagnostics may contain source names and device details. Review before sharing. Settings are stored separately from Desktop. Outputs always start off.").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
        }.padding(24).frame(width: 730,height: 800).preferredColorScheme(.dark)
    }
}
