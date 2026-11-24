/*
 * Self-contained C11 terminfo implementation (`libtinfo.so.6` & `libtinfo.a`)
 * for GHC, GHCi (`haskeline`), and `System.Console.Terminfo` (`terminfo`).
 *
 * Exports the exact 8 X/Open Curses symbols imported by GHC's `libHSterminfo`
 * under ELF symbol version `NCURSES6_TINFO_5.0.19991023` (see tinfo_stub.lds),
 * with zero dependency on host `libtinfo` / `ncurses` headers or libraries:
 *
 *   1. Headless / Bazel sandbox mode: when `term` is NULL and `$TERM` is unset
 *      or empty (the default under `--incompatible_strict_action_env` and
 *      `env -i`), `setupterm` sets `*errret = -1` and returns `-1`, matching
 *      standard ncurses behavior when no terminal is configured.
 *   2. Real `term(5)` binary database reader: when a terminal name is present,
 *      searches `$TERMINFO`, `$HOME/.terminfo`, `$TERMINFO_DIRS`, and standard
 *      system terminfo directories (`/etc/terminfo`, `/lib/terminfo`,
 *      `/usr/share/terminfo`, `/usr/local/share/terminfo`), parsing both
 *      classic 16-bit (`0432`) and ncurses6 extended 32-bit (`01036`) compiled
 *      terminfo entries plus extended user-defined capabilities.
 *   3. Built-in fallback profiles: on minimal containers where no terminfo
 *      files are installed on disk, provides built-in `dumb` and ANSI/VT100/
 *      `xterm` / `xterm-256color` capability sets with live `TIOCGWINSZ`
 *      window dimensions so interactive `ghci` (`hs_repl`) and TUI binaries
 *      still have line editing, arrow-key history, cursor addressing, and
 *      256-color formatting.
 */
#define _POSIX_C_SOURCE 200809L

#include <ctype.h>
#include <limits.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define STD_BOOL_COUNT 44
#define STD_NUM_COUNT 39
#define STD_STR_COUNT 414

static const char *const kBoolNames[STD_BOOL_COUNT] = {
    "bw", "am", "xsb", "xhp", "xenl", "eo", "gn", "hc", "km", "hs",
    "in", "da", "db", "mir", "msgr", "os", "eslok", "xt", "hz", "ul",
    "xon", "nxon", "mc5i", "chts", "nrrmc", "npc", "ndscr", "ccc", "bce", "hls",
    "xhpa", "crxm", "daisy", "xvpa", "sam", "cpix", "lpix", "OTbs", "OTns", "OTnc",
    "OTMT", "OTNL", "OTpt", "OTxr",
};

static const char *const kNumNames[STD_NUM_COUNT] = {
    "cols", "it", "lines", "lm", "xmc", "pb", "vt", "wsl", "nlab", "lh",
    "lw", "ma", "wnum", "colors", "pairs", "ncv", "bufsz", "spinv", "spinh", "maddr",
    "mjump", "mcs", "mls", "npins", "orc", "orl", "orhi", "orvi", "cps", "widcs",
    "btns", "bitwin", "bitype", "OTug", "OTdC", "OTdN", "OTdB", "OTdT", "OTkn",
};

static const char *const kStrNames[STD_STR_COUNT] = {
    "cbt", "bel", "cr", "csr", "tbc", "clear", "el", "ed", "hpa", "cmdch",
    "cup", "cud1", "home", "civis", "cub1", "mrcup", "cnorm", "cuf1", "ll", "cuu1",
    "cvvis", "dch1", "dl1", "dsl", "hd", "smacs", "blink", "bold", "smcup", "smdc",
    "dim", "smir", "invis", "prot", "rev", "smso", "smul", "ech", "rmacs", "sgr0",
    "rmcup", "rmdc", "rmir", "rmso", "rmul", "flash", "ff", "fsl", "is1", "is2",
    "is3", "if", "ich1", "il1", "ip", "kbs", "ktbc", "kclr", "kctab", "kdch1",
    "kdl1", "kcud1", "krmir", "kel", "ked", "kf0", "kf1", "kf10", "kf2", "kf3",
    "kf4", "kf5", "kf6", "kf7", "kf8", "kf9", "khome", "kich1", "kil1", "kcub1",
    "kll", "knp", "kpp", "kcuf1", "kind", "kri", "khts", "kcuu1", "rmkx", "smkx",
    "lf0", "lf1", "lf10", "lf2", "lf3", "lf4", "lf5", "lf6", "lf7", "lf8",
    "lf9", "rmm", "smm", "nel", "pad", "dch", "dl", "cud", "ich", "indn",
    "il", "cub", "cuf", "rin", "cuu", "pfkey", "pfloc", "pfx", "mc0", "mc4",
    "mc5", "rep", "rs1", "rs2", "rs3", "rf", "rc", "vpa", "sc", "ind",
    "ri", "sgr", "hts", "wind", "ht", "tsl", "uc", "hu", "iprog", "ka1",
    "ka3", "kb2", "kc1", "kc3", "mc5p", "rmp", "acsc", "pln", "kcbt", "smxon",
    "rmxon", "smam", "rmam", "xonc", "xoffc", "enacs", "smln", "rmln", "kbeg", "kcan",
    "kclo", "kcmd", "kcpy", "kcrt", "kend", "kent", "kext", "kfnd", "khlp", "kmrk",
    "kmsg", "kmov", "knxt", "kopn", "kopt", "kprv", "kprt", "krdo", "kref", "krfr",
    "krpl", "krst", "kres", "ksav", "kspd", "kund", "kBEG", "kCAN", "kCMD", "kCPY",
    "kCRT", "kDC", "kDL", "kslt", "kEND", "kEOL", "kEXT", "kFND", "kHLP", "kHOM",
    "kIC", "kLFT", "kMSG", "kMOV", "kNXT", "kOPT", "kPRV", "kPRT", "kRDO", "kRPL",
    "kRIT", "kRES", "kSAV", "kSPD", "kUND", "rfi", "kf11", "kf12", "kf13", "kf14",
    "kf15", "kf16", "kf17", "kf18", "kf19", "kf20", "kf21", "kf22", "kf23", "kf24",
    "kf25", "kf26", "kf27", "kf28", "kf29", "kf30", "kf31", "kf32", "kf33", "kf34",
    "kf35", "kf36", "kf37", "kf38", "kf39", "kf40", "kf41", "kf42", "kf43", "kf44",
    "kf45", "kf46", "kf47", "kf48", "kf49", "kf50", "kf51", "kf52", "kf53", "kf54",
    "kf55", "kf56", "kf57", "kf58", "kf59", "kf60", "kf61", "kf62", "kf63", "el1",
    "mgc", "smgl", "smgr", "fln", "sclk", "dclk", "rmclk", "cwin", "wingo", "hup",
    "dial", "qdial", "tone", "pulse", "hook", "pause", "wait", "u0", "u1", "u2",
    "u3", "u4", "u5", "u6", "u7", "u8", "u9", "op", "oc", "initc",
    "initp", "scp", "setf", "setb", "cpi", "lpi", "chr", "cvr", "defc", "swidm",
    "sdrfq", "sitm", "slm", "smicm", "snlq", "snrmq", "sshm", "ssubm", "ssupm", "sum",
    "rwidm", "ritm", "rlm", "rmicm", "rshm", "rsubm", "rsupm", "rum", "mhpa", "mcud1",
    "mcub1", "mcuf1", "mvpa", "mcuu1", "porder", "mcud", "mcub", "mcuf", "mcuu", "scs",
    "smgb", "smgbp", "smglp", "smgrp", "smgt", "smgtp", "sbim", "scsd", "rbim", "rcsd",
    "subcs", "supcs", "docr", "zerom", "csnm", "kmous", "minfo", "reqmp", "getm", "setaf",
    "setab", "pfxl", "devt", "csin", "s0ds", "s1ds", "s2ds", "s3ds", "smglr", "smgtb",
    "birep", "binel", "bicr", "colornm", "defbi", "endbi", "setcolor", "slines", "dispc", "smpch",
    "rmpch", "smsc", "rmsc", "pctrm", "scesc", "scesa", "ehhlm", "elhlm", "elohlm", "erhlm",
    "ethlm", "evhlm", "sgr1", "slength", "OTi2", "OTrs", "OTnl", "OTbc", "OTko", "OTma",
    "OTG2", "OTG3", "OTG1", "OTG4", "OTGR", "OTGL", "OTGU", "OTGD", "OTGH", "OTGV",
    "OTGC", "meml", "memu", "box1",
};

