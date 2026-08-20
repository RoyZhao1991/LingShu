import { FormEvent, type DragEvent as ReactDragEvent, type KeyboardEvent as ReactKeyboardEvent, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import ReactMarkdown, { type Components } from "react-markdown";
import remarkGfm from "remark-gfm";
import type { PDFDocumentLoadingTask, PDFDocumentProxy, RenderTask } from "pdfjs-dist";
import pdfWorkerUrl from "pdfjs-dist/build/pdf.worker.min.mjs?url";
import {
  Activity, Archive, Bot, BrainCircuit, Check, ChevronRight, CircleAlert, Clock3, ExternalLink, Eye, EyeOff,
  Copy, FileBox, FileText, FolderOpen, Gauge, GitBranch, ListChecks, LoaderCircle, MessageCircle,
  LockKeyhole, MessagesSquare, PackageCheck, PackagePlus, Paperclip, Pencil, Play, Plus, Puzzle, RefreshCw, Save, Search, Send,
  Settings, ShieldCheck, Square, Trash2, UserRound, Wrench, X,
} from "lucide-react";
import { executionLinkLabel, strings } from "./i18n";
import {
  chooseExternalSkillDirectory, chooseExternalSkillManifest, chooseFiles, choosePluginManifest, deleteMemory, getMemory,
  hasNativeBridge, listMemory, listenForWindowFileDrops, runtimeInvoke, upsertMemory,
} from "./bridge";
import { browserDroppedFilePaths, mergeAttachmentPaths } from "./attachments";
import { projectChatBubble } from "./chatProjection";
import { projectConversationMessages, type PendingSubmission } from "./conversationProjection";
import { findInteractiveActionTask, findVisibleInteractiveActionTask, interactiveActionCheckpointKey } from "./humanAction";
import { normalizeMarkdownTables } from "./markdown";
import { buildMessageReuseDraft, resolveMessageAttachmentPaths } from "./messageReuse";
import {
  emptyMemoryFilters, MEMORY_CONTENT_MAX_CHARS, MEMORY_TAXONOMY_MAX_ITEMS, MEMORY_TITLE_MAX_CHARS,
  memoryDraftFromEntry, memoryDraftIsValid, memoryEditableKinds, memoryListPreview, memoryTaxonomyCount,
  memoryTextLength, memoryUpsertRequest, newMemoryDraft, truncateMemoryText,
  type MemoryEditorDraft, type MemoryFilters,
} from "./memoryManagement";
import { decodePdfDataUri } from "./pdf";
import { SnapshotGate } from "./snapshotGate";
import packageMetadata from "../package.json";
import type {
  ArtifactRecord, ChatMessage, ExecutionPermissionMode, ExternalSkillRecord, Locale, MemoryEntry, MemoryKind, MemoryListItem,
  MemorySnapshot, MemorySource, MemoryTier, Page, PluginRecord, PreviewPayload, ProviderPreset, RuntimeSettings, RuntimeEvent,
  RuntimeSnapshot, TaskRecord, TaskRole, TaskStatus,
} from "./types";

import type { BootstrapPayload, SubmitMessagePayload } from "./bridge";

const terminalStatuses = new Set<TaskStatus>(["completed", "cancelled"]);
const recoverableStatus = (status: TaskStatus): TaskStatus => status === "failed" ? "needs_recovery" : status;
const appVersion = packageMetadata.version;
const markdownComponents: Components = {
  table: ({ node: _node, ...props }) => <div className="markdown-table-scroll"><table {...props} /></div>,
};

export default function App() {
  const [snapshot, setSnapshot] = useState<RuntimeSnapshot>();
  const [providers, setProviders] = useState<ProviderPreset[]>([]);
  const [page, setPage] = useState<Page>("chat");
  const [prompt, setPrompt] = useState("");
  const [attachments, setAttachments] = useState<string[]>([]);
  const [selectedTaskId, setSelectedTaskId] = useState<string>();
  const [preview, setPreview] = useState<PreviewPayload>();
  const [error, setError] = useState("");
  const [sending, setSending] = useState(false);
  const [settingsDraft, setSettingsDraft] = useState<RuntimeSettings>();
  const [apiKey, setApiKey] = useState("");
  const [validating, setValidating] = useState(false);
  const [permissionUpdating, setPermissionUpdating] = useState(false);
  const [actionAnswer, setActionAnswer] = useState("");
  const [resuming, setResuming] = useState(false);
  const [dismissedActionCheckpointKey, setDismissedActionCheckpointKey] = useState<string>();
  const [pendingSubmissions, setPendingSubmissions] = useState<PendingSubmission[]>([]);
  const [pluginBusy, setPluginBusy] = useState("");
  const [capabilityError, setCapabilityError] = useState("");
  const [dragActive, setDragActive] = useState(false);
  const [messageActionFeedback, setMessageActionFeedback] = useState<{ key: string; kind: "copied" | "restored"; attachmentCount: number }>();
  const messageScroll = useRef<HTMLDivElement>(null);
  const composerInput = useRef<HTMLTextAreaElement>(null);
  const keepAtBottom = useRef(true);
  const previousPage = useRef<Page>(page);
  const previewRequest = useRef(0);
  const snapshotGate = useRef(new SnapshotGate());
  const refreshInFlight = useRef<Promise<void> | undefined>(undefined);
  const refreshAgain = useRef(false);
  const messageActionFeedbackTimer = useRef<number | undefined>(undefined);

  const locale = settingsDraft?.locale ?? snapshot?.settings.locale ?? "zh_cn";
  const t = strings(locale);
  const activeTask = snapshot?.tasks.find((task) => task.id === snapshot.activeTaskId);
  const isBusy = Boolean(snapshot?.tasks.some((task) => ["understanding", "running", "needs_recovery", "failed"].includes(task.status))) || Boolean(snapshot?.queuedTaskCount) || pendingSubmissions.length > 0;
  const selectedTask = snapshot?.tasks.find((task) => task.id === selectedTaskId) ?? activeTask ?? snapshot?.tasks.filter((task) => !task.parentTaskId).at(-1);
  const pendingActionTask = findInteractiveActionTask(snapshot?.tasks);
  const pendingActionCheckpointKey = interactiveActionCheckpointKey(pendingActionTask);
  const actionTask = findVisibleInteractiveActionTask(snapshot?.tasks, dismissedActionCheckpointKey, snapshot?.activeTaskId);
  const conversationMessages = useMemo(
    () => snapshot ? projectConversationMessages(snapshot.messages, snapshot.tasks, pendingSubmissions, locale) : [],
    [locale, pendingSubmissions, snapshot],
  );

  useEffect(() => { document.documentElement.lang = locale === "en" ? "en" : "zh-CN"; }, [locale]);

  useEffect(() => () => {
    if (messageActionFeedbackTimer.current !== undefined) window.clearTimeout(messageActionFeedbackTimer.current);
  }, []);

  const applyMutationSnapshot = useCallback((next: RuntimeSnapshot) => {
    snapshotGate.current.commitMutation();
    setSnapshot(next);
  }, []);

  const applyMemorySummary = useCallback((memory: MemorySnapshot) => {
    snapshotGate.current.commitMutation();
    setSnapshot((current) => current ? { ...current, memory } : current);
  }, []);

  const bindAttachments = useCallback((paths: readonly string[]) => {
    if (!paths.some((path) => path.trim())) return;
    setAttachments((current) => mergeAttachmentPaths(current, paths));
    setPage("chat");
    window.setTimeout(() => composerInput.current?.focus(), 0);
  }, []);

  const refresh = useCallback(async () => {
    refreshAgain.current = true;
    if (refreshInFlight.current) return refreshInFlight.current;
    const run = (async () => {
      do {
        refreshAgain.current = false;
        const readVersion = snapshotGate.current.beginRead();
        try {
          const next = await runtimeInvoke<RuntimeSnapshot>("get_snapshot");
          if (!snapshotGate.current.acceptsRead(readVersion)) continue;
          setSnapshot(next);
          setSettingsDraft((current) => current ?? next.settings);
          setError("");
        } catch (reason) {
          if (snapshotGate.current.acceptsRead(readVersion)) setError(String(reason));
        }
      } while (refreshAgain.current);
    })();
    refreshInFlight.current = run;
    try {
      await run;
    } finally {
      if (refreshInFlight.current === run) refreshInFlight.current = undefined;
    }
  }, []);

  useEffect(() => {
    void runtimeInvoke<BootstrapPayload>("bootstrap").then((payload) => {
      applyMutationSnapshot(payload.snapshot);
      setProviders(payload.providers);
      setSettingsDraft(payload.snapshot.settings);
      setSelectedTaskId(payload.snapshot.activeTaskId ?? payload.snapshot.tasks.at(-1)?.id);
    }).catch((reason) => setError(String(reason)));
  }, [applyMutationSnapshot]);

  useEffect(() => {
    if (!snapshot) return;
    const interval = window.setInterval(() => void refresh(), isBusy ? 350 : 1_500);
    return () => window.clearInterval(interval);
  }, [isBusy, refresh, snapshot]);

  useEffect(() => {
    setActionAnswer("");
    if (pendingActionCheckpointKey !== dismissedActionCheckpointKey) {
      setDismissedActionCheckpointKey(undefined);
    }
  }, [pendingActionCheckpointKey]);

  useLayoutEffect(() => {
    const enteredChat = page === "chat" && previousPage.current !== "chat";
    previousPage.current = page;
    if (page !== "chat") return;
    if (enteredChat) keepAtBottom.current = true;

    const node = messageScroll.current;
    if (node && keepAtBottom.current) {
      node.scrollTop = node.scrollHeight;
    }
  }, [conversationMessages.length, conversationMessages.at(-1)?.text, page, snapshot?.latestEventSequence]);

  useEffect(() => {
    document.title = t.appName;
    void import("@tauri-apps/api/window")
      .then(({ getCurrentWindow }) => getCurrentWindow().setTitle(t.appName))
      .catch(() => undefined);
  }, [t.appName]);

  useEffect(() => {
    let disposed = false;
    let unlisten: (() => void) | undefined;

    void listenForWindowFileDrops((event) => {
      if (disposed) return;
      if (event.type === "enter" || event.type === "over") {
        setDragActive(true);
        return;
      }
      setDragActive(false);
      if (event.type === "drop") bindAttachments(event.paths);
    }).then((stopListening) => {
      if (disposed) stopListening();
      else unlisten = stopListening;
    }).catch((reason) => {
      console.error("Unable to register the native file-drop listener", reason);
      setDragActive(false);
    });

    return () => {
      disposed = true;
      unlisten?.();
    };
  }, [bindAttachments]);

  const trackMessageScroll = () => {
    const node = messageScroll.current;
    if (!node) return;
    keepAtBottom.current = node.scrollHeight - node.scrollTop - node.clientHeight < 56;
  };

  const flashMessageAction = (key: string, kind: "copied" | "restored", attachmentCount: number) => {
    if (messageActionFeedbackTimer.current !== undefined) window.clearTimeout(messageActionFeedbackTimer.current);
    setMessageActionFeedback({ key, kind, attachmentCount });
    messageActionFeedbackTimer.current = window.setTimeout(() => setMessageActionFeedback(undefined), 1_500);
  };

  const copyMessage = async (visibleText: string, key: string) => {
    try {
      await writeClipboardText(visibleText);
      flashMessageAction(key, "copied", 0);
    } catch (reason) {
      setError(`${t.copyMessageFailed}: ${String(reason)}`);
    }
  };

  const editAndResend = (message: ChatMessage, key: string) => {
    const draft = buildMessageReuseDraft(message, snapshot?.tasks ?? []);
    const hasDifferentDraft = prompt.trim() || attachments.length > 0;
    if (hasDifferentDraft && !window.confirm(t.replaceDraftConfirm)) return;

    setPrompt(draft.text);
    setAttachments(draft.attachmentPaths);
    setPage("chat");
    keepAtBottom.current = true;
    flashMessageAction(key, "restored", draft.attachmentPaths.length);
    window.setTimeout(() => {
      const input = composerInput.current;
      input?.focus();
      input?.setSelectionRange(draft.text.length, draft.text.length);
    }, 0);
  };

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    const text = prompt.trim();
    if (!text || sending || permissionUpdating) return;
    const submission: PendingSubmission = {
      id: crypto.randomUUID(),
      text,
      attachmentPaths: [...attachments],
      createdAt: new Date().toISOString(),
    };
    setSending(true);
    setError("");
    setPendingSubmissions((current) => [...current, submission]);
    setPrompt("");
    setAttachments([]);
    try {
      const payload = await runtimeInvoke<SubmitMessagePayload>("submit_message", {
        prompt: text,
        attachmentPaths: submission.attachmentPaths,
      });
      applyMutationSnapshot(payload.snapshot);
      setSelectedTaskId(payload.receipt.threadId);
      setPendingSubmissions((current) => current.filter((item) => item.id !== submission.id));
    } catch (reason) {
      setPendingSubmissions((current) => current.filter((item) => item.id !== submission.id));
      setPrompt((current) => current.trim() ? current : text);
      setAttachments((current) => mergeAttachmentPaths(submission.attachmentPaths, current));
      setError(`${t.requestError}: ${String(reason)}`);
    } finally {
      setSending(false);
    }
  };

  const chooseAttachments = async () => {
    const selected = await chooseFiles();
    bindAttachments(selected);
  };

  const handleBrowserDrag = (event: ReactDragEvent<HTMLDivElement>) => {
    if (hasNativeBridge() || !event.dataTransfer.types.includes("Files")) return;
    event.preventDefault();
    event.dataTransfer.dropEffect = "copy";
    setDragActive(true);
  };

  const handleBrowserDragLeave = (event: ReactDragEvent<HTMLDivElement>) => {
    if (hasNativeBridge()) return;
    const nextTarget = event.relatedTarget;
    if (nextTarget instanceof Node && event.currentTarget.contains(nextTarget)) return;
    setDragActive(false);
  };

  const handleBrowserDrop = (event: ReactDragEvent<HTMLDivElement>) => {
    if (hasNativeBridge()) return;
    event.preventDefault();
    setDragActive(false);
    bindAttachments(browserDroppedFilePaths(event.dataTransfer.files));
  };

  const showPathPreview = async (path: string) => {
    const request = ++previewRequest.current;
    setPreview(undefined);
    try {
      const next = await runtimeInvoke<PreviewPayload>("preview_path", { path });
      if (previewRequest.current === request) setPreview(next);
    } catch (reason) {
      if (previewRequest.current === request) setError(String(reason));
    }
  };

  const showPreview = async (artifact: ArtifactRecord) => showPathPreview(artifact.path);

  const saveSettings = async () => {
    if (!settingsDraft) return;
    setValidating(true);
    setError("");
    try {
      const next = await runtimeInvoke<RuntimeSnapshot>("save_and_validate_settings", {
        settings: { ...settingsDraft, firstRunComplete: true },
        apiKey,
      });
      applyMutationSnapshot(next);
      setSettingsDraft(next.settings);
      setApiKey("");
    } catch (reason) {
      setError(`${t.saveError}: ${String(reason)}`);
    } finally {
      setValidating(false);
    }
  };

  const updateExecutionPermission = async (mode: ExecutionPermissionMode) => {
    if (!snapshot || permissionUpdating || snapshot.settings.executionPermissionMode === mode) return;
    setPermissionUpdating(true);
    setError("");
    try {
      const next = await runtimeInvoke<RuntimeSnapshot>("update_execution_permission_mode", { mode });
      applyMutationSnapshot(next);
      setSettingsDraft((draft) => draft ? { ...draft, executionPermissionMode: next.settings.executionPermissionMode } : next.settings);
    } catch (reason) {
      setError(String(reason));
    } finally {
      setPermissionUpdating(false);
    }
  };

  const resumeAction = async () => {
    if (!actionTask || resuming || !actionAnswer.trim()) return;
    setResuming(true);
    setError("");
    try {
      const checkpointKey = interactiveActionCheckpointKey(actionTask);
      const next = await runtimeInvoke<RuntimeSnapshot | null>("resume_task", {
        threadId: actionTask.id,
        expectedToolCallId: actionTask.pendingToolCallId,
        answer: actionAnswer.trim(),
      });
      if (!next) throw new Error(locale === "en" ? "The task is not ready to resume." : "当前任务暂时无法恢复执行。");
      setDismissedActionCheckpointKey(checkpointKey);
      applyMutationSnapshot(next);
      setActionAnswer("");
    } catch (reason) {
      setError(String(reason));
    } finally {
      setResuming(false);
    }
  };

  const installPlugin = async () => {
    const manifestPath = await choosePluginManifest();
    if (!manifestPath) return;
    setPluginBusy("install");
    setCapabilityError("");
    try {
      await runtimeInvoke<PluginRecord>("install_plugin", { manifestPath });
      await refresh();
    } catch (reason) {
      setCapabilityError(String(reason));
    } finally {
      setPluginBusy("");
    }
  };

  const setPluginEnabled = async (plugin: PluginRecord, enabled: boolean) => {
    setPluginBusy(plugin.id);
    setCapabilityError("");
    try {
      await runtimeInvoke<PluginRecord>("set_plugin_enabled", { id: plugin.id, enabled });
      await refresh();
    } catch (reason) {
      setCapabilityError(String(reason));
    } finally {
      setPluginBusy("");
    }
  };

  const probePlugin = async (plugin: PluginRecord) => {
    setPluginBusy(plugin.id);
    setCapabilityError("");
    try {
      await runtimeInvoke<PluginRecord>("probe_plugin", { id: plugin.id });
      await refresh();
    } catch (reason) {
      setCapabilityError(String(reason));
    } finally {
      setPluginBusy("");
    }
  };

  const removePlugin = async (plugin: PluginRecord) => {
    const confirmed = window.confirm(locale === "en" ? `Remove ${plugin.name}?` : `确认卸载 ${plugin.name}？`);
    if (!confirmed) return;
    setPluginBusy(plugin.id);
    setCapabilityError("");
    try {
      await runtimeInvoke("remove_plugin", { id: plugin.id });
      await refresh();
    } catch (reason) {
      setCapabilityError(String(reason));
    } finally {
      setPluginBusy("");
    }
  };

  const importExternalSkill = async (selection: "manifest" | "directory") => {
    const path = selection === "manifest" ? await chooseExternalSkillManifest() : await chooseExternalSkillDirectory();
    if (!path) return;
    setPluginBusy(`skill-import:${selection}`);
    setCapabilityError("");
    try {
      await runtimeInvoke<ExternalSkillRecord[]>("import_external_skill", { path });
      await refresh();
    } catch (reason) {
      setCapabilityError(String(reason));
    } finally {
      setPluginBusy("");
    }
  };

  const setExternalSkillEnabled = async (skill: ExternalSkillRecord, enabled: boolean) => {
    setPluginBusy(`skill:${skill.id}`);
    setCapabilityError("");
    try {
      await runtimeInvoke<ExternalSkillRecord>("set_external_skill_enabled", { id: skill.id, enabled });
      await refresh();
    } catch (reason) {
      setCapabilityError(String(reason));
    } finally {
      setPluginBusy("");
    }
  };

  const removeExternalSkill = async (skill: ExternalSkillRecord) => {
    const confirmed = window.confirm(`${skill.name}\n\n${t.skillDetachConfirm}`);
    if (!confirmed) return;
    setPluginBusy(`skill:${skill.id}`);
    setCapabilityError("");
    try {
      await runtimeInvoke("remove_external_skill", { id: skill.id });
      await refresh();
    } catch (reason) {
      setCapabilityError(String(reason));
    } finally {
      setPluginBusy("");
    }
  };

  const refreshCapabilities = async () => {
    setPluginBusy("refresh");
    setCapabilityError("");
    try {
      await runtimeInvoke<ExternalSkillRecord[]>("refresh_external_skills");
      await refresh();
    } catch (reason) {
      setCapabilityError(String(reason));
    } finally {
      setPluginBusy("");
    }
  };

  const selectProvider = (providerId: string) => {
    const provider = providers.find((item) => item.id === providerId);
    if (!provider || !settingsDraft) return;
    setSettingsDraft({
      ...settingsDraft,
      providerId: provider.id,
      providerName: provider.name,
      protocol: provider.protocol,
      endpoint: provider.endpoint,
      model: provider.defaultModels[0] ?? "",
    });
  };

  if (!snapshot || !settingsDraft) {
    return <main className="boot"><BrandMark /><span>{t.runtimeName}</span></main>;
  }

  const setupRequired = !snapshot.providerConfigured || !snapshot.settings.firstRunComplete;

  return (
    <div className={`app-shell ${dragActive ? "is-file-dragging" : ""}`}
      onDragEnter={handleBrowserDrag} onDragOver={handleBrowserDrag}
      onDragLeave={handleBrowserDragLeave} onDrop={handleBrowserDrop}>
      <Header page={page} setPage={setPage} busy={isBusy} queuedCount={(snapshot?.queuedTaskCount ?? 0) + pendingSubmissions.length} locale={locale} />
      <main className="workspace-shell">
        {page === "chat" && (
          <section className="chat-page">
            <div className="message-scroll" ref={messageScroll} onScroll={trackMessageScroll}>
              {conversationMessages.length === 0 && <EmptyState icon={<MessageCircle />} text={t.noMessages} />}
              {conversationMessages.map((message) => {
                const messageAttachments = resolveMessageAttachmentPaths(message, snapshot.tasks);
                const messageTask = message.threadId
                  ? snapshot.tasks.find((task) => task.id === message.threadId)
                  : undefined;
                const bubble = projectChatBubble(
                  message,
                  message.threadId ? latestEventForThread(snapshot, message.threadId) : undefined,
                  locale,
                );
                const pendingProjection = message.id.startsWith("pending-");
                const actionFeedback = messageActionFeedback?.key === bubble.key ? messageActionFeedback : undefined;
                const copyable = !bubble.isRunning && Boolean(bubble.text.trim());
                return <article key={bubble.key} className={`message ${message.role} ${bubble.isRunning ? "running" : ""}`}>
                  <div className="message-meta">
                    <span>{message.role === "user" ? (locale === "en" ? "You" : "你") : t.appName}</span>
                    <time>{new Date(message.createdAt).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}</time>
                  </div>
                  <div className="markdown-body">
                    {bubble.isRunning && <LoaderCircle className="inline-loader spin" />}
                    <MarkdownContent>{bubble.text}</MarkdownContent>
                  </div>
                  {message.role === "assistant" && messageTask?.status === "cancelled" && (
                    <div className="message-termination"><Square size={13} />{t.cancelled}</div>
                  )}
                  {messageAttachments.length > 0 && (
                    <div className="message-attachments" aria-label={locale === "en" ? "Message attachments" : "消息附件"}>
                      {messageAttachments.map((path) => (
                        <button type="button" key={path} className="message-attachment" title={path} onClick={() => void showPathPreview(path)}>
                          <FileText />
                          <span><strong>{fileName(path)}</strong><small>{locale === "en" ? "Attachment · Preview" : "附件 · 点击预览"}</small></span>
                          <ChevronRight />
                        </button>
                      ))}
                    </div>
                  )}
                  {message.threadId && message.role === "assistant" && messageTask
                    && shouldShowExecution(snapshot, message.threadId) && (
                    <button className="thread-link" onClick={() => { setSelectedTaskId(message.threadId); setPage("threads"); }}>
                      <MessagesSquare size={16} /> {executionLinkLabel(aggregateTaskStatus(messageTask, snapshot.tasks), locale)}
                    </button>
                  )}
                  {(copyable || (message.role === "user" && !pendingProjection)) && (
                    <div className="message-actions" aria-label={t.messageActions}>
                      {copyable && (
                        <button type="button" className="message-action" title={t.copyMessage}
                          aria-label={t.copyMessage} onClick={() => void copyMessage(bubble.text, bubble.key)}>
                          {actionFeedback?.kind === "copied" ? <Check /> : <Copy />}
                        </button>
                      )}
                      {message.role === "user" && !pendingProjection && (
                        <button type="button" className="message-action" title={t.editAndResend}
                          aria-label={t.editAndResend} onClick={() => editAndResend(message, bubble.key)}>
                          {actionFeedback?.kind === "restored" ? <Check /> : <Pencil />}
                        </button>
                      )}
                      {actionFeedback && (
                        <span className="message-action-feedback" aria-live="polite">
                          {actionFeedback.kind === "restored"
                            ? (actionFeedback.attachmentCount > 0 ? t.draftAndAttachmentsRestored : t.draftRestored)
                            : t.messageCopied}
                        </span>
                      )}
                    </div>
                  )}
                </article>;
              })}
            </div>
            <form className="composer" onSubmit={submit}>
              {error && <div className="error-strip"><CircleAlert size={16} />{error}</div>}
              {attachments.length > 0 && (
                <div className="attachment-strip">
                  {attachments.map((path) => (
                    <button type="button" key={path} className="attachment-chip" onClick={() => setAttachments((items) => items.filter((item) => item !== path))}>
                      <FileText size={15} /><span>{fileName(path)}</span><X size={13} />
                    </button>
                  ))}
                </div>
              )}
              <textarea ref={composerInput} value={prompt} onChange={(event) => setPrompt(event.target.value)} placeholder={t.placeholder}
                aria-label={t.placeholder}
                onKeyDown={(event) => { if (event.key === "Enter" && !event.shiftKey && !event.nativeEvent.isComposing) { event.preventDefault(); event.currentTarget.form?.requestSubmit(); } }} />
              <div className="composer-actions">
                <button type="button" className="icon-button" title={t.attach} onClick={chooseAttachments}><Paperclip /></button>
                <PermissionSelector mode={snapshot.settings.executionPermissionMode} locale={locale} compact disabled={permissionUpdating} onChange={updateExecutionPermission} />
                <span className="channel-state"><span className={snapshot.providerConfigured ? "dot good" : "dot"} />{snapshot.settings.providerName} · {snapshot.settings.model}</span>
                {activeTask && (
                  <button type="button" className="stop-button" onClick={() => void runtimeInvoke("cancel_task", { threadId: activeTask.id }).then(refresh)}><Square size={16} />{t.stop}</button>
                )}
                <button className="send-button" type="submit" disabled={sending || permissionUpdating || !prompt.trim()} title={t.send}><Send /></button>
              </div>
            </form>
          </section>
        )}

        {page === "threads" && (
          <ThreadsPage tasks={snapshot.tasks} events={snapshot.events} selected={selectedTask} locale={locale} onSelect={setSelectedTaskId} onPreview={showPreview} />
        )}

        {page === "status" && <StatusPage snapshot={snapshot} locale={locale} />}

        {page === "memory" && (
          <MemoryPage summary={snapshot.memory} locale={locale} onSummary={applyMemorySummary} />
        )}

        {page === "plugins" && (
          <PluginsPage plugins={snapshot.plugins} externalSkills={snapshot.externalSkills} locale={locale} busy={pluginBusy} error={capabilityError || error}
            onInstall={installPlugin} onRefresh={refreshCapabilities} onProbe={probePlugin}
            onEnabled={setPluginEnabled} onRemove={removePlugin} onImportSkill={importExternalSkill}
            onSkillEnabled={setExternalSkillEnabled} onSkillRemove={removeExternalSkill} />
        )}

        {page === "settings" && (
          <SettingsPage draft={settingsDraft} providers={providers} apiKey={apiKey} locale={locale} validating={validating}
            permissionUpdating={permissionUpdating} connected={snapshot.providerConfigured} onDraft={setSettingsDraft} onApiKey={setApiKey}
            onProvider={selectProvider} onPermission={updateExecutionPermission} onSave={saveSettings} />
        )}
      </main>

      {setupRequired && (
        <SetupDialog draft={settingsDraft} providers={providers} apiKey={apiKey} locale={locale} validating={validating}
          permissionUpdating={permissionUpdating} error={error} onDraft={setSettingsDraft} onApiKey={setApiKey}
          onProvider={selectProvider} onPermission={updateExecutionPermission} onSave={saveSettings} />
      )}
      {preview && <PreviewDialog key={`${preview.path}:${preview.revision}`} payload={preview} locale={locale} onClose={() => setPreview(undefined)} />}
      {actionTask && (
        <HumanActionDialog task={actionTask} locale={locale} value={actionAnswer} busy={resuming} error={error}
          onChange={setActionAnswer} onResume={resumeAction}
          onDismiss={() => { setActionAnswer(""); setDismissedActionCheckpointKey(interactiveActionCheckpointKey(actionTask)); }} />
      )}
      {dragActive && (
        <div className="window-drop-overlay" role="status" aria-live="polite">
          <div><Paperclip /><strong>{t.dropAttachments}</strong><span>{t.dropAttachmentHint}</span></div>
        </div>
      )}
    </div>
  );
}

