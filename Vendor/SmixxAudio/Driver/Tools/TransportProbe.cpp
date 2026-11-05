// Real HAL transport probe, separate from in-process tests.
// Generates five identifiable sources through the production mixer DSP.
// The observer is a distinct client and records PCM; meters are not the assertion.
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include "MixerDSP.h"
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <thread>
#include <vector>

constexpr double sampleRate = 48000;
constexpr std::array<double,5> frequencies{311,463,631,809,997};
struct Context {
    SMEngine* dsp = nullptr; int output = 0; bool writer = false;
    std::vector<float> recorded;
    std::atomic<size_t> used{0};
};
AudioObjectPropertyAddress address(AudioObjectPropertySelector s, AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    return {s,scope,kAudioObjectPropertyElementMain};
}
std::vector<AudioObjectID> objects(AudioObjectID object, AudioObjectPropertySelector s) {
    auto a = address(s); UInt32 size = 0;
    if(AudioObjectGetPropertyDataSize(object,&a,0,nullptr,&size)) return {};
    std::vector<AudioObjectID> ids(size/sizeof(AudioObjectID));
    if(AudioObjectGetPropertyData(object,&a,0,nullptr,&size,ids.data())) return {};
    return ids;
}
AudioObjectID device(const std::string& uid) {
    for(auto id:objects(kAudioObjectSystemObject,kAudioHardwarePropertyDevices)) {
        auto a=address(kAudioDevicePropertyDeviceUID); CFStringRef value=nullptr; UInt32 size=sizeof(value);
        if(AudioObjectGetPropertyData(id,&a,0,nullptr,&size,&value) || !value)continue;
        char text[1024]; bool match=CFStringGetCString(value,text,sizeof(text),kCFStringEncodingUTF8) && uid==text;
        CFRelease(value);if(match)return id;
    }
    return kAudioObjectUnknown;
}
float inputSample(const AudioBufferList* list, unsigned frame, unsigned channel) {
    for(unsigned b=0;b<list->mNumberBuffers;b++) {
        const auto& buffer=list->mBuffers[b];
        if(channel<buffer.mNumberChannels) {
            const auto offset=frame*buffer.mNumberChannels+channel;
            if(buffer.mData && (offset+1)*sizeof(float)<=buffer.mDataByteSize)return static_cast<const float*>(buffer.mData)[offset];
            return 0;
        }
        channel-=buffer.mNumberChannels;
    }
    return 0;
}
OSStatus callback(AudioDeviceID, const AudioTimeStamp*, const AudioBufferList* input, const AudioTimeStamp*, AudioBufferList* output, const AudioTimeStamp*, void* raw) {
    auto& ctx=*static_cast<Context*>(raw);
    if(ctx.writer) { sm_render(ctx.dsp,ctx.output,output,sampleRate); }
    else {
        for(unsigned b=0;b<output->mNumberBuffers;b++)if(output->mBuffers[b].mData)std::memset(output->mBuffers[b].mData,0,output->mBuffers[b].mDataByteSize);
        if(input->mNumberBuffers && input->mBuffers[0].mNumberChannels) {
            const unsigned frames=input->mBuffers[0].mDataByteSize/(sizeof(float)*input->mBuffers[0].mNumberChannels);
            size_t at=ctx.used.load(std::memory_order_relaxed);
            if(at+frames*2<=ctx.recorded.size()) {
                for(unsigned f=0;f<frames;f++)for(unsigned c=0;c<2;c++)ctx.recorded[at+f*2+c]=inputSample(input,f,c);
                ctx.used.store(at+frames*2,std::memory_order_release);
            }
        }
    }
    return noErr;
}
struct Connection {
    AudioObjectID id=0; AudioDeviceIOProcID proc=nullptr;
    bool start(const std::string& uid,Context& context) {
        id=device(uid);if(!id){std::fprintf(stderr,"Missing device: %s\n",uid.c_str());return false;}
        auto a=address(kAudioDevicePropertyNominalSampleRate); double rate=0;UInt32 size=sizeof(rate);
        if(AudioObjectGetPropertyData(id,&a,0,nullptr,&size,&rate)||rate!=sampleRate){std::fprintf(stderr,"Expected 48kHz device\n");return false;}
        auto status=AudioDeviceCreateIOProcID(id,callback,&context,&proc);
        if(!status)status=AudioDeviceStart(id,proc);
        if(status){std::fprintf(stderr,"HAL start failed: %d\n",status);return false;} return true;
    }
    void stop(){if(proc){AudioDeviceStop(id,proc);AudioDeviceDestroyIOProcID(id,proc);proc=nullptr;}}
    ~Connection(){stop();}
};
double magnitude(const std::vector<float>& pcm,size_t begin,size_t frames,double frequency) {
    if((begin+frames)*2>pcm.size())return 0;
    double re=0,im=0;
    for(size_t i=0;i<frames;i++){const double phase=2*M_PI*frequency*i/sampleRate;const double v=pcm[(begin+i)*2];re+=v*std::cos(phase);im+=v*std::sin(phase);}
    return 2*std::hypot(re,im)/frames;
}
int main(int argc,char**argv) {
    if(argc<2){std::fprintf(stderr,"Usage: --write [physical-monitor-UID] | --read output-prefix\n");return 2;}
    const bool writer=std::string(argv[1])=="--write";
    if(!writer && (std::string(argv[1])!="--read"||argc!=3))return 2;
    auto bundle=CFBundleGetMainBundle();auto bundleID=bundle?CFBundleGetIdentifier(bundle):nullptr;char idText[256]="(none)";
    if(bundleID)CFStringGetCString(bundleID,idText,sizeof(idText),kCFStringEncodingUTF8);
    std::printf("Client bundle: %s\n",idText);std::fflush(stdout);
    SMEngine* dsp=sm_create();if(!dsp)return 3;
    if(writer){for(int s=0;s<5;s++)if(sm_prepare_source(dsp,s,48000))return 3;for(int o=0;o<3;o++)if(sm_prepare_bus(dsp,o,48000))return 3;}
    std::array<Context,3> contexts;std::array<Connection,3> connections;
    const char* uids[]={"org.smixx.audio.meeting","org.smixx.audio.out2"};
    for(int o=0;o<2;o++){
        contexts[o].dsp=dsp;contexts[o].writer=writer;contexts[o].output=o;
        if(!writer)contexts[o].recorded.resize(12*48000*2);
        if(!connections[o].start(uids[o],contexts[o]))return 3;
    }
    if(writer && argc==3) {
        contexts[2].dsp=dsp;contexts[2].writer=true;contexts[2].output=3;
        if(sm_prepare_bus(dsp,3,48000))return 3;
        for(int s=0;s<5;s++)sm_set_gain(dsp,s,3,1);
        sm_set_monitor(dsp,0,.25);
        if(!connections[2].start(argv[2],contexts[2]))return 3;
    }
    if(writer){
        const float gains[3][5]={{1,.5,.25,.1,0},{.1,.25,.5,1,1},{.25,.25,.25,.25,.25}};
        for(int s=0;s<5;s++){sm_set_source_rate(dsp,s,48000);for(int o=0;o<3;o++)sm_set_gain(dsp,s,o,gains[o][s]);}
        auto deadline=std::chrono::steady_clock::now();std::array<float,960> samples;
        for(int block=0;block<400;block++){
            for(int s=0;s<5;s++){
                for(int f=0;f<480;f++){float v=.02*std::sin(2*M_PI*frequencies[s]*(block*480+f)/sampleRate);samples[f*2]=v;samples[f*2+1]=v;}
                AudioBufferList list{1,{2,UInt32(samples.size()*sizeof(float)),samples.data()}};sm_capture(dsp,s,&list,0,1);
            }
            deadline+=std::chrono::milliseconds(10);std::this_thread::sleep_until(deadline);
        }
        // Actually stop supplying output; observer remains open to test stale-frame silence.
        for(auto& connection:connections)connection.stop();
        std::printf("Writer stopped. DSP dropout events: %llu\n",(unsigned long long)sm_dropouts(dsp));
        sm_destroy(dsp);return 0;
    }
    std::this_thread::sleep_for(std::chrono::seconds(8));
    for(auto& connection:connections)connection.stop();
    bool pass=true;
    for(int o=0;o<2;o++){
        const size_t used=contexts[o].used.load();contexts[o].recorded.resize(used);
        std::ofstream file(std::string(argv[2])+(o?"-recording.f32":"-meeting.f32"),std::ios::binary);
        file.write(reinterpret_cast<const char*>(contexts[o].recorded.data()),used*sizeof(float));file.close();
        double mags[5];for(int s=0;s<5;s++)mags[s]=magnitude(contexts[o].recorded,2*48000,48000,frequencies[s]);
        double tailPeak=0;const size_t tail=used>48000*2?used-48000*2:0;
        for(size_t i=tail;i<used;i++)tailPeak=std::fmax(tailPeak,std::fabs(contexts[o].recorded[i]));
        std::printf("%s: %zu frames; amplitudes %.6f %.6f %.6f %.6f %.6f; final-second peak %.9f\n",o?"Recording":"Meeting",used/2,mags[0],mags[1],mags[2],mags[3],mags[4],tailPeak);
        if(used<7*48000*2 || tailPeak>1e-6)pass=false;
        const double expected[2][5]={{.020,.010,.005,.002,0},{.002,.005,.010,.020,.020}};
        for(int s=0;s<5;s++)if(std::fabs(mags[s]-expected[o][s])>std::fmax(.001,expected[o][s]*.20))pass=false;
    }
    sm_destroy(dsp);
    std::puts(pass?"PASS: HAL readback has distinct five-source mixes, meeting-return exclusion, and silence after writer stop":"FAIL: recorded HAL samples did not meet expected transport assertions");
    return pass?0:1;
}
