import type { ChatMessage, Locale, RuntimeEvent } from "./types";

export interface ChatBubbleProjection {
  key: string;
  text: string;
  isRunning: boolean;
}

const internalDetailMarkers = [
  '"file_name"',
  '"slides"',
  '"layout"',
  '"theme"',
  '"tool_calls"',
  '"arguments"',
  '"recursive"',
  '"command"',
  '"ok"',
  '"path"',
  "[truncated]",
];

const activeAssistantStates = new Set<ChatMessage["state"]>([
  "thinking",
  "needs_recovery",
  "failed",
]);

function nonEmpty(value: string): string | undefined {
  const trimmed = value.trim();
  return trimmed ? trimmed : undefined;
}

function readableEventDetail(raw: string): string | undefined {
  const visible = raw.trim();
  if (!visible) return undefined;

  const lower = visible.toLowerCase();
  const beginsLikePayload = visible.startsWith("{") || visible.startsWith("[");
  const markerCount = internalDetailMarkers.reduce(
    (count, marker) => count + (lower.includes(marker) ? 1 : 0),
    0,
  );
  if ((beginsLikePayload && markerCount >= 2) || lower.includes("[truncated]")) return undefined;
  return visible;
}

function userFacingProgress(event: RuntimeEvent | undefined, locale: Locale): string | undefined {
  if (!event) return undefined;

  const thinking = locale === "en" ? "Thinking…" : "思考中…";
  const title = nonEmpty(event.title);
  if (["tool", "plan", "delegation"].includes(event.kind)) return title;
  if (event.kind === "reasoning") return thinking;
  if (event.kind === "model") {
    const detail = readableEventDetail(event.detail);
    if (detail) return detail;
    if (title?.startsWith("模型回合 ") || title?.startsWith("Model turn ")) return thinking;
    return title ?? thinking;
  }

  const detail = readableEventDetail(event.detail);
  if (!detail) return title;
  if (!title || detail === title || detail.startsWith(title)) return detail;
  return `${title}\n${detail}`;
}

/**
 * Keep the Windows chat shell on the same projection contract as macOS:
 * cumulative assistant text wins, while runtime progress is only a fallback
 * before the Loop has produced any user-visible text.
 */
export function projectChatBubble(
  message: ChatMessage,
  latestEvent: RuntimeEvent | undefined,
  locale: Locale,
): ChatBubbleProjection {
  const isRunning = message.role === "assistant" && activeAssistantStates.has(message.state);
  if (message.text.trim()) {
    return { key: message.id, text: message.text, isRunning };
  }

  if (!isRunning) {
    return { key: message.id, text: message.text, isRunning: false };
  }

  const progress = userFacingProgress(latestEvent, locale);
  const recovering = message.state === "needs_recovery" || message.state === "failed";
  const fallback = locale === "en"
    ? (recovering ? "Recovering…" : "Thinking…")
    : (recovering ? "正在恢复并继续推进…" : "思考中…");
  return { key: message.id, text: progress || fallback, isRunning: true };
}