function Header({ page, setPage, busy, queuedCount, locale }: { page: Page; setPage: (page: Page) => void; busy: boolean; queuedCount: number; locale: Locale }) {
  const t = strings(locale);
  const navigation: Array<[Page, typeof MessageCircle, string]> = [
    ["chat", MessageCircle, t.chat], ["threads", MessagesSquare, t.threads], ["status", Activity, t.status],
    ["memory", BrainCircuit, t.memory], ["plugins", Puzzle, t.plugins], ["settings", Settings, t.settings],
  ];
  return <header className="app-header">
    <div className="brand"><BrandMark /><div><div className="brand-title"><strong>{t.appName}</strong><span>v{appVersion}</span></div><small>{t.tagline}</small></div></div>
    <nav aria-label={locale === "en" ? "Primary navigation" : "主导航"}>{navigation.map(([id, Icon, label]) => <button key={id} className={page === id ? "active" : ""}
      aria-current={page === id ? "page" : undefined} aria-label={label} title={label} onClick={() => setPage(id)}><Icon /><span>{label}</span></button>)}</nav>
    <div className={`runtime-state ${busy ? "active" : ""}`}>
      <span className="runtime-pulse" aria-hidden="true" />
      <div><small>{queuedCount > 0 ? `${t.queued} · ${queuedCount}` : "STATE"}</small><strong>{busy ? t.running : t.standby}</strong></div>
    </div>
  </header>;
}