typedef struct {
    const char *name;
    int value;
} ExtIntCap;

typedef struct {
    const char *name;
    const char *value;
} ExtStrCap;

typedef struct {
    int fildes;
    int8_t bools[STD_BOOL_COUNT];
    int32_t nums[STD_NUM_COUNT];
    const char *strs[STD_STR_COUNT];

    char *raw_str_buf;
    char *ext_str_buf;

    ExtIntCap *ext_bools;
    size_t ext_bool_len;

    ExtIntCap *ext_nums;
    size_t ext_num_len;

    ExtStrCap *ext_strs;
    size_t ext_str_len;
} RulesHaskellTerm;

static RulesHaskellTerm *g_cur_term = NULL;

static int16_t read_le16(const uint8_t *p) {
    uint16_t u = (uint16_t)p[0] | ((uint16_t)p[1] << 8);
    return (int16_t)u;
}

static int32_t read_le32(const uint8_t *p) {
    uint32_t u = (uint32_t)p[0] |
                 ((uint32_t)p[1] << 8) |
                 ((uint32_t)p[2] << 16) |
                 ((uint32_t)p[3] << 24);
    return (int32_t)u;
}

static void init_empty_term(RulesHaskellTerm *t, int fildes) {
    memset(t, 0, sizeof(*t));
    t->fildes = fildes;
    for (int i = 0; i < STD_NUM_COUNT; i++) {
        t->nums[i] = -1;
    }
}

static void free_term(RulesHaskellTerm *t) {
    if (!t) {
        return;
    }
    free(t->raw_str_buf);
    free(t->ext_str_buf);
    free(t->ext_bools);
    free(t->ext_nums);
    free(t->ext_strs);
    free(t);
}

static bool has_nul_within(const char *buf, size_t offset, size_t total) {
    if (offset >= total) {
        return false;
    }
    return memchr(buf + offset, '\0', total - offset) != NULL;
}

