# Sound against the references (Oct 12)

Five references read against zimr's sound system - the mixer, its renderer, the instrument, the outputs and the
latency readout - looking for where they differ and why. The aim is the lag of a key's sound; the review ends with
the blind spots found, each with its evidence and the change it asks for. Line numbers are those of the uploaded
copies (`JUCE-master`, `zaudio-main`, `sfizz-develop`, `zoto-main`, `groovebasin`).

## 1. What each reference is, for this question

- **JUCE** (`modules/juce_audio_devices`, `juce_audio_basics`, `juce_audio_utils`) - the reference for Windows and for
  notes: `native/juce_WASAPI_windows.cpp` (the output), `midi_io/juce_MidiMessageCollector.cpp` (timestamped events
  into blocks), `midi/juce_MidiKeyboardState.cpp` and `gui/juce_MidiKeyboardComponent.cpp` (a computer keyboard
  playing notes), `synthesisers/juce_Synthesiser.cpp` (voices, stealing, sub-block rendering), `utilities/juce_ADSR.h`,
  `core/containers/juce_AbstractFifo.h`. JUCE has **no browser audio device**: its only wasm file is
  `juce_core/native/juce_SystemStats_wasm.cpp`.
- **miniaudio**, inside `zaudio` (`libs/miniaudio/miniaudio.h`, 95 864 lines) - the reference for the browser, and a
  second one for WASAPI.
- **sfizz** (`src/sfizz`) - a sampler built for hundreds of voices: stealing, fast release, overflow voices.
- **zoto** (`src/driver_js.zig`, `driver_windows.zig`) - a Zig port of Go's `oto`: the browser output pushed from the
  main thread, a worklet copying from a growing buffer, 8 192 frames by default (170 ms at 48 kHz). The design our old
  push path had; nothing for latency.
- **groovebasin** - the snapshot's player is metadata tooling (chromaprint, MusicBrainz, AcoustID); no audio output to
  compare.

## 2. The outputs

### Windows (WASAPI)

| | zimr | JUCE | miniaudio |
|---|---|---|---|
| low-latency stream | `IAudioClient3`, shortest period, tried first | in "low latency" mode, at the chosen buffer size, a multiple of the fundamental period | `IAudioClient3` when the wanted period allows, multiple of fundamental, clamped |
| format of the low-latency stream | **ours, 48 kHz stereo float** | from `GetMixFormat` | the device's mix format; the conversion flags removed (`0x88890021` otherwise, contrary to the documentation) |
| standard stream's buffer | **20 ms** asked | one device period (`GetDevicePeriod` default, 10 ms) | from the period size and period count |
| what is written at each event | all the room (`buffer - padding`) | one block of the callback's size, written as room appears; it waits on the event when there is not enough | the period |
| thread | "Pro Audio" (AVRT) | "Pro Audio", priority normal | the usage's task name, "Pro Audio" for pro audio |
| reported latency | `t3` = padding at the event; `t4` = `GetStreamLatency` | `GetStreamLatency + buffer size` | - |
| timing given to the callback | `AudioRenderTiming` (asked, first frame out) | **none on WASAPI** - the callback's context is `{}` | - |

Ours keeps up with both where it matters (the low-latency stream, no conversion flags on it, MMCSS), and measures more
than JUCE does on this platform. The differences are the format and the standard buffer (blind spots 1 and 2).

### The browser

No reference does what we do. miniaudio's worklets (`MA_ENABLE_AUDIO_WORKLETS`) need Emscripten's wasm workers
(`-sAUDIO_WORKLET=1 -sWASM_WORKERS=1`): the worklet runs the C code on the page's own memory, a `SharedArrayBuffer`,
which needs the page to be cross-origin isolated (COOP and COEP headers) - impossible for a page opened from a file,
and for Claude's viewer. Without it miniaudio uses a ScriptProcessorNode. zoto pushes. Ours - a second instance of the
app's module in the worklet, reached by messages - works where no shared memory is allowed, at the price of copying
samples and of commands crossing as messages. Emscripten shows that a compiled `WebAssembly.Module` does cross into
an AudioWorklet in Chrome; it then instantiates it **asynchronously** inside the worklet. We instantiate it
synchronously, in the processor's constructor, on the audio thread (blind spot 6).

`latencyHint`: none of ours, so `"interactive"` - miniaudio's low-latency profile asks the same.

## 3. Events into blocks

| | zimr | JUCE |
|---|---|---|
| queue | lock-free, one producer each (`NoteQueue` x 2) | a lock (`MidiMessageCollector`, `MidiKeyboardState`) |
| where in the block an event starts | **the block's first frame**, every event | at a sample within the block, by its arrival time since the last callback: relative timing kept, about one block of delay (`removeNextBlockOfMessages`) |
| rendering around events | the whole block after applying the events | split at each event's sample (`processNextBlock`, sub-blocks of at least 32 frames) |
| a computer keyboard | `audio_keyboard`: "a w s e d f t g y h u j k o l p ;" | `MidiKeyboardComponent`: the same keys |
| auto-repeat | `isKeyPressed` reads `pressed_this_frame`; repeats are `isKeyPressedRepeat` | key state, a bitset of pressed notes: only changes act |
| focus lost | the engine releases held keys (`releaseHeld`), so the example releases its notes | `focusLost` releases every key in use |

