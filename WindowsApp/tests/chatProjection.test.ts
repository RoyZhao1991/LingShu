import assert from "node:assert/strict";
import test from "node:test";
import { projectChatBubble } from "../src/chatProjection.ts";
import { executionLinkLabel, strings } from "../src/i18n.ts";
import type { ChatMessage, RuntimeEvent } from "../src/types.ts";

const assistantMessage = (text: string, state: ChatMessage["state"] = "thinking"): ChatMessage => ({
  id: "message-1",
  role: "assistant",
  text,
  createdAt: "2026-08-09T00:00:00Z",
  state,
  threadId: "task-1",
  attachmentPaths: [],
});

const event: RuntimeEvent = {
  id: "event-1",
  sequence: 4,
  taskId: "task-1",
  kind: "model",
  state: "running",
  actor: "deepseek-chat",
  title: "模型回合 4",
  detail: "",
  createdAt: "2026-08-09T00:00:00Z",
  updatedAt: "2026-08-09T00:00:01Z",
};

test("keeps cumulative Loop output in one stable bubble instead of replacing it with the latest event", () => {
  const projection = projectChatBubble(
    assistantMessage("第一轮可见进展\n\n第二轮可见进展"),
    event,
    "zh_cn",
  );

  assert.equal(projection.key, "message-1");
  assert.equal(projection.text, "第一轮可见进展\n\n第二轮可见进展");
  assert.equal(projection.isRunning, true);
});

test("keeps cumulative assistant output intact and non-running after termination", () => {
  const text = "第一轮可见进展\n\n第二轮可见进展";
  const projection = projectChatBubble(assistantMessage(text, "complete"), event, "zh_cn");

  assert.equal(strings("zh_cn").cancelled, "已终止");
  assert.equal(strings("en").cancelled, "Terminated");
  assert.equal(projection.text, text);
  assert.equal(projection.isRunning, false);
});

test("uses readable progress only before the Loop has emitted visible text", () => {
  assert.equal(projectChatBubble(assistantMessage(""), event, "zh_cn").text, "思考中…");
  assert.equal(projectChatBubble(assistantMessage(""), undefined, "zh_cn").text, "思考中…");
  assert.equal(projectChatBubble(assistantMessage(""), undefined, "en").text, "Thinking…");
});

test("keeps structured event payloads in execution details instead of the main bubble", () => {
  const structuredEvent: RuntimeEvent = {
    ...event,
    title: "模型回合 5",
    detail: '{"file_name":"report.pptx","slides":[],"theme":"midnight"}',
  };

  assert.equal(projectChatBubble(assistantMessage(""), structuredEvent, "zh_cn").text, "思考中…");
});

test("projects legacy failure state as active recovery rather than a terminal failed bubble", () => {
  const projection = projectChatBubble(assistantMessage("", "failed"), undefined, "en");
  assert.equal(projection.text, "Recovering…");
  assert.equal(projection.isRunning, true);
});

test("switches only a completed task link from execution process to execution result", () => {
  assert.equal(executionLinkLabel("running", "zh_cn"), "查看执行过程");
  assert.equal(executionLinkLabel("needs_user_action", "zh_cn"), "查看执行过程");
  assert.equal(executionLinkLabel("completed", "zh_cn"), "查看执行结果");
  assert.equal(executionLinkLabel("running", "en"), "View execution");
  assert.equal(executionLinkLabel("completed", "en"), "View execution result");
});
