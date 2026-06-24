#!/usr/bin/env bash
# 贾维斯级真实世界长跑压测:测灵枢“通用中枢客户端”,不是测大模型写代码。
#
# 覆盖:
# - 人格/态势/时间:像一个常驻中枢,不是代码工具
# - 主线程记忆:能接住上下文
# - 受保护边界:需要账号/凭据/物理前提时弹可操作授权卡,不裸漏内部包
# - 本机文件/附件/浏览器/外设/语音入口/独立运行开关:真实能力面可用
# - 队列/打断/恢复:不会卡死或把多问多答乱序堆叠
# - 任务记录:每条任务可回看,无内部协议泄露到主聊天
#
# 默认跑 5 小时。运行前快照 History+Memory,退出时还原,避免污染真实记忆。
# 用法:
#   bash Scripts/jarvis-soak.sh
#   JARVIS_SOAK_MINUTES=20 JARVIS_SOAK_CYCLES=2 bash Scripts/jarvis-soak.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${LINGSHU_MCP_PORT:-8917}"
MINUTES="${JARVIS_SOAK_MINUTES:-300}"
CYCLES="${JARVIS_SOAK_CYCLES:-100000}"
RESTART="${JARVIS_SOAK_RESTART:-1}"
SUP="$HOME/Library/Application Support/LingShu"
SNAP="/tmp/lingshu-jarvis-snap-$(date +%s)"
PROBE="/Users/example/app/.lingshu-jarvis-soak-$(date +%s)"

snapshot() {
  mkdir -p "$SNAP" "$PROBE"
  for d in History Memory; do
    [ -d "$SUP/$d" ] && cp -R "$SUP/$d" "$SNAP/$d"
  done
  echo "已快照灵枢状态 → $SNAP"
}

restore() {
  for d in History Memory; do
    if [ -d "$SNAP/$d" ]; then
      rm -rf "$SUP/$d"
      cp -R "$SNAP/$d" "$SUP/$d"
    fi
  done
  rm -rf "$SNAP" "$PROBE" 2>/dev/null
  echo "已还原灵枢状态(丢弃 soak 污染)"
}
trap restore EXIT

if [ "$RESTART" = "1" ]; then
  echo "==> 构建+重启灵枢"
  if ! bash "$ROOT/Scripts/build-app.sh" debug >/tmp/lingshu-jarvis-build.log 2>&1; then
    echo "构建失败,见 /tmp/lingshu-jarvis-build.log"
    tail -40 /tmp/lingshu-jarvis-build.log
    exit 2
  fi
  osascript -e 'tell application "灵枢" to quit' 2>/dev/null
  sleep 1
  pkill -f "dist/灵枢.app/Contents/MacOS" 2>/dev/null
  sleep 1
  open "$ROOT/dist/灵枢.app"
fi

echo "==> 等控制服务就绪(:$PORT)"
ready=0
for _ in $(seq 1 45); do
  if curl -s --max-time 2 "127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
[ "$ready" = 1 ] || { echo "控制服务未就绪"; exit 2; }

snapshot

PORT="$PORT" PROBE="$PROBE" MINUTES="$MINUTES" CYCLES="$CYCLES" python3 - <<'PY'
import json, os, re, time, urllib.error, urllib.request
from pathlib import Path

PORT = os.environ["PORT"]
PROBE = Path(os.environ["PROBE"])
DEADLINE = time.time() + int(os.environ["MINUTES"]) * 60
CYCLES = int(os.environ["CYCLES"])

SUCCESS_TERMINAL = ("已完成", "已直接回答", "已核验")
WAITING_STATES = ("待用户", "部分完成")
FAILURE_STATES = ("异常", "未达标", "失败")
FINISHED = SUCCESS_TERMINAL + WAITING_STATES + FAILURE_STATES

INTERNAL_LEAK_PATTERNS = [
    "__LINGSHU_HUMAN_INPUT__", "LINGSHU_HUMAN_INPUT",
    "ask_user", "ask_choice", "ask_form",
    "GoalSpec", "GapAnalysis", "CapabilityGraph",
    "VALFILE-", "VALFS-", "VALPHOTO-",
    "index_local_knowledge", "recall_local", "index_browser_history", "index_mail", "index_photos",
    "需要你配合:子任务", "子任务「调用",
    "对「用户」的授权", "对 用户 的授权",
]
PATH_RE = re.compile(r"/[^\s`\"'）)，。、；;】]+?\.(?:py|txt|md|json|csv|pdf|docx|pptx|html?|wav|mp3|png|jpg|jpeg)", re.I)

