// 灵枢虚拟麦克风 —— AudioServerPlugIn(HAL plug-in)loopback 虚拟音频设备。
//
// 架构:一个虚拟设备,同时有 output 流(灵枢把 TTS 播进来)与 input 流(会议 App 当麦克风读)。
//   output 写入的音频经环形缓冲镜像到 input → 会议对方听见灵枢。平台无关(任何能选麦的会议 App)。
//
// 实现参照 Apple `NullAudio` 范式(标准 AudioServerPlugIn 属性模型 + IO),改成 loopback。
// 省略音量/静音控制(设备无控件仍合法),减小出错面。对象:PlugIn=1 / Device=2 / 输入流=3 / 输出流=4。
//
// 构建:Drivers/LingShuAudioDriver/build-driver.sh(clang);随 app 包发布 + 灵枢自安装(一次授权)。

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/AudioHardware.h>  // kAudioDevicePropertyStreamConfiguration('slay')仅在此声明,AudioServerPlugIn.h 不传递包含
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <string.h>
#include <stdint.h>
#include <stddef.h>   // offsetof —— StreamConfiguration 的 AudioBufferList 变长尺寸
#include <os/log.h>   // 加载诊断:coreaudiod 内部日志(sudo log show --predicate 'subsystem=="com.zhaoroy.lingshu.audiodriver"')

// 诊断日志(coreaudiod 进程内)。设备不出现时用 `sudo log show` 看 coreaudiod 走到哪一步。
#define LS_LOG_SUBSYSTEM "com.zhaoroy.lingshu.audiodriver"
static os_log_t LS_Log(void) {
    static os_log_t log = NULL;
    if (!log) log = os_log_create(LS_LOG_SUBSYSTEM, "driver");
    return log;
}

#pragma mark - 常量与对象 ID

enum {
    kObjectID_PlugIn        = kAudioObjectPlugInObject, // 1
    kObjectID_Device        = 2,
    kObjectID_Stream_Input  = 3,
    kObjectID_Stream_Output = 4,
};

#define kDeviceUID          "LingShuVirtualMic_UID"
#define kDeviceName         "灵枢虚拟麦克风"
#define kManufacturerName   "LingShu"
#define kSampleRate         48000.0
#define kChannelsPerFrame   2u
#define kBytesPerFrame      (kChannelsPerFrame * sizeof(Float32))
#define kRingFrames         88200u   // ~1.8s @48k,且作为 ZeroTimeStampPeriod

#pragma mark - 全局状态

static AudioServerPlugInHostRef gHost = NULL;
static pthread_mutex_t          gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt64                   gIOCount = 0;          // StartIO 引用计数
static Float64                  gSampleRate = kSampleRate;

// loopback 环形缓冲(output 写、input 读)。
static Float32                  gRing[kRingFrames * kChannelsPerFrame];
static pthread_mutex_t          gRingMutex = PTHREAD_MUTEX_INITIALIZER;

// 零时戳推进
static mach_timebase_info_data_t gTimebase = {0, 0};
static Float64                  gHostTicksPerFrame = 0.0;
static UInt64                   gAnchorHostTime = 0;
static volatile UInt64          gNumberTimeStamps = 0;

static const AudioStreamBasicDescription kFormat = {
    .mSampleRate       = kSampleRate,
    .mFormatID         = kAudioFormatLinearPCM,
    .mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
    .mBytesPerPacket   = kBytesPerFrame,
    .mFramesPerPacket  = 1,
    .mBytesPerFrame    = kBytesPerFrame,
    .mChannelsPerFrame = kChannelsPerFrame,
    .mBitsPerChannel   = 32,
};

#pragma mark - COM 接口前向声明

