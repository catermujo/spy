#+build !freestanding
#+build !orca
#+build !js
package spy

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:terminal"
import "core:terminal/ansi"
import "core:thread"
import "core:time"

import "base:runtime"

Level_Headers := [?]string {
    0 ..< 10 = "D",
    10 ..< 20 = "I",
    20 ..< 30 = "W",
    30 ..< 40 = "E",
    40 ..< 50 = "F",
}

Default_Console_Logger_Opts :: Options{.Level, .Terminal_Color, .Time, .Short_File_Path, .Line, .Procedure}

Default_File_Logger_Opts :: Options{.Level, .Time, .Short_File_Path, .Line, .Procedure}

LOGGER_QUEUE_CAP :: u64(1 << 12)
LOGGER_QUEUE_SPIN_TRIES :: 64

// DUMBAI: compile-time switch (build with -define:SPY_SYNC=true) that makes create_console_logger
// write each line synchronously instead of through the async drain thread. Needed by FFI hosts like the drift
// node.js dylib so a line emitted just before a panic/segfault reaches the terminal before the process dies.
SYNC :: #config(SPY_SYNC, false)

Queued_Log_Entry :: struct {
    handle: ^os.File,
    line:   string,
}

Log_Queue_Slot :: struct #min_field_align(64) {
    seq: u64,
    val: Queued_Log_Entry,
}

Log_Queue :: struct {
    tail:  u64,
    head:  u64,
    slots: [LOGGER_QUEUE_CAP]Log_Queue_Slot,
}

File_Console_Logger_Data :: struct {
    file_handle:  ^os.File,
    ident:        string,
    lock:         sync.Mutex,
    state_lock:   sync.Mutex,
    allocator:    runtime.Allocator,
    queue:        Log_Queue,
    queue_event:  sync.Auto_Reset_Event,
    drain_thread: ^thread.Thread,
    shutdown:     bool,
}

Terminal_Color_Indexed :: distinct u8

module_colors: [11]Terminal_Color_Indexed = {
    Terminal_Color_Indexed(33),
    Terminal_Color_Indexed(39),
    Terminal_Color_Indexed(45),
    Terminal_Color_Indexed(75),
    Terminal_Color_Indexed(81),
    Terminal_Color_Indexed(111),
    Terminal_Color_Indexed(141),
    Terminal_Color_Indexed(149),
    Terminal_Color_Indexed(171),
    Terminal_Color_Indexed(208),
    Terminal_Color_Indexed(214),
}

set_text_bold :: proc(buf: ^strings.Builder) {
    strings.write_string(buf, ansi.CSI + ansi.BOLD + "m")
}

set_fg_color_indexed :: proc(buf: ^strings.Builder, color: Terminal_Color_Indexed) {
    strings.write_string(buf, ansi.CSI + "38;5;")
    strings.write_uint(buf, cast(uint)u8(color))
    strings.write_rune(buf, 'm')
}

reset_terminal_styles :: proc(buf: ^strings.Builder) {
    strings.write_string(buf, ansi.CSI + "0m")
}

LOG_WIDGET_COLOR_SEGMENT_CAP :: 4

widget_bright_black_rgba :: [4]u8{0x55, 0x55, 0x55, 0xFF}
widget_bright_green_rgba :: [4]u8{0x55, 0xFF, 0x55, 0xFF}
widget_bright_yellow_rgba :: [4]u8{0xFF, 0xFF, 0x55, 0xFF}
widget_bright_red_rgba :: [4]u8{0xFF, 0x55, 0x55, 0xFF}
widget_default_rgba :: [4]u8{}

widget_xterm_palette16: [16][4]u8 = {
    {0x00, 0x00, 0x00, 0xFF},
    {0xAA, 0x00, 0x00, 0xFF},
    {0x00, 0xAA, 0x00, 0xFF},
    {0xAA, 0x55, 0x00, 0xFF},
    {0x00, 0x00, 0xAA, 0xFF},
    {0xAA, 0x00, 0xAA, 0xFF},
    {0x00, 0xAA, 0xAA, 0xFF},
    {0xAA, 0xAA, 0xAA, 0xFF},
    {0x55, 0x55, 0x55, 0xFF},
    {0xFF, 0x55, 0x55, 0xFF},
    {0x55, 0xFF, 0x55, 0xFF},
    {0xFF, 0xFF, 0x55, 0xFF},
    {0x55, 0x55, 0xFF, 0xFF},
    {0xFF, 0x55, 0xFF, 0xFF},
    {0x55, 0xFF, 0xFF, 0xFF},
    {0xFF, 0xFF, 0xFF, 0xFF},
}

