import assert from "node:assert/strict";
import test from "node:test";
import { projectConversationMessages, type PendingSubmission } from "../src/conversationProjection.ts";
import type { ChatMessage, TaskRecord } from "../src/types.ts";

const queuedTask = (status: TaskRecord["status"] = "queued"): TaskRecord => ({
  id: "queued-task",
  title: "Queued task",
  prompt: "Revise the presentation",
  status,
  createdAt: "2026-08-20T00:00:00Z",
  updatedAt: "2026-08-20T00:00:00Z",
  steps: [],
  artifacts: [],
  summary: "",
  userMessageId: "queued-user",
  assistantMessageId: "queued-assistant",
  attachmentPaths: ["C:\\Decks\\brief.pptx"],
  role: "main",
  origin: "conversation",
  participantName: "LingShu",
  depth: 0,
  loopEngine: "grok",
});

test("projects a submission into chat before the native command returns", () => {
  const pending: PendingSubmission = {
    id: "local-1",
    text: "Revise the presentation",
    attachmentPaths: ["C:\\Decks\\brief.pptx"],
    createdAt: "2026-08-20T00:00:00Z",
  };

  const messages = projectConversationMessages([], [], [pending], "zh_cn");
  assert.deepEqual(messages.map((message) => message.role), ["user", "assistant"]);
  assert.equal(messages[0].text, pending.text);
  assert.deepEqual(messages[0].attachmentPaths, pending.attachmentPaths);
  assert.equal(messages[1].text, "正在加入执行队列…");
});

test("projects a queue-only runtime task and replaces it with canonical messages after claim", () => {
  const task = queuedTask();
  const queued = projectConversationMessages([], [task], [], "zh_cn");
  assert.equal(queued.length, 2);
  assert.equal(queued[0].id, "queued-user");
  assert.equal(queued[1].id, "queued-assistant");
  assert.equal(queued[1].text, "已进入队列，等待执行…");

  const canonical: ChatMessage[] = [
    { ...queued[0], text: "Revise the presentation" },
    { ...queued[1], text: "思考中…" },
  ];
  const claimed = projectConversationMessages(canonical, [queuedTask("understanding")], [], "zh_cn");
  assert.deepEqual(claimed, canonical);
});

test("does not duplicate a queued task that already has canonical chat messages", () => {
  const canonical: ChatMessage[] = [{
    id: "queued-user",
    role: "user",
    text: "Revise the presentation",
    createdAt: "2026-08-20T00:00:00Z",
    state: "complete",
    threadId: "queued-task",
    attachmentPaths: [],
  }];
  assert.deepEqual(projectConversationMessages(canonical, [queuedTask()], [], "en"), canonical);
});
