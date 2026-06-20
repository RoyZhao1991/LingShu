import Foundation

/// # 决策知识种子(方案 P0②)—— **数据,不是代码逻辑**
///
/// 把灵枢已学到的**陈述性事实/教训**作为第一个知识包种进知识图谱(原子笔记),
/// 让"知识驱动 > 框架驱动"有最小可验证起点:大脑决策时召回这些事实自行判断,而不是壳里写死步骤。
///
/// 铁律(方案 §10):领域特定的东西(某设备协议)**只能是知识笔记(数据)或自编组件(数据),绝不进壳代码**。
/// 所以这里是**数据清单**(陈述句),不是 if/else 分支。每条都须过"陈述非祈使"纪律([[knowledge-discipline]])。
enum LingShuSeedKnowledge {

    /// 种子标记笔记 id —— 存在即表示已种过(幂等,不重复灌)。
    static let markerTitle = "灵枢决策知识种子v1"

    /// 第一个知识包(全部为陈述性事实/教训,通用、非祈使)。
    static let candidates: [LingShuMemoryGardener.Candidate] = [
        .init(kind: .fact, title: "CozyLife 灯局域网协议",
              aliases: ["CozyLife", "CozyLife 灯", "智能灯本地协议"],
              body: "CozyLife 智能灯走局域网 TCP 5555,JSON 帧以 \\r\\n 结尾;cmd:3 配 {attr:[1],data:{1:1}} 开、{1:0} 关;DP3 是亮度 0-1000,DP4 是色温。属开放本地协议,可自写驱动直连控制。",
              source: .tool, confidence: 0.8),
        .init(kind: .fact, title: "HomeKit 配件单控制者独占",
              aliases: ["HomeKit 独占", "苹果家庭独占"],
              body: "HomeKit 配件同一时刻单控制者独占;一旦设备已加入苹果家庭(Home App),第三方/外部程序就连不上、控不了它,要先把它从苹果家庭移除才能另接。",
              source: .tool, confidence: 0.8),
        .init(kind: .fact, title: "Bonjour 服务类型可全量枚举",
              aliases: ["Bonjour 枚举", "mDNS 服务发现", "dns-sd 枚举"],
              body: "局域网的全部 Bonjour/mDNS 服务类型可用 meta-query 枚举:dns-sd -B _services._dns-sd._udp 列出本网在播的所有服务类型,再逐类浏览拿到具体设备——不必预先写死服务类型清单。",
              source: .tool, confidence: 0.8),
        .init(kind: .fact, title: "本机设备发现手段",
              aliases: ["设备发现命令", "硬件枚举手段", "nmap 子网扫描"],
              body: "发现接入硬件/网络设备的通用只读手段:dns-sd 看 mDNS 服务、ioreg/system_profiler 看 USB/蓝牙/电源控制器、ls /dev/cu.* 看串口、nmap 扫子网常见端口找不广播 Bonjour 的设备。都是只读枚举、不挑品牌。",
              source: .tool, confidence: 0.8),
        .init(kind: .fact, title: "教训:写文档不等于真接入",
              aliases: ["文档冒充接入", "接入交付是效果"],
              body: "教训:对'接入设备/开关灯/操作电脑'这类动作型请求,产出一篇'怎么接入/怎么用'的说明文档 ≠ 真接入。交付是真实效果(设备真能控、试调一次拿到合法响应),不是文件。",
              source: .inference, confidence: 0.9)
    ]

    /// 种子标记候选(种完一并落,作为幂等标记)。
    static var markerCandidate: LingShuMemoryGardener.Candidate {
        .init(kind: .glossary, title: markerTitle,
              body: "灵枢第一个决策知识包(CozyLife 本地协议、HomeKit 独占、Bonjour 枚举、设备发现手段、文档≠接入教训)已种入。此条为幂等标记。",
              source: .inference, confidence: 1.0)
    }
}
