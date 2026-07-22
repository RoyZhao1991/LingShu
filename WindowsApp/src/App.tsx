import { FormEvent, useCallback, useEffect, useMemo, useRef, useState } from "react";
import ReactMarkdown from "react-markdown";
import {
  Activity, Bot, Check, ChevronRight, CircleAlert, ExternalLink, FileBox, FileText,
  FolderOpen, Gauge, LoaderCircle, MessageCircle, MessagesSquare, Paperclip, Play, Search, Send,
  Settings, ShieldCheck, Square, X,
} from "lucide-react";
import { strings } from "./i18n";
import { chooseFiles, runtimeInvoke } from "./bridge";
import type {
  ArtifactRecord, Locale, Page, PreviewPayload, ProviderPreset, RuntimeSettings,
  RuntimeSnapshot, TaskRecord, TaskStatus,
} from "./types";

import type { BootstrapPayload } from "./bridge";

const terminalStatuses = new Set<TaskStatus>(["completed", "failed", "cancelled"]);

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
  const messagesEnd = useRef<HTMLDivElement>(null);

  const locale = settingsDraft?.locale ?? snapshot?.settings.locale ?? "zh_cn";
  const t = strings(locale);
  const activeTask = snapshot?.tasks.find((task) => task.id === snapshot.activeTaskId);
  const isBusy = Boolean(activeTask) || Boolean(snapshot?.queuedTaskCount);
  const selectedTask = snapshot?.tasks.find((task) => task.id === selectedTaskId) ?? activeTask ?? snapshot?.tasks.at(-1);

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
    const interval = window.setInterval(() => void refresh(), isBusy ? 800 : 3_000);
    return () => window.clearInterval(interval);
  }, [isBusy, refresh, snapshot]);

  useEffect(() => {
    if (page === "chat") messagesEnd.current?.scrollIntoView({ behavior: "smooth", block: "end" });
  }, [page, snapshot?.messages.length, snapshot?.messages.at(-1)?.text]);

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

  const showPreview = async (artifact: ArtifactRecord) => {
    try {
      setPreview(await runtimeInvoke<PreviewPayload>("preview_path", { path: artifact.path }));
    } catch (reason) {
      setError(String(reason));
    }
  };

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
    return <main className="boot"><LoaderCircle className="spin" /><span>LingShu Runtime Core</span></main>;
  }

  const setupRequired = !snapshot.providerConfigured || !snapshot.settings.firstRunComplete;

  return (
    <div className="app-shell">
      <Header page={page} setPage={setPage} busy={isBusy} locale={locale} />
      <main className="workspace-shell">
        {page === "chat" && (
          <section className="chat-page">
            <div className="message-scroll">
              {snapshot.messages.length === 0 && <EmptyState icon={<MessageCircle />} text={t.noMessages} />}
              {snapshot.messages.map((message) => (
                <article key={message.id} className={`message ${message.role}`}>
                  <div className="message-meta">
                    <span>{message.role === "user" ? (locale === "en" ? "You" : "你") : "LingShu"}</span>
                    <time>{new Date(message.createdAt).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}</time>
                  </div>
                  <div className="markdown-body">
                    {message.state === "thinking" && <LoaderCircle className="inline-loader spin" />}
                    <ReactMarkdown>{message.text}</ReactMarkdown>
                  </div>
                  {message.threadId && message.role === "assistant"
                    && snapshot.tasks.find((task) => task.id === message.threadId)?.goalSpec?.output_mode !== "chat_reply" && (
                    <button className="thread-link" onClick={() => { setSelectedTaskId(message.threadId); setPage("threads"); }}>
                      <MessagesSquare size={16} /> {locale === "en" ? "View execution" : "查看执行过程"}
                    </button>
                  )}
                </article>
              ))}
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
          <ThreadsPage tasks={snapshot.tasks} selected={selectedTask} locale={locale} onSelect={setSelectedTaskId} onPreview={showPreview} />
        )}

        {page === "status" && <StatusPage snapshot={snapshot} locale={locale} />}

        {page === "settings" && (
          <SettingsPage draft={settingsDraft} providers={providers} apiKey={apiKey} locale={locale} validating={validating}
            connected={snapshot.providerConfigured} onDraft={setSettingsDraft} onApiKey={setApiKey} onProvider={selectProvider} onSave={saveSettings} />
        )}
      </main>

      {setupRequired && (
        <SetupDialog draft={settingsDraft} providers={providers} apiKey={apiKey} locale={locale} validating={validating} error={error}
          onDraft={setSettingsDraft} onApiKey={setApiKey} onProvider={selectProvider} onSave={saveSettings} />
      )}
      {preview && <PreviewDialog payload={preview} locale={locale} onClose={() => setPreview(undefined)} />}
    </div>
  );
}

