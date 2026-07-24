#+build js
package spy

foreign import js_env "env"

import "core:fmt"
import "core:strings"
import "core:time"

import "base:runtime"

@(default_calling_convention = "c")
foreign js_env {
    spy_console_log :: proc(level: int, use_color: u32, include_level: u32, prefix_ptr: ^u8, prefix_len: u32, module_ptr: ^u8, module_len: u32, module_color_idx: int, suffix_ptr: ^u8, suffix_len: u32, message_ptr: ^u8, message_len: u32) ---
}

Default_Console_Logger_Opts :: Options{.Level, .Terminal_Color, .Time, .Short_File_Path, .Line, .Procedure}

JS_MODULE_COLOR_COUNT :: 11
LOG_WIDGET_COLOR_SEGMENT_CAP :: 4

widget_module_colors: [JS_MODULE_COLOR_COUNT]u8 = {33, 39, 45, 75, 81, 111, 141, 149, 171, 208, 214}

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

Console_Logger_Data :: struct {
    ident: string,
}

format_logger_line :: proc(
    logger: Logger,
    level: Level,
    text: string,
    alloc := context.allocator,
    loc := #caller_location,
) -> string {
    ident := ""
    if logger.procedure == console_logger_proc {
        data := cast(^Console_Logger_Data)logger.data
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
    if logger.procedure == console_logger_proc {
        data := cast(^Console_Logger_Data)logger.data
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
                widget_indexed_rgba(widget_module_colors[int(hash % u64(len(widget_module_colors)))]),
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

create_console_logger :: proc(
    lowest := Level.Debug,
    opt := Default_Console_Logger_Opts,
    ident := "",
    alloc := context.allocator,
) -> Logger {
    data := new(Console_Logger_Data, alloc)
    data.ident = strings.clone(ident)
    return {console_logger_proc, data, lowest, opt}
}

destroy_console_logger :: proc(log: Logger, alloc := context.allocator) {
    data := cast(^Console_Logger_Data)log.data
    delete(data.ident)
    free(log.data, alloc)
}

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
    line_cap := len(message_text) + len(ident) + len(location.file_path) + 128
    if line_cap < 256 {
        line_cap = 256
    }
    buf := strings.builder_make_len_cap(0, line_cap, context.temp_allocator)
    do_time_header(options, &buf, time.now())
    do_level_header(options, &buf, level)
    do_module_header(&buf, location, scope_label, has_scope_label)
    if ident != "" {
        fmt.sbprintf(&buf, "[%s] ", ident)
    }
    do_location_header(options, &buf, location)
    strings.write_string(&buf, message_text)
    return strings.clone(strings.to_string(buf), allocator)
}

console_logger_proc :: proc(
    logger_data: rawptr,
    level: Level,
    text: string,
    options: Options,
    loc := #caller_location,
) {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    data := cast(^Console_Logger_Data)logger_data
    scope_label, message_text, has_scope_label := split_log_scope_metadata(text)

    prefix := strings.builder_make_len_cap(0, 64, context.temp_allocator)
    do_time_header(options, &prefix, time.now())

    module_cap := len(loc.file_path) + len(scope_label) + 64
    if module_cap < 128 {
        module_cap = 128
    }
    module := strings.builder_make_len_cap(0, module_cap, context.temp_allocator)
    do_module_header(&module, loc, scope_label, has_scope_label)

    suffix_cap := len(data.ident) + len(loc.file_path) + 64
    if suffix_cap < 128 {
        suffix_cap = 128
    }
    suffix := strings.builder_make_len_cap(0, suffix_cap, context.temp_allocator)
    if data.ident != "" {
        fmt.sbprintf(&suffix, "[%s] ", data.ident)
    }
    do_location_header(options, &suffix, loc)

    prefix_ptr, prefix_len := js_string_parts(strings.to_string(prefix))
    module_ptr, module_len := js_string_parts(strings.to_string(module))
    suffix_ptr, suffix_len := js_string_parts(strings.to_string(suffix))
    message_ptr, message_len := js_string_parts(message_text)

    spy_console_log(
        int(level),
        1 if .Terminal_Color in options else 0,
        1 if .Level in options else 0,
        prefix_ptr,
        prefix_len,
        module_ptr,
        module_len,
        module_color_index(loc.file_path),
        suffix_ptr,
        suffix_len,
        message_ptr,
        message_len,
    )
}

do_level_header :: proc(opts: Options, buf: ^strings.Builder, level: Level) {
    if .Level not_in opts {
        return
    }

    label := "D"
    switch level {
    case .Debug:
        label = "D"
    case .Info:
        label = "I"
    case .Warning:
        label = "W"
    case .Error:
        label = "E"
    case .Fatal:
        label = "F"
    }

    fmt.sbprintf(buf, "%1s ", label)
}

js_string_parts :: #force_inline proc(s: string) -> (ptr: ^u8, count: u32) {
    if len(s) == 0 {
        return nil, 0
    }
    return raw_data(transmute([]u8)s), u32(len(s))
}

// #+vet redundancy public-api
module_color_index :: proc(path: string) -> int {
    start, end, ok := module_bounds(path)
    if !ok {
        return -1
    }

    hash: u64 = 1469598103934665603
    for i := start; i < end; i += 1 {
        c := path[i]
        if c == '/' || c == '\\' {
            hash = module_hash_byte(module_hash_byte(hash, ':'), ':')
            continue
        }
        hash = module_hash_byte(hash, c)
    }
    return int(hash % u64(JS_MODULE_COLOR_COUNT))
}

module_hash_byte :: #force_inline proc(hash: u64, b: byte) -> u64 {
    return (hash ~ u64(b)) * 1099511628211
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

do_scope_label_parts :: proc(buf: ^strings.Builder) {
    count := active_span_count()
    if count == 0 {
        return
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
}

do_scope_label_text :: proc(buf: ^strings.Builder, scope_label: string) {
    if scope_label == "" {
        return
    }
    strings.write_string(buf, scope_label)
}

do_module_header :: proc(
    buf: ^strings.Builder,
    location: runtime.Source_Code_Location,
    scope_override: string,
    has_scope_override: bool,
) {
    start, end, ok := module_bounds(location.file_path)
    scope_count := 0
    if !has_scope_override {
        scope_count = active_span_count()
    }
    if !ok && !has_scope_override && scope_count == 0 {
        return
    }

    strings.write_byte(buf, '[')
    if ok {
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
        if ok {
            strings.write_byte(buf, ':')
        }
        do_scope_label_text(buf, scope_override)
    } else if scope_count > 0 {
        if ok {
            strings.write_byte(buf, ':')
        }
        do_scope_label_parts(buf)
    }
    strings.write_string(buf, "] ")
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