function ThreadsPage({ tasks, events, selected, locale, onSelect, onPreview }: { tasks: TaskRecord[]; events: RuntimeEvent[]; selected?: TaskRecord; locale: Locale; onSelect: (id: string) => void; onPreview: (artifact: ArtifactRecord) => void }) {
  const t = strings(locale);
  const [roleFilter, setRoleFilter] = useState<TaskRole | "all">("all");
  const roots = useMemo(() => tasks.filter((task) => !task.parentTaskId).sort((a, b) => a.updatedAt.localeCompare(b.updatedAt)), [tasks]);
  const rootId = selected?.rootTaskId ?? selected?.id;
  const root = tasks.find((task) => task.id === rootId) ?? selected;
  const participants = useMemo(() => root ? tasks.filter((task) => (task.rootTaskId ?? task.id) === root.id) : [], [root, tasks]);
  const participantIds = useMemo(() => new Set(participants.filter((task) => roleFilter === "all" || task.role === roleFilter).map((task) => task.id)), [participants, roleFilter]);
  const visibleEvents = useMemo(() => events.filter((event) => participantIds.has(event.taskId)).sort((a, b) => a.sequence - b.sequence), [events, participantIds]);

  useEffect(() => setRoleFilter("all"), [root?.id]);

  if (!roots.length) return <EmptyState icon={<MessagesSquare />} text={t.noTasks} />;
  return <section className="threads-page">
    <aside className="thread-list">
      <div className="section-heading"><MessagesSquare /> <strong>{t.threads}</strong><span>{roots.length}</span></div>
      {[...roots].reverse().map((task) => {
        const status = aggregateTaskStatus(task, tasks);
        return <button key={task.id} className={root?.id === task.id ? "selected" : ""} onClick={() => onSelect(task.id)}>
          <StatusGlyph status={status} /><span><strong>{task.title}</strong><small>{statusLabel(status, locale)} · {new Date(task.updatedAt).toLocaleString()}</small></span><ChevronRight />
        </button>;
      })}
    </aside>
    <div className="thread-detail">
      {!root ? <EmptyState icon={<Search />} text={t.selectTask} /> : <>
        <div className="thread-title"><div><small>{statusLabel(aggregateTaskStatus(root, tasks), locale)}</small><h1>{root.title}</h1><p>{participants.length} {t.participants.toLocaleLowerCase()}</p></div><StatusGlyph status={aggregateTaskStatus(root, tasks)} /></div>
        <div className="participant-tabs" aria-label={t.participants}>
          <ParticipantTab role="all" active={roleFilter === "all"} label={t.all} count={participants.length} onSelect={setRoleFilter} />
          <ParticipantTab role="main" active={roleFilter === "main"} label={t.mainRole} count={participants.filter((task) => task.role === "main").length} onSelect={setRoleFilter} />
          <ParticipantTab role="worker" active={roleFilter === "worker"} label={t.workerRole} count={participants.filter((task) => task.role === "worker").length} onSelect={setRoleFilter} />
          <ParticipantTab role="checker" active={roleFilter === "checker"} label={t.checkerRole} count={participants.filter((task) => task.role === "checker").length} onSelect={setRoleFilter} />
        </div>
        <div className="thread-workbench">
          <section className="execution-pane">
            <div className="pane-heading"><Activity /><div><strong>{t.execution}</strong><small>{t.liveDetail}</small></div><span>{visibleEvents.length}</span></div>
            {!visibleEvents.length ? <EmptyState icon={<Activity />} text={t.noEvents} /> : <div className="event-timeline">
              {visibleEvents.map((event) => <ExecutionEvent key={event.id} event={event} task={tasks.find((task) => task.id === event.taskId)} locale={locale} />)}
            </div>}
          </section>
          <aside className="overview-pane">
            <section className="detail-band"><h2><Gauge />{t.goal}</h2>{root.goalSpec ? <><p>{root.goalSpec.objective}</p><TagList values={root.goalSpec.success_criteria} /></> : <p>{root.prompt}</p>}</section>
            <section className="detail-band"><h2><ListChecks />{t.steps}</h2><ol className="steps">{root.steps.map((step) => <li key={step.id}><StatusGlyph status={step.status} /><div><strong>{step.title}</strong><p>{step.detail}</p></div></li>)}</ol></section>
            {participants.length > 1 && <section className="detail-band"><h2><GitBranch />{t.childThreads}<span>{participants.length - 1}</span></h2><div className="child-thread-list">{participants.filter((task) => task.id !== root.id).map((task) => <button key={task.id} onClick={() => setRoleFilter(task.role)}><RoleIcon role={task.role} /><span><strong>{task.participantName}</strong><small>{task.title}</small></span><StatusGlyph status={task.status} /></button>)}</div></section>}
            <section className="detail-band"><h2><FileBox />{t.artifacts}<span>{root.artifacts.length}</span></h2>
              {!root.artifacts.length ? <p className="muted">{locale === "en" ? "No registered artifacts yet." : "暂未登记产出物。"}</p> :
                <div className="artifact-list">{root.artifacts.map((artifact) => <div className="artifact-row" key={artifact.id}><FileText /><div><strong>{artifact.title}</strong><small>{fileName(artifact.path)} · {formatBytes(artifact.sizeBytes)}</small></div><button onClick={() => onPreview(artifact)}><Search />{t.preview}</button></div>)}</div>}
            </section>
            {root.error && <div className="task-error"><CircleAlert />{root.error}</div>}
          </aside>
        </div>
      </>}
    </div>
  </section>;
}

