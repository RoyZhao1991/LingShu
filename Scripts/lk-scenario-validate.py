#!/usr/bin/env python3
"""本机知识中枢·全场景 live 验证:驱动运行中的灵枢(8917)跑各场景,按对话/轨迹判 pass/fail。
前置:灵枢 .app 已运行;测试目录 ~/lk-val 含 notes.md(VALFILE-7001)+ shot.png(VALPHOTO 7002)。"""
import json, time, urllib.request, os, sys

BASE = "http://127.0.0.1:8917/"

def rpc(method, params, timeout=25):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(BASE, data=body, headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=timeout))

def call(tool, args):
    return rpc("tools/call", {"name": tool, "arguments": args})

def chat_text(limit=12):
    try: return call("lingshu_get_chat", {"limit": limit})["result"]["content"][0]["text"]
    except Exception: return ""

def trace_text(limit=60):
    try: return call("lingshu_get_trace", {"limit": limit})["result"]["content"][0]["text"]
    except Exception: return ""

def is_busy():
    try:
        s = json.loads(call("lingshu_status", {})["result"]["content"][0]["text"])
        return bool(s.get("hasActiveModelCall"))
    except Exception: return False

def wait_idle(timeout=60):
    t0 = time.time()
    while time.time() - t0 < timeout:
        if not is_busy(): return True
        time.sleep(2)
    return False

def send(text):
    call("lingshu_send_prompt", {"text": text})

def scenario(name, prompt, pass_when, timeout=75, setup=None):
    """发指令→轮询 pass_when(chat,trace)→True 即通过。"""
    wait_idle(40)
    if setup: setup()
    send(prompt)
    t0 = time.time()
    last = ""
    while time.time() - t0 < timeout:
        time.sleep(3)
        c, tr = chat_text(), trace_text()
        last = c
        if pass_when(c, tr):
            print(f"✅ {name}")
            return True
    print(f"❌ {name}")
    print("   最近对话:", last[-300:].replace("\n", " "))
    return False

results = {}

# S1 文件源:索引 + recall 命中独特 token
results["S1 文件索引+检索"] = scenario(
    "S1 文件索引+检索",
    "调用 index_local_knowledge 工具索引目录 ~/lk-val,完成后调用 recall_local 查 VALFILE-7001,告诉我命中的文件名。",
    lambda c, tr: ("VALFILE-7001" in c or "notes.md" in c) and "recall_local" in tr,
)

# S2 照片源:本机 OCR 索引 + recall 命中图中文字
results["S2 照片OCR索引+检索"] = scenario(
    "S2 照片OCR索引+检索",
    "调用 index_photos 工具,folder 传 ~/lk-val,把图片本机识别后索引;然后调用 recall_local 查 VALPHOTO,告诉我命中的图片文件名。",
    lambda c, tr: ("VALPHOTO" in c or "shot.png" in c) and "index_photos" in tr,
    timeout=90,
)

# S3 对话自然引导(不点名工具,验"基础能力对话直用")
results["S3 自然对话触发recall"] = scenario(
    "S3 自然对话触发recall",
    "我电脑里有没有关于 VALFILE-7001 的资料?有的话告诉我在哪个文件。",
    lambda c, tr: "recall_local" in tr and ("VALFILE-7001" in c or "notes.md" in c),
)

# S4 日历工具可用(授权则索引,否则优雅提示)
results["S4 日历工具"] = scenario(
    "S4 日历工具",
    "调用 index_calendar 工具把我的日历索引进本机知识,把结果一句话告诉我。",
    lambda c, tr: "index_calendar" in tr and ("日程" in c or "日历" in c or "授权" in c or "索引" in c),
)

# S5 浏览历史工具可用
results["S5 浏览历史工具"] = scenario(
    "S5 浏览历史工具",
    "调用 index_browser_history 工具把我的浏览历史索引进来,把结果一句话告诉我。",
    lambda c, tr: "index_browser_history" in tr and ("历史" in c or "浏览" in c or "授权" in c or "索引" in c),
)

# S6 邮件工具可用
results["S6 邮件工具"] = scenario(
    "S6 邮件工具",
    "调用 index_mail 工具把我的邮件索引进来,把结果一句话告诉我。",
    lambda c, tr: "index_mail" in tr and ("邮件" in c or "授权" in c or "索引" in c or "Mail" in c),
)

# S7 FSEvents 自动增量:偷偷加新文件不手动索引,等几秒后 recall 能找到
def add_file():
    with open(os.path.expanduser("~/lk-val/added.md"), "w") as f:
        f.write("FSEvents 自动增量验证,独特标记 VALFS-7003。\n")
    time.sleep(9)  # 去抖2s+重索引
results["S7 FSEvents自动增量"] = scenario(
    "S7 FSEvents自动增量",
    "只调用 recall_local 工具(不要调 index)查 VALFS-7003,告诉我命中的文件名。",
    lambda c, tr: "VALFS-7003" in c or "added.md" in c,
    setup=add_file,
)

print("\n===== 全场景验证结果 =====")
passed = sum(1 for v in results.values() if v)
for k, v in results.items():
    print(("✅" if v else "❌"), k)
print(f"通过 {passed}/{len(results)}")
sys.exit(0 if passed == len(results) else 1)