widget_xterm_level :: #force_inline proc(component: int) -> u8 {
    if component <= 0 {
        return 0
    }
    return u8(55 + component * 40)
}

widget_indexed_rgba :: proc(idx: u8) -> [4]u8 {
    if idx < 16 {
        return widget_xterm_palette16[idx]
    }
    if idx <= 231 {
        value := int(idx) - 16
        r := value / 36
        g := (value / 6) % 6
        b := value % 6
        return {widget_xterm_level(r), widget_xterm_level(g), widget_xterm_level(b), 0xFF}
    }
    if idx <= 255 {
        gray := u8((int(idx) - 232) * 10 + 8)
        return {gray, gray, gray, 0xFF}
    }
    return widget_xterm_palette16[7]
}

widget_level_rgba :: #force_inline proc(level: Level) -> [4]u8 {
    #partial switch level {
    case .Info:
        return widget_bright_green_rgba
    case .Warning:
        return widget_bright_yellow_rgba
    case .Error, .Fatal:
        return widget_bright_red_rgba
    case:
        return widget_bright_black_rgba
    }
}

widget_record_color_segment :: #force_inline proc(
    starts: ^[LOG_WIDGET_COLOR_SEGMENT_CAP]u16,
    ends: ^[LOG_WIDGET_COLOR_SEGMENT_CAP]u16,
    colors: ^[LOG_WIDGET_COLOR_SEGMENT_CAP][4]u8,
    count: ^u8,
    start, end: int,
    color: [4]u8,
) {
    if end <= start || int(count^) >= LOG_WIDGET_COLOR_SEGMENT_CAP {
        return
    }
    idx := int(count^)
    starts[idx] = u16(start)
    ends[idx] = u16(end)
    colors[idx] = color
    count^ += 1
}

@(private)
global_subtract_stdout_options: Options
@(private)
global_subtract_stderr_options: Options

@(init, private)
// #+vet redundancy public-api
init_standard_stream_status :: proc "contextless" () {
    if terminal.color_enabled {
        context = runtime.default_context()
        if !terminal.is_terminal(os.stdout) {
            global_subtract_stdout_options = {.Terminal_Color}
        }
        if !terminal.is_terminal(os.stderr) {
            global_subtract_stderr_options = {.Terminal_Color}
        }
    } else {
        global_subtract_stdout_options = {.Terminal_Color}
        global_subtract_stderr_options = {.Terminal_Color}
    }
}

create_file_logger :: proc(
    f: ^os.File,
    lowest := Level.Debug,
    opt := Default_File_Logger_Opts,
    ident := "",
    alloc := context.allocator,
) -> Logger {
    data := new(File_Console_Logger_Data, alloc)
    data.file_handle = f
    data.ident = ident
    data.allocator = alloc
    start_async_queue(data)
    return {file_logger_proc, data, lowest, opt}
}

destroy_file_logger :: proc(log: Logger, alloc := context.allocator) {
    data := cast(^File_Console_Logger_Data)log.data
    stop_async_queue(data)
    if data.file_handle != nil {
        os.close(data.file_handle)
    }
    free(data, alloc)
}

create_console_logger :: proc(
    lowest := Level.Debug,
    opt := Default_Console_Logger_Opts,
    ident := "",
    alloc := context.allocator,
) -> Logger {
    data := new(File_Console_Logger_Data, alloc)
    data.file_handle = nil
    data.ident = ident
    data.allocator = alloc
    // DUMBAI: with no drain thread, emit_async_log_line falls back to a direct synchronous write; gated at
    // compile time so the async path has zero overhead when SYNC is off.
    when !SYNC {
        start_async_queue(data)
    }
    return {console_logger_proc, data, lowest, opt}
}

destroy_console_logger :: proc(log: Logger, alloc := context.allocator) {
    data := cast(^File_Console_Logger_Data)log.data
    stop_async_queue(data)
    free(data, alloc)
}

