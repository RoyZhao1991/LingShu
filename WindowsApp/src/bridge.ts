import { invoke as tauriInvoke } from "@tauri-apps/api/core";
import { open as tauriOpen } from "@tauri-apps/plugin-dialog";
import type {
  ExternalSkillRecord, MemoryDeleteRequest, MemoryDeleteResult, MemoryEntry, MemoryGetRequest, MemoryListItem, MemoryListPage, MemoryListRequest,
  MemoryMutationResult, MemorySnapshot, MemoryUpsertRequest, PluginRecord, PreviewPayload, ProviderPreset, RuntimeEvent,
  RuntimeSettings, RuntimeSnapshot, TaskRecord,
} from "./types";
import {
  MANUAL_MEMORY_KINDS, MEMORY_CONTENT_MAX_CHARS, MEMORY_TAXONOMY_MAX_ITEMS, MEMORY_TITLE_MAX_CHARS,
  memoryTextLength,
} from "./memoryManagement.ts";

export interface BootstrapPayload {
  snapshot: RuntimeSnapshot;
  providers: ProviderPreset[];
}

export interface SubmitReceipt {
  threadId: string;
  userMessageId: string;
  assistantMessageId: string;
  queued: boolean;
}

export interface SubmitMessagePayload {
  receipt: SubmitReceipt;
  snapshot: RuntimeSnapshot;
}

export type WindowFileDropEvent =
  | { type: "enter"; paths: string[] }
  | { type: "over" }
  | { type: "drop"; paths: string[] }
  | { type: "leave" };

export function hasNativeBridge(): boolean {
  return Reflect.has(window, "__TAURI_INTERNALS__");
}

export async function runtimeInvoke<T>(command: string, args?: Record<string, unknown>): Promise<T> {
  if (hasNativeBridge()) return tauriInvoke<T>(command, args);
  return mockInvoke<T>(command, args);
}

export async function listMemory(request: MemoryListRequest = {}): Promise<MemoryListPage> {
  return runtimeInvoke<MemoryListPage>("memory_list", { request });
}

export async function getMemory(request: MemoryGetRequest): Promise<MemoryListItem> {
  return runtimeInvoke<MemoryListItem>("memory_get", { request });
}

export async function upsertMemory(request: MemoryUpsertRequest): Promise<MemoryMutationResult> {
  return runtimeInvoke<MemoryMutationResult>("memory_upsert", { request });
}

export async function deleteMemory(request: MemoryDeleteRequest): Promise<MemoryDeleteResult> {
  return runtimeInvoke<MemoryDeleteResult>("memory_delete", { request });
}

export async function chooseFiles(): Promise<string[]> {
  if (!hasNativeBridge()) return ["C:\\Users\\Roy\\Documents\\project-brief.md"];
  const selected = await tauriOpen({ multiple: true, directory: false });
  if (!selected) return [];
  return Array.isArray(selected) ? selected : [selected];
}

export async function listenForWindowFileDrops(
  handler: (event: WindowFileDropEvent) => void,
): Promise<() => void> {
  if (!hasNativeBridge()) return () => undefined;
  const { getCurrentWindow } = await import("@tauri-apps/api/window");
  return getCurrentWindow().onDragDropEvent(({ payload }) => {
    if (payload.type === "enter" || payload.type === "drop") {
      handler({ type: payload.type, paths: payload.paths });
      return;
    }
    handler({ type: payload.type });
  });
}

export async function choosePluginManifest(): Promise<string | undefined> {
  if (!hasNativeBridge()) return "C:\\Users\\Roy\\Downloads\\demo-plugin\\plugin.json";
  const selected = await tauriOpen({
    multiple: false,
    directory: false,
    filters: [{ name: "LingShu plugin manifest", extensions: ["json"] }],
  });
  return typeof selected === "string" ? selected : undefined;
}

export async function chooseExternalSkillManifest(): Promise<string | undefined> {
  if (!hasNativeBridge()) return "C:\\Users\\Roy\\.codex\\skills\\presentation-review\\SKILL.md";
  const selected = await tauriOpen({
    multiple: false,
    directory: false,
    filters: [{ name: "Agent Skill manifest", extensions: ["md"] }],
  });
  return typeof selected === "string" ? selected : undefined;
}

