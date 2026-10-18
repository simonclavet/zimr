//! src/audio_worklet.zig - the browser's audio worklet program, written in Zig.
//!
//! What an audio worklet is. A browser plays sound on a thread of its own, the audio thread, and a page may run a
//! small program there: an audio worklet. The browser calls the program each time it needs the next 128 frames of
//! sound - every 2.7 milliseconds at 48 000 frames a second - and a block not ready in time is a gap heard. The
//! program must be JavaScript; this file is Zig, made into that JavaScript by the road the jobs worker's program and
//! the bridge itself take (`src/jobs_worker.zig` explains it from the start):
//!
//!     src/audio_worklet.zig --( zig build-obj -ofmt=c )--> audio_worklet.c --( tools/c2js )--> audio_worklet.js
//!
//! What it does. The worklet runs a second instance of the app's own module, and in it the mixer's renderer
//! (`sound.zig`: `RendererHost`, and the worklet's entry points, `worklet_abi`). The main thread's instance sends it
//! the commands - play, stop, set a volume - and the samples it registers, by messages; the worklet renders each block
//! in its own instance, copies it to the browser's output, and sends the renderer's notices back.
//!
//!     main thread: the app's instance                audio thread: this program, and the app's second instance
//!       commands, as bytes        ---- message --->    into the instance, queued for the next block
//!       samples to register       ---- message --->    copied into the instance, registered
//!                                                      process: 128 frames rendered, copied to the output
//!       notices, as bytes         <--- message ----    the renderer's
//!
//! How it is called. Its JavaScript is the worklet's module, whose loader then calls `start` once. `start` registers
//! the processor: a class, which the browser constructs when the page makes an AudioWorkletNode of its name. From then
//! on the browser calls the processor's constructor once (`initializeProcessor`), which asks for the app's module to be
//! linked; once it is, the processor's start (`onModuleLinked`); its `process` for each block (`processBlock`); and its
//! port's message handler for each message the main thread sends (`handleMessage`).
//!
//! Handles. A JavaScript object cannot live in this program's memory, so the program holds handles: numbers naming
//! objects in a table the c2js runtime keeps. A handle keeps its object alive until it is freed, and `process` runs
//! some 375 times a second, so every handle a callback makes is freed before the callback returns - by `defer js_free`
//! on the line after it is made. (The runtime's `js_mark` and `js_reset` cannot do it inside a callback: a new handle
//! can take a freed slot below the mark, which a reset never reaches.)

const sound = @import("sound.zig");

const worklet_abi = sound.mixer.worklet_abi;
const message = worklet_abi.message;

/// A JavaScript value, named by its slot in the c2js runtime's table.
const Handle = u32;

// ---- The c2js runtime's functions this program calls (`tools/c2js.zig`, its kernel) ----

/// The global scope - here, the worklet's.
extern fn js_global() Handle;
/// `object[name]`.
extern fn js_get(
    object: Handle,
    name_pointer: [*]const u8,
    name_length: u32,
) Handle;
/// `+object[name]`: a property as a number.
extern fn js_get_num(
    object: Handle,
    name_pointer: [*]const u8,
    name_length: u32,
) f64;
/// `object[name] = value`.
extern fn js_set(
    object: Handle,
    name_pointer: [*]const u8,
    name_length: u32,
    value: Handle,
) void;
/// `object[index]`.
extern fn js_get_index(object: Handle, index: u32) Handle;
/// `object.name()`, `object.name(a)`, `object.name(a, b)`, `object.name(a, b, c)`: the result as a handle.
extern fn js_call0(
    object: Handle,
    name_pointer: [*]const u8,
    name_length: u32,
) Handle;
extern fn js_call1(
    object: Handle,
    name_pointer: [*]const u8,
    name_length: u32,
    first_argument: Handle,
) Handle;
extern fn js_call2(
    object: Handle,
    name_pointer: [*]const u8,
    name_length: u32,
    first_argument: Handle,
    second_argument: Handle,
) Handle;
extern fn js_call3(
    object: Handle,
    name_pointer: [*]const u8,
    name_length: u32,
    first_argument: Handle,
    second_argument: Handle,
    third_argument: Handle,
) Handle;
extern fn js_call4(
    object: Handle,
    name_pointer: [*]const u8,
    name_length: u32,
    first_argument: Handle,
    second_argument: Handle,
    third_argument: Handle,
    fourth_argument: Handle,
) Handle;
/// `object.name(...arguments)` inside a `try`: `is_ok` says whether it returned, and the handle is its result - or,
/// when it threw, the exception.
/// `object.name(argument)` inside a `try`, building no argument array: as `js_try_call`, for one argument.
extern fn js_try_call1(
    object: Handle,
    name_pointer: [*]const u8,
    name_length: u32,
    argument: Handle,
    is_ok: *u32,
) Handle;
/// A JavaScript function of exactly three arguments calling the Zig function `function` with their handles - as
/// `js_func`, but building no array on each call, for the callback called on every block (`process`).
extern fn js_func3(function: *const anyopaque) Handle;
/// The same, the result discarded.
extern fn js_call1v(
    object: Handle,
    name_pointer: [*]const u8,
    name_length: u32,
    first_argument: Handle,
) void;
extern fn js_call2v(
    object: Handle,
    name_pointer: [*]const u8,
    name_length: u32,
    first_argument: Handle,
    second_argument: Handle,
) void;
extern fn js_call3v(
    object: Handle,
    name_pointer: [*]const u8,
    name_length: u32,
    first_argument: Handle,
    second_argument: Handle,
    third_argument: Handle,
) void;
/// `new constructor(a, b, c)`.
extern fn js_new3(
    constructor: Handle,
    first_argument: Handle,
    second_argument: Handle,
    third_argument: Handle,
) Handle;
/// A JavaScript number, string, empty object and empty array.
extern fn js_num(number: f64) Handle;
extern fn js_str(text_pointer: [*]const u8, text_length: u32) Handle;
extern fn js_obj() Handle;
extern fn js_array() Handle;
/// `array.push(value)`.
/// Appends `value` to `array`, and returns `array`'s own handle - not a new one, never to be freed apart from it.
extern fn js_push(array: Handle, value: Handle) Handle;
/// The number a value holds: `+value`.
extern fn js_to_num(value: Handle) f64;
/// 1 when `value` is truthy, else 0.
extern fn js_truthy(value: Handle) u32;
/// `value.length`.
extern fn js_len(value: Handle) u32;
/// Whether a value is null or undefined: 1 or 0.
extern fn js_is_null(value: Handle) u32;
/// `left === right`: 1 or 0.
extern fn js_strict_eq(left: Handle, right: Handle) u32;
/// A JavaScript function that calls the Zig function at `zig_function`, with a handle for each of its arguments.
extern fn js_func(zig_function: *const anyopaque) Handle;
/// A class extending `base_class`, whose constructor calls the base's, then `initialize` with the new object and the
/// constructor's arguments (`tools/c2js.zig` explains classes).
extern fn js_subclass(base_class: Handle, initialize: Handle) Handle;
/// Frees a handle: its slot may then name another value.
extern fn js_free(value: Handle) void;
/// The handle table's length: reported with the stats, so that a leak in this realm - the audio thread's, which no
/// frame of the page resets - shows on the page's panel as a length that keeps rising.
extern fn js_table_length() u32;
/// Turns the runtime's debugging of handles on (1) or off (0) in this realm, at the page's word (`handleMessage`).
extern fn js_set_handle_debugging(is_on: u32) void;

