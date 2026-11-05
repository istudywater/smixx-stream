#include "MixerDSP.h"
#include "SMEffects.h"
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
static void check(int ok,const char *text){if(!ok){fprintf(stderr,"FAIL: %s\n",text);exit(1);}}
static double measure_signal(SMEffects *fx,int stage,double hz,double amplitude,double rate,int stereoCheck){
    float samples[SM_BLOCK][2];double sum=0,peak=0;unsigned total=0;
    for(int block=0;block<500;block++){
        for(int i=0;i<SM_BLOCK;i++){samples[i][0]=amplitude*sinf(2*M_PI*hz*(block*SM_BLOCK+i)/rate);samples[i][1]=samples[i][0]*.25;}
        sm_fx_process(fx,samples,SM_BLOCK,stage);
        if(block>100)for(int i=0;i<SM_BLOCK;i++){
            check(isfinite(samples[i][0])&&isfinite(samples[i][1]),"finite effect output");
            if(stereoCheck)check(fabs(samples[i][1]-samples[i][0]*.25)<.0001,"linked stereo preserves channel ratio");
            sum+=samples[i][0]*samples[i][0];peak=fmax(peak,fabs(samples[i][0]));total++;
        }
    }
    check(sm_fx_errors(fx)==0,"no AU render or parameter errors");
    printf("stage=%d rate=%.0f Hz=%.0f input=%.2f rms=%.6f peak=%.6f\n",stage,rate,hz,amplitude,sqrt(sum/total),peak);
    return sqrt(sum/total);
}
static void effects(double rate){
    SMEffects *fx=sm_fx_create();check(fx!=NULL,"allocate effects");
    check(sm_fx_prepare(fx,rate,0)==0,"prepare source Audio Units");
    double dry=measure_signal(fx,0,30,.5,rate,1);
    sm_fx_set(fx,0,1);sm_fx_set(fx,1,150);
    double filtered=measure_signal(fx,0,30,.5,rate,1);
    check(filtered<dry*.15,"high-pass attenuates low frequency");
    sm_fx_set(fx,5,0);double before=measure_signal(fx,1,1000,.8,rate,1);
    sm_fx_set(fx,5,1);sm_fx_set(fx,6,-30);sm_fx_set(fx,7,5);
    double compressed=measure_signal(fx,1,1000,.8,rate,1);
    check(compressed<before*.6,"compressor reduces real signal level");
    check(sm_fx_prepare(fx,rate,1)==0,"prepare bus Audio Units");
    sm_fx_set(fx,10,1);double limited=measure_signal(fx,2,1000,2,rate,1);
    check(limited<.75&&limited>.1,"limiter controls over-full-scale sine");
    sm_fx_set(fx,10,0);double bypass=measure_signal(fx,2,1000,.4,rate,1);
    check(fabs(bypass-.4/sqrt(2))<.005,"bypass preserves amplitude");
    sm_fx_destroy(fx);
}
static AudioBufferList list(float *samples,int frames){return (AudioBufferList){1,{{2,(UInt32)(frames*8),samples}}};}
static void savedTrimAtStartup(void){
    SMEngine *e=sm_create();sm_set_input_gain(e,0,.01);check(sm_prepare_source(e,0,48000)==0,"prepare saved trim");
    float in[512];for(int i=0;i<512;i++)in[i]=.4;
    for(int b=0;b<8;b++){AudioBufferList input=list(in,256);sm_capture(e,0,&input,0,1);}
    check(sm_take_source_peak(e,0)<=.00401,"saved input trim applies from first captured sample");sm_destroy(e);
}
static void routing(void){
    SMEngine *e=sm_create();check(e!=NULL,"allocate engine");
    for(int s=0;s<6;s++){
        check(sm_prepare_source(e,s,48000)==0,"prepare six captures");
        for(int o=0;o<4;o++)sm_set_gain(e,s,o,o==3?1:(o==0&&s<5?1:0));
    }
    for(int o=0;o<4;o++)check(sm_prepare_bus(e,o,o==3?44100:48000)==0,"prepare output with limiter");
    sm_set_monitor(e,0,.25);
    float in[512],out[3][512],monitor[512];double bus=0,phone=0;
    for(int block=0;block<200;block++){
        for(int s=0;s<6;s++){for(int f=0;f<512;f++)in[f]=(s+1)*.02;AudioBufferList b=list(in,256);sm_capture(e,s,&b,0,1);}
        for(int o=0;o<3;o++){AudioBufferList b=list(out[o],256);sm_render(e,o,&b,48000);}
        AudioBufferList b=list(monitor,235);sm_render(e,3,&b,44100);
        if(block>100){bus=fmax(bus,fabs(out[0][500]));phone=fmax(phone,fabs(monitor[460]));}
    }
    check(fabs(bus-.3)<.002,"outgoing bus excludes sixth source with Send off");
    check(fabs(phone-.105)<.002,"headphones include sixth source before Send at independent clock rate");
    sm_set_master(e,0,0);sm_set_monitor(e,0,.5);phone=0;
    // No outgoing callbacks: headphones must continue on their own physical clock.
    for(int block=0;block<150;block++){
        for(int s=0;s<6;s++){for(int f=0;f<512;f++)in[f]=(s+1)*.02;AudioBufferList b=list(in,256);sm_capture(e,s,&b,0,1);}
        AudioBufferList b=list(monitor,235);sm_render_monitor(e,&b,44100);
        if(block>100)phone=fmax(phone,fabs(monitor[460]));
    }
    check(fabs(phone-.21)<.002,"headphones survive bus mute and disconnected bus callbacks");
    AudioBufferList b=list(out[0],256);sm_render(e,0,&b,48000);
    for(int i=0;i<512;i++)check(out[0][i]==0,"bus mute silences buffered effect tails");
    sm_set_monitor(e,0,0);b=list(monitor,235);sm_render_monitor(e,&b,44100);
    for(int i=0;i<470;i++)check(monitor[i]==0,"headphone mute silences buffered effect tails");
    check(sm_effect_errors(e)==0,"all engine Audio Units render without errors");
    sm_destroy(e);puts("PASS: six sources, pre-Send headphones, independent clocks and mute isolation");
}