static bool parse_terminfo_bytes(const uint8_t *data, size_t len, RulesHaskellTerm *t) {
    if (len < 12) {
        return false;
    }
    int16_t magic = read_le16(data);
    size_t num_width = 0;
    if (magic == 0432) {
        num_width = 2;
    } else if (magic == 01036) {
        num_width = 4;
    } else {
        return false;
    }

    int16_t names_sz = read_le16(data + 2);
    int16_t bool_cnt = read_le16(data + 4);
    int16_t num_cnt = read_le16(data + 6);
    int16_t off_cnt = read_le16(data + 8);
    uint16_t str_sz = (uint16_t)read_le16(data + 10);

    if (names_sz < 0 || bool_cnt < 0 || num_cnt < 0 || off_cnt < 0) {
        return false;
    }

    size_t pos = 12;
    if (pos + (size_t)names_sz + (size_t)bool_cnt > len) {
        return false;
    }
    pos += (size_t)names_sz;

    const uint8_t *bool_base = data + pos;
    pos += (size_t)bool_cnt;
    if ((pos % 2) != 0) {
        if (pos + 1 > len) {
            return false;
        }
        pos += 1;
    }

    size_t nums_bytes = (size_t)num_cnt * num_width;
    size_t offs_bytes = (size_t)off_cnt * 2;
    if (pos + nums_bytes + offs_bytes + (size_t)str_sz > len) {
        return false;
    }

    const uint8_t *num_base = data + pos;
    pos += nums_bytes;

    const uint8_t *off_base = data + pos;
    pos += offs_bytes;

    const uint8_t *str_base = data + pos;
    pos += (size_t)str_sz;

    char *str_copy = NULL;
    if (str_sz > 0) {
        str_copy = (char *)malloc((size_t)str_sz + 1);
        if (!str_copy) {
            return false;
        }
        memcpy(str_copy, str_base, str_sz);
        str_copy[str_sz] = '\0';
    }
    t->raw_str_buf = str_copy;

    int b_lim = bool_cnt < STD_BOOL_COUNT ? bool_cnt : STD_BOOL_COUNT;
    for (int i = 0; i < b_lim; i++) {
        t->bools[i] = (bool_base[i] == 1) ? 1 : 0;
    }

    int n_lim = num_cnt < STD_NUM_COUNT ? num_cnt : STD_NUM_COUNT;
    for (int i = 0; i < n_lim; i++) {
        int32_t v = (num_width == 4)
                        ? read_le32(num_base + (size_t)i * 4)
                        : (int32_t)read_le16(num_base + (size_t)i * 2);
        t->nums[i] = (v >= 0) ? v : -1;
    }

    int s_lim = off_cnt < STD_STR_COUNT ? off_cnt : STD_STR_COUNT;
    for (int i = 0; i < s_lim; i++) {
        int16_t off = read_le16(off_base + (size_t)i * 2);
        if (off >= 0 && str_copy && has_nul_within(str_copy, (size_t)off, str_sz)) {
            t->strs[i] = str_copy + off;
        } else {
            t->strs[i] = NULL;
        }
    }

    /* Optional ncurses extended capability section (even-aligned after str_table). */
    if ((pos % 2) != 0) {
        pos += 1;
    }
    if (pos + 10 > len) {
        return true;
    }

    int16_t ext_bool_cnt = read_le16(data + pos);
    int16_t ext_num_cnt = read_le16(data + pos + 2);
    int16_t ext_str_cnt = read_le16(data + pos + 4);
    int16_t ext_off_cnt = read_le16(data + pos + 6);
    uint16_t ext_str_sz = (uint16_t)read_le16(data + pos + 8);
    pos += 10;

    if (ext_bool_cnt < 0 || ext_num_cnt < 0 || ext_str_cnt < 0 || ext_off_cnt < 0) {
        return true;
    }

    int32_t total_ext_names = (int32_t)ext_bool_cnt + (int32_t)ext_num_cnt + (int32_t)ext_str_cnt;
    if ((int32_t)ext_off_cnt < (int32_t)ext_str_cnt + total_ext_names) {
        return true;
    }

    size_t ext_pad = ((size_t)ext_bool_cnt % 2) != 0 ? 1 : 0;
    size_t ext_nums_bytes = (size_t)ext_num_cnt * num_width;
    size_t ext_offs_bytes = (size_t)ext_off_cnt * 2;
    if (pos + (size_t)ext_bool_cnt + ext_pad + ext_nums_bytes + ext_offs_bytes + (size_t)ext_str_sz > len) {
        return true;
    }

    const uint8_t *eb_base = data + pos;
    pos += (size_t)ext_bool_cnt + ext_pad;

    const uint8_t *en_base = data + pos;
    pos += ext_nums_bytes;

    const uint8_t *eo_base = data + pos;
    pos += ext_offs_bytes;

    const uint8_t *es_base = data + pos;
    if (ext_str_sz == 0 || total_ext_names == 0) {
        return true;
    }

    char *ext_copy = (char *)malloc((size_t)ext_str_sz + 1);
    if (!ext_copy) {
        return true;
    }
    memcpy(ext_copy, es_base, ext_str_sz);
    ext_copy[ext_str_sz] = '\0';
    t->ext_str_buf = ext_copy;

    /* Extended capability names start immediately after the last extended string value. */
    size_t names_start = 0;
    for (int i = 0; i < ext_str_cnt; i++) {
        int16_t off = read_le16(eo_base + (size_t)i * 2);
        if (off >= 0 && (size_t)off < ext_str_sz) {
            const char *nul = (const char *)memchr(ext_copy + off, '\0', ext_str_sz - (size_t)off);
            if (nul) {
                size_t end_off = (size_t)(nul - ext_copy) + 1;
                if (end_off > names_start) {
                    names_start = end_off;
                }
            }
        }
    }
    if (names_start > ext_str_sz) {
        return true;
    }

    const uint8_t *name_offs = eo_base + (size_t)ext_str_cnt * 2;
    size_t name_idx = 0;

    if (ext_bool_cnt > 0) {
        t->ext_bools = (ExtIntCap *)calloc((size_t)ext_bool_cnt, sizeof(ExtIntCap));
        if (t->ext_bools) {
            for (int i = 0; i < ext_bool_cnt; i++, name_idx++) {
                int16_t noff = read_le16(name_offs + name_idx * 2);
                if (noff >= 0 && has_nul_within(ext_copy, names_start + (size_t)noff, ext_str_sz)) {
                    t->ext_bools[t->ext_bool_len].name = ext_copy + names_start + noff;
                    t->ext_bools[t->ext_bool_len].value = (eb_base[i] == 1) ? 1 : 0;
                    t->ext_bool_len++;
                }
            }
        } else {
            name_idx += (size_t)ext_bool_cnt;
        }
    }

    if (ext_num_cnt > 0) {
        t->ext_nums = (ExtIntCap *)calloc((size_t)ext_num_cnt, sizeof(ExtIntCap));
        if (t->ext_nums) {
            for (int i = 0; i < ext_num_cnt; i++, name_idx++) {
                int16_t noff = read_le16(name_offs + name_idx * 2);
                int32_t v = (num_width == 4)
                                ? read_le32(en_base + (size_t)i * 4)
                                : (int32_t)read_le16(en_base + (size_t)i * 2);
                if (noff >= 0 && has_nul_within(ext_copy, names_start + (size_t)noff, ext_str_sz)) {
                    t->ext_nums[t->ext_num_len].name = ext_copy + names_start + noff;
                    t->ext_nums[t->ext_num_len].value = (v >= 0) ? (int)v : -1;
                    t->ext_num_len++;
                }
            }
        } else {
            name_idx += (size_t)ext_num_cnt;
        }
    }

    if (ext_str_cnt > 0) {
        t->ext_strs = (ExtStrCap *)calloc((size_t)ext_str_cnt, sizeof(ExtStrCap));
        if (t->ext_strs) {
            for (int i = 0; i < ext_str_cnt; i++, name_idx++) {
                int16_t noff = read_le16(name_offs + name_idx * 2);
                int16_t voff = read_le16(eo_base + (size_t)i * 2);
                if (noff >= 0 && has_nul_within(ext_copy, names_start + (size_t)noff, ext_str_sz)) {
                    const char *val = NULL;
                    if (voff >= 0 && has_nul_within(ext_copy, (size_t)voff, ext_str_sz)) {
                        val = ext_copy + voff;
                    }
                    t->ext_strs[t->ext_str_len].name = ext_copy + names_start + noff;
                    t->ext_strs[t->ext_str_len].value = val;
                    t->ext_str_len++;
                }
            }
        }
    }

    return true;
}