// ---- The program's state ----

/// What the callbacks share: the handles kept from the constructor - the app instance's exports and memory, the
/// processor's port, and the two typed-array constructors - and the addresses of the instance's command and notices
/// buffers. The browser calls the callbacks with nothing of ours, so they find it here; the worklet has one processor,
/// and so one state.
const ProgramState = struct {
    is_ready: bool = false,
    /// Blocks rendered since the processor started, for its reports to the page (`postStats`).
    blocks_rendered: f64 = 0,
    /// Views of the rendered block in the instance's memory, one a channel, made once and kept
    /// (`renderedChannelView`): a new view each block would make two objects a block on the audio thread, for its
    /// garbage collector to find. Made again only when stale - the block at another address or of another length, or
    /// the instance's memory grown, which detaches the buffer the views were made over (a detached view's length reads
    /// 0, the test miniaudio makes for its own view).
    left_view: Handle = 0,
    right_view: Handle = 0,
    views_address: f64 = 0,
    views_frame_count: f64 = 0,
    /// The worklet's clock - `performance` where the browser gives a worklet one, else `Date` - and what this second's
    /// blocks took: the longest a block's call lasted, and the longest gap from one block's start to the next's
    /// (`postStats`). A long block is this program's work, or a collection, or a function compiled on its first call; a
    /// long gap with short blocks is the thread not being run in time.
    clock: Handle = 0,
    /// Whether that clock is `Date`, which counts whole milliseconds: a block's time then reads 0 or 1 whatever it
    /// took, which the page's panel says beside it.
    is_clock_whole_milliseconds: bool = false,
    last_block_start_ms: f64 = 0,
    longest_block_ms: f64 = 0,
    longest_gap_ms: f64 = 0,
    /// The blocks' durations added up, and their count, since the last report: their mean is the renderer's usual
    /// cost. The clock may count whole milliseconds, so one block reads 0, 1 or 2 ms, but the mean of hundreds is fine.
    block_ms_sum: f64 = 0,
    blocks_since_report: f64 = 0,
    instance_exports: Handle = 0,
    instance_memory: Handle = 0,
    processor_port: Handle = 0,
    float32_array_constructor: Handle = 0,
    uint8_array_constructor: Handle = 0,
    command_buffer_address: f64 = 0,
    notices_buffer_address: f64 = 0,
};
// lint:off module-var: the program's one state - the browser's callbacks carry nothing of ours
var program_state: ProgramState = .{};

// ---- Small helpers over them ----

/// `object[name]`, for a name known when compiling.
fn property(object: Handle, comptime name: []const u8) Handle {
    return js_get(object, name.ptr, name.len);
}

/// `+object[name]`.
/// `value`, or 0 when it is no finite number - a missing property reads as NaN, which fails both comparisons, as an
/// infinity fails one.
fn finiteOrZero(value: f64) f64 {
    const is_finite: bool = value > -1e300 and value < 1e300;
    return if (is_finite) value else 0;
}

fn numberProperty(object: Handle, comptime name: []const u8) f64 {
    return js_get_num(object, name.ptr, name.len);
}

/// `object[name] = value`.
fn setProperty(object: Handle, comptime name: []const u8, value: Handle) void {
    js_set(object, name.ptr, name.len, value);
}

/// A JavaScript string of `text`.
fn string(comptime text: []const u8) Handle {
    return js_str(text.ptr, text.len);
}