export async function chooseExternalSkillDirectory(): Promise<string | undefined> {
  if (!hasNativeBridge()) return "C:\\Users\\Roy\\.codex\\skills";
  const selected = await tauriOpen({ multiple: false, directory: true });
  return typeof selected === "string" ? selected : undefined;
}

const providers: ProviderPreset[] = [
  { id: "deepseek", name: "DeepSeek", region: "CN", endpoint: "https://api.deepseek.com", protocol: "openai_chat_completions", defaultModels: ["deepseek-chat", "deepseek-reasoner"], requiresApiKey: true },
  { id: "minimax-official", name: "MiniMax", region: "CN", endpoint: "https://api.minimaxi.com/v1", protocol: "openai_chat_completions", defaultModels: ["MiniMax-M3"], requiresApiKey: true },
  { id: "openai", name: "OpenAI", region: "Global", endpoint: "https://api.openai.com/v1", protocol: "openai_responses", defaultModels: ["gpt-5.5", "gpt-5"], requiresApiKey: true },
  { id: "anthropic", name: "Anthropic Claude", region: "Global", endpoint: "https://api.anthropic.com/v1", protocol: "anthropic_messages", defaultModels: ["claude-opus-4-8", "claude-sonnet-4-6"], requiresApiKey: true },
  { id: "custom-compatible", name: "Custom OpenAI-compatible", region: "Custom", endpoint: "https://your-gateway.example.com/v1", protocol: "openai_chat_completions", defaultModels: ["custom-model"], requiresApiKey: true },
];

const now = new Date().toISOString();
const demoArtifactPath = "C:\\Users\\Roy\\Documents\\LingShu Workspace\\Project-Aurora-Brief.md";
const demoAttachmentPath = "C:\\Users\\Roy\\Documents\\Project-Aurora-Resume.pdf";
const demoTask: TaskRecord = {
  id: "demo-thread",
  title: "Create and verify a Project Aurora brief",
  prompt: "Create a concise project brief and register the file.",
  status: "completed",
  createdAt: now,
  updatedAt: now,
  goalSpec: {
    objective: "Create and verify a concise Project Aurora brief",
    kind: "task",
    output_mode: "artifact",
    reference_scope: "current_input",
    reference_evidence: ["Current user request"],
    reference_explicit: true,
    reference_confidence: "high",
    constraints: ["Use fictional data"], boundaries: ["Do not operate the Windows desktop"], risks: [],
    success_criteria: ["A readable Markdown file is registered", "The file opens in LingShu preview"], open_questions: [],
  },
  steps: [
    { id: "demo-step-1", title: "Understand the request", detail: "GoalSpec accepted by LingShu Runtime Core", status: "completed", updatedAt: now },
    { id: "demo-step-2", title: "Produce the response and artifacts", detail: "Response and artifact registry completed", status: "completed", updatedAt: now },
  ],
  artifacts: [{ id: "demo-artifact", title: "Project Aurora brief", path: demoArtifactPath, kind: "markdown", sizeBytes: 1840, modifiedAt: now }],
  summary: "The Project Aurora brief is ready and registered.", error: undefined, attachmentPaths: [demoAttachmentPath],
  rootTaskId: "demo-thread", role: "main", origin: "conversation", participantName: "LingShu", depth: 0,
  loopEngine: "grok",
};

const demoEvents: RuntimeEvent[] = [
  { id: "demo-event-1", sequence: 1, taskId: demoTask.id, kind: "plan", state: "completed", actor: "GoalSpec", title: "Goal accepted", detail: "Create and verify a concise Project Aurora brief", createdAt: now, updatedAt: now },
  { id: "demo-event-2", sequence: 2, taskId: demoTask.id, kind: "reasoning", state: "completed", actor: "deepseek-chat", title: "Reasoning summary", detail: "I will create the requested file, inspect the real output, and then report the registered path.", createdAt: now, updatedAt: now },
  { id: "demo-event-3", sequence: 3, taskId: demoTask.id, kind: "tool", state: "completed", actor: "LingShu", title: "Create artifact", detail: "Project-Aurora-Brief.md was created and registered.", createdAt: now, updatedAt: now },
];

