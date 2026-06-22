#!/usr/bin/env bash
# 贾维斯级真实世界场景 soak(测灵枢 harness,不是测大模型,更不是数学题)。
# 用真人口语下达**雄心勃勃/开放式/真实世界**的大场景任务,断言**灵枢框架自己把事推进**:
#   推断意图、发现设备、拆解规划、可行性判断、真实工具(扫描/调度/查证)、自我恢复、接住追问,
#   且**不 wedge / 不死锁 / 不网关400 / 不幻觉(声称的文件/动作必须真) / 循环不变量恒 0 / 人格是贾维斯不是编程AI**。
#
# **非破坏性(关键教训)**:运行前快照 History+Memory,运行后**还原**,绝不把 soak 污染留进灵枢真实状态。
# **安全**:只测发现/设计/研究/规划/调度类(可断言、无不可逆副作用);订外卖/支付/控真实设备这类有人监督另测、不在此无人值守跑。
#
# 用法:bash Scripts/jarvis-soak.sh        (默认用已在跑的实例;没有则构建启动)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${LINGSHU_MCP_PORT:-8917}"
SUP="$HOME/Library/Application Support/LingShu"
SNAP="/tmp/lingshu-jarvis-snap-$(date +%s)"

snapshot() { mkdir -p "$SNAP"; for d in History Memory; do [ -d "$SUP/$d" ] && cp -R "$SUP/$d" "$SNAP/$d"; done; echo "已快照 灵枢状态 → $SNAP"; }
restore()  { for d in History Memory; do if [ -d "$SNAP/$d" ]; then rm -rf "$SUP/$d"; cp -R "$SNAP/$d" "$SUP/$d"; fi; done; rm -rf "$SNAP"; echo "已还原 灵枢状态(丢弃 soak 污染)"; }
trap restore EXIT

# 起实例(已在跑就复用)
if ! curl -s --max-time 2 "127.0.0.1:$PORT/health" >/dev/null 2>&1; then
  echo "==> 构建+启动灵枢"
  bash "$ROOT/Scripts/build-app.sh" debug >/tmp/lingshu-jarvis-build.log 2>&1 || { echo "构建失败"; exit 2; }
  open "$ROOT/dist/灵枢.app"
  for _ in $(seq 1 30); do curl -s --max-time 2 "127.0.0.1:$PORT/health" >/dev/null 2>&1 && break; sleep 1; done
fi
snapshot

