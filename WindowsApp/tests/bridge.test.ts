import assert from "node:assert/strict";
import test from "node:test";
import type { ExternalSkillRecord, MemoryListPage, MemoryMutationResult, RuntimeSnapshot } from "../src/types.ts";
import { MEMORY_CONTENT_MAX_CHARS, MEMORY_TAXONOMY_MAX_ITEMS, MEMORY_TITLE_MAX_CHARS } from "../src/memoryManagement.ts";

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

test("browser mock redacts sensitive memory until one exact item is explicitly revealed", async () => {
  Object.defineProperty(globalThis, "window", { value: {}, configurable: true });
  const { getMemory, listMemory } = await import("../src/bridge.ts");

  const page = await listMemory({ sensitive: true, sensitiveVisibility: "redacted", limit: 10 });
  const redacted = page.items[0];
  assert.ok(redacted);
  assert.equal(redacted.redacted, true);
  assert.equal(redacted.content, "");
  assert.equal(redacted.lastPrompt, "");
  assert.deepEqual(redacted.tags, []);
  assert.equal(JSON.stringify(redacted).includes("Finance sandbox credential"), false);

  const secretSearch = await listMemory({ query: "credential", sensitiveVisibility: "redacted" });
  assert.equal(secretSearch.items.some((item) => item.id === redacted.id), false);

  const full = await getMemory({ id: redacted.id, sensitiveVisibility: "full" });
  assert.equal(full.redacted, false);
  assert.equal(full.sensitive, true);
  assert.match(full.content, /Credential Manager/);
});

