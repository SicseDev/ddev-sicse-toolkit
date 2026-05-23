#!/usr/bin/env bats

# Unit tests for sicse/lib/common.sh.
#
# These tests exercise the library's logic without requiring a running DDEV
# environment or a Drupal installation. They are deliberately fast and
# self-contained so that you can run them during day-to-day development.
#
# Prerequisites – install once via your system package manager:
#   Debian/Ubuntu:
#     sudo apt-get install bats bats-assert bats-file bats-support
#   macOS/Linux:
#     brew install bats-core bats-assert bats-file bats-support
#
# Run only this file:
#   bats ./tests/unit/common.bats
#
# Run the full unit suite:
#   bats ./tests/unit/
#
# Verbose output (useful when debugging a failing test):
#   bats ./tests/unit/common.bats \
#     --show-output-of-passing-tests \
#     --verbose-run \
#     --print-output-on-failure

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

  # Test fixtures shipped with the repository.
  export TESTDATA_DIR="${DIR}/tests/testdata"

  # A temporary directory used by tests that need to create files. Stub binaries
  # are placed under UNIT_TMPDIR/stubs and prepended to PATH so that functions
  # under test resolve them first.
  export UNIT_TMPDIR
  UNIT_TMPDIR="$(mktemp -d)"

  export STUBS_DIR="${UNIT_TMPDIR}/stubs"
  mkdir -p "${STUBS_DIR}"
  export PATH="${STUBS_DIR}:${PATH}"

  # Source the library under test. WEB_ROOT and COMMANDS_DIR are set to
  # DDEV-specific paths by the library, but none of the functions tested here
  # depend on those values, so they are safe to ignore in this context.
  # shellcheck source=../../sicse/lib/common.sh
  source "${DIR}/sicse/lib/common.sh"
}

teardown() {
  [[ -n "${UNIT_TMPDIR:-}" ]] && rm -rf "${UNIT_TMPDIR}"
}

# ==============================================================================
# Color constants
#
# common.sh must define five ANSI color variables so that every output helper
# can apply terminal colors. Verifying they are non-empty guards against
# accidental removal.
# ==============================================================================

@test "color constants: RED is defined and non-empty" {
  assert [ -n "${RED}" ]
}

@test "color constants: GREEN is defined and non-empty" {
  assert [ -n "${GREEN}" ]
}

@test "color constants: YELLOW is defined and non-empty" {
  assert [ -n "${YELLOW}" ]
}

@test "color constants: BLUE is defined and non-empty" {
  assert [ -n "${BLUE}" ]
}

@test "color constants: NC (reset) is defined and non-empty" {
  assert [ -n "${NC}" ]
}

# ==============================================================================
# Path constants
#
# DB_SEED_FILE and DB_EXPORTS_DIR are defined in common.sh and act as the single
# source of truth for database file locations. These tests guard against
# accidental path changes.
# ==============================================================================

@test "DB_SEED_FILE: points to database/seed/database.sql under WEB_ROOT" {
  assert_equal "${DB_SEED_FILE}" "/var/www/html/database/seed/database.sql"
}

@test "DB_EXPORTS_DIR: points to database/exports under WEB_ROOT" {
  assert_equal "${DB_EXPORTS_DIR}" "/var/www/html/database/exports"
}

# ==============================================================================
# verify_backup
#
# This function validates that a file exists, is non-empty, and begins with a
# recognisable mysqldump/mariadump header line.
# ==============================================================================

@test "verify_backup: fails when the file does not exist" {
  local missing_file="${UNIT_TMPDIR}/nonexistent.sql"
  run verify_backup "${missing_file}"
  assert_failure
  assert_output --partial "Backup file not found"
  assert_output --partial "${missing_file}"
}

@test "verify_backup: fails when the file is empty" {
  local empty_file="${UNIT_TMPDIR}/empty.sql"
  touch "${empty_file}"

  run verify_backup "${empty_file}"
  assert_failure
  assert_output --partial "Backup file is empty"
}