static HRESULT  LS_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG    LS_AddRef(void* inDriver);
static ULONG    LS_Release(void* inDriver);
static OSStatus LS_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus LS_CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo*, AudioObjectID*);
static OSStatus LS_DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID);
static OSStatus LS_AddDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
static OSStatus LS_RemoveDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
static OSStatus LS_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
static OSStatus LS_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
static Boolean  LS_HasProperty(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*);
static OSStatus LS_IsPropertySettable(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, Boolean*);
static OSStatus LS_GetPropertyDataSize(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32*);
static OSStatus LS_GetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, UInt32*, void*);
static OSStatus LS_SetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, const void*);
static OSStatus LS_StartIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus LS_StopIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus LS_GetZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID, UInt32, Float64*, UInt64*, UInt64*);
static OSStatus LS_WillDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, Boolean*, Boolean*);
static OSStatus LS_BeginIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);
static OSStatus LS_DoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*, void*, void*);
static OSStatus LS_EndIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    LS_QueryInterface, LS_AddRef, LS_Release,
    LS_Initialize, LS_CreateDevice, LS_DestroyDevice,
    LS_AddDeviceClient, LS_RemoveDeviceClient,
    LS_PerformDeviceConfigurationChange, LS_AbortDeviceConfigurationChange,
    LS_HasProperty, LS_IsPropertySettable, LS_GetPropertyDataSize, LS_GetPropertyData, LS_SetPropertyData,
    LS_StartIO, LS_StopIO, LS_GetZeroTimeStamp,
    LS_WillDoIOOperation, LS_BeginIOOperation, LS_DoIOOperation, LS_EndIOOperation
};
static AudioServerPlugInDriverInterface* gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;
static UInt32 gRefCount = 1;

#pragma mark - 工厂

void* LingShuAudioDriver_Create(CFAllocatorRef allocator, CFUUIDRef typeID);
void* LingShuAudioDriver_Create(CFAllocatorRef allocator, CFUUIDRef typeID) {
    (void)allocator;
    Boolean match = CFEqual(typeID, kAudioServerPlugInTypeUUID);
    os_log(LS_Log(), "LingShu factory invoked, type match=%{public}d", match);
    if (match) return gDriverRef;
    return NULL;
}

#pragma mark - COM

static HRESULT LS_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface) {
    if (!inDriver || !outInterface) return kAudioHardwareIllegalOperationError;
    CFUUIDRef req = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(req, IUnknownUUID) || CFEqual(req, kAudioServerPlugInDriverInterfaceUUID)) {
        gRefCount++;
        *outInterface = gDriverRef;
        result = S_OK;
    }
    if (req) CFRelease(req);
    return result;
}
static ULONG LS_AddRef(void* inDriver)  { (void)inDriver; return ++gRefCount; }
static ULONG LS_Release(void* inDriver) { (void)inDriver; if (gRefCount > 1) gRefCount--; return gRefCount; }

static OSStatus LS_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    (void)inDriver;
    gHost = inHost;
    mach_timebase_info(&gTimebase);
    // host ticks/秒 = 1e9 * denom/numer;每帧 host ticks = (ticks/秒)/采样率。
    Float64 hostTicksPerSecond = 1.0e9 * (Float64)gTimebase.denom / (Float64)gTimebase.numer;
    gHostTicksPerFrame = hostTicksPerSecond / kSampleRate;
    memset(gRing, 0, sizeof(gRing));
    gIOCount = 0;
    gNumberTimeStamps = 0;
    os_log(LS_Log(), "LingShu Initialize ok (device should now enumerate)");
    return 0;
}

// 静态单设备:不支持运行时增删。
static OSStatus LS_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo* c, AudioObjectID* o) {
    (void)d;(void)desc;(void)c;(void)o; return kAudioHardwareUnsupportedOperationError;
}
static OSStatus LS_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID o) { (void)d;(void)o; return kAudioHardwareUnsupportedOperationError; }
static OSStatus LS_AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID o, const AudioServerPlugInClientInfo* c) { (void)d;(void)o;(void)c; return 0; }
static OSStatus LS_RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID o, const AudioServerPlugInClientInfo* c) { (void)d;(void)o;(void)c; return 0; }
static OSStatus LS_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID o, UInt64 a, void* i) { (void)d;(void)o;(void)a;(void)i; return 0; }
static OSStatus LS_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID o, UInt64 a, void* i) { (void)d;(void)o;(void)a;(void)i; return 0; }

