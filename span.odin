package spy

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"

import "base:runtime"

Span_Lifecycle :: enum {
    Off,
    Enter_Exit,
    Enter_Exit_Duration,
}

Span :: struct {
    id:      u64,
    active:  bool,
    started: time.Tick,
}

Span_Frame :: struct {
    id:      u64,
    name:    string,
    fields:  string,
    started: time.Tick,
}

Span_Context_Frame :: struct {
    id:      u64,
    name:    string,
    fields:  string,
    started: time.Tick,
}

Span_Context :: struct {
    frames:  [dynamic]Span_Context_Frame,
    next_id: u64,
}

Span_Context_Guard :: struct {
    previous: Span_Context,
    active:   bool,
}

@(thread_local, private = "file")
span_stack: [dynamic]Span_Frame

@(thread_local, private = "file")
span_next_id: u64

@(private = "file")
span_lifecycle_lock: sync.Mutex
@(private = "file")
span_lifecycle_mode: Span_Lifecycle
@(private = "file")
span_lifecycle_level: Level = .Debug

// #+vet redundancy public-api
set_span_lifecycle :: proc(mode: Span_Lifecycle, level := Level.Debug) {
    sync.lock(&span_lifecycle_lock)
    defer sync.unlock(&span_lifecycle_lock)
    span_lifecycle_mode = mode
    span_lifecycle_level = level
}

span_lifecycle :: proc() -> (mode: Span_Lifecycle, level: Level) {
    sync.lock(&span_lifecycle_lock)
    defer sync.unlock(&span_lifecycle_lock)
    return span_lifecycle_mode, span_lifecycle_level
}

// #+vet redundancy public-api
span_lifecycle_emit_enter :: proc(frame: Span_Frame, loc := #caller_location) {
    mode, level := span_lifecycle()
    if mode == .Off {
        return
    }
    if frame.fields == "" {
        logf(level, "span.enter %s", frame.name, loc = loc)
        return
    }
    logf(level, "span.enter %s {%s}", frame.name, frame.fields, loc = loc)
}

// #+vet redundancy public-api
span_lifecycle_emit_exit :: proc(frame: Span_Frame, loc := #caller_location) {
    mode, level := span_lifecycle()
    if mode == .Off {
        return
    }
    if mode == .Enter_Exit_Duration {
        elapsed := time.tick_since(frame.started)
        if frame.fields == "" {
            logf(level, "span.exit %s duration=%v", frame.name, elapsed, loc = loc)
            return
        }
        logf(level, "span.exit %s {%s} duration=%v", frame.name, frame.fields, elapsed, loc = loc)
        return
    }
    if frame.fields == "" {
        logf(level, "span.exit %s", frame.name, loc = loc)
        return
    }
    logf(level, "span.exit %s {%s}", frame.name, frame.fields, loc = loc)
}

@(private)
// #+vet redundancy public-api
span_stack_clear :: proc(alloc := context.allocator) {
    for i := len(span_stack) - 1; i >= 0; i -= 1 {
        if span_stack[i].name != "" {
            delete(span_stack[i].name, alloc)
        }
        if span_stack[i].fields != "" {
            delete(span_stack[i].fields, alloc)
        }
    }
    clear(&span_stack)
    span_next_id = 0
}

span_stack_destroy :: proc(alloc := context.allocator) {
    span_stack_clear(alloc)
    delete(span_stack)
    span_stack = nil
}

span_context_destroy :: proc(ctx: ^Span_Context, alloc := context.allocator) {
    if ctx == nil {
        return
    }
    for i := len(ctx.frames) - 1; i >= 0; i -= 1 {
        if ctx.frames[i].name != "" {
            delete(ctx.frames[i].name, alloc)
        }
        if ctx.frames[i].fields != "" {
            delete(ctx.frames[i].fields, alloc)
        }
    }
    if len(ctx.frames) > 0 {
        delete(ctx.frames)
    }
    ctx^ = {}
}

capture_span_context :: proc(alloc := context.allocator) -> (ctx: Span_Context) {
    ctx.next_id = span_next_id
    if len(span_stack) == 0 {
        return ctx
    }

    ctx.frames = make([dynamic]Span_Context_Frame, 0, len(span_stack), alloc)
    for frame in span_stack {
        append(&ctx.frames, Span_Context_Frame {
            id      = frame.id,
            name    = strings.clone(frame.name, alloc),
            fields  = strings.clone(frame.fields, alloc),
            started = frame.started,
        })
    }
    return ctx
}

