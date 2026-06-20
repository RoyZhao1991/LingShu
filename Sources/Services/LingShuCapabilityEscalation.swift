import Foundation

/// # 能力分层 = 失败升级的"脚手架阶梯"(通用编排,纯逻辑可单测)
///
/// 见 `Docs/能力分层与知识驱动架构方案.md` §2。对每一个"既能让大脑自由做、又存在结构化兜底"的能力,
/// 统一成一个升级阶梯:**默认从最薄(Rung0:大脑 + 原语 + 召回知识 + 极简提示)开始,只有确定性后置
/// 校验失败 / 停滞 / 大脑自述缺信息才升一级加脚手架**(Rung1 注入结构化引导、Rung2 切确定性兜底过程)。
///
/// 关键:`verify` 校的是**真实世界结果**(maker≠checker),不是"大脑声称完成"——根治"写指南文档冒充接入"。
/// `attempt`/`verify` 由调用方注入(挂在 `verifyAndContinue` 旁),所以这里**纯逻辑可单测**:
/// 给定 verify 结果序列即可断言升级路径(`CapabilityEscalationTests`)。
///
/// 旋钮性质:脚手架介入频率与脑力成反比——强脑几乎只在 Rung0 就过,弱脑才一路升级。机制不变,随脑增减。
enum LingShuCapabilityEscalation {

    /// 触发升级的三信号(任一即升级;见 §2)。
    enum Trigger: Equatable, Sendable {
        case verifyFailed   // verifyOutcome 后置校验失败
        case stalled        // 停滞检测命中(原地空转)
        case askedUser      // 大脑 ask_user 自述缺信息
    }

    /// 一次能力执行的结局(可断言:成功与否、止步在哪级、走过的路径)。
    struct Outcome<R: Sendable>: Sendable {
        let succeeded: Bool      // 是否在某级 verify 通过
        let rungReached: Int     // 通过/止步时所在 rung 下标
        let handback: Bool       // 是否因 askedUser 提前诚实交还(交还≠升到顶仍失败)
        let result: R            // 最后一次 attempt 结果
        let trace: [String]      // 逐级走向(rung0:attempt / pass / fail / handback…),供单测与审计
    }

    /// 通用升级编排。`rungs[0]` 一般是空串(最薄:不注入额外脚手架);后续每级是更强的引导/兜底说明。
    /// - Parameters:
    ///   - attempt: 在第 rung 级、带 guidance 推进一次,返回结果 R。
    ///   - verify: 对结果做**确定性后置校验**(真实世界结果),通过=true。
    ///   - triggerOf: 可选,从结果识别 `.stalled`/`.askedUser`(默认 nil:仅以 verify 通过与否驱动)。
    ///     返回 `.askedUser` → 立刻诚实交还(不再升级:缺的是用户信息,加脚手架补不了)。
    static func run<R: Sendable>(
        goal: String,
        rungs: [String],
        attempt: (_ rung: Int, _ guidance: String, _ goal: String) async -> R,
        verify: (_ rung: Int, _ result: R) async -> Bool,
        triggerOf: ((_ rung: Int, _ result: R) -> Trigger?)? = nil
    ) async -> Outcome<R> {
        precondition(!rungs.isEmpty, "至少要有 Rung0(最薄)")
        var trace: [String] = []
        var last: R!
        for rung in rungs.indices {
            trace.append("rung\(rung):attempt")
            let r = await attempt(rung, rungs[rung], goal)
            last = r
            // ask_user 自述缺信息 → 不升级,诚实交还(加脚手架补不了缺的用户信息)。
            if triggerOf?(rung, r) == .askedUser {
                trace.append("rung\(rung):handback(askedUser)")
                return Outcome(succeeded: false, rungReached: rung, handback: true, result: r, trace: trace)
            }
            if await verify(rung, r) {
                trace.append("rung\(rung):pass")
                return Outcome(succeeded: true, rungReached: rung, handback: false, result: r, trace: trace)
            }
            trace.append("rung\(rung):fail")
        }
        // 升到最后一级仍不过 → 诚实交还(由调用方接 ask_user);这里只如实报结局,不假装完成。
        return Outcome(succeeded: false, rungReached: rungs.count - 1, handback: false, result: last, trace: trace)
    }

    /// 把升级阶梯**并入现有验收门**的引导生成(方案 §2 改造点:"验收不过→原样重试"升级为"验收不过→升一级脚手架再试")。
    /// 给定验收返工轮次 `round`(0 起),返回**逐级加厚**的返工引导:
    /// - Rung0(round 0):最薄——只把验收意见原样回灌,让大脑自由修。
    /// - Rung1(round 1–2):注入**结构化引导**(先列差距清单再逐点用确定性工具补齐)。
    /// - Rung2(round ≥3):切**最确定的做法**(别再换花样,用最直接可验证的方式做到,做不到就诚实交还+ask_user)。
    /// 纯逻辑可单测(`CapabilityEscalationTests`)。强脑通常 round 0 就过,弱脑才一路升级——脚手架随脑力可调。
    static func revisionGuidance(round: Int, critique: String) -> String {
        let head = "验收未通过,逐条意见如下:\n\(critique)\n请真正用 write_file/run_command 修正,确保你声称的产出物在硬盘真实存在,再重新交付。"
        switch round {
        case 0:
            return head
        case 1, 2:
            return head + "\n[结构化引导] 先**一条条列出**还差哪几点(对照上面每条未达标意见),再**逐点**用确定性工具(write_file/run_command/真实动作工具)补齐——别整体重写、别换思路绕开问题。"
        default:
            return head + "\n[切确定性兜底] 已多轮未过:**别再换花样**,挑**最直接、可被确定性校验**的做法把每条差距做到位(如直接跑命令拿到真实结果/真实调用动作工具拿合法响应);若确实卡在缺信息或外部条件,就诚实说清卡在哪、用 ask_user 求助,不要再空转。"
        }
    }
}
