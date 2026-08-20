import assert from "node:assert/strict";
import test from "node:test";
import { projectConversationMessages, type PendingSubmission } from "../src/conversationProjection.ts";
import { buildMessageReuseDraft, resolveMessageAttachmentPaths } from "../src/messageReuse.ts";
import type { ChatMessage, TaskRecord } from "../src/types.ts";

const task = (attachmentPaths: string[] = []): TaskRecord => ({
  id: "task-1",
  title: "Revise the presentation",
  prompt: "Revise the presentation",
  status: "completed",
  createdAt: "2026-08-20T00:00:00Z",
  updatedAt: "2026-08-20T00:00:01Z",
  steps: [],
  artifacts: [],
  summary: "Done",
  attachmentPaths,
  role: "main",
  origin: "conversation",
  participantName: "LingShu",
  depth: 0,
  loopEngine: "grok",
});

const message = (overrides: Partial<ChatMessage> = {}): ChatMessage => ({
  id: "message-1",
  role: "user",
  text: "Revise the presentation",
  createdAt: "2026-08-20T00:00:00Z",
  state: "complete",
  threadId: "task-1",
  attachmentPaths: [],
  ...overrides,
});

test("builds an editable draft from a message's direct attachments", () => {
  const source = message({
    text: "Keep **this** text editable\nwith its line break.",
    attachmentPaths: ["C:\\Decks\\brief.pptx", "C:\\Decks\\notes.docx"],
  });

  assert.deepEqual(buildMessageReuseDraft(source, [task(["C:\\Legacy\\fallback.pdf"])]), {
    text: source.text,
    attachmentPaths: ["C:\\Decks\\brief.pptx", "C:\\Decks\\notes.docx"],
  });
});

test("falls back to the originating task for a legacy user message", () => {
  assert.deepEqual(
    resolveMessageAttachmentPaths(message(), [task(["C:\\Decks\\legacy-brief.pptx"])]),
    ["C:\\Decks\\legacy-brief.pptx"],
  );
});

test("keeps pending submission attachments without requiring a runtime task", () => {
  const pending: PendingSubmission = {
    id: "pending-1",
    text: "Review this file",
    attachmentPaths: ["C:\\Docs\\review.pdf"],
    createdAt: "2026-08-20T00:00:00Z",
  };
  const pendingUserMessage = projectConversationMessages([], [], [pending], "zh_cn")
    .find((candidate) => candidate.role === "user");

  assert.ok(pendingUserMessage);
  assert.deepEqual(buildMessageReuseDraft(pendingUserMessage, []), {
    text: pending.text,
    attachmentPaths: pending.attachmentPaths,
  });
});

test("does not make an assistant message inherit the task's user attachments", () => {
  const assistant = message({ role: "assistant", attachmentPaths: [] });

  assert.deepEqual(
    resolveMessageAttachmentPaths(assistant, [task(["C:\\Private\\user-input.docx"])]),
    [],
  );
});

test("returns an empty attachment list when the originating task is unavailable", () => {
  assert.deepEqual(resolveMessageAttachmentPaths(message(), []), []);
});

test("deduplicates equivalent Windows attachment paths", () => {
  const source = message({
    attachmentPaths: [
      "C:\\Users\\Roy\\Documents\\Resume.PDF",
      "c:/users/roy/documents/resume.pdf",
      "  C:\\Users\\Roy\\Documents\\notes.md  ",
      "",
    ],
  });

  assert.deepEqual(resolveMessageAttachmentPaths(source, []), [
    "C:\\Users\\Roy\\Documents\\Resume.PDF",
    "C:\\Users\\Roy\\Documents\\notes.md",
  ]);
});

test("returns attachment arrays isolated from the message and task snapshots", () => {
  const source = message();
  const sourceTask = task(["C:\\Decks\\source.pptx"]);
  const first = buildMessageReuseDraft(source, [sourceTask]);

  first.attachmentPaths.push("C:\\Decks\\new-file.pptx");

  assert.deepEqual(source.attachmentPaths, []);
  assert.deepEqual(sourceTask.attachmentPaths, ["C:\\Decks\\source.pptx"]);
  assert.deepEqual(buildMessageReuseDraft(source, [sourceTask]).attachmentPaths, [
    "C:\\Decks\\source.pptx",
  ]);
});