static bool load_terminfo_file_at(const char *path, RulesHaskellTerm *t) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        return false;
    }
    if (fseek(f, 0, SEEK_END) != 0) {
        fclose(f);
        return false;
    }
    long sz = ftell(f);
    if (sz < 12 || sz > 262144) {
        fclose(f);
        return false;
    }
    rewind(f);
    uint8_t *buf = (uint8_t *)malloc((size_t)sz);
    if (!buf) {
        fclose(f);
        return false;
    }
    size_t nread = fread(buf, 1, (size_t)sz, f);
    fclose(f);
    if (nread != (size_t)sz) {
        free(buf);
        return false;
    }
    bool ok = parse_terminfo_bytes(buf, nread, t);
    free(buf);
    return ok;
}

static bool load_terminfo_from_dir(const char *dir, const char *term, RulesHaskellTerm *t) {
    if (!dir || !*dir) {
        return false;
    }
    unsigned char c = (unsigned char)term[0];
    char path[PATH_MAX];

    int n = snprintf(path, sizeof(path), "%s/%c/%s", dir, (char)c, term);
    if (n > 0 && (size_t)n < sizeof(path) && load_terminfo_file_at(path, t)) {
        return true;
    }

    n = snprintf(path, sizeof(path), "%s/%02x/%s", dir, (unsigned int)c, term);
    if (n > 0 && (size_t)n < sizeof(path) && load_terminfo_file_at(path, t)) {
        return true;
    }

    n = snprintf(path, sizeof(path), "%s/%02X/%s", dir, (unsigned int)c, term);
    if (n > 0 && (size_t)n < sizeof(path) && load_terminfo_file_at(path, t)) {
        return true;
    }

    return false;
}

static bool load_terminfo_from_disk(const char *term, RulesHaskellTerm *t) {
    if (!term || !*term || term[0] == '.' || strchr(term, '/') != NULL) {
        return false;
    }

    const char *env_ti = getenv("TERMINFO");
    if (env_ti && *env_ti) {
        if (load_terminfo_from_dir(env_ti, term, t)) {
            return true;
        }
    }

    const char *home = getenv("HOME");
    if (home && *home) {
        char home_ti[PATH_MAX];
        int n = snprintf(home_ti, sizeof(home_ti), "%s/.terminfo", home);
        if (n > 0 && (size_t)n < sizeof(home_ti) && load_terminfo_from_dir(home_ti, term, t)) {
            return true;
        }
    }

    const char *env_dirs = getenv("TERMINFO_DIRS");
    if (env_dirs && *env_dirs) {
        const char *p = env_dirs;
        while (true) {
            const char *colon = strchr(p, ':');
            size_t dlen = colon ? (size_t)(colon - p) : strlen(p);
            if (dlen == 0) {
                if (load_terminfo_from_dir("/usr/share/terminfo", term, t)) {
                    return true;
                }
            } else if (dlen < PATH_MAX) {
                char d[PATH_MAX];
                memcpy(d, p, dlen);
                d[dlen] = '\0';
                if (load_terminfo_from_dir(d, term, t)) {
                    return true;
                }
            }
            if (!colon) {
                break;
            }
            p = colon + 1;
        }
        return false;
    }

    static const char *const kDefaultDirs[] = {
        "/etc/terminfo",
        "/lib/terminfo",
        "/usr/share/terminfo",
        "/usr/local/share/terminfo",
    };
    for (size_t i = 0; i < sizeof(kDefaultDirs) / sizeof(kDefaultDirs[0]); i++) {
        if (load_terminfo_from_dir(kDefaultDirs[i], term, t)) {
            return true;
        }
    }
    return false;
}

static int find_name_index(const char *const *table, int count, const char *name) {
    for (int i = 0; i < count; i++) {
        if (strcmp(table[i], name) == 0) {
            return i;
        }
    }
    return -1;
}

static void set_std_bool(RulesHaskellTerm *t, const char *name, int8_t val) {
    int idx = find_name_index(kBoolNames, STD_BOOL_COUNT, name);
    if (idx >= 0) {
        t->bools[idx] = val;
    }
}

static void set_std_num(RulesHaskellTerm *t, const char *name, int32_t val) {
    int idx = find_name_index(kNumNames, STD_NUM_COUNT, name);
    if (idx >= 0) {
        t->nums[idx] = val;
    }
}

static void set_std_str(RulesHaskellTerm *t, const char *name, const char *val) {
    int idx = find_name_index(kStrNames, STD_STR_COUNT, name);
    if (idx >= 0) {
        t->strs[idx] = val;
    }
}

