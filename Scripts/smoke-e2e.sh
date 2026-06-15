#!/usr/bin/env bash
# 真·端到端冒烟:构建 → 启动灵枢实例 → 经 MCP 控制服务发真任务 → 按**盘上真产出物**断言 → PASS/FAIL → 拆。
#
# 与单测(swift test,脱网+脚本化模型)互补:这里跑**真模型 + 真运行的 app**,证明引擎能从头跑通一个任务,
# 而不只是单元逻辑对。外部 bash 驱动(非 app 自己驱动自己)→ 天然没有"自指/重入"问题。
#
# 取舍:真 e2e 必然要网络 + 模型 token + 输出非确定,所以**不进离线 CI**,定位是"按需/联网时跑的冒烟";
# 断言只认**抗模型措辞波动**的硬事实(文件真落盘、任务到达终态),不比字符串。
#
# 用法:bash Scripts/smoke-e2e.sh        (默认 Apple Development 签名)
#       LINGSHU_SIGN_IDENTITY="Developer ID Application: ..." bash Scripts/smoke-e2e.sh
# 退出码:0=全通过,1=有用例失败,2=环境/构建/启动失败。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${LINGSHU_MCP_PORT:-8917}"
PROBE_DIR="/Users/example/app/.lingshu-smoke-$(date +%s)"
cleanup() { rm -rf "$PROBE_DIR" 2>/dev/null; }
trap cleanup EXIT

echo "==> [1/4] 构建 .app"
if ! bash "$ROOT/Scripts/build-app.sh" debug >/tmp/lingshu-smoke-build.log 2>&1; then
  echo "构建失败,见 /tmp/lingshu-smoke-build.log"; tail -5 /tmp/lingshu-smoke-build.log; exit 2
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

echo "==> [4/4] 端到端冒烟(真模型)"
mkdir -p "$PROBE_DIR"
PROBE_DIR="$PROBE_DIR" PORT="$PORT" python3 - <<'PY'
import json, os, time, glob, urllib.request
PORT = os.environ["PORT"]; PROBE = os.environ["PROBE_DIR"]

def call(name, args, timeout=60):
    body = json.dumps({"jsonrpc":"2.0","id":1,"method":"tools/call",
                       "params":{"name":name,"arguments":args}}).encode()
    req = urllib.request.Request(f"http://127.0.0.1:{PORT}/", data=body)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())["result"]["content"][0]["text"]

def top_status():
    try:
        recs = json.loads(call("lingshu_task_records", {}))["records"]
        return recs[0]["status"] if recs else "?"
    except Exception as e:
        return f"查询失败({e})"

TERMINAL = ("已完成", "已直接回答", "异常", "未达标")
def send_wait(prompt, max_polls=30):
    call("lingshu_send_prompt", {"text": prompt})
    for _ in range(max_polls):
        time.sleep(10)
        st = top_status()
        if any(k in st for k in TERMINAL):
            return st
    return "超时"

results = []  # (名称, 通过?, 证据)

# 用例1:编码闭环(写源码 + 测试门:写测试且跑绿)——断言**盘上真有源码 + 测试文件**。
st1 = send_wait(f"在目录 {PROBE} 写 add.py,实现 add(a,b) 返回 a+b;再写测试验证 add(2,3)==5 并真正跑通;最后一句话告诉我结果与文件路径。")
has_src = os.path.exists(f"{PROBE}/add.py")
has_test = len(glob.glob(f"{PROBE}/*test*.py")) > 0 or len(glob.glob(f"{PROBE}/test_*.py")) > 0
results.append(("编码闭环: 源码+测试真落盘", has_src and has_test, f"status={st1} add.py={'有' if has_src else '无'} 测试={'有' if has_test else '无'}"))

# 用例2:对话回路——断言任务到达终态(引擎对纯问答也能跑通收尾)。
st2 = send_wait("1 加 1 等于几?一句话直接回答。", max_polls=12)
results.append(("对话回路: 纯问答能收尾", any(k in st2 for k in TERMINAL), f"status={st2}"))

print("\n===== 冒烟结果 =====")
passed = 0
for name, ok, ev in results:
    print(f"[{'PASS' if ok else 'FAIL'}] {name}  — {ev}")
    passed += 1 if ok else 0
print(f"===== {passed}/{len(results)} 通过 =====")
open("/tmp/lingshu-smoke-result", "w").write("PASS" if passed == len(results) else "FAIL")
PY

RESULT="$(cat /tmp/lingshu-smoke-result 2>/dev/null || echo FAIL)"
echo "==> 收尾:退出灵枢实例"
osascript -e 'tell application "灵枢" to quit' 2>/dev/null
[ "$RESULT" = "PASS" ] && { echo "✅ 端到端冒烟全通过"; exit 0; } || { echo "❌ 端到端冒烟有失败项"; exit 1; }