@(private)
build_log_line :: proc(
    ident: string,
    level: Level,
    text: string,
    options: Options,
    location: runtime.Source_Code_Location,
    allocator: runtime.Allocator,
) -> string {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    scope_label, message_text, has_scope_label := split_log_scope_metadata(text)
    line_cap := len(message_text) + 256
    if line_cap < 512 {
        line_cap = 512
    }
    buf := strings.builder_make_len_cap(0, line_cap, context.temp_allocator)

    do_time_header(options, &buf, time.now())
    do_level_header(options, &buf, level)
    if .Thread_Id in options {
        fmt.sbprintf(&buf, "[%v] ", os.get_current_thread_id())
    }
    do_module_header(options, &buf, location, scope_label, has_scope_label)

    if ident != "" {
        fmt.sbprintf(&buf, "[%s] ", ident)
    }

    do_location_header(options, &buf, location)
    strings.write_string(&buf, message_text)
    return strings.clone(strings.to_string(buf), allocator)
}

format_logger_line :: proc(
    logger: Logger,
    level: Level,
    text: string,
    alloc := context.allocator,
    loc := #caller_location,
) -> string {
    ident := ""
    if logger.procedure == console_logger_proc || logger.procedure == file_logger_proc {
        data := cast(^File_Console_Logger_Data)logger.data
        if data != nil {
            ident = data.ident
        }
    }
    return build_log_line(ident, level, text, logger.options - {.Terminal_Color}, loc, alloc)
}

format_logger_line_widget :: proc(
    logger: Logger,
    level: Level,
    text: string,
    out: ^strings.Builder,
    loc := #caller_location,
) -> (
    line_text: string,
    color_starts: [LOG_WIDGET_COLOR_SEGMENT_CAP]u16,
    color_ends: [LOG_WIDGET_COLOR_SEGMENT_CAP]u16,
    color_rgba: [LOG_WIDGET_COLOR_SEGMENT_CAP][4]u8,
    color_count: u8,
) {
    ident := ""
    if logger.procedure == console_logger_proc || logger.procedure == file_logger_proc {
        data := cast(^File_Console_Logger_Data)logger.data
        if data != nil {
            ident = data.ident
        }
    }

    options := logger.options - {.Terminal_Color}

    scope_label, message_text, has_scope_label := split_log_scope_metadata(text)
    do_time_header(options, out, time.now())
    if .Level in options {
        level_start := len(out.buf)
        do_level_header(options, out, level)
        level_end := len(out.buf)
        if level_end > level_start {
            level_end -= 1
        }
        widget_record_color_segment(
            &color_starts,
            &color_ends,
            &color_rgba,
            &color_count,
            level_start,
            level_end,
            widget_level_rgba(level),
        )
    }

    start, end, has_path := module_bounds(loc.file_path)
    if has_path || has_scope_label {
        if has_path {
            hash: u64 = 1469598103934665603
            module_start := len(out.buf)
            strings.write_byte(out, '[')
            for i := start; i < end; i += 1 {
                c := loc.file_path[i]
                if c == '/' || c == '\\' {
                    hash = module_hash_byte(module_hash_byte(hash, ':'), ':')
                    strings.write_string(out, "::")
                    continue
                }
                hash = module_hash_byte(hash, c)
                strings.write_byte(out, c)
            }
            if has_scope_label {
                strings.write_byte(out, ':')
            } else {
                strings.write_string(out, "] ")
            }
            widget_record_color_segment(
                &color_starts,
                &color_ends,
                &color_rgba,
                &color_count,
                module_start,
                len(out.buf),
                widget_indexed_rgba(u8(module_color(hash))),
            )
        } else {
            strings.write_byte(out, '[')
        }

        if has_scope_label {
            scope_start := len(out.buf)
            strings.write_string(out, scope_label)
            widget_record_color_segment(
                &color_starts,
                &color_ends,
                &color_rgba,
                &color_count,
                scope_start,
                len(out.buf),
                widget_bright_black_rgba,
            )
            strings.write_string(out, "] ")
        }
    }

    if ident != "" {
        fmt.sbprintf(out, "[%s] ", ident)
    }

    do_location_header(options, out, loc)
    strings.write_string(out, message_text)
    line_text = strings.to_string(out^)
    return
}