static bool has_prefix_ci(const char *s, const char *prefix) {
    while (*prefix) {
        if (tolower((unsigned char)*s) != tolower((unsigned char)*prefix)) {
            return false;
        }
        s++;
        prefix++;
    }
    return true;
}

static bool contains_substr_ci(const char *s, const char *needle) {
    size_t nlen = strlen(needle);
    if (nlen == 0) {
        return true;
    }
    for (; *s; s++) {
        if (has_prefix_ci(s, needle)) {
            return true;
        }
    }
    return false;
}

static bool populate_builtin_fallback(const char *term, RulesHaskellTerm *t) {
    if (strcmp(term, "dumb") == 0) {
        set_std_bool(t, "am", 1);
        set_std_num(t, "cols", 80);
        set_std_str(t, "bel", "\a");
        set_std_str(t, "cr", "\r");
        set_std_str(t, "cud1", "\n");
        set_std_str(t, "ind", "\n");
        return true;
    }

    static const char *const kAnsiPrefixes[] = {
        "xterm", "tmux", "screen", "rxvt", "alacritty", "kitty", "wezterm",
        "foot", "ghostty", "konsole", "gnome", "vte", "putty", "linux",
        "vt100", "vt102", "vt220", "ansi", "eterm", "cygwin", "st",
    };
    bool matched = false;
    for (size_t i = 0; i < sizeof(kAnsiPrefixes) / sizeof(kAnsiPrefixes[0]); i++) {
        const char *pfx = kAnsiPrefixes[i];
        if (strcmp(pfx, "st") == 0) {
            if (strcmp(term, "st") == 0 || has_prefix_ci(term, "st-")) {
                matched = true;
                break;
            }
        } else if (has_prefix_ci(term, pfx)) {
            matched = true;
            break;
        }
    }
    if (!matched) {
        return false;
    }

    bool is_256 = contains_substr_ci(term, "256color") ||
                  contains_substr_ci(term, "direct") ||
                  has_prefix_ci(term, "alacritty") ||
                  has_prefix_ci(term, "kitty") ||
                  has_prefix_ci(term, "wezterm") ||
                  has_prefix_ci(term, "foot") ||
                  has_prefix_ci(term, "ghostty");
    bool is_vt = has_prefix_ci(term, "vt100") ||
                 has_prefix_ci(term, "vt102") ||
                 has_prefix_ci(term, "vt220");

    set_std_bool(t, "am", 1);
    set_std_bool(t, "xenl", 1);
    set_std_bool(t, "km", 1);
    set_std_bool(t, "mir", 1);
    set_std_bool(t, "msgr", 1);
    if (!is_vt) {
        set_std_bool(t, "bce", 1);
    }

    set_std_num(t, "cols", 80);
    set_std_num(t, "it", 8);
    set_std_num(t, "lines", 24);
    if (!is_vt) {
        set_std_num(t, "colors", is_256 ? 256 : 8);
        set_std_num(t, "pairs", is_256 ? 65536 : 64);
    }

    /* Cursor movement & scrolling */
    set_std_str(t, "bel", "\a");
    set_std_str(t, "cr", "\r");
    set_std_str(t, "ht", "\t");
    set_std_str(t, "cbt", "\033[Z");
    set_std_str(t, "nel", "\r\n");
    set_std_str(t, "ind", "\n");
    set_std_str(t, "ri", "\033M");
    set_std_str(t, "home", "\033[H");
    set_std_str(t, "cup", "\033[%i%p1%d;%p2%dH");
    set_std_str(t, "hpa", "\033[%i%p1%dG");
    set_std_str(t, "vpa", "\033[%i%p1%dd");
    set_std_str(t, "csr", "\033[%i%p1%d;%p2%dr");
    set_std_str(t, "cuu1", "\033[A");
    set_std_str(t, "cud1", "\n");
    set_std_str(t, "cuf1", "\033[C");
    set_std_str(t, "cub1", "\b");
    set_std_str(t, "cuu", "\033[%p1%dA");
    set_std_str(t, "cud", "\033[%p1%dB");
    set_std_str(t, "cuf", "\033[%p1%dC");
    set_std_str(t, "cub", "\033[%p1%dD");
    set_std_str(t, "sc", "\0337");
    set_std_str(t, "rc", "\0338");
    set_std_str(t, "civis", "\033[?25l");
    set_std_str(t, "cnorm", "\033[?12l\033[?25h");
    set_std_str(t, "cvvis", "\033[?12;25h");
    set_std_str(t, "smcup", "\033[?1049h\033[22;0;0t");
    set_std_str(t, "rmcup", "\033[?1049l\033[23;0;0t");

    /* Clearing & editing */
    set_std_str(t, "clear", "\033[H\033[2J");
    set_std_str(t, "ed", "\033[J");
    set_std_str(t, "el", "\033[K");
    set_std_str(t, "el1", "\033[1K");
    set_std_str(t, "ech", "\033[%p1%dX");
    set_std_str(t, "dch1", "\033[P");
    set_std_str(t, "dch", "\033[%p1%dP");
    set_std_str(t, "ich1", "\033[@");
    set_std_str(t, "ich", "\033[%p1%d@");
    set_std_str(t, "dl1", "\033[M");
    set_std_str(t, "dl", "\033[%p1%dM");
    set_std_str(t, "il1", "\033[L");
    set_std_str(t, "il", "\033[%p1%dL");

    /* Text attributes & colors */
    set_std_str(t, "sgr0", "\033(B\033[m");
    set_std_str(t, "bold", "\033[1m");
    set_std_str(t, "dim", "\033[2m");
    set_std_str(t, "sitm", "\033[3m");
    set_std_str(t, "ritm", "\033[23m");
    set_std_str(t, "smul", "\033[4m");
    set_std_str(t, "rmul", "\033[24m");
    set_std_str(t, "blink", "\033[5m");
    set_std_str(t, "rev", "\033[7m");
    set_std_str(t, "smso", "\033[7m");
    set_std_str(t, "rmso", "\033[27m");
    set_std_str(t, "invis", "\033[8m");
    set_std_str(t, "flash", "\033[?5h$<100/>\033[?5l");
    if (!is_vt) {
        set_std_str(t, "op", "\033[39;49m");
        if (is_256) {
            set_std_str(
                t,
                "setaf",
                "\033[%?%p1%{8}%<%t3%p1%d%e%p1%{16}%<%t9%p1%{8}%-%d%e38;5;%p1%d%;m"
            );
            set_std_str(
                t,
                "setab",
                "\033[%?%p1%{8}%<%t4%p1%d%e%p1%{16}%<%t10%p1%{8}%-%d%e48;5;%p1%d%;m"
            );
        } else {
            set_std_str(t, "setaf", "\033[3%p1%dm");
            set_std_str(t, "setab", "\033[4%p1%dm");
        }
    }

    /* Keypad & input keys (matching xterm-256color for haskeline / terminfo) */
    set_std_str(t, "smkx", "\033[?1h\033=");
    set_std_str(t, "rmkx", "\033[?1l\033>");
    set_std_str(t, "kbs", "\177");
    set_std_str(t, "kdch1", "\033[3~");
    set_std_str(t, "kich1", "\033[2~");
    set_std_str(t, "kcuu1", "\033OA");
    set_std_str(t, "kcud1", "\033OB");
    set_std_str(t, "kcuf1", "\033OC");
    set_std_str(t, "kcub1", "\033OD");
    set_std_str(t, "khome", "\033OH");
    set_std_str(t, "kend", "\033OF");
    set_std_str(t, "kpp", "\033[5~");
    set_std_str(t, "knp", "\033[6~");
    set_std_str(t, "kent", "\033OM");
    set_std_str(t, "kcbt", "\033[Z");
    set_std_str(t, "kf1", "\033OP");
    set_std_str(t, "kf2", "\033OQ");
    set_std_str(t, "kf3", "\033OR");
    set_std_str(t, "kf4", "\033OS");
    set_std_str(t, "kf5", "\033[15~");
    set_std_str(t, "kf6", "\033[17~");
    set_std_str(t, "kf7", "\033[18~");
    set_std_str(t, "kf8", "\033[19~");
    set_std_str(t, "kf9", "\033[20~");
    set_std_str(t, "kf10", "\033[21~");
    set_std_str(t, "kf11", "\033[23~");
    set_std_str(t, "kf12", "\033[24~");

    return true;
}

