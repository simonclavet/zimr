# The sound path's performance (Oct 12)

A review of the code that runs for every block of sound - the renderer, the queues, the Windows render thread, the
worklet's program, the page's side - for its cost per block, its use of the caches, and what it does on the threads
that must never wait. Sizes and times are measured (`@sizeOf` on x86-64; Node for the module), not estimated.

## The budget

A block is 128 frames in the worklet (2.67 ms at 48 kHz, 375 blocks a second) and a device period on Windows (about
2.7 ms on the low-latency stream, 10 ms on the standard one). The renderer's work per block is, per sounding voice,
one read of its source into the scratch block and one mixing pass with the gain ramp:

    sample voice    ~25 operations a frame: the fixed-point position split, two interpolations, two stores
    mixing          ~6 operations a frame: two loads, two multiply-adds, the ramp's two increments
    16 voices x 128 frames x ~31 operations   ~64 000 operations a block   - tens of microseconds of a 2 670 budget

So the arithmetic is far inside the budget; what can still hurt is a stall - an allocation, a lock, a collection, a
miss on memory not in the caches - on a thread with a deadline.

## Clean, and as good as this design allows

- *No allocation on the audio threads.* The renderer's scratch block is allocated at `start`; rendering allocates
  nothing (`render_block_most_frames`). Windows renders straight into the device's buffer (`GetBuffer` /
  `ReleaseBuffer`, no copy).
- *No locks.* The command, note and notice queues are single-producer single-consumer rings in Erik Rigtorp's form:
  each side's counter on a cache line of its own (`align(cache_line)` - 128 bytes on x86-64, where lines are fetched
  in pairs), each side keeping the other's counter as last seen, so a push or a pop usually touches no line the other
  thread writes.
- *Bounded work.* Sixty-four slots, sixteen notes, at most one command queue's worth of commands a block.
- *The render thread is scheduled as audio work* (MMCSS's "Pro Audio" task), as JUCE's and miniaudio's are.
- *Precision that does not drift:* positions in 32.32 fixed point, a note's phase in f64, each block's gains ending at
  their exact target.
- *The worklet keeps no handle:* 13 live before 2 000 blocks and 200 messages, 13 after (the worklet test).

## What costs more than it needs to, in order of value for the work

1. **A second audio context on every page that plays sound.** `audio_device.init` makes the older browser-graph layer's
   context (`web.audio.createContext`) eagerly, for `music` and `streams` - beside the renderer's own. Each running
   context keeps an output stream open on the device: CPU and battery for nothing when the app plays no music. Make it
   lazy - made on the first use of `music` or `streams` - or delete it with step 3 of the order (music and streams on
   the mixer).
2. **A voice slot is 2 080 bytes, 133 KB for the 64.** `VoiceSlot.tail_samples` - the copy of a voice's last 5 ms,
   1 920 bytes - sits inside every slot, though only a voice whose samples are freed while it plays ever uses it. The
   state the renderer reads each block is about 180 bytes a slot - three cache lines - spread over 133 KB, the cold copy
   between them. Moved to an array of its own (or a small pool), the hot slots take 12 KB: inside a first-level cache,
   in three pages instead of thirty-three.
3. **The resampling loop keeps its position in memory.** `readSampleSource` reads and writes `voice_slot.source_position`
   through the slot's pointer on every frame while it stores floats into the scratch block; Zig emits no type-based
   alias information, so the compiler cannot prove the stores miss the position, and may load and store it each frame.
   A local copy, written back after the loop, keeps it in a register.
4. **The worklet's glue allocates on every block.** Per block: two new `Float32Array` views of the rendered channels, an
   argument array inside `js_try_call`, and a call into the instance for notices whether or not there are any - about
   1 100 short-lived objects a second on the thread with the deadline. The rendered block's address never changes:
   the two views can be made once and remade only when the instance's memory grows (its buffer then changes).
5. **The page forwards one message per command.** Each command is its own `postMessage`, with its own buffer. A frame's
   commands can travel as one buffer in one message - the worklet's program already accepts several commands in one
   (`acceptCommands`).
6. **Denormals on the Windows render thread.** x86 computes subnormal floats slowly, by default. Nothing in the renderer
   decays into them today (a note ends at 1e-4), but a future instrument's filter or reverb would. Setting flush-to-zero
   and denormals-are-zero (MXCSR) when the render thread starts costs nothing - JUCE does it for every callback.
7. *Fixed (Oct 12):* `page_audio.takeNoticeBytes` built a view of the app's memory before checking whether any notice
   was held, every frame. It now makes nothing until one is.
8. *Fixed (Oct 12), after Simon heard glitches in Chrome:* item 4. A block made five objects - two arrays in
   `js_func`'s wrapper, one in `js_try_call`, two views; now none (`js_func3`, `js_try_call1`, views kept by
   `keepViewsFresh`), and the worklet test counts the views a steady block makes.

