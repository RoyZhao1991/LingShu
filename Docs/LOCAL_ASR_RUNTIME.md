# LingShu Local ASR Runtime

LingShu treats speech recognition as a perception plugin. The plugin must output normalized text, and the main dialogue pipeline remains unchanged.

## Provider Order

1. SenseVoice / sherpa-onnx embedded runtime
2. Apple Speech fallback
3. FunASR or external realtime adapter

## SenseVoice Asset Layout

The app searches these roots:

- `LingShu.app/Contents/Resources/Models/SenseVoice`
- `~/Library/Application Support/LingShu/Models/SenseVoice`
- `/Users/example/app/LingShuMac/Models/SenseVoice`

Required files:

- `bin/sherpa-onnx-vad-microphone-offline-asr`
- `model.onnx` or `model.int8.onnx`
- `tokens.txt`
- `silero_vad.onnx`

The runtime may also be placed as an extracted sherpa-onnx release folder under the root, for example:

```text
~/Library/Application Support/LingShu/Models/SenseVoice/
  sherpa-onnx-v1.13.2-osx-arm64-shared-no-tts/
    bin/sherpa-onnx-vad-microphone-offline-asr
    lib/libsherpa-onnx-c-api.dylib
  model.int8.onnx
  tokens.txt
  silero_vad.onnx
```

## Installed Footprint

Current local embedded ASR package:

- `sherpa-onnx-v1.13.2-osx-arm64-shared-no-tts`: about 80 MB extracted.
- `sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09`: about 247 MB extracted.
- `silero_vad.onnx`: about 652 KB.
- Total local `SenseVoice` runtime directory after removing download archives: about 328 MB.

The int8 download archive is about 158 MB; the full precision SenseVoice download archive is about 845 MB. The default LingShu embedded profile should use the int8 model first, then allow a user-selected high-precision model path for machines with enough disk and compute budget.

## Runtime Contract

When all required files are present, `VoiceIOManager` launches the local sherpa-onnx microphone runtime with VAD enabled. Every final transcript is normalized and submitted through `submitVoiceTranscript`, exactly like typed text.

If any required file is missing, LingShu disables the SenseVoice provider and safely falls back to Apple Speech.

## TTS Direction

Speech output must remain a replaceable gateway. LingShu no longer ships or recommends a local persona voice model by default; high-quality persona speech should be provided by a cloud or managed TTS model gateway.

Recommended Chinese TTS tiers:

1. Custom cloud TTS gateway. This is the default path. Until an endpoint is configured, LingShu keeps text replies and does not fall back to a local persona voice.
2. CosyVoice3 or another HTTP adapter for streaming product use. It is useful when the model is deployed in LAN or cloud and can provide stronger emotion control.
3. Doubao / Volcengine style cloud voice adapter for small app footprint and many managed voices. The app only stores endpoint, voice ID and credentials; model weights stay in the cloud.

IndexTTS2 is not a default local dependency. It requires a larger Python / model runtime stack and should only be enabled after it can be packaged as a LingShu model pack or exposed through an explicit external adapter. LingShu must not silently assume a local IndexTTS2 service is already running.

## Retired Embedded TTS Asset Layout

The previous development-only sherpa-onnx / VITS package has been removed from the default route because its voice quality was not good enough for LingShu's persona. The code keeps the adapter boundary for future experiments, but production use should prefer cloud TTS.

Previous local roots:

- `LingShu.app/Contents/Resources/Models/SpeechOutput`
- `~/Library/Application Support/LingShu/Models/SpeechOutput`
- `/Users/example/app/LingShuMac/Models/SpeechOutput`

Retired development layout:

```text
~/Library/Application Support/LingShu/Models/SpeechOutput/
  sherpa-onnx-v1.13.2-osx-arm64-shared/
    bin/sherpa-onnx-offline-tts
    lib/libonnxruntime.dylib
  vits-icefall-zh-aishell3/
    model.onnx
    tokens.txt
    lexicon.txt
```

Removed package sizes:

- `sherpa-onnx-v1.13.2-osx-arm64-shared.tar.bz2`: about 25 MB.
- `vits-icefall-zh-aishell3.tar.bz2`: about 31.6 MB.
- Extracted runtime: about 85 MB.
- Extracted Chinese VITS model: about 219 MB.

These assets should not be reintroduced as an invisible dependency. If a local voice model is tested again later, it must be an explicit optional model pack with clear quality acceptance criteria.

Default persona direction:

- `soft-dominant-young-male`: young male, clean and approachable, calm and confident, warm but controlled. This is LingShu's first "温柔霸总男声" profile.

LingShu's speech output path is a gateway. The UI selects a provider, endpoint and persona. Cloud providers must expose a LingShu-compatible HTTP endpoint:

```json
{
  "text": "我是灵枢，有什么可以帮你的？",
  "provider": "cosyVoice3Service",
  "voiceID": "lingshu_soft_dominant_male",
  "speakerID": 0,
  "personaPrompt": "young male voice persona prompt",
  "emotionPrompt": "calm, confident, slightly warm",
  "speed": 0.96,
  "pitch": 0.92,
  "volume": 1.0,
  "responseFormat": "wav",
  "locale": "zh-CN"
}
```

The endpoint can return raw audio bytes or JSON containing `audio_base64` / `audio_url`. Large emotional TTS checkpoints are optional model packs or cloud adapters, not hidden runtime requirements.