const demoPlugins: PluginRecord[] = [
  {
    id: "lingshu.design-kb",
    name: "DesignKB",
    version: "1.1.0",
    description: "Built-in presentation layouts, palettes, typography, icons, generator, and review rubric.",
    descriptionZh: "内置演示文稿版式、配色、字体、图标、生成器与验收规范。",
    source: "built_in",
    enabled: true,
    available: true,
    runtimeReady: true,
    rootPath: "C:\\Program Files\\Nous\\resources\\DesignKB",
    permissions: { fileRead: true, fileWrite: true, network: false, shell: false, systemSensitive: false },
    tools: [{
      name: "create_designed_presentation",
      exposedName: "create_designed_presentation",
      description: "Create and register a polished PowerPoint with DesignKB.",
      descriptionZh: "使用 DesignKB 生成并登记高质量 PowerPoint。",
      parameters: { type: "object" },
    }],
    statusDetail: "Knowledge and generator ready",
  },
];

const demoExternalSkill: ExternalSkillRecord = {
  id: "codex.presentation-review",
  name: "Presentation Review",
  description: "Review presentation structure, visual consistency, and delivery readiness.",
  sourceFormat: "codex",
  sourcePath: "C:\\Users\\Roy\\.codex\\skills\\presentation-review",
  manifestPath: "C:\\Users\\Roy\\.codex\\skills\\presentation-review\\SKILL.md",
  enabled: true,
  available: true,
  modelInvocationEnabled: true,
  statusDetail: "SKILL.md is readable and registered",
  warnings: [],
  scripts: [{ path: "scripts\\review.mjs", kind: "script", sizeBytes: 2814 }],
  references: [{ path: "references\\rubric.md", kind: "reference", sizeBytes: 4920 }],
  assets: [],
  license: "MIT",
  compatibility: "Codex Skill",
  allowedTools: ["read_file", "run_command"],
  contentFingerprint: "development-preview",
};

let demoMemories: MemoryEntry[] = [
  {
    id: "memory-project-aurora", kind: "fact", tier: "hot", title: "Project Aurora owner",
    content: "Project Aurora is owned by Mira Chen. Release decisions should include her review.", lastPrompt: "Remember who owns Project Aurora.",
    tags: ["aurora", "owner"], source: "user_explicit", importance: 0.88, confidence: 1, sensitive: false, messageCount: 1,
    createdAt: "2026-08-18T02:12:00.000Z", updatedAt: "2026-08-20T03:42:00.000Z", aliases: ["Aurora owner"], accessCount: 4,
    lastAccessedAt: "2026-08-20T04:02:00.000Z", fingerprint: "mock-aurora-v1",
  },
  {
    id: "memory-writing-preference", kind: "preference", tier: "hot", title: "Delivery writing preference",
    content: "Lead with the concrete result, keep the explanation concise, and include a direct download path for packaged builds.", lastPrompt: "Remember how I want release handoffs written.",
    tags: ["writing", "delivery"], source: "user_explicit", importance: 0.92, confidence: 1, sensitive: false, messageCount: 2,
    createdAt: "2026-08-17T08:30:00.000Z", updatedAt: "2026-08-19T09:18:00.000Z", aliases: [], accessCount: 8,
    lastAccessedAt: "2026-08-20T02:45:00.000Z", fingerprint: "mock-writing-v2",
  },
  {
    id: "memory-sensitive-api", kind: "fact", tier: "hot", title: "Finance sandbox access",
    content: "The Finance sandbox credential is stored in Windows Credential Manager under the team account.", lastPrompt: "Remember where the Finance sandbox credential is stored.",
    tags: ["finance", "credential"], source: "user_explicit", importance: 0.96, confidence: 1, sensitive: true, messageCount: 1,
    createdAt: "2026-08-19T07:15:00.000Z", updatedAt: "2026-08-19T07:15:00.000Z", aliases: [], accessCount: 0,
    fingerprint: "mock-sensitive-v1",
  },
  {
    id: "memory-release-task", kind: "task", tier: "hot", title: "Windows preview release workflow",
    content: "Run frontend, Rust, shared core, and installer checks before publishing the signed checksum manifest.", lastPrompt: "Build a new Windows technical preview.",
    tags: ["windows", "release"], source: "task", importance: 0.82, confidence: 0.9, sensitive: false, messageCount: 6,
    taskId: "demo-thread", executionRecordId: "demo-thread", createdAt: "2026-08-15T05:00:00.000Z", updatedAt: "2026-08-18T12:20:00.000Z",
    aliases: ["Windows release"], accessCount: 3, lastAccessedAt: "2026-08-19T02:10:00.000Z", fingerprint: "mock-task-v3",
  },
  {
    id: "memory-design-knowledge", kind: "knowledge", tier: "cold", title: "Bright presentation palette rule",
    content: "For a bright presentation, prefer ivory surfaces with cobalt and amber accents over a deep royal-blue background.", lastPrompt: "Use a brighter presentation theme.",
    tags: ["presentation", "design"], source: "platform", importance: 0.65, confidence: 0.78, sensitive: false, messageCount: 1,
    createdAt: "2026-07-12T06:00:00.000Z", updatedAt: "2026-07-20T06:00:00.000Z", archivedAt: "2026-08-10T06:00:00.000Z",
    aliases: ["bright slides"], accessCount: 1, fingerprint: "mock-knowledge-v1",
  },
];

