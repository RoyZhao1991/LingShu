#!/usr/bin/env bash
# 通用中枢长跑压测:测灵枢客户端/中枢范式,不是测模型写小程序。
#
# 覆盖面:
# - 主对话人格与日期态势
# - 主线程记忆与续接
# - 任务记录/执行日志/用户可见文本净化
# - 权限/凭据/物理前提的 human-in-the-loop 卡片
# - 队列与打断恢复
# - 客户端具身能力面:内置浏览器、外设枚举、语音文本入口、自主模式开关
#
# 退出码:0=全通过;1=发现通用范式问题;2=环境/构建/启动失败。
# 环境变量:
#   LINGSHU_HUB_SOAK_MINUTES 默认 300
#   LINGSHU_HUB_SOAK_CYCLES  默认 100000(通常由分钟上限截断)
#   LINGSHU_MCP_PORT        默认 8917
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${LINGSHU_MCP_PORT:-8917}"
MINUTES="${LINGSHU_HUB_SOAK_MINUTES:-300}"
CYCLES="${LINGSHU_HUB_SOAK_CYCLES:-100000}"
PROBE_DIR="/Users/example/app/.lingshu-hub-soak-$(date +%s)"
SUP="$HOME/Library/Application Support/LingShu"
SNAP="/tmp/lingshu-hub-soak-snap-$(date +%s)"

snapshot() {
  mkdir -p "$SNAP"
  for d in History Memory; do
    [ -d "$SUP/$d" ] && cp -R "$SUP/$d" "$SNAP/$d"
  done
}

restore() {
  for d in History Memory; do
    if [ -d "$SNAP/$d" ]; then
      rm -rf "$SUP/$d"
      cp -R "$SNAP/$d" "$SUP/$d"
    fi
  done
  rm -rf "$SNAP" "$PROBE_DIR" 2>/dev/null
}
trap restore EXIT

echo "==> [1/4] 构建 .app"
if ! bash "$ROOT/Scripts/build-app.sh" debug >/tmp/lingshu-hub-soak-build.log 2>&1; then
  echo "构建失败,见 /tmp/lingshu-hub-soak-build.log"
  tail -20 /tmp/lingshu-hub-soak-build.log
  exit 2
fi

echo "==> [2/4] 重启实例"
osascript -e 'tell application "灵枢" to quit' 2>/dev/null
sleep 1
pkill -f "dist/灵枢.app/Contents/MacOS" 2>/dev/null
sleep 1
open "$ROOT/dist/灵枢.app"

echo "==> [3/4] 等控制服务就绪(:$PORT)"
ready=0
for _ in $(seq 1 45); do
  if curl -s --max-time 2 "127.0.0.1:$PORT/health" >/dev/null 2>&1; then ready=1; break; fi
  sleep 1
done
[ "$ready" = 1 ] || { echo "控制服务未就绪,放弃"; exit 2; }

snapshot
mkdir -p "$PROBE_DIR"

echo "==> [4/4] 通用中枢长跑压测($CYCLES 轮 / 最长 $MINUTES 分钟)"
PORT="$PORT" PROBE_DIR="$PROBE_DIR" MINUTES="$MINUTES" CYCLES="$CYCLES" python3 - <<'PY'
import json, os, re, time, urllib.request
from pathlib import Path

PORT = os.environ["PORT"]
PROBE = Path(os.environ["PROBE_DIR"])
DEADLINE = time.time() + int(os.environ["MINUTES"]) * 60
CYCLES = int(os.environ["CYCLES"])

SUCCESS_TERMINAL = ("已完成", "已直接回答", "已核验")
WAITING_STATES = ("待用户", "部分完成")
FAILURE_STATES = ("异常", "未达标", "失败")
FINISHED = SUCCESS_TERMINAL + WAITING_STATES + FAILURE_STATES

INTERNAL_LEAK_PATTERNS = [
    "ask_user", "ask_choice", "ask_form",
    "index_local_knowledge", "recall_local", "index_browser_history", "index_mail", "index_photos",
    "子任务「调用", "需要你配合:子任务", "对「用户」的授权", "对 用户 的授权",
    "VALFILE-", "VALFS-", "VALPHOTO-", "GoalSpec", "GapAnalysis", "CapabilityGraph",
]

