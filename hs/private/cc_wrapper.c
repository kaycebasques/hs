/*
 * Hermetic native C adapter bridging GHC (and Cabal ./configure) with Bazel's
 * active cc_toolchain (hermetic_cc_toolchain/zig cc, toolchains_llvm, or GCC).
 *
 * Zero Python or shell runtime dependencies. Handles all verified GHC <-> zig cc
 * integration mismatches:
 *   1. Sanitizes leaked Bazel RUNFILES_* env vars before exec.
 *   2. Intercepts `--print-file-name` so Clang/Zig never leaks host /usr/lib
 *      linker scripts or crashes on Zig's `.2.xx` glibc triple suffix.
 *   3. Rewrites `-Wl,-h` / `-Wl,-h,<soname>` -> `-Wl,-soname,<soname>` (incl. @rsp).
 *   4. Strips legacy `-fuse-ld=gold`.
 *   5. Rewrites `-fno-PIC` -> `-fPIC` when RULES_HASKELL_FORCE_PIC=1 (Zig gnu targets).
 *   6. Symlinks `.dyn_o`/`.p_o` object inputs to `.o` in TMPDIR (Zig rejects non-.o).
 *   7. Injects `-Wno-unused-command-line-argument` (except on --version queries)
 *      to silence Zig's implicit `-fno-sanitize=undefined` during `-E` / `-x assembler`
 *      and autoconf `./configure` preprocessor probes.
 */
#define _POSIX_C_SOURCE 200809L

#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

typedef struct {
    char **items;
    size_t len;
    size_t cap;
} StrVec;

static void vec_push(StrVec *v, char *s) {
    if (v->len == v->cap) {
        size_t ncap = v->cap ? v->cap * 2 : 32;
        char **nitems = (char **)realloc(v->items, ncap * sizeof(char *));
        if (!nitems) {
            perror("ghc_cc_wrapper: realloc");
            exit(1);
        }
        v->items = nitems;
        v->cap = ncap;
    }
    v->items[v->len++] = s;
}

static char *xstrdup(const char *s) {
    char *p = strdup(s);
    if (!p) {
        perror("ghc_cc_wrapper: strdup");
        exit(1);
    }
    return p;
}

static bool starts_with(const char *s, const char *prefix) {
    return strncmp(s, prefix, strlen(prefix)) == 0;
}

static bool ends_with(const char *s, const char *suffix) {
    size_t slen = strlen(s);
    size_t suflen = strlen(suffix);
    return slen >= suflen && strcmp(s + slen - suflen, suffix) == 0;
}

static char *read_entire_file(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        return NULL;
    }
    if (fseek(f, 0, SEEK_END) != 0) {
        fclose(f);
        return NULL;
    }
    long sz = ftell(f);
    if (sz < 0) {
        fclose(f);
        return NULL;
    }
    rewind(f);
    char *buf = (char *)malloc((size_t)sz + 1);
    if (!buf) {
        fclose(f);
        perror("ghc_cc_wrapper: malloc");
        exit(1);
    }
    size_t nread = fread(buf, 1, (size_t)sz, f);
    buf[nread] = '\0';
    fclose(f);
    return buf;
}

/* Parse GCC/GHC-style @response_file tokens (supports "...", '...', and \ escapes). */
static void parse_rsp(const char *content, StrVec *out) {
    const char *p = content;
    while (*p) {
        while (*p && isspace((unsigned char)*p)) {
            p++;
        }
        if (!*p) {
            break;
        }
        size_t cap = 64;
        size_t len = 0;
        char *tok = (char *)malloc(cap);
        if (!tok) {
            perror("ghc_cc_wrapper: malloc");
            exit(1);
        }
        char quote = 0;
        while (*p) {
            char c = *p;
            if (quote == 0) {
                if (isspace((unsigned char)c)) {
                    break;
                }
                if (c == '"' || c == '\'') {
                    quote = c;
                    p++;
                    continue;
                }
                if (c == '\\' && p[1]) {
                    p++;
                    c = *p++;
                } else {
                    p++;
                }
            } else if (quote == '\'') {
                if (c == '\'') {
                    quote = 0;
                    p++;
                    continue;
                }
                p++;
            } else { /* quote == '"' */
                if (c == '"') {
                    quote = 0;
                    p++;
                    continue;
                }
                if (c == '\\' && p[1]) {
                    p++;
                    c = *p++;
                } else {
                    p++;
                }
            }
            if (len + 2 >= cap) {
                cap *= 2;
                tok = (char *)realloc(tok, cap);
                if (!tok) {
                    perror("ghc_cc_wrapper: realloc");
                    exit(1);
                }
            }
            tok[len++] = c;
        }
        tok[len] = '\0';
        vec_push(out, tok);
    }
}

