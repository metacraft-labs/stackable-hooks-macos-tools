/*
 * arch(1) — a monitorable drop-in for the SIP-protected /usr/bin/arch.
 *
 * WHY THIS EXISTS
 *
 * Every other tool in this bundle is a non-Apple build of the same program.
 * `arch` has no such build: GNU coreutils' `arch` only prints the machine
 * type, while Apple's also RUNS a chosen slice of a universal binary. Dropping
 * the GNU one in would not merely lose an observation, it would answer WRONG —
 * `nix` probes Rosetta availability with
 *
 *     arch -arch x86_64 /usr/bin/true
 *
 * and a print-only `arch` exits 0 without running anything, which tells nix
 * that x86_64 execution works on a machine where it may not.
 *
 * So this is a reimplementation, and the reason it is worth having is
 * coverage: `/usr/bin/arch` is SIP-protected, so exec'ing it strips
 * DYLD_INSERT_LIBRARIES and everything it launches is invisible to the
 * monitor. That probe launches a program. A monitorable `arch` keeps the
 * subtree.
 *
 * WHAT IT DOES NOT DO
 *
 * Apple's `arch` has a second mode — with `-c`, `-d` or `-e` and no explicit
 * architecture it edits per-application architecture preferences in plists
 * ("arch: Can't find any plists for ..."). That is Apple-internal behaviour we
 * cannot reproduce faithfully, so we do not try: any invocation this program
 * does not fully understand is handed to the real /usr/bin/arch unchanged.
 * Losing the injection for that one exec is the correct trade — a wrong answer
 * is worse than an unobserved one, and the monitor records the loss.
 */

#include <errno.h>
#include <mach/machine.h>
#include <mach-o/arch.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/utsname.h>
#include <unistd.h>

extern char **environ;

#define REAL_ARCH "/usr/bin/arch"

struct arch_name {
  const char *name;
  cpu_type_t type;
};

/*
 * The names accepted by `-arch`. Kept to the architectures macOS can actually
 * execute today plus the two 32-bit spellings, which still appear in older
 * build scripts and must at least resolve to the right cpu type rather than
 * being reported as unknown.
 */
static const struct arch_name kArchNames[] = {
    {"arm64", CPU_TYPE_ARM64},
    {"arm64e", CPU_TYPE_ARM64},
    {"arm64_32", CPU_TYPE_ARM64_32},
    {"arm", CPU_TYPE_ARM},
    {"x86_64", CPU_TYPE_X86_64},
    {"x86_64h", CPU_TYPE_X86_64},
    {"i386", CPU_TYPE_X86},
};

static cpu_type_t lookup_arch(const char *name) {
  for (size_t i = 0; i < sizeof(kArchNames) / sizeof(kArchNames[0]); i++) {
    if (strcmp(kArchNames[i].name, name) == 0) {
      return kArchNames[i].type;
    }
  }
  return 0;
}

/* Hand the original invocation to Apple's binary, unchanged. */
static int delegate(char **argv) {
  execv(REAL_ARCH, argv);
  fprintf(stderr, "arch: cannot exec %s: %s\n", REAL_ARCH, strerror(errno));
  return 1;
}

/*
 * The no-argument answer comes from the same API Apple's own arch uses
 * (<mach-o/arch.h>), not from a reimplementation of the string. That matters
 * because the value is quirky — on Intel hardware `arch` historically answers
 * `i386` rather than `x86_64` — and sharing the source of truth reproduces the
 * quirk by construction instead of by a table we would have to keep right on
 * hardware we do not have.
 */
static int print_local_arch(void) {
  const NXArchInfo *info = NXGetLocalArchInfo();
  if (info != NULL) {
    /*
     * By CPU TYPE, not by the local arch info's own name. The local info
     * carries the SUBTYPE — on Apple Silicon it answers `arm64e`, where
     * Apple's arch(1) answers `arm64`. Re-querying by cpu type with
     * CPU_SUBTYPE_MULTIPLE drops the subtype and reproduces Apple's answer.
     * (Measured: local.name=arm64e, by-cputype name=arm64.)
     */
    const NXArchInfo *base =
        NXGetArchInfoFromCpuType(info->cputype, CPU_SUBTYPE_MULTIPLE);
    const char *name = (base != NULL && base->name != NULL) ? base->name
                                                            : info->name;
    if (name != NULL) {
      printf("%s\n", name);
      return 0;
    }
  }
  struct utsname u;
  if (uname(&u) == 0) {
    printf("%s\n", u.machine);
    return 0;
  }
  fprintf(stderr, "arch: cannot determine the local architecture\n");
  return 1;
}

static void env_unset(const char *name) {
  unsetenv(name);
}

static int env_set(const char *assignment) {
  char *copy = strdup(assignment);
  if (copy == NULL) {
    return -1;
  }
  char *eq = strchr(copy, '=');
  if (eq == NULL) {
    free(copy);
    return -1;
  }
  *eq = '\0';
  int rc = setenv(copy, eq + 1, 1);
  free(copy);
  return rc;
}