static void refresh_winsize(RulesHaskellTerm *t) {
    if (!t) {
        return;
    }
    struct winsize ws;
    if (t->fildes >= 0 && ioctl(t->fildes, TIOCGWINSZ, &ws) == 0) {
        if (ws.ws_col > 0) {
            t->nums[0] = (int32_t)ws.ws_col; /* cols */
        }
        if (ws.ws_row > 0) {
            t->nums[2] = (int32_t)ws.ws_row; /* lines */
        }
    }
    const char *env_cols = getenv("COLUMNS");
    if (env_cols && *env_cols) {
        long c = strtol(env_cols, NULL, 10);
        if (c > 0 && c <= 32767) {
            t->nums[0] = (int32_t)c;
        }
    }
    const char *env_lines = getenv("LINES");
    if (env_lines && *env_lines) {
        long l = strtol(env_lines, NULL, 10);
        if (l > 0 && l <= 32767) {
            t->nums[2] = (int32_t)l;
        }
    }
}

/* ============================================================================
 * Exported X/Open Curses ABI (`@NCURSES6_TINFO_5.0.19991023`)
 * ============================================================================ */

int setupterm(const char *term, int fildes, int *errret) {
    if (!term) {
        term = getenv("TERM");
    }
    if (!term || !*term) {
        if (errret) {
            *errret = -1;
        }
        return -1;
    }

    RulesHaskellTerm *t = (RulesHaskellTerm *)malloc(sizeof(RulesHaskellTerm));
    if (!t) {
        if (errret) {
            *errret = -1;
        }
        return -1;
    }
    init_empty_term(t, fildes);

    if (!load_terminfo_from_disk(term, t)) {
        init_empty_term(t, fildes);
        if (!populate_builtin_fallback(term, t)) {
            free_term(t);
            if (errret) {
                *errret = 0;
            }
            return -1;
        }
    }

    refresh_winsize(t);
    g_cur_term = t;
    if (errret) {
        *errret = 1;
    }
    return 0;
}

void *set_curterm(void *nterm) {
    void *prev = (void *)g_cur_term;
    g_cur_term = (RulesHaskellTerm *)nterm;
    return prev;
}

int del_curterm(void *oterm) {
    if (!oterm) {
        return -1;
    }
    if ((void *)g_cur_term == oterm) {
        g_cur_term = NULL;
    }
    free_term((RulesHaskellTerm *)oterm);
    return 0;
}

int tigetflag(const char *capname) {
    if (!g_cur_term || !capname) {
        return -1;
    }
    int idx = find_name_index(kBoolNames, STD_BOOL_COUNT, capname);
    if (idx >= 0) {
        return (int)g_cur_term->bools[idx];
    }
    for (size_t i = 0; i < g_cur_term->ext_bool_len; i++) {
        if (strcmp(g_cur_term->ext_bools[i].name, capname) == 0) {
            return g_cur_term->ext_bools[i].value;
        }
    }
    return -1;
}

int tigetnum(const char *capname) {
    if (!g_cur_term || !capname) {
        return -2;
    }
    int idx = find_name_index(kNumNames, STD_NUM_COUNT, capname);
    if (idx >= 0) {
        if (idx == 0 || idx == 2) {
            refresh_winsize(g_cur_term);
        }
        return (int)g_cur_term->nums[idx];
    }
    for (size_t i = 0; i < g_cur_term->ext_num_len; i++) {
        if (strcmp(g_cur_term->ext_nums[i].name, capname) == 0) {
            return g_cur_term->ext_nums[i].value;
        }
    }
    return -2;
}

