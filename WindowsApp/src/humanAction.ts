import type { TaskRecord } from "./types.ts";

export function isInteractiveActionTask(
  task: Pick<TaskRecord, "status" | "pendingToolCallId" | "role" | "parentTaskId">,
): boolean {
  return task.role === "main"
    && !task.parentTaskId
    && task.status === "needs_user_action"
    && Boolean(task.pendingToolCallId?.trim());
}

export function findInteractiveActionTask(tasks: readonly TaskRecord[] | undefined): TaskRecord | undefined {
  return tasks?.find(isInteractiveActionTask);
}

export function interactiveActionCheckpointKey(task: TaskRecord | undefined): string | undefined {
  if (!task || !isInteractiveActionTask(task)) return undefined;
  return `${task.id}:${task.pendingToolCallId!.trim()}`;
}

export function findVisibleInteractiveActionTask(
  tasks: readonly TaskRecord[] | undefined,
  dismissedCheckpointKey: string | undefined,
  activeTaskId: string | undefined,
): TaskRecord | undefined {
  if (activeTaskId) return undefined;
  const task = findInteractiveActionTask(tasks);
  return interactiveActionCheckpointKey(task) === dismissedCheckpointKey ? undefined : task;
}