@(private)
write_log_line :: proc(data: ^File_Console_Logger_Data, h: ^os.File, line: string) {
    sync.lock(&data.lock)
    defer sync.unlock(&data.lock)
    fmt.fprintf(h, "%s\n", line)
}

@(private)
start_async_queue :: proc(data: ^File_Console_Logger_Data) {
    if data == nil {
        return
    }
    log_queue_init(&data.queue)
    data.shutdown = false
    when thread.IS_SUPPORTED {
        data.drain_thread = thread.create(drain_queue_thread)
        if data.drain_thread != nil {
            data.drain_thread.data = data
            thread.start(data.drain_thread)
        }
    }
}

@(private)
stop_async_queue :: proc(data: ^File_Console_Logger_Data) {
    if data == nil {
        return
    }
    when thread.IS_SUPPORTED {
        if data.drain_thread != nil {
            sync.lock(&data.state_lock)
            data.shutdown = true
            sync.unlock(&data.state_lock)
            sync.auto_reset_event_signal(&data.queue_event)
            thread.join(data.drain_thread)
            thread.destroy(data.drain_thread)
            data.drain_thread = nil
        }
    }
    for {
        entry, ok := log_queue_dequeue(&data.queue)
        if !ok {
            break
        }
        write_log_line(data, entry.handle, entry.line)
        delete(entry.line, data.allocator)
    }
}

@(private)
drain_queue_thread :: proc(t: ^thread.Thread) {
    data := cast(^File_Console_Logger_Data)t.data
    for {
        drained := false
        for {
            entry, ok := log_queue_dequeue(&data.queue)
            if !ok {
                break
            }
            drained = true
            write_log_line(data, entry.handle, entry.line)
            delete(entry.line, data.allocator)
        }

        shutdown := false
        sync.lock(&data.state_lock)
        shutdown = data.shutdown
        sync.unlock(&data.state_lock)
        if shutdown && log_queue_is_empty(&data.queue) {
            break
        }
        if !drained {
            sync.auto_reset_event_wait(&data.queue_event)
        }
    }
}

@(private)
emit_async_log_line :: proc(data: ^File_Console_Logger_Data, h: ^os.File, line: string) {
    when thread.IS_SUPPORTED {
        if data.drain_thread != nil {
            entry: Queued_Log_Entry = {
                handle = h,
                line   = line,
            }
            for _ in 0 ..< LOGGER_QUEUE_SPIN_TRIES {
                if log_queue_enqueue(&data.queue, entry) {
                    sync.auto_reset_event_signal(&data.queue_event)
                    return
                }
                thread.yield()
            }
        }
    }
    write_log_line(data, h, line)
    delete(line, data.allocator)
}

@(private)
// #+vet redundancy public-api
log_queue_init :: #force_inline proc(queue: ^Log_Queue) #no_bounds_check {
    for i in 0 ..< LOGGER_QUEUE_CAP {
        sync.atomic_store_explicit(&queue.slots[i].seq, i, .Relaxed)
    }
}

@(private)
// #+vet redundancy public-api
log_queue_enqueue :: proc(queue: ^Log_Queue, x: Queued_Log_Entry) -> bool #no_bounds_check {
    for {
        pos := sync.atomic_load_explicit(&queue.tail, .Relaxed)
        slot := &queue.slots[pos & (LOGGER_QUEUE_CAP - 1)]
        seq := sync.atomic_load_explicit(&slot.seq, .Acquire)
        diff := i64(seq) - i64(pos)

        switch {
        case diff == 0:
            _, success := sync.atomic_compare_exchange_strong_explicit(&queue.tail, pos, pos + 1, .Relaxed, .Relaxed)
            if success {
                slot.val = x
                sync.atomic_store_explicit(&slot.seq, pos + 1, .Release)
                return true
            }
            sync.cpu_relax()
        case diff < 0:
            return false
        case:
            sync.cpu_relax()
        }
    }
}

