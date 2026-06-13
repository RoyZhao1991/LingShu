# Bert-VITS2 实时中文情绪 TTS —— 部署交接（给 Codex）

目标：用 **Bert-VITS2**(开源、私有化、非自回归)替换当前算力机上的 CosyVoice2 实时语音通道，
把云端男声首包延迟从 ~4s 降到亚秒级，保留中文情绪韵律。

> 你（Codex）没有产品端对话的上下文。本文是**唯一信息源**，按它执行即可。
> 最高优先级：**不要改灵枢客户端的网络契约**（见 §1）。只要契约不破，灵枢 App 零改动。

---

## 0. 硬约束（违反任何一条都算失败）

1. **冻结对外契约**：外部 HTTP 接口（URL/请求头/请求体/响应类型/voiceId/emotion 枚举）必须与 §1 完全一致。
2. **感知数据零留存**：服务端**不得**把请求文本或合成音频写盘、写日志、留 `/tmp`。处理完即丢，内存里走完就释放。
3. **开源 + 私有化**：只用开源权重，全部跑在算力机上，不接任何商用云 TTS API。
4. **实测交付**：每一步附真实 `curl` 证据（HTTP 码、字节数、content-type、耗时），不接受"应该可以"。

---

## 1. 冻结的对外契约（Bert-VITS2 适配服务必须照单实现）

灵枢客户端发的请求长这样，**一个字节都不能要求它改**：

- **方法/URL**：`POST https://model-gateway.datanet.bj.cn/v1/perception/swds-speaker-tts`
- **请求头**：
  - `Content-Type: application/json`
  - `Accept: audio/wav, application/json`
  - `X-Model-Token: <datanet token>` ← 鉴权，沿用现有 token
- **请求体**（JSON）：
  ```json
  { "text": "要合成的中文", "voiceId": "male_steady", "emotion": "calm" }
  ```
- **响应**：`Content-Type: audio/wav`，body 是**完整 WAV 容器**（客户端用 `AVAudioPlayer(data:)` 播放，必须是带头的容器；采样率不限，44100Hz 可接受）。
  - 也允许返回 `application/json` `{ "audio_base64": "..." }`，但优先直接回 WAV。
- **voiceId 枚举**（至少实现 `male_steady`，这是默认贾维斯男声）：
  `male_steady`、`male_elder`、`female_default`、`female_bright`、`female_soft`
  - 收到未知 voiceId → 返回 **400**，body 里带 `availableVoiceIds` 数组（沿用现有网关行为，便于客户端自诊断）。
- **emotion 枚举**：`neutral`、`calm`、`happy`、`sad`、`excited`、`angry`、`breathy`
  - 收到未知 emotion → 退化成 `neutral`，不报错。

> 客户端对应代码（**只读，别动**）：契约结构体 `LingShuSpeechSynthesisRequest{text,voiceId,emotion}`、
> 端点常量、`X-Model-Token` 头都在 `Sources/Services/Voice/LingShuSpeechOutputGateway.swift`；
> 默认人格 `calmJarvisMale → voiceId=male_steady, emotion=calm`。

---

## 2. 现有基础设施（已知事实，省得你摸索）

- **算力机**：`10.99.134.25`，SSH `root@10.99.134.25 -p 2222`，8×H100（80G/卡）。**你只有这台的权限。**
- **下载代理**（modelscope/HuggingFace 走它）：`http://10.99.134.16:3128`（设 `HTTP_PROXY/HTTPS_PROXY`）。
- **当前 TTS（要被替换/降级的）**：CosyVoice2-0.5B
  - 适配服务 `/opt/cosyvoice-tts-server.py`，FastAPI 监听 `127.0.0.1:8021`，跑在 **GPU7**。
  - 算力机 nginx 把 `/api/realtime/speaker-tts`（以及对外的 `/v1/perception/swds-speaker-tts` 转发链路）`proxy_pass` 到 `127.0.0.1:8021`（改前**备份** `*.bak.tts`）。
- **GPU 占用**：VL 在 GPU5、vision-fast 在 GPU6、CosyVoice2 在 GPU7。**Bert-VITS2 用空闲卡（GPU0-4 任一）**，它才几个 GB，随便放。
- **前置网关** `172.25.208.8`（对外 `model-gateway.datanet.bj.cn`）：**你没有权限**。所以——
  - **关键策略：不要碰前置网关。** 对外路由 `/v1/perception/swds-speaker-tts` 已开放且转发到算力机。
    你只需**在算力机侧把 :8021 背后的服务换成 Bert-VITS2 适配服务**（或新起 :8023 再把算力机 nginx 的 upstream 指过去），
    对外契约不变，前置网关无需改动。

---

## 3. 服务端部署步骤（算力机）

1. **拉代码 + 建环境**
   - `git clone https://github.com/fishaudio/Bert-VITS2`（走代理）。用独立 venv（如 `/opt/bv2-venv`，Python 3.10）。
   - 装 `requirements.txt`（torch 对应 CUDA 版本）。
2. **下载所需权重**（全走代理）
   - Bert-VITS2 **底模 + 配置**：选一个**中文男声质量好的预训练 checkpoint**（`G_*.pth` + `config.json`）。优先用社区公认中文自然度高的发布版；确认许可证可私有部署（用稳定版、核对 LICENSE）。
   - **BERT**：中文 `chinese-roberta-wwm-ext-large`（多语种再加对应 BERT）。
   - **情绪/风格依赖**：按所选 Bert-VITS2 版本补齐（如 WavLM / 情绪 embedding 模型）。
   - 权重统一放 `/data/tts-models/bert-vits2/`。
