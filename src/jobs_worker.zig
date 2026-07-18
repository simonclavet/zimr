//! src/jobs_worker.zig — THE WEB WORKER, WRITTEN IN ZIG.
//!
//! ===========================================================================================
//! IF YOU KNOW ZIG BUT HAVE NEVER TOUCHED JAVASCRIPT, START HERE
//! ===========================================================================================
//!
//! WHAT A WORKER IS.
//! A browser runs your whole page on ONE thread. Anything slow you do on that thread — encoding
//! a PNG, tracing a ray — freezes the entire user interface for as long as it runs. A *Web
//! Worker* is a second operating-system thread with its own, completely separate memory. It
//! cannot touch the page, the canvas, or the GPU. The only thing it can do is: receive a
//! message, compute, send a message back. Think of it as a child process you talk to over a
//! pipe that carries raw bytes.
//!
//! HOW THIS FILE BECOMES THAT THREAD.
//! The browser will only start a worker from a JAVASCRIPT program. We do not write that
//! JavaScript by hand. This file is Zig, and the build translates it:
//!
//!     src/jobs_worker.zig
//!         --( zig build-obj -ofmt=c )-->  jobs_worker.c
//!         --( tools/c2js           )-->  jobs_worker.js
//!         --( c2js --worker-js-embed )-->  window.ZIMR_WORKER_JS, inside the page
//!
//! and `bridge.zig` hands that string to the browser as the worker's program. So the code below
//! IS the worker. It merely gets translated on the way. (`src/bridge.zig` — the entire browser
//! side of zimr — is built by the exact same path. This is the established road, not a new one.)
//!
//! HOW ZIG TOUCHES A BROWSER OBJECT.
//! A JavaScript object cannot live inside Zig's memory, so we never hold one. We hold a
//! `JsHandle`: an index into a table that the c2js runtime keeps on the JavaScript side.
//! `JsValue` wraps one of those handles and gives it methods, so that this Zig:
//!
//!     const message_object: JsValue = event_object.getProperty("data");
//!     const job_handle: f64        = message_object.getNumberProperty("handle");
//!     _ = globalScope().callMethod("postMessage", .{reply_object});
//!
//! reads exactly like this JavaScript:
//!
//!     const message_object = event_object.data;
//!     const job_handle     = message_object.handle;
//!     postMessage(reply_object);
//!
//! You are writing JavaScript's semantics in Zig's syntax, with Zig's type checker on top of it.
//!
//! WHAT A CALLBACK IS.
//! The browser never calls `main()`. It calls YOU — later, when a message arrives — by invoking
//! whatever function you stored in the global variable named `onmessage`. `asJsFunction()` wraps
//! a Zig function so the runtime is able to invoke it. That is this file's entire control flow:
//! register one callback, then get called.
//!
//! ===========================================================================================
//! WHY IT IS WORTH THE TROUBLE OF WRITING THIS IN ZIG
//! ===========================================================================================
//!
//! This used to be about forty lines of hand-written JavaScript, living inside a Zig string
//! literal. It was the ONLY hand-written JavaScript in the whole engine, and it produced the two
//! worst bugs the jobs system has ever had.
//!
//!   BUG ONE — THE ABI WAS SPELLED TWICE.
//!   `jobs.zig` wrote `@export(&Worker.alloc, .{ .name = "zimr_job_alloc" })`.
//!   The JavaScript wrote `exports.zimr_job_alloc(n)`.
//!   Two string literals, in two languages, and NOTHING checked that they agreed. Rename one and
//!   the worker fails SILENTLY: no error, no result, just a job that never comes back, forever.
//!   Every one of those names now lives in `src/jobs_abi.zig`, and all three sides read it.
//!
//!   BUG TWO — THE HANDLER WAS `async`, AND THAT WAS A LIVE, SHIPPED BUG.
//!   The old JavaScript did `await WebAssembly.instantiate(...)`. In JavaScript, `await` YIELDS:
//!   the function pauses, and the browser is then free to deliver the NEXT message, which
//!   re-enters this same handler while the kernel's exports are still unset. A job that arrived
//!   inside that window threw an exception inside the worker and was never heard from again — no
//!   error, no result, nothing to grep for.
//!
//!   `worker_png` never hit it, because it submits ONE job, many frames after the pool boots.
//!   `rt_workers` submits SIXTEEN jobs on its very first frame — the same frame the pool spawns —
//!   and hit it every single time. Sixteen tiles dispatched. Zero returned. Silence.
//!
//!   In Zig there is no `await` to reach for. `instantiateKernelWasm` below is an ordinary
//!   blocking function call. The bug is not defended against; it is UNWRITABLE.