@(private)
log_queue_dequeue :: proc(queue: ^Log_Queue) -> (value: Queued_Log_Entry, ok: bool) #no_bounds_check {
    for {
        pos := sync.atomic_load_explicit(&queue.head, .Relaxed)
        slot := &queue.slots[pos & (LOGGER_QUEUE_CAP - 1)]

        seq := sync.atomic_load_explicit(&slot.seq, .Acquire)
        diff := i64(seq) - i64(pos + 1)

        switch {
        case diff == 0:
            sync.atomic_store_explicit(&queue.head, pos + 1, .Relaxed)
            v := slot.val
            sync.atomic_store_explicit(&slot.seq, pos + LOGGER_QUEUE_CAP, .Release)
            return v, true
        case diff < 0:
            return {}, false
        case:
            sync.cpu_relax()
        }
    }
}

@(private)
// #+vet redundancy public-api
log_queue_is_empty :: #force_inline proc(queue: ^Log_Queue) -> bool #no_bounds_check {
    pos := sync.atomic_load_explicit(&queue.head, .Relaxed)
    seq := sync.atomic_load_explicit(&queue.slots[pos & (LOGGER_QUEUE_CAP - 1)].seq, .Acquire)
    return i64(seq) - i64(pos + 1) < 0
}

// #+vet redundancy public-api
file_logger_proc :: proc(logger_data: rawptr, level: Level, text: string, options: Options, loc := #caller_location) {
    data := cast(^File_Console_Logger_Data)logger_data
    line := build_log_line(data.ident, level, text, options, loc, data.allocator)
    emit_async_log_line(data, data.file_handle, line)
}

console_logger_proc :: proc(
    logger_data: rawptr,
    level: Level,
    text: string,
    options: Options,
    loc := #caller_location,
) {
    options := options
    data := cast(^File_Console_Logger_Data)logger_data
    h: ^os.File
    if level < Level.Error {
        h = os.stdout
        options -= global_subtract_stdout_options
    } else {
        h = os.stderr
        options -= global_subtract_stderr_options
    }
    line := build_log_line(data.ident, level, text, options, loc, data.allocator)
    emit_async_log_line(data, h, line)
}

// #+vet redundancy public-api
do_level_header :: proc(opts: Options, buf: ^strings.Builder, level: Level) {
    if .Level not_in opts {
        return
    }

    label := Level_Headers[level]
    if .Terminal_Color in opts {
        color := ansi.FG_BRIGHT_BLACK
        switch level {
        case .Debug:
            color = ansi.FG_BRIGHT_BLACK
        case .Info:
            color = ansi.FG_BRIGHT_GREEN
        case .Warning:
            color = ansi.FG_BRIGHT_YELLOW
        case .Error, .Fatal:
            color = ansi.FG_BRIGHT_RED
        }
        strings.write_string(buf, ansi.CSI)
        strings.write_string(buf, color)
        strings.write_string(buf, ansi.SGR)
        fmt.sbprintf(buf, "%1s", label)
        strings.write_string(buf, ansi.CSI + ansi.RESET + ansi.SGR)
    } else {
        fmt.sbprintf(buf, "%1s", label)
    }
    strings.write_string(buf, " ")
}

do_time_header :: proc(opts: Options, buf: ^strings.Builder, t: time.Time) {
    if Full_Timestamp_Opts & opts == nil {
        return
    }

    strings.write_byte(buf, '[')
    y, m, d := time.date(t)
    h, min, s := time.clock(t)
    if .Date in opts {
        fmt.sbprintf(buf, "%d-%02d-%02d", y, m, d)
        if .Time in opts {
            strings.write_byte(buf, ' ')
        }
    }
    if .Time in opts {
        fmt.sbprintf(buf, "%02d:%02d:%02d", h, min, s)
    }
    strings.write_string(buf, "] ")
}

@(private)
do_scope_label_parts :: proc(opts: Options, buf: ^strings.Builder) {
    count := active_span_count()
    if count == 0 {
        return
    }

    if .Terminal_Color in opts {
        strings.write_string(buf, ansi.CSI + ansi.FG_BRIGHT_BLACK + ansi.SGR)
    }
    for i in 0 ..< count {
        if i > 0 {
            strings.write_byte(buf, ':')
        }
        frame := active_span_at(i)
        strings.write_string(buf, frame.name)
        if frame.fields != "" {
            strings.write_byte(buf, '{')
            strings.write_string(buf, frame.fields)
            strings.write_byte(buf, '}')
        }
    }
    if .Terminal_Color in opts {
        strings.write_string(buf, ansi.CSI + ansi.RESET + ansi.SGR)
    }
}