#pragma mark - 属性:HasProperty / IsSettable

static Boolean LS_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress* a) {
    (void)inDriver;(void)pid;
    UInt32 size = 0;
    return LS_GetPropertyDataSize(inDriver, o, pid, a, 0, NULL, &size) == 0;
}
static OSStatus LS_IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress* a, Boolean* outSettable) {
    (void)d;(void)o;(void)pid;
    // 本设备所有暴露属性均只读(无可设格式/采样率切换)。
    if (a->mSelector == kAudioDevicePropertyNominalSampleRate) { *outSettable = false; return 0; }
    *outSettable = false;
    return 0;
}

#pragma mark - 属性:GetPropertyDataSize

static OSStatus LS_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress* a, UInt32 qds, const void* qd, UInt32* outSize) {
    (void)inDriver;(void)pid;(void)qds;(void)qd;
    OSStatus s = 0;
    switch (o) {
        case kObjectID_PlugIn:
            switch (a->mSelector) {
                case kAudioObjectPropertyBaseClass: *outSize = sizeof(AudioClassID); break;
                case kAudioObjectPropertyClass: *outSize = sizeof(AudioClassID); break;
                case kAudioObjectPropertyOwner: *outSize = sizeof(AudioObjectID); break;
                case kAudioObjectPropertyManufacturer: *outSize = sizeof(CFStringRef); break;
                case kAudioObjectPropertyOwnedObjects:
                case kAudioPlugInPropertyDeviceList: *outSize = sizeof(AudioObjectID); break;
                case kAudioPlugInPropertyTranslateUIDToDevice: *outSize = sizeof(AudioObjectID); break;
                case kAudioPlugInPropertyResourceBundle: *outSize = sizeof(CFStringRef); break;
                case kAudioObjectPropertyCustomPropertyInfoList: *outSize = 0; break;
                default: s = kAudioHardwareUnknownPropertyError; break;
            }
            break;
        case kObjectID_Device:
            switch (a->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass: *outSize = sizeof(AudioClassID); break;
                case kAudioObjectPropertyOwner: *outSize = sizeof(AudioObjectID); break;
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyManufacturer:
                case kAudioDevicePropertyDeviceUID:
                case kAudioDevicePropertyModelUID: *outSize = sizeof(CFStringRef); break;
                case kAudioDevicePropertyTransportType:
                case kAudioDevicePropertyClockDomain:
                case kAudioDevicePropertyDeviceIsAlive:
                case kAudioDevicePropertyDeviceIsRunning:
                case kAudioObjectPropertyControlList: *outSize = (a->mSelector==kAudioObjectPropertyControlList)?0:sizeof(UInt32); break;
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                case kAudioDevicePropertyLatency:
                case kAudioDevicePropertySafetyOffset:
                case kAudioDevicePropertyZeroTimeStampPeriod: *outSize = sizeof(UInt32); break;
                case kAudioDevicePropertyNominalSampleRate: *outSize = sizeof(Float64); break;
                case kAudioDevicePropertyAvailableNominalSampleRates: *outSize = sizeof(AudioValueRange); break;
                case kAudioObjectPropertyOwnedObjects:
                case kAudioDevicePropertyStreams: {
                    UInt32 n = 2;
                    if (a->mScope == kAudioObjectPropertyScopeInput || a->mScope == kAudioObjectPropertyScopeOutput) n = 1;
                    *outSize = n * sizeof(AudioObjectID);
                    break;
                }
                // 通道布局(关键):没有它,HAL/会议 App 认为设备 0 通道 → 设备被丢弃/不出现。
                // input scope 1 个流、output scope 1 个流、global 两个流,各 1 个 AudioBuffer。
                case kAudioDevicePropertyStreamConfiguration: {
                    UInt32 n = (a->mScope == kAudioObjectPropertyScopeGlobal) ? 2 : 1;
                    *outSize = (UInt32)(offsetof(AudioBufferList, mBuffers) + n * sizeof(AudioBuffer));
                    break;
                }
                case kAudioDevicePropertyPreferredChannelsForStereo: *outSize = 2 * sizeof(UInt32); break;
                case kAudioDevicePropertyPreferredChannelLayout: *outSize = (UInt32)offsetof(AudioChannelLayout, mChannelDescriptions); break;
                case kAudioDevicePropertyRelatedDevices: *outSize = sizeof(AudioObjectID); break;
                default: s = kAudioHardwareUnknownPropertyError; break;
            }
            break;
        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            switch (a->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass: *outSize = sizeof(AudioClassID); break;
                case kAudioObjectPropertyOwner: *outSize = sizeof(AudioObjectID); break;
                case kAudioStreamPropertyIsActive:
                case kAudioStreamPropertyDirection:
                case kAudioStreamPropertyTerminalType:
                case kAudioStreamPropertyStartingChannel:
                case kAudioStreamPropertyLatency: *outSize = sizeof(UInt32); break;
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat: *outSize = sizeof(AudioStreamBasicDescription); break;
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats: *outSize = sizeof(AudioStreamRangedDescription); break;
                default: s = kAudioHardwareUnknownPropertyError; break;
            }
            break;
        default: s = kAudioHardwareBadObjectError; break;
    }
    return s;
}