// ===========================================================================================
// SECTION 1 — THE c2js INTEROP KERNEL
//
// c2js emits a JavaScript implementation of every `extern fn` below, into every program it
// translates. These are the only way Zig code can reach the browser, and they are the same
// primitives `src/bridge.zig` uses.
//
// You do not need to read this section to understand the worker. `JsValue`, in section 2,
// hides all of it.
// ===========================================================================================

/// An index into the c2js runtime's table of live JavaScript objects.
///
/// Zig never holds a JavaScript object — it cannot; a JS object does not live in linear memory.
/// It holds one of these integers and asks the runtime to act on the object it names.
pub const JsHandle = u32;

/// The handle of `globalThis` — in a worker, the object that owns `onmessage` and `postMessage`.
extern fn js_global() JsHandle;

/// `object[property_name]` -> a JavaScript value.
extern fn js_get(
    object: JsHandle,
    property_name_pointer: [*]const u8,
    property_name_length: u32,
) JsHandle;

/// `object[property_name]` -> a number. (JavaScript has exactly one number type, and it is f64.)
extern fn js_get_num(
    object: JsHandle,
    property_name_pointer: [*]const u8,
    property_name_length: u32,
) f64;

/// `object[property_name] = value`
extern fn js_set(
    object: JsHandle,
    property_name_pointer: [*]const u8,
    property_name_length: u32,
    value: JsHandle,
) void;

/// `object[property_name] = number`
extern fn js_set_num(
    object: JsHandle,
    property_name_pointer: [*]const u8,
    property_name_length: u32,
    number: f64,
) void;

/// `object[method_name]()`
extern fn js_call0(
    object: JsHandle,
    method_name_pointer: [*]const u8,
    method_name_length: u32,
) JsHandle;

/// `object[method_name](first_argument)`
extern fn js_call1(
    object: JsHandle,
    method_name_pointer: [*]const u8,
    method_name_length: u32,
    first_argument: JsHandle,
) JsHandle;

/// `object[method_name](first_argument, second_argument)`
extern fn js_call2(
    object: JsHandle,
    method_name_pointer: [*]const u8,
    method_name_length: u32,
    first_argument: JsHandle,
    second_argument: JsHandle,
) JsHandle;

/// `new constructor()`
extern fn js_new0(constructor: JsHandle) JsHandle;

/// `new constructor(first_argument)`
extern fn js_new1(constructor: JsHandle, first_argument: JsHandle) JsHandle;

/// `new constructor(first_argument, second_argument)`
extern fn js_new2(
    constructor: JsHandle,
    first_argument: JsHandle,
    second_argument: JsHandle,
) JsHandle;

/// `new constructor(first_argument, second_argument, third_argument)`
extern fn js_new3(
    constructor: JsHandle,
    first_argument: JsHandle,
    second_argument: JsHandle,
    third_argument: JsHandle,
) JsHandle;

/// A Zig f64, as a JavaScript number.
extern fn js_num(number: f64) JsHandle;

/// A Zig string, as a JavaScript string.
extern fn js_str(string_pointer: [*]const u8, string_length: u32) JsHandle;

/// JavaScript's `Number(value)`. See the warning on `JsValue.asNumber` before you use it.
extern fn js_to_num(value: JsHandle) f64;

/// JavaScript's `if (value)`. Returns 0 for the falsy values: null, undefined, 0, "".
extern fn js_truthy(value: JsHandle) u32;

/// JavaScript's `left === right`. On two strings this compares BY VALUE.
extern fn js_strict_eq(left: JsHandle, right: JsHandle) u32;

/// Wrap a Zig function pointer so the JavaScript runtime is able to call it.
extern fn js_func(zig_function_pointer: *const anyopaque) JsHandle;

