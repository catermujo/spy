package spy

import "core:strings"
import "core:sync"

import "base:runtime"

Filter_Opts :: struct {
    exclude_packages: []string,
    exclude_scopes:   []string,
    lowest_level:     Level,
}

Filter_Layer_Id :: distinct u64

Package_Exclude_Filter_Data :: struct {
    drop_packages: [dynamic]string,
    allocator:     runtime.Allocator,
}

Scope_Exclude_Filter_Data :: struct {
    drop_scopes: [dynamic]string,
    allocator:   runtime.Allocator,
}

@(private)
Filtered_Logger_Data :: struct {
    target:              Logger,
    package_filter_data: ^Package_Exclude_Filter_Data,
    scope_filter_data:   ^Scope_Exclude_Filter_Data,
    lowest_level:        Level,
    allocator:           runtime.Allocator,
}

@(private)
Global_Filter_Layer_State :: struct {
    package_filter_data: ^Package_Exclude_Filter_Data,
    scope_filter_data:   ^Scope_Exclude_Filter_Data,
    package_layer_id:    Subscriber_Layer_Id,
    scope_layer_id:      Subscriber_Layer_Id,
    allocator:           runtime.Allocator,
}

@(private)
Global_Filter_Layer_Entry :: struct {
    id:    Filter_Layer_Id,
    state: ^Global_Filter_Layer_State,
}

@(private)
global_filter_layers_lock: sync.Mutex
@(private)
global_filter_layers: [dynamic]Global_Filter_Layer_Entry
@(private)
global_filter_layers_next_id: u64

// #+vet redundancy public-api
create_filtered_logger :: proc(target: Logger, opts: Filter_Opts, alloc := context.allocator) -> Logger {
    if target.procedure == nil || target.procedure == nil_logger_proc {
        return target
    }
    if len(opts.exclude_packages) == 0 && len(opts.exclude_scopes) == 0 {
        return target
    }

    allocator := filter_allocator(alloc)
    data := new(Filtered_Logger_Data, allocator)
    data.target = target
    data.lowest_level = opts.lowest_level
    data.allocator = allocator

    if len(opts.exclude_packages) > 0 {
        data.package_filter_data = new_package_exclude_filter(opts.exclude_packages, allocator)
    }
    if len(opts.exclude_scopes) > 0 {
        data.scope_filter_data = new_scope_exclude_filter(opts.exclude_scopes, allocator)
    }

    return {
        procedure = filtered_logger_proc,
        data = data,
        lowest_level = target.lowest_level,
        options = target.options,
    }
}

// #+vet redundancy public-api
destroy_filtered_logger :: proc(log: Logger, alloc := context.allocator) {
    if log.procedure != filtered_logger_proc {
        return
    }
    data := cast(^Filtered_Logger_Data)log.data
    if data == nil {
        return
    }
    if data.package_filter_data != nil {
        destroy_package_exclude_filter(data.package_filter_data)
    }
    if data.scope_filter_data != nil {
        destroy_scope_exclude_filter(data.scope_filter_data)
    }
    free(data, filter_allocator(data.allocator))
}

// #+vet redundancy public-api
add_global_filter_layer :: proc(
    logger: Logger,
    opts: Filter_Opts,
    alloc := context.allocator,
) -> (
    id: Filter_Layer_Id,
    ok: bool,
) {
    if len(opts.exclude_packages) == 0 && len(opts.exclude_scopes) == 0 {
        return 0, false
    }

    allocator := filter_allocator(alloc)
    state := new(Global_Filter_Layer_State, allocator)
    state.allocator = allocator

    if len(opts.exclude_packages) > 0 {
        state.package_filter_data = new_package_exclude_filter(opts.exclude_packages, allocator)
        layer_id, add_ok := add_global_subscriber_layer_with_id(
            logger,
            package_exclude_subscriber_filter(state.package_filter_data),
        )
        if !add_ok {
            destroy_package_exclude_filter(state.package_filter_data)
            free(state, allocator)
            return 0, false
        }
        state.package_layer_id = layer_id
    }

    if len(opts.exclude_scopes) > 0 {
        state.scope_filter_data = new_scope_exclude_filter(opts.exclude_scopes, allocator)
        layer_id, add_ok := add_global_subscriber_layer_with_id(
            logger,
            scope_exclude_subscriber_filter(state.scope_filter_data),
        )
        if !add_ok {
            if state.package_layer_id != 0 {
                remove_global_subscriber_layer_by_id(state.package_layer_id)
            }
            destroy_package_exclude_filter(state.package_filter_data)
            destroy_scope_exclude_filter(state.scope_filter_data)
            free(state, allocator)
            return 0, false
        }
        state.scope_layer_id = layer_id
    }

    sync.lock(&global_filter_layers_lock)
    defer sync.unlock(&global_filter_layers_lock)
    id = Filter_Layer_Id(global_filter_layers_next_id + 1)
    global_filter_layers_next_id += 1
    append(&global_filter_layers, Global_Filter_Layer_Entry{id = id, state = state})
    return id, true
}

