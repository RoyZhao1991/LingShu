export type Locale = "zh_cn" | "en";
export type ProviderProtocol = "openai_chat_completions" | "anthropic_messages";
export type MessageState = "complete" | "thinking" | "failed" | "needs_user_action";
export type TaskStatus = "queued" | "understanding" | "running" | "needs_user_action" | "completed" | "failed" | "cancelled";

export interface RuntimeSettings {
  locale: Locale;
  providerId: string;
  providerName: string;
  protocol: ProviderProtocol;
  endpoint: string;
  model: string;
  workspace: string;
  firstRunComplete: boolean;
}

export interface PlatformCapabilities {
  computerControl: boolean;
  realtimePerception: boolean;
  internalPreview: boolean;
  externalOpen: boolean;
}

export interface ChatMessage {
  id: string;
  role: "user" | "assistant" | "system";
  text: string;
  createdAt: string;
  state: MessageState;
  threadId?: string;
}

export interface GoalSpec {
  objective: string;
  kind: string;
  output_mode: string;
  reference_scope: string;
  reference_evidence: string[];
  reference_explicit: boolean;
  reference_confidence: string;
  constraints: string[];
  boundaries: string[];
  risks: string[];
  success_criteria: string[];
  open_questions: string[];
}

export interface ArtifactRecord {
  id: string;
  title: string;
  path: string;
  kind: string;
  sizeBytes: number;
  modifiedAt: string;
}

export interface TaskStep {
  id: string;
  title: string;
  detail: string;
  status: TaskStatus;
  updatedAt: string;
}

export interface TaskRecord {
  id: string;
  title: string;
  prompt: string;
  status: TaskStatus;
  createdAt: string;
  updatedAt: string;
  goalSpec?: GoalSpec;
  steps: TaskStep[];
  artifacts: ArtifactRecord[];
  summary: string;
  error?: string;
  attachmentPaths: string[];
}

export interface RuntimeSnapshot {
  kernelAbiVersion: string;
  settings: RuntimeSettings;
  platform: string;
  capabilities: PlatformCapabilities;
  messages: ChatMessage[];
  tasks: TaskRecord[];
  activeTaskId?: string;
  queuedTaskCount: number;
  providerConfigured: boolean;
}

export interface ProviderPreset {
  id: string;
  name: string;
  region: string;
  endpoint: string;
  protocol: ProviderProtocol;
  defaultModels: string[];
  requiresApiKey: boolean;
}

export interface PreviewPayload {
  name: string;
  path: string;
  kind: "text" | "markdown" | "code" | "html" | "image" | "pdf" | "document" | "presentation" | "unsupported";
  mimeType: string;
  content: string;
  sections: string[];
  sizeBytes: number;
}

export type Page = "chat" | "threads" | "status" | "settings";