function demoMemorySnapshot(): MemorySnapshot {
  const countsByKind: Record<string, number> = {};
  for (const entry of demoMemories) countsByKind[entry.kind] = (countsByKind[entry.kind] ?? 0) + 1;
  return {
    schemaVersion: 1,
    totalCount: demoMemories.length,
    hotCount: demoMemories.filter((entry) => entry.tier === "hot").length,
    coldCount: demoMemories.filter((entry) => entry.tier === "cold").length,
    countsByKind,
    latestUpdatedAt: demoMemories.map((entry) => entry.updatedAt).sort().at(-1),
    lastConsolidatedAt: "2026-08-20T01:30:00.000Z",
    importedSources: { macos_legacy: "1" },
  };
}

function demoMemoryStateFingerprint(): string {
  return demoMemories
    .map((entry) => entry.sensitive ? `${entry.id}:${entry.updatedAt}:${entry.kind}:${entry.tier}:${entry.source}` : `${entry.id}:${entry.fingerprint}`)
    .sort()
    .join("|");
}

function mockMemoryPayloadIsSensitive(values: readonly string[]): boolean {
  const combined = values.join("\n").toLocaleLowerCase();
  return ["api key", "apikey", "token", "password", "密码", "密钥", "secret", "sk-"].some((signal) => combined.includes(signal));
}

function mockNormalizedUniqueCount(values: readonly string[]): number {
  return new Set(values.map((value) => value.trim().toLocaleLowerCase()).filter(Boolean)).size;
}

