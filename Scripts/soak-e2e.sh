#!/usr/bin/env bash
# 真·长跑泡测(测灵枢的 harness 能力,不是测大模型能力):构建 → 启动灵枢 → 经 MCP 发**像真人那样说的**
# 自然、含糊、不完整的请求 → 断言**灵枢框架自己把事做成**:推断意图/自己挑文件名/决定怎么验证/规划/运行/恢复/
# 接住追问,且**不 wedge / 不死循环 / 不幻觉(声称的文件必须真存在)/ 循环不变量恒 0 / 主线程不死锁**。
#
# 关键(2026-06-21 用户纠正):**不要写机器规格**(精确文件名/签名/断言/输出格式)——那只测模型会不会照抄规格,
# 几乎不考验 harness。真人会说"给我写两个函数,加法和加法验证,跑一下看结果"。断言也随之改成**鲁棒性 + 诚实性**
# (到终态、不 wedge、不变量0、声称/登记的产出物真存在),而不是"某个精确文件名存在"。
#
# 退出码:0=全通过,1=有失败/不变量破/wedge/死锁,2=环境/构建/启动失败。
# 环境变量:LINGSHU_SOAK_TASKS(默认 60)  LINGSHU_SOAK_MINUTES(默认 300,到点即止)  LINGSHU_MCP_PORT(默认 8917)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${LINGSHU_MCP_PORT:-8917}"
TASKS="${LINGSHU_SOAK_TASKS:-60}"
MINUTES="${LINGSHU_SOAK_MINUTES:-300}"
PROBE_DIR="/Users/example/app/.lingshu-soak-$(date +%s)"
cleanup() { rm -rf "$PROBE_DIR" 2>/dev/null; }
trap cleanup EXIT

echo "==> [1/4] 构建 .app"
if ! bash "$ROOT/Scripts/build-app.sh" debug >/tmp/lingshu-soak-build.log 2>&1; then
  echo "构建失败,见 /tmp/lingshu-soak-build.log"; tail -5 /tmp/lingshu-soak-build.log; exit 2
fi

echo "==> [2/4] 重启实例"
osascript -e 'tell application "灵枢" to quit' 2>/dev/null; sleep 1
pkill -f "dist/灵枢.app/Contents/MacOS" 2>/dev/null; sleep 1
open "$ROOT/dist/灵枢.app"

echo "==> [3/4] 等控制服务就绪(:$PORT)"
ready=0
for _ in $(seq 1 30); do
  if curl -s --max-time 2 "127.0.0.1:$PORT/health" >/dev/null 2>&1; then ready=1; break; fi
  sleep 1
done
[ "$ready" = 1 ] || { echo "控制服务未就绪,放弃"; exit 2; }

echo "==> [4/4] 长跑泡测(真模型 · 自然口语请求;$TASKS 条 / 最长 $MINUTES 分钟)"
mkdir -p "$PROBE_DIR"
PROBE_DIR="$PROBE_DIR" PORT="$PORT" TASKS="$TASKS" MINUTES="$MINUTES" python3 - <<'PY'
import json, os, time, glob, random, re, urllib.request
PORT = os.environ["PORT"]; PROBE = os.environ["PROBE_DIR"]
TASKS = int(os.environ["TASKS"]); DEADLINE = time.time() + int(os.environ["MINUTES"]) * 60

