#include "SMEffects.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#define DELAY 8192
typedef struct { UInt32 count; AudioBuffer buffers[2]; } StereoList;
typedef struct {
    AudioUnit unit;
    float left[SM_BLOCK], right[SM_BLOCK];
    float dry[DELAY][2], wet[DELAY][2];
    unsigned cursor, latency, padding;
    double sampleTime;
    float blend;
} Stage;
struct SMEffects {
    Stage stages[3];
    _Atomic float values[SM_FX_VALUES];
    float current[SM_FX_VALUES];
    double rate;
    int ready, bus;
    _Atomic uint64_t errors;
};
static OSStatus input(void *ctx, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time, UInt32 bus, UInt32 n, AudioBufferList *data) {
    Stage *s = ctx;
    if (n > SM_BLOCK || data->mNumberBuffers != 2) return kAudio_ParamError;
    for (int c=0;c<2;c++) {
        float *src = c ? s->right : s->left;
        if (data->mBuffers[c].mData) memcpy(data->mBuffers[c].mData, src, n*sizeof(float));
        else data->mBuffers[c].mData = src;
        data->mBuffers[c].mDataByteSize=n*sizeof(float);
    }
    return noErr;
}
SMEffects *sm_fx_create(void) {
    SMEffects *f=calloc(1,sizeof(*f));
    if(f){float defaults[SM_FX_VALUES]={0,80,0,0,0,0,-18,10,.01,.1,0,.002,.005,0};
        for(int i=0;i<SM_FX_VALUES;i++){atomic_store(&f->values[i],defaults[i]);f->current[i]=defaults[i];}}
    return f;
}
static void dispose(SMEffects *f){for(int i=0;i<3;i++)if(f->stages[i].unit){AudioUnitUninitialize(f->stages[i].unit);AudioComponentInstanceDispose(f->stages[i].unit);}memset(f->stages,0,sizeof(f->stages));f->ready=0;}
void sm_fx_destroy(SMEffects *f){if(f){dispose(f);free(f);}}
void sm_fx_set(SMEffects *f,int p,float value){if(f&&p>=0&&p<SM_FX_VALUES&&isfinite(value))atomic_store(&f->values[p],value);}
static OSStatus param(Stage *s, UInt32 id,float v){return AudioUnitSetParameter(s->unit,id,kAudioUnitScope_Global,0,v,0);}
OSStatus sm_fx_prepare(SMEffects *f,double rate,int bus){
    if(!f || rate<32000 || rate>192000)return kAudio_ParamError;
    dispose(f);f->rate=rate;f->bus=bus;
    OSType types[3]={kAudioUnitSubType_NBandEQ,kAudioUnitSubType_DynamicsProcessor,kAudioUnitSubType_PeakLimiter};
    OSStatus status=0;
    for(int i=0;i<3;i++){
        if((bus&&i==0)||(!bus&&i==2))continue;
        Stage *s=&f->stages[i];
        AudioComponentDescription d={kAudioUnitType_Effect,types[i],kAudioUnitManufacturer_Apple,0,0};
        AudioComponent component=AudioComponentFindNext(NULL,&d);if(!component){status=kAudioUnitErr_InvalidProperty;goto fail;}
        if((status=AudioComponentInstanceNew(component,&s->unit)))goto fail;
        AudioStreamBasicDescription format={rate,kAudioFormatLinearPCM,kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked|kAudioFormatFlagIsNonInterleaved,4,1,4,2,32,0};
        if((status=AudioUnitSetProperty(s->unit,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Input,0,&format,sizeof(format))))goto fail;
        if((status=AudioUnitSetProperty(s->unit,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Output,0,&format,sizeof(format))))goto fail;
        UInt32 max=SM_BLOCK;
        if((status=AudioUnitSetProperty(s->unit,kAudioUnitProperty_MaximumFramesPerSlice,kAudioUnitScope_Global,0,&max,sizeof(max))))goto fail;
        AURenderCallbackStruct callback={input,s};
        if((status=AudioUnitSetProperty(s->unit,kAudioUnitProperty_SetRenderCallback,kAudioUnitScope_Input,0,&callback,sizeof(callback))))goto fail;
        if(i==0){
            UInt32 bands=4;
            if((status=AudioUnitSetProperty(s->unit,kAUNBandEQProperty_NumberOfBands,kAudioUnitScope_Global,0,&bands,sizeof(bands))))goto fail;
            int filters[4]={kAUNBandEQFilterType_2ndOrderButterworthHighPass,kAUNBandEQFilterType_LowShelf,kAUNBandEQFilterType_Parametric,kAUNBandEQFilterType_HighShelf};
            float hz[4]={80,150,1000,6000};
            for(int b=0;b<4;b++){param(s,kAUNBandEQParam_BypassBand+b,0);param(s,kAUNBandEQParam_FilterType+b,filters[b]);param(s,kAUNBandEQParam_Frequency+b,hz[b]);param(s,kAUNBandEQParam_Bandwidth+b,1);}
        }else if(i==1){param(s,kDynamicsProcessorParam_ExpansionRatio,1);param(s,kDynamicsProcessorParam_OverallGain,0);}
        else param(s,kLimiterParam_AttackTime,.002); // Fixed 2 ms lookahead keeps latency stable during edits.
        if((status=AudioUnitInitialize(s->unit)))goto fail;
        double latency=0;UInt32 size=sizeof(latency);
        if((status=AudioUnitGetProperty(s->unit,kAudioUnitProperty_Latency,kAudioUnitScope_Global,0,&latency,&size)))goto fail;
        unsigned native=(unsigned)llround(latency*rate);
        s->latency=i==1?(unsigned)ceil(rate*.01):native;
        if(native>s->latency||s->latency>=DELAY){status=kAudioUnitErr_TooManyFramesToProcess;goto fail;}
        s->padding=s->latency-native;
        // Warm allocations on control thread before the HAL callback starts.
        StereoList list={2,{{1,SM_BLOCK*4,s->left},{1,SM_BLOCK*4,s->right}}};
        AudioTimeStamp t={0};t.mFlags=kAudioTimeStampSampleTimeValid;AudioUnitRenderActionFlags flags=0;
        if((status=AudioUnitRender(s->unit,&flags,&t,0,SM_BLOCK,(AudioBufferList*)&list)))goto fail;
        AudioUnitReset(s->unit,kAudioUnitScope_Global,0);
    }
    for(int i=0;i<SM_FX_VALUES;i++)f->current[i]=atomic_load(&f->values[i]);
    for(int i=0;i<3;i++)f->stages[i].blend=atomic_load(&f->values[i==0?0:i==1?5:10])>0?1:0;
    f->ready=1;return 0;
fail: dispose(f);return status;
}
void sm_fx_process(SMEffects *f,float samples[SM_BLOCK][2],unsigned n,int index){
    if(!f||!f->ready||n>SM_BLOCK)return;
    Stage *s=&f->stages[index];if(!s->unit)return;
    // Parameter changes approach their target over 20 ms, on the render thread only.
    float a=1-expf(-(float)n/(float)(f->rate*.02));
    int first=index==0?1:index==1?6:12, last=index==0?4:index==1?9:13;
    for(int p=first;p<=last;p++)f->current[p]+=(atomic_load(&f->values[p])-f->current[p])*a;
    OSStatus status=0;
    if(index==0){status|=param(s,kAUNBandEQParam_Frequency,f->current[1]);for(int b=1;b<4;b++)status|=param(s,kAUNBandEQParam_Gain+b,f->current[b+1]);}
    if(index==1){status|=param(s,0,f->current[6]);status|=param(s,1,f->current[7]);status|=param(s,4,f->current[8]);status|=param(s,5,f->current[9]);}
    if(index==2){status|=param(s,1,f->current[12]);status|=param(s,2,f->current[13]);}
    for(unsigned i=0;i<n;i++){s->left[i]=samples[i][0];s->right[i]=samples[i][1];}
    StereoList list={2,{{1,n*4,s->left},{1,n*4,s->right}}};
    AudioTimeStamp t={0};t.mFlags=kAudioTimeStampSampleTimeValid;t.mSampleTime=s->sampleTime;s->sampleTime+=n;
    AudioUnitRenderActionFlags flags=0;
    status|=AudioUnitRender(s->unit,&flags,&t,0,n,(AudioBufferList*)&list);
    if(status){atomic_fetch_add(&f->errors,1);memset(samples,0,n*sizeof(samples[0]));return;}
    float target=atomic_load(&f->values[index==0?0:index==1?5:10])>0?1:0;
    float step=1/(float)(f->rate*.01);
    for(unsigned i=0;i<n;i++){
        s->blend+=fmaxf(-step,fminf(step,target-s->blend));
        unsigned pos=s->cursor++%DELAY;
        for(int c=0;c<2;c++){
            s->dry[pos][c]=samples[i][c];s->wet[pos][c]=c?s->right[i]:s->left[i];
            float dry=s->dry[(pos+DELAY-s->latency)%DELAY][c];
            float wet=s->wet[(pos+DELAY-s->padding)%DELAY][c];
            samples[i][c]=dry+(wet-dry)*s->blend;
        }
    }
}
uint64_t sm_fx_errors(SMEffects *f){return f?atomic_load(&f->errors):0;}