/// `[]` — a new, empty JavaScript array.
extern fn js_array() JsHandle;

/// `array.push(value)`
extern fn js_push(array: JsHandle, value: JsHandle) JsHandle;

// ===========================================================================================
// SECTION 2 — A JAVASCRIPT VALUE, AS SEEN FROM ZIG
// ===========================================================================================

/// One JavaScript value, held by handle.
///
/// Two translations get you through this entire file:
///
///     value.getProperty("foo")        is      value.foo
///     value.callMethod("bar", .{x})   is      value.bar(x)
const JsValue = struct {
    handle: JsHandle,

    /// `self.property_name`
    fn getProperty(
        self: JsValue,
        comptime property_name: []const u8,
    ) JsValue {
        const result_handle: JsHandle = js_get(
            self.handle,
            property_name.ptr,
            property_name.len,
        );
        return .{ .handle = result_handle };
    }

    /// `self.property_name`, when you already know it holds a number.
    fn getNumberProperty(
        self: JsValue,
        comptime property_name: []const u8,
    ) f64 {
        return js_get_num(self.handle, property_name.ptr, property_name.len);
    }

    /// `self.property_name = value`
    fn setProperty(
        self: JsValue,
        comptime property_name: []const u8,
        value: JsValue,
    ) void {
        js_set(self.handle, property_name.ptr, property_name.len, value.handle);
    }

    /// `self.property_name = number`
    fn setNumberProperty(
        self: JsValue,
        comptime property_name: []const u8,
        number: f64,
    ) void {
        js_set_num(self.handle, property_name.ptr, property_name.len, number);
    }

    /// `self.method_name(...arguments)`
    fn callMethod(
        self: JsValue,
        comptime method_name: []const u8,
        arguments: anytype,
    ) JsValue {
        const argument_count: usize = arguments.len;

        if (argument_count == 0) {
            const result_handle: JsHandle = js_call0(
                self.handle,
                method_name.ptr,
                method_name.len,
            );
            return .{ .handle = result_handle };
        }

        if (argument_count == 1) {
            const first_argument: JsValue = arguments[0];
            const result_handle: JsHandle = js_call1(
                self.handle,
                method_name.ptr,
                method_name.len,
                first_argument.handle,
            );
            return .{ .handle = result_handle };
        }

        if (argument_count == 2) {
            const first_argument: JsValue = arguments[0];
            const second_argument: JsValue = arguments[1];
            const result_handle: JsHandle = js_call2(
                self.handle,
                method_name.ptr,
                method_name.len,
                first_argument.handle,
                second_argument.handle,
            );
            return .{ .handle = result_handle };
        }

        @compileError("jobs_worker: callMethod takes at most 2 arguments; this file needs no more");
    }

    /// `new self(...arguments)` — JavaScript's constructor call, e.g. `new Uint8Array(b, p, n)`.
    fn construct(self: JsValue, arguments: anytype) JsValue {
        const argument_count: usize = arguments.len;

        if (argument_count == 0) {
            return .{ .handle = js_new0(self.handle) };
        }

        if (argument_count == 1) {
            const first_argument: JsValue = arguments[0];
            return .{ .handle = js_new1(self.handle, first_argument.handle) };
        }

        if (argument_count == 2) {
            const first_argument: JsValue = arguments[0];
            const second_argument: JsValue = arguments[1];
            const result_handle: JsHandle = js_new2(
                self.handle,
                first_argument.handle,
                second_argument.handle,
            );
            return .{ .handle = result_handle };
        }

        if (argument_count == 3) {
            const first_argument: JsValue = arguments[0];
            const second_argument: JsValue = arguments[1];
            const third_argument: JsValue = arguments[2];
            const result_handle: JsHandle = js_new3(
                self.handle,
                first_argument.handle,
                second_argument.handle,
                third_argument.handle,
            );
            return .{ .handle = result_handle };
        }

        @compileError("jobs_worker: construct takes 0, 1, 2 or 3 arguments");
    }

    /// JavaScript's `if (self)`. Note that `null`, `undefined`, `0` and `""` are all FALSY —
    /// which is why a missing kernel export can be detected simply by asking whether it is
    /// truthy.
    fn isTruthy(self: JsValue) bool {
        return js_truthy(self.handle) != 0;
    }

    /// `self === other`. For two JavaScript strings this compares BY VALUE, not by identity,
    /// which is what makes it the right way to test a message tag.
    fn strictlyEquals(self: JsValue, other: JsValue) bool {
        return js_strict_eq(self.handle, other.handle) != 0;
    }

    /// `Number(self)` — and ONLY ever on a value you already know is a number.
    ///
    /// DO NOT POINT THIS AT A BUFFER. `Number(some_typed_array)` coerces via `toString()`,
    /// which builds a string of every element separated by commas — for a 2.7 MB result that is
    /// 2.7 million integers, about ten megabytes of text, parsed to NaN and thrown away.
    /// `bridge.zig` did exactly that once, on the frame each result landed. It cost 95 ms per
    /// frame and made the entire jobs system look like it did not work.
    fn asNumber(self: JsValue) f64 {
        return js_to_num(self.handle);
    }
};