function Header({ page, setPage, busy, locale }: { page: Page; setPage: (page: Page) => void; busy: boolean; locale: Locale }) {
  const t = strings(locale);
  const navigation: Array<[Page, typeof MessageCircle, string]> = [
    ["chat", MessageCircle, t.chat], ["threads", MessagesSquare, t.threads], ["status", Activity, t.status], ["settings", Settings, t.settings],
  ];
  return <header className="app-header">
    <div className="brand"><div className="brand-mark"><Bot /></div><div><strong>LingShu</strong><small>NOUS · AGENT RUNTIME</small></div></div>
    <nav>{navigation.map(([id, Icon, label]) => <button key={id} className={page === id ? "active" : ""} onClick={() => setPage(id)}><Icon />{label}</button>)}</nav>
    <div className="runtime-state"><small>STATE</small><strong className={busy ? "active" : ""}>{busy ? t.running : t.standby}</strong></div>
  </header>;
}

function ThreadsPage({ tasks, selected, locale, onSelect, onPreview }: { tasks: TaskRecord[]; selected?: TaskRecord; locale: Locale; onSelect: (id: string) => void; onPreview: (artifact: ArtifactRecord) => void }) {
  const t = strings(locale);
  if (!tasks.length) return <EmptyState icon={<MessagesSquare />} text={t.noTasks} />;
  return <section className="threads-page">
    <aside className="thread-list">
      <div className="section-heading"><MessagesSquare /> <strong>{t.threads}</strong><span>{tasks.length}</span></div>
      {[...tasks].reverse().map((task) => <button key={task.id} className={selected?.id === task.id ? "selected" : ""} onClick={() => onSelect(task.id)}>
        <StatusGlyph status={task.status} /><span><strong>{task.title}</strong><small>{statusLabel(task.status, locale)} · {new Date(task.updatedAt).toLocaleString()}</small></span><ChevronRight />
      </button>)}
    </aside>
    <div className="thread-detail">
      {!selected ? <EmptyState icon={<Search />} text={t.selectTask} /> : <>
        <div className="thread-title"><div><small>{statusLabel(selected.status, locale)}</small><h1>{selected.title}</h1></div><StatusGlyph status={selected.status} /></div>
        <section className="detail-band"><h2><Gauge />{t.goal}</h2>{selected.goalSpec ? <><p>{selected.goalSpec.objective}</p><TagList values={selected.goalSpec.success_criteria} /></> : <p>{selected.prompt}</p>}</section>
        <section className="detail-band"><h2><Activity />{t.steps}</h2><ol className="steps">{selected.steps.map((step) => <li key={step.id}><StatusGlyph status={step.status} /><div><strong>{step.title}</strong><p>{step.detail}</p></div></li>)}</ol></section>
        <section className="detail-band"><h2><FileBox />{t.artifacts}<span>{selected.artifacts.length}</span></h2>
          {!selected.artifacts.length ? <p className="muted">{locale === "en" ? "No registered artifacts yet." : "暂未登记产出物。"}</p> :
            <div className="artifact-list">{selected.artifacts.map((artifact) => <div className="artifact-row" key={artifact.id}><FileText /><div><strong>{artifact.title}</strong><small>{fileName(artifact.path)} · {formatBytes(artifact.sizeBytes)}</small></div><button onClick={() => onPreview(artifact)}><Search />{t.preview}</button></div>)}</div>}
        </section>
        {selected.error && <div className="task-error"><CircleAlert />{selected.error}</div>}
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
    <div className="status-intro"><div><small>LINGSHU RUNTIME CORE</small><h1>{t.kernel} ABI {snapshot.kernelAbiVersion}</h1><p>{t.windowsBoundary}</p></div><ShieldCheck /></div>
    <div className="metrics"><div><span>{t.active}</span><strong>{snapshot.activeTaskId ? snapshot.tasks.find((task) => task.id === snapshot.activeTaskId)?.title : t.none}</strong></div><div><span>{t.queue}</span><strong>{snapshot.queuedTaskCount}</strong></div><div><span>{t.modelChannels}</span><strong>{snapshot.settings.providerName} / {snapshot.settings.model}</strong></div></div>
    <div className="capability-table"><h2>{t.capabilities}</h2>{capabilities.map(([label, enabled]) => <div key={label}><span>{enabled ? <Check /> : <X />}{label}</span><strong className={enabled ? "available" : "unavailable"}>{enabled ? t.available : t.unavailable}</strong></div>)}</div>
  </section>;
}

interface SettingsProps {
  draft: RuntimeSettings; providers: ProviderPreset[]; apiKey: string; locale: Locale; validating: boolean; connected?: boolean;
  onDraft: (settings: RuntimeSettings) => void; onApiKey: (key: string) => void; onProvider: (id: string) => void; onSave: () => void;
}

function SettingsPage(props: SettingsProps) {
  const t = strings(props.locale);
  return <section className="settings-page">
    <div className="page-heading"><Settings /><div><h1>{t.modelChannels}</h1><p>{props.connected ? t.connected : t.disconnected}</p></div></div>
    <SettingsForm {...props} />
  </section>;
}

function SettingsForm({ draft, providers, apiKey, locale, validating, onDraft, onApiKey, onProvider, onSave }: SettingsProps) {
  const t = strings(locale);
  const selected = providers.find((provider) => provider.id === draft.providerId);
  return <div className="settings-form">
    <label>{t.language}<select value={draft.locale} onChange={(event) => onDraft({ ...draft, locale: event.target.value as Locale })}><option value="zh_cn">{t.chinese}</option><option value="en">{t.english}</option></select></label>
    <label>{t.provider}<select value={draft.providerId} onChange={(event) => onProvider(event.target.value)}>{providers.map((provider) => <option key={provider.id} value={provider.id}>{provider.name} · {provider.region}</option>)}</select></label>
    <label>{t.model}<input value={draft.model} onChange={(event) => onDraft({ ...draft, model: event.target.value })} list="model-options" /><datalist id="model-options">{selected?.defaultModels.map((model) => <option key={model} value={model} />)}</datalist></label>
    <label>{t.endpoint}<input value={draft.endpoint} onChange={(event) => onDraft({ ...draft, endpoint: event.target.value })} /></label>
    <label>{t.token}<input type="password" value={apiKey} placeholder="••••••••••••••••" onChange={(event) => onApiKey(event.target.value)} /><small>{t.apiHint}</small></label>
    <label>{t.workspace}<input value={draft.workspace} onChange={(event) => onDraft({ ...draft, workspace: event.target.value })} /></label>
    <button className="primary-command" onClick={onSave} disabled={validating}>{validating ? <LoaderCircle className="spin" /> : <Play />}{validating ? t.validating : t.saveValidate}</button>
  </div>;
}

function SetupDialog(props: SettingsProps & { error: string }) {
  const t = strings(props.locale);
  return <div className="modal-layer setup-layer"><div className="setup-dialog">
    <div className="setup-mark"><Bot /></div><h1>{t.firstRunTitle}</h1><p>{t.firstRunBody}</p>
    <SettingsForm {...props} />
    {props.error && <div className="error-strip"><CircleAlert />{props.error}</div>}
  </div></div>;
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
  if (payload.kind === "markdown") return <div className="document-preview markdown-body"><ReactMarkdown>{payload.content}</ReactMarkdown></div>;
  if (payload.kind === "presentation") return <div className="slide-preview">{payload.sections.map((section, index) => { const [title, ...body] = section.split("\n"); return <section key={`${index}-${title}`}><small>{String(index + 1).padStart(2, "0")}</small><h2>{title}</h2><ul>{body.map((line) => <li key={line}>{line}</li>)}</ul></section>; })}</div>;
  if (payload.kind === "document") return <div className="document-preview">{payload.sections.map((section, index) => index === 0 ? <h1 key={index}>{section}</h1> : <p key={index}>{section}</p>)}</div>;
  if (["text", "code"].includes(payload.kind)) return <pre className="code-preview">{payload.content}</pre>;
  return <EmptyState icon={<FileBox />} text={unsupported} />;
}

function EmptyState({ icon, text }: { icon: React.ReactNode; text: string }) { return <div className="empty-state">{icon}<p>{text}</p></div>; }
function StatusGlyph({ status }: { status: TaskStatus }) { return terminalStatuses.has(status) ? (status === "completed" ? <Check className="status-glyph done" /> : <X className="status-glyph failed" />) : <LoaderCircle className="status-glyph spin active" />; }
function TagList({ values }: { values: string[] }) { return <ul className="tag-list">{values.map((value) => <li key={value}>{value}</li>)}</ul>; }
function fileName(path: string) { return path.split(/[\\/]/).at(-1) ?? path; }
function formatBytes(value: number) { return value < 1024 ? `${value} B` : value < 1024 * 1024 ? `${(value / 1024).toFixed(1)} KB` : `${(value / 1024 / 1024).toFixed(1)} MB`; }
function statusLabel(status: TaskStatus, locale: Locale) { const t = strings(locale); if (status === "completed") return t.completed; if (status === "failed") return t.failed; if (status === "cancelled") return t.cancelled; if (status === "queued") return t.queued; return t.running; }