/// Whether the JavaScript value `value` is the string `text`.
fn isString(value: Handle, comptime text: []const u8) bool {
    const text_handle: Handle = string(text);
    defer js_free(text_handle);
    return js_strict_eq(value, text_handle) == 1;
}

/// Calls the app instance's export `name` with the given numbers - four at most, as the entry points take
/// (`worklet_abi`) - and returns the number it returns.
fn callExport(comptime name: []const u8, arguments: []const f64) f64 {
    const instance_exports: Handle = program_state.instance_exports;
    const result: Handle = switch (arguments.len) {
        0 => js_call0(instance_exports, name.ptr, name.len),
        1 => call1: {
            const first_argument: Handle = js_num(arguments[0]);
            defer js_free(first_argument);
            break :call1 js_call1(instance_exports, name.ptr, name.len, first_argument);
        },
        2 => call2: {
            const first_argument: Handle = js_num(arguments[0]);
            defer js_free(first_argument);
            const second_argument: Handle = js_num(arguments[1]);
            defer js_free(second_argument);
            break :call2 js_call2(instance_exports, name.ptr, name.len, first_argument, second_argument);
        },
        3 => call3: {
            const first_argument: Handle = js_num(arguments[0]);
            defer js_free(first_argument);
            const second_argument: Handle = js_num(arguments[1]);
            defer js_free(second_argument);
            const third_argument: Handle = js_num(arguments[2]);
            defer js_free(third_argument);
            break :call3 js_call3(
                instance_exports,
                name.ptr,
                name.len,
                first_argument,
                second_argument,
                third_argument,
            );
        },
        4 => call4: {
            const first_argument: Handle = js_num(arguments[0]);
            defer js_free(first_argument);
            const second_argument: Handle = js_num(arguments[1]);
            defer js_free(second_argument);
            const third_argument: Handle = js_num(arguments[2]);
            defer js_free(third_argument);
            const fourth_argument: Handle = js_num(arguments[3]);
            defer js_free(fourth_argument);
            break :call4 js_call4(
                instance_exports,
                name.ptr,
                name.len,
                first_argument,
                second_argument,
                third_argument,
                fourth_argument,
            );
        },
        else => @panic("an export of the worklet's instance is called with at most four numbers"),
    };
    defer js_free(result);
    return js_to_num(result);
}

/// A typed array over `element_count` elements of the app instance's memory, from the byte `byte_address`: a view,
/// through which JavaScript reads and writes that memory directly. `constructor` is `Float32Array` or `Uint8Array`.
/// The memory's buffer is taken afresh each time, since the instance's memory replaces its buffer when it grows.
fn viewOfInstanceMemory(
    constructor: Handle,
    byte_address: f64,
    element_count: f64,
) Handle {
    const memory_buffer: Handle = property(program_state.instance_memory, "buffer");
    defer js_free(memory_buffer);
    const address_handle: Handle = js_num(byte_address);
    defer js_free(address_handle);
    const count_handle: Handle = js_num(element_count);
    defer js_free(count_handle);
    return js_new3(constructor, memory_buffer, address_handle, count_handle);
}

// ---- Linking the app's module ----

/// A stand-in for every function the app's module imports: does nothing, and returns 0. The module imports the browser
/// bridge's functions - the canvas, the GPU, input - none of which the renderer calls, and none of which the worklet
/// has; but a module links only when every import is given.
fn standInForImport() u32 {
    return 0;
}

/// The import object that links the app's module here: `{ module_name: { import_name: stand_in, ... }, ... }`, built
/// from the module's own list of imports (`WebAssembly.Module.imports`). Its names are set with `Reflect.get` and
/// `Reflect.set`, which take a key as a JavaScript value, so that each name stays a JavaScript string throughout.
fn standInImportObject(compiled_module: Handle) Handle {
    const global_scope: Handle = js_global();
    const web_assembly: Handle = property(global_scope, "WebAssembly");
    defer js_free(web_assembly);
    const module_constructor: Handle = property(web_assembly, "Module");
    defer js_free(module_constructor);
    const reflect: Handle = property(global_scope, "Reflect");
    defer js_free(reflect);
    const import_list: Handle = js_call1(module_constructor, "imports", "imports".len, compiled_module);
    defer js_free(import_list);
    const stand_in: Handle = js_func(&standInForImport);
    defer js_free(stand_in);
    const import_object: Handle = js_obj();
    const import_count: u32 = js_len(import_list);
    var import_index: u32 = 0;
    while (import_index < import_count) : (import_index += 1) {
        const import_entry: Handle = js_get_index(import_list, import_index);
        defer js_free(import_entry);
        const module_name: Handle = property(import_entry, "module");
        defer js_free(module_name);
        const import_name: Handle = property(import_entry, "name");
        defer js_free(import_name);
        // The module name's object of imports, made the first time the name is met.
        var namespace: Handle = js_call2(reflect, "get", "get".len, import_object, module_name);
        if (js_is_null(namespace) == 1) {
            js_free(namespace);
            namespace = js_obj();
            js_call3v(reflect, "set", "set".len, import_object, module_name, namespace);
        }
        defer js_free(namespace);
        js_call3v(reflect, "set", "set".len, namespace, import_name, stand_in);
    }
    return import_object;
}

// ---- The main thread's messages ----

