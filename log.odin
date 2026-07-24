// Implementations of the `context.Logger` interface.
package spy

import "core:fmt"
import "core:strings"
import "core:sync"

import "base:runtime"


// NOTE(bill, 2019-12-31): These are defined in `package runtime` as they are used in the `context`. This is to prevent an import definition cycle.

/*
Logger_Level :: enum {
	Debug   = 0,
	Info    = 10,
	Warning = 20,
	Error   = 30,
	Fatal   = 40,
}
*/
Level :: runtime.Logger_Level

/*
Option :: enum {
	Level,
	Date,
	Time,
	Short_File_Path,
	Long_File_Path,
	Line,
	Procedure,
	Terminal_Color
}
*/
Option :: runtime.Logger_Option

/*
Options :: bit_set[Option];
*/
Options :: runtime.Logger_Options

Full_Timestamp_Opts :: Options{.Date, .Time}
Location_Header_Opts :: Options{.Short_File_Path, .Long_File_Path, .Line, .Procedure}
Location_File_Opts :: Options{.Short_File_Path, .Long_File_Path}


/*
Logger_Proc :: #type proc(data: rawptr, level: Level, text: string, options: Options, location := #caller_location);
*/
Logger_Proc :: runtime.Logger_Proc

/*
Logger :: struct {
	procedure:    Logger_Proc,
	data:         rawptr,
	lowest_level: Level,
	options:      Logger_Options,
}
*/
Logger :: runtime.Logger

nil_logger_proc :: runtime.default_logger_proc

// #+vet redundancy public-api
nil_logger :: proc() -> Logger {
    return {nil_logger_proc, nil, Level.Debug, nil}
}

Subscriber_Filter_Proc :: #type proc(
    filter_data: rawptr,
    level: Level,
    text: string,
    options: Options,
    location: runtime.Source_Code_Location,
) -> bool

Subscriber_Filter :: struct {
    procedure: Subscriber_Filter_Proc,
    data:      rawptr,
}

Subscriber_Layer_Id :: distinct u64

Subscriber_Layer :: struct {
    id:     Subscriber_Layer_Id,
    logger: Logger,
    filter: Subscriber_Filter,
}

@(private)
subscriber_registry_lock: sync.Mutex
@(private)
subscriber_registry_layers: [dynamic]Subscriber_Layer
@(private)
subscriber_registry_logger: Logger
@(private)
subscriber_registry_active: bool
@(private)
subscriber_registry_next_layer_id: u64

@(private)
subscriber_registry_refresh_locked :: proc() {
    if len(subscriber_registry_layers) == 0 {
        subscriber_registry_logger = {}
        subscriber_registry_active = false
        return
    }

    lowest := subscriber_registry_layers[0].logger.lowest_level
    for layer in subscriber_registry_layers[1:] {
        if layer.logger.lowest_level < lowest {
            lowest = layer.logger.lowest_level
        }
    }

    subscriber_registry_logger = {
        procedure    = subscriber_registry_dispatch_proc,
        data         = nil,
        lowest_level = lowest,
        options      = nil,
    }
    subscriber_registry_active = true
}

@(private)
// #+vet redundancy public-api
subscriber_layers_snapshot :: proc(allocator := context.temp_allocator) -> []Subscriber_Layer {
    sync.lock(&subscriber_registry_lock)
    defer sync.unlock(&subscriber_registry_lock)

    if len(subscriber_registry_layers) == 0 {
        return nil
    }
    layers := make([]Subscriber_Layer, len(subscriber_registry_layers), allocator)
    copy(layers, subscriber_registry_layers[:])
    return layers
}

@(private)
// #+vet redundancy public-api
subscriber_registry_dispatch_proc :: proc(
    _: rawptr,
    level: Level,
    text: string,
    options: Options,
    loc := #caller_location,
) {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    layers := subscriber_layers_snapshot()
    for layer in layers {
        if level < layer.logger.lowest_level {
            continue
        }
        if layer.filter.procedure != nil {
            if !layer.filter.procedure(layer.filter.data, level, text, options, loc) {
                continue
            }
        }
        layer.logger.procedure(layer.logger.data, level, text, layer.logger.options, loc)
    }
}

add_global_subscriber_layer_with_id :: proc(
    logger: Logger,
    filter := Subscriber_Filter{},
) -> (
    id: Subscriber_Layer_Id,
    ok: bool,
) {
    if logger.procedure == nil || logger.procedure == nil_logger_proc {
        return 0, false
    }

    sync.lock(&subscriber_registry_lock)
    defer sync.unlock(&subscriber_registry_lock)

    layer_id := Subscriber_Layer_Id(subscriber_registry_next_layer_id + 1)
    subscriber_registry_next_layer_id += 1
    append(&subscriber_registry_layers, Subscriber_Layer{id = layer_id, logger = logger, filter = filter})
    subscriber_registry_refresh_locked()
    return layer_id, true
}