function PluginsPage({ plugins, externalSkills, locale, busy, error, onInstall, onRefresh, onProbe, onEnabled, onRemove, onImportSkill, onSkillEnabled, onSkillRemove }: {
  plugins: PluginRecord[]; externalSkills: ExternalSkillRecord[]; locale: Locale; busy: string; error: string;
  onInstall: () => void; onRefresh: () => void; onProbe: (plugin: PluginRecord) => void;
  onEnabled: (plugin: PluginRecord, enabled: boolean) => void; onRemove: (plugin: PluginRecord) => void;
  onImportSkill: (selection: "manifest" | "directory") => void;
  onSkillEnabled: (skill: ExternalSkillRecord, enabled: boolean) => void; onSkillRemove: (skill: ExternalSkillRecord) => void;
}) {
  const t = strings(locale);
  return <section className="plugins-page">
    <div className="page-heading plugin-heading">
      <Puzzle />
      <div><h1>{t.pluginTitle}</h1><p>{t.pluginSubtitle}</p></div>
      <div className="page-commands">
        <button onClick={onRefresh} disabled={Boolean(busy)}><RefreshCw />{t.refreshPlugins}</button>
        <button onClick={() => onImportSkill("manifest")} disabled={Boolean(busy)}><FileText />{t.importSkillFile}</button>
        <button onClick={() => onImportSkill("directory")} disabled={Boolean(busy)}><FolderOpen />{t.importSkillFolder}</button>
        <button className="primary" onClick={onInstall} disabled={Boolean(busy)}><PackagePlus />{t.installPlugin}</button>
      </div>
    </div>
    {error && <div className="error-strip plugin-error"><CircleAlert size={16} />{error}</div>}
    <div className="plugin-callout skill-bridge-callout"><BrainCircuit /><span>{t.skillBridgeActive}<small>{t.skillBridgeBoundary}</small></span></div>

    <section className="capability-section">
      <div className="capability-section-heading"><div><h2>{t.externalSkillsTitle}</h2><p>{t.externalSkillsSubtitle}</p></div><span>{externalSkills.length}</span></div>
      {!externalSkills.length ? <EmptyState icon={<BrainCircuit />} text={t.noExternalSkills} /> : (
        <div className="external-skill-grid">
          {externalSkills.map((skill) => {
            const state = !skill.available ? t.skillUnavailable : !skill.enabled ? t.skillDisabled : !skill.modelInvocationEnabled ? t.skillModelInvocationOff : t.skillReady;
            const busyKey = `skill:${skill.id}`;
            return <article className={`external-skill-card ${skill.enabled ? "" : "disabled"}`} key={skill.id}>
              <header>
                <span className={`skill-source-icon ${skill.sourceFormat}`}><BrainCircuit /></span>
                <div><div className="plugin-name"><h2>{skill.name}</h2><span className={`skill-source ${skill.sourceFormat}`}>{externalSkillSourceLabel(skill, locale)}</span></div><p>{skill.description || skill.statusDetail}</p></div>
                <span className={`plugin-state ${skill.available && skill.enabled && skill.modelInvocationEnabled ? "ready" : "warning"}`}><span className="dot" />{state}</span>
              </header>
              <div className="plugin-meta skill-meta">
                {skill.compatibility && <span>{t.skillCompatibility}: {skill.compatibility}</span>}
                {skill.license && <span>{t.skillLicense}: {skill.license}</span>}
                <code>{skill.id}</code>
              </div>
              <section>
                <h3>{t.skillAllowedTools}</h3>
                <div className="permission-tags skill-tool-tags">{skill.allowedTools.length ? skill.allowedTools.map((tool) => <span key={tool}><ShieldCheck />{tool}</span>) : <span>{t.skillNoTools}</span>}</div>
              </section>
              <section>
                <h3>{t.skillResources}</h3>
                <div className="skill-resource-summary">
                  <span><Wrench />{t.skillScripts}<strong>{skill.scripts.length}</strong></span>
                  <span><FileText />{t.skillReferences}<strong>{skill.references.length}</strong></span>
                  <span><FileBox />{t.skillAssets}<strong>{skill.assets.length}</strong></span>
                </div>
              </section>
              {!skill.modelInvocationEnabled && <section className="skill-warnings"><h3>{t.skillModelInvocationOff}</h3><p><CircleAlert />{t.skillModelInvocationOffHint}</p></section>}
              {skill.warnings.length > 0 && <section className="skill-warnings"><h3>{t.skillWarnings}</h3>{skill.warnings.map((warning) => <p key={warning}><CircleAlert />{warning}</p>)}</section>}
              <footer>
                <div className="plugin-path" title={skill.manifestPath}><small>{t.skillManifest}</small><code>{skill.manifestPath}</code></div>
                <div className="plugin-actions">
                  <button onClick={() => onSkillEnabled(skill, !skill.enabled)} disabled={busy === busyKey}>{busy === busyKey ? <LoaderCircle className="spin" /> : <RefreshCw />}{skill.enabled ? t.skillDisable : t.skillEnable}</button>
                  <button className="danger" onClick={() => onSkillRemove(skill)} disabled={busy === busyKey}><Trash2 />{t.skillDetach}</button>
                </div>
              </footer>
            </article>;
          })}
        </div>
      )}
      <p className="plugin-install-hint">{t.skillImportHint}</p>
    </section>

    <section className="capability-section native-plugin-section">
      <div className="capability-section-heading"><div><h2>{t.nativePluginsTitle}</h2><p>{t.nativePluginsSubtitle}</p></div><span>{plugins.length}</span></div>
      {plugins.some((plugin) => plugin.id === "lingshu.design-kb" && plugin.available) && <div className="plugin-callout"><PackageCheck /><span>{t.designKbActive}</span></div>}
      {!plugins.length ? <EmptyState icon={<Puzzle />} text={t.noPlugins} /> : (
        <div className="plugin-grid">
          {plugins.map((plugin) => {
            const description = locale === "zh_cn" && plugin.descriptionZh ? plugin.descriptionZh : plugin.description;
            const state = !plugin.available ? t.pluginUnavailable : !plugin.runtimeReady ? t.pluginDegraded : t.pluginReady;
            const permissions = pluginPermissionLabels(plugin, locale);
            return <article className={`plugin-card ${plugin.enabled ? "" : "disabled"}`} key={plugin.id}>
              <header>
                <span className="plugin-icon">{plugin.id === "lingshu.design-kb" ? <PackageCheck /> : <Puzzle />}</span>
                <div><div className="plugin-name"><h2>{plugin.name}</h2><code>v{plugin.version}</code></div><p>{description}</p></div>
                <span className={`plugin-state ${plugin.available && plugin.runtimeReady ? "ready" : "warning"}`}><span className="dot" />{state}</span>
              </header>
              <div className="plugin-meta"><span>{plugin.source === "built_in" ? t.builtIn : t.userPlugin}</span><span>{plugin.enabled ? t.pluginEnabled : t.pluginDisabled}</span><code>{plugin.id}</code></div>
              <section><h3>{t.modelTools}</h3><div className="tool-list">{plugin.tools.map((tool) => <div key={tool.exposedName}><Wrench /><span><strong>{tool.exposedName}</strong><small>{locale === "zh_cn" && tool.descriptionZh ? tool.descriptionZh : tool.description}</small></span></div>)}</div></section>
              <section><h3>{t.pluginPermissions}</h3><div className="permission-tags">{permissions.length ? permissions.map((label) => <span key={label}><ShieldCheck />{label}</span>) : <span>{t.permissionNone}</span>}</div></section>
              <footer>
                <div className="plugin-path" title={plugin.rootPath}><small>{t.pluginLocation}</small><code>{plugin.rootPath || plugin.statusDetail}</code></div>
                <div className="plugin-actions">
                  <button onClick={() => onProbe(plugin)} disabled={busy === plugin.id}>{busy === plugin.id ? <LoaderCircle className="spin" /> : <RefreshCw />}{t.pluginProbe}</button>
                  {plugin.source === "user" && <button onClick={() => onEnabled(plugin, !plugin.enabled)} disabled={busy === plugin.id}>{plugin.enabled ? t.pluginDisable : t.pluginEnable}</button>}
                  {plugin.source === "user" && <button className="danger" onClick={() => onRemove(plugin)} disabled={busy === plugin.id}><Trash2 />{t.pluginRemove}</button>}
                </div>
              </footer>
            </article>;
          })}
        </div>
      )}
      <p className="plugin-install-hint">{t.pluginInstallHint}</p>
    </section>
  </section>;
}

function externalSkillSourceLabel(skill: ExternalSkillRecord, locale: Locale): string {
  const t = strings(locale);
  if (skill.sourceFormat === "codex") return t.skillSourceCodex;
  if (skill.sourceFormat === "claude") return t.skillSourceClaude;
  return t.skillSourceOpen;
}

function pluginPermissionLabels(plugin: PluginRecord, locale: Locale): string[] {
  const t = strings(locale);
  return [
    [plugin.permissions.fileRead, t.permissionFileRead],
    [plugin.permissions.fileWrite, t.permissionFileWrite],
    [plugin.permissions.network, t.permissionNetwork],
    [plugin.permissions.shell, t.permissionShell],
    [plugin.permissions.systemSensitive, t.permissionSensitive],
  ].filter(([enabled]) => enabled).map(([, label]) => String(label));
}

function StatusPage({ snapshot, locale }: { snapshot: RuntimeSnapshot; locale: Locale }) {
  const t = strings(locale);
  const capabilities = [
    [t.internalPreview, snapshot.capabilities.internalPreview], [t.externalOpen, snapshot.capabilities.externalOpen],
    [t.computerControl, snapshot.capabilities.computerControl], [t.realtimePerception, snapshot.capabilities.realtimePerception],
  ] as const;
  return <section className="status-page">
    <div className="status-intro"><div><small>{t.runtimeName.toUpperCase()}</small><h1>{t.kernel} ABI {snapshot.kernelAbiVersion}</h1><p>{t.windowsBoundary}</p></div><ShieldCheck /></div>
    <div className="metrics"><div><span>{t.active}</span><strong>{snapshot.activeTaskId ? snapshot.tasks.find((task) => task.id === snapshot.activeTaskId)?.title : t.none}</strong></div><div><span>{t.queue}</span><strong>{snapshot.queuedTaskCount}</strong></div><div><span>{t.modelChannels}</span><strong>{snapshot.settings.providerName} / {snapshot.settings.model}</strong></div></div>
    <div className="capability-table"><h2>{t.capabilities}</h2>{capabilities.map(([label, enabled]) => <div key={label}><span>{enabled ? <Check /> : <X />}{label}</span><strong className={enabled ? "available" : "unavailable"}>{enabled ? t.available : t.unavailable}</strong></div>)}</div>
  </section>;
}

const memoryKinds: MemoryKind[] = ["conversation", "task", "fact", "preference", "experience", "artifact", "knowledge"];
const memoryTiers: MemoryTier[] = ["hot", "cold"];
const memorySources: MemorySource[] = ["runtime", "user_explicit", "task", "legacy_swift", "platform"];