int main(int argc, char **argv) {
  if (argc == 1) {
    return print_local_arch();
  }

  cpu_type_t prefs[16];
  size_t pref_count = 0;
  int clear_env = 0;
  /* Collected, then applied only once we know this is exec mode. */
  const char *env_sets[64];
  size_t env_set_count = 0;
  const char *env_unsets[64];
  size_t env_unset_count = 0;

  int i = 1;
  for (; i < argc; i++) {
    const char *arg = argv[i];

    if (arg[0] != '-' || strcmp(arg, "-") == 0) {
      break; /* the program to run */
    }

    if (strcmp(arg, "-h") == 0) {
      /* Apple prints a usage block and exits 0. Delegate so the text stays
       * whatever Apple's is, rather than drifting from it here. */
      return delegate(argv);
    }

    if (strcmp(arg, "-c") == 0) {
      clear_env = 1;
      continue;
    }

    if (strcmp(arg, "-d") == 0 || strcmp(arg, "-e") == 0) {
      int is_set = (arg[1] == 'e');
      if (i + 1 >= argc) {
        return delegate(argv);
      }
      const char *value = argv[++i];
      if (is_set) {
        if (env_set_count >= sizeof(env_sets) / sizeof(env_sets[0])) {
          return delegate(argv);
        }
        env_sets[env_set_count++] = value;
      } else {
        if (env_unset_count >= sizeof(env_unsets) / sizeof(env_unsets[0])) {
          return delegate(argv);
        }
        env_unsets[env_unset_count++] = value;
      }
      continue;
    }

    if (strcmp(arg, "-arch") == 0) {
      if (i + 1 >= argc) {
        return delegate(argv);
      }
      const char *name = argv[++i];
      cpu_type_t type = lookup_arch(name);
      if (type == 0) {
        fprintf(stderr, "arch: Unknown architecture: %s\n", name);
        return 1;
      }
      if (pref_count < sizeof(prefs) / sizeof(prefs[0])) {
        prefs[pref_count++] = type;
      }
      continue;
    }

    if (strcmp(arg, "-32") == 0 || strcmp(arg, "-64") == 0) {
      /* The 32/64-bit variant of the HOST architecture. */
      const NXArchInfo *info = NXGetLocalArchInfo();
      cpu_type_t host = (info != NULL) ? info->cputype : CPU_TYPE_ANY;
      cpu_type_t want;
      if (strcmp(arg, "-64") == 0) {
        want = (host & CPU_ARCH_ABI64) ? host : (host | CPU_ARCH_ABI64);
      } else {
        want = host & ~CPU_ARCH_ABI64;
      }
      if (pref_count < sizeof(prefs) / sizeof(prefs[0])) {
        prefs[pref_count++] = want;
      }
      continue;
    }

    /* Legacy `-x86_64` / `-arm64` spelling. */
    cpu_type_t legacy = lookup_arch(arg + 1);
    if (legacy != 0) {
      if (pref_count < sizeof(prefs) / sizeof(prefs[0])) {
        prefs[pref_count++] = legacy;
      }
      continue;
    }

    /* Anything else is a flag we do not model — Apple's binary owns it. */
    return delegate(argv);
  }

  if (i >= argc) {
    /*
     * Flags but no program: this is the per-application plist mode
     * (`arch -e FOO=bar` answers "Can't find any plists for ..."). Not ours.
     */
    return delegate(argv);
  }

  if (pref_count == 0) {
    /*
     * A program with env flags but no architecture is still plist territory in
     * Apple's implementation; only an explicit architecture makes it exec mode.
     */
    if (clear_env || env_set_count > 0 || env_unset_count > 0) {
      return delegate(argv);
    }
    const NXArchInfo *info = NXGetLocalArchInfo();
    if (info == NULL) {
      return delegate(argv);
    }
    prefs[pref_count++] = info->cputype;
  }

  if (clear_env) {
    environ = NULL;
    static char *empty[] = {NULL};
    environ = empty;
  }
  for (size_t u = 0; u < env_unset_count; u++) {
    env_unset(env_unsets[u]);
  }
  for (size_t s = 0; s < env_set_count; s++) {
    if (env_set(env_sets[s]) != 0) {
      fprintf(stderr, "arch: bad environment assignment: %s\n", env_sets[s]);
      return 1;
    }
  }

  posix_spawnattr_t attr;
  if (posix_spawnattr_init(&attr) != 0) {
    return delegate(argv);
  }

  size_t copied = 0;
  if (posix_spawnattr_setbinpref_np(&attr, pref_count, prefs, &copied) != 0 ||
      copied != pref_count) {
    posix_spawnattr_destroy(&attr);
    return delegate(argv);
  }

  /*
   * POSIX_SPAWN_SETEXEC replaces THIS process image rather than forking, which
   * is what makes the drop-in transparent: the caller's wait() sees the target
   * program, not a wrapper, and the monitor follows one process rather than
   * inventing a generation.
   */
  if (posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETEXEC) != 0) {
    posix_spawnattr_destroy(&attr);
    return delegate(argv);
  }

  char **child_argv = &argv[i];

  /*
   * Apple reports an unrunnable target as `arch: <prog> isn't executable`
   * with exit 1 — the same message whether it is missing or merely not +x —
   * so the check happens before the spawn rather than being derived from
   * posix_spawnp's errno afterwards. A bare name is left to posix_spawnp's
   * PATH search, which Apple's arch also performs.
   */
  if (strchr(child_argv[0], '/') != NULL &&
      access(child_argv[0], X_OK) != 0) {
    fprintf(stderr, "arch: %s isn't executable\n", child_argv[0]);
    return 1;
  }

  pid_t pid;
  int rc = posix_spawnp(&pid, child_argv[0], NULL, &attr, child_argv, environ);
  posix_spawnattr_destroy(&attr);

  /*
   * SETEXEC only returns on failure. A PATH search that found nothing lands
   * here, and Apple words that the same way as the pre-check above.
   */
  if (rc == ENOENT || rc == EACCES || rc == ENOEXEC) {
    fprintf(stderr, "arch: %s isn't executable\n", child_argv[0]);
    return 1;
  }
  fprintf(stderr, "arch: posix_spawnp: %s: %s\n", child_argv[0], strerror(rc));
  return 1;
}