def rpc(name, args=None, timeout=60):
    body = json.dumps({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {"name": name, "arguments": args or {}},
    }).encode()
    last_error = None
    for attempt in range(1, 6):
        req = urllib.request.Request(f"http://127.0.0.1:{PORT}/", data=body)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                data = json.loads(r.read())
            break
        except (urllib.error.URLError, OSError, TimeoutError) as e:
            last_error = e
            if attempt == 5:
                raise
            time.sleep(min(2.0, 0.2 * attempt))
    else:
        raise last_error or RuntimeError("RPC failed")
    if "error" in data:
        raise RuntimeError(data["error"])
    result = data["result"]
    text = result["content"][0]["text"]
    if result.get("isError"):
        raise RuntimeError(text)
    return text

def load(name, args=None, timeout=60):
    return json.loads(rpc(name, args or {}, timeout))

def health():
    try:
        urllib.request.urlopen(f"http://127.0.0.1:{PORT}/health", timeout=3)
        return True
    except Exception:
        return False

def status():
    return load("lingshu_status", {}, 10)

def records(limit=10):
    return load("lingshu_task_records", {"limit": str(limit)}, 20).get("records", [])

def detail(record_id):
    return load("lingshu_task_detail", {"recordId": record_id}, 25)

def chat(limit=40):
    data = load("lingshu_get_chat", {"limit": str(limit)}, 20)
    return data.get("messages", data) if isinstance(data, dict) else data

def top_record():
    rs = records(1)
    return rs[0] if rs else None

def assistant_for_record(record_id, max_wait=0):
    end = time.time() + max_wait
    while True:
        for m in reversed(chat(60)):
            if not m.get("isUser") and not m.get("isLoading") and m.get("taskRecordID") == record_id:
                return m
        if time.time() >= end:
            return {}
        time.sleep(1)

def reply_text(record_id=None, max_wait=0):
    if record_id:
        return assistant_for_record(record_id, max_wait).get("text", "")
    for m in reversed(chat(30)):
        if not m.get("isUser") and not m.get("isLoading"):
            return m.get("text", "")
    return ""

def has_choices(record_id, max_wait=0):
    return bool(assistant_for_record(record_id, max_wait).get("choices") or [])

def wait_record(record_id=None, max_sec=180):
    # AI 任务不按固定总时长切死:只要状态/消息/产出物仍在变化,说明心跳还活着,继续等。
    # max_sec 表示“连续无进展”的超时窗口,不是整条任务上限。
    last_progress = time.time()
    last_signature = None
    last = "?"
    while time.time() < DEADLINE:
        if not health():
            return "DEADLOCK"
        r = None
        for item in records(16):
            if record_id and item.get("id") == record_id:
                r = item
                break
        if r is None and not record_id:
            r = top_record()
        r = r or {}
        last = r.get("status", "?")
        signature = (last, r.get("messageCount", 0), r.get("artifactCount", 0))
        if signature != last_signature:
            last_signature = signature
            last_progress = time.time()
        if any(k in last for k in FINISHED):
            return last
        if time.time() - last_progress > max_sec:
            return f"超时无进展({last})"
        time.sleep(4)
    return f"到达长跑时间上限({last})"

def record_matches_prompt(item, prompt):
    title = item.get("title", "") or ""
    if not title or not prompt:
        return False
    key = prompt[:min(24, len(prompt))]
    return title.startswith(key) or key in title

def await_new_record(prompt, before_ids, timeout=30):
    fallback = None
    end = time.time() + timeout
    while time.time() < end:
        new_items = [r for r in records(20) if r.get("id") not in before_ids]
        for item in new_items:
            if record_matches_prompt(item, prompt):
                return item.get("id")
        if new_items and fallback is None:
            fallback = new_items[0].get("id")
        time.sleep(1)
    return fallback or (top_record() or {}).get("id")

def send(prompt, max_sec=180):
    before = {r.get("id") for r in records(20)}
    rpc("lingshu_send_prompt", {"text": prompt}, 30)
    rid = await_new_record(prompt, before, 30)
    return rid, wait_record(rid, max_sec)

