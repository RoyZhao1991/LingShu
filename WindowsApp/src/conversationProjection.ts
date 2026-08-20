import type { ChatMessage, Locale, TaskRecord } from "./types.ts";

export interface PendingSubmission {
  id: string;
  text: string;
  attachmentPaths: string[];
  createdAt: string;
}

interface OrderedMessage {
  message: ChatMessage;
  order: number;
}

function queuedMessages(task: TaskRecord, locale: Locale): ChatMessage[] {
  const userId = task.userMessageId ?? `queued-user-${task.id}`;
  const assistantId = task.assistantMessageId ?? `queued-assistant-${task.id}`;
  return [
    {
      id: userId,
      role: "user",
      text: task.prompt,
      createdAt: task.createdAt,
      state: "complete",
      threadId: task.id,
      attachmentPaths: task.attachmentPaths,
    },
    {
      id: assistantId,
      role: "assistant",
      text: locale === "en" ? "Queued for execution…" : "已进入队列，等待执行…",
      createdAt: task.createdAt,
      state: "thinking",
      threadId: task.id,
      attachmentPaths: [],
    },
  ];
}

function pendingMessages(submission: PendingSubmission, locale: Locale): ChatMessage[] {
  return [
    {
      id: `pending-user-${submission.id}`,
      role: "user",
      text: submission.text,
      createdAt: submission.createdAt,
      state: "complete",
      attachmentPaths: submission.attachmentPaths,
    },
    {
      id: `pending-assistant-${submission.id}`,
      role: "assistant",
      text: locale === "en" ? "Adding to the execution queue…" : "正在加入执行队列…",
      createdAt: submission.createdAt,
      state: "thinking",
      attachmentPaths: [],
    },
  ];
}

/**
 * The runtime keeps queued turns in the task queue until they are claimed. Project those tasks
 * into the Windows conversation immediately, while canonical runtime messages remain authoritative
 * as soon as they exist.
 */
export function projectConversationMessages(
  messages: readonly ChatMessage[],
  tasks: readonly TaskRecord[],
  pendingSubmissions: readonly PendingSubmission[],
  locale: Locale,
): ChatMessage[] {
  const representedThreads = new Set(
    messages.flatMap((message) => message.threadId ? [message.threadId] : []),
  );
  const ordered: OrderedMessage[] = messages.map((message, order) => ({ message, order }));
  let order = ordered.length;

  for (const task of tasks) {
    if (task.parentTaskId || task.role !== "main" || task.status !== "queued" || representedThreads.has(task.id)) continue;
    for (const message of queuedMessages(task, locale)) ordered.push({ message, order: order++ });
  }
  for (const submission of pendingSubmissions) {
    for (const message of pendingMessages(submission, locale)) ordered.push({ message, order: order++ });
  }

  return ordered
    .sort((left, right) => {
      const byTime = Date.parse(left.message.createdAt) - Date.parse(right.message.createdAt);
      return byTime || left.order - right.order;
    })
    .map(({ message }) => message);
}
