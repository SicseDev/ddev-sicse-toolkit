#!/usr/bin/env bats

# Unit tests for the theme-build command.
#
# These tests exercise build_theme() and the core orchestration logic inside
# main() without requiring a running DDEV environment or real npm packages. The
# script is sourced rather than executed so that individual functions are
# callable directly; the BASH_SOURCE guard in the script prevents main() from
# running when it is sourced.
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
#   bats ./tests/unit/theme-build.bats
#
# Run the full unit suite:
#   bats ./tests/unit/

# ------------------------------------------------------------------------------
# Setup and teardown
# ------------------------------------------------------------------------------

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

  # Source theme-build. Override the source builtin to intercept the hard-coded
  # DDEV mount path. The BASH_SOURCE guard prevents main() from executing when
  # the file is sourced rather than run directly.
  source() {
    if [[ "${1}" == "/mnt/ddev_config/sicse/lib/common.sh" ]]; then
      return 0
    fi
    builtin source "${@}"
  }
  # shellcheck source=../../commands/web/theme-build
  builtin source "${DIR}/commands/web/theme-build"
  unset -f source
}

teardown() {
  [[ -n "${UNIT_TMPDIR:-}" ]] && rm -rf "${UNIT_TMPDIR}"
}

# ==============================================================================
# build_theme
#
# Builds a single theme by running npm install and npm run build inside the
# theme directory. Skips silently when package.json is absent. Collects failures
# without aborting, so all themes are always attempted.
# ==============================================================================

@test "build_theme: skips the theme when package.json is absent" {
  local theme_dir="${UNIT_TMPDIR}/themes/no_pkg"
  mkdir -p "${theme_dir}"

  run build_theme "${theme_dir}"
  assert_success
  assert_output --partial "Skipping"
}

@test "build_theme: succeeds when npm install and npm run build both succeed" {
  local theme_dir="${UNIT_TMPDIR}/themes/my_theme"
  mkdir -p "${theme_dir}"
  echo '{}' > "${theme_dir}/package.json"

  run build_theme "${theme_dir}"
  assert_success
  assert_output --partial "Finished building my_theme"
}

@test "build_theme: fails when npm install exits non-zero" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "${STUBS_DIR}/npm"

  local theme_dir="${UNIT_TMPDIR}/themes/my_theme"
  mkdir -p "${theme_dir}"
  echo '{}' > "${theme_dir}/package.json"

  run build_theme "${theme_dir}"
  assert_failure
  assert_output --partial "npm install failed"
}

@test "build_theme: fails when npm run build exits non-zero" {
  # npm install succeeds; npm run build fails.
  cat > "${STUBS_DIR}/npm" << 'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"run build"* ]]; then
  exit 1
fi
exit 0
STUB
  chmod +x "${STUBS_DIR}/npm"

  local theme_dir="${UNIT_TMPDIR}/themes/my_theme"
  mkdir -p "${theme_dir}"
  echo '{}' > "${theme_dir}/package.json"

  run build_theme "${theme_dir}"
  assert_failure
  assert_output --partial "npm run build failed"
}

@test "build_theme: outputs the theme name in the section header" {
  local theme_dir="${UNIT_TMPDIR}/themes/my_theme"
  mkdir -p "${theme_dir}"
  echo '{}' > "${theme_dir}/package.json"

  run build_theme "${theme_dir}"
  assert_output --partial "my_theme"
}

# ==============================================================================
# main
#
# Orchestrates discovery and building of all or a specific theme. The primary
# specification is that a failing theme must not abort the build of the
# remaining themes, and all failures are reported together at the end.
# ==============================================================================

@test "main: fails when the custom themes directory does not exist" {
  # WEB_ROOT exists, but the themes subdirectory does not.
  run main
  assert_failure
  assert_output --partial "does not exist"
}

@test "main: fails when a named theme directory does not exist" {
  mkdir -p "${WEB_ROOT}/web/themes/custom"

  run main "nonexistent_theme"
  assert_failure
  assert_output --partial "does not exist"
}

@test "main: fails when there are no themes in the themes directory" {
  mkdir -p "${WEB_ROOT}/web/themes/custom"
  # No subdirectories → no themes.

  run main
  assert_failure
  assert_output --partial "No themes found"
}

@test "main: succeeds and reports success when all themes build successfully" {
  local themes_dir="${WEB_ROOT}/web/themes/custom/my_theme"
  mkdir -p "${themes_dir}"
  echo '{}' > "${themes_dir}/package.json"

  run main
  assert_success
  assert_output --partial "All themes built successfully"
}

@test "main: continues building remaining themes when one fails" {
  local themes_dir="${WEB_ROOT}/web/themes/custom"
  mkdir -p "${themes_dir}/theme_a" "${themes_dir}/theme_b"
  echo '{}' > "${themes_dir}/theme_a/package.json"
  echo '{}' > "${themes_dir}/theme_b/package.json"

  # Fail only when npm is invoked inside theme_a's directory.
  cat > "${STUBS_DIR}/npm" << 'STUB'
#!/usr/bin/env bash
if [[ "$PWD" == *"theme_a"* ]]; then
  exit 1
fi
exit 0
STUB
  chmod +x "${STUBS_DIR}/npm"

  run main
  assert_failure
  # theme_b must still have been processed despite theme_a failing.
  assert_output --partial "theme_a"
  assert_output --partial "theme_b"
}

@test "main: reports all failed theme names at the end" {
  local themes_dir="${WEB_ROOT}/web/themes/custom"
  mkdir -p "${themes_dir}/theme_a" "${themes_dir}/theme_b"
  echo '{}' > "${themes_dir}/theme_a/package.json"
  echo '{}' > "${themes_dir}/theme_b/package.json"

  # All npm invocations fail.
  printf '#!/usr/bin/env bash\nexit 1\n' > "${STUBS_DIR}/npm"

  run main
  assert_failure
  assert_output --partial "theme_a"
  assert_output --partial "theme_b"
  assert_output --partial "Failed to build 2 theme(s)"
}

@test "main: builds only the named theme when one is specified" {
  local themes_dir="${WEB_ROOT}/web/themes/custom"
  mkdir -p "${themes_dir}/theme_a" "${themes_dir}/theme_b"
  echo '{}' > "${themes_dir}/theme_a/package.json"
  echo '{}' > "${themes_dir}/theme_b/package.json"

  run main "theme_a"
  assert_success
  assert_output --partial "theme_a"
  refute_output --partial "theme_b"
}