def voice_text(prompt, max_sec=160):
    before = {r.get("id") for r in records(20)}
    rpc("lingshu_voice_text", {"text": prompt}, 30)
    rid = await_new_record(prompt, before, 30)
    return rid, wait_record(rid, max_sec)

def inv():
    return int(status().get("loopInvariantViolations", 0))

def leaks(text):
    low = (text or "").lower()
    return [p for p in INTERNAL_LEAK_PATTERNS if p.lower() in low]

def hallucinated_paths(text):
    bad = []
    for path in set(PATH_RE.findall(text or "")):
        if not os.path.exists(path):
            bad.append(path)
    return bad

def artifact_paths(record_id):
    try:
        d = detail(record_id)
    except Exception:
        return []
    out = []
    for a in d.get("artifacts", []):
        loc = a.get("location") if isinstance(a, dict) else None
        if loc:
            out.append(loc)
    return out

def accurate_model_block(text, state):
    body = f"{state}\n{text or ''}"
    quota = any(k in body for k in ["欠费", "余额不足", "额度不足", "额度已用尽", "账户余额", "billing", "quota", "credits"])
    auth = any(k in body for k in ["API Key", "认证", "授权", "401", "403", "invalid api key", "unauthorized", "forbidden"])
    invalid = any(k in body for k in ["请求参数", "模型请求", "request", "参数不合法"])
    mislabeled_network = "网络异常" in body or "网络已恢复" in body or "正在重试" in body
    return (quota or auth or invalid) and not mislabeled_network

def trace_text(limit=80):
    try:
        return rpc("lingshu_get_trace", {"limit": str(limit)}, 20)
    except Exception:
        return ""

def assert_probe(ok, label, evidence):
    print(f"[{'PASS' if ok else 'FAIL'}] {label} — {evidence}", flush=True)
    return ok

def finish_probe(record_id, state, label, require_success=True, allow_wait=False):
    txt = reply_text(record_id, 30)
    clean = not leaks(txt)
    no_fake_path = not hallucinated_paths(txt)
    terminal_ok = any(k in state for k in SUCCESS_TERMINAL)
    if allow_wait:
        terminal_ok = terminal_ok or any(k in state for k in WAITING_STATES)
    if not require_success:
        terminal_ok = not any(k in state for k in FAILURE_STATES)
    ok = terminal_ok and clean and no_fake_path
    return assert_probe(ok, label, f"status={state} clean={clean} fakePath={hallucinated_paths(txt)[:2]} reply={txt[:120]}")

def reset_context():
    for name, args in [
        ("lingshu_stop", {}),
        ("lingshu_autonomous", {"action": "stop"}),
        ("lingshu_clear_context", {}),
    ]:
        try:
            rpc(name, args, 15)
        except Exception:
            pass

