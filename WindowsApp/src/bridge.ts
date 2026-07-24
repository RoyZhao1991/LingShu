import { invoke as tauriInvoke } from "@tauri-apps/api/core";
import { open as tauriOpen } from "@tauri-apps/plugin-dialog";
import type {
  PluginRecord, PreviewPayload, ProviderPreset, RuntimeEvent, RuntimeSettings, RuntimeSnapshot, TaskRecord,
} from "./types";

export interface BootstrapPayload {
  snapshot: RuntimeSnapshot;
  providers: ProviderPreset[];
}

export function hasNativeBridge(): boolean {
  return Reflect.has(window, "__TAURI_INTERNALS__");
}

export async function runtimeInvoke<T>(command: string, args?: Record<string, unknown>): Promise<T> {
  if (hasNativeBridge()) return tauriInvoke<T>(command, args);
  return mockInvoke<T>(command, args);
}

export async function chooseFiles(): Promise<string[]> {
  if (!hasNativeBridge()) return ["C:\\Users\\Roy\\Documents\\project-brief.md"];
  const selected = await tauriOpen({ multiple: true, directory: false });
  if (!selected) return [];
  return Array.isArray(selected) ? selected : [selected];
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
    version: "1.0.0",
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

let snapshot: RuntimeSnapshot = {
  kernelAbiVersion: "1.0.0",
  settings: {
    locale: "en", providerId: "deepseek", providerName: "DeepSeek", protocol: "openai_chat_completions",
    endpoint: "https://api.deepseek.com", model: "deepseek-chat",
    workspace: "C:\\Users\\Roy\\Documents\\LingShu Workspace",
    executionPermissionMode: "sandbox", firstRunComplete: true,
  },
  platform: "windows",
  capabilities: { computerControl: false, realtimePerception: false, internalPreview: true, externalOpen: true },
  messages: [
    { id: "demo-user", role: "user", text: "Review the attached resume and summarize the fit for Project Aurora.", createdAt: now, state: "complete", threadId: demoTask.id, attachmentPaths: [] },
    { id: "demo-assistant", role: "assistant", text: "The attached resume has been reviewed.\n\nDimension | Assessment || Delivery | Strong || Architecture | Good fit || Risk | Needs validation\n\nThe Project Aurora brief is ready and can be inspected in Nous's built-in preview.", createdAt: now, state: "complete", threadId: demoTask.id, attachmentPaths: [] },
  ],
  tasks: [demoTask], activeTaskId: undefined, queuedTaskCount: 0, providerConfigured: true,
  events: demoEvents, latestEventSequence: 3, plugins: demoPlugins,
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
      const task: TaskRecord & { assistantMessageId: string } = {
        id, title: prompt, prompt, status: "understanding", createdAt, updatedAt: createdAt,
        steps: [{ id: crypto.randomUUID(), title: "Understand the request", detail: "Generating a complete GoalSpec", status: "understanding", updatedAt: createdAt }],
        artifacts: [], summary: "", assistantMessageId: crypto.randomUUID(), attachmentPaths: (args?.attachmentPaths as string[]) ?? [],
        rootTaskId: id, role: "main", origin: "conversation", participantName: "LingShu", depth: 0,
      };
      const event: RuntimeEvent = { id: crypto.randomUUID(), sequence: snapshot.latestEventSequence + 1, taskId: id, kind: "model", state: "running", actor: snapshot.settings.model, title: "Understanding the goal", detail: "Compiling the current input into an executable goal.", createdAt, updatedAt: createdAt };
      snapshot = {
        ...snapshot, activeTaskId: id, tasks: [...snapshot.tasks, task],
        events: [...snapshot.events, event], latestEventSequence: event.sequence,
        messages: [...snapshot.messages,
          { id: crypto.randomUUID(), role: "user", text: prompt, createdAt, state: "complete", threadId: id, attachmentPaths: task.attachmentPaths },
          { id: task.assistantMessageId, role: "assistant", text: "Understanding…", createdAt, state: "thinking", threadId: id, attachmentPaths: [] },
        ],
      };
      return { threadId: id, queued: false } as T;
    }
    case "cancel_task": {
      const id = String(args?.threadId ?? "");
      snapshot = { ...snapshot, activeTaskId: undefined, tasks: snapshot.tasks.map((task) => task.id === id ? { ...task, status: "cancelled" } : task) };
      return true as T;
    }
    case "resume_task": {
      const id = String(args?.threadId ?? "");
      snapshot = { ...snapshot, activeTaskId: id, tasks: snapshot.tasks.map((task) => task.id === id ? { ...task, status: "running", pendingQuestion: undefined } : task) };
      return true as T;
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
    case "preview_path": return {
      name: "Project-Aurora-Brief.md", path: demoArtifactPath, kind: "markdown", mimeType: "text/markdown", sizeBytes: 1840,
      content: "# Project Aurora\n\n## Objective\nImprove release quality with a visible, repeatable verification loop.\n\n## Delivery plan\n\n1. Define measurable acceptance criteria.\n2. Produce the requested artifact.\n3. Verify the real file before completion.", sections: [],
    } satisfies PreviewPayload as T;
    case "open_external":
    case "reveal_path": return undefined as T;
    default: throw new Error(`Unsupported development bridge command: ${command}`);
  }
}

function clone<T>(value: T): T {
  return structuredClone(value);
}
