#pragma once
#include <AudioToolbox/AudioToolbox.h>
#define SM_BLOCK 256
#define SM_FX_VALUES 14
typedef struct SMEffects SMEffects;
// Allocate/prepare only while this chain's capture or bus callback is stopped.
SMEffects *sm_fx_create(void);
void sm_fx_destroy(SMEffects *);
OSStatus sm_fx_prepare(SMEffects *, double rate, int bus);
void sm_fx_set(SMEffects *, int parameter, float value);
void sm_fx_process(SMEffects *, float samples[SM_BLOCK][2], unsigned count, int stage);
uint64_t sm_fx_errors(SMEffects *);