static bool write_rsp(const char *path, const StrVec *tokens) {
    FILE *f = fopen(path, "wb");
    if (!f) {
        return false;
    }
    for (size_t i = 0; i < tokens->len; i++) {
        fputc('"', f);
        for (const char *p = tokens->items[i]; *p; p++) {
            if (*p == '\\' || *p == '"') {
                fputc('\\', f);
            }
            fputc(*p, f);
        }
        fputs("\"\n", f);
    }
    if (fclose(f) != 0) {
        return false;
    }
    return true;
}

static int g_obj_counter = 0;
static char g_session_dir[PATH_MAX] = "";
static StrVec g_cleanup_files = {0};

static void vec_free_contents(StrVec *v) {
    for (size_t i = 0; i < v->len; i++) {
        free(v->items[i]);
    }
    free(v->items);
    v->items = NULL;
    v->len = 0;
    v->cap = 0;
}

static const char *get_session_tmpdir(void) {
    if (g_session_dir[0] != '\0') {
        return g_session_dir;
    }
    const char *tmpdir = getenv("TMPDIR");
    if (!tmpdir || !*tmpdir) {
        tmpdir = "/tmp";
    }
    int n = snprintf(g_session_dir, sizeof(g_session_dir), "%s/hs_ccw.XXXXXX", tmpdir);
    if (n < 0 || (size_t)n >= sizeof(g_session_dir) || !mkdtemp(g_session_dir)) {
        g_session_dir[0] = '\0';
        return tmpdir;
    }
    return g_session_dir;
}

static void cleanup_session_tmpdir(void) {
    for (size_t i = 0; i < g_cleanup_files.len; i++) {
        unlink(g_cleanup_files.items[i]);
    }
    if (g_session_dir[0] != '\0') {
        rmdir(g_session_dir);
        g_session_dir[0] = '\0';
    }
}

static char *ensure_dot_o_alias(const char *path) {
    if (access(path, F_OK) != 0) {
        return xstrdup(path);
    }
    char abs_buf[PATH_MAX];
    const char *target = realpath(path, abs_buf);
    if (!target) {
        target = path;
    }
    const char *sdir = get_session_tmpdir();
    char link_path[PATH_MAX];
    int written = snprintf(
        link_path,
        sizeof(link_path),
        "%s/hs_obj_%d.o",
        sdir,
        g_obj_counter++
    );
    if (written < 0 || (size_t)written >= sizeof(link_path)) {
        return xstrdup(path);
    }
    unlink(link_path);
    if (symlink(target, link_path) != 0) {
        return xstrdup(path);
    }
    vec_push(&g_cleanup_files, xstrdup(link_path));
    return xstrdup(link_path);
}

