#include "ProcessInspection.h"
#include <errno.h>
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <unistd.h>

struct process_record {
    int32_t pid;
    struct proc_bsdinfo info;
};

static int is_descendant(struct process_record *records, int count, int index,
                         int32_t root) {
    int32_t parent = records[index].info.pbi_ppid;
    for (int depth = 0; depth < 64 && parent > 1; ++depth) {
        if (parent == root) return 1;
        int found = 0;
        for (int j = 0; j < count; ++j) {
            if (records[j].pid == parent) {
                parent = records[j].info.pbi_ppid;
                found = 1;
                break;
            }
        }
        if (!found) break;
    }
    return 0;
}

static int is_uuid_lock(const char *name) {
    if (strlen(name) != 41 || strcmp(name + 36, ".lock") != 0) return 0;
    for (int j = 0; j < 36; ++j) {
        if (j == 8 || j == 13 || j == 18 || j == 23) {
            if (name[j] != '-') return 0;
        } else if (!((name[j] >= '0' && name[j] <= '9') ||
                     (name[j] >= 'a' && name[j] <= 'f') ||
                     (name[j] >= 'A' && name[j] <= 'F'))) return 0;
    }
    return 1;
}

static int same_process(int32_t pid, const struct proc_bsdinfo *before) {
    struct proc_bsdinfo after;
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &after, sizeof(after)) == sizeof(after) &&
           after.pbi_uid == before->pbi_uid && after.pbi_ppid == before->pbi_ppid &&
           after.pbi_start_tvsec == before->pbi_start_tvsec &&
           after.pbi_start_tvusec == before->pbi_start_tvusec;
}

static int engine_path(const char *bundle, const char *relative, char *resolved) {
    char path[PROC_PIDPATHINFO_MAXSIZE];
    int length = snprintf(path, sizeof(path), "%s/%s", bundle, relative);
    return length > 0 && length < (int)sizeof(path) && realpath(path, resolved) != NULL;
}

int cs_inspect_writers(int32_t app_pid, const char *app_bundle_path, const char *lock_directory,
                      cs_writer_callback callback, void *context,
                      int32_t *engine_count) {
    if (!app_bundle_path || !lock_directory || !callback || !engine_count) return -1;
    *engine_count = 0;
    char bundled_engine[PROC_PIDPATHINFO_MAXSIZE] = {0};
    char bundled_launcher[PROC_PIDPATHINFO_MAXSIZE] = {0};
    int has_engine = engine_path(app_bundle_path, "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", bundled_engine);
    int has_launcher = engine_path(app_bundle_path, "Contents/Resources/codex-cli/bin/codex", bundled_launcher);
    if (!has_engine && !has_launcher) return -1;
    struct proc_bsdinfo root;
    if (proc_pidinfo(app_pid, PROC_PIDTBSDINFO, 0, &root, sizeof(root)) != sizeof(root) ||
        root.pbi_uid != getuid()) return -1;
    int capacity = proc_listallpids(NULL, 0);
    if (capacity <= 0 || capacity > 100000) return -1;
    capacity += 1024;
    int32_t *pids = calloc((size_t)capacity, sizeof(*pids));
    struct process_record *records = calloc((size_t)capacity, sizeof(*records));
    if (!pids || !records) { free(pids); free(records); return -1; }
    int count = proc_listallpids(pids, capacity * (int)sizeof(*pids));
    if (count <= 0 || count >= capacity) {
        free(pids); free(records); return -1;
    }
    int used = 0, result = 0;
    for (int j = 0; j < count; ++j) {
        struct proc_bsdinfo info;
        if (proc_pidinfo(pids[j], PROC_PIDTBSDINFO, 0, &info, sizeof(info)) == sizeof(info)) {
            if (info.pbi_uid == getuid()) records[used++] = (struct process_record){pids[j], info};
        } else {
            char path[PROC_PIDPATHINFO_MAXSIZE];
            if (proc_pidpath(pids[j], path, sizeof(path)) > 0 &&
                (strcmp(path, bundled_engine) == 0 || strcmp(path, bundled_launcher) == 0)) {
                result = -1;
            }
        }
    }
    free(pids);
    size_t prefix_length = strlen(lock_directory);
    for (int j = 0; j < used; ++j) {
        if (!is_descendant(records, used, j, app_pid)) continue;
        char executable[PROC_PIDPATHINFO_MAXSIZE];
        if (proc_pidpath(records[j].pid, executable, sizeof(executable)) <= 0) {
            if (strcmp(records[j].info.pbi_name, "codex") == 0 ||
                strcmp(records[j].info.pbi_comm, "codex") == 0) result = -1;
            continue;
        }
        if (strcmp(executable, bundled_engine) != 0 && strcmp(executable, bundled_launcher) != 0) continue;
        ++*engine_count;
        if (!same_process(records[j].pid, &records[j].info)) { result = -1; continue; }
        int bytes = proc_pidinfo(records[j].pid, PROC_PIDLISTFDS, 0, NULL, 0);
        if (bytes <= 0) { result = -1; continue; }
        bytes += 256 * (int)sizeof(struct proc_fdinfo);
        struct proc_fdinfo *fds = malloc((size_t)bytes);
        if (!fds) { result = -1; continue; }
        int actual = proc_pidinfo(records[j].pid, PROC_PIDLISTFDS, 0, fds, bytes);
        if (actual <= 0 || actual >= bytes) {
            free(fds); result = -1; continue;
        }
        for (int k = 0; k < actual / (int)sizeof(*fds); ++k) {
            if (fds[k].proc_fdtype != PROX_FDTYPE_VNODE) continue;
            struct vnode_fdinfowithpath vnode;
            errno = 0;
            int received = proc_pidfdinfo(records[j].pid, fds[k].proc_fd,
                                         PROC_PIDFDVNODEPATHINFO, &vnode, sizeof(vnode));
            if (received != sizeof(vnode)) {
                // Descriptors may close during inspection; denial is not an empty result.
                if (errno != EBADF && errno != ENOENT) result = -1;
                continue;
            }
            const char *path = vnode.pvip.vip_path;
            if (strncmp(path, lock_directory, prefix_length) != 0 ||
                path[prefix_length] != '/') continue;
            const char *name = path + prefix_length + 1;
            if (!is_uuid_lock(name)) continue;
            char thread_id[37];
            memcpy(thread_id, name, 36);
            thread_id[36] = '\0';
            double started = (double)records[j].info.pbi_start_tvsec +
                             (double)records[j].info.pbi_start_tvusec / 1000000.0;
            callback(thread_id, records[j].pid, started, context);
        }
        free(fds);
        if (!same_process(records[j].pid, &records[j].info)) result = -1;
    }
    free(records);
    if (!same_process(app_pid, &root)) result = -1;
    return result;
}

