// Exercise the exact driver callbacks in-process. This is NOT installed-HAL evidence.
#include "../Driver.cpp"
#include <cstdio>
#include <cstdlib>
static void expect(bool condition, const char* message) {
    if (!condition) { std::fprintf(stderr, "FAIL: %s\n", message); std::exit(1); }
}
int main() {
    auto driver = createDriver(); auto plugin = driver->GetPlugin();
    expect(plugin->GetDeviceCount() == 3, "three devices");
    const char* uids[] = {"org.smixx.audio.meeting", "org.smixx.audio.out2", "org.smixx.audio.recording"};
    for (unsigned i = 0; i < 3; ++i) {
        auto device = plugin->GetDeviceByID(plugin->GetDeviceIDByUID(uids[i]));
        expect(device && device->GetName() == "Smixx Bus " + std::to_string(i+1), "numbered endpoint with stable UID");
        expect(device->GetStreamCount(aspl::Direction::Input) == 1 && device->GetStreamCount(aspl::Direction::Output) == 1, "duplex stereo feed");
        expect(device->GetNominalSampleRate() == 48000, "fixed sample rate");
        auto* control = device->GetControlHandler(); expect(control->OnStartIO() == noErr, "start");
        aspl::ClientInfo appInfo; appInfo.ClientID = 1; appInfo.ProcessID = 101; appInfo.BundleID = "org.smixx.desktop";
        aspl::ClientInfo otherInfo; otherInfo.ClientID = 2; otherInfo.BundleID = "com.other.player";
        aspl::ClientInfo readerInfo; readerInfo.ClientID = 3; readerInfo.BundleID = "com.microsoft.teams2";
        auto app = control->OnAddClient(appInfo), other = control->OnAddClient(otherInfo), reader = control->OnAddClient(readerInfo);
        auto outStream = device->GetStreamByIndex(aspl::Direction::Output, 0);
        auto inStream = device->GetStreamByIndex(aspl::Direction::Input, 0);
        expect(inStream->GetVirtualFormat().mFormatFlags & kAudioFormatFlagIsFloat, "float PCM compatible with current adapter");
        auto* io = device->GetIOHandler(); float samples[] = {.25, -.25, .5, -.5}; float readback[4];
        io->OnWriteClientOutput(other, outStream, 0, 4096, samples, 2, 2);
        io->OnReadClientInput(reader, inStream, 0, 4096 + smixx::TimelineBuffer::latency, readback, sizeof(readback));
        expect(readback[0] == 0, "unrelated app output ignored");
        io->OnWriteClientOutput(app, outStream, 0, 4096, samples, 2, 2);
        io->OnReadClientInput(reader, inStream, 0, 4096 + smixx::TimelineBuffer::latency, readback, sizeof(readback));
        expect(readback[0] == .25 && readback[3] == -.5, "app audio reaches microphone reader");
        io->OnReadClientInput(other, inStream, 0, 4096 + smixx::TimelineBuffer::latency, readback, sizeof(readback));
        expect(readback[0] == .25, "second consumer does not drain first consumer");
        io->OnReadClientInput(reader, inStream, 0, 4098 + smixx::TimelineBuffer::latency, readback, sizeof(readback));
        expect(readback[0] == 0 && readback[3] == 0, "silence after supplied frames end");
        aspl::ClientInfo streamInfo; streamInfo.ClientID = 4; streamInfo.ProcessID = 104; streamInfo.BundleID = "org.smixx.stream";
        auto stream = control->OnAddClient(streamInfo);
        io->OnWriteClientOutput(stream, outStream, 0, 8192, samples, 2, 2);
        io->OnReadClientInput(reader, inStream, 0, 8192 + smixx::TimelineBuffer::latency, readback, sizeof(readback));
        expect(readback[0] == 0, "Stream cannot steal Desktop writer ownership");
        auto* feed = static_cast<FeedHandler*>(control);
        CFStringRef owner = feed->CopyOwnerPID(); expect(CFStringCompare(owner, CFSTR("101"), 0) == kCFCompareEqualTo, "owner PID reported"); CFRelease(owner);
        control->OnRemoveClient(app);
        io->OnWriteClientOutput(stream, outStream, 0, 8192, samples, 2, 2);
        io->OnReadClientInput(reader, inStream, 0, 8192 + smixx::TimelineBuffer::latency, readback, sizeof(readback));
        expect(readback[0] == .25, "Stream delivers after Desktop releases ownership");
        owner = feed->CopyOwnerPID(); expect(CFStringCompare(owner, CFSTR("104"), 0) == kCFCompareEqualTo, "Stream owner PID reported"); CFRelease(owner);
        control->OnRemoveClient(stream); control->OnStopIO();
    }
    std::puts("PASS: driver construction, fixed identities/formats, producer filtering, multi-reader delivery, stop-supply silence");
}
