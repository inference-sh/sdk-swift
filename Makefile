# InferenceSDK — make test | make e2e | make test-linux

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

.PHONY: build test test-linux e2e clean

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

clean:
	rm -rf .build
