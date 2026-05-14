#!/usr/bin/env bats

# Integration tests for the ddev-sicse-toolkit add-on.
#
# These tests create a temporary DDEV project, install the add-on from either a
# local directory or a published GitHub release, restart DDEV, and then verify
# that every command file is present, executable, and registered with DDEV.
#
# Prerequisites:
#   - A working DDEV installation
#   - bats-core, bats-assert, bats-file, bats-support
#
# Run (excluding the release test):
#   bats ./tests/integration/installation.bats --filter-tags '!release'
#
# Run all tests including the release test:
#   bats ./tests/integration/installation.bats
#
# Debug a failing test:
#   bats ./tests/integration/installation.bats \
#     --show-output-of-passing-tests \
#     --verbose-run \
#     --print-output-on-failure

# ---------------------------------------------------------------------------
# Setup and teardown
# ---------------------------------------------------------------------------

setup() {
  set -eu -o pipefail

  load '../helpers/setup'
  load_bats_libraries

  export GITHUB_REPO=SicseDev/ddev-sicse-toolkit

  export DIR
  DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"

  export PROJNAME="test-$(basename "${GITHUB_REPO}")"
  mkdir -p "${HOME}/tmp"
  export TESTDIR
  TESTDIR="$(mktemp -d "${HOME}/tmp/${PROJNAME}.XXXXXX")"

  export DDEV_NONINTERACTIVE=true
  export DDEV_NO_INSTRUMENTATION=true

  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1 || true
  cd "${TESTDIR}"
  run ddev config --project-name="${PROJNAME}" --project-tld=ddev.site
  assert_success
  run ddev start -y
  assert_success
}

teardown() {
  set -eu -o pipefail
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1

  # Persist TESTDIR when running inside GitHub Actions so that artifacts can be
  # uploaded. See:
  # https://github.com/ddev/github-action-add-on-test#preserving-artifacts
  if [ -n "${GITHUB_ENV:-}" ]; then
    [ -e "${GITHUB_ENV:-}" ] \
      && echo "TESTDIR=${HOME}/tmp/${PROJNAME}" >> "${GITHUB_ENV}"
  else
    [ "${TESTDIR}" != "" ] && rm -rf "${TESTDIR}"
  fi
}

# ---------------------------------------------------------------------------
# smoke_checks
#
# Invokes a small number of commands in the running DDEV web container to verify
# the full execution path after installation: that every command script can
# source common.sh from its real DDEV mount path
# (/mnt/ddev_config/sicse/lib/common.sh) and that the commands handle their
# error cases gracefully.
#
# Both commands are run against a bare DDEV project with no Drupal codebase, so
# they are expected to fail with a specific, predictable error. That is
# intentional: we are not testing Drupal features here but that the commands are
# reachable and fail gracefully.
#
# translations-extract (no arguments): fails immediately inside validate_inputs
# with "Specify either --module or --theme" before touching any external tool.
# This is entirely deterministic in a bare DDEV project and confirms that
# common.sh was sourced successfully.
#
# theme-build: fails predictably with an "Error:"-prefixed message regardless of
# whether npm is available inside the container. Without npm the check_command
# guard triggers; with npm the missing themes directory is detected. Both paths
# go through fail(), which always outputs "✗ Error:", confirming that common.sh
# was sourced and the command executed.
# ---------------------------------------------------------------------------

smoke_checks() {
  run ddev translations-extract
  assert_failure
  assert_output --partial "Specify either --module"

  run ddev theme-build
  assert_failure
  assert_output --partial "Error"
}

# ---------------------------------------------------------------------------
# health_checks
#
# Shared assertions run after every successful installation. Verifies that all
# support files, command files and DDEV registrations are in place, and that the
# commands are actually executable in the container.
# ---------------------------------------------------------------------------

health_checks() {
  # --- sicse add-on support files ---
  # These files must be present in the DDEV config directory so that all web
  # commands can source them at runtime and rsync has access to the exclude
  # list.
  assert_file_exist "${TESTDIR}/.ddev/sicse/lib/common.sh"
  assert_file_exist "${TESTDIR}/.ddev/sicse/lib/deploy-lib.sh"
  assert_file_exist "${TESTDIR}/.ddev/sicse/rsync-exclude.txt"

  # --- Web command files ---
  # Each entry here corresponds to a command that must be installed in the web
  # container so that developers can invoke it with "ddev <command>".
  local -a web_commands=(
    apply-updates
    config-sync
    database-export-prod
    database-import-dev
    deploy-acc
    deploy-prod
    hash-salt
    init-dev
    theme-build
    theme-update
    theme-watch
    translations-extract
  )

  for cmd in "${web_commands[@]}"; do
    assert_file_exist      "${TESTDIR}/.ddev/commands/web/${cmd}"
    assert_file_executable "${TESTDIR}/.ddev/commands/web/${cmd}"
  done

  # --- Host command files ---
  assert_file_exist      "${TESTDIR}/.ddev/commands/host/login"
  assert_file_executable "${TESTDIR}/.ddev/commands/host/login"

  # --- DDEV command registration ---
  # After the add-on is installed and DDEV is restarted, every web command must
  # appear in "ddev --help". This confirms that DDEV has parsed the
  # ## Description / ## Usage metadata in each command file.
  run ddev --help
  assert_success

  for cmd in "${web_commands[@]}"; do
    assert_output --partial "${cmd}"
  done

  smoke_checks
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "install from directory" {
  set -eu -o pipefail
  echo "# ddev add-on get ${DIR} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success
  health_checks
}

# bats test_tags=release
@test "install from release" {
  set -eu -o pipefail
  echo "# ddev add-on get ${GITHUB_REPO} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${GITHUB_REPO}"
  assert_success
  run ddev restart -y
  assert_success
  health_checks
}
