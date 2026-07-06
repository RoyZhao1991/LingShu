#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
灵枢产品化回归基线。

定位:
- 测灵枢客户端/harness 能力,不是刷大模型写算法题。
- 默认连接当前运行中的灵枢控制服务,不重启、不清空用户环境。
- --quick 跑短程基线;--full 追加更慢的演示/队列探针。
- --report-to-chat 把摘要发进灵枢聊天窗口,便于界面验收。

退出码:
0 = 全通过
1 = 有失败
2 = 控制服务不可用
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


SUCCESS_TERMINAL = ("已完成", "已直接回答", "已核验", "已交付")
WAITING_STATES = ("待用户", "部分完成", "等待")
FAILURE_STATES = ("异常", "未达标", "失败")
FINISHED = SUCCESS_TERMINAL + WAITING_STATES + FAILURE_STATES

INTERNAL_LEAK_PATTERNS = (
    "__LINGSHU_HUMAN_INPUT__",
    "LINGSHU_HUMAN_INPUT",
    "ask_user",
    "ask_choice",
    "ask_form",
    "GoalSpec",
    "GapAnalysis",
    "VALFILE-",
    "VALFS-",
    "index_local_knowledge",
    "recall_local",
    "需要你配合:子任务",
    "子任务「调用",
    "\"route\"",
    "\"authorization\"",
    "\"missingPrerequisites\"",
)

PATH_RE = re.compile(
    r"/[^\s`\"'）)，。、；;】]+?\.(?:py|txt|md|json|csv|pdf|docx|pptx|html?|wav|mp3|png|jpg|jpeg)",
    re.I,
)


@dataclass
class ProbeResult:
    name: str
    passed: bool
    evidence: str
    record_id: str = ""
    status: str = ""


