#!/usr/bin/env bats

# Unit tests for the theme-watch command.
#
# These tests exercise find_theme_with_watch(), has_watch_script(), and the
# orchestration logic inside main() without requiring a running DDEV environment
# or real npm packages. The script is sourced rather than executed so that
# individual functions are callable directly; the BASH_SOURCE guard in the
# script prevents main() from running when it is sourced.
#
# npm is replaced by a stub binary placed in a temporary stubs directory that is
# prepended to PATH in setup().
#
# Prerequisites – install once via your system package manager:
#   Debian/Ubuntu:
#     sudo apt-get install bats bats-assert bats-file bats-support
#   macOS/Linux:
#     brew install bats-core bats-assert bats-file bats-support
#
# Run only this file:
#   bats ./tests/unit/theme-watch.bats
#
# Run the full unit suite:
#   bats ./tests/unit/

# ---------------------------------------------------------------------------
# Setup and teardown
# ---------------------------------------------------------------------------

setup() {
  set -eu -o pipefail

  load '../helpers/setup'
  load_bats_libraries

  # Repository root is two directories above tests/unit/.
  export DIR
  DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"

  export UNIT_TMPDIR
  UNIT_TMPDIR="$(mktemp -d)"

  # Stub binaries directory – prepended to PATH so functions under test resolve
  # the stubs before any real system binary.
  export STUBS_DIR="${UNIT_TMPDIR}/stubs"
  mkdir -p "${STUBS_DIR}"
  export PATH="${STUBS_DIR}:${PATH}"

  # Default npm stub: no output, exits 0. Individual tests that need specific
  # npm behaviour overwrite this stub before calling run.
  printf '#!/usr/bin/env bash\nexit 0\n' > "${STUBS_DIR}/npm"
  chmod +x "${STUBS_DIR}/npm"

  export WEB_ROOT="${UNIT_TMPDIR}/webroot"
  mkdir -p "${WEB_ROOT}"

  # Source common.sh to make shared helpers available, then restore WEB_ROOT
  # because common.sh hard-codes it to /var/www/html.
  # shellcheck source=../../sicse/lib/common.sh
  source "${DIR}/sicse/lib/common.sh"
  export WEB_ROOT="${UNIT_TMPDIR}/webroot"

  # Source theme-watch. Override the source builtin to intercept the hard-coded
  # DDEV mount path. The BASH_SOURCE guard prevents main() from executing when
  # the file is sourced rather than run directly.
  source() {
    if [[ "${1}" == "/mnt/ddev_config/sicse/lib/common.sh" ]]; then
      return 0
    fi
    builtin source "${@}"
  }
  # shellcheck source=../../commands/web/theme-watch
  builtin source "${DIR}/commands/web/theme-watch"
  unset -f source
}

teardown() {
  [[ -n "${UNIT_TMPDIR:-}" ]] && rm -rf "${UNIT_TMPDIR}"
}

# ==============================================================================
# find_theme_with_watch
#
# Scans a themes directory and returns (via stdout) the name of the first theme
# whose package.json contains the string "watch". Returns exit code 1 when no
# matching theme is found.
# ==============================================================================

@test "find_theme_with_watch: returns the name of the first theme with a watch script" {
  local themes_dir="${UNIT_TMPDIR}/themes"
  mkdir -p "${themes_dir}/my_theme"
  printf '{"scripts":{"watch":"npm run watching"}}\n' \
    > "${themes_dir}/my_theme/package.json"

  run find_theme_with_watch "${themes_dir}"
  assert_success
  assert_output "my_theme"
}

@test "find_theme_with_watch: fails when no theme has a watch script" {
  local themes_dir="${UNIT_TMPDIR}/themes"
  mkdir -p "${themes_dir}/my_theme"
  printf '{"scripts":{"build":"npm run build"}}\n' \
    > "${themes_dir}/my_theme/package.json"

  run find_theme_with_watch "${themes_dir}"
  assert_failure
}

@test "find_theme_with_watch: skips themes that have no package.json" {
  local themes_dir="${UNIT_TMPDIR}/themes"
  mkdir -p "${themes_dir}/no_pkg"
  mkdir -p "${themes_dir}/has_watch"
  printf '{"scripts":{"watch":"..."}}\n' \
    > "${themes_dir}/has_watch/package.json"

  run find_theme_with_watch "${themes_dir}"
  assert_success
  assert_output "has_watch"
}

@test "find_theme_with_watch: skips non-directory entries in the themes dir" {
  local themes_dir="${UNIT_TMPDIR}/themes"
  mkdir -p "${themes_dir}"
  # A plain file should never be treated as a theme.
  echo "not a theme directory" > "${themes_dir}/some_file"

  mkdir -p "${themes_dir}/real_theme"
  printf '{"scripts":{"watch":"..."}}\n' \
    > "${themes_dir}/real_theme/package.json"

  run find_theme_with_watch "${themes_dir}"
  assert_success
  assert_output "real_theme"
}

@test "find_theme_with_watch: fails when the themes directory is empty" {
  local themes_dir="${UNIT_TMPDIR}/themes"
  mkdir -p "${themes_dir}"

  run find_theme_with_watch "${themes_dir}"
  assert_failure
}

