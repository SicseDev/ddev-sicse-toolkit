#!/usr/bin/env bats

# Unit tests for sicse/lib/deploy-lib.sh.
#
# These tests exercise the deploy library's logic without requiring a running
# DDEV environment, a real Drupal installation, or network access. External
# commands (drush, composer, theme-build, config-sync) are replaced by stub
# scripts placed in a temporary stubs directory that is prepended to PATH before
# each test.
#
# Prerequisites – install once via your system package manager:
#   Debian/Ubuntu:
#     sudo apt-get install bats bats-assert bats-file bats-support
#   macOS/Linux:
#     brew install bats-core bats-assert bats-file bats-support
#
# Run only this file:
#   bats ./tests/unit/deploy-lib.bats
#
# Run the full unit suite:
#   bats ./tests/unit/
#
# Verbose output (useful when debugging a failing test):
#   bats ./tests/unit/deploy-lib.bats \
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

  export UNIT_TMPDIR
  UNIT_TMPDIR="$(mktemp -d)"

  # Stub binaries directory – prepended to PATH so functions under test resolve
  # the stubs before any real system binary.
  export STUBS_DIR="${UNIT_TMPDIR}/stubs"
  mkdir -p "${STUBS_DIR}"
  export PATH="${STUBS_DIR}:${PATH}"

  # drush: for sql:dump calls, emit a valid MySQL dump header so that
  # verify_backup passes; all other invocations just exit 0. Use echo rather
  # than printf to avoid printf treating the leading "--" as an option flag.
  cat > "${STUBS_DIR}/drush" << 'STUB'
#!/usr/bin/env bash
if [[ "${*}" == *"sql:dump"* ]]; then
  echo '-- MySQL dump 10.13  Distrib 8.0.32'
  echo '-- Host: localhost'
fi
exit 0
STUB
  chmod +x "${STUBS_DIR}/drush"

  # composer: exits 0 silently.
  printf '#!/usr/bin/env bash\nexit 0\n' > "${STUBS_DIR}/composer"
  chmod +x "${STUBS_DIR}/composer"

  # ----------------------------------------------------------------------------
  # Stub DDEV command scripts
  # ----------------------------------------------------------------------------

  export COMMANDS_DIR="${UNIT_TMPDIR}/commands"
  mkdir -p "${COMMANDS_DIR}"

  printf '#!/usr/bin/env bash\nexit 0\n' > "${COMMANDS_DIR}/theme-build"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${COMMANDS_DIR}/config-sync"
  chmod +x "${COMMANDS_DIR}/theme-build" "${COMMANDS_DIR}/config-sync"

  # ----------------------------------------------------------------------------
  # WEB_ROOT and derived constants
  # ----------------------------------------------------------------------------

  # Source common.sh to obtain all shared helpers.
  # shellcheck source=../../sicse/lib/common.sh
  source "${DIR}/sicse/lib/common.sh"

  # Override WEB_ROOT, DB_SEED_FILE, DB_EXPORTS_DIR, COMMANDS_DIR, and
  # RSYNC_EXCLUDE_FILE after sourcing because common.sh hard-codes all of them.
  export WEB_ROOT="${UNIT_TMPDIR}/webroot"
  mkdir -p "${WEB_ROOT}"
  export DB_SEED_FILE="${WEB_ROOT}/database/seed/database.sql"
  export DB_EXPORTS_DIR="${WEB_ROOT}/database/exports"
  export COMMANDS_DIR="${UNIT_TMPDIR}/commands"
  export RSYNC_EXCLUDE_FILE="${UNIT_TMPDIR}/rsync-exclude.txt"
  touch "${RSYNC_EXCLUDE_FILE}"

  # Source deploy-lib.sh. The library sources common.sh from a hard-coded DDEV
  # mount path; override the source builtin to redirect that call to the
  # already-loaded copy and avoid a missing-path error.
  source() {
    if [[ "${1}" == "/mnt/ddev_config/sicse/lib/common.sh" ]]; then
      return 0
    fi
    builtin source "${@}"
  }
  # shellcheck source=../../sicse/lib/deploy-lib.sh
  builtin source "${DIR}/sicse/lib/deploy-lib.sh"
  unset -f source
}

