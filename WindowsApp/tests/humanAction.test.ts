import assert from "node:assert/strict";
import test from "node:test";
import {
  findInteractiveActionTask,
  findVisibleInteractiveActionTask,
  interactiveActionCheckpointKey,
  isInteractiveActionTask,
} from "../src/humanAction.ts";
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

test("does not present a child worker or checker checkpoint as a directly resumable root action", () => {
  const worker = { ...task("worker", "ask-worker"), role: "worker" as const, parentTaskId: "root" };
  const checker = { ...task("checker", "ask-checker"), role: "checker" as const, parentTaskId: "root" };
  assert.equal(isInteractiveActionTask(worker), false);
  assert.equal(isInteractiveActionTask(checker), false);
  assert.equal(findInteractiveActionTask([worker, checker]), undefined);
});

test("dismisses one exact checkpoint but shows a later checkpoint on the same task", () => {
  const first = task("interactive", "ask-user-call-1");
  const firstKey = interactiveActionCheckpointKey(first);
  assert.equal(firstKey, "interactive:ask-user-call-1");
  assert.equal(findVisibleInteractiveActionTask([first], firstKey, undefined), undefined);

  const second = { ...first, pendingToolCallId: "ask-user-call-2" };
  assert.equal(findVisibleInteractiveActionTask([second], firstKey, undefined)?.id, "interactive");
});

test("does not show a checkpoint while another root owns the runtime", () => {
  const waiting = task("waiting", "ask-user-call-1");
  assert.equal(findVisibleInteractiveActionTask([waiting], undefined, "running-root"), undefined);
  assert.equal(findVisibleInteractiveActionTask([waiting], undefined, undefined)?.id, "waiting");
});