#pragma mark - 属性:GetPropertyData

static OSStatus LS_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress* a, UInt32 qds, const void* qd, UInt32 dataSize, UInt32* outSize, void* outData) {
    (void)inDriver;(void)pid;(void)qds;(void)qd;
    OSStatus s = 0;
    switch (o) {
        case kObjectID_PlugIn:
            switch (a->mSelector) {
                case kAudioObjectPropertyBaseClass: *((AudioClassID*)outData)=kAudioObjectClassID; *outSize=sizeof(AudioClassID); break;
                case kAudioObjectPropertyClass: *((AudioClassID*)outData)=kAudioPlugInClassID; *outSize=sizeof(AudioClassID); break;
                case kAudioObjectPropertyOwner: *((AudioObjectID*)outData)=kAudioObjectUnknown; *outSize=sizeof(AudioObjectID); break;
                case kAudioObjectPropertyManufacturer: *((CFStringRef*)outData)=CFSTR(kManufacturerName); *outSize=sizeof(CFStringRef); break;
                case kAudioObjectPropertyOwnedObjects:
                case kAudioPlugInPropertyDeviceList:
                    if (dataSize >= sizeof(AudioObjectID)) { *((AudioObjectID*)outData)=kObjectID_Device; *outSize=sizeof(AudioObjectID); }
                    else *outSize = 0;
                    break;
                case kAudioPlugInPropertyTranslateUIDToDevice: {
                    CFStringRef uid = qd ? *((CFStringRef*)qd) : NULL;
                    *((AudioObjectID*)outData) = (uid && CFEqual(uid, CFSTR(kDeviceUID))) ? kObjectID_Device : kAudioObjectUnknown;
                    *outSize = sizeof(AudioObjectID);
                    break;
                }
                case kAudioPlugInPropertyResourceBundle: *((CFStringRef*)outData)=CFSTR(""); *outSize=sizeof(CFStringRef); break;
                default: s = kAudioHardwareUnknownPropertyError; break;
            }
            break;
        case kObjectID_Device:
            switch (a->mSelector) {
                case kAudioObjectPropertyBaseClass: *((AudioClassID*)outData)=kAudioObjectClassID; *outSize=sizeof(AudioClassID); break;
                case kAudioObjectPropertyClass: *((AudioClassID*)outData)=kAudioDeviceClassID; *outSize=sizeof(AudioClassID); break;
                case kAudioObjectPropertyOwner: *((AudioObjectID*)outData)=kObjectID_PlugIn; *outSize=sizeof(AudioObjectID); break;
                case kAudioObjectPropertyName: *((CFStringRef*)outData)=CFSTR(kDeviceName); *outSize=sizeof(CFStringRef); break;
                case kAudioObjectPropertyManufacturer: *((CFStringRef*)outData)=CFSTR(kManufacturerName); *outSize=sizeof(CFStringRef); break;
                case kAudioDevicePropertyDeviceUID: *((CFStringRef*)outData)=CFSTR(kDeviceUID); *outSize=sizeof(CFStringRef); break;
                case kAudioDevicePropertyModelUID: *((CFStringRef*)outData)=CFSTR(kDeviceUID); *outSize=sizeof(CFStringRef); break;
                case kAudioDevicePropertyTransportType: *((UInt32*)outData)=kAudioDeviceTransportTypeVirtual; *outSize=sizeof(UInt32); break;
                case kAudioDevicePropertyClockDomain: *((UInt32*)outData)=0; *outSize=sizeof(UInt32); break;
                case kAudioDevicePropertyDeviceIsAlive: *((UInt32*)outData)=1; *outSize=sizeof(UInt32); break;
                case kAudioDevicePropertyDeviceIsRunning: { pthread_mutex_lock(&gStateMutex); *((UInt32*)outData)=(gIOCount>0)?1:0; pthread_mutex_unlock(&gStateMutex); *outSize=sizeof(UInt32); break; }
                case kAudioDevicePropertyDeviceCanBeDefaultDevice: *((UInt32*)outData)=1; *outSize=sizeof(UInt32); break;
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: *((UInt32*)outData)=1; *outSize=sizeof(UInt32); break;
                case kAudioDevicePropertyLatency: *((UInt32*)outData)=0; *outSize=sizeof(UInt32); break;
                case kAudioDevicePropertySafetyOffset: *((UInt32*)outData)=0; *outSize=sizeof(UInt32); break;
                case kAudioDevicePropertyZeroTimeStampPeriod: *((UInt32*)outData)=kRingFrames; *outSize=sizeof(UInt32); break;
                case kAudioDevicePropertyNominalSampleRate: { pthread_mutex_lock(&gStateMutex); *((Float64*)outData)=gSampleRate; pthread_mutex_unlock(&gStateMutex); *outSize=sizeof(Float64); break; }
                case kAudioDevicePropertyAvailableNominalSampleRates:
                    if (dataSize >= sizeof(AudioValueRange)) { AudioValueRange r={kSampleRate,kSampleRate}; *((AudioValueRange*)outData)=r; *outSize=sizeof(AudioValueRange); }
                    else *outSize=0;
                    break;
                case kAudioObjectPropertyControlList: *outSize=0; break;
                case kAudioObjectPropertyOwnedObjects:
                case kAudioDevicePropertyStreams: {
                    AudioObjectID* list=(AudioObjectID*)outData; UInt32 idx=0;
                    UInt32 cap = dataSize / sizeof(AudioObjectID);
                    if ((a->mScope==kAudioObjectPropertyScopeGlobal || a->mScope==kAudioObjectPropertyScopeInput)  && idx<cap) list[idx++]=kObjectID_Stream_Input;
                    if ((a->mScope==kAudioObjectPropertyScopeGlobal || a->mScope==kAudioObjectPropertyScopeOutput) && idx<cap) list[idx++]=kObjectID_Stream_Output;
                    *outSize = idx*sizeof(AudioObjectID);
                    break;
                }
                // 通道布局:每个 scope 对应的流各 1 个 buffer,mNumberChannels=2;mDataByteSize=0(配置查询,无数据)。
                case kAudioDevicePropertyStreamConfiguration: {
                    AudioBufferList* bl = (AudioBufferList*)outData;
                    UInt32 cap = (dataSize >= offsetof(AudioBufferList, mBuffers))
                                 ? (UInt32)((dataSize - offsetof(AudioBufferList, mBuffers)) / sizeof(AudioBuffer)) : 0;
                    Boolean wantIn  = (a->mScope==kAudioObjectPropertyScopeInput  || a->mScope==kAudioObjectPropertyScopeGlobal);
                    Boolean wantOut = (a->mScope==kAudioObjectPropertyScopeOutput || a->mScope==kAudioObjectPropertyScopeGlobal);
                    UInt32 n = 0;
                    if (wantIn  && n<cap) { bl->mBuffers[n].mNumberChannels=kChannelsPerFrame; bl->mBuffers[n].mDataByteSize=0; bl->mBuffers[n].mData=NULL; n++; }
                    if (wantOut && n<cap) { bl->mBuffers[n].mNumberChannels=kChannelsPerFrame; bl->mBuffers[n].mDataByteSize=0; bl->mBuffers[n].mData=NULL; n++; }
                    bl->mNumberBuffers = n;
                    *outSize = (UInt32)(offsetof(AudioBufferList, mBuffers) + n*sizeof(AudioBuffer));
                    break;
                }
                case kAudioDevicePropertyPreferredChannelsForStereo: {
                    UInt32* ch=(UInt32*)outData; ch[0]=1; ch[1]=2; *outSize=2*sizeof(UInt32); break;
                }
                case kAudioDevicePropertyPreferredChannelLayout: {
                    AudioChannelLayout* layout=(AudioChannelLayout*)outData;
                    memset(layout, 0, offsetof(AudioChannelLayout, mChannelDescriptions));
                    layout->mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
                    *outSize = (UInt32)offsetof(AudioChannelLayout, mChannelDescriptions);
                    break;
                }
                case kAudioDevicePropertyRelatedDevices:
                    if (dataSize >= sizeof(AudioObjectID)) { *((AudioObjectID*)outData)=kObjectID_Device; *outSize=sizeof(AudioObjectID); }
                    else *outSize=0;
                    break;
                default: s = kAudioHardwareUnknownPropertyError; break;
            }
            break;
        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output: {
            Boolean isInput = (o==kObjectID_Stream_Input);
            switch (a->mSelector) {
                case kAudioObjectPropertyBaseClass: *((AudioClassID*)outData)=kAudioObjectClassID; *outSize=sizeof(AudioClassID); break;
                case kAudioObjectPropertyClass: *((AudioClassID*)outData)=kAudioStreamClassID; *outSize=sizeof(AudioClassID); break;
                case kAudioObjectPropertyOwner: *((AudioObjectID*)outData)=kObjectID_Device; *outSize=sizeof(AudioObjectID); break;
                case kAudioStreamPropertyIsActive: *((UInt32*)outData)=1; *outSize=sizeof(UInt32); break;
                case kAudioStreamPropertyDirection: *((UInt32*)outData)= isInput?1:0; *outSize=sizeof(UInt32); break;
                case kAudioStreamPropertyTerminalType: *((UInt32*)outData)= isInput?kAudioStreamTerminalTypeMicrophone:kAudioStreamTerminalTypeSpeaker; *outSize=sizeof(UInt32); break;
                case kAudioStreamPropertyStartingChannel: *((UInt32*)outData)=1; *outSize=sizeof(UInt32); break;
                case kAudioStreamPropertyLatency: *((UInt32*)outData)=0; *outSize=sizeof(UInt32); break;
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat: *((AudioStreamBasicDescription*)outData)=kFormat; *outSize=sizeof(AudioStreamBasicDescription); break;
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats:
                    if (dataSize >= sizeof(AudioStreamRangedDescription)) {
                        AudioStreamRangedDescription rd; memset(&rd,0,sizeof(rd)); rd.mFormat=kFormat; rd.mSampleRateRange.mMinimum=kSampleRate; rd.mSampleRateRange.mMaximum=kSampleRate;
                        *((AudioStreamRangedDescription*)outData)=rd; *outSize=sizeof(AudioStreamRangedDescription);
                    } else *outSize=0;
                    break;
                default: s = kAudioHardwareUnknownPropertyError; break;
            }
            break;
        }
        default: s = kAudioHardwareBadObjectError; break;
    }
    return s;
}

