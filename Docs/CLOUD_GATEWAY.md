# 数据增值协作网络算力中心网关接入

> 2026-06-11 接入并验收。灵枢的默认主通道即此网关，感知专项任务也只走网关域名，不直连底层算力服务器或任何具体模型（MiniMax/Qwen 等）。鉴权、限额、Token 计量、日志与后端路由全部由网关处理。

## 通道一览

| 用途 | 端点 | 调用方 |
| --- | --- | --- |
| 文本/推理/Agent 任务 | `POST /v1/chat/completions` | `LingShuModelGateway` + `LingShuRemoteModelClient`（OpenAI-compatible，chatCompletions 格式） |
| 感知模型列表 | `GET /v1/perception/models` | `LingShuCloudPerceptionClient.listModels()` |
| 图片快速理解 | `POST /v1/perception/swds-vision-fast` | `LingShuCloudPerceptionClient.analyzeImage(...)` |
| 音频/听觉理解 | `POST /v1/perception/swds-realtime-hearing` | `LingShuCloudPerceptionClient.analyzeAudio(...)` |
| 视频/深度视觉理解 | `POST /v1/perception/swds-vision-deep` | `LingShuCloudPerceptionClient.analyzeVideo(...)` |

基础域名：`https://model-gateway.datanet.bj.cn`。预设见 `ModelProviderPreset.dataNetGateway`（`Sources/Domain/LingShuDomainModels.swift`），默认聊天模型 `swds-multimodal-parse`，备用文本模型 `swds-text-parse`。

## 鉴权与凭据安全

- 所有请求携带 `X-Model-Token` 请求头（`LingShuModelGateway.headers` 对“数据网络”供应商的专用分支；感知客户端内置）。
- **Token 不出现在仓库、UserDefaults 或明文文件里**。`LingShuCredentialStore`（`Sources/Services/LingShuCredentialStore.swift`）把凭据存入 macOS 钥匙串（service：`cn.lingshu.model-credentials`，account：provider id）。
- 读取顺序：内存缓存 → 钥匙串 → 环境变量 `LINGSHU_TOKEN_DATANET_GATEWAY`（CI/调试用）。
- 应用启动与切换供应商时自动从凭据仓库填充；在设置页修改 API Key 会写回钥匙串。
- 手工种入/更新 token：
  ```bash
  security add-generic-password -U -s cn.lingshu.model-credentials -a datanet-gateway -w "<TOKEN>"
  ```

## 返回处理约定

- Chat：读取 `choices[0].message.content`；`reasoning_content` 不混入正文（`extractText` 只取 content，思考内容后续可做折叠展示）。
- 感知：归一化为 `LingShuCloudPerceptionResult`（success / task_type / transcript / ocrTexts / detectionCount / semantic_suggestions / warnings / usage / model）。
- 用量：每次调用后读取 `usage.total_tokens`，由 `LingShuState.recordModelUsage` 记入执行轨迹（actor「用量」），流式响应通常无 usage 字段则跳过。

## 文件大小约定

- 小图片/小音频/小视频可用 `image_base64` / `audio_base64` / `video_base64` 字段直传（客户端 API 同时支持 URL 与 base64，二者必传其一）。
- 生产环境大文件**必须**先上传对象存储/文件服务器，把算力服务器可访问的 URL 传给网关；不要把 GB 级文件塞进 JSON 请求体。

## 验收记录（2026-06-11，真实网关最小调用）

1. ✅ `/v1/chat/completions`：X-Model-Token 与 Bearer 两种鉴权均返回正常回复，`usage.total_tokens` 正常计量。
2. ✅ `/v1/perception/models`：返回 6 个专项模型（图片快/预标注、音频实时/预标注、视频预标注/深度）。
3. ✅ 图片：200×80 测试图 OCR 正确识别 “LingShu Test 2026”（score 0.998）。
4. ✅ 音频：本地合成语音 base64 直传，转写正确返回。
5. ✅ 视频：2 秒测试视频返回场景切分 + 关键帧；无音轨时给出 warning 而非失败。
6. ✅ 离线单测覆盖请求契约、响应解析、用量计量与凭据仓库（`Tests/LingShuMacTests/CloudGatewayTests.swift`）。

## 已知注意点

- 网关的 prompt_tokens 基数较大（约 1.3 万），疑似网关侧注入了较长的系统上下文；展示用量时以网关计量为准。
- 应用首次从钥匙串读取 token 时，macOS 可能弹出钥匙串授权框，允许一次即可。
- 感知接口超时设为 300s（视频深度理解耗时较长）。
