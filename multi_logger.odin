package spy


Multi_Logger_Data :: struct {
    loggers: []Logger,
}

// #+vet redundancy public-api
create_multi_logger :: proc(logs: ..Logger, alloc := context.allocator) -> Logger {
    data := new(Multi_Logger_Data, alloc)
    data.loggers = make([]Logger, len(logs), alloc)
    copy(data.loggers, logs)
    return {multi_logger_proc, data, Level.Debug, nil}
}

// #+vet redundancy public-api
destroy_multi_logger :: proc(log: Logger, alloc := context.allocator) {
    data := (^Multi_Logger_Data)(log.data)
    delete(data.loggers, alloc)
    free(data, alloc)
}

// #+vet redundancy public-api
multi_logger_proc :: proc(logger_data: rawptr, level: Level, text: string, options: Options, loc := #caller_location) {
    data := cast(^Multi_Logger_Data)logger_data
    for log in data.loggers {
        if level < log.lowest_level {
            return
        }
        log.procedure(log.data, level, text, log.options, loc)
    }
}
