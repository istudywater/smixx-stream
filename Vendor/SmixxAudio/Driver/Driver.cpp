// Smixx Audio feasibility driver. libASPL is statically linked; see ThirdParty notices.
#include "TimelineBuffer.hpp"
#include <aspl/Driver.hpp>
#include <CoreAudio/AudioServerPlugIn.h>

namespace {
constexpr UInt32 rate = 48000;
class FeedClient final : public aspl::Client {
public:
    explicit FeedClient(const aspl::ClientInfo& info) : aspl::Client(info),
        producer(info.BundleID == "org.smixx.desktop" || info.BundleID == "org.smixx.stream" || info.BundleID == "org.smixx.transport-probe") {}
    const bool producer; // Computed on the control thread, never inspect strings in I/O.
};
class FeedHandler final : public aspl::ControlRequestHandler, public aspl::IORequestHandler {
public:
    OSStatus OnStartIO() override { timeline.clear(); owner.store(UINT64_MAX); return noErr; }
    std::shared_ptr<aspl::Client> OnAddClient(const aspl::ClientInfo& info) override {
        return std::make_shared<FeedClient>(info);
    }
    void OnRemoveClient(std::shared_ptr<aspl::Client> client) override {
        uint64_t expected = owner.load();
        if (uint32_t(expected) == client->GetClientID()) owner.compare_exchange_strong(expected, UINT64_MAX);
    }
    void OnWriteClientOutput(const std::shared_ptr<aspl::Client>& client,
        const std::shared_ptr<aspl::Stream>&, Float64, Float64 timestamp,
        const Float32* frames, UInt32 frameCount, UInt32 channelCount) override {
        if (!client || !static_cast<const FeedClient*>(client.get())->producer || channelCount != 2 || !valid(timestamp)) return;
        const uint64_t id = (uint64_t(uint32_t(client->GetProcessID())) << 32) | client->GetClientID();
        uint64_t empty = UINT64_MAX; owner.compare_exchange_strong(empty, id);
        if (owner.load() != id) return;
        timeline.write(static_cast<int64_t>(timestamp), frames, frameCount);
    }
    void OnReadClientInput(const std::shared_ptr<aspl::Client>&,
        const std::shared_ptr<aspl::Stream>&, Float64, Float64 timestamp,
        void* bytes, UInt32 count) override {
        std::memset(bytes, 0, count);
        if (!valid(timestamp) || count % (2 * sizeof(float))) return;
        timeline.read(static_cast<int64_t>(timestamp), static_cast<float*>(bytes), count / (2 * sizeof(float)));
    }
    CFStringRef CopyOwnerPID() const {
        const uint64_t value = owner.load();
        return CFStringCreateWithFormat(kCFAllocatorDefault, nullptr, CFSTR("%u"), value == UINT64_MAX ? 0u : uint32_t(value >> 32));
    }
private:
    static bool valid(double t) { return std::isfinite(t) && t >= 0 && t < double(INT64_MAX / 2) && std::floor(t) == t; }
    smixx::TimelineBuffer timeline;
    std::atomic<uint64_t> owner{UINT64_MAX};
};
std::shared_ptr<aspl::Driver> createDriver() {
    auto context = std::make_shared<aspl::Context>(std::make_shared<aspl::Tracer>(aspl::Tracer::Mode::Noop));
    auto plugin = std::make_shared<aspl::Plugin>(context);
    for (const auto& feed : {std::pair{"Smixx Bus 1", "org.smixx.audio.meeting"}, std::pair{"Smixx Bus 2", "org.smixx.audio.out2"}, std::pair{"Smixx Bus 3", "org.smixx.audio.recording"}}) {
        aspl::DeviceParameters p;
        p.Name = feed.first; p.DeviceUID = feed.second; p.Manufacturer = "The Smixx Project";
        p.ModelUID = "org.smixx.audio.virtual.v2"; p.ConfigurationApplicationBundleID = "org.smixx.desktop";
        p.SampleRate = rate; p.ChannelCount = 2; p.EnableMixing = false;
        p.CanBeDefault = true; p.CanBeDefaultForSystemSounds = false;
        p.Latency = 0; p.SafetyOffset = 256; p.ZeroTimeStampPeriod = 512;
        p.EnableRealtimeTracing = false;
        auto device = std::make_shared<aspl::Device>(context, p);
        for (auto direction : {aspl::Direction::Input, aspl::Direction::Output}) {
            aspl::StreamParameters stream;
            stream.Direction = direction;
            stream.Latency = direction == aspl::Direction::Input ? smixx::TimelineBuffer::latency : 0;
            stream.Format = {};
            stream.Format.mSampleRate = rate;
            stream.Format.mFormatID = kAudioFormatLinearPCM;
            stream.Format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
            stream.Format.mBitsPerChannel = 32; stream.Format.mChannelsPerFrame = 2;
            stream.Format.mFramesPerPacket = 1; stream.Format.mBytesPerFrame = 8; stream.Format.mBytesPerPacket = 8;
            device->AddStreamAsync(stream);
        }
        auto handler = std::make_shared<FeedHandler>();
        device->RegisterCustomProperty(0x736d6f77, [handler]() -> CFStringRef { return handler->CopyOwnerPID(); }); // smow, read-only owner PID
        device->SetControlHandler(handler); device->SetIOHandler(handler); plugin->AddDevice(device);
    }
    return std::make_shared<aspl::Driver>(context, plugin);
}
}
extern "C" __attribute__((visibility("default"))) void* SmixxAudioEntryPoint(CFAllocatorRef, CFUUIDRef type) {
    if (!CFEqual(type, kAudioServerPlugInTypeUUID)) return nullptr;
    static auto driver = createDriver();
    return driver->GetReference();
}