do_scope_label_text :: proc(opts: Options, buf: ^strings.Builder, scope_label: string) {
    if scope_label == "" {
        return
    }
    if .Terminal_Color in opts {
        strings.write_string(buf, ansi.CSI + ansi.FG_BRIGHT_BLACK + ansi.SGR)
    }
    strings.write_string(buf, scope_label)
    if .Terminal_Color in opts {
        strings.write_string(buf, ansi.CSI + ansi.RESET + ansi.SGR)
    }
}

do_module_header :: proc(
    opts: Options,
    buf: ^strings.Builder,
    location: runtime.Source_Code_Location,
    scope_override: string,
    has_scope_override: bool,
) {
    start, end, has_path := module_bounds(location.file_path)
    scope_count := 0
    if !has_scope_override {
        scope_count = active_span_count()
    }
    if !has_path && !has_scope_override && scope_count == 0 {
        return
    }

    if has_path {
        hash: u64 = 1469598103934665603
        for i := start; i < end; i += 1 {
            c := location.file_path[i]
            if c == '/' || c == '\\' {
                hash = module_hash_byte(module_hash_byte(hash, ':'), ':')
                continue
            }
            hash = module_hash_byte(hash, c)
        }
        if .Terminal_Color in opts {
            set_text_bold(buf)
            set_fg_color_indexed(buf, module_color(hash))
        }
    }

    strings.write_byte(buf, '[')
    if has_path {
        for i := start; i < end; i += 1 {
            c := location.file_path[i]
            if c == '/' || c == '\\' {
                strings.write_string(buf, "::")
                continue
            }
            strings.write_byte(buf, c)
        }
    }
    if has_scope_override {
        if has_path {
            strings.write_byte(buf, ':')
        }
        do_scope_label_text(opts, buf, scope_override)
    } else if scope_count > 0 {
        if has_path {
            strings.write_byte(buf, ':')
        }
        do_scope_label_parts(opts, buf)
    }
    strings.write_string(buf, "] ")
    if has_path && .Terminal_Color in opts {
        reset_terminal_styles(buf)
    }
}

// #+vet redundancy public-api
module_hash :: proc(s: string) -> u64 {
    hash: u64 = 1469598103934665603
    for i := 0; i < len(s); i += 1 {
        hash = module_hash_byte(hash, s[i])
    }
    return hash
}

module_hash_byte :: #force_inline proc(hash: u64, b: byte) -> u64 {
    return (hash ~ u64(b)) * 1099511628211
}

// #+vet redundancy public-api
module_color :: proc(hash: u64) -> Terminal_Color_Indexed {
    return module_colors[int(hash % u64(len(module_colors)))]
}

module_bounds :: proc(path: string) -> (start: int, end: int, ok: bool) {
    if path == "" {
        return
    }

    end = -1
    for i := len(path) - 1; i >= 0; i -= 1 {
        if path[i] == '/' || path[i] == '\\' {
            end = i
            break
        }
    }
    if end <= 0 {
        return
    }

    start = 0
    parent_sep := -1
    for i := end - 1; i >= 0; i -= 1 {
        if path[i] == '/' || path[i] == '\\' {
            parent_sep = i
            break
        }
    }
    if parent_sep < 0 {
        return
    }
    start = parent_sep + 1

    if end <= start {
        return
    }
    return start, end, true
}

do_location_header :: proc(opts: Options, buf: ^strings.Builder, loc := #caller_location) {
    if Location_Header_Opts & opts == nil {
        return
    }

    strings.write_byte(buf, '(')
    wrote := false

    file := loc.file_path
    if .Short_File_Path in opts {
        last := 0
        for i := 0; i < len(loc.file_path); i += 1 {
            if loc.file_path[i] == '/' || loc.file_path[i] == '\\' {
                last = i + 1
            }
        }
        file = loc.file_path[last:]
    }

    if Location_File_Opts & opts != nil {
        strings.write_string(buf, file)
        wrote = true
    }
    if .Line in opts {
        if wrote {
            strings.write_byte(buf, ':')
        }
        fmt.sbprint(buf, loc.line)
        wrote = true
    }
    if .Procedure in opts {
        if wrote {
            strings.write_byte(buf, ':')
        }
        fmt.sbprintf(buf, "%s()", loc.procedure)
    }

    strings.write_string(buf, ") ")
}
