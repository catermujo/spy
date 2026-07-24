package spy

import "base:runtime"

Span_Carrier :: struct {
    ctx:       Span_Context,
    allocator: runtime.Allocator,
}

Scoped_Message :: struct($T: typeid) {
    payload: T,
    span:    Span_Carrier,
}

// #+vet redundancy public-api
capture_span_carrier :: proc(allocator := runtime.default_context().allocator) -> Span_Carrier {
    return {ctx = capture_span_context(allocator), allocator = allocator}
}

// #+vet redundancy public-api
destroy_span_carrier :: proc(carrier: ^Span_Carrier) {
    if carrier == nil {
        return
    }
    allocator := carrier.allocator
    if allocator.procedure == nil {
        allocator = runtime.default_context().allocator
    }
    span_context_destroy(&carrier.ctx, allocator)
    carrier^ = {}
}

wrap_scoped_message :: proc(payload: $T, span_allocator := runtime.default_context().allocator) -> Scoped_Message(T) {
    return {payload = payload, span = capture_span_carrier(span_allocator)}
}

scoped_message_destroy :: proc(msg: ^Scoped_Message($T)) {
    if msg == nil {
        return
    }
    destroy_span_carrier(&msg.span)
    msg^ = {}
}

attach_scoped_message_context :: proc(msg: Scoped_Message($T), alloc := context.allocator) -> Span_Context_Guard {
    return attach_span_context(msg.span.ctx, alloc)
}
