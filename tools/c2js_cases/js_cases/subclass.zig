//! js_subclass: a class extending another, made by transpiled code - as the audio worklet's program will make its
//! processor. Runs against subclass.fixture.js, which installs `AudioWorkletProcessor` - a base class standing in for
//! the browser's, whose constructor gives each object a `port`, as the real one does - and `registerProcessor`, which,
//! as the browser would, constructs the registered class with options and calls its `process` once, recording what
//! it saw in `fixtureRecord`. run_test() returns 0 on success, or the number of the first check that failed.

const Handle = u32;
extern fn js_global() Handle;
extern fn js_get(
    o: Handle,
    p: [*]const u8,
    l: u32,
) Handle;
extern fn js_set(
    o: Handle,
    p: [*]const u8,
    l: u32,
    v: Handle,
) void;
extern fn js_get_index(o: Handle, i: u32) Handle;
extern fn js_set_index(
    o: Handle,
    i: u32,
    v: Handle,
) void;
extern fn js_func(f: *const anyopaque) Handle;
extern fn js_subclass(base: Handle, init: Handle) Handle;
extern fn js_str(p: [*]const u8, l: u32) Handle;
extern fn js_num(x: f64) Handle;
extern fn js_to_num(v: Handle) f64;
extern fn js_is_null(v: Handle) u32;
extern fn js_call2v(
    o: Handle,
    p: [*]const u8,
    l: u32,
    a: Handle,
    b: Handle,
) void;

/// The property `name` of the JavaScript object `object_handle`, as a handle.
fn property(object_handle: Handle, comptime name: []const u8) Handle {
    return js_get(object_handle, name.ptr, name.len);
}

/// What the two callbacks saw, read back by `run_test`.
var init_call_count: u32 = 0;
var init_found_base_port: bool = false;
var init_option_value: f64 = 0;
var process_call_count: u32 = 0;

/// The subclass's init, called by its constructor once the base class's constructor has run: `this_handle` is the new
/// object, and `options_handle` the first argument the constructor was given. A worklet's processor would keep its
/// port here, and read the options the main thread passed to it.
fn initializeProcessor(this_handle: Handle, options_handle: Handle) void {
    init_call_count += 1;
    // The base constructor gave the object its port: the property is there, not null or undefined.
    const port_handle: Handle = property(this_handle, "port");
    const is_port_missing: bool = js_is_null(port_handle) != 0;
    init_found_base_port = !is_port_missing;
    // The constructor's argument arrived as given: { value: 42 }.
    const value_handle: Handle = property(options_handle, "value");
    init_option_value = js_to_num(value_handle);
}

/// The `process` method, as a worklet's processor has it: called with the block's inputs and outputs - arrays of
/// arrays of channels, each channel an array of samples - and its parameters. It writes 0.25 into the first sample of
/// the first output's first channel, and returns 1: true, keep calling me.
fn processBlock(inputs_handle: Handle, outputs_handle: Handle, parameters_handle: Handle) u32 {
    _ = inputs_handle;
    _ = parameters_handle;
    process_call_count += 1;
    const first_output_handle: Handle = js_get_index(outputs_handle, 0);
    const first_channel_handle: Handle = js_get_index(first_output_handle, 0);
    const sample_value_handle: Handle = js_num(0.25);
    js_set_index(first_channel_handle, 0, sample_value_handle);
    const keep_calling: u32 = 1;
    return keep_calling;
}

export fn run_test() i32 {
    const global_handle: Handle = js_global();
    // The class: extending the fixture's AudioWorkletProcessor, its constructor calling ours after the base's.
    const base_class_handle: Handle = property(global_handle, "AudioWorkletProcessor");
    const initialize_function_handle: Handle = js_func(&initializeProcessor);
    const processor_class_handle: Handle = js_subclass(base_class_handle, initialize_function_handle);
    // Its method `process`, set on its prototype - the object all its instances take their methods from.
    const prototype_handle: Handle = property(processor_class_handle, "prototype");
    const process_function_handle: Handle = js_func(&processBlock);
    const process_name = "process";
    js_set(prototype_handle, process_name, process_name.len, process_function_handle);
    // Registered under a name, as a worklet registers its processor. The fixture's registerProcessor constructs it at
    // once and calls its process once - as the browser does when the page makes an AudioWorkletNode of that name.
    const processor_name = "zimr-test";
    const processor_name_handle: Handle = js_str(processor_name, processor_name.len);
    const register_name = "registerProcessor";
    js_call2v(global_handle, register_name, register_name.len, processor_name_handle, processor_class_handle);
    // What the callbacks saw.
    if (init_call_count != 1) {
        return 1;
    }
    if (!init_found_base_port) {
        return 2;
    }
    if (init_option_value != 42) {
        return 3;
    }
    if (process_call_count != 1) {
        return 4;
    }
    // What the fixture saw.
    const record_handle: Handle = property(global_handle, "fixtureRecord");
    const is_processor: f64 = js_to_num(property(record_handle, "isProcessor"));
    const kept_alive: f64 = js_to_num(property(record_handle, "keepAlive"));
    const first_sample: f64 = js_to_num(property(record_handle, "firstSample"));
    const port_from_base: f64 = js_to_num(property(record_handle, "portFromBase"));
    const name_matches: f64 = js_to_num(property(record_handle, "nameMatches"));
    if (is_processor != 1) {
        return 5;
    }
    if (kept_alive != 1) {
        return 6;
    }
    if (first_sample != 0.25) {
        return 7;
    }
    if (port_from_base != 1) {
        return 8;
    }
    if (name_matches != 1) {
        return 9;
    }
    return 0;
}