/// `globalThis` — inside a worker, the object that owns `onmessage` and `postMessage`.
fn globalScope() JsValue {
    return .{ .handle = js_global() };
}

/// A Zig f64, as a JavaScript number.
fn asJsNumber(number: f64) JsValue {
    return .{ .handle = js_num(number) };
}

/// A Zig string, as a JavaScript string.
fn asJsString(string: []const u8) JsValue {
    const string_length: u32 = @intCast(string.len);
    return .{ .handle = js_str(string.ptr, string_length) };
}

/// `{}` — a fresh, empty JavaScript object. Every reply this worker sends is built from one.
fn newEmptyJsObject() JsValue {
    const object_constructor: JsValue = globalScope().getProperty("Object");
    return object_constructor.construct(.{});
}

/// `[]` — a fresh, empty JavaScript array.
fn newEmptyJsArray() JsValue {
    return .{ .handle = js_array() };
}

/// `array.push(value)`
fn pushOntoJsArray(array: JsValue, value: JsValue) void {
    _ = js_push(array.handle, value.handle);
}

/// Wrap a Zig function so that the browser can call it. THIS IS WHAT A CALLBACK IS.
fn asJsFunction(zig_function_pointer: *const anyopaque) JsValue {
    return .{ .handle = js_func(zig_function_pointer) };
}

// ===========================================================================================
// SECTION 3 — THE PROTOCOL
//
// These names are NOT defined here. They live in `src/jobs_abi.zig`, which all three sides of
// the system read: `jobs.zig` (which becomes the kernel wasm and EXPORTS them), this file
// (which becomes the worker and CALLS them), and `tools/c2js.zig` (which VERIFIES them).
//
// Three separate compilations that never link against one another — and exactly one spelling
// of each name between them.
// ===========================================================================================

const jobs_abi = @import("jobs_abi.zig");

const message_tags = jobs_abi.msg;
const worker_error_names = jobs_abi.worker_errors;

// ===========================================================================================
// SECTION 4 — THE WORKER ITSELF
// ===========================================================================================

/// The kernel wasm's exports table, once we have instantiated it. Zero means "not yet".
///
/// This is a module-level `var` because the browser's callback model leaves nowhere else to put
/// it: the runtime invokes `handleMessageFromHost` with no context of ours to carry state in.
var kernel_wasm_exports_handle: JsHandle = 0; // lint:off module-var: one kernel instance per worker

/// THE ENTRY POINT. c2js emits this as a plain JavaScript function, and the worker bootstrap in
/// `bridge.zig` calls it exactly once, immediately after loading the program.
///
/// All it does is register the callback. Everything else in this file happens only because the
/// browser delivers a message.
export fn start() void {
    const the_global_scope: JsValue = globalScope();
    const message_handler: JsValue = asJsFunction(&handleMessageFromHost);
    the_global_scope.setProperty("onmessage", message_handler);
}