let snapshot: RuntimeSnapshot = {
  kernelAbiVersion: "1.2.0",
  settings: {
    locale: "en", providerId: "deepseek", providerName: "DeepSeek", protocol: "openai_chat_completions",
    endpoint: "https://api.deepseek.com", model: "deepseek-chat",
    workspace: "C:\\Users\\Roy\\Documents\\LingShu Workspace",
    executionPermissionMode: "sandbox", loopEngine: "grok", firstRunComplete: true,
  },
  platform: "windows",
  capabilities: { computerControl: false, realtimePerception: false, internalPreview: true, externalOpen: true },
  messages: [
    { id: "demo-user", role: "user", text: "Review the attached resume and summarize the fit for Project Aurora.", createdAt: now, state: "complete", threadId: demoTask.id, attachmentPaths: [] },
    { id: "demo-assistant", role: "assistant", text: "The attached resume has been reviewed.\n\nDimension | Assessment || Delivery | Strong || Architecture | Good fit || Risk | Needs validation\n\nThe Project Aurora brief is ready and can be inspected in Nous's built-in preview.", createdAt: now, state: "complete", threadId: demoTask.id, attachmentPaths: [] },
  ],
  tasks: [demoTask], activeTaskId: undefined, queuedTaskCount: 0, providerConfigured: true,
  events: demoEvents, latestEventSequence: 3, plugins: demoPlugins, externalSkills: [demoExternalSkill],
  memory: demoMemorySnapshot(),
  loopEngines: [
    {
      id: "grok", name: "Grok Loop", description: "Built-in Loop harness", descriptionZh: "内置 Loop harness",
      adapterBuiltin: true, available: true, selected: true, executionMode: "in_process",
      statusDetail: "Built-in adapter and engine are ready", harnessOnly: true, transportOwner: "lingshu",
      nativeAuthDisabled: true, nativeQuotaDisabled: true,
    },
    {
      id: "codex", name: "Codex Loop", description: "LingShu-managed Loop harness", descriptionZh: "灵枢托管 Loop harness",
      adapterBuiltin: true, available: false, selected: false, executionMode: "external_cli",
      statusDetail: "Harness executable not found", harnessOnly: true, transportOwner: "lingshu",
      nativeAuthDisabled: true, nativeQuotaDisabled: true,
    },
  ],
};

