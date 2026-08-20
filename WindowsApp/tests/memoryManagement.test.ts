import assert from "node:assert/strict";
import test from "node:test";
import {
  filterMemoryEntries, MEMORY_CONTENT_MAX_CHARS, MEMORY_TAXONOMY_MAX_ITEMS, MEMORY_TITLE_MAX_CHARS,
  memoryDraftFromEntry, memoryDraftIsValid, memoryEditableKinds, memoryListPreview, memoryTaxonomyCount,
  memoryTextLength, memoryUpsertRequest, newMemoryDraft, truncateMemoryText,
} from "../src/memoryManagement.ts";
import type { MemoryEntry } from "../src/types.ts";

const entry = (overrides: Partial<MemoryEntry> = {}): MemoryEntry => ({
  id: "memory-1",
  kind: "fact",
  tier: "hot",
  title: "Project Aurora owner",
  content: "Aurora is owned by Mira Chen",
  lastPrompt: "Remember the Aurora owner",
  tags: ["aurora", "team"],
  source: "user_explicit",
  importance: 0.8,
  confidence: 1,
  sensitive: false,
  messageCount: 1,
  createdAt: "2026-08-18T08:00:00Z",
  updatedAt: "2026-08-19T08:00:00Z",
  aliases: [],
  accessCount: 2,
  fingerprint: "fingerprint",
  ...overrides,
});

test("filters memory by kind, tier, source, query and newest-first order", () => {
  const visible = filterMemoryEntries([
    entry({ id: "old", updatedAt: "2026-08-18T08:00:00Z" }),
    entry({ id: "cold", tier: "cold", updatedAt: "2026-08-20T08:00:00Z" }),
    entry({ id: "task", kind: "task", source: "task", content: "Aurora delivery", updatedAt: "2026-08-21T08:00:00Z" }),
  ], { query: "owner", kind: "fact", tier: "hot", source: "user_explicit" });

  assert.deepEqual(visible.map((item) => item.id), ["old"]);
});

test("does not search concealed sensitive content or prompt text", () => {
  const secret = entry({
    id: "secret",
    title: "Account note",
    content: "password is swordfish",
    lastPrompt: "remember swordfish",
    sensitive: true,
  });

  assert.deepEqual(filterMemoryEntries([secret], { query: "swordfish", kind: "all", tier: "all", source: "all" }), []);
  assert.deepEqual(filterMemoryEntries([secret], { query: "account", kind: "all", tier: "all", source: "all" }).map((item) => item.id), ["secret"]);
});

test("never returns sensitive content for a list preview", () => {
  const secret = entry({ content: "API token sk-live-private", sensitive: true });
  assert.equal(memoryListPreview(secret, "Sensitive content hidden", "No content"), "Sensitive content hidden");
});

test("builds a normalized manual write without mutating the entry draft", () => {
  const draft = memoryDraftFromEntry(entry({ tags: ["Aurora", "team"] }));
  draft.tagsText = " #Aurora, team，TEAM\n delivery ";
  draft.importance = 1.4;
  draft.confidence = -0.2;

  assert.deepEqual(memoryUpsertRequest(draft, entry()), {
    id: "memory-1",
    expectedFingerprint: "fingerprint",
    expectedUpdatedAt: "2026-08-19T08:00:00Z",
    kind: "fact",
    tier: "hot",
    title: "Project Aurora owner",
    content: "Aurora is owned by Mira Chen",
    tags: ["Aurora", "team", "delivery"],
    importance: 1,
    confidence: 0,
    sensitive: false,
    aliases: [],
  });
  assert.deepEqual(entry().tags, ["aurora", "team"]);
});

test("new memory defaults to an explicit fact-oriented safe draft", () => {
  assert.deepEqual(newMemoryDraft(), {
    kind: "fact",
    tier: "hot",
    title: "",
    content: "",
    tagsText: "",
    aliasesText: "",
    importance: 0.5,
    confidence: 0.8,
    sensitive: false,
  });
});

test("uses updatedAt alone when a redacted entry does not expose its fingerprint", () => {
  const redacted = entry({ sensitive: true, fingerprint: "" });
  const request = memoryUpsertRequest(memoryDraftFromEntry(redacted), redacted);

  assert.equal("expectedFingerprint" in request, false);
  assert.equal(request.expectedUpdatedAt, redacted.updatedAt);
});

test("uses the same explicit title and content limits as the shared core", () => {
  const draft = newMemoryDraft();
  draft.title = "题".repeat(MEMORY_TITLE_MAX_CHARS);
  draft.content = "文".repeat(MEMORY_CONTENT_MAX_CHARS);
  assert.equal(memoryTextLength(draft.title), MEMORY_TITLE_MAX_CHARS);
  assert.equal(memoryDraftIsValid(draft), true);

  draft.title += "题";
  assert.equal(memoryDraftIsValid(draft), false);
  draft.title = "valid";
  draft.content += "文";
  assert.equal(memoryDraftIsValid(draft), false);
});

test("counts Unicode characters consistently and caps text without splitting emoji", () => {
  const overLimit = "😀".repeat(MEMORY_TITLE_MAX_CHARS + 1);
  const truncated = truncateMemoryText(overLimit, MEMORY_TITLE_MAX_CHARS);

  assert.equal(memoryTextLength(truncated), MEMORY_TITLE_MAX_CHARS);
  assert.equal(truncated, "😀".repeat(MEMORY_TITLE_MAX_CHARS));
});

test("rejects more than 24 unique tags or aliases without penalizing duplicates", () => {
  const draft = newMemoryDraft();
  draft.title = "Taxonomy limits";
  draft.content = "Keep managed metadata bounded without silent truncation.";
  draft.tagsText = Array.from({ length: MEMORY_TAXONOMY_MAX_ITEMS }, (_, index) => `tag-${index}`).join(",");
  draft.aliasesText = "Alias, alias, ALIAS";

  assert.equal(memoryTaxonomyCount(draft.tagsText), MEMORY_TAXONOMY_MAX_ITEMS);
  assert.equal(memoryTaxonomyCount(draft.aliasesText), 1);
  assert.equal(memoryDraftIsValid(draft), true);

  draft.tagsText += ",one-too-many";
  assert.equal(memoryDraftIsValid(draft), false);
});

test("offers only the original automatic kind plus user-managed conversion kinds", () => {
  assert.deepEqual(memoryEditableKinds(), ["fact", "preference", "experience", "knowledge"]);
  assert.deepEqual(memoryEditableKinds("task"), ["task", "fact", "preference", "experience", "knowledge"]);
  assert.deepEqual(memoryEditableKinds("fact"), ["fact", "preference", "experience", "knowledge"]);
});
