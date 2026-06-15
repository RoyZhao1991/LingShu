// 灵枢虚拟麦克风 —— AudioServerPlugIn(HAL plug-in)loopback 虚拟音频设备。
//
// 架构:一个虚拟设备,output 端收到的音频经环形缓冲镜像到 input 端。
//   灵枢把 TTS 播到本设备 output → 会议 App 把麦克风选成本设备 → 听到灵枢。
//
// ⚠️ 这是系统级 C 驱动:必须本机 clang 编译(build-driver.sh)+ 你的证书签名 + 装到
//    /Library/Audio/Plug-Ins/HAL/ + 重启 coreaudiod 才能验证。SwiftPM/单测覆盖不到它。
//    本文件是**结构就位的 v1**:COM 工厂 + 插件接口骨架 + loopback 环形缓冲已写;
//    设备/流的完整属性模型(GetPropertyDataSize/GetPropertyData 全集)与 DoIOOperation
//    的逐字段实现,需在本机一轮 compile→install→『音频 MIDI 设置』里出现设备→会议里听到声音 中收敛。
//    参考 Apple `NullAudio` 范式 + BlackHole 的 loopback。绝不在未跑通前声称"已可用"(假 demo 红线)。

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <pthread.h>
#include <string.h>

// ---------- loopback 环形缓冲(output→input 镜像)----------
#define LS_RING_FRAMES 16384
#define LS_CHANNELS 2
static float gRing[LS_RING_FRAMES * LS_CHANNELS];
static volatile UInt64 gRingWrite = 0;   // output 写入帧位
static pthread_mutex_t gRingLock = PTHREAD_MUTEX_INITIALIZER;

// output 端把本次播放写进环;input 端按相同采样位读出 → 实现镜像。
static void ls_ring_write(const float* src, UInt32 frames) {
    pthread_mutex_lock(&gRingLock);
    for (UInt32 i = 0; i < frames; i++) {
        UInt64 slot = (gRingWrite + i) % LS_RING_FRAMES;
        for (int c = 0; c < LS_CHANNELS; c++) gRing[slot * LS_CHANNELS + c] = src[i * LS_CHANNELS + c];
    }
    gRingWrite += frames;
    pthread_mutex_unlock(&gRingLock);
}
static void ls_ring_read(float* dst, UInt32 frames, UInt64 readStartFrame) {
    pthread_mutex_lock(&gRingLock);
    for (UInt32 i = 0; i < frames; i++) {
        UInt64 slot = (readStartFrame + i) % LS_RING_FRAMES;
        for (int c = 0; c < LS_CHANNELS; c++) dst[i * LS_CHANNELS + c] = gRing[slot * LS_CHANNELS + c];
    }
    pthread_mutex_unlock(&gRingLock);
}

// ---------- AudioServerPlugIn COM 接口 ----------
// HAL 通过 CFPlugIn 工厂拿到 AudioServerPlugInDriverInterface 的实例。下面是接口表骨架。

static AudioServerPlugInDriverInterface gInterface;          // 函数表(vtable)
static AudioServerPlugInDriverInterface* gInterfacePtr = &gInterface;
static AudioServerPlugInHostRef gHost = NULL;
static ULONG gRefCount = 1;

static HRESULT LS_QueryInterface(void* self, REFIID iid, LPVOID* out) {
    (void)self; (void)iid;
    if (out) { *out = &gInterfacePtr; }
    gRefCount++;
    return 0; // S_OK
}
static ULONG LS_AddRef(void* self) { (void)self; return ++gRefCount; }
static ULONG LS_Release(void* self) { (void)self; return --gRefCount; }

static OSStatus LS_Initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host) {
    (void)driver;
    gHost = host;
    memset(gRing, 0, sizeof(gRing));
    gRingWrite = 0;
    return 0; // noErr
}

// TODO(on-device,逐个补齐并在本机跑通):
//  - CreateDevice / DestroyDevice(本 loopback 用静态单设备可返回 kAudioHardwareUnsupportedOperationError)
//  - HasProperty / IsPropertySettable / GetPropertyDataSize / GetPropertyData / SetPropertyData
//      为 kAudioObjectPlugInScope 下的:Device(UID="LingShuVirtualMic"、Name="灵枢虚拟麦克风"、
//      采样率 48k、双声道、同时具备 Input+Output Stream)、Stream(物理/虚拟格式)、Control。
//  - StartIO / StopIO / GetZeroTimeStamp(基于 mach_absolute_time 推进零时戳)
//  - WillDoIOOperation / BeginIOOperation / DoIOOperation / EndIOOperation:
//      kAudioServerPlugInIOOperationWriteMix  → ls_ring_write(本次 output buffer)
//      kAudioServerPlugInIOOperationReadInput → ls_ring_read(对齐采样位,镜像到 input)
// 这些属性表是 AudioServerPlugIn 最繁的部分,必须在『音频 MIDI 设置』能看到设备 + 会议能选麦 中逐步验证。

// IO 镜像核心(StartIO 后由 HAL 高优先级线程回调):output 写环、input 读环。
static OSStatus LS_DoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID device, AudioObjectID stream,
                                 UInt32 clientID, UInt32 op, UInt32 ioBufferFrameSize,
                                 const AudioServerPlugInIOCycleInfo* cycle, void* mainBuffer, void* secondaryBuffer) {
    (void)driver; (void)device; (void)stream; (void)clientID; (void)secondaryBuffer;
    if (op == kAudioServerPlugInIOOperationWriteMix && mainBuffer) {
        ls_ring_write((const float*)mainBuffer, ioBufferFrameSize);
    } else if (op == kAudioServerPlugInIOOperationReadInput && mainBuffer) {
        UInt64 start = (UInt64)(cycle ? cycle->mInputTime.mSampleTime : 0);
        ls_ring_read((float*)mainBuffer, ioBufferFrameSize, start);
    }
    return 0; // noErr
}

// 工厂:Info.plist 的 CFPlugInFactories 指向这里。HAL 调它拿接口实例。
void* LingShuAudioDriver_Create(CFAllocatorRef allocator, CFUUIDRef typeID);
void* LingShuAudioDriver_Create(CFAllocatorRef allocator, CFUUIDRef typeID) {
    (void)allocator; (void)typeID;
    gInterface.QueryInterface = LS_QueryInterface;
    gInterface.AddRef = LS_AddRef;
    gInterface.Release = LS_Release;
    gInterface.Initialize = LS_Initialize;
    gInterface.DoIOOperation = LS_DoIOOperation;
    // 其余函数指针(CreateDevice/HasProperty/GetPropertyData/StartIO/...)在 on-device 阶段逐个赋值。
    return &gInterfacePtr;
}