@test "verify_backup: fails for the repository invalid.sql fixture" {
  run verify_backup "${TESTDATA_DIR}/invalid.sql"
  assert_failure
  assert_output --partial "Backup file appears invalid"
}

@test "verify_backup: succeeds for the repository valid-mysql-dump fixture" {
  run verify_backup "${TESTDATA_DIR}/valid-mysql-dump.sql"
  assert_success
  assert_output --partial "Backup verified"
}

@test "verify_backup: success message contains the file path for a mysql dump" {
  run verify_backup "${TESTDATA_DIR}/valid-mysql-dump.sql"
  assert_output --partial "${TESTDATA_DIR}/valid-mysql-dump.sql"
}

@test "verify_backup: succeeds for the repository valid-mariadb-dump fixture" {
  run verify_backup "${TESTDATA_DIR}/valid-mariadb-dump.sql"
  assert_success
  assert_output --partial "Backup verified"
}

@test "verify_backup: success message contains the file path for a mariadb dump" {
  run verify_backup "${TESTDATA_DIR}/valid-mariadb-dump.sql"
  assert_output --partial "${TESTDATA_DIR}/valid-mariadb-dump.sql"
}

# ==============================================================================
# check_command
#
# This function verifies that a given binary is reachable via PATH and calls
# fail() (exit 1) when it is not.
# ==============================================================================

@test "check_command: succeeds when the command exists in PATH" {
  # bash is guaranteed to be present in any environment running tests.
  run check_command bash
  assert_success
}

@test "check_command: fails when the command is not in PATH" {
  run check_command _this_command_definitely_does_not_exist_
  assert_failure
}

@test "check_command: error message contains the missing command name" {
  run check_command _this_command_definitely_does_not_exist_
  assert_output --partial "_this_command_definitely_does_not_exist_"
  assert_output --partial "command not found"
}

# ==============================================================================
# check_composer / check_drush / check_npm
#
# These three thin wrappers delegate to check_command with a fixed binary name.
# The tests verify both the happy path (binary present in PATH as a stub) and
# the failure path (binary absent).
# ==============================================================================

@test "check_composer: succeeds when composer is in PATH" {
  printf '#!/usr/bin/env bash\nexit 0\n' > "${STUBS_DIR}/composer"
  chmod +x "${STUBS_DIR}/composer"

  run check_composer
  assert_success
}

@test "check_composer: fails when composer is not in PATH" {
  # Run in a subshell with a restricted PATH so that a system-installed
  # composer binary (common on CI runners) does not interfere.
  run bash -c "PATH='${STUBS_DIR}'; source '${DIR}/sicse/lib/common.sh'; check_composer"
  assert_failure
  assert_output --partial "composer"
}

@test "check_drush: succeeds when drush is in PATH" {
  printf '#!/usr/bin/env bash\nexit 0\n' > "${STUBS_DIR}/drush"
  chmod +x "${STUBS_DIR}/drush"

  run check_drush
  assert_success
}

@test "check_drush: fails when drush is not in PATH" {
  # Run in a subshell with a restricted PATH so that a system-installed
  # drush binary does not interfere.
  run bash -c "PATH='${STUBS_DIR}'; source '${DIR}/sicse/lib/common.sh'; check_drush"
  assert_failure
  assert_output --partial "drush"
}

@test "check_npm: succeeds when npm is in PATH" {
  printf '#!/usr/bin/env bash\nexit 0\n' > "${STUBS_DIR}/npm"
  chmod +x "${STUBS_DIR}/npm"

  run check_npm
  assert_success
}

@test "check_npm: fails when npm is not in PATH" {
  # Run in a subshell with a restricted PATH so that a system-installed
  # npm binary (common on CI runners) does not interfere.
  run bash -c "PATH='${STUBS_DIR}'; source '${DIR}/sicse/lib/common.sh'; check_npm"
  assert_failure
  assert_output --partial "npm"
}

