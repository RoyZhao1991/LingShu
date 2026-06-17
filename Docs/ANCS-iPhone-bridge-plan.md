# 灵枢 · iPhone 通知桥(ANCS)落地方案

> 目标:灵枢通过 BLE 读取 iPhone 的**系统通知**(含微信/钉钉/iMessage/日历等所有出现在通知中心的消息),
> 抽出**关键待办**,并据此**预准备资料**。作为**独立模块**实现,与灵枢主体松耦合。
> 本文档供「新开线程独立实现」直接对照执行。

---

## ✅ 落地状态(2026-06-17)

按用户拍板,实现成**通用「外接设备感知框架」**(ANCS 只是其中一个可插拔模块),代码在
`Sources/ExternalSensory/`,接线 `Sources/State/LingShuState+ExternalSensory.swift`,UI 在
「配置 → 外接设备」。详见[架构速查手册](架构速查手册.md)「外接设备感知框架」行。

- **框架/汇聚/无缝切换(§2)**:`LingShuExternalSensorySource` 协议 + `LingShuExternalSensoryHub`
  汇聚成标准输入 `LingShuExternalSensoryReading`,经 `LingShuSituationContext.ExternalSensoryComponent`
  与视觉/听觉并列注入大脑。**已落地、单测覆盖**。