/// Called by the browser once per message from the host. THIS IS THE ENTIRE WORKER.
///
/// Notice what is absent: no loop, no waiting, no locks, no shared state. A worker handles one
/// message at a time, start to finish, and `bridge.zig` guarantees it never has two jobs in
/// flight on one worker (see `busy_with` there). So this can be perfectly ordinary, blocking,
/// sequential code — which is precisely why it is able to be Zig.
fn handleMessageFromHost(event_handle: JsHandle) callconv(.c) void {
    const event_object: JsValue = .{ .handle = event_handle };
    const message_object: JsValue = event_object.getProperty("data");

    const message_tag: JsValue = message_object.getProperty("t");
    const init_tag: JsValue = asJsString(message_tags.init);
    const this_message_is_the_init_message: bool = message_tag.strictlyEquals(init_tag);

    if (this_message_is_the_init_message) {
        const kernel_wasm_bytes: JsValue = message_object.getProperty("wasm");
        instantiateKernelWasm(kernel_wasm_bytes);
        return;
    }

    // Anything that is not `init` is a job: { t: "job", handle, kernel, bytes }.
    runOneJob(message_object);
}

/// Compile and instantiate the kernel wasm, then tell the host we are ready to receive work.
///
/// THE WHOLE POINT OF THIS FUNCTION IS THAT IT BLOCKS.
///
/// The JavaScript version called `WebAssembly.instantiate`, which returns a PROMISE — a value
/// that is not ready yet — and then `await`ed it. `await` YIELDS: this function would pause, the
/// browser would deliver the next queued message, and the handler would re-enter with
/// `kernel_wasm_exports_handle` still zero. Sixteen path-tracing tiles submitted on a single
/// frame all landed in that window, threw, and vanished without a trace.
///
/// `WebAssembly.Module` and `WebAssembly.Instance` are CONSTRUCTORS. They do not yield. And a
/// worker is permitted to compile synchronously — the four-kilobyte synchronous-compile limit
/// applies only to the page's main thread, not to us. So this runs to completion before the next
/// message is so much as looked at.
fn instantiateKernelWasm(kernel_wasm_bytes: JsValue) void {
    const web_assembly_namespace: JsValue = globalScope().getProperty("WebAssembly");

    // `new WebAssembly.Module(bytes)` — compile the wasm.
    const module_constructor: JsValue = web_assembly_namespace.getProperty("Module");
    const compiled_module: JsValue = module_constructor.construct(.{kernel_wasm_bytes});

    // `new WebAssembly.Instance(module, {})` — link it.
    //
    // An EMPTY object is a COMPLETE import object here, because a job kernel has ZERO imports.
    // That is not luck: `tools/c2js.zig` refuses to embed a kernel wasm whose import section is
    // non-empty, so a kernel that reaches for the DOM fails the BUILD rather than failing on
    // somebody's phone.
    const instance_constructor: JsValue = web_assembly_namespace.getProperty("Instance");
    const empty_import_object: JsValue = newEmptyJsObject();
    const kernel_instance: JsValue = instance_constructor.construct(.{
        compiled_module,
        empty_import_object,
    });

    const exports_table: JsValue = kernel_instance.getProperty("exports");
    kernel_wasm_exports_handle = exports_table.handle;

    // `postMessage({ t: "ready" })`.
    //
    // The host will not dispatch a job to us until it has seen this. It used to THROW THIS
    // MESSAGE AWAY — the reply carries no job handle, so it fell through a `handle >= 1` guard
    // in `onWorkerMessage` and vanished. Nothing knew when a worker had finished instantiating,
    // so the dispatcher would hand a job to a worker that could not yet run one.
    const ready_reply: JsValue = newEmptyJsObject();
    const ready_tag: JsValue = asJsString(message_tags.ready);
    ready_reply.setProperty("t", ready_tag);
    _ = globalScope().callMethod("postMessage", .{ready_reply});
}