/// `{ kind: "commands", bytes }`: each whole command in `bytes` copied into the instance's command buffer, and
/// accepted - queued for the renderer's next block.
fn acceptCommands(data: Handle) void {
    const command_bytes: Handle = property(data, message.bytes_field);
    defer js_free(command_bytes);
    const byte_count: f64 = numberProperty(command_bytes, "byteLength");
    const command_byte_count: f64 = @floatFromInt(worklet_abi.command_byte_count);
    const command_count: f64 = @floor(byte_count / command_byte_count);
    const uint8_constructor: Handle = program_state.uint8_array_constructor;
    const command_buffer_address: f64 = program_state.command_buffer_address;
    var command_index: f64 = 0;
    while (command_index < command_count) : (command_index += 1) {
        const first_byte_handle: Handle = js_num(command_index * command_byte_count);
        defer js_free(first_byte_handle);
        const length_handle: Handle = js_num(command_byte_count);
        defer js_free(length_handle);
        const one_command: Handle = js_new3(uint8_constructor, command_bytes, first_byte_handle, length_handle);
        defer js_free(one_command);
        const command_room: Handle = viewOfInstanceMemory(
            uint8_constructor,
            command_buffer_address,
            command_byte_count,
        );
        defer js_free(command_room);
        js_call1v(command_room, "set", "set".len, one_command);
        _ = callExport(worklet_abi.accept_command, &.{});
    }
}

/// `{ kind: "samples", samplesId, samples }`: room for the samples in the instance's memory, the samples copied in,
/// and registered under the id. With no room - memory ran out - they are not registered, and a voice of them ends at
/// once, silent.
fn acceptSamples(data: Handle) void {
    const samples_id: f64 = numberProperty(data, message.samples_id_field);
    const samples: Handle = property(data, message.samples_field);
    defer js_free(samples);
    const sample_count: f64 = numberProperty(samples, "length");
    const room_address: f64 = callExport(worklet_abi.allocate_samples, &.{ samples_id, sample_count });
    if (room_address == 0) {
        return;
    }
    // The view is made after the allocation, which may have grown the memory and replaced its buffer.
    const float32_constructor: Handle = program_state.float32_array_constructor;
    const room: Handle = viewOfInstanceMemory(float32_constructor, room_address, sample_count);
    defer js_free(room);
    js_call1v(room, "set", "set".len, samples);
    _ = callExport(worklet_abi.register_samples, &.{samples_id});
}

/// `{ kind: "stream", streamId, channels, sampleRate, frames }`: a forwarded stream's frames, copied into the
/// instance's stream buffer and written into the stream's ring there (`worklet_abi.accept_stream_frames`). A message
/// holds at most a ring's worth - the main side forwards no ring larger than the host's
/// (`Mixer.freeForwardedStreamId`), and the buffer holds a host ring's worth of stereo - so one that would not fit is
/// not taken, rather than thrown on.
fn acceptStreamFrames(data: Handle) void {
    const stream_id: f64 = numberProperty(data, message.stream_id_field);
    const channels: f64 = numberProperty(data, message.channels_field);
    const sample_rate: f64 = numberProperty(data, message.sample_rate_field);
    const frames: Handle = property(data, message.frames_field);
    defer js_free(frames);
    const sample_count: f64 = numberProperty(frames, "length");
    const buffer_samples: f64 = @floatFromInt(worklet_abi.stream_frames_buffer_samples);
    if (sample_count > buffer_samples) {
        return;
    }
    const buffer_address: f64 = callExport(worklet_abi.stream_frames_buffer, &.{});
    const float32_constructor: Handle = program_state.float32_array_constructor;
    const room: Handle = viewOfInstanceMemory(float32_constructor, buffer_address, sample_count);
    defer js_free(room);
    js_call1v(room, "set", "set".len, frames);
    _ = callExport(worklet_abi.accept_stream_frames, &.{ stream_id, channels, sample_rate, sample_count });
}

/// `{ kind: "note", key, isDown, velocity }`: a key's event, queued for the instrument at the next block. A key's
/// handler on the main thread posts one as the key moves, so its note waits for no frame: only for the next block.
fn acceptNote(data: Handle) void {
    const key: f64 = numberProperty(data, message.key_field);
    const is_down: f64 = numberProperty(data, message.is_down_field);
    const velocity: f64 = numberProperty(data, message.velocity_field);
    // The times its start is measured from, handed over first (`worklet_abi.stamp_note`); 0 for each a page left out.
    const requested_at_ms: f64 = finiteOrZero(numberProperty(data, message.requested_at_field));
    const pressed_at_ms: f64 = finiteOrZero(numberProperty(data, message.pressed_at_field));
    _ = callExport(worklet_abi.stamp_note, &.{ requested_at_ms, pressed_at_ms });
    _ = callExport(worklet_abi.accept_note, &.{ key, is_down, velocity });
}

/// `{ kind: "analysis" }`: the renderer's last frames mixed, copied into the instance's analysis buffer
/// (`worklet_abi.copy_analysis`) and sent back as `{ kind: "analysis", bytes }` - the buffer's bytes sliced out of
/// the instance's memory and handed over to the main thread, not copied again.
fn sendAnalysis() void {
    const buffer_address: f64 = callExport(worklet_abi.copy_analysis, &.{});
    const byte_count: f64 = @floatFromInt(worklet_abi.analysis_frame_count * @sizeOf(f32));
    const memory_buffer: Handle = property(program_state.instance_memory, "buffer");
    defer js_free(memory_buffer);
    const first_byte_handle: Handle = js_num(buffer_address);
    defer js_free(first_byte_handle);
    const end_byte_handle: Handle = js_num(buffer_address + byte_count);
    defer js_free(end_byte_handle);
    const frame_bytes: Handle = js_call2(memory_buffer, "slice", "slice".len, first_byte_handle, end_byte_handle);
    defer js_free(frame_bytes);
    const answer: Handle = js_obj();
    defer js_free(answer);
    const kind: Handle = string(message.analysis_kind);
    defer js_free(kind);
    setProperty(answer, message.kind_field, kind);
    setProperty(answer, message.bytes_field, frame_bytes);
    const transfer_list: Handle = js_array();
    defer js_free(transfer_list);
    // `js_push` returns the array's own handle, not a new one: nothing to free.
    _ = js_push(transfer_list, frame_bytes);
    js_call2v(program_state.processor_port, "postMessage", "postMessage".len, answer, transfer_list);
}

