# InferenceSDK — make test | make e2e | make live | make dictate | make audio-e2e | make test-linux

SWIFT_IMAGE ?= swift:5.10-jammy

# Live check: make e2e AGENT=namespace/agent
#   TTS_APP=inworld/text-to-speech-1-5-mini   also synthesize + download the reply
#   INTERRUPT_AFTER=2                          stop the chat mid-run, expect `cancelled`
#   STT_APP="elevenlabs/stt language_code=eng"  transcribe STT_FILE and send that
AGENT ?= okaris/delta-test-agent
TEXT ?= Reply with exactly: swift sdk e2e ok
TTS_APP ?=
INTERRUPT_AFTER ?=
STT_APP ?=
STT_FILE ?= Tests/InferenceSDKTests/Fixtures/ptt-e2e-ok.wav

# Live check of a stream function: make live APP=infsh/voice-loop
#   AUDIO_FILE=mic.wav     16-bit PCM WAV streamed into the function's audio input
#   SEND='{"effect":"echo"}'  a JSON frame to send once the app is there
#   STAY=5                 seconds to stay before closing
APP ?= infsh/voice-loop
AUDIO_FILE ?=
SEND ?=
STAY ?= 5

.PHONY: build test test-linux e2e live dictate audio-e2e clean

build:
	swift build

test:
	swift test

# The library is Foundation-only; this is the check that it stays that way.
test-linux:
	docker run --rm -v "$(CURDIR)":/pkg -w /pkg $(SWIFT_IMAGE) swift test --build-path /tmp/build

e2e:
	@test -n "$$INFERENCE_API_KEY" || { echo "set INFERENCE_API_KEY"; exit 2; }
	TTS_APP=$(TTS_APP) INTERRUPT_AFTER=$(INTERRUPT_AFTER) STT_APP=$(STT_APP) STT_FILE=$(STT_FILE) \
		swift run agent-run "$(AGENT)" "$(TEXT)"

live:
	@test -n "$$INFERENCE_API_KEY" || { echo "set INFERENCE_API_KEY"; exit 2; }
	AUDIO_FILE=$(AUDIO_FILE) SEND='$(SEND)' STAY=$(STAY) TRANSPORT=$(TRANSPORT) swift run live-run $(APP)

# Live dictation (InferenceAudio): make dictate APP=xai/grok-stt
#   AUDIO_FILE=speech.wav   feed a WAV in real time instead of the microphone
#   STOP_AFTER=10           stop the microphone after this long (default: Enter)
#   BACKEND=recorder        the microphone backend (engine, recorder; default automatic)
#   BATCH=1                 no streaming: record, transcribe on release
dictate: APP = xai/grok-stt
dictate:
	@test -n "$$INFERENCE_API_KEY" || { echo "set INFERENCE_API_KEY"; exit 2; }
	AUDIO_FILE=$(AUDIO_FILE) swift run live-dictate $(APP)

# Voice call round trip through LiveVoiceCall: a file stands in for the
# microphone, infsh/voice-loop echoes it. LIVE_E2E_WAV=speech.wav, LIVE_E2E_PLAY=1.
audio-e2e:
	@test -n "$$INFERENCE_API_KEY" || { echo "set INFERENCE_API_KEY"; exit 2; }
	LIVE_E2E=1 swift test --filter LiveE2ETests

clean:
	rm -rf .build