teardown() {
  [[ -n "${UNIT_TMPDIR:-}" ]] && rm -rf "${UNIT_TMPDIR}"
}

# Helper: return the expected monthly log file path for a given environment.
# Usage: log_file_for acc
log_file_for() {
  local environment="${1}"
  echo "${WEB_ROOT}/deployment_logs/deploy_${environment}_$(date +%Y%m).log"
}

# ==============================================================================
# log_deployment
#
# Writes a timestamped entry to a monthly log file under
# ${WEB_ROOT}/deployment_logs/. Creates the directory on demand.
# ==============================================================================

@test "log_deployment: creates the deployment_logs directory" {
  log_deployment "acc" "test:action" "started"
  assert_dir_exist "${WEB_ROOT}/deployment_logs"
}

@test "log_deployment: creates a log file for the environment" {
  log_deployment "acc" "test:action" "started"
  assert_file_exist "$(log_file_for acc)"
}

@test "log_deployment: log entry contains the action and status" {
  log_deployment "prod" "composer:install" "success"
  local log_file
  log_file="$(log_file_for prod)"
  run grep "composer:install: success" "${log_file}"
  assert_success
}

@test "log_deployment: log entry starts with an ISO timestamp" {
  log_deployment "acc" "test:action" "started"
  local log_file
  log_file="$(log_file_for acc)"
  # Each line must start with [<ISO 8601 datetime>]
  run grep -E "^\[[0-9]{4}-" "${log_file}"
  assert_success
}

@test "log_deployment: multiple calls append to the same file" {
  log_deployment "acc" "step:one" "started"
  log_deployment "acc" "step:two" "success"
  local log_file
  log_file="$(log_file_for acc)"
  local line_count
  line_count=$(wc -l < "${log_file}")
  assert [ "${line_count}" -eq 2 ]
}

@test "log_deployment: different environments write to separate files" {
  log_deployment "acc"  "test:action" "started"
  log_deployment "prod" "test:action" "started"
  assert_file_exist "$(log_file_for acc)"
  assert_file_exist "$(log_file_for prod)"
  assert [ "$(log_file_for acc)" != "$(log_file_for prod)" ]
}

# ==============================================================================
# deploy_composer_install
#
# Runs composer install --no-dev and logs the result.
# ==============================================================================

@test "deploy_composer_install: returns 0 when composer succeeds" {
  run deploy_composer_install "acc"
  assert_success
}

@test "deploy_composer_install: output contains success message" {
  run deploy_composer_install "acc"
  assert_output --partial "Composer dependencies installed"
}

@test "deploy_composer_install: returns 1 when composer fails" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "${STUBS_DIR}/composer"

  run deploy_composer_install "acc"
  assert_failure
}

@test "deploy_composer_install: output contains failure message on error" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "${STUBS_DIR}/composer"

  run deploy_composer_install "acc"
  assert_output --partial "Failed to install Composer dependencies"
}

@test "deploy_composer_install: logs 'success' entry on success" {
  deploy_composer_install "acc"
  run grep "composer:install: success" "$(log_file_for acc)"
  assert_success
}

@test "deploy_composer_install: logs 'failed' entry on failure" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "${STUBS_DIR}/composer"

  # Capture exit code without aborting the test.
  deploy_composer_install "acc" || true
  run grep "composer:install: failed" "$(log_file_for acc)"
  assert_success
}

# ==============================================================================
# deploy_theme_build
#
# Delegates to ${COMMANDS_DIR}/theme-build and logs the result.
# ==============================================================================

@test "deploy_theme_build: returns 0 when theme-build succeeds" {
  run deploy_theme_build "acc"
  assert_success
}