// #+vet redundancy public-api
add_global_subscriber_layer :: proc(logger: Logger, filter := Subscriber_Filter{}) -> bool {
    _, ok := add_global_subscriber_layer_with_id(logger, filter)
    return ok
}

// #+vet redundancy public-api
remove_global_subscriber_layer :: proc(index: int) -> bool {
    sync.lock(&subscriber_registry_lock)
    defer sync.unlock(&subscriber_registry_lock)
    if index < 0 || index >= len(subscriber_registry_layers) {
        return false
    }

    for i := index; i + 1 < len(subscriber_registry_layers); i += 1 {
        subscriber_registry_layers[i] = subscriber_registry_layers[i + 1]
    }
    resize(&subscriber_registry_layers, len(subscriber_registry_layers) - 1)
    subscriber_registry_refresh_locked()
    return true
}

remove_global_subscriber_layer_by_id :: proc(id: Subscriber_Layer_Id) -> bool {
    if id == 0 {
        return false
    }

    sync.lock(&subscriber_registry_lock)
    defer sync.unlock(&subscriber_registry_lock)

    for layer, i in subscriber_registry_layers {
        if layer.id != id {
            continue
        }
        for j := i; j + 1 < len(subscriber_registry_layers); j += 1 {
            subscriber_registry_layers[j] = subscriber_registry_layers[j + 1]
        }
        resize(&subscriber_registry_layers, len(subscriber_registry_layers) - 1)
        subscriber_registry_refresh_locked()
        return true
    }

    return false
}

// #+vet redundancy public-api
global_subscriber_layer_count :: proc() -> int {
    sync.lock(&subscriber_registry_lock)
    defer sync.unlock(&subscriber_registry_lock)
    return len(subscriber_registry_layers)
}

// #+vet redundancy public-api
clear_global_subscriber_layers :: proc() {
    sync.lock(&subscriber_registry_lock)
    defer sync.unlock(&subscriber_registry_lock)
    if len(subscriber_registry_layers) > 0 {
        delete(subscriber_registry_layers)
        subscriber_registry_layers = nil
    }
    subscriber_registry_refresh_locked()
}

@(private)
// #+vet redundancy public-api
global_subscriber_registry_logger :: proc() -> (Logger, bool) {
    sync.lock(&subscriber_registry_lock)
    defer sync.unlock(&subscriber_registry_lock)
    if !subscriber_registry_active {
        return {}, false
    }
    return subscriber_registry_logger, true
}

resolve_logger :: #force_inline proc() -> (Logger, bool) {
    logger := context.logger
    if logger.procedure != nil && logger.procedure != nil_logger_proc {
        return logger, true
    }
    return global_subscriber_registry_logger()
}

SCOPE_META_PREFIX :: "\x1fspy_scope:"
SCOPE_META_DELIM :: byte(0x1f)

// #+vet redundancy public-api
active_scope_label_text :: proc(allocator := context.temp_allocator) -> string {
    count := active_span_count()
    if count == 0 {
        return ""
    }
    sb := strings.builder_make_len_cap(0, 64, allocator)
    for i in 0 ..< count {
        if i > 0 {
            strings.write_byte(&sb, ':')
        }
        frame := active_span_at(i)
        strings.write_string(&sb, frame.name)
        if frame.fields != "" {
            strings.write_byte(&sb, '{')
            strings.write_string(&sb, frame.fields)
            strings.write_byte(&sb, '}')
        }
    }
    return strings.to_string(sb)
}

annotate_log_text_with_active_scope :: proc(text: string, allocator := context.temp_allocator) -> string {
    scope_label := active_scope_label_text(allocator)
    if scope_label == "" {
        return text
    }
    sb := strings.builder_make_len_cap(0, len(SCOPE_META_PREFIX) + len(scope_label) + 1 + len(text), allocator)
    strings.write_string(&sb, SCOPE_META_PREFIX)
    strings.write_string(&sb, scope_label)
    strings.write_byte(&sb, SCOPE_META_DELIM)
    strings.write_string(&sb, text)
    return strings.to_string(sb)
}

split_log_scope_metadata :: proc(text: string) -> (scope_label: string, message_text: string, has_scope: bool) {
    if !strings.has_prefix(text, SCOPE_META_PREFIX) {
        return "", text, false
    }
    start := len(SCOPE_META_PREFIX)
    if start >= len(text) {
        return "", text, false
    }
    for i := start; i < len(text); i += 1 {
        if text[i] == SCOPE_META_DELIM {
            return text[start:i], text[i + 1:], true
        }
    }
    return "", text, false
}

debugf :: proc(fmt_str: string, args: ..any, loc := #caller_location) {
    logf(.Debug, fmt_str, ..args, loc = loc)
}
infof :: proc(fmt_str: string, args: ..any, loc := #caller_location) {
    logf(.Info, fmt_str, ..args, loc = loc)
}
warnf :: proc(fmt_str: string, args: ..any, loc := #caller_location) {
    logf(.Warning, fmt_str, ..args, loc = loc)
}
errorf :: proc(fmt_str: string, args: ..any, loc := #caller_location) {
    logf(.Error, fmt_str, ..args, loc = loc)
}
// #+vet redundancy public-api
fatalf :: proc(fmt_str: string, args: ..any, loc := #caller_location) {
    logf(.Fatal, fmt_str, ..args, loc = loc)
}