def presentation_report_probe(cycle):
    prompt = (
        "完整模拟一次学校课题规划汇报,这是优先压测场景。"
        "主题《基于AI原生的A2A工程管理》,交付对象是灵枢。"
        "请你自主完成:1) 制作真实可打开的3页PPTX,页面为背景/四周工作计划/预期目标;"
        "2) 同时生成可预览版本并在灵枢内打开预览;"
        "3) 材料生成后进入自主/演示状态,全屏或可视化讲解第一页,然后停下来等待老师提问。"
        "不要问我额外信息,按现有项目上下文和合理假设推进;不要暴露内部工具名、内部协议或占位符。"
    )
    rid, st = send(prompt, 420)
    txt = reply_text(rid, 30)
    if accurate_model_block(txt, st):
        return assert_probe(True, f"#{cycle} PPT汇报全链路-模型环境阻塞准确",
                            f"status={st} reply={txt[:160]}")

    paths = artifact_paths(rid)
    existing = [p for p in paths if os.path.exists(p)]
    pptx = [p for p in existing if p.lower().endswith(".pptx")]
    preview = [p for p in existing if p.lower().endswith((".html", ".htm", ".pdf", ".pptx"))]
    s = status()
    ps = s.get("previewState", {}) if isinstance(s, dict) else {}
    spoken = "\n".join(s.get("recentSpoken", [])[-8:]) if isinstance(s, dict) else ""
    preview_open = bool(ps.get("isPresented")) or bool(ps.get("title"))
    live_mode = bool(s.get("standingPersonOnDuty")) or bool(ps.get("slideshow")) or "自主模式" in txt or "演示状态" in txt
    first_leg_ok = (
        any(k in st for k in SUCCESS_TERMINAL + WAITING_STATES)
        and bool(pptx)
        and bool(preview)
        and preview_open
        and live_mode
        and not leaks(txt)
        and not hallucinated_paths(txt)
        and any(k in (txt + spoken) for k in ["第一页", "背景", "A2A", "工程管理", "灵枢"])
    )
    if not assert_probe(first_leg_ok, f"#{cycle} PPT制作+预览+首段汇报",
                        f"status={st} pptx={pptx[:1]} previewOpen={preview_open} liveMode={live_mode} reply={txt[:140]}"):
        return False

    q_prompt = "老师提问:灵枢和 Codex、Claude Code 这种强客户端相比,你的工程管理价值到底是什么?请基于刚才汇报内容直接答疑,答完继续等待后续问题。"
    qid, qst = send(q_prompt, 260)
    qtxt = reply_text(qid, 30)
    qa_ok = (
        any(k in qst for k in SUCCESS_TERMINAL + WAITING_STATES)
        and "灵枢" in qtxt
        and any(k in qtxt for k in ["中枢", "调度", "工程管理", "任务", "验收", "记忆", "能力"])
        and "已完成答疑" not in qtxt
        and "等待后续问题" not in qtxt
        and not leaks(qtxt)
        and not hallucinated_paths(qtxt)
    )
    if not assert_probe(qa_ok, f"#{cycle} 汇报现场答疑",
                        f"status={qst} reply={qtxt[:180]}"):
        return False

    end_id, end_st = send("本轮汇报结束,关闭预览材料并收尾,一句话确认。", 140)
    end_txt = reply_text(end_id, 20)
    time.sleep(2)
    ps2 = status().get("previewState", {})
    closed = not bool(ps2.get("isPresented"))
    return assert_probe((any(k in end_st for k in SUCCESS_TERMINAL + WAITING_STATES) and closed and not leaks(end_txt)),
                        f"#{cycle} 汇报收尾关闭预览",
                        f"status={end_st} previewClosed={closed} reply={end_txt[:100]}")

def persona_probe(cycle):
    rid, st = send("我是第一次见你。用一句话介绍你自己,不要列能力清单。", 120)
    txt = reply_text(rid, 20)
    collapse = ("代码编辑器" in txt) or ("AI 编辑器" in txt) or ("你想让我写什么" in txt)
    ok = any(k in st for k in SUCCESS_TERMINAL) and "灵枢" in txt and not collapse and not leaks(txt)
    return assert_probe(ok, f"#{cycle} 人格直答", f"status={st} collapse={collapse} reply={txt[:100]}")

def time_probe(cycle):
    rid, st = send("现在是几月几日星期几?只回答当前日期。", 120)
    txt = reply_text(rid, 20)
    wrong = any(y in txt for y in ["2023", "2024", "2025", "2027", "2028"])
    ok = any(k in st for k in SUCCESS_TERMINAL) and "2026" in txt and not wrong and not leaks(txt)
    return assert_probe(ok, f"#{cycle} 当前时间态势", f"status={st} reply={txt[:100]}")

def memory_probe(cycle):
    code = f"JARVIS-{int(time.time())}-{cycle}"
    rid1, st1 = send(f"记住一个临时偏好:今天的长跑代号是 {code}。只回复已记录。", 140)
    rid2, st2 = send("刚才我说的长跑代号是什么?只回答代号。", 140)
    txt = reply_text(rid2, 20)
    ok = any(k in st2 for k in SUCCESS_TERMINAL) and code in txt and not leaks(txt)
    return assert_probe(ok, f"#{cycle} 主线程记忆", f"record1={st1} record2={st2} reply={txt[:100]}")

def permission_probe(cycle):
    rid, st = send("把我今天待办同步到一个尚未授权的外部知识库。没有授权就不要假装完成,告诉我下一步需要什么。", 180)
    txt = reply_text(rid, 30)
    waiting = any(k in st for k in WAITING_STATES) or any(k in txt for k in ["授权", "凭据", "登录", "token", "OAuth"])
    ok = waiting and has_choices(rid, 20) and not leaks(txt) and not any(k in st for k in FAILURE_STATES)
    return assert_probe(ok, f"#{cycle} 受保护边界授权", f"status={st} choices={has_choices(rid)} reply={txt[:140]}")

