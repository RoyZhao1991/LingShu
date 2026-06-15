# 灵枢虚拟麦克风(自建签名 HAL 驱动)

让会议 App 能"听见"灵枢:一个 **AudioServerPlugIn(HAL plug-in)虚拟音频设备**,做成 **loopback**——
灵枢把 TTS 播到该设备的**输出端**,设备把同样的音频镜像到自己的**输入端**;会议 App(腾讯会议/Zoom/飞书…)
把麦克风选成"灵枢虚拟麦克风"就听到了灵枢的声音。平台无关,只要 App 能选麦克风即可。

```
灵枢 TTS ──播放到──▶ [灵枢虚拟麦克风:输出] ══loopback══▶ [灵枢虚拟麦克风:输入] ──作为麦克风──▶ 会议 App
                                                            会议对方声音 ──系统音频采集──▶ 灵枢(已实现 S1)
```

## 为什么是 HAL 驱动(而非 BlackHole)
用户拍板:自建签名 HAL 驱动,不依赖第三方虚拟声卡。Apple 账号已开通对应能力(Developer ID / 系统扩展)。

## 组成
- `LingShuAudioDriver.c` —— AudioServerPlugIn 实现(loopback 虚拟设备)。基于 Apple `NullAudio` 范式 +
  环形缓冲把 output 镜像到 input。**这是系统级 C 驱动,必须在本机 clang 编译 + 你的证书签名 + 安装到系统目录 + 重启 coreaudiod 才能验证——SwiftPM/单测都覆盖不到它。**
- `Info.plist` —— 插件 bundle 描述(`CFPlugInFactories` 工厂 UUID 等)。
- `build-driver.sh` —— clang 编译成 `LingShuAudioDriver.driver` bundle。
- `install-driver.sh` —— 签名 + 拷到 `/Library/Audio/Plug-Ins/HAL/` + 重启 coreaudiod(需 sudo)。

## 安装模型 = 灵枢自安装(用户拍板:装了灵枢就有这能力,不手动操作系统)
驱动**随 app 包发布**(`build-app.sh` 自动编译+拷进 `灵枢.app/Contents/Resources/LingShuAudioDriver.driver`),
运行时由灵枢**自安装**:`LingShuAudioDriverInstaller.installIfNeeded()` 用**一次系统管理员授权**(osascript
`with administrator privileges`,原生密码框只弹一次)把驱动拷到 `/Library/Audio/Plug-Ins/HAL/` + 重启
coreaudiod。装好后永久生效。会议对话 `meeting_converse_start` 时自动触发(没装才弹授权)。
**用户不跑任何脚本/sudo。** `build-driver.sh`/`install-driver.sh` 仅供本仓库开发期单独编译/调试驱动用。

## ⚠️ 上机验证结论(2026-06-15):驱动已完成,卡在签名证书(=你提供的"组件")
**驱动属性模型已补全**(PlugIn/Device/输入流/输出流 + loopback IO + 零时戳),clang 编译干净、签名有效
(`codesign --verify` 通过 "satisfies its Designated Requirement")、自安装跑通(已落 `/Library/Audio/Plug-Ins/HAL/` + 重启 coreaudiod)。
**但 coreaudiod 拒不加载**——实测:
- 用 **Apple Development** 证书签名(本机现有)→ 设备不出现,coreaudiod 连 bundle 都不打开,日志无任何记录;去掉 hardened runtime 重签也一样 → **排除库校验/格式问题**。
- 对比能用的 **BlackHole**:它是 **Developer ID Application + 公证**(TeamID Q5C99V536K)。

**结论:coreaudiod 只加载 Developer ID Application 签名(分发还需公证)的 HAL 插件;Apple Development 证书被静默拒绝。**
这正是"灵枢能力 + 用户提供组件"模型里你要给的**组件**:到 Apple 开发者后台生成一张 **Developer ID Application** 证书(你账号已开此能力)下载到本机。

**拿到证书后(一步到位)**:`LINGSHU_SIGN_IDENTITY="Developer ID Application: <你> (TEAMID)" bash Scripts/build-app.sh debug`
→ app 连同随包驱动一起用 Developer ID 签名 → 灵枢自安装 → 『音频 MIDI 设置』出现"灵枢虚拟麦克风" →
`meeting_converse_start` 时 TTS 自动路由到它 → 会议 App 选它当麦 → 对方听见灵枢。(分发到别人机器再加 `notarytool` 公证。)

## 仍需在本机收敛的(让设备真正可用)
自安装机制已就位;但驱动**本体**要真出现为可选麦克风,需补全 `LingShuAudioDriver.c` 的属性模型 + IO
(见文件内 TODO),并在 build→自安装→『音频 MIDI 设置』出现设备→会议听见 一轮迭代。
这一步因系统驱动无法离机自验,需在本机跑通(可借助计算机操作能力)。
> 进阶选项:若要彻底免授权框 + 现代沙箱,可改 **DriverKit AudioDriverKit 系统扩展**(`.dext` 随包 +
> `OSSystemExtensionRequest` 激活,用户在系统设置点一次允许)。需 DriverKit/系统扩展 entitlement +
> 描述文件(用户 Apple 账号已开),且驱动改用 Xcode DriverKit target 构建。当前先用 HAL .driver + 自安装跑通。

## 状态
- ✅ S1 会议对话闭环(系统音频→ASR→agent→TTS):已实现 + 实测可启动采集(`LingShuMeetingConversationController` / `meeting_converse_*`)。
- ✅ S3 app 侧输出设备路由:`LingShuState+AudioRouting`(把 TTS 流式播放器定向到指定输出设备)。
- 🔧 S2 HAL 驱动:本目录脚手架 + 实现就位;**待在你机器上 build+sign+install+test 一轮跑通**(系统驱动无法在此自验,避免假交付)。
- ⏭ S4 自主运行里"自己演示 PPT":开稿 + 逐页讲解(后续)。

## 安全/签名
- 系统扩展/HAL 插件需稳定签名身份;Developer ID Application 证书可分发。开发期 ad-hoc 签名 + SIP 下本机可加载。
- 驱动只做音频 loopback,不联网、不读文件——最小权限。