debug :: proc(args: ..any, sep := " ", loc := #caller_location) {
    log(.Debug, ..args, sep = sep, loc = loc)
}
info :: proc(args: ..any, sep := " ", loc := #caller_location) {
    log(.Info, ..args, sep = sep, loc = loc)
}
warn :: proc(args: ..any, sep := " ", loc := #caller_location) {
    log(.Warning, ..args, sep = sep, loc = loc)
}
error :: proc(args: ..any, sep := " ", loc := #caller_location) {
    log(.Error, ..args, sep = sep, loc = loc)
}
// #+vet redundancy public-api
fatal :: proc(args: ..any, sep := " ", loc := #caller_location) {
    log(.Fatal, ..args, sep = sep, loc = loc)
}

panic :: proc(args: ..any, loc := #caller_location) -> ! {
    log(.Fatal, ..args, loc = loc)
    p := context.assertion_failure_proc
    if p == nil {
        p = runtime.default_assertion_failure_proc
    }
    message := fmt.tprint(..args)
    p("panic", message, loc)
}
panicf :: proc(fmt_str: string, args: ..any, loc := #caller_location) -> ! {
    logf(.Fatal, fmt_str, ..args, loc = loc)
    p := context.assertion_failure_proc
    if p == nil {
        p = runtime.default_assertion_failure_proc
    }
    message := fmt.tprintf(fmt_str, ..args)
    p("panic", message, loc)
}

@(disabled = ODIN_DISABLE_ASSERT)
// #+vet redundancy public-api
assert :: proc(condition: bool, message := #caller_expression(condition), loc := #caller_location) {
    if !condition {
        @(cold)
        internal :: proc(message: string, loc: runtime.Source_Code_Location) {
            p := context.assertion_failure_proc
            if p == nil {
                p = runtime.default_assertion_failure_proc
            }
            log(.Fatal, message, loc = loc)
            p("runtime assertion", message, loc)
        }
        internal(message, loc)
    }
}

@(disabled = ODIN_DISABLE_ASSERT)
assertf :: proc(condition: bool, fmt_str: string, args: ..any, loc := #caller_location) {
    if !condition {
        // NOTE(dragos): We are using the same trick as in builtin.assert
        // to improve performance to make the CPU not
        // execute speculatively, making it about an order of
        // magnitude faster
        @(cold)
        internal :: proc(loc: runtime.Source_Code_Location, fmt_str: string, args: ..any) {
            p := context.assertion_failure_proc
            if p == nil {
                p = runtime.default_assertion_failure_proc
            }
            message := fmt.tprintf(fmt_str, ..args)
            log(.Fatal, message, loc = loc)
            p("runtime assertion", message, loc)
        }
        internal(loc, fmt_str, ..args)
    }
}

// #+vet redundancy public-api
ensure :: proc(condition: bool, message := #caller_expression(condition), loc := #caller_location) {
    if !condition {
        @(cold)
        internal :: proc(message: string, loc: runtime.Source_Code_Location) {
            p := context.assertion_failure_proc
            if p == nil {
                p = runtime.default_assertion_failure_proc
            }
            log(.Fatal, message, loc = loc)
            p("unsatisfied ensure", message, loc)
        }
        internal(message, loc)
    }
}

// #+vet redundancy public-api
ensuref :: proc(condition: bool, fmt_str: string, args: ..any, loc := #caller_location) {
    if !condition {
        @(cold)
        internal :: proc(loc: runtime.Source_Code_Location, fmt_str: string, args: ..any) {
            p := context.assertion_failure_proc
            if p == nil {
                p = runtime.default_assertion_failure_proc
            }
            message := fmt.tprintf(fmt_str, ..args)
            log(.Fatal, message, loc = loc)
            p("unsatisfied ensure", message, loc)
        }
        internal(loc, fmt_str, ..args)
    }
}


log :: proc(level: Level, args: ..any, sep := " ", loc := #caller_location) {
    logger, ok := resolve_logger()
    if !ok {
        return
    }
    if level < logger.lowest_level {
        return
    }
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    str := fmt.tprint(..args, sep = sep)
    str = annotate_log_text_with_active_scope(str)
    logger.procedure(logger.data, level, str, logger.options, loc)
}

logf :: proc(level: Level, fmt_str: string, args: ..any, loc := #caller_location) {
    logger, ok := resolve_logger()
    if !ok {
        return
    }
    if level < logger.lowest_level {
        return
    }
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    str := fmt.tprintf(fmt_str, ..args)
    str = annotate_log_text_with_active_scope(str)
    logger.procedure(logger.data, level, str, logger.options, loc)
}