def file_attachment_probe(cycle):
    note = PROBE / f"meeting_note_{cycle}.md"
    note.write_text(
        "# 周会记录\n- A 项目需要周三前确认预算\n- B 项目风险是供应商延期\n- 下周要准备课题汇报\n",
        encoding="utf-8",
    )
    attach = load("lingshu_attach", {"path": str(note)}, 30)
    if not attach.get("ready"):
        return assert_probe(False, f"#{cycle} 本机附件理解", f"attachNotReady={attach}")
    rid, st = send("总结我刚才附件里的三条待办,用三点列表回答。", 160)
    txt = reply_text(rid, 20)
    ok = any(k in st for k in SUCCESS_TERMINAL) and "预算" in txt and "供应商" in txt and "课题" in txt and not leaks(txt)
    return assert_probe(ok, f"#{cycle} 本机附件理解", f"status={st} reply={txt[:140]}")

def browser_probe(cycle):
    html = PROBE / f"screen_{cycle}.html"
    html.write_text(f"<!doctype html><meta charset='utf-8'><title>灵枢可视化验证 {cycle}</title><main><h1>现实窗口 {cycle}</h1></main>", encoding="utf-8")
    rpc("browser_open", {"url": str(html)}, 30)
    time.sleep(1)
    title = rpc("browser_eval", {"js": "document.title"}, 30).strip()
    body = rpc("browser_read", {}, 30)
    ok = f"灵枢可视化验证 {cycle}" in title and f"现实窗口 {cycle}" in body
    return assert_probe(ok, f"#{cycle} 内置浏览器四肢", f"title={title[:80]}")

def peripheral_probe(cycle):
    rid, st = send("看看现在这台电脑周围有哪些可发现的外设和投屏设备,只做发现和分类,不要要求我提供账号。", 180)
    txt = reply_text(rid, 30)
    tr = trace_text(80)
    tool_used = any(k in tr for k in ["discover_devices", "peripherals", "mDNS", "Bonjour", "_airplay", "_googlecast", "扫描"])
    ok = (any(k in st for k in SUCCESS_TERMINAL + WAITING_STATES) and tool_used and not leaks(txt))
    return assert_probe(ok, f"#{cycle} 设备发现", f"status={st} toolUsed={tool_used} reply={txt[:120]}")

def voice_probe(cycle):
    rid, st = voice_text("灵枢,这是一条语音入口压测。听到后用一句话说:语音入口可用。", 160)
    txt = reply_text(rid, 20)
    ok = any(k in st for k in SUCCESS_TERMINAL) and any(k in txt for k in ["语音", "听到", "可用"]) and not leaks(txt)
    return assert_probe(ok, f"#{cycle} 语音文本入口", f"status={st} reply={txt[:100]}")

def queue_probe(cycle):
    prompts = [
        "快速问答A:给我一句话解释今天接下来最该先处理什么。",
        "快速问答B:给我一句话提醒如何避免任务切换混乱。",
        "快速问答C:给我一句话说明遇到权限阻塞该怎么办。",
        "快速问答D:给我一句话说明执行记录有什么用。",
    ]
    for p in prompts:
        rpc("lingshu_send_prompt", {"text": p}, 30)
        time.sleep(0.35)
    end = time.time() + 240
    relevant = []
    while time.time() < end:
        relevant = [r for r in records(16) if r.get("title", "").startswith("快速问答")]
        done = [r for r in relevant if any(k in r.get("status", "") for k in FINISHED)]
        if len(relevant) >= 4 and len(done) >= 4:
            break
        if not health():
            break
        time.sleep(5)
    statuses = [r.get("status", "?") for r in relevant[:4]]
    paired_all = False
    no_two_users = False
    ui_end = time.time() + 60
    while time.time() < ui_end:
        messages = chat(120)
        positions = []
        for p in prompts:
            try:
                idx = next(i for i, m in enumerate(messages) if m.get("isUser") and m.get("text") == p)
            except StopIteration:
                positions.append((p, -1, False))
                continue
            next_msg = messages[idx + 1] if idx + 1 < len(messages) else {}
            paired = (not next_msg.get("isUser")) and (
                bool((next_msg.get("text") or "").strip())
                or bool(next_msg.get("isLoading"))
                or bool(next_msg.get("taskRecordID"))
            )
            positions.append((p, idx, paired))
        found_indices = [idx for _, idx, _ in positions if idx >= 0]
        no_two_users = True
        if found_indices:
            segment = messages[min(found_indices):]
            for a, b in zip(segment, segment[1:]):
                if a.get("isUser") and b.get("isUser"):
                    no_two_users = False
                    break
        paired_all = all(paired for _, idx, paired in positions if idx >= 0) and len(found_indices) == len(prompts)
        if paired_all and no_two_users:
            break
        time.sleep(1)
    ok = len(relevant) >= 4 and not any(any(k in s for k in FAILURE_STATES) for s in statuses) and paired_all and no_two_users
    return assert_probe(ok, f"#{cycle} 一问一答交互", f"records={len(relevant)} statuses={statuses} paired={paired_all} noTwoUsers={no_two_users}")