- **M1 ANCS(§3)**:`LingShuANCSProtocol`(8 字节包解析 / Control Point 请求构造 / Data Source 分片重组,
  **纯函数、已单测**)+ `LingShuANCSSensorySource`(CoreBluetooth posture #1:Mac 作 central)。
  **结构完整,但 M0 BLE 链路待真机配对验证**——macOS 作 central 能否订到 iPhone 的 ANCS 是头号风险(§1);
  订不到时如实发 `.unavailable`,Hub 无缝切到 EventKit 兜底。
- **M3 蒸馏(§4)**:`LingShuPhoneTodoDistiller`(降噪去重 + 纯启发式蒸馏,**已单测**)+
  `LingShuState.distillPhoneTodos`(模型驱动,失败回退启发式)。**已落地**。
- **M5 UI + 隐私(§5)**:配置页(主开关默认关 / 各模块启停 + 状态 + 配对提示 / 待办列表 / 隐私说明,中英 i18n)。
  本地只读、正文不落盘、关闭即清空内存。**已落地**。
- **兜底源(§8)**:`LingShuEventKitSensorySource`(日历 + 提醒事项,**零配对、实测可用**)=最稳起步源,已落地。
- **待办**:① M0 真机验证 ANCS 链路(拿明确 yes/no);② M4 `MaterialPrepper`(待办→预备资料,复用现有
  web_search/write_file 四肢);③ 后续模块(短信库 / 可穿戴 / 智能家居)按协议加在 `makeDefault()`。

---

## 0. 一句话原理(为什么蓝牙这条能走)
iOS 自己暴露一个标准 GATT 服务 **ANCS(Apple Notification Center Service)**:**配对过的「配件」**(智能手表/手环就是这么显示 iPhone 通知的)订阅它,即可拿到 iPhone 全部通知的 **app 标识 / 标题 / 副标题 / 正文 / 时间 / 类别**。让灵枢(Mac)扮成这样一个配件去订阅,就读到了 iPhone 通知——**无需在 iPhone 上装 app**。卡点不在蓝牙传输,而在「iPhone 端谁合法地交出数据」,ANCS 正是 Apple 官方给配件的那条合法通道。

---

## 1. ⚠️ 头号风险 & M0 可行性 spike(先做,决定整条路成立与否)
**ANCS 的角色关系**(务必先吃透):
- iPhone = **Notification Provider**,是 ANCS 的 **GATT Server**。
- 配件(灵枢/Mac)= **Notification Consumer**,是 **GATT Client**;且**GAP 角色通常是 peripheral**(广播 ANCS 的 *solicited service*,由 iPhone 作 central 来连)。
- 关键坑:**GATT client/server 角色 与 GAP central/peripheral 角色相互独立**。ANCS 配件「以 peripheral 广播、却要作 GATT client 去读 iPhone 的 ANCS」——**macOS CoreBluetooth 是否支持这种组合,不确定**(CBPeripheralManager 只给 server 能力;CBCentralManager/CBPeripheral 才给 client 能力)。这是整条路成败所在。

**M0 spike(1–2 天,先于一切)**:写一个最小命令行/小 app,验证 macOS 上**能否真订阅到 iPhone 的 ANCS Notification Source 并收到一条通知**。三种姿势都试:
1. Mac 作 **central** 主动连 iPhone,发现并订阅 ANCS;
2. Mac 作 **peripheral** 广播 ANCS solicited service(UUID 见 §3),iPhone 连上后作 GATT client 读 ANCS;
3. 调研现成实现(ESP32/Linux/macOS 的 ANCS demo)在 macOS 的可移植性。
- **spike 通过** → 按 M1+ 推进。
- **spike 不通过(macOS 不放行 ANCS consumer)** → ANCS 路线在纯 Mac 上不成立,**走 §8 兜底数据源**,下游(待办抽取 + 资料预备)照常做、只换上游。**先别写下游大量代码,等 M0 结论。**

---

## 2. 模块边界(独立、可插拔)
新建独立模块,例如 `Sources/iPhoneBridge/`(或独立 SPM target),**不侵入主体**:
- **上游(数据源,可插拔)**:`NotificationSource` 协议 → 发出统一事件流 `PhoneNotification`。实现:`ANCSNotificationSource`(本方案主角)、`EventKitSource`(兜底)、未来 `MessagesDBSource`。
- **中游(蒸馏)**:`TodoDistiller`(把通知流 → 关键待办)、`MaterialPrepper`(待办 → 预备资料)。**与数据源无关**,所以 M0 没结论也能先做、用假数据/EventKit 喂。
- **下游对接灵枢**:通过已有大脑/工具(web_search/write_file/记忆)做抽取与预备;事件经一个 `@Published var phoneTodos: [PhoneTodo]` 暴露给 UI + 可注入主会话上下文。
- **UI**:配置里「常驻与触发」加一块,或新增「iPhone」页:配对 / 开关 / 状态 / 待办列表。i18n 走 `state.loc(zh,en)`。

```
[ANCSNotificationSource] ─┐
[EventKitSource]          ─┼─→ PhoneNotification 流 → TodoDistiller → PhoneTodo[] → MaterialPrepper → 资料
[MessagesDBSource(后续)] ─┘                                   │
                                                              └→ @Published 给 UI / 注入主会话
```

---

## 3. ANCS 技术细节(实现时照抄)
**Service / Characteristic UUID**(Apple 固定):
- ANCS Service: `7905F431-B5CE-4E99-A40F-4B1E122D00D0`
- Notification Source(notify,订它收"通知到达/移除"事件): `9FBF120D-6301-42D9-8C58-25E699A21DBD`
- Control Point(write,主动请求通知/app 的详细属性): `69D1D8F0-45E1-49A8-9821-9BBDFDAAD9D9`
- Data Source(notify,Control Point 请求的属性从这条流式回来): `22EAC6E9-24D6-4BB5-BE44-B36ACE7C7BFB`

**流程**:
1. 连接 + **bond(加密配对)**:iPhone 只把 ANCS 暴露给已配对设备。触发配对 = 读/订一个需要加密的特征,iPhone 弹配对框,用户确认。
2. 订阅 **Notification Source** → 每条通知来一个 8 字节包:`EventID`(Added/Modified/Removed)+ `EventFlags`(Silent/Important/PreExisting…)+ `CategoryID`(Social/Email/Schedule/IncomingCall…)+ `CategoryCount` + `NotificationUID`(4 字节)。
3. 对每个 UID,往 **Control Point** 写 `GetNotificationAttributes`(请求 AppIdentifier / Title / Subtitle / Message / Date),结果从 **Data Source** 流式回来,自己做分片重组解析。
4. 可选 `GetAppAttributes` 拿 app 显示名。

**注意**:ANCS 只给"从连上这刻起的通知流"(+ PreExisting 标志的当前驻留通知),**没有历史聊天**;部分通知 iOS 只给摘要。

**工程**:CoreBluetooth;`Info.plist` 加 `NSBluetoothAlwaysUsageDescription`;entitlements 蓝牙;后台保活(BLE 长连)。

---

## 4. 数据流水线(下游,与数据源无关)
1. **归一化**:`PhoneNotification{ appId, appName, title, subtitle, body, date, category }`。
2. **降噪 + 去重**:丢低优先级类别(如纯营销)、合并同会话连发、按 UID 去重。
3. **关键待办抽取**(`TodoDistiller`,走灵枢大脑):批量喂入近 N 条通知 → 输出 `PhoneTodo{ 标题, 来源app, 截止/时间, 涉及人, 行动建议, 原文引用 }`。提示词强调"只挑真需行动的,忽略寒暄/系统噪声"。
4. **资料预备**(`MaterialPrepper`):对每条待办用现有四肢预备(web_search 查背景、write_file 起草、查相关文件/记忆),产出"待办 + 一键可用的预备材料"。

---

## 5. 隐私 / 安全(硬约束,照 [[perception-data-zero-retention]] 与项目红线)
- **全程本地**:通知正文不出本机、不上传任何云端;若用云模型抽取待办,**只传去标识后的最小必要文本**或走本机模型,且**绝不留存原始消息**。
- **只读**:只收通知,不回写 iPhone。
- **显式同意**:配对要用户在 iPhone 上确认;模块有总开关,默认关。
- **可解释**:UI 明示"正在读 iPhone 通知"+ 可随时断开 + 清空。

---

## 6. 里程碑
- **M0** 可行性 spike:macOS 能否订到 ANCS 收到一条真通知(§1)。**门槛级,先做。**
- **M1** BLE 模块:配对 + 收到 Notification Source 事件 + Control Point 取属性 + 解析成 `PhoneNotification` 流。
- **M2** 归一化 + 降噪去重 + 一个"iPhone 通知"实时列表视图(验证数据质量)。
- **M3** `TodoDistiller`:通知 → 关键待办列表(可先用 EventKit/假数据跑通,不等 M0)。
- **M4** `MaterialPrepper`:待办 → 预备资料。
- **M5** UI(配对/开关/状态/待办+资料)+ i18n + 隐私控制 + 后台保活。

---

## 7. 与灵枢主体的对接点(尽量小)
- 模块自包含;只通过:① 一个 `@Published var phoneTodos`/事件流给 UI;② 可选把"今日关键待办摘要"作为 system 提示注入主会话(让灵枢在对话里能主动提);③ 复用现有 `web_search`/`write_file`/记忆 做资料预备。
- **不动**现有 agent 循环、i18n、布局等;新页签 + 新模块即可。

---

## 8. 兜底数据源(M0 不通 / 或先行起步)
ANCS 在 macOS 不放行时,上游换成:
- **EventKit(日历 + 提醒事项)**:系统级、零配对、隐私可控 → 直接喂 `TodoDistiller`。**最稳的起步源**。
- **Messages 库(iMessage/短信)**:Mac 已登录 iMessage 时读本机 `~/Library/Messages/chat.db`(需完全磁盘访问,只读)。
下游(§4)完全复用,只换 `NotificationSource` 实现——这就是把上游做成可插拔协议的意义。

---

## 9. 给新线程的起手式
1. 先做 **M0 spike**(独立小程序验证 macOS ANCS 订阅),拿到明确 yes/no。
2. 同时并行 **M3/M4 下游**(用 EventKit 或假数据),不被 M0 卡住。
3. M0 通过则接 `ANCSNotificationSource`;不通过则以 EventKit 为正式上游、ANCS 标注为"受限/待 Apple 放行"。
4. 全程独立模块,本地 + 只读 + 显式同意;UI 文案走 `state.loc`。