// #+vet redundancy public-api
remove_global_filter_layer :: proc(id: Filter_Layer_Id) -> bool {
    if id == 0 {
        return false
    }

    state: ^Global_Filter_Layer_State
    found := false

    sync.lock(&global_filter_layers_lock)
    for entry, i in global_filter_layers {
        if entry.id != id {
            continue
        }
        state = entry.state
        found = true
        for j := i; j + 1 < len(global_filter_layers); j += 1 {
            global_filter_layers[j] = global_filter_layers[j + 1]
        }
        resize(&global_filter_layers, len(global_filter_layers) - 1)
        break
    }
    sync.unlock(&global_filter_layers_lock)

    if !found || state == nil {
        return false
    }

    if state.package_layer_id != 0 {
        remove_global_subscriber_layer_by_id(state.package_layer_id)
    }
    if state.scope_layer_id != 0 {
        remove_global_subscriber_layer_by_id(state.scope_layer_id)
    }
    destroy_package_exclude_filter(state.package_filter_data)
    destroy_scope_exclude_filter(state.scope_filter_data)
    free(state, filter_allocator(state.allocator))
    return true
}

new_package_exclude_filter :: proc(
    drop_packages: []string = nil,
    alloc := context.allocator,
) -> ^Package_Exclude_Filter_Data {
    allocator := filter_allocator(alloc)
    data := new(Package_Exclude_Filter_Data, allocator)
    data.allocator = allocator
    data.drop_packages = clone_string_list(drop_packages, allocator)
    return data
}

destroy_package_exclude_filter :: proc(data: ^Package_Exclude_Filter_Data) {
    if data == nil {
        return
    }

    alloc := filter_allocator(data.allocator)
    destroy_string_list(&data.drop_packages, alloc)
    free(data, alloc)
}

// #+vet redundancy public-api
package_exclude_subscriber_filter :: proc(data: ^Package_Exclude_Filter_Data) -> Subscriber_Filter {
    return {procedure = package_exclude_filter_proc, data = data}
}

new_scope_exclude_filter :: proc(
    drop_scopes: []string = nil,
    alloc := context.allocator,
) -> ^Scope_Exclude_Filter_Data {
    allocator := filter_allocator(alloc)
    data := new(Scope_Exclude_Filter_Data, allocator)
    data.allocator = allocator
    data.drop_scopes = clone_string_list(drop_scopes, allocator)
    return data
}

destroy_scope_exclude_filter :: proc(data: ^Scope_Exclude_Filter_Data) {
    if data == nil {
        return
    }

    alloc := filter_allocator(data.allocator)
    destroy_string_list(&data.drop_scopes, alloc)
    free(data, alloc)
}

// #+vet redundancy public-api
scope_exclude_subscriber_filter :: proc(data: ^Scope_Exclude_Filter_Data) -> Subscriber_Filter {
    return {procedure = scope_exclude_filter_proc, data = data}
}

@(private)
// #+vet redundancy public-api
filtered_logger_proc :: proc(
    filter_data: rawptr,
    level: Level,
    text: string,
    options: Options,
    loc := #caller_location,
) {
    data := cast(^Filtered_Logger_Data)filter_data
    if data == nil || data.target.procedure == nil || data.target.procedure == nil_logger_proc {
        return
    }

    filtered := false

    if data.package_filter_data != nil {
        if package_filter_matches(data.package_filter_data, loc) {
            filtered = true
        }
    }
    if data.scope_filter_data != nil {
        if scope_filter_matches(data.scope_filter_data, text) {
            filtered = true
        }
    }

    if filtered && level < data.lowest_level {
        return
    }
    data.target.procedure(data.target.data, level, text, data.target.options, loc)
}