def interrupt_probe(cycle):
    rpc("lingshu_send_prompt", {"text": "先分析一个开放式问题:如何让灵枢像贾维斯一样稳定运行。不要执行任何破坏性动作。"}, 30)
    time.sleep(5)
    rpc("lingshu_stop", {}, 20)
    time.sleep(2)
    rid, st = send("打断后恢复测试:1+1 等于几?一句话回答。", 100)
    txt = reply_text(rid, 20)
    ok = any(k in st for k in SUCCESS_TERMINAL) and ("2" in txt or "二" in txt) and not leaks(txt)
    return assert_probe(ok, f"#{cycle} 打断恢复", f"status={st} reply={txt[:100]}")

def autonomous_probe(cycle):
    rpc("lingshu_autonomous", {"action": "go_live"}, 40)
    on = False
    for _ in range(12):
        time.sleep(1)
        if status().get("standingPersonOnDuty") is True:
            on = True
            break
    rpc("lingshu_autonomous", {"action": "stop"}, 40)
    off = False
    for _ in range(12):
        time.sleep(1)
        if status().get("standingPersonOnDuty") is False:
            off = True
            break
    return assert_probe(on and off, f"#{cycle} 独立运行开关", f"on={on} off={off}")

def task_record_probe(cycle):
    r = top_record()
    if not r:
        return assert_probe(False, f"#{cycle} 任务执行记录", "no record")
    d = detail(r["id"])
    msgs = d.get("messages", [])
    txt = reply_text(r["id"], 10)
    ok = len(msgs) >= 1 and not leaks(txt)
    return assert_probe(ok, f"#{cycle} 任务执行记录", f"record={r.get('status')} messages={len(msgs)}")

PROBES = [
    presentation_report_probe,
    persona_probe,
    time_probe,
    memory_probe,
    permission_probe,
    file_attachment_probe,
    browser_probe,
    peripheral_probe,
    voice_probe,
    queue_probe,
    interrupt_probe,
    autonomous_probe,
    task_record_probe,
]

def main():
    reset_context()
    base = inv()
    print(f"[基线] loopInvariantViolations={base}", flush=True)
    total = passed = 0
    cycle = 0
    while cycle < CYCLES and time.time() < DEADLINE:
        for probe in PROBES:
            if time.time() >= DEADLINE:
                break
            total += 1
            try:
                ok = probe(cycle)
                current = inv()
                if current != base:
                    print(f"[FAIL] #{cycle} 循环不变量泄漏 — base={base} current={current}", flush=True)
                    ok = False
                if ok:
                    passed += 1
                else:
                    print(f"===== 贾维斯长跑提前停止:{passed}/{total} 通过 =====", flush=True)
                    Path("/tmp/lingshu-jarvis-result").write_text("FAIL")
                    return 1
            except Exception as e:
                print(f"[FAIL] {probe.__name__} 异常 — {type(e).__name__}: {e}", flush=True)
                print(f"===== 贾维斯长跑提前停止:{passed}/{total} 通过 =====", flush=True)
                Path("/tmp/lingshu-jarvis-result").write_text("FAIL")
                return 1
        reset_context()
        cycle += 1
    print(f"===== 贾维斯长跑结果:{passed}/{total} 通过 =====", flush=True)
    Path("/tmp/lingshu-jarvis-result").write_text("PASS" if total and passed == total else "FAIL")
    return 0 if total and passed == total else 1

raise SystemExit(main())
PY

RESULT="$(cat /tmp/lingshu-jarvis-result 2>/dev/null || echo FAIL)"
echo "==> 结果:$RESULT"
[ "$RESULT" = PASS ] && { echo "✅ 贾维斯真实世界长跑通过"; exit 0; } || { echo "❌ 贾维斯真实世界长跑发现问题"; exit 1; }