3. **选定男声 + 情绪素材**
   - 从底模的多说话人里选一个**沉稳中文男声 sid** 当 `male_steady`（贾维斯）；`male_elder` 选偏年长的 sid。
   - **情绪映射（核心设计）**：Bert-VITS2 的情绪不是离散枚举，靠**参考音频/风格**驱动。
     为 `male_steady` 准备 7 段**参考音频**（neutral/calm/happy/sad/excited/angry/breathy 各一段几秒的对应情绪录音），
     适配服务按请求里的 `emotion` 选对应参考音频喂给 `infer(...)`。
     （若用的版本支持 `style_text`/`emotion-id`，也可改用那条路；但参考音频最稳、最可控。）
4. **写适配服务**（把 repo 的 `server_fastapi.py` 改造，或新写一个）
   - 监听 `127.0.0.1:8023`（别和 8021 撞）。
   - 入参：§1 的 `{text, voiceId, emotion}` JSON；校验 voiceId（未知→400+availableVoiceIds）。
   - 映射：`voiceId → sid/checkpoint`，`emotion → 参考音频或风格参数`。
   - 调 `infer(text, sdp_ratio≈0.5, noise_scale≈0.6, noise_scale_w≈0.8, length_scale=控制语速, sid, language="ZH", reference_audio=情绪音频)`。
   - 拿到 44100Hz 波形 → **在内存里**封 WAV（`scipy.io.wavfile`/`soundfile` 写到 `BytesIO`）→ 返回 `audio/wav`。
   - **零留存**：不落盘、不打印文本/音频；参考音频是预置素材不算请求数据。
   - **启动即热加载**：进程起来就把模型 + BERT 常驻 GPU（别每请求加载），这是低延迟的关键。
   - 用 systemd 或 supervisor 守护，带代理 env 启动。
5. **本地自测**（在算力机上）
   ```bash
   curl -sS -m 20 -w "\n[%{http_code}] %{size_download}B %{content_type} ttfb=%{time_starttransfer}s total=%{time_total}s\n" \
     -X POST http://127.0.0.1:8023/v1/perception/swds-speaker-tts \
     -H "Content-Type: application/json" \
     -d '{"text":"我是灵枢，已经在线。","voiceId":"male_steady","emotion":"calm"}' -o /tmp/t.wav && file /tmp/t.wav && rm -f /tmp/t.wav
   ```
   目标：`200`、`audio/wav`、**ttfb < 1s**（短句）。

---

## 4. 网关后端切换（算力机 nginx，**不碰前置网关**）

1. 备份现配置：`cp <nginx-tts.conf> <nginx-tts.conf>.bak.bv2`。
2. 把转发到 `/v1/perception/swds-speaker-tts` 的 `proxy_pass` 从 `127.0.0.1:8021`（CosyVoice2）改到 `127.0.0.1:8023`（Bert-VITS2）。
3. `nginx -t && nginx -s reload`。
4. **保留 CosyVoice2 :8021 不停**，作为"非实时高质量"备用档（长播报/念稿可留着）。
5. 从外部验证对外契约没破：
   ```bash
   curl -sS -m 20 -w "\n[%{http_code}] %{size_download}B %{content_type} ttfb=%{time_starttransfer}s\n" \
     -X POST https://model-gateway.datanet.bj.cn/v1/perception/swds-speaker-tts \
     -H "Content-Type: application/json" -H "X-Model-Token: <token>" \
     -d '{"text":"我是灵枢，已经在线。","voiceId":"male_steady","emotion":"calm"}' -o /tmp/g.wav && file /tmp/g.wav && rm -f /tmp/g.wav
   ```

---

## 5. 验收清单（实测，逐项给证据）

- [ ] **首包延迟**：短句 ttfb < 1s；中长句 < 2s（对外路由实测，非本地）。
- [ ] **情绪可辨**：同一句话用 `emotion=calm / excited / angry` 各合一遍，音频能听出明显差异。
- [ ] **男声真男**：`male_steady` 实测基频 F0 落在男声区（~90-140Hz），别又回女声。
- [ ] **契约未破**：外部 `curl`（§4）返回 200 + `audio/wav`，灵枢客户端**不改任何代码**即可出云端男声。
- [ ] **未知 voiceId**：返回 400 且带 `availableVoiceIds`。
- [ ] **零留存**：服务端确认无文本/音频落盘、无敏感日志。
- [ ] **守护**：服务随机器重启自起，模型热加载（首请求不冷启）。

---

## 6. 灵枢客户端（确认即可，**预期零改动**）

- 现有 `voiceId/emotion` 枚举、端点、`X-Model-Token` 都不变 → **无需改代码**。
- 仅需在切换后由产品侧实测一次：发条正常长度消息，确认听到 Bert-VITS2 云端男声、底部无降级告警。
- 后续可选优化（不阻塞本次，产品侧做）：首包降下来后把客户端 TTS 超时从自适应上限收紧；分句队列加预取流水线消句间空档。

---

## 7. 交接边界

- Codex 负责：算力机上 §3 部署 + §4 算力机 nginx 切换 + §5 实测。
- 需要产品侧/有权限者：前置网关 `172.25.208.8` **本次不需要动**；若将来要上真流式 PCM 端点再议。
- 完成后请回传：§5 清单逐项的实测输出（含 `curl` 原始结果）。