apply_span_context :: proc(ctx: Span_Context, alloc := context.allocator) {
    span_stack_clear(alloc)
    if len(ctx.frames) == 0 {
        span_next_id = ctx.next_id
        return
    }

    for frame in ctx.frames {
        append(&span_stack, Span_Frame {
            id      = frame.id,
            name    = strings.clone(frame.name, alloc),
            fields  = strings.clone(frame.fields, alloc),
            started = frame.started,
        })
    }
    span_next_id = ctx.next_id
}

attach_span_context :: proc(ctx: Span_Context, alloc := context.allocator) -> Span_Context_Guard {
    guard: Span_Context_Guard = {
        previous = capture_span_context(alloc),
        active   = true,
    }
    apply_span_context(ctx, alloc)
    return guard
}

detach_span_context :: proc(guard: ^Span_Context_Guard, alloc := context.allocator) {
    if guard == nil || !guard.active {
        return
    }
    apply_span_context(guard.previous, alloc)
    span_context_destroy(&guard.previous, alloc)
    guard.active = false
}

@(private)
// #+vet redundancy public-api
scoped_span_context_end :: proc(
    _: Span_Context,
    allocator: runtime.Allocator,
    _: runtime.Source_Code_Location,
    guard: Span_Context_Guard,
) {
    guard := guard
    detach_span_context(&guard, allocator)
}

// #+vet redundancy public-api
scoped_span_context :: proc(
    ctx: Span_Context,
    alloc := context.allocator,
    loc := #caller_location,
) -> (
    scope_guard: Span_Context_Guard,
) #scope_exit(.implicit, scoped_span_context_end(ctx, alloc, loc, scope_guard)) {
    return attach_span_context(ctx, alloc)
}

enter_span :: proc(name: string, fields := "", alloc := context.allocator, loc := #caller_location) -> Span {
    span_name := name if name != "" else "span"
    start := time.tick_now()
    frame: Span_Frame = {
        id      = span_next_id + 1,
        name    = strings.clone(span_name, alloc),
        fields  = strings.clone(fields, alloc),
        started = start,
    }
    span_next_id = frame.id
    append(&span_stack, frame)
    span_lifecycle_emit_enter(frame, loc = loc)
    return {id = frame.id, active = true, started = start}
}

exit_span :: proc(span: ^Span, alloc := context.allocator, loc := #caller_location) {
    if span == nil || !span.active {
        return
    }

    index := -1
    for i := len(span_stack) - 1; i >= 0; i -= 1 {
        if span_stack[i].id == span.id {
            index = i
            break
        }
    }
    if index < 0 {
        span.active = false
        return
    }

    frame := span_stack[index]
    span_lifecycle_emit_exit(frame, loc = loc)

    for i := len(span_stack) - 1; i >= index; i -= 1 {
        if span_stack[i].name != "" {
            delete(span_stack[i].name, alloc)
        }
        if span_stack[i].fields != "" {
            delete(span_stack[i].fields, alloc)
        }
    }
    resize(&span_stack, index)
    span.active = false
}

// #+vet redundancy public-api
in_span :: proc(name: string, body: proc(), fields := "", alloc := context.allocator) {
    scope := enter_span(name, fields, alloc)
    defer exit_span(&scope, alloc)
    body()
}

@(private)
// #+vet redundancy public-api
scoped_span_end :: proc(_, _: string, allocator: runtime.Allocator, location: runtime.Source_Code_Location, scope: Span) {
    scope := scope
    exit_span(&scope, allocator, loc = location)
}

// #+vet redundancy public-api
scoped_span :: proc(
    name: string,
    fields := "",
    alloc := context.allocator,
    loc := #caller_location,
) -> (
    scope_value: Span,
) #scope_exit(.implicit, scoped_span_end(name, fields, alloc, loc, scope_value)) {
    return enter_span(name, fields, alloc, loc = loc)
}

scope :: proc(name: string, fields := "", alloc := context.allocator, loc := #caller_location) -> (scope_value: Span) \
#scope_exit(.implicit, scoped_span_end(name, fields, alloc, loc, scope_value)) {
    return enter_span(name, fields, alloc, loc = loc)
}

span :: enter_span
span_end :: exit_span
scope_begin :: enter_span
scope_end :: exit_span

format_span_fields :: proc(fmt_str: string, args: ..any) -> string {
    return fmt.tprintf(fmt_str, ..args)
}

active_span_count :: #force_inline proc() -> int {
    return len(span_stack)
}

active_span_at :: #force_inline proc(index: int) -> Span_Frame {
    return span_stack[index]
}
