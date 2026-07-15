# 感知层模型对接清单（修正版）

> 2026-06-12 经算力机（10.99.134.25）root 核实后修正。所有感知接口走公网网关
> `https://model-gateway.datanet.bj.cn`，鉴权头 `X-Model-Token: <key>`（或 `Authorization: Bearer <key>`）。
> 灵枢只走网关域名，不直连后端端口。

## 一、接口与真实后端

| 对外接口 | 能力 | 后端服务 | 后端模型 | 状态 |
| --- | --- | --- | --- | --- |
| `POST /v1/perception/swds-vision-fast` | 图片 OCR + 目标检测 + 场景语义 | image_parse_service（:8010） | PaddleOCR / grounding-dino / 语义=minimax-m2.7 | **部分降级** |
| `POST /v1/perception/swds-realtime-hearing` | 音频转写 + 文本语义 | media_parse_service（:8020） | SenseVoiceSmall / minimax-m2.7 | ✅ 可用 |
| `POST /v1/perception/swds-vision-deep` | 视频抽帧 OCR/检测 + 转写 + 文本语义 | media_parse_service（:8020） | PaddleOCR / grounding-dino / SenseVoice / minimax-m2.7 | ✅ 可用 |
| `GET /v1/perception/models` | 感知模型列表 | 网关 | — | ✅ 可用 |

其他存在但灵枢未用：`swds-image-parse`、`swds-audio-parse`、`swds-video-parse`（预标注版，后端同上）。

## 二、两个必须知道的修正点

### 1. 目标检测必须传 `detection_queries`
后端逻辑是 `if include_grounding and detection_queries:` 才跑 grounding-dino。**只给 `include_grounding: true` 但不给 `detection_queries`，检测不执行、`detections` 永远为空。**
- 修正：图片/视频请求要带 `detection_queries`，即要检测的对象词列表。
- 实时态势建议默认值：`["person", "face", "screen", "document", "phone", "hand"]`。

### 2. 图片场景语义暂不可用（多模态后端配置错）
`swds-vision-fast` 的 `include_qwen_semantics: true` 会 `400 /models/MiniMax-M2.7 is not a multimodal model`——后端把多模态语义指向了纯文本模型（详见 [CLOUD_GATEWAY.md] 与记忆 datanet-semantics-backend-down）。
- 修正：图片请求保持 `include_qwen_semantics: false`（OCR+检测照常可用）。
- 注意：音频/视频的语义走**纯文本** `chat_json`（只喂转写和 OCR 文字，不传图），不受影响，可正常开启。

## 三、灵枢侧推荐请求参数

**图片（swds-vision-fast）**
```json
{
  "image_base64": "<base64，无 data: 前缀>",
  "prompt": "解析画面文字、人物、物体、场景与风险点",
  "include_ocr": true,
  "include_grounding": true,
  "detection_queries": ["person", "face", "screen", "document", "phone", "hand"],
  "include_qwen_semantics": false
}
```

**音频（swds-realtime-hearing）**
```json
{ "audio_base64": "<WAV base64>", "language": "auto", "include_qwen_semantics": false }
```
（音频语义可设 `true`，后端纯文本路径可用；实时态势为省 token 暂保持 false。）

**视频（swds-vision-deep）**
```json
{
  "video_base64": "<base64>",
  "prompt": "按关键帧理解人物、事件、文字、语音转写与异常",
  "sample_interval_sec": 1,
  "max_keyframes": 8,
  "include_ocr": true,
  "include_grounding": true,
  "detection_queries": ["person", "face", "screen", "document"],
  "include_qwen_semantics": true
}
```

## 四、文件来源约束（不变）
小媒体用 base64；大文件先上传到对象存储/文件服务再传可访问 URL；不要把大文件塞进 JSON。
灵枢客户端默认只在内存中处理媒体，不主动归档原始流。一旦调用远程感知接口，媒体已经离开本机；
服务端是否留存取决于实际部署配置与服务条款，客户端无法单方面验证。详见 [PERCEPTION_AUDIT.md](PERCEPTION_AUDIT.md)。

## 五、灵枢代码待改项
- `LingShuCloudPerceptionClient.analyzeImage/analyzeVideo`：增加 `detection_queries` 参数并默认带上常用对象词，否则目标检测不生效。
- 图片 `include_qwen_semantics` 维持 false（已是默认），待服务端修复多模态后端后再开。