/// Run exactly one job: copy the bytes in, call the one kernel export, copy the result out.
fn runOneJob(message_object: JsValue) void {
    const job_handle: f64 = message_object.getNumberProperty("handle");

    // ---- 0. are we even able to run anything yet? ------------------------------------------
    const kernel_has_been_instantiated: bool = kernel_wasm_exports_handle != 0;
    if (!kernel_has_been_instantiated) {
        // Unreachable if the host behaves, because it waits for our `ready` before dispatching.
        // We REPORT it rather than throwing anyway: a worker that dies silently is a worker you
        // will spend an hour debugging.
        replyWithFailureName(job_handle, worker_error_names.not_ready);
        return;
    }
    const kernel_exports: JsValue = .{ .handle = kernel_wasm_exports_handle };

    // ---- 1. find this job's kernel, by name -------------------------------------------------
    //
    // `kernel_exports["zimr_job_" + message.kernel]`. Every kernel is its own wasm export, so
    // there is no id and no dispatch table, and a job physically cannot reach the wrong kernel.
    //
    // `Reflect.get(object, key)` is JavaScript's read-a-property-by-dynamic-key — the `obj[key]`
    // form, spelled as a function call so that it can cross the interop boundary.
    const requested_kernel_name: JsValue = message_object.getProperty("kernel");
    const export_name_prefix: JsValue = asJsString(jobs_abi.kernel_prefix);
    const full_export_name: JsValue = export_name_prefix.callMethod("concat", .{requested_kernel_name});

    const reflect_namespace: JsValue = globalScope().getProperty("Reflect");
    const kernel_function: JsValue = reflect_namespace.callMethod("get", .{
        kernel_exports,
        full_export_name,
    });

    const kernel_function_exists: bool = kernel_function.isTruthy();
    if (!kernel_function_exists) {
        replyWithFailureName(job_handle, worker_error_names.no_such_kernel);
        return;
    }

    // ---- 2. copy the job's bytes INTO the kernel wasm's own linear memory --------------------
    const incoming_bytes: JsValue = message_object.getProperty("bytes");
    const incoming_byte_count: f64 = incoming_bytes.getNumberProperty("byteLength");

    const allocated_pointer: f64 = kernel_exports.callMethod(
        jobs_abi.alloc,
        .{asJsNumber(incoming_byte_count)},
    ).asNumber();

    const allocation_succeeded: bool = allocated_pointer != 0;
    if (!allocation_succeeded) {
        replyWithFailureName(job_handle, worker_error_names.out_of_memory);
        return;
    }

    // Read `.buffer` AFTER the allocation, deliberately.
    //
    // Allocating may have GROWN the kernel's wasm memory, and growing a wasm memory DETACHES the
    // old ArrayBuffer — every view taken before the call is now dead. It does not throw; it reads
    // as zero bytes and says nothing. This is the classic wasm-in-JavaScript bug, and it is why
    // `.buffer` is fetched fresh at every single use in this file.
    const uint8_array_constructor: JsValue = globalScope().getProperty("Uint8Array");
    const kernel_memory: JsValue = kernel_exports.getProperty(jobs_abi.memory);
    const kernel_memory_buffer: JsValue = kernel_memory.getProperty("buffer");

    const destination_view: JsValue = uint8_array_constructor.construct(.{
        kernel_memory_buffer,
        asJsNumber(allocated_pointer),
        asJsNumber(incoming_byte_count),
    });
    const source_view: JsValue = uint8_array_constructor.construct(.{incoming_bytes});
    _ = destination_view.callMethod("set", .{source_view});

    // ---- 3. RUN THE KERNEL --------------------------------------------------------------------
    //
    // `kernel_function.call(this_argument, byte_count)` is JavaScript's way of invoking a value
    // that happens to be a function. The `this` argument is unused by a wasm export, so an empty
    // object serves.
    const unused_this_argument: JsValue = newEmptyJsObject();
    const result_byte_count: f64 = kernel_function.callMethod("call", .{
        unused_this_argument,
        asJsNumber(incoming_byte_count),
    }).asNumber();

    const kernel_returned_an_error: bool = result_byte_count < 0;
    if (kernel_returned_an_error) {
        replyWithKernelError(job_handle, kernel_exports);
        return;
    }

    // ---- 4. copy the result back OUT ----------------------------------------------------------
    const result_pointer: f64 = kernel_exports.callMethod(jobs_abi.out_ptr, .{}).asNumber();

    // `.buffer` again, freshly — for exactly the reason given in step 2. The kernel just ran, and
    // running it may have grown its memory.
    const kernel_memory_after_run: JsValue = kernel_exports.getProperty(jobs_abi.memory);
    const buffer_after_run: JsValue = kernel_memory_after_run.getProperty("buffer");

    const result_view_into_kernel_memory: JsValue = uint8_array_constructor.construct(.{
        buffer_after_run,
        asJsNumber(result_pointer),
        asJsNumber(result_byte_count),
    });

    // A fresh array that WE own. `result_view_into_kernel_memory` points into the kernel's memory,
    // which the very next job will overwrite; we cannot hand that to the host.
    const result_bytes: JsValue = uint8_array_constructor.construct(.{
        asJsNumber(result_byte_count),
    });
    _ = result_bytes.callMethod("set", .{result_view_into_kernel_memory});
    const result_buffer: JsValue = result_bytes.getProperty("buffer");

    // ---- 5. send it home ----------------------------------------------------------------------
    const done_reply: JsValue = newEmptyJsObject();
    done_reply.setProperty("t", asJsString(message_tags.done));
    done_reply.setNumberProperty("handle", job_handle);

    // `failed: 0` is written out ON PURPOSE, and leaving it out is not harmless.
    //
    // An absent field reads back on the host as `undefined`; `getNum` turns that into NaN; and
    // `NaN != 0` evaluates to TRUE. So a job that SUCCEEDED would be filed as a failure. That bug
    // shipped once. Now neither side is able to produce it on its own.
    done_reply.setNumberProperty("failed", 0);
    done_reply.setProperty("result", result_buffer);

    // The second argument to postMessage is the TRANSFER LIST. Naming a buffer there moves its
    // ownership to the host instead of copying it: O(1), however many megabytes it holds. The
    // buffer is detached on our side afterwards, which is fine — we are done with it.
    const transfer_list: JsValue = newEmptyJsArray();
    pushOntoJsArray(transfer_list, result_buffer);

    _ = globalScope().callMethod("postMessage", .{ done_reply, transfer_list });
}