@test "find_theme_with_watch: returns only the theme name, not the full path" {
  local themes_dir="${UNIT_TMPDIR}/themes"
  mkdir -p "${themes_dir}/my_theme"
  printf '{"scripts":{"watch":"..."}}\n' \
    > "${themes_dir}/my_theme/package.json"

  run find_theme_with_watch "${themes_dir}"
  assert_output "my_theme"
  # The output must not contain a directory separator.
  refute_output --partial "/"
}

# ==============================================================================
# has_watch_script
#
# Returns 0 when the package.json in the given directory declares a "watch" npm
# script, 1 otherwise (including when the file is absent).
# ==============================================================================

@test "has_watch_script: returns 0 when package.json declares a watch script" {
  local theme_dir="${UNIT_TMPDIR}/my_theme"
  mkdir -p "${theme_dir}"
  printf '{"scripts":{"watch":"..."}}\n' > "${theme_dir}/package.json"

  run has_watch_script "${theme_dir}"
  assert_success
}

@test "has_watch_script: returns 1 when package.json has no watch script" {
  local theme_dir="${UNIT_TMPDIR}/my_theme"
  mkdir -p "${theme_dir}"
  printf '{"scripts":{"build":"..."}}\n' > "${theme_dir}/package.json"

  run has_watch_script "${theme_dir}"
  assert_failure
}

@test "has_watch_script: returns 1 when package.json does not exist" {
  local theme_dir="${UNIT_TMPDIR}/my_theme"
  mkdir -p "${theme_dir}"

  run has_watch_script "${theme_dir}"
  assert_failure
}

# ==============================================================================
# main
#
# Resolves a theme by argument or by auto-discovery, validates the theme
# directory and its package.json, then executes npm run watch.
# ==============================================================================

@test "main: fails when the custom themes directory does not exist" {
  # WEB_ROOT exists, but the themes subdirectory does not.
  run main
  assert_failure
  assert_output --partial "does not exist"
}

@test "main: fails when the named theme directory does not exist" {
  mkdir -p "${WEB_ROOT}/web/themes/custom"

  run main "nonexistent_theme"
  assert_failure
  assert_output --partial "does not exist"
}

@test "main: fails when the named theme has no package.json" {
  local themes_dir="${WEB_ROOT}/web/themes/custom"
  mkdir -p "${themes_dir}/my_theme"
  # Intentionally no package.json.

  run main "my_theme"
  assert_failure
  assert_output --partial "package.json not found"
}

@test "main: fails when the named theme has no watch script" {
  local themes_dir="${WEB_ROOT}/web/themes/custom"
  mkdir -p "${themes_dir}/my_theme"
  printf '{"scripts":{"build":"..."}}\n' \
    > "${themes_dir}/my_theme/package.json"

  run main "my_theme"
  assert_failure
  assert_output --partial "'watch' script not found"
}

@test "main: succeeds and runs npm run watch for a named theme" {
  local themes_dir="${WEB_ROOT}/web/themes/custom"
  mkdir -p "${themes_dir}/my_theme"
  printf '{"scripts":{"watch":"..."}}\n' \
    > "${themes_dir}/my_theme/package.json"

  run main "my_theme"
  assert_success
  assert_output --partial "Watching theme: my_theme"
}

@test "main: outputs the theme directory in the detail line" {
  local themes_dir="${WEB_ROOT}/web/themes/custom"
  mkdir -p "${themes_dir}/my_theme"
  printf '{"scripts":{"watch":"..."}}\n' \
    > "${themes_dir}/my_theme/package.json"

  run main "my_theme"
  assert_success
  assert_output --partial "Directory"
  assert_output --partial "my_theme"
}

@test "main: outputs the stop-watching hint" {
  local themes_dir="${WEB_ROOT}/web/themes/custom"
  mkdir -p "${themes_dir}/my_theme"
  printf '{"scripts":{"watch":"..."}}\n' \
    > "${themes_dir}/my_theme/package.json"

  run main "my_theme"
  assert_success
  assert_output --partial "Ctrl+C"
}

@test "main: auto-discovers and watches the first theme with a watch script" {
  local themes_dir="${WEB_ROOT}/web/themes/custom"
  mkdir -p "${themes_dir}/my_theme"
  printf '{"scripts":{"watch":"..."}}\n' \
    > "${themes_dir}/my_theme/package.json"

  run main
  assert_success
  assert_output --partial "Watching theme: my_theme"
}

@test "main: prints a warning naming the auto-discovered theme" {
  local themes_dir="${WEB_ROOT}/web/themes/custom"
  mkdir -p "${themes_dir}/my_theme"
  printf '{"scripts":{"watch":"..."}}\n' \
    > "${themes_dir}/my_theme/package.json"

  run main
  assert_success
  assert_output --partial "No theme specified, using: my_theme"
}

@test "main: does not print the auto-discovery warning for a named theme" {
  local themes_dir="${WEB_ROOT}/web/themes/custom"
  mkdir -p "${themes_dir}/my_theme"
  printf '{"scripts":{"watch":"..."}}\n' \
    > "${themes_dir}/my_theme/package.json"

  run main "my_theme"
  assert_success
  refute_output --partial "No theme specified"
}

@test "main: fails when no theme with a watch script is found during auto-discovery" {
  local themes_dir="${WEB_ROOT}/web/themes/custom"
  mkdir -p "${themes_dir}/my_theme"
  printf '{"scripts":{"build":"..."}}\n' \
    > "${themes_dir}/my_theme/package.json"

  run main
  assert_failure
  assert_output --partial "No theme with a 'watch' script found"
}