function MemoryPage({ summary, locale, onSummary }: { summary: MemorySnapshot; locale: Locale; onSummary: (summary: MemorySnapshot) => void }) {
  const t = strings(locale);
  const [filters, setFilters] = useState<MemoryFilters>(emptyMemoryFilters);
  const [entries, setEntries] = useState<MemoryListItem[]>([]);
  const [resultTotal, setResultTotal] = useState(0);
  const [hasMore, setHasMore] = useState(false);
  const [sensitiveCount, setSensitiveCount] = useState(0);
  const [selectedId, setSelectedId] = useState<string>();
  const [revealed, setRevealed] = useState<MemoryListItem>();
  const [editor, setEditor] = useState<{ original?: MemoryEntry; draft: MemoryEditorDraft }>();
  const [deleteTarget, setDeleteTarget] = useState<MemoryEntry>();
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [revealing, setRevealing] = useState(false);
  const [saving, setSaving] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [memoryError, setMemoryError] = useState("");
  const requestSequence = useRef(0);
  const pageFingerprint = useRef("");

  useEffect(() => {
    const concealSensitive = () => {
      setRevealed(undefined);
      setEditor((current) => current?.original?.sensitive ? undefined : current);
    };
    const concealWhenHidden = () => { if (document.visibilityState === "hidden") concealSensitive(); };
    window.addEventListener("blur", concealSensitive);
    document.addEventListener("visibilitychange", concealWhenHidden);
    return () => {
      window.removeEventListener("blur", concealSensitive);
      document.removeEventListener("visibilitychange", concealWhenHidden);
    };
  }, []);

  useEffect(() => {
    if (!revealed || editor || deleteTarget) return;
    const concealOnEscape = (event: KeyboardEvent) => { if (event.key === "Escape") setRevealed(undefined); };
    window.addEventListener("keydown", concealOnEscape);
    return () => window.removeEventListener("keydown", concealOnEscape);
  }, [deleteTarget, editor, revealed]);

  const fetchMemories = useCallback(async (offset = 0) => {
    const sequence = ++requestSequence.current;
    if (offset === 0) setLoading(true);
    else setLoadingMore(true);
    setMemoryError("");
    try {
      const request = {
        query: filters.query.trim(),
        kind: filters.kind === "all" ? undefined : filters.kind,
        tier: filters.tier === "all" ? undefined : filters.tier,
        source: filters.source === "all" ? undefined : filters.source,
        sensitiveVisibility: "redacted" as const,
        offset,
        expectedStateFingerprint: offset > 0 ? pageFingerprint.current : undefined,
        limit: 50,
      };
      const [page, sensitivePage] = await Promise.all([
        listMemory(request),
        offset === 0 ? listMemory({ sensitive: true, sensitiveVisibility: "redacted", limit: 1 }) : Promise.resolve(undefined),
      ]);
      if (sequence !== requestSequence.current) return;
      if (offset === 0) pageFingerprint.current = page.stateFingerprint;
      setEntries((current) => {
        const combined = offset === 0 ? page.items : [...current, ...page.items];
        const seen = new Set<string>();
        return combined.filter((entry) => !seen.has(entry.id) && Boolean(seen.add(entry.id)));
      });
      setResultTotal(page.totalCount);
      setHasMore(page.hasMore);
      if (sensitivePage) setSensitiveCount(sensitivePage.totalCount);
      setSelectedId((current) => {
        if (offset > 0) return current ?? page.items[0]?.id;
        if (current && page.items.some((entry) => entry.id === current)) return current;
        return page.items[0]?.id;
      });
      setRevealed(undefined);
    } catch (reason) {
      if (sequence === requestSequence.current) setMemoryError(String(reason));
    } finally {
      if (sequence === requestSequence.current) {
        setLoading(false);
        setLoadingMore(false);
      }
    }
  }, [filters]);

  // Query changes are slightly delayed so typing does not hammer the local IPC boundary.
  useEffect(() => {
    const timer = window.setTimeout(() => void fetchMemories(0), 220);
    return () => window.clearTimeout(timer);
  }, [fetchMemories]);

  const selected = entries.find((entry) => entry.id === selectedId);
  const selectedForDetail = revealed?.id === selected?.id ? revealed : selected;

  const revealSensitive = async () => {
    if (!selected?.sensitive || !selected.redacted || revealing) return;
    setRevealing(true);
    setMemoryError("");
    try {
      const full = await getMemory({ id: selected.id, sensitiveVisibility: "full" });
      if (full.redacted) throw new Error(locale === "en" ? "The sensitive memory could not be revealed." : "无法显示这条敏感记忆。");
      setRevealed(full);
    } catch (reason) {
      setMemoryError(String(reason));
    } finally {
      setRevealing(false);
    }
  };

  const saveMemory = async (draft: MemoryEditorDraft) => {
    if (!memoryDraftIsValid(draft) || saving) return;
    setSaving(true);
    setMemoryError("");
    try {
      const result = await upsertMemory(memoryUpsertRequest(draft, editor?.original));
      onSummary(result.snapshot);
      setEditor(undefined);
      setRevealed(undefined);
      setSelectedId(result.entry.id);
      await fetchMemories(0);
    } catch (reason) {
      setMemoryError(String(reason));
    } finally {
      setSaving(false);
    }
  };

  const removeMemory = async () => {
    if (!deleteTarget || deleting) return;
    setDeleting(true);
    setMemoryError("");
    try {
      const result = await deleteMemory({
        id: deleteTarget.id,
        ...(deleteTarget.fingerprint ? { expectedFingerprint: deleteTarget.fingerprint } : {}),
        expectedUpdatedAt: deleteTarget.updatedAt,
      });
      onSummary(result.snapshot);
      setDeleteTarget(undefined);
      setRevealed(undefined);
      setSelectedId(undefined);
      await fetchMemories(0);
    } catch (reason) {
      setMemoryError(String(reason));
    } finally {
      setDeleting(false);
    }
  };

  return <section className="memory-page">
    <header className="memory-heading">
      <div className="memory-heading-copy"><span className="memory-heading-icon"><BrainCircuit /></span><div><h1>{t.memoryTitle}</h1><p>{t.memorySubtitle}</p></div></div>
      <div className="memory-primary-actions">
        <button type="button" className="secondary-command" disabled={loading} onClick={() => void fetchMemories(0)}>
          <RefreshCw className={loading ? "spin" : ""} />{loading ? t.memoryRefreshing : t.memoryRefresh}
        </button>
        <button type="button" className="primary-command compact" onClick={() => { setMemoryError(""); setEditor({ draft: newMemoryDraft() }); }}><Plus />{t.memoryNew}</button>
      </div>
    </header>

    <div className="memory-stats" aria-label={locale === "en" ? "Memory summary" : "记忆统计摘要"}>
      <MemoryStat label={t.memoryTotal} value={summary.totalCount} tone="teal" />
      <MemoryStat label={t.memoryHot} value={summary.hotCount} tone="blue" />
      <MemoryStat label={t.memoryCold} value={summary.coldCount} tone="violet" />
      <MemoryStat label={t.memorySensitive} value={sensitiveCount} tone="orange" sensitive />
    </div>

    <div className="memory-controls">
      <label className="memory-search"><Search /><input value={filters.query} placeholder={t.memorySearch} aria-label={t.memorySearch}
        onChange={(event) => setFilters((current) => ({ ...current, query: event.target.value }))} />
        {filters.query && <button type="button" title={t.close} aria-label={t.close} onClick={() => setFilters((current) => ({ ...current, query: "" }))}><X /></button>}
      </label>
      <MemoryFilter label={t.memoryKind} value={filters.kind} onChange={(value) => setFilters((current) => ({ ...current, kind: value as MemoryFilters["kind"] }))}>
        <option value="all">{t.memoryAll}</option>{memoryKinds.map((kind) => <option key={kind} value={kind}>{memoryKindLabel(kind, locale)}</option>)}
      </MemoryFilter>
      <MemoryFilter label={t.memoryTier} value={filters.tier} onChange={(value) => setFilters((current) => ({ ...current, tier: value as MemoryFilters["tier"] }))}>
        <option value="all">{t.memoryAll}</option>{memoryTiers.map((tier) => <option key={tier} value={tier}>{memoryTierLabel(tier, locale)}</option>)}
      </MemoryFilter>
      <MemoryFilter label={t.memorySource} value={filters.source} onChange={(value) => setFilters((current) => ({ ...current, source: value as MemoryFilters["source"] }))}>
        <option value="all">{t.memoryAll}</option>{memorySources.map((source) => <option key={source} value={source}>{memorySourceLabel(source, locale)}</option>)}
      </MemoryFilter>
    </div>

    {memoryError && <div className="memory-error error-strip"><CircleAlert />{memoryError}</div>}

    <div className="memory-workbench">
      <aside className="memory-list-panel">
        <header><div><strong>{t.memoryVisible}</strong><span>{resultTotal} {t.memoryResults}</span></div><small>{entries.length}/{resultTotal}</small></header>
        <div className="memory-list">
          {loading && entries.length === 0 ? <div className="memory-list-loading"><LoaderCircle className="spin" />{t.memoryRefreshing}</div> :
            entries.length === 0 ? <EmptyState icon={<BrainCircuit />} text={t.memoryNoItems} /> : entries.map((entry) => (
              <button type="button" key={entry.id} className={`memory-row ${selectedId === entry.id ? "selected" : ""} ${entry.sensitive ? "sensitive" : ""}`}
                aria-pressed={selectedId === entry.id} onClick={() => { setSelectedId(entry.id); setRevealed(undefined); }}>
                <span className={`memory-kind-dot kind-${entry.kind}`} aria-hidden="true" />
                <span className="memory-row-main">
                  <span className="memory-row-title"><strong>{entry.redacted ? t.memorySensitiveHidden : entry.title}</strong>{entry.sensitive && <LockKeyhole />}</span>
                  <span className="memory-row-preview">{memoryListPreview(entry, t.memorySensitiveHidden, t.memoryNoContent)}</span>
                  <span className="memory-row-meta"><span>{memoryKindLabel(entry.kind, locale)}</span><span>{memoryTierLabel(entry.tier, locale)}</span><time>{formatMemoryDate(entry.updatedAt, locale)}</time></span>
                </span>
                <ChevronRight />
              </button>
            ))}
          {hasMore && <button type="button" className="memory-load-more" disabled={loadingMore} onClick={() => void fetchMemories(entries.length)}>
            {loadingMore ? <LoaderCircle className="spin" /> : <Plus />}{t.memoryLoadMore}
          </button>}
        </div>
      </aside>

      <section className="memory-detail-panel">
        {!selectedForDetail ? <EmptyState icon={<BrainCircuit />} text={t.memorySelect} /> : <>
          <header className="memory-detail-header">
            <div className="memory-detail-title">
              <div className="memory-badges"><span className={`kind-${selectedForDetail.kind}`}>{memoryKindLabel(selectedForDetail.kind, locale)}</span><span>{memoryTierLabel(selectedForDetail.tier, locale)}</span><span>{memorySourceLabel(selectedForDetail.source, locale)}</span></div>
              <h2>{selectedForDetail.redacted ? t.memorySensitiveHidden : selectedForDetail.title}</h2>
              <p>{t.memoryUpdated} {formatMemoryDateTime(selectedForDetail.updatedAt, locale)}</p>
            </div>
            <div className="memory-detail-actions">
              {selectedForDetail.redacted ? <button type="button" title={t.memoryRedactedEditHint} disabled><Pencil />{t.memoryEdit}</button> :
                <button type="button" onClick={() => { setMemoryError(""); setEditor({ original: selectedForDetail, draft: memoryDraftFromEntry(selectedForDetail) }); }}><Pencil />{t.memoryEdit}</button>}
              <button type="button" className="danger" onClick={() => { setMemoryError(""); setDeleteTarget(selectedForDetail); }}><Trash2 />{t.memoryDelete}</button>
            </div>
          </header>

          <div className="memory-detail-scroll">
            {selectedForDetail.redacted ? <section className="memory-sensitive-guard">
              <div className="memory-sensitive-mark"><LockKeyhole /></div><div><strong>{t.memorySensitiveHidden}</strong><p>{t.memorySensitiveListHint}</p><p>{t.memorySensitiveDetailHint}</p>
                <button type="button" disabled={revealing} onClick={() => void revealSensitive()}>{revealing ? <LoaderCircle className="spin" /> : <Eye />}{t.memoryRevealSensitive}</button></div>
            </section> : selectedForDetail.sensitive && <section className="memory-sensitive-guard revealed">
              <div className="memory-sensitive-mark"><Eye /></div><div><strong>{t.memorySensitive}</strong><p>{t.memorySensitiveDetailHint}</p>
                <button type="button" onClick={() => setRevealed(undefined)}><EyeOff />{t.memoryHideSensitive}</button></div>
            </section>}

            {!selectedForDetail.redacted && <>
              <section className="memory-content-card"><h3><FileText />{t.memoryContent}</h3><p>{selectedForDetail.content || t.memoryNoContent}</p></section>
              {selectedForDetail.lastPrompt && <section className="memory-content-card secondary"><h3><MessageCircle />{t.memoryLastPrompt}</h3><p>{selectedForDetail.lastPrompt}</p></section>}
            </>}

            <section className="memory-metadata-grid">
              <MemoryMetric label={t.memoryImportance} value={`${Math.round(selectedForDetail.importance * 100)}%`} />
              <MemoryMetric label={t.memoryConfidence} value={`${Math.round(selectedForDetail.confidence * 100)}%`} />
              <MemoryMetric label={t.memoryAccess} value={String(selectedForDetail.accessCount)} />
              <MemoryMetric label={t.memoryCreated} value={formatMemoryDate(selectedForDetail.createdAt, locale)} />
            </section>

            {!selectedForDetail.redacted && <section className="memory-taxonomy">
              <MemoryTokenGroup label={t.memoryTags} values={selectedForDetail.tags.map((tag) => `#${tag}`)} empty={t.memoryNone} />
              <MemoryTokenGroup label={t.memoryAliases} values={selectedForDetail.aliases} empty={t.memoryNone} />
              {selectedForDetail.taskId && <MemoryTokenGroup label={t.memoryLinkedTask} values={[selectedForDetail.taskId]} empty={t.memoryNone} mono />}
            </section>}
          </div>
        </>}
      </section>
    </div>

    {editor && <MemoryEditorDialog key={editor.original?.id ?? "new-memory"} locale={locale} original={editor.original} draft={editor.draft}
      saving={saving} error={memoryError} onCancel={() => setEditor(undefined)} onSave={saveMemory} />}
    {deleteTarget && <div className="modal-layer memory-modal-layer" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget && !deleting) setDeleteTarget(undefined); }}>
      <section className="memory-confirm-dialog" role="alertdialog" aria-modal="true" aria-labelledby="memory-delete-title" onKeyDown={(event) => handleModalKeyDown(event, deleting, () => setDeleteTarget(undefined))}>
        <span className="memory-confirm-icon"><Trash2 /></span><h2 id="memory-delete-title">{t.memoryDeleteTitle}</h2><p>{t.memoryDeleteBody}</p>
        <strong className="memory-delete-name">{deleteTarget.sensitive ? t.memorySensitiveHidden : deleteTarget.title}</strong>
        {memoryError && <div className="memory-confirm-error error-strip"><CircleAlert />{memoryError}</div>}
        <footer><button type="button" autoFocus disabled={deleting} onClick={() => setDeleteTarget(undefined)}>{t.memoryCancel}</button>
          <button type="button" className="danger" disabled={deleting} onClick={() => void removeMemory()}>{deleting ? <LoaderCircle className="spin" /> : <Trash2 />}{deleting ? t.memoryDeleting : t.memoryDeleteConfirm}</button></footer>
      </section>
    </div>}
  </section>;
}