@dataclass
class LingShuClient:
    endpoint: str
    anchors: dict[str, str] = field(default_factory=dict)

    def rpc(self, name: str, args: dict[str, Any] | None = None, timeout: int = 60) -> str:
        body = json.dumps({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {"name": name, "arguments": args or {}},
        }).encode("utf-8")
        req = urllib.request.Request(self.endpoint, data=body, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as response:
            data = json.loads(response.read())
        if "error" in data:
            raise RuntimeError(data["error"])
        result = data.get("result", {})
        text = result.get("content", [{}])[0].get("text", "")
        if result.get("isError"):
            raise RuntimeError(text)
        return text

    def load(self, name: str, args: dict[str, Any] | None = None, timeout: int = 60) -> Any:
        return json.loads(self.rpc(name, args or {}, timeout))

    def health(self) -> bool:
        try:
            urllib.request.urlopen(self.endpoint.replace("/", "/health", 1), timeout=3)
            return True
        except Exception:
            try:
                # endpoint normally ends with "/", so the replacement above is intentionally defensive.
                base = self.endpoint.rstrip("/")
                urllib.request.urlopen(f"{base}/health", timeout=3)
                return True
            except Exception:
                return False

    def status(self) -> dict[str, Any]:
        return self.load("lingshu_status", {}, 10)

    def records(self, limit: int = 20) -> list[dict[str, Any]]:
        return self.load("lingshu_task_records", {"limit": limit}, 20).get("records", [])

    def detail(self, record_id: str) -> dict[str, Any]:
        return self.load("lingshu_task_detail", {"recordId": record_id}, 30)

    def chat(self, limit: int = 80) -> list[dict[str, Any]]:
        data = self.load("lingshu_get_chat", {"limit": limit}, 20)
        return data.get("messages", data) if isinstance(data, dict) else data

    def message_by_id(self, message_id: str, limit: int = 120) -> dict[str, Any]:
        if not message_id:
            return {}
        for message in self.chat(limit):
            if message.get("id") == message_id:
                return message
        return {}

    def latest_assistant_text(self, record_id: str = "", max_wait: int = 0) -> str:
        end = time.time() + max_wait
        while True:
            if record_id:
                anchor = self.anchors.get(record_id, "")
                if anchor:
                    message = self.message_by_id(anchor)
                    if message and not message.get("isLoading"):
                        return message.get("text", "")
                for message in reversed(self.chat(100)):
                    if not message.get("isUser") and not message.get("isLoading") and message.get("taskRecordID") == record_id:
                        return message.get("text", "")
            else:
                for message in reversed(self.chat(50)):
                    if not message.get("isUser") and not message.get("isLoading"):
                        return message.get("text", "")
            if time.time() >= end:
                return ""
            time.sleep(1)

    def has_user_choice(self, record_id: str = "") -> bool:
        anchor = self.anchors.get(record_id, "")
        candidates = []
        if anchor:
            candidates.append(self.message_by_id(anchor))
        candidates.extend(self.chat(40))
        for message in candidates:
            if record_id and message.get("taskRecordID") not in (record_id, None):
                continue
            if message.get("choices") or message.get("form"):
                return True
        return False

    def send(self, text: str, max_idle_sec: int = 160) -> tuple[str, str]:
        record_id, assistant_id, _ = self.start_turn(text)
        return record_id, self._wait_record(record_id, assistant_id, max_idle_sec)

    def start_turn(self, text: str) -> tuple[str, str, set[str]]:
        before_ids = {record.get("id") for record in self.records(40)}
        anchor = self.load("lingshu_send_prompt", {"text": text}, 30)
        assistant_id = anchor.get("assistantMessageId", "")
        record_id = anchor.get("recordId", "") or self._await_record(text, before_ids, assistant_id)
        if record_id and assistant_id:
            self.anchors[record_id] = assistant_id
        return record_id, assistant_id, before_ids

    def followup(self, record_id: str, text: str, max_idle_sec: int = 180) -> str:
        self.load("lingshu_task_followup", {"recordId": record_id, "text": text}, 30)
        return self._wait_record(record_id, self.anchors.get(record_id, ""), max_idle_sec)

    def _await_record(self, prompt: str, before_ids: set[str], assistant_id: str, timeout: int = 45) -> str:
        end = time.time() + timeout
        key = prompt[: min(24, len(prompt))]
        while time.time() < end:
            if assistant_id:
                message = self.message_by_id(assistant_id)
                if message.get("taskRecordID"):
                    return message["taskRecordID"]
                if message and not message.get("isLoading") and (message.get("text") or "").strip():
                    return f"anchor:{assistant_id}"
            for record in self.records(30):
                if record.get("id") not in before_ids and key and key in (record.get("title", "") + record.get("promptExcerpt", "")):
                    return record.get("id", "")
            time.sleep(1)
        return f"anchor:{assistant_id}" if assistant_id else ""

    def _wait_record(self, record_id: str, assistant_id: str, max_idle_sec: int) -> str:
        last_signature: tuple[Any, ...] | None = None
        last_progress = time.time()
        last_status = "?"
        while True:
            if not self.health():
                return "DEADLOCK"
            record = {}
            if record_id and not record_id.startswith("anchor:"):
                record = next((item for item in self.records(30) if item.get("id") == record_id), {})
            elif not record_id:
                all_records = self.records(1)
                record = all_records[0] if all_records else {}
            message = self.message_by_id(assistant_id) if assistant_id else {}
            last_status = record.get("status", last_status)
            signature = (
                last_status,
                record.get("messageCount", 0),
                record.get("artifactCount", 0),
                bool(message.get("isLoading")),
                len(message.get("text", "") or ""),
                bool(message.get("choices") or message.get("form")),
            )
            if signature != last_signature:
                last_signature = signature
                last_progress = time.time()
            if message and not message.get("isLoading"):
                if message.get("choices") or message.get("form"):
                    return "待用户"
                if record_id.startswith("anchor:") and (message.get("text") or "").strip():
                    return "已直接回答"
            if any(mark in last_status for mark in FINISHED):
                return last_status
            if time.time() - last_progress > max_idle_sec:
                return f"超时无进展({last_status})"
            time.sleep(3)

    def find_record_by_tokens(self, tokens: list[str], exclude_ids: set[str] | None = None, limit: int = 80) -> dict[str, Any]:
        exclude_ids = exclude_ids or set()
        best: dict[str, Any] = {}
        best_hits = 0
        for record in self.records(limit):
            if record.get("id") in exclude_ids:
                continue
            haystack = json.dumps(record, ensure_ascii=False)
            hits = sum(1 for token in tokens if token and token in haystack)
            if hits > best_hits:
                best = record
                best_hits = hits
        required_hits = min(2, len([token for token in tokens if token]))
        return best if best_hits >= required_hits else {}

    def wait_record_or_preview(self, record_id: str, max_idle_sec: int, require_preview: bool = False) -> str:
        last_signature: tuple[Any, ...] | None = None
        last_progress = time.time()
        last_status = "?"
        while True:
            if not self.health():
                return "DEADLOCK"
            record = {}
            if record_id and not record_id.startswith("anchor:"):
                record = next((item for item in self.records(80) if item.get("id") == record_id), {})
                last_status = record.get("status", last_status)
            preview = self.status().get("previewState", {})
            preview_ready = bool(preview.get("isPresented") or preview.get("title"))
            signature = (
                last_status,
                record.get("messageCount", 0),
                record.get("artifactCount", 0),
                preview.get("isPresented"),
                preview.get("title", ""),
                preview.get("pageCount", 0),
                preview.get("pageIndex", 0),
            )
            if signature != last_signature:
                last_signature = signature
                last_progress = time.time()
            if any(mark in last_status for mark in FAILURE_STATES):
                return last_status
            if preview_ready and not any(mark in last_status for mark in FAILURE_STATES):
                return last_status if last_status != "?" else "预览已打开"
            if any(mark in last_status for mark in SUCCESS_TERMINAL + WAITING_STATES) and not require_preview:
                return last_status
            if time.time() - last_progress > max_idle_sec:
                return f"超时无进展({last_status})"
            time.sleep(3)


def internal_leaks(text: str) -> list[str]:
    low = (text or "").lower()
    return [item for item in INTERNAL_LEAK_PATTERNS if item.lower() in low]


def hallucinated_paths(text: str) -> list[str]:
    return [path for path in set(PATH_RE.findall(text or "")) if not os.path.exists(path)]


def terminal_success(status: str, allow_waiting: bool = False) -> bool:
    if any(mark in status for mark in SUCCESS_TERMINAL):
        return True
    return allow_waiting and any(mark in status for mark in WAITING_STATES)


def ok_text(client: LingShuClient, name: str, record_id: str, status: str, must_contain: tuple[str, ...] = (), allow_waiting: bool = False) -> ProbeResult:
    text = client.latest_assistant_text(record_id, 20)
    leaks = internal_leaks(text)
    fake_paths = hallucinated_paths(text)
    contains = all(token in text for token in must_contain)
    passed = terminal_success(status, allow_waiting) and contains and not leaks and not fake_paths
    return ProbeResult(
        name=name,
        passed=passed,
        status=status,
        record_id=record_id,
        evidence=f"status={status} contains={contains} leaks={leaks[:2]} fakePaths={fake_paths[:2]} reply={text[:160]}",
    )


def probe_context_continuation(client: LingShuClient) -> ProbeResult:
    rid1, st1 = client.send("我是第一次见你。用两句话介绍你自己，不要列能力清单。", 140)
    first = client.latest_assistant_text(rid1, 20)
    rid2, st2 = client.send("继续", 140)
    second = client.latest_assistant_text(rid2, 20)
    blocked = any(token in second for token in ("继续什么", "指明具体", "当前状态", "可续接的方向"))
    drifted = any(token in second for token in ("三页", "演示材料", "讲完", "页面", "PPT", "预览"))
    continued_intro = any(token in second for token in ("灵枢", "我", "中枢", "助手", "Roy"))
    passed = terminal_success(st1) and terminal_success(st2) and "灵枢" in first and continued_intro and not blocked and not drifted and not internal_leaks(second)
    return ProbeResult(
        "最近上下文续接",
        passed,
        f"first={st1} second={st2} blocked={blocked} drifted={drifted} reply={second[:160]}",
        rid2,
        st2,
    )


def probe_oauth_no_false_auth(client: LingShuClient) -> ProbeResult:
    rid, status = client.send("一句话解释 OAuth 的 access token 是什么。", 120)
    text = client.latest_assistant_text(rid, 20)
    false_auth = client.has_user_choice(rid) or any(token in text for token in ("这一步需要你授权", "确认授权", "给我 token"))
    passed = terminal_success(status) and "OAuth" in text and not false_auth and not internal_leaks(text)
    return ProbeResult("普通知识不误弹授权", passed, f"status={status} falseAuth={false_auth} reply={text[:160]}", rid, status)


def probe_attachment_reuse(client: LingShuClient, workdir: Path) -> ProbeResult:
    note = workdir / "meeting-note.md"
    note.write_text(
        "# 会议记录\n- 周三前确认预算\n- 供应商延期是主要风险\n- 下周准备课题汇报\n",
        encoding="utf-8",
    )
    attach = client.load("lingshu_attach", {"path": str(note)}, 30)
    if not attach.get("ready"):
        return ProbeResult("附件直接复用", False, f"attachment not ready: {attach}")
    rid, status = client.send("总结刚才附件里的三条待办，不要再找文件。", 160)
    text = client.latest_assistant_text(rid, 20)
    passed = terminal_success(status) and all(token in text for token in ("预算", "供应商", "课题")) and not internal_leaks(text)
    return ProbeResult("附件直接复用", passed, f"status={status} reply={text[:160]}", rid, status)


def probe_task_artifact_and_followup(client: LingShuClient, workdir: Path) -> ProbeResult:
    target = workdir / "brief.md"
    rid, status = client.send(
        f"在 {workdir} 生成一个 markdown 简报，主题是灵枢九站链路，保存为 brief.md，并登记产出物。",
        240,
    )
    exists = target.exists()
    detail = client.detail(rid) if rid and not rid.startswith("anchor:") else {}
    artifact_locations = [item.get("location") for item in detail.get("artifacts", []) if isinstance(item, dict)]
    first_pass = terminal_success(status) and exists and str(target) in artifact_locations
    if not first_pass:
        return ProbeResult("任务产物与续接", False, f"first status={status} exists={exists} artifacts={artifact_locations}", rid, status)
    before_messages = len(detail.get("messages", []))
    next_status = client.followup(rid, "在同一个简报里补一段风险与验收标准，仍然登记同一个产出物。", 240)
    next_detail = client.detail(rid)
    after_messages = len(next_detail.get("messages", []))
    content = target.read_text(encoding="utf-8", errors="ignore")
    passed = terminal_success(next_status) and after_messages > before_messages and "风险" in content and "验收" in content
    return ProbeResult(
        "任务产物与续接",
        passed,
        f"first={status} followup={next_status} messages=+{after_messages-before_messages} exists={exists}",
        rid,
        next_status,
    )


def probe_stop_recovery(client: LingShuClient) -> ProbeResult:
    client.load("lingshu_send_prompt", {"text": "先详细分析一个开放问题：如何让灵枢稳定成为通用中枢。不要执行破坏性动作。"}, 30)
    time.sleep(5)
    stop = client.load("lingshu_stop", {}, 20)
    rid, status = client.send("打断后恢复测试：2+3 等于几？一句话回答。", 100)
    text = client.latest_assistant_text(rid, 20)
    passed = terminal_success(status) and ("5" in text or "五" in text) and not internal_leaks(text)
    return ProbeResult("停止后恢复", passed, f"stop={stop} status={status} reply={text[:120]}", rid, status)


def probe_ledger_latest(client: LingShuClient) -> ProbeResult:
    records = client.records(8)
    status = client.status()
    ledger = status.get("globalTaskThreadLedger", [])
    newest = records[0] if records else {}
    newest_id = newest.get("id", "")
    haystack = json.dumps(ledger, ensure_ascii=False)
    passed = bool(newest_id) and newest_id in haystack
    return ProbeResult("主线程账本同步", passed, f"newest={newest_id} ledgerHit={passed}")


def probe_one_question_one_answer(client: LingShuClient) -> ProbeResult:
    token = f"BASE-QA-{int(time.time())}"
    prompts = [
        f"{token}-A:一句话说说灵枢是什么。",
        f"{token}-B:一句话说说任务记录有什么用。",
        f"{token}-C:一句话说说遇到权限阻塞怎么办。",
    ]
    before = len(client.chat(160))
    for prompt in prompts:
        client.load("lingshu_send_prompt", {"text": prompt}, 30)
        time.sleep(0.4)
    end = time.time() + 220
    paired = False
    no_adjacent_users = False
    while time.time() < end:
        messages = client.chat(220)
        segment = messages[before:]
        user_indices = [idx for idx, message in enumerate(segment) if message.get("isUser") and token in (message.get("text") or "")]
        if len(user_indices) >= len(prompts):
            paired = True
            for idx in user_indices:
                if idx + 1 >= len(segment):
                    paired = False
                    break
                next_message = segment[idx + 1]
                if next_message.get("isUser") or (not next_message.get("isLoading") and not (next_message.get("text") or next_message.get("taskRecordID"))):
                    paired = False
                    break
            no_adjacent_users = all(not (a.get("isUser") and b.get("isUser")) for a, b in zip(segment, segment[1:]))
            if paired and no_adjacent_users:
                break
        time.sleep(2)
    return ProbeResult("一问一答顺序", paired and no_adjacent_users, f"paired={paired} noAdjacentUsers={no_adjacent_users}")


def probe_presentation_path(client: LingShuClient, workdir: Path) -> ProbeResult:
    prompt = f"在 {workdir} 制作一个 3 页 HTML 演示页，主题是灵枢九站链路，然后打开预览并讲第一页，最后等待提问。"
    rid, _, before_ids = client.start_turn(prompt)
    matched = client.find_record_by_tokens([str(workdir), "HTML 演示页", "灵枢九站链路"], before_ids)
    if matched:
        rid = matched.get("id", rid)
    status = "?"
    detail: dict[str, Any] = {}
    preview: dict[str, Any] = {}
    existing: list[str] = []
    last_signature: tuple[Any, ...] | None = None
    last_progress = time.time()
    while True:
        record = next((item for item in client.records(80) if item.get("id") == rid), {}) if rid and not rid.startswith("anchor:") else {}
        status = record.get("status", status)
        detail = client.detail(rid) if rid and not rid.startswith("anchor:") else {}
        artifacts = [item.get("location") for item in detail.get("artifacts", []) if isinstance(item, dict)]
        existing = [path for path in artifacts if path and os.path.exists(path)]
        preview = client.status().get("previewState", {})
        signature = (
            status,
            len(existing),
            preview.get("isPresented"),
            preview.get("title", ""),
            preview.get("pageCount", 0),
            preview.get("pageIndex", 0),
        )
        if signature != last_signature:
            last_signature = signature
            last_progress = time.time()
        preview_ready = bool(preview.get("isPresented") or preview.get("title"))
        if any(mark in status for mark in FAILURE_STATES):
            break
        if existing and preview_ready:
            break
        if any(mark in status for mark in SUCCESS_TERMINAL + WAITING_STATES) and existing:
            break
        if time.time() - last_progress > 420:
            status = f"超时无进展({status})"
            break
        time.sleep(3)
    text = client.latest_assistant_text(rid, 30)
    passed = terminal_success(status, allow_waiting=True) and bool(existing) and bool(preview.get("isPresented") or preview.get("title")) and not internal_leaks(text)
    return ProbeResult("演示交付链路", passed, f"status={status} artifacts={existing[:2]} preview={preview}", rid, status)


def run(mode: str, client: LingShuClient, workdir: Path) -> list[ProbeResult]:
    probes = [
        lambda: probe_context_continuation(client),
        lambda: probe_oauth_no_false_auth(client),
        lambda: probe_attachment_reuse(client, workdir),
        lambda: probe_task_artifact_and_followup(client, workdir),
        lambda: probe_stop_recovery(client),
        lambda: probe_ledger_latest(client),
    ]
    if mode == "full":
        probes.extend([
            lambda: probe_one_question_one_answer(client),
            lambda: probe_presentation_path(client, workdir),
        ])
    results: list[ProbeResult] = []
    for probe in probes:
        try:
            result = probe()
        except Exception as exc:  # noqa: BLE001 - baseline must record the failure.
            result = ProbeResult(getattr(probe, "__name__", "probe"), False, f"{type(exc).__name__}: {exc}")
        results.append(result)
        mark = "PASS" if result.passed else "FAIL"
        print(f"[{mark}] {result.name} — {result.evidence}", flush=True)
        if not result.passed and mode == "quick":
            break
    return results


def report_to_chat(client: LingShuClient, results: list[ProbeResult], label: str) -> None:
    passed = sum(1 for item in results if item.passed)
    lines = [f"灵枢产品化回归基线 {label}: {passed}/{len(results)} 通过"]
    for item in results:
        mark = "PASS" if item.passed else "FAIL"
        lines.append(f"- {mark} {item.name}: {item.evidence[:120]}")
    text = "\n".join(lines)
    client.load(
        "lingshu_send_prompt",
        {"text": f"请把下面这份测试结果作为普通消息记录到对话窗口，不要启动新任务，不要调用工具：\n{text}"},
        30,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("quick", "full"), default="quick")
    parser.add_argument("--quick", action="store_true", help="alias for --mode quick")
    parser.add_argument("--full", action="store_true", help="alias for --mode full")
    parser.add_argument("--port", default=os.environ.get("LINGSHU_MCP_PORT", "8917"))
    parser.add_argument("--workdir", default="")
    parser.add_argument("--report-to-chat", action="store_true")
    args = parser.parse_args()

    mode = "full" if args.full else ("quick" if args.quick else args.mode)
    endpoint = f"http://127.0.0.1:{args.port}/"
    client = LingShuClient(endpoint)
    if not client.health():
        print(f"控制服务不可用: {endpoint}", file=sys.stderr)
        return 2

    workdir = Path(args.workdir) if args.workdir else Path(tempfile.mkdtemp(prefix="lingshu-product-baseline-"))
    workdir.mkdir(parents=True, exist_ok=True)
    print(f"==> 灵枢产品化回归基线 mode={mode} workdir={workdir}", flush=True)
    results = run(mode, client, workdir)
    passed = sum(1 for item in results if item.passed)
    print(f"==> 结果: {passed}/{len(results)} 通过", flush=True)
    if args.report_to_chat:
        report_to_chat(client, results, mode)
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