char *tigetstr(const char *capname) {
    if (!g_cur_term || !capname) {
        return (char *)-1;
    }
    int idx = find_name_index(kStrNames, STD_STR_COUNT, capname);
    if (idx >= 0) {
        return (char *)g_cur_term->strs[idx];
    }
    for (size_t i = 0; i < g_cur_term->ext_str_len; i++) {
        if (strcmp(g_cur_term->ext_strs[i].name, capname) == 0) {
            return (char *)g_cur_term->ext_strs[i].value;
        }
    }
    return (char *)-1;
}

typedef struct {
    char *buf;
    size_t len;
    size_t cap;
} TparmOut;

static void out_init(TparmOut *o, char *backing, size_t cap) {
    o->buf = backing;
    o->len = 0;
    o->cap = cap;
    o->buf[0] = '\0';
}

static void out_putc(TparmOut *o, char c) {
    if (o->len + 1 < o->cap) {
        o->buf[o->len++] = c;
        o->buf[o->len] = '\0';
    }
}

static void out_puts(TparmOut *o, const char *s) {
    if (!s) {
        return;
    }
    while (*s && o->len + 1 < o->cap) {
        o->buf[o->len++] = *s++;
    }
    o->buf[o->len] = '\0';
}

static int scan_needed_params(const char *str, bool *uses_explicit_p) {
    int max_p = 0;
    int seq_pops = 0;
    bool has_p = false;

    for (const char *p = str; *p; p++) {
        if (*p != '%') {
            continue;
        }
        p++;
        if (!*p) {
            break;
        }
        if (*p == '%') {
            continue;
        }
        if (*p == 'p' && p[1] >= '1' && p[1] <= '9') {
            has_p = true;
            int idx = (p[1] - '0');
            if (idx > max_p) {
                max_p = idx;
            }
            p++;
        } else if (*p == 'i') {
            if (max_p < 2) {
                max_p = 2;
            }
        } else if (*p == '\'') {
            if (p[1] && p[2] == '\'') {
                p += 2;
            }
        } else if (*p == '{') {
            while (p[1] && p[1] != '}') {
                p++;
            }
            if (p[1] == '}') {
                p++;
            }
        } else if (*p == 'P' || *p == 'g') {
            if (p[1]) {
                p++;
            }
        } else if (*p == ':' || *p == ' ' || *p == '+' || *p == '-' || *p == '#' || isdigit((unsigned char)*p) || *p == '.') {
            const char *q = p;
            if (*q == ':') {
                q++;
            }
            while (*q == ' ' || *q == '+' || *q == '-' || *q == '#' || *q == '0') {
                q++;
            }
            while (isdigit((unsigned char)*q)) {
                q++;
            }
            if (*q == '.') {
                q++;
                while (isdigit((unsigned char)*q)) {
                    q++;
                }
            }
            if (*q == 'd' || *q == 'o' || *q == 'x' || *q == 'X' || *q == 's') {
                seq_pops++;
                p = q;
            }
        } else if (*p == 'd' || *p == 'o' || *p == 'x' || *p == 'X' || *p == 's' || *p == 'c') {
            seq_pops++;
        }
    }

    *uses_explicit_p = has_p;
    if (!has_p && seq_pops > max_p) {
        max_p = seq_pops;
    }
    if (max_p > 9) {
        max_p = 9;
    }
    return max_p;
}

static const char *skip_branch_tokens(const char *p, bool stop_at_else) {
    int depth = 0;
    while (*p) {
        if (*p != '%') {
            p++;
            continue;
        }
        p++;
        if (!*p) {
            break;
        }
        if (*p == '?') {
            depth++;
        } else if (*p == ';') {
            if (depth == 0) {
                return p + 1;
            }
            depth--;
        } else if (*p == 'e' && depth == 0 && stop_at_else) {
            return p + 1;
        } else if (*p == '\'') {
            if (p[1] && p[2] == '\'') {
                p += 2;
            }
        } else if (*p == '{') {
            while (p[1] && p[1] != '}') {
                p++;
            }
            if (p[1] == '}') {
                p++;
            }
        } else if ((*p == 'p' || *p == 'P' || *p == 'g') && p[1]) {
            p++;
        }
        p++;
    }
    return p;
}