function MemoryStat({ label, value, tone, sensitive = false }: { label: string; value: number; tone: string; sensitive?: boolean }) {
  return <div className={`memory-stat ${tone}`}><span>{sensitive ? <LockKeyhole /> : tone === "violet" ? <Archive /> : <BrainCircuit />}{label}</span><strong>{value}</strong></div>;
}

function MemoryFilter({ label, value, onChange, children }: { label: string; value: string; onChange: (value: string) => void; children: React.ReactNode }) {
  return <label className="memory-filter"><span>{label}</span><select value={value} onChange={(event) => onChange(event.target.value)}>{children}</select></label>;
}

function MemoryMetric({ label, value }: { label: string; value: string }) {
  return <div><span>{label}</span><strong>{value}</strong></div>;
}

function MemoryTokenGroup({ label, values, empty, mono = false }: { label: string; values: string[]; empty: string; mono?: boolean }) {
  return <div><strong>{label}</strong><span className={`memory-token-row ${mono ? "mono" : ""}`}>{values.length ? values.map((value) => <span key={value}>{value}</span>) : <em>{empty}</em>}</span></div>;
}

function handleModalKeyDown(event: ReactKeyboardEvent<HTMLElement>, busy: boolean, onClose: () => void) {
  if (event.key === "Escape") {
    if (!busy) {
      event.preventDefault();
      onClose();
    }
    return;
  }
  if (event.key !== "Tab") return;
  const focusable = Array.from(event.currentTarget.querySelectorAll<HTMLElement>(
    'button:not([disabled]), input:not([disabled]), textarea:not([disabled]), select:not([disabled]), [tabindex]:not([tabindex="-1"])',
  )).filter((element) => element.getAttribute("aria-hidden") !== "true" && element.offsetParent !== null);
  if (!focusable.length) {
    event.preventDefault();
    return;
  }
  const first = focusable[0];
  const last = focusable[focusable.length - 1];
  if (event.shiftKey && document.activeElement === first) {
    event.preventDefault();
    last.focus();
  } else if (!event.shiftKey && document.activeElement === last) {
    event.preventDefault();
    first.focus();
  }
}

function MemoryEditorDialog({ locale, original, draft: initialDraft, saving, error, onCancel, onSave }: {
  locale: Locale; original?: MemoryEntry; draft: MemoryEditorDraft; saving: boolean; error: string;
  onCancel: () => void; onSave: (draft: MemoryEditorDraft) => void;
}) {
  const t = strings(locale);
  const [draft, setDraft] = useState(initialDraft);
  const submitEditor = (event: FormEvent) => { event.preventDefault(); if (memoryDraftIsValid(draft)) onSave(draft); };
  return <div className="modal-layer memory-modal-layer" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget && !saving) onCancel(); }}>
    <form className="memory-editor-dialog" role="dialog" aria-modal="true" aria-labelledby="memory-editor-title" onSubmit={submitEditor} onKeyDown={(event) => handleModalKeyDown(event, saving, onCancel)}>
      <header><span><BrainCircuit /></span><div><h2 id="memory-editor-title">{original ? t.memoryEditTitle : t.memoryNewTitle}</h2><p>{t.memoryEditorHint}</p></div><button type="button" className="action-close" title={t.close} aria-label={t.close} disabled={saving} onClick={onCancel}><X /></button></header>
      <div className="memory-editor-body">
        {error && <div className="error-strip"><CircleAlert />{error}</div>}
        <div className="memory-editor-grid compact-fields">
          <label>{t.memoryKind}<select value={draft.kind} onChange={(event) => setDraft((current) => ({ ...current, kind: event.target.value as MemoryKind }))}>{memoryEditableKinds(original?.kind).map((kind) => <option key={kind} value={kind}>{memoryKindLabel(kind, locale)}</option>)}</select></label>
          <label>{t.memoryTier}<select value={draft.tier} onChange={(event) => setDraft((current) => ({ ...current, tier: event.target.value as MemoryTier }))}>{memoryTiers.map((tier) => <option key={tier} value={tier}>{memoryTierLabel(tier, locale)}</option>)}</select></label>
        </div>
        <label><span className="memory-field-heading"><span>{t.memoryTitleLabel}</span><output>{memoryTextLength(draft.title)}/{MEMORY_TITLE_MAX_CHARS}</output></span><input aria-label={t.memoryTitleLabel} autoFocus value={draft.title} onChange={(event) => setDraft((current) => ({ ...current, title: truncateMemoryText(event.target.value, MEMORY_TITLE_MAX_CHARS) }))} /></label>
        <label><span className="memory-field-heading"><span>{t.memoryContentLabel}</span><output>{memoryTextLength(draft.content)}/{MEMORY_CONTENT_MAX_CHARS}</output></span><textarea aria-label={t.memoryContentLabel} value={draft.content} onChange={(event) => setDraft((current) => ({ ...current, content: truncateMemoryText(event.target.value, MEMORY_CONTENT_MAX_CHARS) }))} /></label>
        <div className="memory-editor-grid">
          <label><span className="memory-field-heading"><span>{t.memoryTags}</span><output>{memoryTaxonomyCount(draft.tagsText)}/{MEMORY_TAXONOMY_MAX_ITEMS}</output></span><input value={draft.tagsText} placeholder={t.memoryTagsHint} onChange={(event) => setDraft((current) => ({ ...current, tagsText: event.target.value }))} /></label>
          <label><span className="memory-field-heading"><span>{t.memoryAliases}</span><output>{memoryTaxonomyCount(draft.aliasesText)}/{MEMORY_TAXONOMY_MAX_ITEMS}</output></span><input value={draft.aliasesText} placeholder={t.memoryAliasesHint} onChange={(event) => setDraft((current) => ({ ...current, aliasesText: event.target.value }))} /></label>
        </div>
        <div className="memory-editor-grid memory-sliders">
          <label><span>{t.memoryImportance}<output>{Math.round(draft.importance * 100)}%</output></span><input type="range" min="0" max="1" step="0.05" value={draft.importance} onChange={(event) => setDraft((current) => ({ ...current, importance: Number(event.target.value) }))} /></label>
          <label><span>{t.memoryConfidence}<output>{Math.round(draft.confidence * 100)}%</output></span><input type="range" min="0" max="1" step="0.05" value={draft.confidence} onChange={(event) => setDraft((current) => ({ ...current, confidence: Number(event.target.value) }))} /></label>
        </div>
        <label className={`memory-sensitive-toggle ${draft.sensitive ? "active" : ""}`}><input type="checkbox" checked={draft.sensitive} onChange={(event) => setDraft((current) => ({ ...current, sensitive: event.target.checked }))} /><LockKeyhole /><span><strong>{t.memoryMarkSensitive}</strong><small>{t.memoryMarkSensitiveHint}</small></span></label>
        {original?.sensitive && !draft.sensitive && <div className="memory-unmask-warning"><CircleAlert /><span>{t.memoryUnmarkSensitiveWarning}</span></div>}
      </div>
      <footer><button type="button" disabled={saving} onClick={onCancel}>{t.memoryCancel}</button><button type="submit" className="primary" disabled={saving || !memoryDraftIsValid(draft)}>{saving ? <LoaderCircle className="spin" /> : <Save />}{saving ? t.memorySaving : t.memorySave}</button></footer>
    </form>
  </div>;
}

function memoryKindLabel(kind: MemoryKind, locale: Locale): string {
  const labels: Record<MemoryKind, [string, string]> = {
    conversation: ["对话", "Conversation"], task: ["任务", "Task"], fact: ["事实", "Fact"], preference: ["偏好", "Preference"],
    experience: ["经验", "Experience"], artifact: ["产出物", "Artifact"], knowledge: ["知识", "Knowledge"],
  };
  return labels[kind][locale === "en" ? 1 : 0];
}

function memoryTierLabel(tier: MemoryTier, locale: Locale): string {
  return tier === "hot" ? (locale === "en" ? "Hot" : "热记忆") : (locale === "en" ? "Cold" : "冷记忆");
}