## Known costs, kept by design

- **The worklet runs the whole app module.** Its instance takes the module's whole initial memory - 21.8 MB for
  `audio_keyboard`, mostly reserved rather than touched, but the data segments are copied in - and instantiates on the
  audio thread (2 ms in Node on x86; longer on a phone). The price of running the app's own instrument and generators
  there: their function pointers are valid only in the same module. Instantiating asynchronously inside the worklet
  (the reference review's blind spot 6) moves the cost off the first block.
- **Pages and the Windows build are `ReleaseSmall`.** At that level the compiler unrolls and vectorizes little; the
  renderer's arithmetic is far inside the budget, so nothing is to be gained today.
- **The page's frame loop reclaims no handles** (found in stage 3): a few a frame, for the page's life - recorded in the
  plan as a step of its own.

## Against JUCE and miniaudio

How the two libraries answer the same questions (the uploaded copies: `JUCE-master`, miniaudio in `zaudio-main`).

| question | zimr | JUCE | miniaudio |
|---|---|---|---|
| denormals | not handled | `ScopedNoDenormals` offered; its DSP module tells processing code to use it | disabled around every data callback by default - MXCSR's flush-to-zero and denormals-are-zero set, then the caller's state restored (`ma_device_disable_denormals`); `noDisableDenormals` opts out |
| a lock-free queue's two positions | each on a cache line of its own, each side keeping the other's as last seen (Rigtorp) | `AbstractFifo`: `validStart, validEnd` side by side - one line, written by both threads | `ma_rb`: `encodedReadOffset`, `encodedWriteOffset` side by side - one line |
| the resampling position | 32.32 fixed point, through the slot's pointer each frame | a `double` member through `this` each sample - which C++'s strict aliasing lets the compiler keep in a register, a `float` store being unable to change a `double` | - |
| a voice's mix | read into a scratch block, then mixed with the gain ramp: two passes, interleaved | straight into the output, with the envelope, in one pass over planar channels | - |
| the browser's copy out of wasm memory | two new `Float32Array` views every block | - | one view over its rendered buffer, made again only when `view.length == 0` - which is what a view of a buffer detached by the memory's growth reads - and copied out in a loop |
| a block's events | one message per command, each with its own buffer | `MidiBuffer`: a block's events in one contiguous array of bytes, sized ahead (`ensureSize`) so that the audio thread does not allocate | - |
| the worklet's memory | a second instance of the app's module, with its own memory (21.8 MB for `audio_keyboard`) | - | Emscripten's audio worklets run the same module on the page's own memory, a `SharedArrayBuffer` - nothing duplicated, but only on a page that is cross-origin isolated, which a page opened from a file never is |

What follows for the changes. Flush-to-zero as miniaudio does it, but once, when the render thread starts: the thread is
ours, so there is no caller's state to restore. The worklet's views as miniaudio keeps its view, with the same
`length == 0` test for a memory that has grown. A frame's commands in one buffer, as `MidiBuffer` keeps a block's
events. The resampling position in a local - Zig's way to what C++'s aliasing rule gives JUCE for nothing. The queues
stay as they are: both libraries share a line between the two positions, and ours do not.