static OSStatus LS_SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress* a, UInt32 qds, const void* qd, UInt32 dataSize, const void* data) {
    (void)d;(void)o;(void)pid;(void)a;(void)qds;(void)qd;(void)dataSize;(void)data;
    return kAudioHardwareUnknownPropertyError; // 无可设属性(固定 48k/格式)
}

#pragma mark - IO

static OSStatus LS_StartIO(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 c) {
    (void)d;(void)o;(void)c;
    pthread_mutex_lock(&gStateMutex);
    if (gIOCount == 0) { gAnchorHostTime = mach_absolute_time(); gNumberTimeStamps = 0; }
    gIOCount++;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}
static OSStatus LS_StopIO(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 c) {
    (void)d;(void)o;(void)c;
    pthread_mutex_lock(&gStateMutex);
    if (gIOCount > 0) gIOCount--;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus LS_GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 c, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    (void)d;(void)o;(void)c;
    pthread_mutex_lock(&gStateMutex);
    UInt64 now = mach_absolute_time();
    UInt64 ringPeriodTicks = (UInt64)(kRingFrames * gHostTicksPerFrame);
    if (ringPeriodTicks == 0) ringPeriodTicks = 1;
    UInt64 elapsed = now - gAnchorHostTime;
    UInt64 wraps = elapsed / ringPeriodTicks;
    gNumberTimeStamps = wraps;
    *outSampleTime = (Float64)(wraps * kRingFrames);
    *outHostTime   = gAnchorHostTime + (wraps * ringPeriodTicks);
    *outSeed       = 1;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus LS_WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 c, UInt32 op, Boolean* outWill, Boolean* outWillInPlace) {
    (void)d;(void)o;(void)c;
    Boolean will = (op==kAudioServerPlugInIOOperationWriteMix || op==kAudioServerPlugInIOOperationReadInput);
    if (outWill) *outWill = will;
    if (outWillInPlace) *outWillInPlace = true;
    return 0;
}
static OSStatus LS_BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 c, UInt32 op, UInt32 n, const AudioServerPlugInIOCycleInfo* i) { (void)d;(void)o;(void)c;(void)op;(void)n;(void)i; return 0; }
static OSStatus LS_EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 c, UInt32 op, UInt32 n, const AudioServerPlugInIOCycleInfo* i) { (void)d;(void)o;(void)c;(void)op;(void)n;(void)i; return 0; }