@test "deploy_theme_build: output contains success message" {
  run deploy_theme_build "acc"
  assert_output --partial "Theme assets built"
}

@test "deploy_theme_build: returns 1 when theme-build fails" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "${COMMANDS_DIR}/theme-build"

  run deploy_theme_build "acc"
  assert_failure
}

@test "deploy_theme_build: output contains failure message on error" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "${COMMANDS_DIR}/theme-build"

  run deploy_theme_build "acc"
  assert_output --partial "Failed to build theme assets"
}

@test "deploy_theme_build: logs 'success' entry on success" {
  deploy_theme_build "acc"
  run grep "theme:build: success" "$(log_file_for acc)"
  assert_success
}

@test "deploy_theme_build: logs 'failed' entry on failure" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "${COMMANDS_DIR}/theme-build"

  deploy_theme_build "acc" || true
  run grep "theme:build: failed" "$(log_file_for acc)"
  assert_success
}

# ==============================================================================
# deploy_database_dump
#
# Runs drush sql:dump, verifies the output, and logs the result. On failure the
# destination file is removed so no partial dump is left.
# ==============================================================================

@test "deploy_database_dump: returns 0 when drush produces a valid dump" {
  local dest_file="${UNIT_TMPDIR}/backup.sql"
  run deploy_database_dump "acc" "prod" "${dest_file}"
  assert_success
}

@test "deploy_database_dump: creates the destination file on success" {
  local dest_file="${UNIT_TMPDIR}/backup.sql"
  deploy_database_dump "acc" "prod" "${dest_file}"
  assert_file_exist "${dest_file}"
}

@test "deploy_database_dump: creates parent directory if absent" {
  local dest_file="${UNIT_TMPDIR}/new_dir/backup.sql"
  deploy_database_dump "acc" "prod" "${dest_file}"
  assert_dir_exist "${UNIT_TMPDIR}/new_dir"
}

@test "deploy_database_dump: returns 1 when drush fails" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "${STUBS_DIR}/drush"

  local dest_file="${UNIT_TMPDIR}/backup.sql"
  run deploy_database_dump "acc" "prod" "${dest_file}"
  assert_failure
}

@test "deploy_database_dump: removes destination file when drush fails" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "${STUBS_DIR}/drush"

  local dest_file="${UNIT_TMPDIR}/backup.sql"
  run deploy_database_dump "acc" "prod" "${dest_file}"
  assert_file_not_exist "${dest_file}"
}

@test "deploy_database_dump: returns 1 when dump fails verification" {
  # drush succeeds but emits output that is not a valid SQL dump header.
  printf '#!/usr/bin/env bash\necho "not a valid dump"\nexit 0\n' \
    > "${STUBS_DIR}/drush"

  local dest_file="${UNIT_TMPDIR}/backup.sql"
  run deploy_database_dump "acc" "prod" "${dest_file}"
  assert_failure
}

@test "deploy_database_dump: removes file when backup verification fails" {
  printf '#!/usr/bin/env bash\necho "not a valid dump"\nexit 0\n' \
    > "${STUBS_DIR}/drush"

  local dest_file="${UNIT_TMPDIR}/backup.sql"
  run deploy_database_dump "acc" "prod" "${dest_file}"
  assert_file_not_exist "${dest_file}"
}

@test "deploy_database_dump: logs 'success' entry on success" {
  local dest_file="${UNIT_TMPDIR}/backup.sql"
  deploy_database_dump "acc" "prod" "${dest_file}"
  run grep "database:dump-prod: success" "$(log_file_for acc)"
  assert_success
}

@test "deploy_database_dump: logs 'failed' entry on failure" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "${STUBS_DIR}/drush"

  local dest_file="${UNIT_TMPDIR}/backup.sql"
  deploy_database_dump "acc" "prod" "${dest_file}" || true
  run grep "database:dump-prod: failed" "$(log_file_for acc)"
  assert_success
}

