import { FormEvent, type DragEvent as ReactDragEvent, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import ReactMarkdown, { type Components } from "react-markdown";
import remarkGfm from "remark-gfm";
import type { PDFDocumentLoadingTask, PDFDocumentProxy, RenderTask } from "pdfjs-dist";
import pdfWorkerUrl from "pdfjs-dist/build/pdf.worker.min.mjs?url";
import {
  Activity, Bot, BrainCircuit, Check, ChevronRight, CircleAlert, Clock3, ExternalLink,
  FileBox, FileText, FolderOpen, Gauge, GitBranch, ListChecks, LoaderCircle, MessageCircle,
  MessagesSquare, PackageCheck, PackagePlus, Paperclip, Play, Puzzle, RefreshCw, Search, Send,
  Settings, ShieldCheck, Square, Trash2, UserRound, Wrench, X,
} from "lucide-react";
import { executionLinkLabel, strings } from "./i18n";
import { chooseFiles, choosePluginManifest, hasNativeBridge, listenForWindowFileDrops, runtimeInvoke } from "./bridge";
import { browserDroppedFilePaths, mergeAttachmentPaths } from "./attachments";
import { projectChatBubble } from "./chatProjection";
import { projectConversationMessages, type PendingSubmission } from "./conversationProjection";
import { findInteractiveActionTask, findVisibleInteractiveActionTask, interactiveActionCheckpointKey } from "./humanAction";
import { normalizeMarkdownTables } from "./markdown";
import { decodePdfDataUri } from "./pdf";
import { SnapshotGate } from "./snapshotGate";
import packageMetadata from "../package.json";
import type {
  ArtifactRecord, ChatMessage, ExecutionPermissionMode, Locale, Page, PluginRecord, PreviewPayload, ProviderPreset, RuntimeSettings,
  RuntimeEvent, RuntimeSnapshot, TaskRecord, TaskRole, TaskStatus,
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
  const [dragActive, setDragActive] = useState(false);
  const messageScroll = useRef<HTMLDivElement>(null);
  const composerInput = useRef<HTMLTextAreaElement>(null);
  const keepAtBottom = useRef(true);
  const previousPage = useRef<Page>(page);
  const previewRequest = useRef(0);
  const snapshotGate = useRef(new SnapshotGate());
  const refreshInFlight = useRef<Promise<void> | undefined>(undefined);
  const refreshAgain = useRef(false);

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

  const applyMutationSnapshot = useCallback((next: RuntimeSnapshot) => {
    snapshotGate.current.commitMutation();
    setSnapshot(next);
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
    setError("");
    try {
      await runtimeInvoke<PluginRecord>("install_plugin", { manifestPath });
      await refresh();
    } catch (reason) {
      setError(String(reason));
    } finally {
      setPluginBusy("");
    }
  };

  const setPluginEnabled = async (plugin: PluginRecord, enabled: boolean) => {
    setPluginBusy(plugin.id);
    setError("");
    try {
      await runtimeInvoke<PluginRecord>("set_plugin_enabled", { id: plugin.id, enabled });
      await refresh();
    } catch (reason) {
      setError(String(reason));
    } finally {
      setPluginBusy("");
    }
  };

  const probePlugin = async (plugin: PluginRecord) => {
    setPluginBusy(plugin.id);
    setError("");
    try {
      await runtimeInvoke<PluginRecord>("probe_plugin", { id: plugin.id });
      await refresh();
    } catch (reason) {
      setError(String(reason));
    } finally {
      setPluginBusy("");
    }
  };

  const removePlugin = async (plugin: PluginRecord) => {
    const confirmed = window.confirm(locale === "en" ? `Remove ${plugin.name}?` : `确认卸载 ${plugin.name}？`);
    if (!confirmed) return;
    setPluginBusy(plugin.id);
    setError("");
    try {
      await runtimeInvoke("remove_plugin", { id: plugin.id });
      await refresh();
    } catch (reason) {
      setError(String(reason));
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
                const messageAttachments = attachmentPathsForMessage(snapshot, message);
                const messageTask = message.threadId
                  ? snapshot.tasks.find((task) => task.id === message.threadId)
                  : undefined;
                const bubble = projectChatBubble(
                  message,
                  message.threadId ? latestEventForThread(snapshot, message.threadId) : undefined,
                  locale,
                );
                return <article key={bubble.key} className={`message ${message.role}`}>
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
                onKeyDown={(event) => { if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); event.currentTarget.form?.requestSubmit(); } }} />
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

        {page === "plugins" && (
          <PluginsPage plugins={snapshot.plugins} locale={locale} busy={pluginBusy} error={error}
            onInstall={installPlugin} onRefresh={refresh} onProbe={probePlugin}
            onEnabled={setPluginEnabled} onRemove={removePlugin} />
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
    ["plugins", Puzzle, t.plugins], ["settings", Settings, t.settings],
  ];
  return <header className="app-header">
    <div className="brand"><BrandMark /><div><div className="brand-title"><strong>{t.appName}</strong><span>v{appVersion}</span></div><small>{t.tagline}</small></div></div>
    <nav>{navigation.map(([id, Icon, label]) => <button key={id} className={page === id ? "active" : ""} onClick={() => setPage(id)}><Icon />{label}</button>)}</nav>
    <div className="runtime-state"><small>{queuedCount > 0 ? `${t.queued} · ${queuedCount}` : "STATE"}</small><strong className={busy ? "active" : ""}>{busy ? t.running : t.standby}</strong></div>
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

function PluginsPage({ plugins, locale, busy, error, onInstall, onRefresh, onProbe, onEnabled, onRemove }: {
  plugins: PluginRecord[]; locale: Locale; busy: string; error: string;
  onInstall: () => void; onRefresh: () => void; onProbe: (plugin: PluginRecord) => void;
  onEnabled: (plugin: PluginRecord, enabled: boolean) => void; onRemove: (plugin: PluginRecord) => void;
}) {
  const t = strings(locale);
  return <section className="plugins-page">
    <div className="page-heading plugin-heading">
      <Puzzle />
      <div><h1>{t.pluginTitle}</h1><p>{t.pluginSubtitle}</p></div>
      <div className="page-commands">
        <button onClick={onRefresh} disabled={Boolean(busy)}><RefreshCw />{t.refreshPlugins}</button>
        <button className="primary" onClick={onInstall} disabled={Boolean(busy)}><PackagePlus />{t.installPlugin}</button>
      </div>
    </div>
    {error && <div className="error-strip plugin-error"><CircleAlert size={16} />{error}</div>}
    <div className="plugin-callout"><BrainCircuit /><span>{t.designKbActive}</span></div>
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
              <span className={`plugin-state ${plugin.available && plugin.runtimeReady ? "ready" : "warning"}`}>
                <span className="dot" />{state}
              </span>
            </header>
            <div className="plugin-meta">
              <span>{plugin.source === "built_in" ? t.builtIn : t.userPlugin}</span>
              <span>{plugin.enabled ? t.pluginEnabled : t.pluginDisabled}</span>
              <code>{plugin.id}</code>
            </div>
            <section>
              <h3>{t.modelTools}</h3>
              <div className="tool-list">{plugin.tools.map((tool) => <div key={tool.exposedName}><Wrench /><span><strong>{tool.exposedName}</strong><small>{locale === "zh_cn" && tool.descriptionZh ? tool.descriptionZh : tool.description}</small></span></div>)}</div>
            </section>
            <section>
              <h3>{t.pluginPermissions}</h3>
              <div className="permission-tags">{permissions.length ? permissions.map((label) => <span key={label}><ShieldCheck />{label}</span>) : <span>{t.permissionNone}</span>}</div>
            </section>
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
  </section>;
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
  return <div className="modal-layer setup-layer"><div className="setup-dialog">
    <div className="setup-mark"><BrandMark /></div><h1>{t.firstRunTitle}</h1><p>{t.firstRunBody}</p>
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
  return <div className="modal-layer"><div className="preview-dialog">
    <header><div><FileText /><strong>{payload.name}</strong></div><div className="preview-actions"><button onClick={() => void runtimeInvoke("open_external", { path: payload.path })}><ExternalLink />{t.openExternal}</button><button onClick={() => void runtimeInvoke("reveal_path", { path: payload.path })}><FolderOpen />{t.reveal}</button><button className="icon-button" title={t.close} onClick={onClose}><X /></button></div></header>
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
function attachmentPathsForMessage(snapshot: RuntimeSnapshot, message: ChatMessage): string[] {
  const direct = message.attachmentPaths ?? [];
  if (direct.length > 0 || message.role !== "user" || !message.threadId) return direct;
  return snapshot.tasks.find((task) => task.id === message.threadId)?.attachmentPaths ?? [];
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