async function mockInvoke<T>(command: string, args?: Record<string, unknown>): Promise<T> {
  switch (command) {
    case "bootstrap": return { snapshot: clone(snapshot), providers } as T;
    case "get_snapshot": return clone(snapshot) as T;
    case "save_and_validate_settings": {
      const settings = args?.settings as RuntimeSettings;
      snapshot = { ...snapshot, settings, providerConfigured: true };
      return clone(snapshot) as T;
    }
    case "update_execution_permission_mode": {
      const executionPermissionMode = args?.mode as RuntimeSettings["executionPermissionMode"];
      snapshot = { ...snapshot, settings: { ...snapshot.settings, executionPermissionMode } };
      return clone(snapshot) as T;
    }
    case "submit_message": {
      const prompt = String(args?.prompt ?? "").trim();
      const id = crypto.randomUUID();
      const createdAt = new Date().toISOString();
      const userMessageId = crypto.randomUUID();
      const assistantMessageId = crypto.randomUUID();
      const queued = Boolean(snapshot.activeTaskId) || snapshot.tasks.some((task) => task.status === "queued");
      const task: TaskRecord & { assistantMessageId: string } = {
        id, title: prompt, prompt, status: "queued", createdAt, updatedAt: createdAt,
        steps: [{ id: crypto.randomUUID(), title: "Understand the request", detail: "Waiting for the shared runtime kernel", status: "queued", updatedAt: createdAt }],
        artifacts: [], summary: "", userMessageId, assistantMessageId, attachmentPaths: (args?.attachmentPaths as string[]) ?? [],
        rootTaskId: id, role: "main", origin: "conversation", participantName: "LingShu", depth: 0,
        loopEngine: snapshot.settings.loopEngine,
      };
      const event: RuntimeEvent = { id: crypto.randomUUID(), sequence: snapshot.latestEventSequence + 1, taskId: id, kind: "model", state: "running", actor: snapshot.settings.model, title: "Understanding the goal", detail: "Compiling the current input into an executable goal.", createdAt, updatedAt: createdAt };
      snapshot = {
        ...snapshot,
        queuedTaskCount: snapshot.queuedTaskCount + 1,
        tasks: [...snapshot.tasks, task],
        messages: queued ? snapshot.messages : [...snapshot.messages,
          { id: userMessageId, role: "user", text: prompt, createdAt, state: "complete", threadId: id, attachmentPaths: task.attachmentPaths },
          { id: assistantMessageId, role: "assistant", text: "Understanding…", createdAt, state: "thinking", threadId: id, attachmentPaths: [] },
        ],
      };
      const enqueueSnapshot = clone(snapshot);
      if (!queued) {
        setTimeout(() => {
          const queuedTask = snapshot.tasks.find((item) => item.id === id);
          if (snapshot.activeTaskId || queuedTask?.status !== "queued") return;
          snapshot = {
            ...snapshot,
            activeTaskId: id,
            queuedTaskCount: Math.max(0, snapshot.queuedTaskCount - 1),
            tasks: snapshot.tasks.map((item) => item.id === id ? {
              ...item,
              status: "understanding",
              steps: item.steps.map((step, index) => index === 0 ? {
                ...step,
                status: "understanding",
                detail: "Generating a complete GoalSpec",
              } : step),
            } : item),
            events: [...snapshot.events, event],
            latestEventSequence: event.sequence,
          };
        }, 0);
      }
      return {
        receipt: { threadId: id, userMessageId, assistantMessageId, queued },
        snapshot: enqueueSnapshot,
      } satisfies SubmitMessagePayload as T;
    }
    case "cancel_task": {
      const id = String(args?.threadId ?? "");
      snapshot = { ...snapshot, activeTaskId: undefined, tasks: snapshot.tasks.map((task) => task.id === id ? { ...task, status: "cancelled" } : task) };
      return true as T;
    }
    case "resume_task": {
      const id = String(args?.threadId ?? "");
      const expectedToolCallId = String(args?.expectedToolCallId ?? "");
      const task = snapshot.tasks.find((item) => item.id === id);
      if (!task || task.status !== "needs_user_action" || task.pendingToolCallId !== expectedToolCallId || snapshot.activeTaskId) return null as T;
      snapshot = { ...snapshot, activeTaskId: id, tasks: snapshot.tasks.map((item) => item.id === id ? { ...item, status: "running", pendingQuestion: undefined, pendingToolCallId: undefined } : item) };
      return clone(snapshot) as T;
    }
    case "memory_list": {
      const request = (args?.request ?? {}) as MemoryListRequest;
      const query = request.query?.trim().toLocaleLowerCase() ?? "";
      const offset = Math.max(0, request.offset ?? 0);
      const limit = Math.min(100, request.limit && request.limit > 0 ? request.limit : 50);
      const full = request.sensitiveVisibility === "full";
      if (full && !request.id?.trim()) throw new Error("full sensitive visibility requires an exact memory id");
      const stateFingerprint = demoMemoryStateFingerprint();
      if (offset > 0 && !request.expectedStateFingerprint?.trim()) throw new Error("memory pagination after offset zero requires expectedStateFingerprint");
      if (offset > 0 && request.expectedStateFingerprint !== stateFingerprint) throw new Error("memory list changed while paging; refresh from the first page");
      const filtered = demoMemories
        .filter((entry) => !request.id || entry.id === request.id)
        .filter((entry) => !request.kind || entry.kind === request.kind)
        .filter((entry) => !request.tier || entry.tier === request.tier)
        .filter((entry) => !request.source || entry.source === request.source)
        .filter((entry) => request.sensitive === undefined || entry.sensitive === request.sensitive)
        .filter((entry) => {
          if (!query) return true;
          const searchable = entry.sensitive && !full
            ? [entry.id, entry.kind, entry.tier, entry.source, "sensitive memory", "敏感记忆"]
            : [entry.id, entry.kind, entry.tier, entry.source, entry.title, entry.content, entry.lastPrompt, ...entry.tags, ...entry.aliases];
          return searchable.join(" ").toLocaleLowerCase().includes(query);
        })
        .sort((left, right) => right.updatedAt.localeCompare(left.updatedAt) || left.id.localeCompare(right.id));
      const items: MemoryListItem[] = filtered.slice(offset, offset + limit).map((entry) => entry.sensitive && !full ? {
        ...entry,
        title: "Sensitive memory",
        content: "",
        lastPrompt: "",
        tags: [],
        aliases: [],
        taskId: undefined,
        executionRecordId: undefined,
        fingerprint: "",
        redacted: true,
      } : { ...entry, redacted: false });
      return clone({ items, totalCount: filtered.length, offset, limit, hasMore: offset + items.length < filtered.length, stateFingerprint }) as T;
    }
    case "memory_get": {
      const request = args?.request as MemoryGetRequest;
      const entry = demoMemories.find((item) => item.id === request.id);
      if (!entry) throw new Error("memory not found");
      if (entry.sensitive && request.sensitiveVisibility !== "full") {
        return clone({ ...entry, title: "Sensitive memory", content: "", lastPrompt: "", tags: [], aliases: [], taskId: undefined, executionRecordId: undefined, fingerprint: "", redacted: true }) as T;
      }
      return clone({ ...entry, redacted: false }) as T;
    }
    case "memory_upsert": {
      const request = args?.request as MemoryUpsertRequest;
      const title = request.title.trim();
      const content = request.content.trim();
      if (!title || !content) throw new Error("memory title and content must not be empty");
      if (memoryTextLength(title) > MEMORY_TITLE_MAX_CHARS) throw new Error(`memory title exceeds the ${MEMORY_TITLE_MAX_CHARS}-character limit`);
      if (memoryTextLength(content) > MEMORY_CONTENT_MAX_CHARS) throw new Error(`memory content exceeds the ${MEMORY_CONTENT_MAX_CHARS}-character limit`);
      if (mockNormalizedUniqueCount(request.tags) > MEMORY_TAXONOMY_MAX_ITEMS) throw new Error(`memory tags exceed the ${MEMORY_TAXONOMY_MAX_ITEMS}-item limit`);
      if (mockNormalizedUniqueCount(request.aliases) > MEMORY_TAXONOMY_MAX_ITEMS) throw new Error(`memory aliases exceed the ${MEMORY_TAXONOMY_MAX_ITEMS}-item limit`);
      const existingIndex = request.id ? demoMemories.findIndex((entry) => entry.id === request.id) : -1;
      const existing = existingIndex >= 0 ? demoMemories[existingIndex] : undefined;
      if (request.id && !existing) throw new Error(`memory not found: ${request.id}`);
      if ((!existing || request.kind !== existing.kind) && !MANUAL_MEMORY_KINDS.includes(request.kind)) {
        throw new Error("new user-managed memory kind must be fact, preference, experience, or knowledge");
      }
      const hasExpectedVersion = request.expectedFingerprint !== undefined || request.expectedUpdatedAt !== undefined;
      if (existing && (!hasExpectedVersion
        || (request.expectedFingerprint !== undefined && request.expectedFingerprint !== existing.fingerprint)
        || (request.expectedUpdatedAt !== undefined && request.expectedUpdatedAt !== existing.updatedAt))) {
        throw new Error("memory changed since it was opened; refresh and retry");
      }
      const timestamp = new Date().toISOString();
      const next: MemoryEntry = {
        id: existing?.id ?? `manual-${crypto.randomUUID()}`,
        kind: request.kind,
        tier: request.tier,
        title,
        content,
        lastPrompt: existing?.lastPrompt ?? "",
        tags: [...request.tags],
        source: "user_explicit",
        importance: request.importance,
        confidence: request.confidence,
        sensitive: request.sensitive || mockMemoryPayloadIsSensitive([title, content, ...request.tags, ...request.aliases]),
        messageCount: existing?.messageCount ?? 1,
        taskId: existing?.taskId,
        executionRecordId: existing?.executionRecordId,
        createdAt: existing?.createdAt ?? timestamp,
        updatedAt: timestamp,
        archivedAt: request.tier === "cold" ? (existing?.archivedAt ?? timestamp) : undefined,
        compressedAt: existing?.compressedAt,
        aliases: [...request.aliases],
        accessCount: existing?.accessCount ?? 0,
        lastAccessedAt: existing?.lastAccessedAt,
        fingerprint: `mock-${crypto.randomUUID()}`,
      };
      if (existingIndex >= 0) demoMemories[existingIndex] = next;
      else demoMemories = [next, ...demoMemories];
      snapshot = { ...snapshot, memory: demoMemorySnapshot() };
      return clone({ entry: { ...next, redacted: false }, snapshot: snapshot.memory }) as T;
    }
    case "memory_delete": {
      const request = args?.request as MemoryDeleteRequest;
      const existing = demoMemories.find((entry) => entry.id === request.id);
      if (!existing) throw new Error("memory not found");
      const hasExpectedVersion = request.expectedFingerprint !== undefined || request.expectedUpdatedAt !== undefined;
      if (!hasExpectedVersion
        || (request.expectedFingerprint !== undefined && request.expectedFingerprint !== existing.fingerprint)
        || (request.expectedUpdatedAt !== undefined && request.expectedUpdatedAt !== existing.updatedAt)) {
        throw new Error("memory changed since it was opened; refresh and retry");
      }
      demoMemories = demoMemories.filter((entry) => entry.id !== request.id);
      snapshot = { ...snapshot, memory: demoMemorySnapshot() };
      return clone({ deletedId: request.id, snapshot: snapshot.memory }) as T;
    }
    case "list_plugins": return clone(snapshot.plugins) as T;
    case "install_plugin": return clone(snapshot.plugins[0]) as T;
    case "set_plugin_enabled": {
      const id = String(args?.id ?? "");
      const enabled = Boolean(args?.enabled);
      snapshot = { ...snapshot, plugins: snapshot.plugins.map((plugin) => plugin.id === id ? { ...plugin, enabled } : plugin) };
      return clone(snapshot.plugins.find((plugin) => plugin.id === id)) as T;
    }
    case "probe_plugin": {
      const id = String(args?.id ?? "");
      return clone(snapshot.plugins.find((plugin) => plugin.id === id)) as T;
    }
    case "remove_plugin": {
      const id = String(args?.id ?? "");
      snapshot = { ...snapshot, plugins: snapshot.plugins.filter((plugin) => plugin.id !== id) };
      return undefined as T;
    }
    case "list_external_skills": return clone(snapshot.externalSkills) as T;
    case "refresh_external_skills": return clone(snapshot.externalSkills) as T;
    case "import_external_skill": {
      const path = String(args?.path ?? "");
      const normalized = path.toLowerCase();
      const sourceFormat = normalized.includes(".claude") ? "claude" : normalized.includes(".codex") ? "codex" : "open_agent_skill";
      const imported: ExternalSkillRecord = {
        ...demoExternalSkill,
        sourceFormat,
        sourcePath: path.replace(/[\\/]SKILL\.md$/i, ""),
        manifestPath: /SKILL\.md$/i.test(path) ? path : `${path}\\presentation-review\\SKILL.md`,
        compatibility: sourceFormat === "claude" ? "Claude Skill" : sourceFormat === "codex" ? "Codex Skill" : "Open Agent Skill",
      };
      snapshot = { ...snapshot, externalSkills: [...snapshot.externalSkills.filter((skill) => skill.id !== imported.id), imported] };
      return [clone(imported)] as T;
    }
    case "set_external_skill_enabled": {
      const id = String(args?.id ?? "");
      const enabled = Boolean(args?.enabled);
      snapshot = { ...snapshot, externalSkills: snapshot.externalSkills.map((skill) => skill.id === id ? { ...skill, enabled } : skill) };
      return clone(snapshot.externalSkills.find((skill) => skill.id === id)) as T;
    }
    case "remove_external_skill": {
      const id = String(args?.id ?? "");
      snapshot = { ...snapshot, externalSkills: snapshot.externalSkills.filter((skill) => skill.id !== id) };
      return undefined as T;
    }
    case "preview_path": return {
      name: "Project-Aurora-Brief.md", path: demoArtifactPath, kind: "markdown", mimeType: "text/markdown", sizeBytes: 1840,
      content: "# Project Aurora\n\n## Objective\nImprove release quality with a visible, repeatable verification loop.\n\n## Delivery plan\n\n1. Define measurable acceptance criteria.\n2. Produce the requested artifact.\n3. Verify the real file before completion.", sections: [],
      revision: "development-preview", faithful: true,
    } satisfies PreviewPayload as T;
    case "open_external":
    case "reveal_path": return undefined as T;
    default: throw new Error(`Unsupported development bridge command: ${command}`);
  }
}

function clone<T>(value: T): T {
  return structuredClone(value);
}
