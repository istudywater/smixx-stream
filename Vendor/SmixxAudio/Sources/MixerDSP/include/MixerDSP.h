#pragma once
#include <CoreAudio/CoreAudio.h>
#include <stdint.h>
#include "SMEffects.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct SMEngine SMEngine;
SMEngine *sm_create(void);
void sm_destroy(SMEngine *engine);
OSStatus sm_prepare_source(SMEngine *, int source, double rate);
OSStatus sm_prepare_bus(SMEngine *, int bus, double rate);
void sm_set_effect(SMEngine *, int bus, int index, int parameter, float value);
void sm_set_master(SMEngine *, int bus, float gain);
void sm_set_monitor(SMEngine *, int bus, float gain);
void sm_render_monitor(SMEngine *, AudioBufferList *, double rate);
uint64_t sm_effect_errors(SMEngine *);
void sm_set_gain(SMEngine *, int source, int output, float gain);
void sm_set_input_gain(SMEngine *, int source, float gain);
void sm_set_source_rate(SMEngine *, int source, double rate);
// Call reset only after stopping the source AND all output callbacks.
void sm_reset(SMEngine *);
void sm_capture(SMEngine *, int source, const AudioBufferList *, int channel, int stereo);
void sm_render(SMEngine *, int output, AudioBufferList *, double rate);
// Host-time metadata for capture freshness and A/V diagnostics. This does not
// change the inherited ring resampler or promise sample-accurate A/V alignment.
void sm_capture_at_host_time(SMEngine *, int source, const AudioBufferList *, int channel, int stereo, uint64_t hostTime);
uint64_t sm_last_capture_host_time(SMEngine *, int source);
float sm_take_source_peak(SMEngine *, int source);
float sm_take_pre_limiter_peak(SMEngine *, int output);
float sm_take_output_peak(SMEngine *, int output);
uint64_t sm_dropouts(SMEngine *);
uint64_t sm_capture_count(SMEngine *, int source);
uint64_t sm_render_count(SMEngine *, int output);

#ifdef __cplusplus
}
#endif
