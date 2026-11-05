#include "MixerDSP.h"
#include "SMEffects.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#define SOURCES 6
#define OUTPUTS 4
#define CAPACITY 32768
#define MASK (CAPACITY - 1)
// Every ring has exactly one capture producer and one output consumer.
// Audio callbacks allocate nothing and never acquire locks.
typedef struct {
    float samples[CAPACITY][2];
    _Atomic uint64_t write;
    _Atomic uint64_t read;
    _Atomic uint64_t discardBefore;
    double phase;
    int primed;
    float currentGain;
} Ring;
struct SMEngine {
    _Atomic uint64_t captureHostTimes[SOURCES];
    Ring rings[SOURCES][OUTPUTS];
    _Atomic float gains[SOURCES][OUTPUTS];
    _Atomic float inputGains[SOURCES];
    float currentInputGains[SOURCES], currentMaster[OUTPUTS];
    _Atomic float master[OUTPUTS];
    SMEffects *sourceFX[SOURCES], *busFX[OUTPUTS];
    _Atomic double rates[SOURCES];
    _Atomic float sourcePeaks[SOURCES], outputPeaks[OUTPUTS], preLimiterPeaks[OUTPUTS];
    _Atomic uint64_t captures[SOURCES], renders[OUTPUTS], dropouts;
};
static void peak(_Atomic float *p, float v) {
    float old = atomic_load_explicit(p, memory_order_relaxed);
    while (v > old && !atomic_compare_exchange_weak_explicit(p, &old, v, memory_order_relaxed, memory_order_relaxed)) {}
}
SMEngine *sm_create(void) {
    SMEngine *e = calloc(1, sizeof(SMEngine));
    if(e){
        for(int i=0;i<SOURCES;i++) { atomic_store(&e->inputGains[i],1);e->currentInputGains[i]=1;atomic_store(&e->rates[i],48000);e->sourceFX[i]=sm_fx_create(); }
        for(int o=0;o<OUTPUTS;o++) { atomic_store(&e->master[o],1);e->currentMaster[o]=1;e->busFX[o]=sm_fx_create();sm_fx_set(e->busFX[o],10,1); }
    }
    if(e){for(int i=0;i<SOURCES;i++)if(!e->sourceFX[i]){sm_destroy(e);return NULL;}for(int o=0;o<OUTPUTS;o++)if(!e->busFX[o]){sm_destroy(e);return NULL;}}
    return e;
}
void sm_destroy(SMEngine *e) { if(e){for(int i=0;i<SOURCES;i++)sm_fx_destroy(e->sourceFX[i]);for(int o=0;o<OUTPUTS;o++)sm_fx_destroy(e->busFX[o]);free(e);} }
OSStatus sm_prepare_source(SMEngine *e,int s,double rate) {
    e->currentInputGains[s]=atomic_load(&e->inputGains[s]);
    for(int o=0;o<OUTPUTS;o++)atomic_store(&e->rings[s][o].discardBefore,atomic_load(&e->rings[s][o].write));
    sm_set_source_rate(e,s,rate); return sm_fx_prepare(e->sourceFX[s],rate,0);
}
OSStatus sm_prepare_bus(SMEngine *e,int o,double rate) {
    e->currentMaster[o]=atomic_load(&e->master[o]);
    for(int s=0;s<SOURCES;s++){Ring *r=&e->rings[s][o];atomic_store(&r->read,atomic_load(&r->write));r->primed=0;r->phase=0;r->currentGain=0;}
    return sm_fx_prepare(e->busFX[o],rate,1);
}
void sm_set_effect(SMEngine *e,int bus,int index,int parameter,float value){sm_fx_set(bus?e->busFX[index]:e->sourceFX[index],parameter,value);}
void sm_set_master(SMEngine *e,int o,float gain){atomic_store(&e->master[o],gain);}
void sm_set_monitor(SMEngine *e,int bus,float gain){(void)bus;sm_set_master(e,3,gain);}
uint64_t sm_effect_errors(SMEngine *e){uint64_t n=0;for(int s=0;s<SOURCES;s++)n+=sm_fx_errors(e->sourceFX[s]);for(int o=0;o<OUTPUTS;o++)n+=sm_fx_errors(e->busFX[o]);return n;}
void sm_set_gain(SMEngine *e, int s, int o, float g) { atomic_store(&e->gains[s][o], isfinite(g) ? g : 0); }
void sm_set_input_gain(SMEngine *e, int s, float g) { atomic_store(&e->inputGains[s], g); }
void sm_set_source_rate(SMEngine *e, int s, double r) { atomic_store(&e->rates[s], r); }
void sm_reset(SMEngine *e) { memset(e->rings, 0, sizeof(e->rings)); }
static unsigned frames(const AudioBufferList *b) {
    if (!b || !b->mNumberBuffers || !b->mBuffers[0].mNumberChannels) return 0;
    return b->mBuffers[0].mDataByteSize / (sizeof(float) * b->mBuffers[0].mNumberChannels);
}
static float sample(const AudioBufferList *b, unsigned frame, int channel) {
    for (unsigned j = 0; j < b->mNumberBuffers; j++) {
        const AudioBuffer *v = &b->mBuffers[j];
        if (channel < (int)v->mNumberChannels) {
            if (!v->mData || (frame * v->mNumberChannels + channel + 1) * sizeof(float) > v->mDataByteSize) return 0;
            float value = ((float *)v->mData)[frame * v->mNumberChannels + channel];
            return isfinite(value) ? value : 0;
        }
        channel -= v->mNumberChannels;
    }
    return 0;
}
static void put(AudioBufferList *b, unsigned frame, int channel, float value) {
    for (unsigned j = 0; j < b->mNumberBuffers; j++) {
        AudioBuffer *v = &b->mBuffers[j];
        if (channel < (int)v->mNumberChannels) {
            if (v->mData && (frame * v->mNumberChannels + channel + 1) * sizeof(float) <= v->mDataByteSize)
                ((float *)v->mData)[frame * v->mNumberChannels + channel] = value;
            return;
        }
        channel -= v->mNumberChannels;
    }
}
void sm_capture(SMEngine *e, int s, const AudioBufferList *b, int channel, int stereo) {
    unsigned n = frames(b); if (!n) return;
    atomic_fetch_add(&e->captures[s], 1);
    float p = 0, inputGain = atomic_load(&e->inputGains[s]);
    uint64_t writes[OUTPUTS]; int canWrite[OUTPUTS];
    for (int o = 0; o < OUTPUTS; o++) {
        Ring *r = &e->rings[s][o]; writes[o] = atomic_load_explicit(&r->write, memory_order_relaxed);
        canWrite[o] = n < CAPACITY && writes[o] - atomic_load_explicit(&r->read, memory_order_acquire) + n < CAPACITY;
        // Inactive outputs can fill; do not count them as an audible overrun.
        if (!canWrite[o] && atomic_load(&e->gains[s][o]) > 0) atomic_fetch_add(&e->dropouts, 1);
    }
    float block[SM_BLOCK][2];
    for(unsigned base=0;base<n;base+=SM_BLOCK){
        unsigned count=n-base<SM_BLOCK?n-base:SM_BLOCK;
        for(unsigned f=0;f<count;f++){
            e->currentInputGains[s]+=(inputGain-e->currentInputGains[s])*.002f;
            block[f][0]=sample(b,base+f,channel)*e->currentInputGains[s];
            block[f][1]=(stereo?sample(b,base+f,channel+1):sample(b,base+f,channel))*e->currentInputGains[s];
        }
        sm_fx_process(e->sourceFX[s],block,count,0);sm_fx_process(e->sourceFX[s],block,count,1);
        for(unsigned f=0;f<count;f++){
            p=fmaxf(p,fmaxf(fabsf(block[f][0]),fabsf(block[f][1])));
            for(int o=0;o<OUTPUTS;o++)if(canWrite[o])for(int c=0;c<2;c++) e->rings[s][o].samples[(writes[o]+base+f)&MASK][c]=block[f][c];
        }
    }
    for (int o = 0; o < OUTPUTS; o++) if (canWrite[o]) atomic_store_explicit(&e->rings[s][o].write, writes[o] + n, memory_order_release);
    peak(&e->sourcePeaks[s], p);
}
void sm_render(SMEngine *e, int o, AudioBufferList *b, double rate) {
    unsigned n = frames(b); if (!n || rate <= 0 || o<0 || o>=OUTPUTS) return;
    for (unsigned j = 0; j < b->mNumberBuffers; j++) if (b->mBuffers[j].mData) memset(b->mBuffers[j].mData, 0, b->mBuffers[j].mDataByteSize);
    atomic_fetch_add(&e->renders[o], 1);
    // Fixed-size chunks avoid allocation even for unusually large hardware buffers.
    float mix[256][2]; float outputPeak = 0;
    for (unsigned base = 0; base < n; base += 256) {
        unsigned count = n - base < 256 ? n - base : 256; memset(mix, 0, sizeof(mix));
        for (int s = 0; s < SOURCES; s++) {
            Ring *r = &e->rings[s][o];
            uint64_t w = atomic_load_explicit(&r->write, memory_order_acquire), rd = atomic_load_explicit(&r->read, memory_order_relaxed);
            uint64_t discard=atomic_load(&r->discardBefore);if(rd<discard){rd=discard;r->phase=0;r->primed=0;}
            double ratio = atomic_load(&e->rates[s]) / rate;
            uint64_t target = (uint64_t)fmax(512, atomic_load(&e->rates[s]) * .012);
            float gain = atomic_load(&e->gains[s][o]);
            // Discard stale audio after a stopped consumer or long scheduling pause.
            if (w - rd > target * 4) { rd = w - target; r->phase = 0; r->primed = 1; }
            if (!r->primed && w - rd >= target) r->primed = 1;
            if (!r->primed) continue;
            // Small occupancy correction accommodates independent device clocks.
            double correction = fmax(-.005, fmin(.005, ((double)(w - rd) - target) / (target * 200.0)));
            ratio *= 1 + correction;
            if (gain == 0) r->currentGain = 0; // Mute must not leak a fade-out tail.
            for (unsigned f = 0; f < count; f++) {
                if (rd + 1 >= w) { r->primed = 0; if (gain > 0) atomic_fetch_add(&e->dropouts, 1); break; }
                if (gain > 0) r->currentGain += (gain - r->currentGain) * .008f;
                for (int c = 0; c < 2; c++) {
                    float a = r->samples[rd & MASK][c], bb = r->samples[(rd + 1) & MASK][c];
                    mix[f][c] += (a + (bb - a) * r->phase) * r->currentGain;
                }
                r->phase += ratio; uint64_t step = (uint64_t)r->phase; r->phase -= step;
                rd += step; if (rd > w) rd = w;
            }
            atomic_store_explicit(&r->read, rd, memory_order_release);
        }
        sm_fx_process(e->busFX[o],mix,count,1);
        float master=atomic_load(&e->master[o]);
        for(unsigned f=0;f<count;f++){
            if(master==0)e->currentMaster[o]=0;else e->currentMaster[o]+=(master-e->currentMaster[o])*.008f;
            for(int c=0;c<2;c++)mix[f][c]*=e->currentMaster[o];
        }
        for(unsigned f=0;f<count;f++)peak(&e->preLimiterPeaks[o],fmaxf(fabsf(mix[f][0]),fabsf(mix[f][1])));
        sm_fx_process(e->busFX[o],mix,count,2);
        for (unsigned f = 0; f < count; f++) for (int c = 0; c < 2; c++) {
            // Mute also silences delayed effect tails immediately.
            float value=master==0?0:mix[f][c];if(!isfinite(value))value=0;
            outputPeak = fmaxf(outputPeak, fabsf(value));
            put(b, base + f, c, value);
        }

    }
    peak(&e->outputPeaks[o], outputPeak);
}
float sm_take_source_peak(SMEngine *e, int s) { return atomic_exchange(&e->sourcePeaks[s], 0); }
float sm_take_output_peak(SMEngine *e, int o) { return atomic_exchange(&e->outputPeaks[o], 0); }
uint64_t sm_dropouts(SMEngine *e) { return atomic_load(&e->dropouts); }
uint64_t sm_capture_count(SMEngine *e, int s) { return atomic_load(&e->captures[s]); }
uint64_t sm_render_count(SMEngine *e, int o) { return atomic_load(&e->renders[o]); }

// Headphones consume their own per-source rings, independent of outgoing bus callbacks.
void sm_render_monitor(SMEngine *e,AudioBufferList *b,double rate){sm_render(e,3,b,rate);}

float sm_take_pre_limiter_peak(SMEngine *e,int o){return atomic_exchange(&e->preLimiterPeaks[o],0);}

void sm_capture_at_host_time(SMEngine *e, int s, const AudioBufferList *b, int channel, int stereo, uint64_t hostTime) {
    if (!e || s < 0 || s >= SOURCES) return;
    atomic_store(&e->captureHostTimes[s], hostTime);
    sm_capture(e, s, b, channel, stereo);
}
uint64_t sm_last_capture_host_time(SMEngine *e, int s) {
    return e && s >= 0 && s < SOURCES ? atomic_load(&e->captureHostTimes[s]) : 0;
}