@(private)
// #+vet redundancy public-api
package_exclude_filter_proc :: proc(
    filter_data: rawptr,
    _: Level,
    _: string,
    _: Options,
    loc: runtime.Source_Code_Location,
) -> bool {
    data := cast(^Package_Exclude_Filter_Data)filter_data
    return !package_filter_matches(data, loc)
}

@(private)
// #+vet redundancy public-api
scope_exclude_filter_proc :: proc(
    filter_data: rawptr,
    _: Level,
    text: string,
    _: Options,
    _: runtime.Source_Code_Location,
) -> bool {
    data := cast(^Scope_Exclude_Filter_Data)filter_data
    return !scope_filter_matches(data, text)
}

@(private)
package_filter_matches :: proc(data: ^Package_Exclude_Filter_Data, loc: runtime.Source_Code_Location) -> bool {
    if data == nil || len(data.drop_packages) == 0 {
        return false
    }

    package_name, ok := source_package_name(loc.file_path)
    if !ok || package_name == "" {
        return false
    }

    for denied in data.drop_packages {
        if denied != "" && denied == package_name {
            return true
        }
    }
    return false
}

@(private)
scope_filter_matches :: proc(data: ^Scope_Exclude_Filter_Data, text: string) -> bool {
    if data == nil || len(data.drop_scopes) == 0 {
        return false
    }

    scope_label, _, has_scope := split_log_scope_metadata(text)
    if !has_scope || scope_label == "" {
        return false
    }

    for denied in data.drop_scopes {
        if denied == "" {
            continue
        }
        if scope_label == denied {
            return true
        }
        if len(scope_label) > len(denied) &&
           strings.has_prefix(scope_label, denied) &&
           scope_label[len(denied)] == ':' {
            return true
        }
        if scope_chain_has_segment_name(scope_label, denied) {
            return true
        }
    }

    return false
}

@(private)
filter_allocator :: #force_inline proc(alloc: runtime.Allocator) -> runtime.Allocator {
    if alloc.procedure == nil {
        return runtime.default_context().allocator
    }
    return alloc
}

@(private)
clone_string_list :: proc(items: []string, alloc: runtime.Allocator) -> [dynamic]string {
    if len(items) == 0 {
        return nil
    }
    out := make([dynamic]string, 0, len(items), alloc)
    for item in items {
        append(&out, strings.clone(item, alloc))
    }
    return out
}

@(private)
destroy_string_list :: proc(items: ^[dynamic]string, alloc: runtime.Allocator) {
    if items == nil {
        return
    }
    for item in items^ {
        if item != "" {
            delete(item, alloc)
        }
    }
    if len(items^) > 0 {
        delete(items^)
    }
    items^ = nil
}

@(private)
// #+vet redundancy public-api
scope_chain_has_segment_name :: proc(scope_label, denied: string) -> bool {
    if scope_label == "" || denied == "" {
        return false
    }

    start := 0
    brace_depth := 0
    for i := 0; i <= len(scope_label); i += 1 {
        is_boundary := i == len(scope_label)
        if !is_boundary {
            c := scope_label[i]
            if c == '{' {
                brace_depth += 1
            } else if c == '}' && brace_depth > 0 {
                brace_depth -= 1
            }
            is_boundary = c == ':' && brace_depth == 0
        }
        if !is_boundary {
            continue
        }

        segment := scope_label[start:i]
        name := segment
        for j := 0; j < len(segment); j += 1 {
            if segment[j] == '{' {
                name = segment[:j]
                break
            }
        }
        if name == denied {
            return true
        }
        start = i + 1
    }

    return false
}

// #+vet redundancy public-api
source_package_name :: proc(path: string) -> (name: string, ok: bool) {
    if path == "" {
        return "", false
    }

    end := -1
    for i := len(path) - 1; i >= 0; i -= 1 {
        if path[i] == '/' || path[i] == '\\' {
            end = i
            break
        }
    }
    if end <= 0 {
        return "", false
    }

    start := 0
    for i := end - 1; i >= 0; i -= 1 {
        if path[i] == '/' || path[i] == '\\' {
            start = i + 1
            break
        }
    }

    if end <= start {
        return "", false
    }
    return path[start:end], true
}