/// `{ kind: "clock", contextMs, pageMs }`: the context's timeline tied to the page's clock, kept by the instance
/// (`worklet_abi.tie_clocks`) for timing the blocks that follow.
fn tieClocks(data: Handle) void {
    const context_ms: f64 = finiteOrZero(numberProperty(data, message.context_ms_field));
    const page_ms: f64 = finiteOrZero(numberProperty(data, message.page_ms_field));
    if (context_ms <= 0 or page_ms <= 0) {
        return;
    }
    _ = callExport(worklet_abi.tie_clocks, &.{ context_ms, page_ms });
}

/// The port's message handler: one message from the main thread, `event_handle.data`, by its kind.
fn handleMessage(event_handle: Handle) void {
    const data: Handle = property(event_handle, "data");
    defer js_free(data);
    const kind: Handle = property(data, message.kind_field);
    defer js_free(kind);
    if (isString(kind, message.commands_kind)) {
        acceptCommands(data);
    } else if (isString(kind, message.samples_kind)) {
        acceptSamples(data);
    } else if (isString(kind, message.note_kind)) {
        acceptNote(data);
    } else if (isString(kind, message.stream_kind)) {
        acceptStreamFrames(data);
    } else if (isString(kind, message.analysis_kind)) {
        sendAnalysis();
    } else if (isString(kind, message.clock_kind)) {
        tieClocks(data);
    } else if (isString(kind, "debugHandles")) {
        js_set_handle_debugging(@trunc(numberProperty(data, "on")));
    }
}

/// An exception that escaped one of the processor's callbacks - `process`, the port's handler - handed over by the
/// runtime before it goes on (`__zimrOnCallbackError`): sent to the page as a failure with its stack, which the
/// browser's own report of it, `processorerror`, does not carry.
fn reportCallbackError(error_handle: Handle) void {
    const failure_message: Handle = js_obj();
    defer js_free(failure_message);
    const kind_value: Handle = string(message.failed_kind);
    defer js_free(kind_value);
    const stack: Handle = property(error_handle, "stack");
    defer js_free(stack);
    const has_stack: bool = js_truthy(stack) == 1;
    const global_scope: Handle = js_global();
    const failure_text: Handle = js_call1(global_scope, "String", "String".len, if (has_stack) stack else error_handle);
    defer js_free(failure_text);
    setProperty(failure_message, message.kind_field, kind_value);
    setProperty(failure_message, "message", failure_text);
    js_call1v(program_state.processor_port, "postMessage", "postMessage".len, failure_message);
}

// ---- The processor's callbacks ----

/// Sends the renderer's notices, if it has any, to the main thread: `{ kind: "notices", bytes }`, whole notices one
/// after another. The bytes are copied out of the instance's memory (`ArrayBuffer.slice`) and transferred - handed
/// over, not copied again - with the message.
fn sendNotices() void {
    const notice_count: f64 = callExport(worklet_abi.take_notices, &.{});
    if (notice_count == 0) {
        return;
    }
    const notice_byte_count: f64 = @floatFromInt(worklet_abi.notice_byte_count);
    const first_byte: f64 = program_state.notices_buffer_address;
    const end_byte: f64 = first_byte + notice_count * notice_byte_count;
    const memory_buffer: Handle = property(program_state.instance_memory, "buffer");
    defer js_free(memory_buffer);
    const first_byte_handle: Handle = js_num(first_byte);
    defer js_free(first_byte_handle);
    const end_byte_handle: Handle = js_num(end_byte);
    defer js_free(end_byte_handle);
    const notice_bytes: Handle = js_call2(memory_buffer, "slice", "slice".len, first_byte_handle, end_byte_handle);
    defer js_free(notice_bytes);
    const notices_message: Handle = js_obj();
    defer js_free(notices_message);
    const kind: Handle = string(message.notices_kind);
    defer js_free(kind);
    setProperty(notices_message, message.kind_field, kind);
    setProperty(notices_message, message.bytes_field, notice_bytes);
    const transfer_list: Handle = js_array();
    defer js_free(transfer_list);
    // `js_push` returns the array's own handle, not a new one: nothing to free.
    _ = js_push(transfer_list, notice_bytes);
    js_call2v(program_state.processor_port, "postMessage", "postMessage".len, notices_message, transfer_list);
}

/// The worklet's clock, in milliseconds: `performance.now()` where the browser gives a worklet `performance`, else
/// `Date.now()`, whole milliseconds.
fn clockMilliseconds() f64 {
    const now: Handle = js_call0(program_state.clock, "now", "now".len);
    defer js_free(now);
    return js_to_num(now);
}

/// How often the processor reports to the page: at its first block, so that the page sees at once that `process`
/// runs, then every 375 blocks of 128 frames - a second at 48 000 Hz - so that it sees it keeps running.
const blocks_per_report: f64 = 375;

