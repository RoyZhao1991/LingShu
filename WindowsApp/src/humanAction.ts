import type { TaskRecord } from "./types.ts";

export function isInteractiveActionTask(
  task: Pick<TaskRecord, "status" | "pendingToolCallId">,
): boolean {
  return task.status === "needs_user_action" && Boolean(task.pendingToolCallId?.trim());
}

export function findInteractiveActionTask(tasks: readonly TaskRecord[] | undefined): TaskRecord | undefined {
  return tasks?.find(isInteractiveActionTask);
}
