import assert from "node:assert/strict";
import test from "node:test";
import type { ExternalSkillRecord, RuntimeSnapshot } from "../src/types.ts";

test("browser mock returns the same enqueue boundary as the native submit command", async () => {
  Object.defineProperty(globalThis, "window", { value: {}, configurable: true });
  const { runtimeInvoke } = await import("../src/bridge.ts");
  const payload = await runtimeInvoke<{
    receipt: { threadId: string; queued: boolean };
    snapshot: RuntimeSnapshot;
  }>("submit_message", { prompt: "Queue contract" });

  const enqueued = payload.snapshot.tasks.find((task) => task.id === payload.receipt.threadId);
  assert.equal(payload.receipt.queued, false);
  assert.equal(enqueued?.status, "queued");
  assert.equal(payload.snapshot.activeTaskId, undefined);
  assert.equal(payload.snapshot.queuedTaskCount, 1);
  assert.equal(payload.snapshot.events.some((event) => event.taskId === enqueued?.id), false);
  assert.equal(payload.snapshot.messages.filter((message) => message.threadId === enqueued?.id).length, 2);

  await new Promise((resolve) => setTimeout(resolve, 0));
  const claimed = await runtimeInvoke<RuntimeSnapshot>("get_snapshot");
  assert.equal(claimed.activeTaskId, enqueued?.id);
  assert.equal(claimed.queuedTaskCount, 0);
  assert.equal(claimed.tasks.find((task) => task.id === enqueued?.id)?.status, "understanding");
});

test("browser mock mirrors the external Skill registration lifecycle", async () => {
  Object.defineProperty(globalThis, "window", { value: {}, configurable: true });
  const { runtimeInvoke } = await import("../src/bridge.ts");
  const source = "C:\\Users\\Roy\\.claude\\skills\\presentation-review\\SKILL.md";
  const imported = await runtimeInvoke<ExternalSkillRecord[]>("import_external_skill", { path: source });

  assert.equal(imported.length, 1);
  assert.equal(imported[0]?.manifestPath, source);
  assert.equal(imported[0]?.enabled, true);
  assert.equal(imported[0]?.modelInvocationEnabled, true);

  const disabled = await runtimeInvoke<ExternalSkillRecord>("set_external_skill_enabled", { id: imported[0]?.id, enabled: false });
  assert.equal(disabled.enabled, false);
  const refreshed = await runtimeInvoke<ExternalSkillRecord[]>("refresh_external_skills");
  assert.equal(refreshed.find((skill) => skill.id === imported[0]?.id)?.enabled, false);

  await runtimeInvoke("remove_external_skill", { id: imported[0]?.id });
  const remaining = await runtimeInvoke<ExternalSkillRecord[]>("list_external_skills");
  assert.equal(remaining.some((skill) => skill.id === imported[0]?.id), false);
});