/// The kernel returned a Zig error. Fetch its NAME out of the kernel's memory and send that, so
/// the host reads "ShortPayload" instead of a bare, useless "-1".
fn replyWithKernelError(job_handle: f64, kernel_exports: JsValue) void {
    const error_name_pointer: f64 = kernel_exports.callMethod(jobs_abi.err_ptr, .{}).asNumber();
    const error_name_length: f64 = kernel_exports.callMethod(jobs_abi.err_len, .{}).asNumber();

    // `.buffer` fresh, once more — the kernel ran, so its memory may have grown.
    const kernel_memory: JsValue = kernel_exports.getProperty(jobs_abi.memory);
    const kernel_memory_buffer: JsValue = kernel_memory.getProperty("buffer");

    const uint8_array_constructor: JsValue = globalScope().getProperty("Uint8Array");
    const error_name_bytes: JsValue = uint8_array_constructor.construct(.{
        kernel_memory_buffer,
        asJsNumber(error_name_pointer),
        asJsNumber(error_name_length),
    });

    const text_decoder_constructor: JsValue = globalScope().getProperty("TextDecoder");
    const text_decoder: JsValue = text_decoder_constructor.construct(.{});
    const error_name_string: JsValue = text_decoder.callMethod("decode", .{error_name_bytes});

    replyWithFailureValue(job_handle, error_name_string);
}

/// Report a failure whose name we already know as a Zig string.
fn replyWithFailureName(job_handle: f64, failure_name: []const u8) void {
    replyWithFailureValue(job_handle, asJsString(failure_name));
}

/// Report a failure whose name is already a JavaScript string.
fn replyWithFailureValue(job_handle: f64, failure_name: JsValue) void {
    const failure_reply: JsValue = newEmptyJsObject();
    failure_reply.setProperty("t", asJsString(message_tags.done));
    failure_reply.setNumberProperty("handle", job_handle);
    failure_reply.setNumberProperty("failed", 1);
    failure_reply.setProperty("err", failure_name);
    _ = globalScope().callMethod("postMessage", .{failure_reply});
}

comptime {
    // `start` must survive optimisation. It is the worker's only entry point, and if it were
    // dropped the worker would load, register nothing, and sit there in perfect silence.
    _ = &start;
}
