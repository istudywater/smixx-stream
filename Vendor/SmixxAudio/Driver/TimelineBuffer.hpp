#pragma once
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>

namespace smixx {
// A timestamp-addressed buffer, not a destructive queue: multiple independent
// microphone readers receive the same frames. Missing/old frames are silence.
// One admitted producer per device. No callback allocates or takes our locks.
class TimelineBuffer {
public:
    static constexpr uint32_t capacity = 32768;
    static constexpr int64_t latency = 2048; // 42.67 ms at fixed 48 kHz; prototype budget.
    TimelineBuffer() { clear(); }
    void clear() noexcept {
        for (auto& slot : slots_) { slot.tag.store(invalid); slot.bits.store(0); }
    }
    void write(int64_t timestamp, const float* stereo, uint32_t frames) noexcept {
        if (frames > capacity || timestamp < 0 || timestamp > INT64_MAX - frames) return;
        for (uint32_t i = 0; i < frames; ++i) {
            float values[2] = {safe(stereo[i * 2]), safe(stereo[i * 2 + 1])};
            uint64_t bits; std::memcpy(&bits, values, sizeof(bits));
            auto& slot = slots_[(uint64_t(timestamp) + i) & (capacity - 1)];
            // Sequentially consistent atomics make both stamp checks bracket
            // the data read, even when an old slot wraps during a reader callback.
            slot.tag.store(invalid); slot.bits.store(bits); slot.tag.store(timestamp + i);
        }
    }
    void read(int64_t timestamp, float* stereo, uint32_t frames) const noexcept {
        std::memset(stereo, 0, size_t(frames) * 2 * sizeof(float));
        if (timestamp < latency || timestamp > INT64_MAX - frames) return;
        const auto first = timestamp - latency;
        for (uint32_t i = 0; i < frames; ++i) {
            const auto expected = first + i;
            const auto& slot = slots_[uint64_t(expected) & (capacity - 1)];
            if (slot.tag.load() != expected) continue;
            const uint64_t bits = slot.bits.load();
            if (slot.tag.load() == expected) std::memcpy(stereo + i * 2, &bits, sizeof(bits));
        }
    }
private:
    static constexpr int64_t invalid = -1;
    static float safe(float v) noexcept { return std::isfinite(v) ? std::fmax(-1.f, std::fmin(1.f, v)) : 0; }
    struct Slot { std::atomic<int64_t> tag; std::atomic<uint64_t> bits; };
    static_assert(std::atomic<uint64_t>::is_always_lock_free, "Driver needs lock-free 64-bit atomics");
    std::array<Slot, capacity> slots_;
};
}
