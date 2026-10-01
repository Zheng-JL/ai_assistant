#ifndef CODEX_PROCESS_INSPECTION_H
#define CODEX_PROCESS_INSPECTION_H

#include <stdint.h>

typedef void (*cs_writer_callback)(const char *thread_id, int32_t pid,
                                  double process_started_at, void *context);

// Inspects file descriptor metadata only. Does not open, lock, or alter files.
// Returns 0 on a complete scan, -1 on an incomplete/denied scan.
int cs_inspect_writers(int32_t app_pid, const char *app_bundle_path, const char *lock_directory,
                      cs_writer_callback callback, void *context,
                      int32_t *engine_count);

typedef void (*cs_engine_callback)(int32_t pid, double process_started_at, void *context);

// Whether `path` is a native engine executable under `directory`, at any numeric version.
int cs_is_claude_engine_path(const char *path, const char *directory);

// Only accepts Claude Desktop descendants at its versioned native engine path.
int cs_inspect_claude_engines(int32_t app_pid, const char *app_bundle_path,
                             const char *engine_directory, cs_engine_callback callback,
                             void *context, double *app_started_at);
int cs_process_matches(int32_t pid, double process_started_at);

#endif
