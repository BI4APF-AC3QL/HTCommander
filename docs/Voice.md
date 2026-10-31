# Voice

Handi-Talky Commander transcribes received radio audio entirely on the device. Audio stays in memory and is not written to disk. Select a model under **Settings → Comms → Speech Recognition** and download it there; the model is optional and is not bundled with the app.

Available models include SenseVoice for Chinese, English, Japanese, Korean and Cantonese; FireRed ASR 2 CTC for Chinese/English and 20+ Chinese dialects or accents; Whisper Tiny/Base for English; Whisper Small/Medium for multilingual recognition; and Zipformer for low-latency English streaming. FireRed is the recommended model to try for Chinese radio traffic: its Sherpa ONNX model is designed for fast CPU decoding and the download is about 740 MB. Whisper Medium has the largest Whisper model in the app and needs considerably more disk space, memory and CPU time. Download sizes shown in the app are estimates.

The language selector can provide a hint to multilingual models. Recognition runs in a background worker, but larger models can still use substantial CPU and may take longer to produce each result. FireRed has not been benchmarked against this app's real radio audio, so compare it with SenseVoice using a few received recordings before choosing a default. Choose Whisper Medium only if the computer has enough memory and slower results are acceptable.

Recognition runs when the radio no longer receives a signal or every 20 to 30 seconds.

In addition, the app supports text-to-speech (TTS). Windows uses Microsoft Speech API, Android uses the system TextToSpeech service, and Apple platforms use AVSpeechSynthesizer. Voice preview playback is local and does not send audio to the radio.

Windows also supports optional offline Kokoro 1.1 (Chinese and English, 103 voices) and MeloTTS Chinese/English models. Download and extract the original model folders into the TTS model folder opened from **Settings → Comms → Text-to-Speech**, then refresh the voice list. Inference runs on a background isolate; rate is supported, while pitch adjustment does not apply to these models. Models are not bundled. See [语音合成模型使用方法.md](语音合成模型使用方法.md) for installation instructions and upstream links.
