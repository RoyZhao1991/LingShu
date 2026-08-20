import type { MemoryEntry, MemoryKind, MemorySource, MemoryTier, MemoryUpsertRequest } from "./types";

export const MEMORY_TITLE_MAX_CHARS = 96;
export const MEMORY_CONTENT_MAX_CHARS = 720;
export const MEMORY_TAXONOMY_MAX_ITEMS = 24;
export const MANUAL_MEMORY_KINDS: readonly MemoryKind[] = ["fact", "preference", "experience", "knowledge"];

export type MemoryFilterValue<T extends string> = "all" | T;

export interface MemoryFilters {
  query: string;
  kind: MemoryFilterValue<MemoryKind>;
  tier: MemoryFilterValue<MemoryTier>;
  source: MemoryFilterValue<MemorySource>;
}

export interface MemoryEditorDraft {
  kind: MemoryKind;
  tier: MemoryTier;
  title: string;
  content: string;
  tagsText: string;
  aliasesText: string;
  importance: number;
  confidence: number;
  sensitive: boolean;
}

export const emptyMemoryFilters: MemoryFilters = {
  query: "",
  kind: "all",
  tier: "all",
  source: "all",
};

export function filterMemoryEntries(entries: readonly MemoryEntry[], filters: MemoryFilters): MemoryEntry[] {
  const query = normalize(filters.query);
  return entries
    .filter((entry) => filters.kind === "all" || entry.kind === filters.kind)
    .filter((entry) => filters.tier === "all" || entry.tier === filters.tier)
    .filter((entry) => filters.source === "all" || entry.source === filters.source)
    .filter((entry) => {
      if (!query) return true;
      // Sensitive content is deliberately excluded from local search. Otherwise a query could
      // disclose whether a secret appears in a memory even while its detail is still concealed.
      const searchable = entry.sensitive
        ? [entry.title, entry.tags.join(" "), entry.aliases.join(" ")]
        : [entry.title, entry.content, entry.lastPrompt, entry.tags.join(" "), entry.aliases.join(" ")];
      return normalize(searchable.join(" ")).includes(query);
    })
    .sort((left, right) => right.updatedAt.localeCompare(left.updatedAt));
}

export function memoryListPreview(entry: MemoryEntry, hiddenLabel: string, emptyLabel: string, limit = 128): string {
  if (entry.sensitive) return hiddenLabel;
  const compact = entry.content.replace(/\s+/g, " ").trim();
  if (!compact) return emptyLabel;
  return compact.length > limit ? `${compact.slice(0, Math.max(1, limit - 1)).trimEnd()}…` : compact;
}

export function newMemoryDraft(): MemoryEditorDraft {
  return {
    kind: "fact",
    tier: "hot",
    title: "",
    content: "",
    tagsText: "",
    aliasesText: "",
    importance: 0.5,
    confidence: 0.8,
    sensitive: false,
  };
}

export function memoryDraftFromEntry(entry: MemoryEntry): MemoryEditorDraft {
  return {
    kind: entry.kind,
    tier: entry.tier,
    title: entry.title,
    content: entry.content,
    tagsText: entry.tags.join(", "),
    aliasesText: entry.aliases.join(", "),
    importance: entry.importance,
    confidence: entry.confidence,
    sensitive: entry.sensitive,
  };
}

export function memoryUpsertRequest(draft: MemoryEditorDraft, original?: MemoryEntry): MemoryUpsertRequest {
  return {
    ...(original ? { id: original.id, expectedUpdatedAt: original.updatedAt } : {}),
    ...(original?.fingerprint ? { expectedFingerprint: original.fingerprint } : {}),
    kind: draft.kind,
    tier: draft.tier,
    title: draft.title.trim(),
    content: draft.content.trim(),
    tags: deduplicateTags(draft.tagsText),
    importance: clamp01(draft.importance),
    confidence: clamp01(draft.confidence),
    sensitive: draft.sensitive,
    aliases: deduplicateTags(draft.aliasesText),
  };
}

export function memoryDraftIsValid(draft: MemoryEditorDraft): boolean {
  const title = draft.title.trim();
  const content = draft.content.trim();
  return Boolean(title && content
    && memoryTextLength(title) <= MEMORY_TITLE_MAX_CHARS
    && memoryTextLength(content) <= MEMORY_CONTENT_MAX_CHARS
    && memoryTaxonomyCount(draft.tagsText) <= MEMORY_TAXONOMY_MAX_ITEMS
    && memoryTaxonomyCount(draft.aliasesText) <= MEMORY_TAXONOMY_MAX_ITEMS);
}

export function memoryTextLength(value: string): number {
  return Array.from(value).length;
}

export function truncateMemoryText(value: string, maxChars: number): string {
  return Array.from(value).slice(0, Math.max(0, maxChars)).join("");
}

export function memoryTaxonomyCount(value: string): number {
  return deduplicateTags(value).length;
}

export function memoryEditableKinds(originalKind?: MemoryKind): readonly MemoryKind[] {
  return originalKind && !MANUAL_MEMORY_KINDS.includes(originalKind)
    ? [originalKind, ...MANUAL_MEMORY_KINDS]
    : MANUAL_MEMORY_KINDS;
}

function deduplicateTags(value: string): string[] {
  const seen = new Set<string>();
  const result: string[] = [];
  for (const raw of value.split(/[,，\n]/)) {
    const tag = raw.trim().replace(/^#+/, "");
    const key = normalize(tag);
    if (!tag || seen.has(key)) continue;
    seen.add(key);
    result.push(tag);
  }
  return result;
}

function clamp01(value: number): number {
  return Number.isFinite(value) ? Math.min(1, Math.max(0, value)) : 0;
}

function normalize(value: string): string {
  return value.trim().toLocaleLowerCase();
}