# ==============================================================================
# check_ssh_agent
#
# Verifies SSH keys are available by running ssh-add -l. The tests stub ssh-add
# so that no real SSH agent is needed.
# ==============================================================================

@test "check_ssh_agent: fails when ssh-add reports no keys" {
  # Exit code 1 from ssh-add -l means no identities are present.
  printf '#!/usr/bin/env bash\nexit 1\n' > "${STUBS_DIR}/ssh-add"
  chmod +x "${STUBS_DIR}/ssh-add"

  run check_ssh_agent
  assert_failure
}

@test "check_ssh_agent: error message mentions ssh keys" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "${STUBS_DIR}/ssh-add"
  chmod +x "${STUBS_DIR}/ssh-add"

  run check_ssh_agent
  assert_output --partial "No SSH keys"
}

@test "check_ssh_agent: succeeds when ssh-add reports loaded keys" {
  printf '#!/usr/bin/env bash\nexit 0\n' > "${STUBS_DIR}/ssh-add"
  chmod +x "${STUBS_DIR}/ssh-add"

  run check_ssh_agent
  assert_success
}

# ==============================================================================
# check_drush_alias
#
# Verifies that a Drush site alias is configured by running
# drush site:alias @<alias>. Tests stub drush to avoid needing Drush or a real
# Drupal installation.
# ==============================================================================

@test "check_drush_alias: fails when alias is not configured" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "${STUBS_DIR}/drush"
  chmod +x "${STUBS_DIR}/drush"

  run check_drush_alias "prod"
  assert_failure
}

@test "check_drush_alias: error message contains the alias name" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "${STUBS_DIR}/drush"
  chmod +x "${STUBS_DIR}/drush"

  run check_drush_alias "prod"
  assert_output --partial "@prod"
}

@test "check_drush_alias: succeeds when drush site:alias exits 0" {
  printf '#!/usr/bin/env bash\nexit 0\n' > "${STUBS_DIR}/drush"
  chmod +x "${STUBS_DIR}/drush"

  run check_drush_alias "prod"
  assert_success
}

# ==============================================================================
# confirm
#
# Prompts for y/N confirmation and exits 0 (graceful abort) on anything other
# than y/Y. Tests use a helper script so that stdin can be piped to the function
# without fighting bats's run mechanics.
# ==============================================================================

setup_confirm_script() {
  local confirm_script="${UNIT_TMPDIR}/run_confirm.sh"
  cat > "${confirm_script}" << SCRIPT
#!/usr/bin/env bash
source '${DIR}/sicse/lib/common.sh'
confirm "Continue?"
echo "after_confirm"
SCRIPT
  chmod +x "${confirm_script}"
  echo "${confirm_script}"
}

@test "confirm: continues executing when 'y' is entered" {
  local script
  script="$(setup_confirm_script)"

  run bash -c "echo 'y' | '${script}'"
  assert_success
  assert_output --partial "after_confirm"
}

@test "confirm: continues executing when 'Y' is entered" {
  local script
  script="$(setup_confirm_script)"

  run bash -c "echo 'Y' | '${script}'"
  assert_success
  assert_output --partial "after_confirm"
}

@test "confirm: exits 0 without continuing when 'n' is entered" {
  local script
  script="$(setup_confirm_script)"

  run bash -c "echo 'n' | '${script}'"
  # exit 0 – graceful abort, not an error
  assert_success
  refute_output --partial "after_confirm"
}

@test "confirm: prints Aborted warning when declined" {
  local script
  script="$(setup_confirm_script)"

  run bash -c "echo 'n' | '${script}'"
  assert_output --partial "Aborted"
}

@test "confirm: exits 0 without continuing when 'N' is entered" {
  local script
  script="$(setup_confirm_script)"

  run bash -c "echo 'N' | '${script}'"
  assert_success
  refute_output --partial "after_confirm"
}