def call(name, args, timeout=60):
    body = json.dumps({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":name,"arguments":args}}).encode()
    req = urllib.request.Request(f"http://127.0.0.1:{PORT}/", data=body)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())["result"]["content"][0]["text"]

def status():
    try: return json.loads(call("lingshu_status", {}))
    except Exception as e: return {"_err": str(e)}

def health_ok():
    try: urllib.request.urlopen(f"http://127.0.0.1:{PORT}/health", timeout=3); return True
    except Exception: return False

def invariants():
    return int(status().get("loopInvariantViolations", -1))

def top_record():
    try:
        recs = json.loads(call("lingshu_task_records", {"limit":"3"}))["records"]
        return recs[0] if recs else None
    except Exception: return None

def record_detail(rid):
    try: return json.loads(call("lingshu_task_detail", {"recordId": rid}))
    except Exception: return {}

def last_reply():
    try:
        msgs = json.loads(call("lingshu_get_chat", {"limit":"4"}))
        msgs = msgs.get("messages", msgs) if isinstance(msgs, dict) else msgs
        for m in reversed(msgs):
            if not m.get("isUser") and not m.get("isLoading"): return m.get("text","")
    except Exception: pass
    return ""

SUCCESS_TERMINAL = ("已完成", "已直接回答")
FAILURE_TERMINAL = ("异常", "未达标")
TERMINAL = SUCCESS_TERMINAL + FAILURE_TERMINAL

def send_wait(prompt, max_polls=42):
    call("lingshu_send_prompt", {"text": prompt})
    for _ in range(max_polls):
        time.sleep(8)
        if not health_ok(): return "DEADLOCK"
        r = top_record(); st = r["status"] if r else "?"
        if any(k in st for k in TERMINAL): return st
    return "超时"

def followup_wait(rid, text, max_polls=42):
    call("lingshu_task_followup", {"recordId": rid, "text": text})
    for _ in range(max_polls):
        time.sleep(8)
        if not health_ok(): return "DEADLOCK"
        r = top_record(); st = r["status"] if r else "?"
        if any(k in st for k in TERMINAL): return st
    return "超时"

# 幻觉/诚实检查:① 登记产出物的 location 必须真存在 ② 回复正文里声称的绝对路径必须真存在。
PATH_RE = re.compile(r"/[^\s`\"'）)，。、；;】]+?\.(?:py|txt|md|json|csv|sh|js|ts|html?|pptx|docx)", re.I)
def honesty_violation(rid):
    det = record_detail(rid)
    for a in det.get("artifacts", []):
        loc = a.get("location","")
        if loc.startswith("/") and not os.path.exists(loc):
            return f"登记产出物不存在:{loc}"
    for p in set(PATH_RE.findall(last_reply())):
        if not os.path.exists(p):
            return f"回复声称的文件不存在:{p}"
    return None

P = PROBE
# 像真人那样说的请求:含糊、不给文件名/签名/断言/格式。intent 决定是否期望产出文件;followup=真人追问。
CODE = [
    f"在 {P} 给我写两个函数,一个做加法一个验证加法对不对,写完跑一下看结果",
    f"帮我在 {P} 弄个算阶乘的小脚本,顺手测一下准不准",
    f"在 {P} 写个判断是不是质数的,自己找几个数试试看对不对",
    f"我想要个能反转字符串的小工具,放 {P},写好跑给我看",
    f"在 {P} 搞个简单计算器,加减乘除都要,测一下能不能用",
    f"帮我在 {P} 写个数一段文字里每个词出现几次的,测测看",
    f"在 {P} 写个能把列表里重复的去掉的,跑个例子给我看看",
]
MULTI = [
    f"在 {P} 先写个斐波那契,然后给它配几个测试,最后跑一遍告诉我结果",
    f"帮我在 {P} 先做个摄氏华氏互转,再写测试,跑通了给我看",
]
FOLLOWUP = [
    (f"在 {P} 写个加法函数顺便测一下", "不错,再帮我加个减法,也测测"),
    (f"在 {P} 给我写个求列表最大值的,跑一下", "再加个求最小值的呗,一起测"),
]
QA = [
    "你能帮我做点啥?简单说说就行",
    "你是谁做出来的?",
    "现在几点了?",
    "你平时是怎么帮我写代码的?",
]

def gen(n):
    out = []
    for i in range(n):
        k = i % 8
        if k in (0,1,2,3): out.append(("code", random.choice(CODE), None))
        elif k == 4:       out.append(("multi", random.choice(MULTI), None))
        elif k == 5:       b,f = random.choice(FOLLOWUP); out.append(("followup", b, f))
        else:              out.append(("qa", random.choice(QA), None))
    return out

results = []
baseline = invariants()
print(f"[基线] loopInvariantViolations={baseline}", flush=True)

# 滚动检查点(测量修复 2026-06-22):每段判"自上次检查以来**无新增**不变量违反",而非全程比对开跑基线——
# 否则某段一旦泄漏,后续每段 ==baseline 都假红、把真正出问题的段掩盖掉(打断段泄漏曾级联误报自主段)。
inv_ckpt = baseline
def clean_since_ckpt():
    global inv_ckpt
    cur = invariants()
    ok = (cur == inv_ckpt)
    inv_ckpt = cur   # 推进:本段判完即作为下段新基线 → 泄漏精确定位到具体段,不级联
    return ok

for idx, (intent, prompt, fup) in enumerate(gen(TASKS)):
    if time.time() > DEADLINE:
        print(f"[到点] 已达上限,在第 {idx} 条停。"); break
    st = send_wait(prompt)
    rid = (top_record() or {}).get("id")
    viol = invariants()
    succeeded = any(k in st for k in SUCCESS_TERMINAL)
    no_dead = st != "DEADLOCK"
    inv_ok = clean_since_ckpt() and viol >= 0
    hon = honesty_violation(rid) if rid else None
    # 期望产出文件的意图(code/multi/followup):harness 应真做出东西 → 至少 1 个登记产出物 或 PROBE 里出现新 .py。
    produced = True
    if intent in ("code","multi","followup"):
        ac = (top_record() or {}).get("artifactCount", 0)
        produced = ac >= 1 or len(glob.glob(f"{PROBE}/**/*.py", recursive=True)) > 0
    ok = succeeded and no_dead and inv_ok and (hon is None) and produced
    # followup:真人追问,验证 harness 接得住、仍到终态、仍诚实。
    fup_note = ""
    if ok and intent == "followup" and rid and fup:
        st2 = followup_wait(rid, fup)
        hon2 = honesty_violation(rid)
        fok = any(k in st2 for k in SUCCESS_TERMINAL) and st2 != "DEADLOCK" and clean_since_ckpt() and hon2 is None
        ok = ok and fok
        fup_note = f" | 追问 status={st2} 诚实={'ok' if hon2 is None else hon2}"
    ev = f"status={st} 不变量={viol} {'诚实ok' if hon is None else '⚠️'+str(hon)} 产出={'有' if produced else '无'}{fup_note}"
    results.append((intent, ok, ev))
    print(f"[{'PASS' if ok else 'FAIL'}] #{idx} {intent} «{prompt[:24]}…» — {ev}", flush=True)
    if st == "DEADLOCK":
        print("  ✗ 主线程死锁(/health 不可达),提前终止。"); break

# ===== 中途打断恢复段(边缘:压测打断标志泄漏修复 + 无 wedge)=====
print("\n--- 中途打断恢复段 ---", flush=True)
for r in range(3):
    if time.time() > DEADLINE: break
    call("lingshu_send_prompt", {"text": f"帮我在 {PROBE} 写个稍微复杂点的素数筛,写完测一下"})
    time.sleep(7)                       # 飞行中
    try: call("lingshu_stop", {})       # 中途打断
    except Exception: pass
    time.sleep(4)
    st = send_wait("顺便问下,3 加 4 等于几?", max_polls=14)   # 打断后干净任务必须正常到终态
    ok = any(k in st for k in SUCCESS_TERMINAL) and st != "DEADLOCK" and health_ok() and clean_since_ckpt()
    results.append(("interrupt", ok, f"打断后 status={st} 不变量={invariants()}"))
    print(f"[{'PASS' if ok else 'FAIL'}] 打断恢复#{r} — status={st} 不变量={invariants()}", flush=True)

# ===== 自主模式段(两模式都锤)=====
print("\n--- 自主模式段 ---", flush=True)
def autonomy(a):
    try: return call("lingshu_autonomous", {"action": a})
    except Exception as e: return f"err({e})"
try:
    autonomy("go_live"); on=False
    for _ in range(8):
        time.sleep(1)
        if status().get("standingPersonOnDuty") is True: on=True; break
    ok = on and health_ok() and clean_since_ckpt()
    results.append(("auto", ok, f"go_live standingPersonOnDuty={on}"))
    print(f"[{'PASS' if ok else 'FAIL'}] 自主:go_live 上岗 — {on}", flush=True)
    st = send_wait("现在适合做点啥?随便说说", max_polls=18)
    ok = any(k in st for k in SUCCESS_TERMINAL) and st!="DEADLOCK" and clean_since_ckpt()
    results.append(("auto", ok, f"在岗任务 status={st}"))
    print(f"[{'PASS' if ok else 'FAIL'}] 自主:在岗任务 — {st}", flush=True)
    autonomy("stop"); time.sleep(2)
    off = status().get("standingPersonOnDuty")
    results.append(("auto", off is False and health_ok(), f"stop standingPersonOnDuty={off}"))
    print(f"[{'PASS' if off is False else 'FAIL'}] 自主:stop 夺回 — {off}", flush=True)
except Exception as e:
    results.append(("auto", False, f"异常 {e}")); print(f"[FAIL] 自主段异常 {e}"); autonomy("stop")

passed = sum(1 for r in results if r[1])
print(f"\n===== 长跑结果:{passed}/{len(results)} 通过 ｜ 不变量累计违反={invariants()} =====", flush=True)
open("/tmp/lingshu-soak-result", "w").write("PASS" if (results and passed == len(results)) else "FAIL")
PY

RESULT="$(cat /tmp/lingshu-soak-result 2>/dev/null || echo FAIL)"
echo "==> 收尾:退出灵枢实例"
osascript -e 'tell application "灵枢" to quit' 2>/dev/null
[ "$RESULT" = "PASS" ] && { echo "✅ 长跑泡测全通过(自然请求 / 零 wedge / 零幻觉 / 零不变量违反)"; exit 0; } || { echo "❌ 长跑泡测有失败项(见上)"; exit 1; }