/// Tells the page how many blocks the processor has rendered, the loudest sample and the clicks since its last report
/// (`{ kind: "stats", blocks, peak, clicks, largestJump }`): the page's diagnostics show from it whether the renderer
/// runs, and whether it makes any sound.
fn postStats() void {
    const stats_message: Handle = js_obj();
    defer js_free(stats_message);
    const kind_value: Handle = string(message.stats_kind);
    defer js_free(kind_value);
    const blocks_value: Handle = js_num(program_state.blocks_rendered);
    defer js_free(blocks_value);
    const peak_value: Handle = js_num(callExport(worklet_abi.take_peak, &.{}));
    defer js_free(peak_value);
    // The renderer's click watch since the last report: the clicks, then the largest jump among them.
    const clicks_value: Handle = js_num(callExport(worklet_abi.take_clicks, &.{}));
    defer js_free(clicks_value);
    const largest_jump_value: Handle = js_num(callExport(worklet_abi.taken_largest_jump, &.{}));
    defer js_free(largest_jump_value);
    const clipped_value: Handle = js_num(callExport(worklet_abi.taken_clipped_samples, &.{}));
    defer js_free(clipped_value);
    // The worklet's own clock, `currentFrame`: the frame its blocks have reached on the context's timeline.
    const global_scope: Handle = js_global();
    const frame_value: Handle = property(global_scope, "currentFrame");
    defer js_free(frame_value);
    setProperty(stats_message, message.kind_field, kind_value);
    setProperty(stats_message, message.blocks_field, blocks_value);
    setProperty(stats_message, message.peak_field, peak_value);
    setProperty(stats_message, message.clicks_field, clicks_value);
    setProperty(stats_message, message.largest_jump_field, largest_jump_value);
    setProperty(stats_message, message.clipped_field, clipped_value);
    setProperty(stats_message, "frame", frame_value);
    const longest_block_value: Handle = js_num(program_state.longest_block_ms);
    defer js_free(longest_block_value);
    setProperty(stats_message, "longestBlockMs", longest_block_value);
    const longest_gap_value: Handle = js_num(program_state.longest_gap_ms);
    defer js_free(longest_gap_value);
    setProperty(stats_message, "longestGapMs", longest_gap_value);
    const has_blocks: bool = program_state.blocks_since_report > 0;
    const mean_block_ms: f64 = if (has_blocks) program_state.block_ms_sum / program_state.blocks_since_report else 0;
    const mean_block_value: Handle = js_num(mean_block_ms);
    defer js_free(mean_block_value);
    setProperty(stats_message, "meanBlockMs", mean_block_value);
    // The table's length, read with this message's handles in it: steady from report to report while nothing leaks.
    const table_length: f64 = @floatFromInt(js_table_length());
    const table_length_value: Handle = js_num(table_length);
    defer js_free(table_length_value);
    setProperty(stats_message, "handles", table_length_value);
    const clock_kind_value: Handle = js_num(if (program_state.is_clock_whole_milliseconds) 1 else 0);
    defer js_free(clock_kind_value);
    setProperty(stats_message, "isClockWholeMs", clock_kind_value);
    program_state.longest_block_ms = 0;
    program_state.longest_gap_ms = 0;
    program_state.block_ms_sum = 0;
    program_state.blocks_since_report = 0;
    js_call1v(program_state.processor_port, "postMessage", "postMessage".len, stats_message);
}

/// Makes the two channel views of the rendered block again when they are stale (`ProgramState.left_view`): not made
/// yet, made for another address or length, or detached by the instance's memory growing. Otherwise keeps them: a
/// block then makes no object.
fn keepViewsFresh(rendered_address: f64, frame_count: f64) void {
    const has_views: bool = program_state.left_view != 0;
    const is_same_block: bool = rendered_address == program_state.views_address and
        frame_count == program_state.views_frame_count;
    const is_detached: bool = has_views and js_len(program_state.left_view) == 0;
    if (has_views and is_same_block and !is_detached) {
        return;
    }
    if (has_views) {
        js_free(program_state.left_view);
        js_free(program_state.right_view);
    }
    const float32_constructor: Handle = program_state.float32_array_constructor;
    const bytes_per_sample: f64 = 4;
    const right_address: f64 = rendered_address + frame_count * bytes_per_sample;
    program_state.left_view = viewOfInstanceMemory(float32_constructor, rendered_address, frame_count);
    program_state.right_view = viewOfInstanceMemory(float32_constructor, right_address, frame_count);
    program_state.views_address = rendered_address;
    program_state.views_frame_count = frame_count;
}

/// Tells the page why the processor stopped: `{ kind: "failed", message }`, the message `reason` - an exception, or a
/// promise's rejection - as text, since an exception object need not survive being posted.
fn postFailure(reason: Handle) void {
    const failure_message: Handle = js_obj();
    defer js_free(failure_message);
    const kind_value: Handle = string(message.failed_kind);
    defer js_free(kind_value);
    const global_scope: Handle = js_global();
    const failure_text: Handle = js_call1(global_scope, "String", "String".len, reason);
    defer js_free(failure_text);
    setProperty(failure_message, message.kind_field, kind_value);
    setProperty(failure_message, "message", failure_text);
    js_call1v(program_state.processor_port, "postMessage", "postMessage".len, failure_message);
}