@test "confirm: exits 0 without continuing on empty input" {
  local script
  script="$(setup_confirm_script)"

  run bash -c "echo '' | '${script}'"
  assert_success
  refute_output --partial "after_confirm"
}

# ==============================================================================
# countdown
#
# Prints a per-second countdown from N to 1. Tests stub sleep so the test suite
# does not actually wait.
# ==============================================================================

@test "countdown: prints a countdown line for each second" {
  printf '#!/usr/bin/env bash\nexit 0\n' > "${STUBS_DIR}/sleep"
  chmod +x "${STUBS_DIR}/sleep"

  run countdown 2
  assert_success
  assert_output --partial "Starting in 2"
  assert_output --partial "Starting in 1"
}

@test "countdown: emits exactly one line per second" {
  printf '#!/usr/bin/env bash\nexit 0\n' > "${STUBS_DIR}/sleep"
  chmod +x "${STUBS_DIR}/sleep"

  run countdown 3
  assert_success
  assert_output --partial "Starting in 3"
  assert_output --partial "Starting in 2"
  assert_output --partial "Starting in 1"
}

@test "countdown: output contains Ctrl+C hint" {
  printf '#!/usr/bin/env bash\nexit 0\n' > "${STUBS_DIR}/sleep"
  chmod +x "${STUBS_DIR}/sleep"

  run countdown 1
  assert_output --partial "Ctrl+C"
}

# ==============================================================================
# fail
#
# This function prints an error message and exits with status 1. It is used
# throughout the command scripts to abort on unrecoverable errors.
# ==============================================================================

@test "fail: exits with status 1" {
  run fail "something broke"
  assert_failure
}

@test "fail: outputs the supplied message" {
  run fail "something broke"
  assert_output --partial "something broke"
}

@test "fail: prefixes the message with the error symbol" {
  run fail "something broke"
  # The output contains the X-mark prefix defined in common.sh.
  assert_output --partial "✗ Error:"
}

# ==============================================================================
# print_success
# ==============================================================================

@test "print_success: exits successfully" {
  run print_success "Everything worked"
  assert_success
}

@test "print_success: output contains the message" {
  run print_success "Everything worked"
  assert_output --partial "Everything worked"
}

@test "print_success: output contains a checkmark symbol" {
  run print_success "Everything worked"
  assert_output --partial "✓"
}

# ==============================================================================
# print_error
# ==============================================================================

@test "print_error: exits successfully (does not abort the script)" {
  # print_error prints but does NOT call exit – that is left to the caller.
  run print_error "Something went wrong"
  assert_success
}

@test "print_error: output contains the message" {
  run print_error "Something went wrong"
  assert_output --partial "Something went wrong"
}

@test "print_error: output contains the error symbol" {
  run print_error "Something went wrong"
  assert_output --partial "✗"
}

@test "print_error: output contains the Error: prefix" {
  run print_error "Something went wrong"
  assert_output --partial "Error:"
}

# ==============================================================================
# print_warning
# ==============================================================================

@test "print_warning: exits successfully (does not abort the script)" {
  run print_warning "Proceed with care"
  assert_success
}

@test "print_warning: output contains the warning symbol" {
  run print_warning "Proceed with care"
  assert_output --partial "⚠"
}

@test "print_warning: output contains the message" {
  run print_warning "Proceed with care"
  assert_output --partial "Proceed with care"
}

# ==============================================================================
# print_header
# ==============================================================================

@test "print_header: exits successfully" {
  run print_header "My Header"
  assert_success
}

@test "print_header: output wraps the title in === delimiters" {
  run print_header "My Header"
  assert_output --partial "==="
  assert_output --partial "My Header"
}

# ==============================================================================
# print_step
# ==============================================================================

@test "print_step: output contains the step number" {
  run print_step 3 "Installing dependencies"
  assert_output --partial "Step 3"
}

@test "print_step: output contains the step description" {
  run print_step 3 "Installing dependencies"
  assert_output --partial "Installing dependencies"
}