char *tparm(const char *str, ...) {
    if (!str || str == (const char *)-1) {
        return NULL;
    }

    static char s_ring[4][1024];
    static unsigned int s_ring_idx = 0;
    static long s_static_vars[26];

    char *backing = s_ring[s_ring_idx++ & 3U];
    TparmOut out;
    out_init(&out, backing, sizeof(s_ring[0]));

    long params[9] = {0};
    long dyn_vars[26] = {0};
    bool uses_explicit_p = false;
    int needed = scan_needed_params(str, &uses_explicit_p);

    va_list ap;
    va_start(ap, str);
    for (int i = 0; i < needed; i++) {
        params[i] = va_arg(ap, long);
    }
    va_end(ap);

    long stack[64] = {0};
    int sp = 0;
#define TPUSH(v) do { if (sp < 64) stack[sp++] = (long)(v); } while (0)
#define TPOP()   ((sp > 0) ? stack[--sp] : 0L)

    if (!uses_explicit_p && needed > 0) {
        for (int i = needed - 1; i >= 0; i--) {
            TPUSH(params[i]);
        }
    }

    const char *p = str;
    while (*p) {
        if (*p != '%') {
            out_putc(&out, *p++);
            continue;
        }
        p++;
        if (!*p) {
            break;
        }

        switch (*p) {
            case '%':
                out_putc(&out, '%');
                p++;
                break;

            case 'i':
                params[0]++;
                params[1]++;
                p++;
                break;

            case 'p':
                p++;
                if (*p >= '1' && *p <= '9') {
                    TPUSH(params[*p - '1']);
                    p++;
                }
                break;

            case 'P':
                p++;
                if (*p >= 'a' && *p <= 'z') {
                    dyn_vars[*p - 'a'] = TPOP();
                    p++;
                } else if (*p >= 'A' && *p <= 'Z') {
                    s_static_vars[*p - 'A'] = TPOP();
                    p++;
                }
                break;

            case 'g':
                p++;
                if (*p >= 'a' && *p <= 'z') {
                    TPUSH(dyn_vars[*p - 'a']);
                    p++;
                } else if (*p >= 'A' && *p <= 'Z') {
                    TPUSH(s_static_vars[*p - 'A']);
                    p++;
                }
                break;

            case '\'':
                p++;
                if (*p) {
                    TPUSH((unsigned char)*p);
                    p++;
                    if (*p == '\'') {
                        p++;
                    }
                }
                break;

            case '{': {
                p++;
                long val = strtol(p, (char **)&p, 10);
                if (*p == '}') {
                    p++;
                }
                TPUSH(val);
                break;
            }

            case 'l': {
                const char *s = (const char *)(intptr_t)TPOP();
                TPUSH(s ? (long)strlen(s) : 0L);
                p++;
                break;
            }

            case '+': { long b = TPOP(), a = TPOP(); TPUSH(a + b); p++; break; }
            case '-': { long b = TPOP(), a = TPOP(); TPUSH(a - b); p++; break; }
            case '*': { long b = TPOP(), a = TPOP(); TPUSH(a * b); p++; break; }
            case '/': { long b = TPOP(), a = TPOP(); TPUSH(b ? (a / b) : 0L); p++; break; }
            case 'm': { long b = TPOP(), a = TPOP(); TPUSH(b ? (a % b) : 0L); p++; break; }
            case '&': { long b = TPOP(), a = TPOP(); TPUSH(a & b); p++; break; }
            case '|': { long b = TPOP(), a = TPOP(); TPUSH(a | b); p++; break; }
            case '^': { long b = TPOP(), a = TPOP(); TPUSH(a ^ b); p++; break; }
            case '=': { long b = TPOP(), a = TPOP(); TPUSH(a == b ? 1 : 0); p++; break; }
            case '>': { long b = TPOP(), a = TPOP(); TPUSH(a > b ? 1 : 0); p++; break; }
            case '<': { long b = TPOP(), a = TPOP(); TPUSH(a < b ? 1 : 0); p++; break; }
            case 'A': { long b = TPOP(), a = TPOP(); TPUSH((a && b) ? 1 : 0); p++; break; }
            case 'O': { long b = TPOP(), a = TPOP(); TPUSH((a || b) ? 1 : 0); p++; break; }
            case '!': { long a = TPOP(); TPUSH(!a ? 1 : 0); p++; break; }
            case '~': { long a = TPOP(); TPUSH(~a); p++; break; }

            case '?':
                p++;
                break;

            case 't': {
                p++;
                long cond = TPOP();
                if (!cond) {
                    p = skip_branch_tokens(p, true);
                }
                break;
            }

            case 'e':
                p = skip_branch_tokens(p + 1, false);
                break;

            case ';':
                p++;
                break;

            case 'c': {
                long v = TPOP();
                char ch = (char)(v == 0 ? 0x80 : (v & 0xFF));
                out_putc(&out, ch);
                p++;
                break;
            }

            case 's': {
                const char *s = (const char *)(intptr_t)TPOP();
                out_puts(&out, s ? s : "");
                p++;
                break;
            }

            case 'd':
            case 'o':
            case 'x':
            case 'X': {
                char fmt[8];
                snprintf(fmt, sizeof(fmt), "%%l%c", *p);
                char num_buf[64];
                snprintf(num_buf, sizeof(num_buf), fmt, TPOP());
                out_puts(&out, num_buf);
                p++;
                break;
            }

            default: {
                /* Handle printf-style flags/width/precision: %[:]?[flags][width][.prec][doxXs] */
                const char *q = p;
                if (*q == ':') {
                    q++;
                }
                const char *spec_start = q;
                while (*q == ' ' || *q == '+' || *q == '-' || *q == '#' || *q == '0') {
                    q++;
                }
                while (isdigit((unsigned char)*q)) {
                    q++;
                }
                if (*q == '.') {
                    q++;
                    while (isdigit((unsigned char)*q)) {
                        q++;
                    }
                }
                size_t slen = (size_t)(q - spec_start);
                if ((*q == 'd' || *q == 'o' || *q == 'x' || *q == 'X' || *q == 's') && slen < 24) {
                    char fmt[32];
                    char tmp[256];
                    if (*q == 's') {
                        snprintf(fmt, sizeof(fmt), "%%%.*ss", (int)slen, spec_start);
                        const char *s = (const char *)(intptr_t)TPOP();
                        snprintf(tmp, sizeof(tmp), fmt, s ? s : "");
                    } else {
                        snprintf(fmt, sizeof(fmt), "%%%.*sl%c", (int)slen, spec_start, *q);
                        snprintf(tmp, sizeof(tmp), fmt, TPOP());
                    }
                    out_puts(&out, tmp);
                    p = q + 1;
                } else {
                    p++;
                }
                break;
            }
        }
    }

#undef TPUSH
#undef TPOP
    return out.buf;
}

int tputs(const char *str, int affcnt, int (*putc_fn)(int)) {
    (void)affcnt;
    if (!str || str == (const char *)-1 || !putc_fn) {
        return -1;
    }
    const char *p = str;
    while (*p) {
        if (p[0] == '$' && p[1] == '<') {
            const char *q = p + 2;
            while (*q && (isdigit((unsigned char)*q) || *q == '.' || *q == '*' || *q == '/')) {
                q++;
            }
            if (*q == '>') {
                p = q + 1;
                continue;
            }
        }
        putc_fn((unsigned char)*p++);
    }
    return 0;
}