test("browser mock mirrors the memory create, edit, and delete lifecycle with CAS", async () => {
  Object.defineProperty(globalThis, "window", { value: {}, configurable: true });
  const { deleteMemory, listMemory, upsertMemory } = await import("../src/bridge.ts");
  const before = await listMemory({ limit: 100 });
  await assert.rejects(() => upsertMemory({
    kind: "fact", tier: "hot", title: "T".repeat(MEMORY_TITLE_MAX_CHARS + 1), content: "Valid content",
    tags: [], importance: 0.5, confidence: 0.8, sensitive: false, aliases: [],
  }), /title exceeds/);
  await assert.rejects(() => upsertMemory({
    kind: "fact", tier: "hot", title: "Valid title", content: "C".repeat(MEMORY_CONTENT_MAX_CHARS + 1),
    tags: [], importance: 0.5, confidence: 0.8, sensitive: false, aliases: [],
  }), /content exceeds/);
  await assert.rejects(() => upsertMemory({
    kind: "fact", tier: "hot", title: "Too many tags", content: "The request must fail rather than silently dropping metadata.",
    tags: Array.from({ length: MEMORY_TAXONOMY_MAX_ITEMS + 1 }, (_, index) => `tag-${index}`),
    importance: 0.5, confidence: 0.8, sensitive: false, aliases: [],
  }), /tags exceed/);
  await assert.rejects(() => upsertMemory({
    kind: "fact", tier: "hot", title: "Too many aliases", content: "The request must fail rather than silently dropping metadata.",
    tags: [], importance: 0.5, confidence: 0.8, sensitive: false,
    aliases: Array.from({ length: MEMORY_TAXONOMY_MAX_ITEMS + 1 }, (_, index) => `alias-${index}`),
  }), /aliases exceed/);
  await assert.rejects(() => upsertMemory({
    kind: "task", tier: "hot", title: "Invalid new kind", content: "New manual memories cannot impersonate task memories.",
    tags: [], importance: 0.5, confidence: 0.8, sensitive: false, aliases: [],
  }), /user-managed memory kind/);
  const automaticTask = (await listMemory({ id: "memory-release-task", sensitiveVisibility: "full" })).items[0];
  assert.ok(automaticTask);
  await assert.rejects(() => upsertMemory({
    id: automaticTask.id, expectedFingerprint: automaticTask.fingerprint, expectedUpdatedAt: automaticTask.updatedAt,
    kind: "artifact", tier: automaticTask.tier, title: automaticTask.title, content: automaticTask.content,
    tags: automaticTask.tags, importance: automaticTask.importance, confidence: automaticTask.confidence,
    sensitive: automaticTask.sensitive, aliases: automaticTask.aliases,
  }), /user-managed memory kind/);
  const autoSensitive = await upsertMemory({
    kind: "fact", tier: "hot", title: "password: mock-private", content: "Server access note.",
    tags: [], importance: 0.5, confidence: 0.8, sensitive: false, aliases: [],
  });
  assert.equal(autoSensitive.entry.sensitive, true);
  const concealed = (await listMemory({ id: autoSensitive.entry.id })).items[0];
  assert.equal(concealed?.redacted, true);
  await deleteMemory({
    id: autoSensitive.entry.id,
    expectedFingerprint: autoSensitive.entry.fingerprint,
    expectedUpdatedAt: autoSensitive.entry.updatedAt,
  });
  await assert.rejects(() => upsertMemory({
    id: "missing-memory",
    expectedUpdatedAt: "2026-08-20T00:00:00Z",
    kind: "fact", tier: "hot", title: "Missing", content: "Must not become a create.",
    tags: [], importance: 0.5, confidence: 0.8, sensitive: false, aliases: [],
  }), /memory not found/);
  const created = await upsertMemory({
    kind: "preference", tier: "hot", title: "Review preference", content: "Use a concise review summary.",
    tags: ["review"], importance: 0.7, confidence: 0.9, sensitive: false, aliases: [],
  });

  assert.equal(created.entry.redacted, false);
  assert.equal(created.snapshot.totalCount, before.totalCount + 1);
  const updated: MemoryMutationResult = await upsertMemory({
    id: created.entry.id,
    expectedFingerprint: created.entry.fingerprint,
    expectedUpdatedAt: created.entry.updatedAt,
    kind: created.entry.kind,
    tier: "cold",
    title: created.entry.title,
    content: "Use a concise review summary with direct evidence.",
    tags: created.entry.tags,
    importance: created.entry.importance,
    confidence: created.entry.confidence,
    sensitive: false,
    aliases: created.entry.aliases,
  });
  assert.equal(updated.entry.tier, "cold");
  assert.match(updated.entry.content, /direct evidence/);

  await assert.rejects(() => upsertMemory({
    id: updated.entry.id,
    expectedFingerprint: "stale-fingerprint",
    expectedUpdatedAt: updated.entry.updatedAt,
    kind: updated.entry.kind,
    tier: updated.entry.tier,
    title: updated.entry.title,
    content: updated.entry.content,
    tags: updated.entry.tags,
    importance: updated.entry.importance,
    confidence: updated.entry.confidence,
    sensitive: updated.entry.sensitive,
    aliases: updated.entry.aliases,
  }), /changed since it was opened/);

  const deleted = await deleteMemory({
    id: updated.entry.id,
    expectedFingerprint: updated.entry.fingerprint,
    expectedUpdatedAt: updated.entry.updatedAt,
  });
  assert.equal(deleted.deletedId, updated.entry.id);
  assert.equal(deleted.snapshot.totalCount, before.totalCount);
  const remaining: MemoryListPage = await listMemory({ id: updated.entry.id });
  assert.equal(remaining.totalCount, 0);
});

test("browser mock rejects a later page after the memory list revision changes", async () => {
  Object.defineProperty(globalThis, "window", { value: {}, configurable: true });
  const { deleteMemory, listMemory, upsertMemory } = await import("../src/bridge.ts");
  const first = await listMemory({ limit: 2 });
  const second = await listMemory({ offset: 2, limit: 2, expectedStateFingerprint: first.stateFingerprint });
  assert.equal(second.offset, 2);

  const created = await upsertMemory({
    kind: "knowledge", tier: "hot", title: "Pagination mutation", content: "Changes the mock list revision.",
    tags: [], importance: 0.5, confidence: 0.8, sensitive: false, aliases: [],
  });
  await assert.rejects(
    () => listMemory({ offset: 2, limit: 2, expectedStateFingerprint: first.stateFingerprint }),
    /list changed while paging/,
  );
  await deleteMemory({
    id: created.entry.id,
    expectedFingerprint: created.entry.fingerprint,
    expectedUpdatedAt: created.entry.updatedAt,
  });
});