@test "print_step: output contains trailing ellipsis" {
  run print_step 3 "Installing dependencies"
  assert_output --partial "..."
}

# ==============================================================================
# print_info
# ==============================================================================

@test "print_info: exits successfully and contains the message" {
  run print_info "Just some information"
  assert_success
  assert_output --partial "Just some information"
}

# ==============================================================================
# print_detail
# ==============================================================================

@test "print_detail: output contains the label" {
  run print_detail "Location" "/var/www/html"
  assert_output --partial "Location"
}

@test "print_detail: output contains the value" {
  run print_detail "Location" "/var/www/html"
  assert_output --partial "/var/www/html"
}

@test "print_detail: label is separated from value by a colon" {
  run print_detail "Location" "/var/www/html"
  assert_output --partial "Location:"
}

# ==============================================================================
# print_tip
# ==============================================================================

@test "print_tip: output contains the TIP prefix" {
  run print_tip "Use --skip-db to skip the database import"
  assert_output --partial "TIP"
}

@test "print_tip: output contains the message" {
  run print_tip "Use --skip-db to skip the database import"
  assert_output --partial "Use --skip-db to skip the database import"
}

# ==============================================================================
# print_separator
# ==============================================================================

@test "print_separator: outputs a line of equals signs" {
  run print_separator
  assert_success
  assert_output --partial "========"
}

# ==============================================================================
# print_section
# ==============================================================================

@test "print_section: output contains separator lines" {
  run print_section "Deployment"
  assert_output --partial "========"
}

@test "print_section: output contains the section title" {
  run print_section "Deployment"
  assert_output --partial "Deployment"
}

# ==============================================================================
# print_footer
# ==============================================================================

@test "print_footer: output contains the title" {
  local start_time
  start_time=$(date +%s)

  run print_footer "Build complete" "${start_time}"
  assert_success
  assert_output --partial "Build complete"
}

@test "print_footer: output contains a duration in seconds" {
  local start_time
  start_time=$(date +%s)

  run print_footer "Build complete" "${start_time}"
  # The footer always ends with "Xs ===" where X is the elapsed seconds.
  assert_output --partial "s ==="
}

@test "print_footer: output contains === delimiters" {
  local start_time
  start_time=$(date +%s)

  run print_footer "Build complete" "${start_time}"
  assert_output --partial "==="
}

# ==============================================================================
# is_extension_enabled
#
# Pure predicate: returns 0 when drush pm:list reports the extension as enabled,
# 1 otherwise. Produces no output and never prompts. Used internally by
# check_enabled and by check_atd_module in translations-extract.
# ==============================================================================

@test "is_extension_enabled: returns 0 when a module is enabled" {
  printf '#!/usr/bin/env bash\necho "my_module"\n' > "${STUBS_DIR}/drush"
  chmod +x "${STUBS_DIR}/drush"

  run is_extension_enabled "Module" "my_module"
  assert_success
}

@test "is_extension_enabled: returns 1 when a module is not enabled" {
  printf '#!/usr/bin/env bash\nexit 0\n' > "${STUBS_DIR}/drush"
  chmod +x "${STUBS_DIR}/drush"

  run is_extension_enabled "Module" "my_module"
  assert_failure
}

@test "is_extension_enabled: returns 0 when a theme is enabled" {
  printf '#!/usr/bin/env bash\necho "my_theme"\n' > "${STUBS_DIR}/drush"
  chmod +x "${STUBS_DIR}/drush"

  run is_extension_enabled "Theme" "my_theme"
  assert_success
}

@test "is_extension_enabled: returns 1 when a theme is not enabled" {
  printf '#!/usr/bin/env bash\nexit 0\n' > "${STUBS_DIR}/drush"
  chmod +x "${STUBS_DIR}/drush"

  run is_extension_enabled "Theme" "my_theme"
  assert_failure
}

@test "is_extension_enabled: produces no output when enabled" {
  printf '#!/usr/bin/env bash\necho "my_module"\n' > "${STUBS_DIR}/drush"
  chmod +x "${STUBS_DIR}/drush"

  run is_extension_enabled "Module" "my_module"
  assert_output ""
}