Starting every event at the block's start gives the least latency and up to one block of jitter: 2.7 ms on the
low-latency stream, **10 ms on the standard one** - as large as the lag being cut (blind spot 4).

## 4. Voices

| | zimr | JUCE | sfizz |
|---|---|---|---|
| the same key again | a second voice beside the first | the ringing voice of that note released (with its tail), then a new one | per region settings |
| stealing | the voice with most frames generated, whatever its state | same note first; then the oldest released; then the oldest with no key down; then the oldest not protecting the lowest or highest held note | by envelope power and age: among the older voices, the first quieter than half the average |
| the stolen voice | a 5 ms fade, kept aside and mixed in (`keepFadeOfStolenNote`) | `stopNote(allowTailOff = false)`: the voice's own business, often a cut | a 10 ms fast release, in one of 1.5 x the voices kept as overflow |
| attack | the instrument's (the sine starts at a zero crossing) | `ADSR` per voice | its envelopes |

## 5. Blind spots

1. **The low-latency stream opens only when the device's engine runs at our format.** `openLowLatencyClient` passes
   our 48 kHz stereo float to `GetSharedModeEnginePeriod` and `InitializeSharedAudioStream`; both refuse any format
   but the engine's own (miniaudio's comment at line 23 915), so on a 44.1 kHz device, or one mixing more channels,
   we fall back to the standard stream without saying why. *Change:* read `GetMixFormat` and open the low-latency
   stream at the device's rate and channel count, converting to it ourselves (the mixer at the device's rate, or our
   resampler on the output), and report the format and the reason in the `output:` line.
2. **The standard stream asks twice JUCE's buffer.** 20 ms where JUCE asks one device period, 10 ms; with all the room
   filled at each event, a new sound waits behind `buffer - period` - 10 ms of the 23 ms we measured on paper.
   *Change (step 5):* ask one period, measure the buffer Windows grants, then fill to a target rather than to the
   brim.
3. **Stealing takes a held note while released ones ring.** *Change:* JUCE's order - the same key's voice first, then
   the oldest released, then the oldest unheld, protecting the lowest and highest held notes; or sfizz's - the
   quietest among the older voices, which needs a voice's recent loudness (the renderer can keep each slot's peak
   while mixing).
4. **The same key again stacks voices.** A key struck again while its note rings adds a voice beside it; a trill uses
   up the sixteen slots. *Change:* JUCE's rule - release the ringing voice of that key with its tail, then start the new
   note.
5. **Events start at the block's start: jitter as large as a period.** On the standard stream that is 10 ms of
   jitter, larger than the lag the plan cuts. Every note already carries its time and every block its timing, so a
   note can start at the frame its time names (`requested + delay - block start`), rendered by splitting the block
   as JUCE does. *Change:* make the timestamp's placement real (it was the instrument's option on paper), and show
   jitter in the readout - the spread of `t2` over the last notes.
6. **The worklet links a 3.9 MB module synchronously on the audio thread.** `new WebAssembly.Instance` in the
   processor's constructor, then the first blocks compile their functions on first call - all on the thread that must
   deliver a block every 2.7 ms. A plausible source of Simon's "glitch at first"; whether it also explains the silence
   the diagnostics build will tell. *Change:* instantiate with `WebAssembly.instantiate` (asynchronous) inside the
   worklet, as Emscripten does, playing silence until it resolves; warm the renderer's functions once before
   reporting `ready`.
7. **Step 6's raw input sees every key, focused or not.** `RIDEV_INPUTSINK` delivers keys while another window has the
   focus: typing elsewhere would play notes. Raw input also repeats a held key's down event, and it bypasses the
   engine's release on focus loss. *Change:* the input thread sends notes only while the window has the focus, keeps
   a bitset of the keys it pressed (JUCE's `keysPressed`) so that repeats are ignored, and releases them all when the
   focus leaves.
8. **Nothing guarantees an attack.** Our instrument interface leaves the attack to the instrument; the sine starts at
   a zero crossing and so does not click, but a sample or a waveform starting elsewhere would. *Change:* a minimum
   attack ramp of a millisecond or two in the renderer for a note's first frames, as JUCE's voices and sfizz's
   envelopes give.

Not blind spots, checked: the lock-free queues (JUCE locks); MMCSS; key repeats and focus loss on the frame path; the
stolen note's fade (JUCE often cuts); the measurement itself (more than JUCE gives on WASAPI).