/// Calls the instance's render (`worklet_abi.render`) for `frame_count` frames inside a `try`: the address of the
/// rendered block, or null when it threw - the exception then sent to the page as `{ kind: "failed", message }`, and
/// the processor stopped (`is_ready` false), so that one failure is reported once, with its text.
fn renderCaught(frame_count: f64) ?f64 {
    const frame_count_handle: Handle = js_num(frame_count);
    defer js_free(frame_count_handle);
    var is_ok: u32 = 0;
    const name: []const u8 = worklet_abi.render;
    const result: Handle = js_try_call1(
        program_state.instance_exports,
        name.ptr,
        name.len,
        frame_count_handle,
        &is_ok,
    );
    defer js_free(result);
    if (is_ok == 1) {
        return js_to_num(result);
    }
    program_state.is_ready = false;
    postFailure(result);
    return null;
}

/// The processor's `process`, called by the browser for each block of 128 frames: renders the block in the app's
/// instance, copies each channel to the output - one `set` for each, from a view of the instance's memory - and sends
/// the renderer's notices to the main thread. `outputs_handle` is the processor's outputs: an array of outputs, each
/// an array of channels, each a `Float32Array` of the block's samples. Returns `true`: keep calling. It must be the
/// boolean - c2js gives a Zig `bool` back as one - and not a number: the specification converts the result with
/// `ToBoolean`, but Chrome keeps a processor with no inputs alive only while it returns exactly `true` (its
/// `IsTrue()`), and a 1 there plays a single block, then silence, with no error.
fn processBlock(
    inputs_handle: Handle,
    outputs_handle: Handle,
    parameters_handle: Handle,
) bool {
    _ = inputs_handle;
    _ = parameters_handle;
    const keep_calling: bool = true;
    // Not linked yet: the output stays as the browser hands it, silent.
    if (!program_state.is_ready) {
        return keep_calling;
    }
    // The gap since the last block's start: the browser asks for blocks in bursts, a device period apart, so the
    // usual longest gap is about a period; one much longer means the thread was not run in time.
    const block_start_ms: f64 = clockMilliseconds();
    const has_last_block: bool = program_state.last_block_start_ms != 0;
    if (has_last_block) {
        const gap_ms: f64 = block_start_ms - program_state.last_block_start_ms;
        program_state.longest_gap_ms = @max(program_state.longest_gap_ms, gap_ms);
    }
    program_state.last_block_start_ms = block_start_ms;
    const first_output: Handle = js_get_index(outputs_handle, 0);
    defer js_free(first_output);
    const output_channel_count: u32 = js_len(first_output);
    if (output_channel_count == 0) {
        return keep_calling;
    }
    const left_channel: Handle = js_get_index(first_output, 0);
    defer js_free(left_channel);
    const frame_count: f64 = @floatFromInt(js_len(left_channel));
    // The block's time on the page's clock, from the frame it begins at on the context's timeline
    // (`worklet_abi.time_block`): the renderer measures the sounds it starts by it.
    const global_scope: Handle = js_global();
    const block_frame_value: Handle = property(global_scope, "currentFrame");
    defer js_free(block_frame_value);
    _ = callExport(worklet_abi.time_block, &.{finiteOrZero(js_to_num(block_frame_value))});
    // The block, rendered: the left channel's samples, then the right channel's (`worklet_abi.render`). A throw from
    // the instance is caught and sent to the page, and the processor plays silence from then on.
    const rendered_address: f64 = renderCaught(frame_count) orelse return keep_calling;
    keepViewsFresh(rendered_address, frame_count);
    js_call1v(left_channel, "set", "set".len, program_state.left_view);
    // A second channel, when the output has one: the right samples follow the left.
    if (output_channel_count >= 2) {
        const right_channel: Handle = js_get_index(first_output, 1);
        defer js_free(right_channel);
        js_call1v(right_channel, "set", "set".len, program_state.right_view);
    }
    sendNotices();
    const block_ms: f64 = clockMilliseconds() - block_start_ms;
    program_state.longest_block_ms = @max(program_state.longest_block_ms, block_ms);
    program_state.block_ms_sum += block_ms;
    program_state.blocks_since_report += 1;
    program_state.blocks_rendered += 1;
    const is_first_block: bool = program_state.blocks_rendered == 1;
    const is_report_due: bool = is_first_block or @mod(program_state.blocks_rendered, blocks_per_report) == 0;
    if (is_report_due) {
        postStats();
    }
    return keep_calling;
}

/// Tells the main thread how the processor's start went: `{ kind: "ready" }` once the module is linked and the renderer
/// started, `{ kind: "failed" }` when the renderer could not start. The page shows it; a processor that never says
/// either threw while linking, and the node reports that itself (`processorerror`).
fn postStatus(comptime kind: []const u8) void {
    const status_message: Handle = js_obj();
    defer js_free(status_message);
    const kind_value: Handle = string(kind);
    defer js_free(kind_value);
    setProperty(status_message, message.kind_field, kind_value);
    js_call1v(program_state.processor_port, "postMessage", "postMessage".len, status_message);
}

/// Called by the browser once the app's module is linked: `instance_handle` is the worklet's own instance of it. Starts
/// the renderer host in it, warms the host up - every function a block calls run once, so that the browser compiles
/// them here rather than in a block that is heard (`RendererHost.warmUp`) - then listens on the port and tells the
/// main thread it is ready. The first block rendered comes after all of it.
fn onModuleLinked(instance_handle: Handle) void {
    // Kept for the life of the processor: never freed.
    program_state.instance_exports = property(instance_handle, "exports");
    program_state.instance_memory = property(program_state.instance_exports, "memory");
    const has_started: bool = callExport(worklet_abi.start, &.{}) == 1;
    if (!has_started) {
        postStatus(message.failed_kind);
        return;
    }
    // A warm-up that ran out of memory leaves the renderer as it was: it plays, only without the warm-up.
    _ = callExport(worklet_abi.warm_up, &.{});
    program_state.command_buffer_address = callExport(worklet_abi.command_buffer, &.{});
    program_state.notices_buffer_address = callExport(worklet_abi.notices_buffer, &.{});
    const message_handler: Handle = js_func(&handleMessage);
    defer js_free(message_handler);
    setProperty(program_state.processor_port, "onmessage", message_handler);
    program_state.is_ready = true;
    postStatus(message.ready_kind);
}

