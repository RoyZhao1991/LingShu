#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
灵枢 E2E 跑批 harness(MCP 驱动,后台分批持续跑)。
三类场景:A 主线程规划任务 / B 子线程任务续接 / C 生成演示文稿并演示。
每个 case 跑完做断言,结构化 pass/fail 落 ~/lingshu_e2e_results.jsonl,便于分批复盘。
用法:python3 e2e_harness.py <batch_name> [起始序号]
"""
import json, urllib.request, time, sys, os, datetime

MCP = "http://127.0.0.1:8917"
LOG = os.path.expanduser("~/lingshu_e2e_results.jsonl")
WORKDIR = os.path.expanduser("~/app")

def call(tool, args=None, timeout=12):
    payload = {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":tool,"arguments":args or {}}}
    req = urllib.request.Request(MCP, data=json.dumps(payload).encode(),
                                 headers={"Content-Type":"application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            d = json.load(r)
        return json.loads(d["result"]["content"][0]["text"])
    except Exception as e:
        return {"_error": str(e)}

def send(text):            return call("lingshu_voice_text", {"text": text}, timeout=15)
def followup(rid, text):   return call("lingshu_task_followup", {"recordId": rid, "text": text}, timeout=15)
def records():
    r = call("lingshu_task_records"); return r.get("records", []) if isinstance(r, dict) else []
def detail(rid):           return call("lingshu_task_detail", {"recordId": rid})
def chat():
    r = call("lingshu_get_chat"); return (r.get("messages") or r.get("chat") or []) if isinstance(r, dict) else (r or [])

def newest_record_id(before_ids):
    for rec in records():
        if rec.get("id") not in before_ids:
            return rec.get("id")
    return None

def participants(rid):
    det = detail(rid); acts=[]
    for m in det.get("messages", []):
        a = m.get("actor","")
        if a and a not in acts: acts.append(a)
    return acts, det

def wait_done(rid, timeout_s):
    """轮询任务到终态;返回 (status, participants, detail)。"""
    t0 = time.time()
    while time.time() - t0 < timeout_s:
        acts, det = participants(rid)
        st = det.get("status","")
        if st in ("已完成","已交付","已停止","verified","部分完成","已搁置","失败"):
            return st, acts, det
        time.sleep(6)
    acts, det = participants(rid)
    return det.get("status","(超时未终态)"), acts, det

def logrec(entry):
    entry["ts"] = datetime.datetime.now().strftime("%H:%M:%S")
    with open(LOG, "a") as f: f.write(json.dumps(entry, ensure_ascii=False)+"\n")
    flag = "✅PASS" if entry.get("pass") else "❌FAIL"
    print(f'{entry["ts"]} [{entry["cat"]}] {flag} {entry["id"]}: {entry.get("note","")[:80]}', flush=True)

# ── 断言库 ──────────────────────────────────────────────────────────────
def assert_dispatched_with_checker(rid, st, acts, det, expect_maker=None):
    """派发任务:终态完成 + 有独立 checker(审查员/Codex maker 时)。"""
    fails=[]
    if st not in ("已完成","已交付","verified"): fails.append(f"状态={st}")
    if expect_maker and expect_maker not in acts: fails.append(f"缺 maker 参与方 {expect_maker}")
    if expect_maker and ("审查员" not in acts and not any("checker" in (m.get("role","")) for m in det.get("messages",[]))):
        fails.append("缺独立 checker(审查员/checker 角色)")
    return (len(fails)==0, "；".join(fails) or "派发完成+独立checker齐")

def assert_direct_answer(reply_text):
    fails=[]
    if not reply_text or len(reply_text) < 10: fails.append("无有效直答")
    return (len(fails)==0, "；".join(fails) or f"直答 {len(reply_text)}字")

# ── 场景批次定义 ──────────────────────────────────────────────────────────
def run_case_dispatch(cid, cat, prompt, timeout_s, expect_maker=None, file_check=None):
    before = {r.get("id") for r in records()}
    send(prompt); time.sleep(4)
    rid = newest_record_id(before)
    if not rid:
        logrec({"id":cid,"cat":cat,"prompt":prompt,"pass":False,"note":"没派生任务记录(可能被直答?)"}); return None
    st, acts, det = wait_done(rid, timeout_s)
    ok, note = assert_dispatched_with_checker(rid, st, acts, det, expect_maker)
    arts = [a.get("location") for a in det.get("artifacts",[])]
    if file_check:
        fok = os.path.exists(os.path.join(WORKDIR, file_check))
        ok = ok and fok; note += f"；文件{file_check}={'有' if fok else '缺'}"
    logrec({"id":cid,"cat":cat,"prompt":prompt,"pass":ok,"note":note,"status":st,
            "participants":acts,"artifacts":arts,"rid":rid})
    return rid

def run_case_direct(cid, cat, prompt, timeout_s):
    """直答类(主线程规划:判为纯对话→直答,不派生重任务)。
    断言:① 该消息的任务记录被标「已直接回答」(=正确直答路由,非派发) 或 ② chat 有实质回复。"""
    before = {r.get("id") for r in records()}
    send(prompt)
    t0=time.time(); reply=""; direct=False
    while time.time()-t0 < timeout_s:
        time.sleep(5)
        for rec in records():
            if rec.get("id") not in before and ("直接回答" in rec.get("status","") or "直答" in rec.get("status","")):
                direct=True
        cand = [m for m in chat() if not m.get("isUser") and (m.get("text") or "").strip() and not m.get("isLoading")]
        if cand: reply = cand[-1].get("text","")
        if direct and len(reply) > 20: break
    ok = direct or len(reply.strip()) > 20
    note = ("直答路由✓(已直接回答) " if direct else "(未标直答) ") + f"{len(reply)}字"
    logrec({"id":cid,"cat":cat,"prompt":prompt,"pass":ok,"note":note,"reply":reply[:160]})

def run_case_followup(cid, cat, prompt, followup_text, timeout_s, expect_maker=None):
    rid = run_case_dispatch(cid, cat, prompt, timeout_s, expect_maker)
    if not rid:
        logrec({"id":cid+".f","cat":cat,"pass":False,"note":"首发失败,跳过续接"}); return
    time.sleep(3)
    n_before = len(detail(rid).get("messages",[]))
    followup(rid, followup_text); time.sleep(4)
    st, acts, det = wait_done(rid, timeout_s)
    n_after = len(det.get("messages",[]))
    # 续接断言:同一 rid 消息增多(续接进了同一子线程,没另起)+ 终态完成
    ok = n_after > n_before and st in ("已完成","已交付","verified")
    note = f"续接同线程(+{n_after-n_before}消息) 状态={st}"
    logrec({"id":cid+".f","cat":cat,"prompt":followup_text,"pass":ok,"note":note,
            "status":st,"participants":acts,"rid":rid})

if __name__ == "__main__":
    print(f"=== E2E harness 启动 {datetime.datetime.now()} 日志={LOG} ===", flush=True)
    # 烟雾测试:确认 MCP 活着
    s = call("lingshu_status")
    if "_error" in s:
        print("MCP 不可用,退出:", s["_error"]); sys.exit(1)
    import os as _os
    BATCH_NAME = sys.argv[1] if len(sys.argv) > 1 else "batch"
    BATCHES = {
        # 第一批:验证 harness + maker/checker 链路
        "batch1": [
            ("A1","A-主线程规划", "dispatch", "@Codex 写一个 Python 摄氏华氏温度互换函数 temp.py(c2f/f2c)并写 pytest 测试", 420, "Codex", "temp.py"),
            ("A2","A-主线程规划", "dispatch", "@Codex 写一个 Python 函数判断括号是否匹配 brackets.py(支持 ()[]{}）并写 pytest 测试", 420, "Codex", "brackets.py"),
            ("B1","B-子线程续接", "followup", "@Codex 写一个 Python 栈类 stack.py(push/pop/peek/is_empty)并写 pytest 测试", "再加一个 size() 方法并补测试", 480, "Codex"),
        ],
        # 第二批:更多变体 + 直答类(主线程不该派发)
        "batch2": [
            ("A3","A-主线程规划", "dispatch", "@Codex 写一个 Python LRU 缓存 lru.py(get/put,容量上限,超限淘汰最久未用)并写 pytest 测试", 480, "Codex", "lru.py"),
            ("A4","A-主线程规划", "direct",   "用三句话讲讲哈希表的原理", 90),
            ("A5","A-主线程规划", "dispatch", "@Codex 写一个 Python 罗马数字转整数函数 roman.py(roman_to_int)并写 pytest 测试", 480, "Codex", "roman.py"),
            ("B2","B-子线程续接", "followup", "@Codex 写一个 Python 单向链表 linkedlist.py(append/find/delete)并写 pytest 测试", "加一个 reverse() 反转方法并补测试", 540, "Codex"),
        ],
        # 第四批:数据处理/校验类 + 比较推理直答 + 精化型续接
        "batch4": [
            ("A9","A-主线程规划", "dispatch", "@Codex 写一个 Python 统计文本词频函数 wordfreq.py(top_words(text,n) 返回前n高频词)并写 pytest 测试", 540, "Codex", "wordfreq.py"),
            ("A10","A-主线程规划", "direct",   "什么时候该用快排,什么时候该用归并排序?", 90),
            ("B4","B-子线程续接", "followup", "@Codex 写一个 Python 邮箱格式校验函数 email_validate.py(is_valid_email)并写 pytest 测试", "再支持一下带子域名和 + 号的地址,改进并补测试", 600, "Codex"),
        ],
        # 第三批:算法/数据结构变体 + 直答
        "batch3": [
            ("A6","A-主线程规划", "dispatch", "@Codex 写一个 Python 二分查找函数 binsearch.py(binary_search)并写 pytest 测试", 480, "Codex", "binsearch.py"),
            ("A7","A-主线程规划", "direct",   "简单解释一下 TCP 三次握手", 90),
            ("A8","A-主线程规划", "dispatch", "@Codex 写一个 Python 命令行计算器 calc.py(支持 + - * / 和括号)并写 pytest 测试", 540, "Codex", "calc.py"),
            ("B3","B-子线程续接", "followup", "@Codex 写一个 Python 二叉搜索树 bst.py(insert/search/inorder)并写 pytest 测试", "加一个 delete 删除节点方法并补测试", 600, "Codex"),
        ],
    }
    BATCH = BATCHES.get(BATCH_NAME.split("-")[0], BATCHES["batch1"])
    for c in BATCH:
        try:
            if c[2]=="dispatch":
                run_case_dispatch(c[0],c[1],c[3],c[4],c[5] if len(c)>5 else None, c[6] if len(c)>6 else None)
            elif c[2]=="followup":
                run_case_followup(c[0],c[1],c[3],c[4],c[5],c[6] if len(c)>6 else None)
            elif c[2]=="direct":
                run_case_direct(c[0],c[1],c[3],c[4])
        except Exception as e:
            logrec({"id":c[0],"cat":c[1],"pass":False,"note":f"harness异常:{e}"})
        time.sleep(5)
    print("=== 批次结束 ===", flush=True)