@test "deploy_database_dump: forwards extra arguments to drush sql:dump" {
  local args_file="${UNIT_TMPDIR}/drush_args"

  cat > "${STUBS_DIR}/drush" << 'STUB'
#!/usr/bin/env bash
if [[ "${*}" == *"sql:dump"* ]]; then
  echo "${*}" >> "${ARGS_FILE}"
  echo '-- MySQL dump 10.13  Distrib 8.0.32'
fi
exit 0
STUB
  # Inject the path via the environment so the heredoc can reference it.
  export ARGS_FILE="${args_file}"
  chmod +x "${STUBS_DIR}/drush"

  local dest_file="${UNIT_TMPDIR}/backup.sql"
  deploy_database_dump "acc" "prod" "${dest_file}" "--structure-tables-key=common"
  run grep -- "--structure-tables-key=common" "${args_file}"
  assert_success
}

# ==============================================================================
# deploy_maintenance_enable
#
# Runs drush maint:set 1 and drush cache:rebuild on the remote alias.
# ==============================================================================

@test "deploy_maintenance_enable: returns 0 when drush succeeds" {
  run deploy_maintenance_enable "acc"
  assert_success
}

@test "deploy_maintenance_enable: output contains success message" {
  run deploy_maintenance_enable "acc"
  assert_output --partial "Maintenance mode enabled"
}

@test "deploy_maintenance_enable: returns 1 when drush fails" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "${STUBS_DIR}/drush"

  run deploy_maintenance_enable "acc"
  assert_failure
}

@test "deploy_maintenance_enable: output contains failure message on error" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "${STUBS_DIR}/drush"

  run deploy_maintenance_enable "acc"
  assert_output --partial "Failed to enable maintenance mode"
}

@test "deploy_maintenance_enable: logs 'success' entry on success" {
  deploy_maintenance_enable "acc"
  run grep "maintenance:enable: success" "$(log_file_for acc)"
  assert_success
}

@test "deploy_maintenance_enable: logs 'failed' entry on failure" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "${STUBS_DIR}/drush"

  deploy_maintenance_enable "acc" || true
  run grep "maintenance:enable: failed" "$(log_file_for acc)"
  assert_success
}

# ==============================================================================
# deploy_maintenance_disable
#
# Runs drush maint:set 0, cache:rebuild, and cache:warm.
# ==============================================================================

@test "deploy_maintenance_disable: returns 0 when drush succeeds" {
  run deploy_maintenance_disable "acc"
  assert_success
}

@test "deploy_maintenance_disable: output contains success message" {
  run deploy_maintenance_disable "acc"
  assert_output --partial "Maintenance mode disabled"
}

@test "deploy_maintenance_disable: returns 1 when drush fails" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "${STUBS_DIR}/drush"

  run deploy_maintenance_disable "acc"
  assert_failure
}

@test "deploy_maintenance_disable: output contains failure message on error" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "${STUBS_DIR}/drush"

  run deploy_maintenance_disable "acc"
  assert_output --partial "Failed to disable maintenance mode"
}

@test "deploy_maintenance_disable: logs 'success' entry on success" {
  deploy_maintenance_disable "acc"
  run grep "maintenance:disable: success" "$(log_file_for acc)"
  assert_success
}

@test "deploy_maintenance_disable: logs 'failed' entry on failure" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "${STUBS_DIR}/drush"

  deploy_maintenance_disable "acc" || true
  run grep "maintenance:disable: failed" "$(log_file_for acc)"
  assert_success
}

# ==============================================================================
# deploy_code_sync
#
# Runs drush rsync to push code to the remote environment. Fails early if the
# rsync exclude file (RSYNC_EXCLUDE_FILE) does not exist.
# ==============================================================================

@test "deploy_code_sync: returns 0 when drush rsync succeeds" {
  run deploy_code_sync "acc"
  assert_success
}