static void rewrite_tokens(
    char **in,
    size_t n,
    bool force_pic,
    StrVec *out,
    bool *changed_out
) {
    for (size_t i = 0; i < n; i++) {
        const char *a = in[i];
        if (a[0] == '@' && a[1] != '\0') {
            const char *rsp_path = a + 1;
            char *content = read_entire_file(rsp_path);
            if (content) {
                StrVec parsed = {0};
                StrVec rewritten = {0};
                bool rsp_changed = false;
                parse_rsp(content, &parsed);
                free(content);
                rewrite_tokens(
                    parsed.items,
                    parsed.len,
                    force_pic,
                    &rewritten,
                    &rsp_changed
                );
                vec_free_contents(&parsed);
                if (rsp_changed) {
                    if (write_rsp(rsp_path, &rewritten)) {
                        vec_push(out, xstrdup(a));
                    } else {
                        const char *sdir = get_session_tmpdir();
                        char tmp_rsp[PATH_MAX];
                        int written = snprintf(
                            tmp_rsp,
                            sizeof(tmp_rsp),
                            "%s/hs_rsp_%d.rsp",
                            sdir,
                            g_obj_counter++
                        );
                        if (written > 0 && (size_t)written < sizeof(tmp_rsp) && write_rsp(tmp_rsp, &rewritten)) {
                            vec_push(&g_cleanup_files, xstrdup(tmp_rsp));
                            char *at_arg = (char *)malloc(strlen(tmp_rsp) + 2);
                            if (!at_arg) {
                                perror("ghc_cc_wrapper: malloc");
                                exit(1);
                            }
                            at_arg[0] = '@';
                            strcpy(at_arg + 1, tmp_rsp);
                            vec_push(out, at_arg);
                        } else {
                            vec_push(out, xstrdup(a));
                        }
                    }
                } else {
                    vec_push(out, xstrdup(a));
                }
                vec_free_contents(&rewritten);
                continue;
            }
            vec_push(out, xstrdup(a));
        } else if (strcmp(a, "-o") == 0 && i + 1 < n) {
            vec_push(out, xstrdup(a));
            vec_push(out, xstrdup(in[++i]));
        } else if (strcmp(a, "-Wl,-h") == 0 && i + 1 < n && starts_with(in[i + 1], "-Wl,")) {
            const char *soname = in[i + 1] + 4;
            char *buf = (char *)malloc(strlen("-Wl,-soname,") + strlen(soname) + 1);
            if (!buf) {
                perror("ghc_cc_wrapper: malloc");
                exit(1);
            }
            sprintf(buf, "-Wl,-soname,%s", soname);
            vec_push(out, buf);
            i++;
            if (changed_out) *changed_out = true;
        } else if (starts_with(a, "-Wl,-h,")) {
            const char *soname = a + 7;
            char *buf = (char *)malloc(strlen("-Wl,-soname,") + strlen(soname) + 1);
            if (!buf) {
                perror("ghc_cc_wrapper: malloc");
                exit(1);
            }
            sprintf(buf, "-Wl,-soname,%s", soname);
            vec_push(out, buf);
            if (changed_out) *changed_out = true;
        } else if (strcmp(a, "-fuse-ld=gold") == 0) {
            if (changed_out) *changed_out = true;
        } else if (force_pic && strcmp(a, "-fno-PIC") == 0) {
            vec_push(out, xstrdup("-fPIC"));
            if (changed_out) *changed_out = true;
        } else if (ends_with(a, ".dyn_o") || ends_with(a, ".p_o")) {
            vec_push(out, ensure_dot_o_alias(a));
            if (changed_out) *changed_out = true;
        } else {
            vec_push(out, xstrdup(a));
        }
    }
}

static bool handle_print_file_name(int argc, char **argv) {
    const char *query = NULL;
    StrVec search_dirs = {0};

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (starts_with(a, "-B") && a[2] != '\0') {
            vec_push(&search_dirs, xstrdup(a + 2));
        } else if (strcmp(a, "-B") == 0 && i + 1 < argc) {
            vec_push(&search_dirs, xstrdup(argv[++i]));
        } else if (starts_with(a, "-L") && a[2] != '\0') {
            vec_push(&search_dirs, xstrdup(a + 2));
        } else if (strcmp(a, "-L") == 0 && i + 1 < argc) {
            vec_push(&search_dirs, xstrdup(argv[++i]));
        } else if (strcmp(a, "--print-file-name") == 0 && i + 1 < argc) {
            query = argv[++i];
        } else if (starts_with(a, "--print-file-name=")) {
            query = a + strlen("--print-file-name=");
        }
    }

    if (!query) {
        return false;
    }

    for (size_t i = 0; i < search_dirs.len; i++) {
        char candidate[PATH_MAX];
        snprintf(candidate, sizeof(candidate), "%s/%s", search_dirs.items[i], query);
        if (access(candidate, F_OK) == 0) {
            printf("%s\n", candidate);
            return true;
        }
    }
    printf("%s\n", query);
    return true;
}

static bool detect_cxx_invocation_depth(char **tokens, size_t n, int depth) {
    if (depth > 16) {
        return false;
    }
    for (size_t i = 0; i < n; i++) {
        const char *a = tokens[i];
        if (a[0] == '@' && a[1] != '\0') {
            char *content = read_entire_file(a + 1);
            if (content) {
                StrVec parsed = {0};
                parse_rsp(content, &parsed);
                free(content);
                bool found = detect_cxx_invocation_depth(parsed.items, parsed.len, depth + 1);
                vec_free_contents(&parsed);
                if (found) {
                    return true;
                }
            }
            continue;
        }
        if (strcmp(a, "-xc++") == 0 ||
            strcmp(a, "-xc++-header") == 0 ||
            strcmp(a, "-xc++-cpp-output") == 0 ||
            starts_with(a, "-std=c++") ||
            starts_with(a, "-std=gnu++") ||
            starts_with(a, "-stdlib=")) {
            return true;
        }
        if (strcmp(a, "-x") == 0 && i + 1 < n) {
            const char *lang = tokens[i + 1];
            if (strcmp(lang, "c++") == 0 ||
                strcmp(lang, "c++-header") == 0 ||
                strcmp(lang, "c++-cpp-output") == 0) {
                return true;
            }
        }
        if (a[0] != '-' &&
            (ends_with(a, ".cc") ||
             ends_with(a, ".cpp") ||
             ends_with(a, ".cxx") ||
             ends_with(a, ".C") ||
             ends_with(a, ".hh") ||
             ends_with(a, ".hpp") ||
             ends_with(a, ".hxx"))) {
            return true;
        }
    }
    return false;
}

