import { FormEvent, useCallback, useEffect, useMemo, useRef, useState } from "react";
import ReactMarkdown, { type Components } from "react-markdown";
import remarkGfm from "remark-gfm";
import {
  Activity, Bot, BrainCircuit, Check, ChevronRight, CircleAlert, Clock3, ExternalLink,
  FileBox, FileText, FolderOpen, Gauge, GitBranch, ListChecks, LoaderCircle, MessageCircle,
  MessagesSquare, Paperclip, Play, Search, Send, Settings, ShieldCheck, Square, UserRound,
  Wrench, X,
} from "lucide-react";
import { strings } from "./i18n";
import { chooseFiles, runtimeInvoke } from "./bridge";
import { normalizeMarkdownTables } from "./markdown";
import packageMetadata from "../package.json";
import type {
  ArtifactRecord, ChatMessage, ExecutionPermissionMode, Locale, Page, PreviewPayload, ProviderPreset, RuntimeSettings,
  RuntimeEvent, RuntimeSnapshot, TaskRecord, TaskRole, TaskStatus,
} from "./types";

import type { BootstrapPayload } from "./bridge";

const terminalStatuses = new Set<TaskStatus>(["completed", "failed", "cancelled"]);
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
  const messagesEnd = useRef<HTMLDivElement>(null);
  const messageScroll = useRef<HTMLDivElement>(null);
  const keepAtBottom = useRef(true);

  const locale = settingsDraft?.locale ?? snapshot?.settings.locale ?? "zh_cn";
  const t = strings(locale);
  const activeTask = snapshot?.tasks.find((task) => task.id === snapshot.activeTaskId);
  const isBusy = Boolean(snapshot?.tasks.some((task) => ["understanding", "running"].includes(task.status))) || Boolean(snapshot?.queuedTaskCount);
  const selectedTask = snapshot?.tasks.find((task) => task.id === selectedTaskId) ?? activeTask ?? snapshot?.tasks.filter((task) => !task.parentTaskId).at(-1);
  const actionTask = snapshot?.tasks.find((task) => task.status === "needs_user_action");

  const refresh = useCallback(async () => {
    try {
      const next = await runtimeInvoke<RuntimeSnapshot>("get_snapshot");
      setSnapshot(next);
      if (!settingsDraft) setSettingsDraft(next.settings);
      setError("");
    } catch (reason) {
      setError(String(reason));
    }
  }, [settingsDraft]);

  useEffect(() => {
    void runtimeInvoke<BootstrapPayload>("bootstrap").then((payload) => {
      setSnapshot(payload.snapshot);
      setProviders(payload.providers);
      setSettingsDraft(payload.snapshot.settings);
      setSelectedTaskId(payload.snapshot.activeTaskId ?? payload.snapshot.tasks.at(-1)?.id);
    }).catch((reason) => setError(String(reason)));
  }, []);

  useEffect(() => {
    if (!snapshot) return;
    const interval = window.setInterval(() => void refresh(), isBusy ? 350 : 1_500);
    return () => window.clearInterval(interval);
  }, [isBusy, refresh, snapshot]);

  useEffect(() => {
    if (page === "chat" && keepAtBottom.current) {
      messagesEnd.current?.scrollIntoView({ behavior: "auto", block: "end" });
    }
  }, [page, snapshot?.messages.length, snapshot?.messages.at(-1)?.text, snapshot?.latestEventSequence]);

  useEffect(() => {
    document.title = t.appName;
    void import("@tauri-apps/api/window")
      .then(({ getCurrentWindow }) => getCurrentWindow().setTitle(t.appName))
      .catch(() => undefined);
  }, [t.appName]);

  const trackMessageScroll = () => {
    const node = messageScroll.current;
    if (!node) return;
    keepAtBottom.current = node.scrollHeight - node.scrollTop - node.clientHeight < 56;
  };

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    const text = prompt.trim();
    if (!text || sending) return;
    setSending(true);
    setError("");
    try {
      await runtimeInvoke("submit_message", { prompt: text, attachmentPaths: attachments });
      setPrompt("");
      setAttachments([]);
      await refresh();
    } catch (reason) {
      setError(`${t.requestError}: ${String(reason)}`);
    } finally {
      setSending(false);
    }
  };

  const chooseAttachments = async () => {
    const selected = await chooseFiles();
    if (selected.length) setAttachments(selected);
  };

  const showPathPreview = async (path: string) => {
    try {
      setPreview(await runtimeInvoke<PreviewPayload>("preview_path", { path }));
    } catch (reason) {
      setError(String(reason));
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
      setSnapshot(next);
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
      setSnapshot(next);
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
      const accepted = await runtimeInvoke<boolean>("resume_task", { threadId: actionTask.id, answer: actionAnswer.trim() });
      if (!accepted) throw new Error(locale === "en" ? "The task is not ready to resume." : "当前任务暂时无法恢复执行。");
      setActionAnswer("");
      await refresh();
    } catch (reason) {
      setError(String(reason));
    } finally {
      setResuming(false);
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
    <div className="app-shell">
      <Header page={page} setPage={setPage} busy={isBusy} locale={locale} />
      <main className="workspace-shell">
        {page === "chat" && (
          <section className="chat-page">
            <div className="message-scroll" ref={messageScroll} onScroll={trackMessageScroll}>
              {snapshot.messages.length === 0 && <EmptyState icon={<MessageCircle />} text={t.noMessages} />}
              {snapshot.messages.map((message) => {
                const messageAttachments = attachmentPathsForMessage(snapshot, message);
                return <article key={message.id} className={`message ${message.role}`}>
                  <div className="message-meta">
                    <span>{message.role === "user" ? (locale === "en" ? "You" : "你") : t.appName}</span>
                    <time>{new Date(message.createdAt).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}</time>
                  </div>
                  <div className="markdown-body">
                    {message.state === "thinking" && <LoaderCircle className="inline-loader spin" />}
                    <MarkdownContent>{message.text}</MarkdownContent>
                  </div>
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
                  {message.state === "thinking" && message.threadId && (
                    <MessageRuntimeStatus event={latestEventForThread(snapshot, message.threadId)} locale={locale} />
                  )}
                  {message.threadId && message.role === "assistant"
                    && shouldShowExecution(snapshot, message.threadId) && (
                    <button className="thread-link" onClick={() => { setSelectedTaskId(message.threadId); setPage("threads"); }}>
                      <MessagesSquare size={16} /> {locale === "en" ? "View execution" : "查看执行过程"}
                    </button>
                  )}
                </article>;
              })}
              <div ref={messagesEnd} />
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
              <textarea value={prompt} onChange={(event) => setPrompt(event.target.value)} placeholder={t.placeholder}
                onKeyDown={(event) => { if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); event.currentTarget.form?.requestSubmit(); } }} />
              <div className="composer-actions">
                <button type="button" className="icon-button" title={t.attach} onClick={chooseAttachments}><Paperclip /></button>
                <PermissionSelector mode={snapshot.settings.executionPermissionMode} locale={locale} compact disabled={permissionUpdating} onChange={updateExecutionPermission} />
                <span className="channel-state"><span className={snapshot.providerConfigured ? "dot good" : "dot"} />{snapshot.settings.providerName} · {snapshot.settings.model}</span>
                {activeTask ? (
                  <button type="button" className="stop-button" onClick={() => void runtimeInvoke("cancel_task", { threadId: activeTask.id }).then(refresh)}><Square size={16} />{t.stop}</button>
                ) : (
                  <button className="send-button" type="submit" disabled={sending || !prompt.trim()} title={t.send}><Send /></button>
                )}
              </div>
            </form>
          </section>
        )}

        {page === "threads" && (
          <ThreadsPage tasks={snapshot.tasks} events={snapshot.events} selected={selectedTask} locale={locale} onSelect={setSelectedTaskId} onPreview={showPreview} />
        )}

        {page === "status" && <StatusPage snapshot={snapshot} locale={locale} />}

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
      {preview && <PreviewDialog payload={preview} locale={locale} onClose={() => setPreview(undefined)} />}
      {actionTask && (
        <HumanActionDialog task={actionTask} locale={locale} value={actionAnswer} busy={resuming} error={error}
          onChange={setActionAnswer} onResume={resumeAction} />
      )}
    </div>
  );
}

