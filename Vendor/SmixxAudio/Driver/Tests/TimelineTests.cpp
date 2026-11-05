#include "../TimelineBuffer.hpp"
#include <cstdio>
#include <cstdlib>
#include <thread>
#include <vector>
static void check(bool v, const char* message) { if (!v) { std::fprintf(stderr, "FAIL: %s\n", message); std::exit(1); } }
int main() {
    auto meeting = std::make_unique<smixx::TimelineBuffer>();
    auto recording = std::make_unique<smixx::TimelineBuffer>();
    float audio[] = {.25f, -.25f, .5f, -.5f}; float out[4] = {1,1,1,1};
    meeting->read(4096, out, 2); check(out[0] == 0 && out[3] == 0, "cold silence");
    meeting->write(4096, audio, 2);
    meeting->read(4096 + smixx::TimelineBuffer::latency, out, 2); check(out[0] == .25f && out[3] == -.5f, "stereo exact delivery");
    meeting->read(4096 + smixx::TimelineBuffer::latency, out, 2); check(out[0] == .25f, "independent reader gets same samples");
    recording->read(4096 + smixx::TimelineBuffer::latency, out, 2); check(out[0] == 0, "feed isolation");
    meeting->read(4098 + smixx::TimelineBuffer::latency, out, 2); check(out[0] == 0 && out[3] == 0, "producer stop gives silence");
    meeting->write(4096 + smixx::TimelineBuffer::capacity, audio, 2);
    meeting->read(4096 + smixx::TimelineBuffer::latency, out, 2); check(out[0] == 0, "wrapped stale data never replayed");
    meeting->clear(); meeting->read(4096 + smixx::TimelineBuffer::capacity + smixx::TimelineBuffer::latency, out, 2); check(out[0] == 0, "restart clears old data");
    float invalid[] = {NAN, INFINITY, 4, -4}; meeting->write(32, invalid, 2);
    meeting->read(32 + smixx::TimelineBuffer::latency, out, 2); check(out[0] == 0 && out[1] == 0 && out[2] == 1 && out[3] == -1, "finite bounded samples");
    std::thread writer([&] { for (int i = 0; i < 200000; ++i) { float pair[] = {.1f, -.1f}; meeting->write(i, pair, 1); } });
    for (int i = 0; i < 200000; ++i) { float pair[2]; meeting->read(i + smixx::TimelineBuffer::latency, pair, 1); check(pair[0] == -pair[1], "concurrent stereo frame consistency"); }
    writer.join(); std::puts("PASS: timestamp delivery, independent readers, isolation, silence, wrap, restart, sanitization, concurrency");
}