static double process_start(const struct proc_bsdinfo *info) {
    return (double)info->pbi_start_tvsec + (double)info->pbi_start_tvusec / 1000000.0;
}

int cs_process_matches(int32_t pid, double process_started_at) {
    struct proc_bsdinfo info;
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) == sizeof(info) &&
           info.pbi_uid == getuid() && process_start(&info) == process_started_at;
}

// Accepts "<directory>/<major>.<minor>.<patch>/claude.app/Contents/MacOS/claude" for any numeric version.
// The structure is still checked strictly; only the specific version number is left open, so a Claude
// update does not make the whole Claude side unverifiable (the version is reported separately).
int cs_is_claude_engine_path(const char *path, const char *directory) {
    size_t prefix = strlen(directory);
    if (strncmp(path, directory, prefix) != 0 || path[prefix] != '/') return 0;
    const char *version = path + prefix + 1;
    const char *suffix = strchr(version, '/');
    if (!suffix || suffix == version ||
        strcmp(suffix, "/claude.app/Contents/MacOS/claude") != 0) return 0;
    int dots = 0, digits = 0;
    for (const char *p = version; p < suffix; ++p) {
        if (*p >= '0' && *p <= '9') ++digits;
        else if (*p == '.' && digits > 0) { ++dots; digits = 0; }
        else return 0;
    }
    return dots == 2 && digits > 0;
}

int cs_inspect_claude_engines(int32_t app_pid, const char *app_bundle_path,
                             const char *engine_directory, cs_engine_callback callback,
                             void *context, double *app_started_at) {
    if (!app_bundle_path || !engine_directory || !callback || !app_started_at) return -1;
    struct proc_bsdinfo root;
    char expected[PROC_PIDPATHINFO_MAXSIZE], executable[PROC_PIDPATHINFO_MAXSIZE];
    if (!engine_path(app_bundle_path, "Contents/MacOS/Claude", expected) ||
        proc_pidinfo(app_pid, PROC_PIDTBSDINFO, 0, &root, sizeof(root)) != sizeof(root) ||
        root.pbi_uid != getuid() || proc_pidpath(app_pid, executable, sizeof(executable)) <= 0 ||
        strcmp(executable, expected) != 0) return -1;
    *app_started_at = process_start(&root);
    int capacity = proc_listallpids(NULL, 0);
    if (capacity <= 0 || capacity > 100000) return -1;
    capacity += 1024;
    int32_t *pids = calloc((size_t)capacity, sizeof(*pids));
    struct process_record *records = calloc((size_t)capacity, sizeof(*records));
    if (!pids || !records) { free(pids); free(records); return -1; }
    int count = proc_listallpids(pids, capacity * (int)sizeof(*pids));
    if (count <= 0 || count >= capacity) { free(pids); free(records); return -1; }
    int used = 0, result = 0;
    for (int j = 0; j < count; ++j) {
        struct proc_bsdinfo info;
        if (proc_pidinfo(pids[j], PROC_PIDTBSDINFO, 0, &info, sizeof(info)) == sizeof(info)) {
            if (info.pbi_uid == getuid()) records[used++] = (struct process_record){pids[j], info};
        } else if (proc_pidpath(pids[j], executable, sizeof(executable)) > 0 &&
                   cs_is_claude_engine_path(executable, engine_directory)) result = -1;
    }
    free(pids);
    for (int j = 0; j < used; ++j) {
        if (!is_descendant(records, used, j, app_pid)) continue;
        if (proc_pidpath(records[j].pid, executable, sizeof(executable)) <= 0) {
            if (strcmp(records[j].info.pbi_name, "claude") == 0 ||
                strcmp(records[j].info.pbi_comm, "claude") == 0) result = -1;
            continue;
        }
        if (!cs_is_claude_engine_path(executable, engine_directory)) {
            if (strcmp(records[j].info.pbi_name, "claude") == 0 ||
                strcmp(records[j].info.pbi_comm, "claude") == 0) result = -1;
            continue;
        }
        if (!same_process(records[j].pid, &records[j].info)) { result = -1; continue; }
        callback(records[j].pid, process_start(&records[j].info), context);
        if (!same_process(records[j].pid, &records[j].info)) result = -1;
    }
    free(records);
    if (!same_process(app_pid, &root)) result = -1;
    return result;
}