function Header({ page, setPage, busy, locale }: { page: Page; setPage: (page: Page) => void; busy: boolean; locale: Locale }) {
  const t = strings(locale);
  const navigation: Array<[Page, typeof MessageCircle, string]> = [
    ["chat", MessageCircle, t.chat], ["threads", MessagesSquare, t.threads], ["status", Activity, t.status], ["settings", Settings, t.settings],
  ];
  return <header className="app-header">
    <div className="brand"><BrandMark /><div><div className="brand-title"><strong>{t.appName}</strong><span>v{appVersion}</span></div><small>{t.tagline}</small></div></div>
    <nav>{navigation.map(([id, Icon, label]) => <button key={id} className={page === id ? "active" : ""} onClick={() => setPage(id)}><Icon />{label}</button>)}</nav>
    <div className="runtime-state"><small>STATE</small><strong className={busy ? "active" : ""}>{busy ? t.running : t.standby}</strong></div>
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

function HumanActionDialog({ task, locale, value, busy, error, onChange, onResume }: { task: TaskRecord; locale: Locale; value: string; busy: boolean; error: string; onChange: (value: string) => void; onResume: () => void }) {
  const t = strings(locale);
  return <div className="modal-layer action-layer"><div className="action-dialog" role="dialog" aria-modal="true" aria-labelledby="action-title">
    <header><div className="action-mark"><UserRound /></div><div><h1 id="action-title">{t.actionRequired}</h1><p>{t.actionBody}</p></div></header>
    <section><div className="action-actor"><RoleIcon role={task.role} /><span>{task.participantName}</span></div><MarkdownContent>{task.pendingQuestion ?? task.summary}</MarkdownContent></section>
    <textarea autoFocus value={value} onChange={(event) => onChange(event.target.value)} placeholder={t.answerPlaceholder}
      onKeyDown={(event) => { if ((event.ctrlKey || event.metaKey) && event.key === "Enter") onResume(); }} />
    {error && <div className="error-strip"><CircleAlert />{error}</div>}
    <button className="action-resume" disabled={busy || !value.trim()} onClick={onResume}>{busy ? <LoaderCircle className="spin" /> : <Check />}{t.resume}</button>
  </div></div>;
}

function MessageRuntimeStatus({ event, locale }: { event?: RuntimeEvent; locale: Locale }) {
  if (!event) return null;
  return <div className="message-runtime-status"><EventIcon kind={event.kind} /><span><strong>{event.title}</strong><small>{event.actor}{event.state === "running" ? (locale === "en" ? " · live" : " · 实时") : ""}</small></span></div>;
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
    <div className="preview-content"><PreviewBody payload={payload} unsupported={t.unsupported} /></div>
  </div></div>;
}

function PreviewBody({ payload, unsupported }: { payload: PreviewPayload; unsupported: string }) {
  if (payload.kind === "image") return <img className="image-preview" src={payload.content} alt={payload.name} />;
  if (payload.kind === "pdf") return <embed className="pdf-preview" src={payload.content} type="application/pdf" />;
  if (payload.kind === "html") return <iframe className="html-preview" sandbox="" srcDoc={payload.content} title={payload.name} />;
  if (payload.kind === "markdown") return <div className="document-preview markdown-body"><MarkdownContent>{payload.content}</MarkdownContent></div>;
  if (payload.kind === "presentation") return <div className="slide-preview">{payload.sections.map((section, index) => { const [title, ...body] = section.split("\n"); return <section key={`${index}-${title}`}><small>{String(index + 1).padStart(2, "0")}</small><h2>{title}</h2><ul>{body.map((line) => <li key={line}>{line}</li>)}</ul></section>; })}</div>;
  if (payload.kind === "document") return <div className="document-preview">{payload.sections.map((section, index) => index === 0 ? <h1 key={index}>{section}</h1> : <p key={index}>{section}</p>)}</div>;
  if (["text", "code"].includes(payload.kind)) return <pre className="code-preview">{payload.content}</pre>;
  return <EmptyState icon={<FileBox />} text={unsupported} />;
}

function EmptyState({ icon, text }: { icon: React.ReactNode; text: string }) { return <div className="empty-state">{icon}<p>{text}</p></div>; }
function MarkdownContent({ children }: { children: string }) {
  return <ReactMarkdown remarkPlugins={[remarkGfm]} components={markdownComponents}>{normalizeMarkdownTables(children)}</ReactMarkdown>;
}
function StatusGlyph({ status }: { status: TaskStatus }) { return terminalStatuses.has(status) ? (status === "completed" ? <Check className="status-glyph done" /> : <X className="status-glyph failed" />) : <LoaderCircle className="status-glyph spin active" />; }
function TagList({ values }: { values: string[] }) { return <ul className="tag-list">{values.map((value) => <li key={value}>{value}</li>)}</ul>; }
function fileName(path: string) { return path.split(/[\\/]/).at(-1) ?? path; }
function attachmentPathsForMessage(snapshot: RuntimeSnapshot, message: ChatMessage): string[] {
  const direct = message.attachmentPaths ?? [];
  if (direct.length > 0 || message.role !== "user" || !message.threadId) return direct;
  return snapshot.tasks.find((task) => task.id === message.threadId)?.attachmentPaths ?? [];
}
function formatBytes(value: number) { return value < 1024 ? `${value} B` : value < 1024 * 1024 ? `${(value / 1024).toFixed(1)} KB` : `${(value / 1024 / 1024).toFixed(1)} MB`; }
function statusLabel(status: TaskStatus, locale: Locale) { const t = strings(locale); if (status === "completed") return t.completed; if (status === "failed") return t.failed; if (status === "cancelled") return t.cancelled; if (status === "queued") return t.queued; if (status === "needs_user_action") return t.blocked; return t.running; }
function roleLabel(role: TaskRole, locale: Locale) { const t = strings(locale); if (role === "worker") return t.workerRole; if (role === "checker") return t.checkerRole; return t.mainRole; }

function aggregateTaskStatus(root: TaskRecord, tasks: TaskRecord[]): TaskStatus {
  const related = tasks.filter((task) => (task.rootTaskId ?? task.id) === root.id);
  if (related.some((task) => task.status === "needs_user_action")) return "needs_user_action";
  if (related.some((task) => ["understanding", "running"].includes(task.status))) return "running";
  if (related.some((task) => task.status === "queued")) return "queued";
  return root.status;
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
