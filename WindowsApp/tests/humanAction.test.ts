import assert from "node:assert/strict";
import test from "node:test";
import { findInteractiveActionTask, isInteractiveActionTask } from "../src/humanAction.ts";
import type { TaskRecord } from "../src/types.ts";

const task = (id: string, pendingToolCallId?: string): TaskRecord => ({
  id,
  title: "Task",
  prompt: "Do the work",
  status: "needs_user_action",
  createdAt: "2026-08-10T00:00:00Z",
  updatedAt: "2026-08-10T00:00:00Z",
  steps: [],
  artifacts: [],
  summary: "Waiting",
  attachmentPaths: [],
  role: "main",
  origin: "chat",
  participantName: "LingShu",
  depth: 0,
  loopEngine: "grok",
  pendingToolCallId,
  pendingQuestion: "Confirm the prerequisite",
});

test("does not turn a legacy technical failure into a human-action modal", () => {
  assert.equal(isInteractiveActionTask(task("technical")), false);
  assert.equal(findInteractiveActionTask([task("technical")]), undefined);
});

test("shows only a checkpoint bound to a real ask_user tool call", () => {
  const interactive = task("interactive", "ask-user-call-1");
  assert.equal(isInteractiveActionTask(interactive), true);
  assert.equal(findInteractiveActionTask([task("technical"), interactive])?.id, "interactive");
});
