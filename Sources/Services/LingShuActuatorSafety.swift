import Foundation

/// **执行器/动作型外围的安全模型**(M4 架构核心,纯逻辑可单测)。
///
/// 执行器与感知(传感器)/计算(工具)的根本区别:它**作用于真实世界**(改音量、转舵机、开继电器、控锁)。
/// 据核心红线「不可逆/对外动作先确认」,执行器按风险分两类,**确认强度不同**:
/// - `.reversible`:可逆/可观测可撤销(音量/亮度/通知)→ 风险审隔离时**首次执行审批**,之后自由(同工具型)。
/// - `.physical`:不可逆/对外的物理或外发动作(电机/锁/继电器/加热/对外发指令)→ **每一次执行都强制主人确认**
///   (即便会话已完整授权),非交互(自主/无头)安全拒绝、绝不静默触发。这比"首次审批"更强,因为每次调用都有真实后果。
///
/// 注:执行器 runner 仍跑在 P3 沙箱(confine 文件/网络到声明范围);安全靠**这道确认门**,不是靠沙箱拒绝
///(沙箱允许它执行声明的 effect)。
enum LingShuActuatorSafety {

    enum Risk: String, Sendable, Equatable, CaseIterable {
        case reversible   // 可逆:音量/亮度/通知…
        case physical     // 不可逆/对外:电机/继电器/锁/对外发指令…

        /// 容错解析:**风险由大脑(组件作者)显式声明**——`physical`/`irreversible` → .physical;其余 → .reversible。
        /// **零关键词清单**(撤"定制":见方案 §4 #7):不再靠 motor/relay/锁… 这类写死关键词猜风险——那是逼大脑走
        /// 我们的路子且永远不通用。风险等级是大脑在 `author_component` 时按它对设备的理解声明的(`actuator_risk`),
        /// 安全靠下面这道**通用确认门**(physical=每次确认),不靠关键词命中。
        static func from(_ raw: String) -> Risk {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return (s == "physical" || s == "irreversible") ? .physical : .reversible
        }
    }

    /// 该风险类是否**每次执行都需确认**(physical=是)。
    static func requiresConfirmationEachCall(_ risk: Risk) -> Bool { risk == .physical }

    /// 给一次动作生成确认提示语(供审批弹窗醒目展示:执行器是什么、对哪个目标、下什么命令)。
    static func confirmationPrompt(actuatorName: String, target: String, command: String) -> String {
        "执行器「\(actuatorName)」将对【\(target.isEmpty ? "目标设备" : target)】下达不可逆/对外动作:\(command.prefix(200))。这是有真实后果的物理/对外动作,确认执行吗?"
    }
}