@test "is_extension_enabled: produces no output when not enabled" {
  printf '#!/usr/bin/env bash\nexit 0\n' > "${STUBS_DIR}/drush"
  chmod +x "${STUBS_DIR}/drush"

  run is_extension_enabled "Module" "my_module"
  assert_output ""
}

# ==============================================================================
# check_enabled
#
# Checks whether a Drupal extension (module or theme) is enabled by querying
# drush pm:list. Prints a warning and prompts to continue when the extension is
# absent. Tests stub drush to avoid needing a real Drupal installation. When the
# extension is absent, check_enabled calls confirm(), which would block on
# stdin; override confirm() with a no-op so tests stay non-interactive.
# ==============================================================================

@test "check_enabled: warns when a module is not in the enabled list" {
  # Default drush stub exits 0 with no output → module not found.
  printf '#!/usr/bin/env bash\nexit 0\n' > "${STUBS_DIR}/drush"
  chmod +x "${STUBS_DIR}/drush"

  # No-op confirm() prevents blocking on stdin.
  # shellcheck disable=SC2317
  confirm() { return 0; }

  run check_enabled "Module" "my_module"
  assert_output --partial "does not appear to be enabled"
}

@test "check_enabled: warning message for a missing module includes the module type" {
  printf '#!/usr/bin/env bash\nexit 0\n' > "${STUBS_DIR}/drush"
  chmod +x "${STUBS_DIR}/drush"

  # shellcheck disable=SC2317
  confirm() { return 0; }

  run check_enabled "Module" "my_module"
  assert_output --partial "Module"
}

@test "check_enabled: warning message for a missing module includes the module name" {
  printf '#!/usr/bin/env bash\nexit 0\n' > "${STUBS_DIR}/drush"
  chmod +x "${STUBS_DIR}/drush"

  # shellcheck disable=SC2317
  confirm() { return 0; }

  run check_enabled "Module" "my_module"
  assert_output --partial "my_module"
}

@test "check_enabled: succeeds silently when a module is enabled" {
  printf '#!/usr/bin/env bash\necho "my_module"\n' > "${STUBS_DIR}/drush"
  chmod +x "${STUBS_DIR}/drush"

  run check_enabled "Module" "my_module"
  assert_success
  refute_output --partial "does not appear to be enabled"
}

@test "check_enabled: succeeds silently when a theme is enabled" {
  printf '#!/usr/bin/env bash\necho "my_theme"\n' > "${STUBS_DIR}/drush"
  chmod +x "${STUBS_DIR}/drush"

  run check_enabled "Theme" "my_theme"
  assert_success
  refute_output --partial "does not appear to be enabled"
}

@test "check_enabled: warns when a theme is not in the enabled list" {
  printf '#!/usr/bin/env bash\nexit 0\n' > "${STUBS_DIR}/drush"
  chmod +x "${STUBS_DIR}/drush"

  # shellcheck disable=SC2317
  confirm() { return 0; }

  run check_enabled "Theme" "my_theme"
  assert_output --partial "does not appear to be enabled"
}

@test "check_enabled: warning message for a missing theme includes the theme type" {
  printf '#!/usr/bin/env bash\nexit 0\n' > "${STUBS_DIR}/drush"
  chmod +x "${STUBS_DIR}/drush"

  # shellcheck disable=SC2317
  confirm() { return 0; }

  run check_enabled "Theme" "my_theme"
  assert_output --partial "Theme"
}

@test "check_enabled: warning message for a missing theme includes the theme name" {
  printf '#!/usr/bin/env bash\nexit 0\n' > "${STUBS_DIR}/drush"
  chmod +x "${STUBS_DIR}/drush"

  # shellcheck disable=SC2317
  confirm() { return 0; }

  run check_enabled "Theme" "my_theme"
  assert_output --partial "my_theme"
}