static bool detect_cxx_invocation(char **tokens, size_t n) {
    return detect_cxx_invocation_depth(tokens, n, 0);
}

int main(int argc, char **argv) {
    /* Never let Bazel runfiles env vars leak into compiler/linker subprocesses. */
    unsetenv("RUNFILES_DIR");
    unsetenv("RUNFILES_MANIFEST_FILE");
    unsetenv("RUNFILES_MANIFEST_ONLY");

    if (handle_print_file_name(argc, argv)) {
        return 0;
    }

    const char *real_cc = getenv("RULES_HASKELL_REAL_CC");
    if (!real_cc || !*real_cc) {
        fprintf(stderr, "ghc_cc_wrapper: RULES_HASKELL_REAL_CC environment variable is not set\n");
        return 1;
    }

    const char *force_pic_env = getenv("RULES_HASKELL_FORCE_PIC");
    bool force_pic = (force_pic_env == NULL || strcmp(force_pic_env, "0") != 0);

    const char *is_gcc_env = getenv("RULES_HASKELL_CC_IS_GCC");
    bool is_gcc = (is_gcc_env != NULL && strcmp(is_gcc_env, "1") == 0);

    bool is_version_query = false;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--version") == 0 ||
            strcmp(argv[i], "-dumpversion") == 0 ||
            strcmp(argv[i], "-dumpmachine") == 0) {
            is_version_query = true;
            break;
        }
    }

    bool is_cxx = detect_cxx_invocation(argv + 1, (size_t)(argc - 1));

    StrVec final_args = {0};
    vec_push(&final_args, xstrdup(real_cc));

    if (!is_version_query && !is_gcc) {
        vec_push(&final_args, xstrdup("-Wno-unused-command-line-argument"));
        /*
         * hermetic_cc_toolchain exposes `zig c++` for C compilation, which places
         * libcxx/include ahead of C headers. That pulls <features.h> via
         * libcxx/include/stddef.h (from GHC's template-hsc.h) before user headers
         * like HsNet.h can `#define _GNU_SOURCE 1`, hiding struct ucred /
         * struct in6_pktinfo. Dropping C++ includes for C/asm/link invocations
         * restores standard C header order.
         */
        if (!is_cxx) {
            vec_push(&final_args, xstrdup("-nostdinc++"));
        }
    }

    /* Optional newline-delimited extra flags from Bazel's cc_toolchain (e.g. --sysroot, -B). */
    const char *extra = getenv("RULES_HASKELL_CC_EXTRA_ARGS");
    if (extra && *extra) {
        const char *p = extra;
        while (*p) {
            const char *nl = strchr(p, '\n');
            size_t len = nl ? (size_t)(nl - p) : strlen(p);
            if (len > 0) {
                char *tok = (char *)malloc(len + 1);
                if (!tok) {
                    perror("ghc_cc_wrapper: malloc");
                    return 1;
                }
                memcpy(tok, p, len);
                tok[len] = '\0';
                if (is_version_query &&
                    (starts_with(tok, "-fuse-ld=") || starts_with(tok, "--ld-path="))) {
                    free(tok);
                } else {
                    vec_push(&final_args, tok);
                }
            }
            if (!nl) break;
            p = nl + 1;
        }
    }

    rewrite_tokens(argv + 1, (size_t)(argc - 1), force_pic, &final_args, NULL);
    vec_push(&final_args, NULL);

    if (g_session_dir[0] == '\0' && g_cleanup_files.len == 0) {
        execv(real_cc, final_args.items);
        fprintf(stderr, "ghc_cc_wrapper: failed to exec '%s': %s\n", real_cc, strerror(errno));
        return 127;
    }

    pid_t pid = fork();
    if (pid < 0) {
        perror("ghc_cc_wrapper: fork");
        cleanup_session_tmpdir();
        return 1;
    }
    if (pid == 0) {
        execv(real_cc, final_args.items);
        fprintf(stderr, "ghc_cc_wrapper: failed to exec '%s': %s\n", real_cc, strerror(errno));
        _exit(127);
    }

    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) {
            cleanup_session_tmpdir();
            return 1;
        }
    }
    cleanup_session_tmpdir();
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    if (WIFSIGNALED(status)) {
        return 128 + WTERMSIG(status);
    }
    return 1;
}