static OSStatus LS_DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID device, AudioObjectID stream, UInt32 clientID, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo* cycle, void* main, void* secondary) {
    (void)d;(void)device;(void)stream;(void)clientID;(void)secondary;
    if (frames == 0 || main == NULL) return 0;
    if (op == kAudioServerPlugInIOOperationWriteMix) {
        // 灵枢/output → 写入环(按输出采样位)。
        UInt64 startFrame = (UInt64)(cycle ? cycle->mOutputTime.mSampleTime : 0);
        const Float32* src = (const Float32*)main;
        pthread_mutex_lock(&gRingMutex);
        for (UInt32 f=0; f<frames; f++) {
            UInt64 slot = (startFrame + f) % kRingFrames;
            for (UInt32 ch=0; ch<kChannelsPerFrame; ch++) gRing[slot*kChannelsPerFrame+ch] = src[f*kChannelsPerFrame+ch];
        }
        pthread_mutex_unlock(&gRingMutex);
    } else if (op == kAudioServerPlugInIOOperationReadInput) {
        // 会议 App/input ← 从环读(同采样位)→ 镜像 output。
        UInt64 startFrame = (UInt64)(cycle ? cycle->mInputTime.mSampleTime : 0);
        Float32* dst = (Float32*)main;
        pthread_mutex_lock(&gRingMutex);
        for (UInt32 f=0; f<frames; f++) {
            UInt64 slot = (startFrame + f) % kRingFrames;
            for (UInt32 ch=0; ch<kChannelsPerFrame; ch++) dst[f*kChannelsPerFrame+ch] = gRing[slot*kChannelsPerFrame+ch];
        }
        pthread_mutex_unlock(&gRingMutex);
    }
    return 0;
}