/// Called by the browser when the app's module could not be linked: `error_handle` is the reason, sent to the page
/// (`postFailure`). The processor plays silence from then on.
fn onModuleLinkFailed(error_handle: Handle) void {
    postFailure(error_handle);
}

/// The processor's constructor, after the base class's: `this_handle` is the new processor, and `options_handle` the
/// options the page made the node with. It keeps what the callbacks need, and asks the browser to link the app's
/// module - compiled on the main thread, and passed in the options (`worklet_abi.module_option`) - with stand-in
/// imports.
///
/// The linking is asynchronous: `WebAssembly.instantiate(module, imports)` returns a promise at once, and the browser
/// links the module off the audio path, then calls `onModuleLinked` with the instance. A constructor
/// (`new WebAssembly.Instance`) would link inside this call - inside the audio thread's turn, delaying the blocks the
/// browser asks for meanwhile, the first glitch heard on a slow phone. Until the instance is ready the processor plays
/// silence (`processBlock`), and the port does not listen: a port's messages wait in its queue until its `onmessage`
/// is set, so the commands, samples and notes the main thread sends meanwhile are all taken, in order, once it is.
fn initializeProcessor(this_handle: Handle, options_handle: Handle) void {
    const global_scope: Handle = js_global();
    // Kept for the life of the processor: never freed.
    program_state.processor_port = property(this_handle, "port");
    program_state.float32_array_constructor = property(global_scope, "Float32Array");
    program_state.uint8_array_constructor = property(global_scope, "Uint8Array");
    // The finest clock the worklet has: `performance` where the browser gives a worklet one, else `Date`.
    const performance: Handle = property(global_scope, "performance");
    const has_performance_clock: bool = js_truthy(performance) == 1;
    program_state.clock = if (has_performance_clock) performance else property(global_scope, "Date");
    program_state.is_clock_whole_milliseconds = !has_performance_clock;
    const processor_options: Handle = property(options_handle, "processorOptions");
    defer js_free(processor_options);
    const compiled_module: Handle = property(processor_options, worklet_abi.module_option);
    defer js_free(compiled_module);
    const import_object: Handle = standInImportObject(compiled_module);
    defer js_free(import_object);
    const web_assembly: Handle = property(global_scope, "WebAssembly");
    defer js_free(web_assembly);
    // Given a compiled module, `instantiate` resolves to the instance itself.
    const instantiation: Handle = js_call2(
        web_assembly,
        "instantiate",
        "instantiate".len,
        compiled_module,
        import_object,
    );
    defer js_free(instantiation);
    const on_linked: Handle = js_func(&onModuleLinked);
    defer js_free(on_linked);
    const on_failed: Handle = js_func(&onModuleLinkFailed);
    defer js_free(on_failed);
    const chained_promise: Handle = js_call2(instantiation, "then", "then".len, on_linked, on_failed);
    js_free(chained_promise);
}

// ---- The entry point ----

/// Called once by the worklet module's loader, right after the program's text has run: registers the processor
/// under its name (`worklet_abi.processor_name`), as a class extending the browser's `AudioWorkletProcessor`, with
/// `process` on its prototype.
export fn start() void {
    const global_scope: Handle = js_global();
    // The runtime hands an exception escaping a callback to this, with its stack, before it goes on.
    const error_reporter: Handle = js_func(&reportCallbackError);
    defer js_free(error_reporter);
    setProperty(global_scope, "__zimrOnCallbackError", error_reporter);
    const base_class: Handle = property(global_scope, "AudioWorkletProcessor");
    defer js_free(base_class);
    const initialize_function: Handle = js_func(&initializeProcessor);
    defer js_free(initialize_function);
    const processor_class: Handle = js_subclass(base_class, initialize_function);
    defer js_free(processor_class);
    const prototype: Handle = property(processor_class, "prototype");
    defer js_free(prototype);
    // `js_func3`: `process` is called on every block, and builds no array that way.
    const process_function: Handle = js_func3(&processBlock);
    defer js_free(process_function);
    setProperty(prototype, "process", process_function);
    const processor_name: Handle = string(worklet_abi.processor_name);
    defer js_free(processor_name);
    js_call2v(global_scope, "registerProcessor", "registerProcessor".len, processor_name, processor_class);
}

comptime {
    // `start` must survive optimisation: it is the program's only entry point.
    _ = &start;
    // `process`'s result reaches the browser as c2js gives it back: a Zig `bool` as a JavaScript boolean, any number
    // as a number. Chrome calls a processor with no inputs again only while `process` returns exactly `true` - the
    // specification's `ToBoolean` would accept a 1, Chrome's `IsTrue()` does not - so anything but `bool` here plays
    // one block, then silence, with no error.
    const process_return_type: ?type = @typeInfo(@TypeOf(processBlock)).@"fn".return_type;
    if (process_return_type != bool) {
        @compileError("processBlock must return bool: Chrome keeps calling `process` only while it returns exactly " ++
            "`true`, and c2js returns a number as a number");
    }
}