static void transitions(void){
    SMEffects *fx=sm_fx_create();sm_fx_set(fx,10,1);check(sm_fx_prepare(fx,48000,1)==0,"prepare default enabled limiter");
    float samples[SM_BLOCK][2];double peak=0;
    for(int b=0;b<20;b++){
        for(int f=0;f<SM_BLOCK;f++)samples[f][0]=samples[f][1]=(b==2&&f==0)?4:0;
        sm_fx_process(fx,samples,SM_BLOCK,2);
        for(int f=0;f<SM_BLOCK;f++)peak=fmax(peak,fabs(samples[f][0]));
    }
    printf("limiter impulse peak %.6f\n",peak);check(peak<=1.001,"default limiter catches transient without hard clipping");
    check(sm_fx_prepare(fx,48000,0)==0,"prepare transition test");
    double previous=0,maxJump=0;
    for(int b=0;b<600;b++){
        if(b==100)sm_fx_set(fx,5,1);
        if(b==200){sm_fx_set(fx,6,-40);sm_fx_set(fx,7,2);}
        if(b==300)sm_fx_set(fx,5,0);
        if(b==400){sm_fx_set(fx,0,1);sm_fx_set(fx,1,400);}
        if(b==500)sm_fx_set(fx,0,0);
        for(int f=0;f<SM_BLOCK;f++)samples[f][0]=samples[f][1]=.4*sinf(2*M_PI*100*(b*SM_BLOCK+f)/48000);
        sm_fx_process(fx,samples,SM_BLOCK,0);sm_fx_process(fx,samples,SM_BLOCK,1);
        for(int f=0;f<SM_BLOCK;f++){if(b>10)maxJump=fmax(maxJump,fabs(samples[f][0]-previous));previous=samples[f][0];}
    }
    printf("effect edit/bypass max adjacent-sample jump %.6f\n",maxJump);
    check(maxJump<.03,"smooth low-frequency bypass and parameter transitions");
    check(sm_fx_errors(fx)==0,"no transition render errors");sm_fx_destroy(fx);
}

int main(void){savedTrimAtStartup();transitions();effects(44100);effects(48000);effects(96000);routing();puts("PASS: native Audio Unit signal tests");}