PORT="$PORT" python3 - <<'PY'
import json, os, time, re, urllib.request
PORT=os.environ["PORT"]
def call(n,a,t=50):
    b=json.dumps({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":n,"arguments":a}}).encode()
    with urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:{PORT}/",data=b),timeout=t) as r:
        return json.loads(r.read())["result"]["content"][0]["text"]
def status():
    try: return json.loads(call("lingshu_status",{}))
    except: return {}
def health():
    try: urllib.request.urlopen(f"http://127.0.0.1:{PORT}/health",timeout=3); return True
    except: return False
def inv(): return int(status().get("loopInvariantViolations",-1))
def top():
    try:
        r=json.loads(call("lingshu_task_records",{"limit":"2"}))["records"]; return r[0] if r else None
    except: return None
def reply():
    try:
        m=json.loads(call("lingshu_get_chat",{"limit":"3"})); m=m.get("messages",m) if isinstance(m,dict) else m
        for x in reversed(m):
            if not x.get("isUser") and not x.get("isLoading"): return x.get("text","")
    except: pass
    return ""
TERMINAL=("已完成","已直接回答","异常","未达标")
PATH_RE=re.compile(r"/[^\s`\"'）)，。、；;】]+?\.(?:py|txt|md|json|csv|pdf|docx|pptx|html?)",re.I)
def wait(maxp=42):
    for _ in range(maxp):
        time.sleep(8)
        if not health(): return "DEADLOCK"
        st=(top() or {}).get("status","?")
        if any(k in st for k in TERMINAL): return st
    return "超时"

# (意图, 提示, 检查类型) —— 真实世界大场景;check: robust/persona/discover/schedule
TASKS=[
  ("persona","先不说具体任务,你这个助手到底能帮我打理生活和工作里哪些事?","persona"),
  ("discover","看看现在这个网络里有没有能无线投屏的电视/盒子(AirPlay/Chromecast那种),找出来告诉我","discover"),
  ("design","帮我设计一套阳台自动浇花+补光的小系统,出方案、做可行性分析、拆实施步骤,评估现在能做到哪步","robust"),
  ("research","我想买个扫地机器人,帮我研究下怎么选、关键看哪些参数,给我个选购建议","robust"),
  ("plan","帮我规划一周的健康晚餐,荤素搭配,说明为什么这么配,大概几点吃合适","robust"),
  ("schedule","以后每天早上帮我整理一份当天要闻摘要,先把这个定时任务给我设好,告诉我你怎么安排的","schedule"),
  ("ambitious","研究一下抗衰老/延寿这个方向,梳理靠谱路径,定个推进计划,评估每条路线的成熟度","robust"),
  ("casual","现在几点了?顺便说说今天适合干点啥","robust"),
]
results=[]
base=inv(); print(f"[基线] 不变量={base}",flush=True)
for i,(intent,prompt,check) in enumerate(TASKS):
    call("lingshu_send_prompt",{"text":prompt})
    st=wait()
    rp=reply(); v=inv()
    reached=any(k in st for k in TERMINAL)
    no_dead=st!="DEADLOCK"; no400="HTTP 400" not in rp and "请求结构" not in rp
    inv_ok=(v==base) and v>=0
    # 幻觉:回复声称的路径必须真存在
    halluc=[p for p in set(PATH_RE.findall(rp)) if not os.path.exists(p)]
    hon=len(halluc)==0
    ok=reached and no_dead and no400 and inv_ok and hon
    note=""
    if check=="persona":
        # 修(棘轮):旧启发式把"只"(太常见)、"修bug"(通才能力之一的正常提及)误判成缩回编程。
        # 真·缩回 = 强信号"你想让我写什么(代码)"/"AI代码编辑器";真·通用 = 展现多领域广度(生活+工作多个域)。
        collapse = ("你想让我写什么" in rp) or ("AI 代码编辑器" in rp) or ("AI 编辑器" in rp)
        breadth = sum(w in rp for w in ["生活","规划","研究","设计","日程","提醒","设备","家","饮食","购物","演示","出谋","安排","健康","文档"]) >= 2
        good = (not collapse) and breadth
        ok = ok and good
        note=f"|人格={'✅通用' if good else ('❌缩回编程' if collapse else '⚠️广度不足')}"
    if check=="discover":
        tr=""
        try: tr=call("lingshu_get_trace",{"limit":"40"})
        except: pass
        scanned=any(k in tr for k in ["dns-sd","_airplay","_googlecast","_raop","Bonjour","mdns","arp","扫描"])
        ok=ok and scanned
        note=f"|发现动作={'✅扫了' if scanned else '❌没扫'}"
    if check=="schedule":
        sched=""
        try: sched=call("lingshu_get_trace",{"limit":"40"})
        except: pass
        used=any(k in sched for k in ["schedule_task","定时","调度","scheduled"])
        ok=ok and used
        note=f"|真调度={'✅' if used else '❌可能假设'}"
    results.append((intent,ok))
    print(f"[{'PASS' if ok else 'FAIL'}] #{i} {intent} «{prompt[:18]}…» status={st} 不变量={v} 400={not no400} 幻觉={halluc[:2]}{note}",flush=True)
    if st=="DEADLOCK": print("  ✗ 死锁,终止。"); break

p=sum(1 for r in results if r[1])
print(f"\n===== 贾维斯 soak:{p}/{len(results)} 通过 ｜ 不变量={inv()} =====",flush=True)
open("/tmp/lingshu-jarvis-result","w").write("PASS" if (results and p==len(results)) else "FAIL")
PY

R="$(cat /tmp/lingshu-jarvis-result 2>/dev/null || echo FAIL)"
echo "==> 结果:$R"
[ "$R" = PASS ] && echo "✅ 贾维斯场景全通过" || echo "❌ 有失败项(见上,这些是真 harness 弱点)"
