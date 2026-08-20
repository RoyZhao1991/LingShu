import { mergeAttachmentPaths } from "./attachments.ts";
import type { ChatMessage, TaskRecord } from "./types.ts";

export interface MessageReuseDraft {
  text: string;
  attachmentPaths: string[];
}

/**
 * Resolve the files that belong to a visible chat message.
 *
 * Current messages carry their files directly. Older user messages may predate that field, so
 * their originating task remains the compatibility fallback. Assistant messages must never use
 * that fallback: the task files are user inputs, not assistant outputs.
 */
export function resolveMessageAttachmentPaths(
  message: ChatMessage,
  tasks: readonly TaskRecord[],
): string[] {
  const direct = mergeAttachmentPaths([], message.attachmentPaths ?? []);
  if (direct.length > 0 || message.role !== "user" || !message.threadId) return direct;

  const taskPaths = tasks.find((task) => task.id === message.threadId)?.attachmentPaths ?? [];
  return mergeAttachmentPaths([], taskPaths);
}

/** Build an isolated, editable copy of a message and all of its input attachments. */
export function buildMessageReuseDraft(
  message: ChatMessage,
  tasks: readonly TaskRecord[],
): MessageReuseDraft {
  return {
    text: message.text,
    attachmentPaths: resolveMessageAttachmentPaths(message, tasks),
  };
}