@test "deploy_code_sync: output contains success message" {
  run deploy_code_sync "acc"
  assert_output --partial "Code synced"
}

@test "deploy_code_sync: returns 1 when drush rsync fails" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "${STUBS_DIR}/drush"

  run deploy_code_sync "acc"
  assert_failure
}

@test "deploy_code_sync: output contains failure message on error" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "${STUBS_DIR}/drush"

  run deploy_code_sync "acc"
  assert_output --partial "Failed to sync code"
}

@test "deploy_code_sync: returns 1 when exclude file is missing" {
  export RSYNC_EXCLUDE_FILE="${UNIT_TMPDIR}/nonexistent-exclude.txt"

  run deploy_code_sync "acc"
  assert_failure
}

@test "deploy_code_sync: output contains error when exclude file is missing" {
  export RSYNC_EXCLUDE_FILE="${UNIT_TMPDIR}/nonexistent-exclude.txt"

  run deploy_code_sync "acc"
  assert_output --partial "Rsync exclude file not found"
}

@test "deploy_code_sync: logs 'failed' entry when exclude file is missing" {
  export RSYNC_EXCLUDE_FILE="${UNIT_TMPDIR}/nonexistent-exclude.txt"

  deploy_code_sync "acc" || true
  run grep "code:sync: failed" "$(log_file_for acc)"
  assert_success
}

@test "deploy_code_sync: logs 'success' entry on success" {
  deploy_code_sync "acc"
  run grep "code:sync: success" "$(log_file_for acc)"
  assert_success
}

@test "deploy_code_sync: logs 'failed' entry when drush fails" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "${STUBS_DIR}/drush"

  deploy_code_sync "acc" || true
  run grep "code:sync: failed" "$(log_file_for acc)"
  assert_success
}

@test "deploy_code_sync: returns 1 when site:ssh chmod fails after rsync" {
  # rsync (first drush call) succeeds; site:ssh chmod (second call) fails.
  local counter_file="${UNIT_TMPDIR}/drush_call_count"
  echo "0" > "${counter_file}"

  cat > "${STUBS_DIR}/drush" << STUB
#!/usr/bin/env bash
count=\$(cat "${counter_file}")
count=\$(( count + 1 ))
echo "\${count}" > "${counter_file}"
# First call (rsync) succeeds; second call (site:ssh chmod) fails.
if [[ \${count} -ge 2 ]]; then
  exit 1
fi
exit 0
STUB
  chmod +x "${STUBS_DIR}/drush"

  run deploy_code_sync "acc"
  assert_failure
  assert_output --partial "Failed to sync code"
}

# ==============================================================================
# deploy_config_sync
#
# Delegates to ${COMMANDS_DIR}/config-sync @<environment>.
# ==============================================================================

@test "deploy_config_sync: returns 0 when config-sync succeeds" {
  run deploy_config_sync "acc"
  assert_success
}

@test "deploy_config_sync: output contains success message" {
  run deploy_config_sync "acc"
  assert_output --partial "Configuration synchronised"
}

@test "deploy_config_sync: logs 'success' entry on success" {
  deploy_config_sync "acc"
  run grep "config:sync: success" "$(log_file_for acc)"
  assert_success
}

@test "deploy_config_sync: returns 1 when config-sync fails" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "${COMMANDS_DIR}/config-sync"

  run deploy_config_sync "acc"
  assert_failure
}

@test "deploy_config_sync: output contains failure message on error" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "${COMMANDS_DIR}/config-sync"

  run deploy_config_sync "acc"
  assert_output --partial "Failed to sync configuration"
}

@test "deploy_config_sync: logs 'failed' entry on failure" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "${COMMANDS_DIR}/config-sync"

  deploy_config_sync "acc" || true
  run grep "config:sync: failed" "$(log_file_for acc)"
  assert_success
}

# ==============================================================================
# deploy_execute
#
# Orchestrates all standard deployment steps in order. The step offset parameter
# lets callers continue their own numbering sequence.
# ==============================================================================

