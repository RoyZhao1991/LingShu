import type { Locale } from "./types";

const copy = {
  zh_cn: {
    chat: "对话", threads: "线程", status: "状态", settings: "配置",
    standby: "待机中", running: "执行中", queued: "排队中", failed: "未完成", completed: "已完成", cancelled: "已停止",
    placeholder: "有什么需要我做的？", send: "发送", attach: "添加附件", stop: "停止",
    noMessages: "配置主脑后即可开始对话或交付文件。", noTasks: "还没有任务线程。",
    modelChannels: "模型通道", provider: "服务商", model: "模型", endpoint: "API 地址", token: "API Token", workspace: "工作目录",
    saveValidate: "保存并验证", validating: "验证中…", connected: "通道已连接", disconnected: "需要配置模型通道",
    firstRunTitle: "连接灵枢主脑", firstRunBody: "选择服务商并填写 Token。自定义兼容通道还需要填写 API 地址和模型名。",
    continue: "开始使用", language: "语言", chinese: "中文", english: "English",
    preview: "预览", openExternal: "用系统应用打开", reveal: "在文件夹中显示", close: "关闭",
    artifacts: "产出物", steps: "执行计划", goal: "核心目标", capabilities: "平台能力", kernel: "共享内核",
    internalPreview: "内置文件预览", externalOpen: "外部应用打开", computerControl: "电脑控制", realtimePerception: "实时感知",
    available: "可用", unavailable: "Windows 首版暂不提供", queue: "主任务队列", active: "当前任务", none: "无",
    windowsBoundary: "Windows 外壳与 macOS 共用 LingShu Runtime Core；本版本不暴露电脑控制和实时感知工具。",
    selectTask: "选择左侧线程查看目标、步骤和产出物。", unsupported: "此格式暂不支持内置预览，可使用系统应用打开。",
    saveError: "保存失败", requestError: "请求失败", bytes: "字节", apiHint: "Token 仅存入当前 Windows 用户的凭据管理器。",
  },
  en: {
    chat: "Chat", threads: "Threads", status: "Status", settings: "Settings",
    standby: "Standby", running: "Running", queued: "Queued", failed: "Failed", completed: "Completed", cancelled: "Cancelled",
    placeholder: "What can I do for you?", send: "Send", attach: "Add attachments", stop: "Stop",
    noMessages: "Connect a brain channel to chat or deliver files.", noTasks: "No task threads yet.",
    modelChannels: "Model Channels", provider: "Provider", model: "Model", endpoint: "API endpoint", token: "API token", workspace: "Workspace",
    saveValidate: "Save & Validate", validating: "Validating…", connected: "Channel connected", disconnected: "Model channel setup required",
    firstRunTitle: "Connect LingShu's Brain", firstRunBody: "Choose a provider and enter its token. A custom-compatible channel also needs an endpoint and model name.",
    continue: "Start LingShu", language: "Language", chinese: "中文", english: "English",
    preview: "Preview", openExternal: "Open in system app", reveal: "Show in folder", close: "Close",
    artifacts: "Artifacts", steps: "Execution Plan", goal: "Core Goal", capabilities: "Platform Capabilities", kernel: "Shared Kernel",
    internalPreview: "Built-in file preview", externalOpen: "Open in external app", computerControl: "Computer control", realtimePerception: "Realtime perception",
    available: "Available", unavailable: "Not exposed in the first Windows release", queue: "Main Task Queue", active: "Active Task", none: "None",
    windowsBoundary: "The Windows shell and macOS share LingShu Runtime Core. This release does not expose computer-control or realtime-perception tools.",
    selectTask: "Select a thread to inspect its goal, steps, and artifacts.", unsupported: "Built-in preview does not support this format yet. You can open it in the system app.",
    saveError: "Could not save", requestError: "Request failed", bytes: "bytes", apiHint: "The token is stored only in the current Windows user's Credential Manager.",
  },
} as const;

export type Copy = typeof copy.zh_cn;
export function strings(locale: Locale): Copy { return copy[locale] as Copy; }