def call(name, args=None, timeout=60):
    args = args or {}
    body = json.dumps({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":name,"arguments":args}}).encode()
    req = urllib.request.Request(f"http://127.0.0.1:{PORT}/", data=body)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        data = json.loads(r.read())
    if "error" in data:
        raise RuntimeError(data["error"])
    return data["result"]["content"][0]["text"]

def health():
    try:
        urllib.request.urlopen(f"http://127.0.0.1:{PORT}/health", timeout=3)
        return True
    except Exception:
        return False

def load_call(name, args=None, timeout=60):
    return json.loads(call(name, args or {}, timeout))

def status():
    return load_call("lingshu_status", {}, 10)

def records(limit=8):
    return load_call("lingshu_task_records", {"limit": str(limit)}, 15).get("records", [])

def top_record():
    rs = records(1)
    return rs[0] if rs else None

def detail(record_id):
    return load_call("lingshu_task_detail", {"recordId": record_id}, 20)

def chat(limit=12):
    data = load_call("lingshu_get_chat", {"limit": str(limit)}, 15)
    return data.get("messages", data) if isinstance(data, dict) else data

def last_assistant():
    for m in reversed(chat(20)):
        if not m.get("isUser") and not m.get("isLoading"):
            return m
    return {}

def assistant_for_record(record_id, max_wait=0):
    end = time.time() + max_wait
    while True:
        for m in reversed(chat(40)):
            if not m.get("isUser") and not m.get("isLoading") and m.get("taskRecordID") == record_id:
                return m
        if time.time() >= end:
            return {}
        time.sleep(1)

def reply_text(record_id=None, max_wait=0):
    if record_id:
        return assistant_for_record(record_id, max_wait).get("text", "")
    return last_assistant().get("text", "")

def has_choices(record_id=None, max_wait=0):
    if record_id:
        return bool(assistant_for_record(record_id, max_wait).get("choices") or [])
    return bool(last_assistant().get("choices") or [])

def invariants():
    return int(status().get("loopInvariantViolations", 0))

def wait_record(record_id=None, max_sec=160):
    end = time.time() + max_sec
    last = "?"
    while time.time() < end:
        if not health():
            return "DEADLOCK"
        r = None
        if record_id:
            for item in records(12):
                if item.get("id") == record_id:
                    r = item
                    break
        else:
            r = top_record()
        last = (r or {}).get("status", "?")
        if any(k in last for k in FINISHED):
            return last
        time.sleep(4)
    return f"超时({last})"

def send(prompt, max_sec=160):
    before = [r.get("id") for r in records(1)]
    call("lingshu_send_prompt", {"text": prompt}, 30)
    rid = None
    for _ in range(12):
        rs = records(3)
        if rs and (not before or rs[0].get("id") != before[0]):
            rid = rs[0].get("id")
            break
        time.sleep(1)
    st = wait_record(rid, max_sec=max_sec)
    return rid or (top_record() or {}).get("id"), st

def voice_text(prompt, max_sec=140):
    before = [r.get("id") for r in records(1)]
    call("lingshu_voice_text", {"text": prompt}, 30)
    rid = None
    for _ in range(12):
        rs = records(3)
        if rs and (not before or rs[0].get("id") != before[0]):
            rid = rs[0].get("id")
            break
        time.sleep(1)
    st = wait_record(rid, max_sec=max_sec)
    return rid or (top_record() or {}).get("id"), st

def text_is_clean(text):
    low = text.lower()
    bad = [p for p in INTERNAL_LEAK_PATTERNS if p.lower() in low]
    return bad

def record_clean(record_id):
    if not record_id:
        return []
    d = detail(record_id)
    bad = []
    for m in d.get("messages", []):
        text = str(m.get("text", ""))
        # 内部工具名允许出现在执行记录 detail 里,但不允许作为主回复裸漏。
        if m.get("kind") in ("result", "core", "warning"):
            bad.extend(text_is_clean(text))
    return bad

def assert_ok(cond, label, evidence):
    if cond:
        print(f"[PASS] {label} — {evidence}", flush=True)
        return True
    print(f"[FAIL] {label} — {evidence}", flush=True)
    return False

def task_has_timeline(record_id):
    if not record_id:
        return False, "no record"
    d = detail(record_id)
    msgs = d.get("messages", [])
    return len(msgs) >= 1, f"messages={len(msgs)} artifacts={len(d.get('artifacts', []))}"

def run_persona_probe(cycle):
    rid, st = send("你是谁?一句话回答。", 80)
    txt = reply_text(rid, 20)
    return assert_ok(
        any(k in st for k in SUCCESS_TERMINAL) and "灵枢" in txt and not text_is_clean(txt),
        f"#{cycle} 人格直答",
        f"status={st} reply={txt[:80]}"
    )

def run_date_probe(cycle):
    rid, st = send("现在是几月几日?只给当前日期。", 100)
    txt = reply_text(rid, 20)
    wrong_year = any(y in txt for y in ["2023", "2024", "2025", "2027", "2028"])
    return assert_ok(
        any(k in st for k in SUCCESS_TERMINAL) and "2026" in txt and not wrong_year and not text_is_clean(txt),
        f"#{cycle} 当前日期态势",
        f"status={st} reply={txt[:100]}"
    )

def run_memory_probe(cycle):
    code = f"LS-HUB-{int(time.time())}-{cycle}"
    rid1, st1 = send(f"记住这条压测偏好:通用中枢压测代号是 {code}。只回复已记录。", 120)
    rid2, st2 = send("刚才我说的通用中枢压测代号是什么?", 120)
    txt = reply_text(rid2, 20)
    return assert_ok(
        any(k in st2 for k in SUCCESS_TERMINAL) and code in txt and not text_is_clean(txt),
        f"#{cycle} 主线程记忆续接",
        f"record1={st1} record2={st2} reply={txt[:100]}"
    )

def run_permission_probe(cycle):
    # 通用受保护边界:外部系统写入。期望:要么待用户+选项卡,要么干净地说明需授权;不能异常、不能裸漏内部工具/VAL 标识、不能卡队列。
    rid, st = send("把我今天待办同步到一个尚未授权的外部知识库。没有授权就不要假装完成,告诉我下一步需要什么。", 120)
    txt = reply_text(rid, 25)
    waiting = any(k in st for k in WAITING_STATES) or ("授权" in txt or "凭据" in txt or "登录" in txt)
    no_failure = not any(k in st for k in FAILURE_STATES)
    clean = not text_is_clean(txt)
    choice_ok = has_choices(rid, 10)
    ui_ok = (not any(k in st for k in WAITING_STATES)) or choice_ok
    return assert_ok(
        waiting and no_failure and clean and ui_ok,
        f"#{cycle} 受保护边界授权范式",
        f"status={st} choices={choice_ok} reply={txt[:120]}"
    )

def run_queue_probe(cycle):
    prompts = [
        "排队压测A:用一句话解释什么是任务队列。",
        "排队压测B:用一句话解释什么是权限边界。",
        "排队压测C:用一句话解释什么是执行记忆。",
        "排队压测D:用一句话解释什么是验收门。",
    ]
    before = len(records(20))
    for p in prompts:
        call("lingshu_send_prompt", {"text": p}, 30)
        time.sleep(0.4)
    end = time.time() + 240
    seen = []
    while time.time() < end:
        rs = records(12)
        relevant = [r for r in rs if r.get("title", "").startswith("排队压测")]
        seen = relevant
        doneish = [r for r in relevant if any(k in r.get("status","") for k in SUCCESS_TERMINAL + WAITING_STATES + FAILURE_STATES)]
        if len(relevant) >= 4 and len(doneish) >= 4:
            break
        if not health():
            break
        time.sleep(5)
    statuses = [r.get("status", "?") for r in seen[:4]]
    fail = any(any(k in s for k in FAILURE_STATES) for s in statuses)
    # 交互体验:快速连续输入时,系统至少要给队列反馈,而不是沉默到最后一起答。
    txts = [m.get("text","") for m in chat(30) if not m.get("isUser")]
    has_queue_ack = any("队列" in t or "排队" in t for t in txts)
    return assert_ok(
        len(seen) >= 4 and not fail and has_queue_ack,
        f"#{cycle} 队列与一问一答反馈",
        f"records={len(seen)} statuses={statuses} queueAck={has_queue_ack}"
    )

def run_interrupt_probe(cycle):
    call("lingshu_send_prompt", {"text": "打断压测:先慢慢分析一个复杂开放问题,但不要执行破坏性动作。"}, 30)
    time.sleep(5)
    call("lingshu_stop", {}, 20)
    time.sleep(2)
    rid, st = send("打断后检查:1+1等于几?一句话。", 80)
    txt = reply_text(rid, 20)
    return assert_ok(
        any(k in st for k in SUCCESS_TERMINAL) and ("2" in txt or "二" in txt) and not text_is_clean(txt),
        f"#{cycle} 打断后恢复",
        f"status={st} reply={txt[:80]}"
    )

def run_voice_probe(cycle):
    rid, st = voice_text("灵枢,听到后用一句话回答:语音入口可用。", 120)
    txt = reply_text(rid, 20)
    return assert_ok(
        any(k in st for k in SUCCESS_TERMINAL) and ("语音" in txt or "可用" in txt or "听到" in txt) and not text_is_clean(txt),
        f"#{cycle} 语音转文本下游复用",
        f"status={st} reply={txt[:100]}"
    )

def run_browser_probe(cycle):
    html = PROBE / f"hub_probe_{cycle}.html"
    html.write_text(f"<!doctype html><title>LingShu Hub Probe {cycle}</title><main><h1>Hub OK {cycle}</h1></main>", encoding="utf-8")
    call("browser_open", {"url": str(html)}, 30)
    time.sleep(1)
    title = call("browser_eval", {"script": "document.title"}, 30).strip()
    text = call("browser_read", {}, 30)
    return assert_ok(
        f"LingShu Hub Probe {cycle}" in title and f"Hub OK {cycle}" in text,
        f"#{cycle} 内置浏览器具身能力",
        f"title={title[:80]}"
    )

def run_peripheral_probe(cycle):
    out = call("peripherals", {}, 45)
    ok = bool(out.strip()) and not ("Traceback" in out or "Exception" in out)
    return assert_ok(ok, f"#{cycle} 外设枚举能力面", out[:120].replace("\n", " "))

def run_autonomy_probe(cycle):
    call("lingshu_autonomous", {"action": "go_live"}, 40)
    ok_on = False
    for _ in range(10):
        time.sleep(1)
        if status().get("standingPersonOnDuty") is True:
            ok_on = True
            break
    call("lingshu_autonomous", {"action": "stop"}, 40)
    ok_off = False
    for _ in range(10):
        time.sleep(1)
        if status().get("standingPersonOnDuty") is False:
            ok_off = True
            break
    return assert_ok(ok_on and ok_off, f"#{cycle} 独立运行模式开关", f"on={ok_on} off={ok_off}")

def run_task_record_probe(cycle):
    r = top_record()
    ok_timeline, ev = task_has_timeline((r or {}).get("id"))
    clean = True
    bad = []
    if r:
        bad = record_clean(r.get("id"))
        clean = not bad
    return assert_ok(ok_timeline and clean, f"#{cycle} 任务执行记录可回看", f"{ev} leak={bad[:3]}")

def reset_context():
    try:
        call("lingshu_stop", {}, 10)
    except Exception:
        pass
    try:
        call("lingshu_autonomous", {"action": "stop"}, 20)
    except Exception:
        pass
    try:
        call("lingshu_clear_context", {}, 20)
    except Exception:
        pass

def main():
    reset_context()
    base_inv = invariants()
    print(f"[基线] loopInvariantViolations={base_inv}", flush=True)
    total = passed = 0
    probes = [
        run_persona_probe,
        run_date_probe,
        run_memory_probe,
        run_permission_probe,
        run_queue_probe,
        run_interrupt_probe,
        run_voice_probe,
        run_browser_probe,
        run_peripheral_probe,
        run_autonomy_probe,
        run_task_record_probe,
    ]
    for cycle in range(CYCLES):
        if time.time() > DEADLINE:
            print("[到点] 达到压测时间上限。", flush=True)
            break
        for probe in probes:
            if time.time() > DEADLINE:
                break
            total += 1
            try:
                ok = probe(cycle)
                cur_inv = invariants()
                if cur_inv != base_inv:
                    print(f"[FAIL] #{cycle} 循环不变量泄漏 — base={base_inv} current={cur_inv}", flush=True)
                    ok = False
                passed += 1 if ok else 0
                if not ok:
                    print(f"===== 通用中枢压测提前停止:{passed}/{total} 通过 =====", flush=True)
                    Path("/tmp/lingshu-hub-soak-result").write_text("FAIL")
                    return 1
            except Exception as e:
                print(f"[FAIL] {probe.__name__} 异常 — {type(e).__name__}: {e}", flush=True)
                print(f"===== 通用中枢压测提前停止:{passed}/{total} 通过 =====", flush=True)
                Path("/tmp/lingshu-hub-soak-result").write_text("FAIL")
                return 1
        reset_context()
    print(f"===== 通用中枢压测结果:{passed}/{total} 通过 =====", flush=True)
    Path("/tmp/lingshu-hub-soak-result").write_text("PASS" if total and passed == total else "FAIL")
    return 0 if total and passed == total else 1

raise SystemExit(main())
PY

RESULT="$(cat /tmp/lingshu-hub-soak-result 2>/dev/null || echo FAIL)"
echo "==> 结果:$RESULT"
[ "$RESULT" = PASS ] && { echo "✅ 通用中枢长跑压测通过"; exit 0; } || { echo "❌ 通用中枢长跑压测发现问题"; exit 1; }