@test "deploy_execute: returns 0 when all steps succeed" {
  run deploy_execute "acc" 1
  assert_success
}

@test "deploy_execute: defaults to step 1 when step_offset is omitted" {
  run deploy_execute "acc"
  assert_success
  assert_output --partial "Step 1"
}

@test "deploy_execute: logs 'completed' entry on success" {
  deploy_execute "acc" 1
  run grep "deployment: completed" "$(log_file_for acc)"
  assert_success
}

@test "deploy_execute: returns 1 when composer_install fails" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "${STUBS_DIR}/composer"

  run deploy_execute "acc" 1
  assert_failure
}

@test "deploy_execute: returns 1 when theme_build fails" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "${COMMANDS_DIR}/theme-build"

  run deploy_execute "acc" 1
  assert_failure
}

@test "deploy_execute: warns about maintenance mode when code sync fails" {
  # drush fails on rsync (code sync) but not on maint:set or cache:rebuild. Use
  # a counter-file trick: first two drush invocations succeed (maint:set,
  # cache:rebuild), subsequent ones fail (rsync).
  local counter_file="${UNIT_TMPDIR}/drush_call_count"
  echo "0" > "${counter_file}"

  cat > "${STUBS_DIR}/drush" << STUB
#!/usr/bin/env bash
count=\$(cat "${counter_file}")
count=\$(( count + 1 ))
echo "\${count}" > "${counter_file}"
# Fail starting from the 3rd call (rsync).
if [[ \${count} -ge 3 ]]; then
  exit 1
fi
exit 0
STUB
  chmod +x "${STUBS_DIR}/drush"

  run deploy_execute "acc" 1
  assert_failure
  assert_output --partial "maintenance mode"
}

@test "deploy_execute: uses the supplied step offset in output" {
  run deploy_execute "acc" 5
  assert_success
  # First printed step should start at 5.
  assert_output --partial "Step 5"
}

@test "deploy_execute: returns 1 when maintenance_enable fails" {
  # drush fails for all calls; maintenance-enable is the first drush step
  # (composer and theme-build do not use drush).
  printf '#!/usr/bin/env bash\nexit 1\n' > "${STUBS_DIR}/drush"

  run deploy_execute "acc" 1
  assert_failure
  # Maintenance was never activated, so no special residual warning.
  refute_output --partial "Maintenance mode will remain active"
}

@test "deploy_execute: warns about maintenance mode when config_sync fails" {
  # Maintenance mode is enabled and code is synced successfully, but config-sync
  # then fails. Maintenance mode is still active.
  printf '#!/usr/bin/env bash\nexit 1\n' > "${COMMANDS_DIR}/config-sync"

  run deploy_execute "acc" 1
  assert_failure
  assert_output --partial "maintenance mode"
}

@test "deploy_execute: returns 1 when maintenance_disable fails" {
  # The first four drush invocations succeed in order:
  #   1. maint:set 1   (deploy_maintenance_enable)
  #   2. cache:rebuild (deploy_maintenance_enable)
  #   3. rsync         (deploy_code_sync)
  #   4. site:ssh chmod (deploy_code_sync — makes drush executable)
  # Everything from the fifth call onward (maint:set 0 in
  # deploy_maintenance_disable) fails. A counter file tracks the invocation
  # count across drush subprocess calls.
  local counter_file="${UNIT_TMPDIR}/drush_call_count"
  echo "0" > "${counter_file}"

  cat > "${STUBS_DIR}/drush" << STUB
#!/usr/bin/env bash
count=\$(cat "${counter_file}")
count=\$(( count + 1 ))
echo "\${count}" > "${counter_file}"
if [[ \${count} -ge 5 ]]; then
  exit 1
fi
exit 0
STUB
  chmod +x "${STUBS_DIR}/drush"

  run deploy_execute "acc" 1
  assert_failure
}