function memorySourceLabel(source: MemorySource, locale: Locale): string {
  const labels: Record<MemorySource, [string, string]> = {
    runtime: ["运行时", "Runtime"], user_explicit: ["用户明确记录", "User explicit"], task: ["任务沉淀", "Task"],
    legacy_swift: ["旧版 macOS 导入", "Legacy macOS import"], platform: ["平台", "Platform"],
  };
  return labels[source][locale === "en" ? 1 : 0];
}

function formatMemoryDate(value: string, locale: Locale): string {
  const date = new Date(value);
  return Number.isNaN(date.valueOf()) ? value : date.toLocaleDateString(locale === "en" ? "en-US" : "zh-CN", { month: "short", day: "numeric", year: "numeric" });
}

function formatMemoryDateTime(value: string, locale: Locale): string {
  const date = new Date(value);
  return Number.isNaN(date.valueOf()) ? value : date.toLocaleString(locale === "en" ? "en-US" : "zh-CN", { dateStyle: "medium", timeStyle: "short" });
}

interface SettingsProps {
  draft: RuntimeSettings; providers: ProviderPreset[]; apiKey: string; locale: Locale; validating: boolean; connected?: boolean;
  permissionUpdating: boolean;
  onDraft: (settings: RuntimeSettings) => void; onApiKey: (key: string) => void; onProvider: (id: string) => void;
  onPermission: (mode: ExecutionPermissionMode) => void; onSave: () => void;
}

function SettingsPage(props: SettingsProps) {
  const t = strings(props.locale);
  return <section className="settings-page">
    <div className="page-heading"><Settings /><div><h1>{t.modelChannels}</h1><p>{props.connected ? t.connected : t.disconnected}</p></div></div>
    <SettingsForm {...props} />
  </section>;
}

function SettingsForm({ draft, providers, apiKey, locale, validating, permissionUpdating, onDraft, onApiKey, onProvider, onPermission, onSave }: SettingsProps) {
  const t = strings(locale);
  const selected = providers.find((provider) => provider.id === draft.providerId);
  return <div className="settings-form">
    <label>{t.language}<select value={draft.locale} onChange={(event) => onDraft({ ...draft, locale: event.target.value as Locale })}><option value="zh_cn">{t.chinese}</option><option value="en">{t.english}</option></select></label>
    <label>{t.provider}<select value={draft.providerId} onChange={(event) => onProvider(event.target.value)}>{providers.map((provider) => <option key={provider.id} value={provider.id}>{provider.name} · {provider.region}</option>)}</select></label>
    <label>{t.model}<input value={draft.model} onChange={(event) => onDraft({ ...draft, model: event.target.value })} list="model-options" /><datalist id="model-options">{selected?.defaultModels.map((model) => <option key={model} value={model} />)}</datalist></label>
    <label>{t.loopEngine}<select value={draft.loopEngine} onChange={(event) => onDraft({ ...draft, loopEngine: event.target.value as RuntimeSettings["loopEngine"] })}><option value="grok">{t.grokLoop}</option><option value="codex">{t.codexLoop}</option></select></label>
    <label>{t.endpoint}<input value={draft.endpoint} onChange={(event) => onDraft({ ...draft, endpoint: event.target.value })} /></label>
    <label>{t.token}<input type="password" value={apiKey} placeholder="••••••••••••••••" onChange={(event) => onApiKey(event.target.value)} /><small>{t.apiHint}</small></label>
    <label>{t.workspace}<input value={draft.workspace} onChange={(event) => onDraft({ ...draft, workspace: event.target.value })} /></label>
    <label>{t.executionPermission}
      <PermissionSelector mode={draft.executionPermissionMode} locale={locale} disabled={permissionUpdating} onChange={onPermission} />
      <small>{draft.executionPermissionMode === "full_access" ? t.fullAccessHint : t.sandboxHint}</small>
    </label>
    <button className="primary-command" onClick={onSave} disabled={validating}>{validating ? <LoaderCircle className="spin" /> : <Play />}{validating ? t.validating : t.saveValidate}</button>
  </div>;
}

function PermissionSelector({ mode, locale, compact = false, disabled, onChange }: {
  mode: ExecutionPermissionMode; locale: Locale; compact?: boolean; disabled: boolean;
  onChange: (mode: ExecutionPermissionMode) => void;
}) {
  const t = strings(locale);
  return <span className={`permission-selector ${compact ? "compact" : ""} ${mode === "full_access" ? "full" : ""}`}>
    <ShieldCheck />
    <select aria-label={t.executionPermission} value={mode} disabled={disabled}
      onChange={(event) => onChange(event.target.value as ExecutionPermissionMode)}>
      <option value="sandbox">{t.sandbox}</option>
      <option value="full_access">{t.fullAccess}</option>
    </select>
  </span>;
}

function SetupDialog(props: SettingsProps & { error: string }) {
  const t = strings(props.locale);
  return <div className="modal-layer setup-layer"><div className="setup-dialog" role="dialog" aria-modal="true" aria-labelledby="setup-title">
    <div className="setup-mark"><BrandMark /></div><h1 id="setup-title">{t.firstRunTitle}</h1><p>{t.firstRunBody}</p>
    <SettingsForm {...props} />
    {props.error && <div className="error-strip"><CircleAlert />{props.error}</div>}
  </div></div>;
}

function HumanActionDialog({ task, locale, value, busy, error, onChange, onResume, onDismiss }: { task: TaskRecord; locale: Locale; value: string; busy: boolean; error: string; onChange: (value: string) => void; onResume: () => void; onDismiss: () => void }) {
  const t = strings(locale);
  useEffect(() => {
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape" && !busy) onDismiss();
    };
    window.addEventListener("keydown", closeOnEscape);
    return () => window.removeEventListener("keydown", closeOnEscape);
  }, [busy, onDismiss]);
  return <div className="modal-layer action-layer"><div className="action-dialog" role="dialog" aria-modal="true" aria-labelledby="action-title">
    <button type="button" className="action-close" aria-label={t.close} title={t.close} disabled={busy} onClick={onDismiss}><X /></button>
    <header><div className="action-mark"><UserRound /></div><div><h1 id="action-title">{t.actionRequired}</h1><p>{t.actionBody}</p></div></header>
    <section><div className="action-actor"><RoleIcon role={task.role} /><span>{task.participantName}</span></div><MarkdownContent>{task.pendingQuestion ?? task.summary}</MarkdownContent></section>
    <textarea autoFocus value={value} onChange={(event) => onChange(event.target.value)} placeholder={t.answerPlaceholder}
      onKeyDown={(event) => { if ((event.ctrlKey || event.metaKey) && event.key === "Enter") onResume(); }} />
    {error && <div className="error-strip"><CircleAlert />{error}</div>}
    <div className="action-footer">
      <button type="button" className="action-dismiss" disabled={busy} onClick={onDismiss}>{t.handleLater}</button>
      <button type="button" className="action-resume" disabled={busy || !value.trim()} onClick={onResume}>{busy ? <LoaderCircle className="spin" /> : <Check />}{t.resume}</button>
    </div>
  </div></div>;
}

function ParticipantTab({ role, active, label, count, onSelect }: { role: TaskRole | "all"; active: boolean; label: string; count: number; onSelect: (role: TaskRole | "all") => void }) {
  return <button className={active ? "active" : ""} onClick={() => onSelect(role)}><RoleIcon role={role} /><span>{label}</span><small>{count}</small></button>;
}

function ExecutionEvent({ event, task, locale }: { event: RuntimeEvent; task?: TaskRecord; locale: Locale }) {
  const body = formatEventDetail(event.detail);
  const hasBody = body.trim().length > 0;
  const [expanded, setExpanded] = useState(event.state === "running" || event.state === "blocked" || event.kind === "reasoning" || event.kind === "result");
  useEffect(() => { if (event.state === "running" || event.state === "blocked") setExpanded(true); }, [event.state]);
  return <article className={`execution-event ${event.kind} ${event.state}`}>
    <div className="event-rail"><EventStateIcon event={event} /></div>
    <div className="event-main">
      <header><span className="event-kind"><EventIcon kind={event.kind} />{event.title}</span><time><Clock3 />{new Date(event.updatedAt).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" })}</time></header>
      <div className="event-actor"><RoleIcon role={task?.role ?? "main"} /><strong>{localizedActor(event.actor || task?.participantName, locale)}</strong>{task && <small>{roleLabel(task.role, locale)}</small>}</div>
      {hasBody && <details open={expanded} onToggle={(toggleEvent) => setExpanded(toggleEvent.currentTarget.open)}>
        <summary>{locale === "en" ? "Details" : "明细"}</summary>
        {event.kind === "tool" || event.kind === "delegation" ? <pre>{body}</pre> : <div className="event-markdown markdown-body"><MarkdownContent>{body}</MarkdownContent></div>}
      </details>}
    </div>
  </article>;
}

function EventIcon({ kind }: { kind: RuntimeEvent["kind"] }) {
  if (kind === "reasoning") return <BrainCircuit />;
  if (kind === "tool") return <Wrench />;
  if (kind === "delegation") return <GitBranch />;
  if (kind === "plan") return <ListChecks />;
  if (kind === "human_interaction") return <UserRound />;
  if (kind === "warning") return <CircleAlert />;
  if (kind === "result") return <Check />;
  return <Bot />;
}

function EventStateIcon({ event }: { event: RuntimeEvent }) {
  if (event.state === "running") return <LoaderCircle className="spin" />;
  if (event.state === "completed") return <Check />;
  if (event.state === "blocked") return <UserRound />;
  if (event.state === "cancelled") return <Square />;
  return <X />;
}

function RoleIcon({ role }: { role: TaskRole | "all" }) {
  if (role === "worker") return <Wrench />;
  if (role === "checker") return <ShieldCheck />;
  if (role === "all") return <MessagesSquare />;
  return <Bot />;
}

function BrandMark() {
  return <div className="brand-mark" aria-hidden="true"><img src="/brand/nous-orb.svg" alt="" /></div>;
}

function localizedActor(actor: string | undefined, locale: Locale): string {
  if (!actor || ["lingshu", "nous", "灵枢"].includes(actor.trim().toLocaleLowerCase())) {
    return strings(locale).appName;
  }
  return actor;
}

function PreviewDialog({ payload, locale, onClose }: { payload: PreviewPayload; locale: Locale; onClose: () => void }) {
  const t = strings(locale);
  useEffect(() => {
    const closeOnEscape = (event: KeyboardEvent) => { if (event.key === "Escape") onClose(); };
    window.addEventListener("keydown", closeOnEscape);
    return () => window.removeEventListener("keydown", closeOnEscape);
  }, [onClose]);
  return <div className="modal-layer"><div className="preview-dialog" role="dialog" aria-modal="true" aria-labelledby="preview-title">
    <header><div><FileText /><strong id="preview-title">{payload.name}</strong></div><div className="preview-actions"><button onClick={() => void runtimeInvoke("open_external", { path: payload.path })}><ExternalLink />{t.openExternal}</button><button onClick={() => void runtimeInvoke("reveal_path", { path: payload.path })}><FolderOpen />{t.reveal}</button><button className="icon-button" title={t.close} aria-label={t.close} onClick={onClose}><X /></button></div></header>
    <div className="preview-content"><PreviewBody payload={payload} unsupported={t.unsupported} presentationOutline={t.presentationOutline}
      previewLoading={t.previewLoading} previewRenderFailed={t.previewRenderFailed} /></div>
  </div></div>;
}

function PreviewBody({ payload, unsupported, presentationOutline, previewLoading, previewRenderFailed }: {
  payload: PreviewPayload;
  unsupported: string;
  presentationOutline: string;
  previewLoading: string;
  previewRenderFailed: string;
}) {
  if (payload.kind === "image") return <img className="image-preview" src={payload.content} alt={payload.name} />;
  if (payload.kind === "pdf") return <PdfCanvasPreview source={payload.content} revision={payload.revision} name={payload.name}
    loadingLabel={previewLoading} errorLabel={previewRenderFailed} />;
  if (payload.kind === "html") return <iframe className="html-preview" sandbox="" srcDoc={payload.content} title={payload.name} />;
  if (payload.kind === "markdown") return <div className="document-preview markdown-body"><MarkdownContent>{payload.content}</MarkdownContent></div>;
  if (payload.kind === "presentation" && payload.faithful && payload.renderedContent && payload.renderedMimeType === "application/pdf") {
    return <PdfCanvasPreview source={payload.renderedContent} revision={payload.revision} name={payload.name}
      loadingLabel={previewLoading} errorLabel={previewRenderFailed}
      fallback={<PresentationOutline payload={payload} note={presentationOutline} />} />;
  }
  if (payload.kind === "presentation") return <PresentationOutline payload={payload} note={presentationOutline} />;
  if (payload.kind === "spreadsheet") return <div className="spreadsheet-preview">{payload.sections.map((section, sheetIndex) => {
    const [title, ...lines] = section.split("\n");
    const rows = lines.map((line) => line.split("\t"));
    return <section key={`${sheetIndex}-${title}`}><h2>{title}</h2><div className="spreadsheet-table-wrap"><table><tbody>{rows.map((row, rowIndex) => <tr key={`${sheetIndex}-${rowIndex}`}>{row.map((cell, cellIndex) => rowIndex === 0 ? <th key={cellIndex}>{cell}</th> : <td key={cellIndex}>{cell}</td>)}</tr>)}</tbody></table></div></section>;
  })}</div>;
  if (payload.kind === "document") return <div className="document-preview">{payload.sections.map((section, index) => index === 0 ? <h1 key={index}>{section}</h1> : <p key={index}>{section}</p>)}</div>;
  if (["text", "code"].includes(payload.kind)) return <pre className="code-preview">{payload.content}</pre>;
  return <EmptyState icon={<FileBox />} text={unsupported} />;
}

function PresentationOutline({ payload, note }: { payload: PreviewPayload; note: string }) {
  return <div className="presentation-outline"><p className="preview-fallback-note">{note}</p>{payload.sections.map((section, index) => {
    const [title, ...body] = section.split("\n");
    return <section key={`${index}-${title}`}><small>{String(index + 1).padStart(2, "0")}</small><div><h2>{title || `${index + 1}`}</h2><ul>{body.map((line, lineIndex) => <li key={`${lineIndex}-${line}`}>{line}</li>)}</ul></div></section>;
  })}</div>;
}

function PdfCanvasPreview({ source, revision, name, loadingLabel, errorLabel, fallback }: {
  source: string;
  revision: string;
  name: string;
  loadingLabel: string;
  errorLabel: string;
  fallback?: React.ReactNode;
}) {
  const [document, setDocument] = useState<PDFDocumentProxy>();
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    let disposed = false;
    setDocument(undefined);
    setFailed(false);

    let pdfBytes: Uint8Array;
    try {
      pdfBytes = decodePdfDataUri(source);
    } catch {
      setFailed(true);
      return;
    }

    let loadingTask: PDFDocumentLoadingTask | undefined;
    void import("pdfjs-dist").then(({ getDocument, GlobalWorkerOptions }) => {
      if (disposed) return undefined;
      GlobalWorkerOptions.workerSrc = pdfWorkerUrl;
      loadingTask = getDocument({ data: pdfBytes });
      return loadingTask.promise;
    }).then((pdf) => {
      if (!pdf) return;
      if (disposed) {
        void pdf.destroy();
        return;
      }
      setDocument(pdf);
    }).catch(() => {
      if (!disposed) setFailed(true);
    });

    return () => {
      disposed = true;
      void loadingTask?.destroy();
    };
  }, [source, revision]);

  if (failed && fallback) return <>{fallback}</>;
  return <div className="pdf-canvas-shell">
    {!document && !failed && <div className="preview-render-state" role="status"><LoaderCircle className="spin" />{loadingLabel}</div>}
    {failed && <div className="preview-render-state error" role="alert"><CircleAlert />{errorLabel}</div>}
    {document && <div className="pdf-canvas-pages">
      {Array.from({ length: document.numPages }, (_, index) => (
        <PdfCanvasPage key={`${revision}:${index + 1}`} document={document} pageNumber={index + 1} name={name} />
      ))}
    </div>}
  </div>;
}

function PdfCanvasPage({ document, pageNumber, name }: { document: PDFDocumentProxy; pageNumber: number; name: string }) {
  const host = useRef<HTMLElement>(null);
  const canvas = useRef<HTMLCanvasElement>(null);
  const [visible, setVisible] = useState(pageNumber <= 2);
  const [ratio, setRatio] = useState(16 / 9);
  const [rendering, setRendering] = useState(pageNumber <= 2);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    if (visible) return;
    const node = host.current;
    if (!node || typeof IntersectionObserver === "undefined") {
      setVisible(true);
      return;
    }
    const observer = new IntersectionObserver(([entry]) => {
      if (!entry.isIntersecting) return;
      setVisible(true);
      observer.disconnect();
    }, { rootMargin: "900px 0px" });
    observer.observe(node);
    return () => observer.disconnect();
  }, [visible]);

  useEffect(() => {
    if (!visible) return;
    let disposed = false;
    let renderTask: RenderTask | undefined;
    setRendering(true);
    setFailed(false);

    void document.getPage(pageNumber).then((page) => {
      if (disposed) return;
      const baseViewport = page.getViewport({ scale: 1 });
      setRatio(baseViewport.width / baseViewport.height);
      const hostWidth = Math.max(1, Math.min(1180, host.current?.clientWidth ?? baseViewport.width));
      const cssScale = hostWidth / baseViewport.width;
      const outputScale = Math.min(window.devicePixelRatio || 1, 2);
      const viewport = page.getViewport({ scale: cssScale * outputScale });
      const target = canvas.current;
      if (!target) return;
      target.width = Math.ceil(viewport.width);
      target.height = Math.ceil(viewport.height);
      target.style.width = `${Math.ceil(baseViewport.width * cssScale)}px`;
      target.style.height = `${Math.ceil(baseViewport.height * cssScale)}px`;
      renderTask = page.render({ canvas: target, viewport, background: "#ffffff" });
      return renderTask.promise;
    }).then(() => {
      if (!disposed) setRendering(false);
    }).catch((reason: unknown) => {
      const cancelled = reason instanceof Error && reason.name === "RenderingCancelledException";
      if (!disposed && !cancelled) {
        setRendering(false);
        setFailed(true);
      }
    });

    return () => {
      disposed = true;
      renderTask?.cancel();
    };
  }, [document, pageNumber, visible]);

  return <article ref={host} className="pdf-canvas-page" style={{ aspectRatio: `${ratio}` }}>
    <canvas ref={canvas} aria-label={`${name} · ${pageNumber}`} />
    {rendering && visible && <div className="preview-page-loading"><LoaderCircle className="spin" /></div>}
    {failed && <div className="preview-page-loading error"><CircleAlert /></div>}
  </article>;
}

function EmptyState({ icon, text }: { icon: React.ReactNode; text: string }) { return <div className="empty-state">{icon}<p>{text}</p></div>; }
function MarkdownContent({ children }: { children: string }) {
  return <ReactMarkdown remarkPlugins={[remarkGfm]} components={markdownComponents}>{normalizeMarkdownTables(children)}</ReactMarkdown>;
}
function StatusGlyph({ status }: { status: TaskStatus }) {
  const visible = recoverableStatus(status);
  if (visible === "completed") return <Check className="status-glyph done" />;
  if (visible === "cancelled") return <Square className="status-glyph" />;
  if (visible === "needs_user_action") return <CircleAlert className="status-glyph active" />;
  return <LoaderCircle className="status-glyph spin active" />;
}
function TagList({ values }: { values: string[] }) { return <ul className="tag-list">{values.map((value) => <li key={value}>{value}</li>)}</ul>; }
function fileName(path: string) { return path.split(/[\\/]/).at(-1) ?? path; }
async function writeClipboardText(text: string): Promise<void> {
  if (navigator.clipboard?.writeText) {
    try {
      await navigator.clipboard.writeText(text);
      return;
    } catch {
      // WebView2 can expose the Clipboard API while denying a particular write. Fall through to
      // the selection-based path so the visible copy action still works in that configuration.
    }
  }
  const fallback = document.createElement("textarea");
  fallback.value = text;
  fallback.setAttribute("readonly", "");
  fallback.style.position = "fixed";
  fallback.style.opacity = "0";
  document.body.appendChild(fallback);
  fallback.select();
  const copied = document.execCommand("copy");
  fallback.remove();
  if (!copied) throw new Error("clipboard unavailable");
}
function formatBytes(value: number) { return value < 1024 ? `${value} B` : value < 1024 * 1024 ? `${(value / 1024).toFixed(1)} KB` : `${(value / 1024 / 1024).toFixed(1)} MB`; }
function statusLabel(status: TaskStatus, locale: Locale) { const t = strings(locale); const visible = recoverableStatus(status); if (visible === "completed") return t.completed; if (visible === "cancelled") return t.cancelled; if (visible === "queued") return t.queued; if (visible === "needs_user_action") return t.blocked; if (visible === "needs_recovery") return t.recovering; return t.running; }
function roleLabel(role: TaskRole, locale: Locale) { const t = strings(locale); if (role === "worker") return t.workerRole; if (role === "checker") return t.checkerRole; return t.mainRole; }

function aggregateTaskStatus(root: TaskRecord, tasks: TaskRecord[]): TaskStatus {
  // A terminal main task is authoritative. Descendants are execution detail and must not turn a
  // delivered task back into "running" while their final projection is still arriving.
  const rootStatus = recoverableStatus(root.status);
  if (terminalStatuses.has(rootStatus)) return rootStatus;
  const related = tasks.filter((task) => (task.rootTaskId ?? task.id) === root.id);
  if (related.some((task) => recoverableStatus(task.status) === "needs_user_action")) return "needs_user_action";
  if (related.some((task) => recoverableStatus(task.status) === "needs_recovery")) return "needs_recovery";
  if (related.some((task) => ["understanding", "running"].includes(task.status))) return "running";
  if (related.some((task) => task.status === "queued")) return "queued";
  return rootStatus;
}

function latestEventForThread(snapshot: RuntimeSnapshot, threadId: string): RuntimeEvent | undefined {
  const root = snapshot.tasks.find((task) => task.id === threadId);
  if (!root) return undefined;
  const ids = new Set(snapshot.tasks.filter((task) => (task.rootTaskId ?? task.id) === (root.rootTaskId ?? root.id)).map((task) => task.id));
  return [...snapshot.events].reverse().find((event) => ids.has(event.taskId));
}

function shouldShowExecution(snapshot: RuntimeSnapshot, threadId: string): boolean {
  const task = snapshot.tasks.find((candidate) => candidate.id === threadId);
  if (!task) return false;
  if (task.goalSpec?.output_mode && task.goalSpec.output_mode !== "chat_reply") return true;
  const ids = new Set(snapshot.tasks.filter((candidate) => (candidate.rootTaskId ?? candidate.id) === (task.rootTaskId ?? task.id)).map((candidate) => candidate.id));
  return snapshot.events.some((event) => ids.has(event.taskId) && ["tool", "delegation", "human_interaction"].includes(event.kind));
}

function formatEventDetail(detail: string): string {
  const trimmed = detail.trim();
  if (!trimmed) return "";
  try { return JSON.stringify(JSON.parse(trimmed), null, 2); } catch { return trimmed; }
}
