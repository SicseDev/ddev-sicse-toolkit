#!/usr/bin/env bats

# Unit tests for the translations-extract command.
#
# These tests exercise the pure-logic functions (parse_args, validate_inputs,
# verify_translation_file, ensure_translations_dir, move_pot_to_translation,
# create_htaccess, check_enabled, run_extraction, check_atd_module) without
# requiring a running DDEV environment or a Drupal installation. The command is
# sourced rather than executed so that individual functions are callable
# directly; the BASH_SOURCE guard in the script prevents main() from running
# when it is sourced.
#
# External commands (drush) are replaced by a stub binary placed in a temporary
# stubs directory that is prepended to PATH in setup().
#
# Prerequisites – install once via your system package manager:
#   Debian/Ubuntu:
#     sudo apt-get install bats bats-assert bats-file bats-support
#   macOS/Linux:
#     brew install bats-core bats-assert bats-file bats-support
#
# Run only this file:
#   bats ./tests/unit/translations-extract.bats
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

  # Use a temporary WEB_ROOT so that directory-existence checks inside
  # validate_inputs operate on paths we control.
  export WEB_ROOT="${UNIT_TMPDIR}/webroot"
  mkdir -p "${WEB_ROOT}"

  # Stub binaries directory – prepended to PATH so functions under test resolve
  # the stubs before any real system binary.
  export STUBS_DIR="${UNIT_TMPDIR}/stubs"
  mkdir -p "${STUBS_DIR}"
  export PATH="${STUBS_DIR}:${PATH}"

  # Default drush stub: no output, exits 0. Individual tests that require
  # specific drush behaviour overwrite this before calling run.
  printf '#!/usr/bin/env bash\nexit 0\n' > "${STUBS_DIR}/drush"
  chmod +x "${STUBS_DIR}/drush"

  # Source common.sh to make shared helpers (fail, print_warning, ...)
  # available in the current shell.
  # shellcheck source=../../sicse/lib/common.sh
  source "${DIR}/sicse/lib/common.sh"

  # Override WEB_ROOT after sourcing common.sh because common.sh hard-codes it
  # to /var/www/html.
  export WEB_ROOT="${UNIT_TMPDIR}/webroot"

  # Source the translations-extract script. The source builtin is temporarily
  # overridden to intercept the hard-coded DDEV mount path. The BASH_SOURCE
  # guard in the script prevents main() from executing when the file is sourced
  # rather than run directly.
  source() {
    if [[ "${1}" == "/mnt/ddev_config/sicse/lib/common.sh" ]]; then
      return 0
    fi
    builtin source "${@}"
  }
  # shellcheck source=../../commands/web/translations-extract
  builtin source "${DIR}/commands/web/translations-extract"
  unset -f source

  # The script registers a cleanup EXIT trap when sourced. Remove it so it does
  # not interfere with bats's own exit handling.
  trap - EXIT

  # Reset the global variables the script declares so each test starts
  # from known defaults.
  MODULE=""
  THEME=""
  LANGUAGE="nl"
  EXTENSION_TYPE=""
  EXTENSION_NAME=""
  EXTENSION_DIR=""
  TRANSLATION_FILE=""
}

teardown() {
  [[ -n "${UNIT_TMPDIR:-}" ]] && rm -rf "${UNIT_TMPDIR}"
}

# ==============================================================================
# parse_args
#
# Parses command-line arguments and populates the global variables MODULE,
# THEME, and LANGUAGE. Flags may be passed in either --flag=value or
# --flag value form, with single-letter shortcuts.
# ==============================================================================

@test "parse_args: --module=value sets MODULE" {
  parse_args --module=my_module
  assert_equal "${MODULE}" "my_module"
}

@test "parse_args: --module value sets MODULE" {
  parse_args --module my_module
  assert_equal "${MODULE}" "my_module"
}

@test "parse_args: -m value sets MODULE" {
  parse_args -m my_module
  assert_equal "${MODULE}" "my_module"
}

@test "parse_args: -m=value sets MODULE" {
  parse_args -m=my_module
  assert_equal "${MODULE}" "my_module"
}

@test "parse_args: --theme=value sets THEME" {
  parse_args --theme=my_theme
  assert_equal "${THEME}" "my_theme"
}

@test "parse_args: --theme value sets THEME" {
  parse_args --theme my_theme
  assert_equal "${THEME}" "my_theme"
}

@test "parse_args: -t value sets THEME" {
  parse_args -t my_theme
  assert_equal "${THEME}" "my_theme"
}

@test "parse_args: -t=value sets THEME" {
  parse_args -t=my_theme
  assert_equal "${THEME}" "my_theme"
}

@test "parse_args: --language=value sets LANGUAGE" {
  parse_args --language=de
  assert_equal "${LANGUAGE}" "de"
}

@test "parse_args: --language value sets LANGUAGE" {
  parse_args --language de
  assert_equal "${LANGUAGE}" "de"
}

@test "parse_args: -l value sets LANGUAGE" {
  parse_args -l de
  assert_equal "${LANGUAGE}" "de"
}

@test "parse_args: -l=value sets LANGUAGE" {
  parse_args -l=de
  assert_equal "${LANGUAGE}" "de"
}

@test "parse_args: no arguments leaves defaults intact" {
  parse_args
  assert_equal "${MODULE}"   ""
  assert_equal "${THEME}"    ""
  assert_equal "${LANGUAGE}" "nl"
}

@test "parse_args: unknown argument triggers a warning" {
  run parse_args --unknown-flag
  assert_output --partial "Unknown argument"
}

@test "parse_args: multiple flags with equals form are all applied" {
  parse_args --module=my_module --language=de
  assert_equal "${MODULE}"   "my_module"
  assert_equal "${LANGUAGE}" "de"
}

@test "parse_args: multiple flags with space-separated form are all applied" {
  parse_args --module my_module --language de
  assert_equal "${MODULE}"   "my_module"
  assert_equal "${LANGUAGE}" "de"
}

@test "parse_args: shorthand flags with space-separated values are all applied" {
  parse_args -m my_module -l de
  assert_equal "${MODULE}"   "my_module"
  assert_equal "${LANGUAGE}" "de"
}

@test "parse_args: shorthand flags with equals form are all applied" {
  parse_args -m=my_module -l=de
  assert_equal "${MODULE}"   "my_module"
  assert_equal "${LANGUAGE}" "de"
}

@test "parse_args: theme and language flags combined are all applied" {
  parse_args --theme=my_theme --language=de
  assert_equal "${THEME}"    "my_theme"
  assert_equal "${LANGUAGE}" "de"
}

# ==============================================================================
# validate_inputs
#
# Validates the parsed arguments, sets EXTENSION_TYPE/NAME/DIR/ARG and
# TRANSLATION_FILE, and calls fail() on invalid input.
# ==============================================================================

@test "validate_inputs: fails when neither module nor theme is provided" {
  MODULE=""
  THEME=""

  run validate_inputs
  assert_failure
  assert_output --partial "--module"
  assert_output --partial "--theme"
}

@test "validate_inputs: fails when both module and theme are provided" {
  MODULE="my_module"
  THEME="my_theme"

  run validate_inputs
  assert_failure
  assert_output --partial "Cannot specify both"
}

@test "validate_inputs: fails for a single-character language code" {
  MODULE="my_module"
  LANGUAGE="n"
  mkdir -p "${WEB_ROOT}/web/modules/custom/my_module"

  run validate_inputs
  assert_failure
  assert_output --partial "Invalid language code"
}

@test "validate_inputs: fails for a language code with lowercase country" {
  MODULE="my_module"
  LANGUAGE="en_us"
  mkdir -p "${WEB_ROOT}/web/modules/custom/my_module"

  run validate_inputs
  assert_failure
  assert_output --partial "Invalid language code"
}

@test "validate_inputs: fails for a numeric language code" {
  MODULE="my_module"
  LANGUAGE="42"
  mkdir -p "${WEB_ROOT}/web/modules/custom/my_module"

  run validate_inputs
  assert_failure
  assert_output --partial "Invalid language code"
}

@test "validate_inputs: fails when the module directory does not exist" {
  MODULE="nonexistent_module"
  LANGUAGE="nl"

  run validate_inputs
  assert_failure
  assert_output --partial "directory does not exist"
}

@test "validate_inputs: fails when the theme directory does not exist" {
  THEME="nonexistent_theme"
  LANGUAGE="nl"

  run validate_inputs
  assert_failure
  assert_output --partial "directory does not exist"
}

@test "validate_inputs: fails when the module .info.yml does not exist" {
  MODULE="my_module"
  LANGUAGE="nl"
  mkdir -p "${WEB_ROOT}/web/modules/custom/my_module"
  # Intentionally no .info.yml file.

  run validate_inputs
  assert_failure
  assert_output --partial "info file does not exist"
}

@test "validate_inputs: fails when the theme .info.yml does not exist" {
  THEME="my_theme"
  LANGUAGE="nl"
  mkdir -p "${WEB_ROOT}/web/themes/custom/my_theme"
  # Intentionally no .info.yml file.

  run validate_inputs
  assert_failure
  assert_output --partial "info file does not exist"
}

@test "validate_inputs: succeeds with a two-letter language code for a module" {
  MODULE="my_module"
  LANGUAGE="nl"
  mkdir -p "${WEB_ROOT}/web/modules/custom/my_module"
  touch "${WEB_ROOT}/web/modules/custom/my_module/my_module.info.yml"

  validate_inputs
  assert_equal "${EXTENSION_TYPE}" "Module"
}

@test "validate_inputs: succeeds with an ll_CC language code for a module" {
  MODULE="my_module"
  LANGUAGE="en_US"
  mkdir -p "${WEB_ROOT}/web/modules/custom/my_module"
  touch "${WEB_ROOT}/web/modules/custom/my_module/my_module.info.yml"

  validate_inputs
  assert_equal "${EXTENSION_TYPE}" "Module"
}

@test "validate_inputs: succeeds with a three-letter language code" {
  MODULE="my_module"
  LANGUAGE="zho"
  mkdir -p "${WEB_ROOT}/web/modules/custom/my_module"
  touch "${WEB_ROOT}/web/modules/custom/my_module/my_module.info.yml"

  validate_inputs
  assert_equal "${LANGUAGE}" "zho"
}

@test "validate_inputs: sets EXTENSION_TYPE to Module for --module" {
  MODULE="my_module"
  LANGUAGE="nl"
  mkdir -p "${WEB_ROOT}/web/modules/custom/my_module"
  touch "${WEB_ROOT}/web/modules/custom/my_module/my_module.info.yml"

  validate_inputs
  assert_equal "${EXTENSION_TYPE}" "Module"
}

@test "validate_inputs: sets EXTENSION_TYPE to Theme for --theme" {
  THEME="my_theme"
  LANGUAGE="nl"
  mkdir -p "${WEB_ROOT}/web/themes/custom/my_theme"
  touch "${WEB_ROOT}/web/themes/custom/my_theme/my_theme.info.yml"

  validate_inputs
  assert_equal "${EXTENSION_TYPE}" "Theme"
}

@test "validate_inputs: sets EXTENSION_NAME correctly for a module" {
  MODULE="my_module"
  LANGUAGE="nl"
  mkdir -p "${WEB_ROOT}/web/modules/custom/my_module"
  touch "${WEB_ROOT}/web/modules/custom/my_module/my_module.info.yml"

  validate_inputs
  assert_equal "${EXTENSION_NAME}" "my_module"
}

@test "validate_inputs: sets EXTENSION_NAME correctly for a theme" {
  THEME="my_theme"
  LANGUAGE="nl"
  mkdir -p "${WEB_ROOT}/web/themes/custom/my_theme"
  touch "${WEB_ROOT}/web/themes/custom/my_theme/my_theme.info.yml"

  validate_inputs
  assert_equal "${EXTENSION_NAME}" "my_theme"
}

@test "validate_inputs: sets EXTENSION_ARG correctly for a module" {
  MODULE="my_module"
  LANGUAGE="nl"
  mkdir -p "${WEB_ROOT}/web/modules/custom/my_module"
  touch "${WEB_ROOT}/web/modules/custom/my_module/my_module.info.yml"

  validate_inputs
  assert_equal "${EXTENSION_ARG}" "--modules=my_module"
}

@test "validate_inputs: sets EXTENSION_ARG correctly for a theme" {
  THEME="my_theme"
  LANGUAGE="nl"
  mkdir -p "${WEB_ROOT}/web/themes/custom/my_theme"
  touch "${WEB_ROOT}/web/themes/custom/my_theme/my_theme.info.yml"

  validate_inputs
  assert_equal "${EXTENSION_ARG}" "--themes=my_theme"
}

@test "validate_inputs: sets EXTENSION_DIR correctly for a module" {
  MODULE="my_module"
  LANGUAGE="nl"
  mkdir -p "${WEB_ROOT}/web/modules/custom/my_module"
  touch "${WEB_ROOT}/web/modules/custom/my_module/my_module.info.yml"

  validate_inputs
  assert_equal \
    "${EXTENSION_DIR}" \
    "${WEB_ROOT}/web/modules/custom/my_module"
}

@test "validate_inputs: sets EXTENSION_DIR correctly for a theme" {
  THEME="my_theme"
  LANGUAGE="nl"
  mkdir -p "${WEB_ROOT}/web/themes/custom/my_theme"
  touch "${WEB_ROOT}/web/themes/custom/my_theme/my_theme.info.yml"

  validate_inputs
  assert_equal \
    "${EXTENSION_DIR}" \
    "${WEB_ROOT}/web/themes/custom/my_theme"
}

@test "validate_inputs: TRANSLATION_FILE path includes language and module name" {
  MODULE="my_module"
  LANGUAGE="de"
  mkdir -p "${WEB_ROOT}/web/modules/custom/my_module"
  touch "${WEB_ROOT}/web/modules/custom/my_module/my_module.info.yml"

  validate_inputs

  assert_equal \
    "${TRANSLATION_FILE}" \
    "${WEB_ROOT}/web/modules/custom/my_module/translations/my_module.de.po"
}

@test "validate_inputs: TRANSLATION_FILE path includes language and theme name" {
  THEME="my_theme"
  LANGUAGE="de"
  mkdir -p "${WEB_ROOT}/web/themes/custom/my_theme"
  touch "${WEB_ROOT}/web/themes/custom/my_theme/my_theme.info.yml"

  validate_inputs

  assert_equal \
    "${TRANSLATION_FILE}" \
    "${WEB_ROOT}/web/themes/custom/my_theme/translations/my_theme.de.po"
}

# ==============================================================================
# verify_translation_file
#
# Checks that the generated .po file is non-empty and contains at least one
# msgid string.
# ==============================================================================

@test "verify_translation_file: succeeds when file contains msgid entries" {
  TRANSLATION_FILE="${UNIT_TMPDIR}/test.nl.po"
  printf 'msgid "Hello"\nmsgstr ""\n' > "${TRANSLATION_FILE}"
  EXTENSION_TYPE="Module"
  EXTENSION_NAME="test"

  run verify_translation_file
  assert_success
  assert_output --partial "Translation template extracted successfully"
}

@test "verify_translation_file: fails when the file is empty" {
  TRANSLATION_FILE="${UNIT_TMPDIR}/empty.nl.po"
  touch "${TRANSLATION_FILE}"
  EXTENSION_TYPE="Module"
  EXTENSION_NAME="test"

  run verify_translation_file
  assert_failure
  assert_output --partial "empty or invalid"
}

@test "verify_translation_file: fails when the file contains no msgid" {
  local no_msgid_file="${UNIT_TMPDIR}/no_msgid.nl.po"
  # The content must not accidentally contain the string "msgid", or
  # grep would find it and the validator would incorrectly succeed.
  echo '# This file has only a comment, no translations.' > "${no_msgid_file}"
  TRANSLATION_FILE="${no_msgid_file}"
  EXTENSION_TYPE="Module"
  EXTENSION_NAME="test"

  run verify_translation_file
  assert_failure
  assert_output --partial "empty or invalid"
}

# ==============================================================================
# ensure_translations_dir
#
# Creates the translations/ subdirectory inside the extension directory. It must
# be idempotent so that running it on an existing directory is always safe.
# ==============================================================================

@test "ensure_translations_dir: creates the translations subdirectory" {
  MODULE="my_module"
  LANGUAGE="nl"
  mkdir -p "${WEB_ROOT}/web/modules/custom/my_module"
  touch "${WEB_ROOT}/web/modules/custom/my_module/my_module.info.yml"

  validate_inputs
  ensure_translations_dir

  assert_dir_exist "${EXTENSION_DIR}/translations"
}

@test "ensure_translations_dir: is idempotent when directory already exists" {
  MODULE="my_module"
  LANGUAGE="nl"
  mkdir -p "${WEB_ROOT}/web/modules/custom/my_module/translations"
  touch "${WEB_ROOT}/web/modules/custom/my_module/my_module.info.yml"

  validate_inputs
  ensure_translations_dir

  assert_dir_exist "${EXTENSION_DIR}/translations"
}

# ==============================================================================
# move_pot_to_translation
#
# Moves the temporary POT_FILE produced by drush potx to the final
# TRANSLATION_FILE path.
# ==============================================================================

@test "move_pot_to_translation: moves the POT file to the translation path" {
  export POT_FILE="${UNIT_TMPDIR}/general.pot"
  TRANSLATION_FILE="${UNIT_TMPDIR}/my_module.nl.po"
  printf 'msgid "Hello"\nmsgstr ""\n' > "${POT_FILE}"

  move_pot_to_translation

  assert_file_not_exist "${POT_FILE}"
  assert_file_exist "${TRANSLATION_FILE}"
}

@test "move_pot_to_translation: destination contains the original content" {
  export POT_FILE="${UNIT_TMPDIR}/general.pot"
  TRANSLATION_FILE="${UNIT_TMPDIR}/my_module.nl.po"
  printf 'msgid "Hello"\nmsgstr ""\n' > "${POT_FILE}"

  move_pot_to_translation

  run grep "msgid" "${TRANSLATION_FILE}"
  assert_success
}

# ==============================================================================
# create_htaccess
#
# Creates a .htaccess file that denies all web access in the given directory. It
# prefers Drupal's FileSecurity helper via drush; if that is unavailable, it
# falls back to writing a minimal deny-all file. Skips creation when .htaccess
# already exists.
# ==============================================================================

@test "create_htaccess: reports success when .htaccess already exists" {
  local dir="${UNIT_TMPDIR}/translations"
  mkdir -p "${dir}"
  echo "existing" > "${dir}/.htaccess"

  run create_htaccess "${dir}"
  assert_success
  assert_output --partial "already exists"
}

@test "create_htaccess: creates a fallback .htaccess when drush does not output OK" {
  # The default drush stub exits 0 without printing 'OK', so the FileSecurity
  # path is skipped and the built-in fallback runs.
  local dir="${UNIT_TMPDIR}/translations"
  mkdir -p "${dir}"

  run create_htaccess "${dir}"
  assert_success
  assert_file_exist "${dir}/.htaccess"
}

@test "create_htaccess: uses Drupal FileSecurity when drush outputs OK" {
  # Stub drush to print 'OK' so the FileSecurity path is taken.
  printf '#!/usr/bin/env bash\necho "OK"\n' > "${STUBS_DIR}/drush"

  local dir="${UNIT_TMPDIR}/translations"
  mkdir -p "${dir}"

  run create_htaccess "${dir}"
  assert_success
  assert_output --partial "Drupal"
}


# ==============================================================================
# run_extraction
#
# Orchestrates the drush commands that produce the POT file: cache rebuild,
# locale update, and potx. Fails when potx exits non-zero or when the expected
# POT_FILE is not created afterwards.
# ===========================================================================

@test "run_extraction: fails when drush potx exits non-zero" {
  cat > "${STUBS_DIR}/drush" << 'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"potx"* ]]; then
  exit 1
fi
exit 0
STUB
  chmod +x "${STUBS_DIR}/drush"

  EXTENSION_ARG="--modules=my_module"

  run run_extraction
  assert_failure
  assert_output --partial "Failed to extract translations"
}

@test "run_extraction: fails when potx succeeds but does not create the POT file" {
  # Default drush stub exits 0 but never creates POT_FILE.
  export POT_FILE="${UNIT_TMPDIR}/no_such_file.pot"
  EXTENSION_ARG="--modules=my_module"

  run run_extraction
  assert_failure
  assert_output --partial "was not generated"
}

@test "run_extraction: succeeds when potx creates the POT file" {
  export POT_FILE="${UNIT_TMPDIR}/general.pot"

  # Stub drush to write the POT file when invoked with potx.
  cat > "${STUBS_DIR}/drush" << 'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"potx"* ]]; then
  printf 'msgid "Hello"\nmsgstr ""\n' > "${POT_FILE}"
fi
exit 0
STUB
  chmod +x "${STUBS_DIR}/drush"

  EXTENSION_ARG="--modules=my_module"

  run run_extraction
  assert_success
}

# ==============================================================================
# check_atd_module
#
# Checks whether the ATD module is installed (via is_extension_enabled) and
# warns when it is not, including instructions for manual configuration. When
# ATD is not installed, the function first checks whether the extension's
# .info.yml already contains the two required translation-discovery keys. If
# they are present the function exits silently with a success message; otherwise
# it prints instructions and waits for Enter. The "not installed, keys absent"
# path ends with a bare `read` call that would block on stdin; override read()
# with a no-op (visible in the run subshell) to prevent blocking.
# ==============================================================================

@test "check_atd_module: warns when the ATD module is not installed" {
  # Default drush stub produces no output → ATD not found.
  # No-op read() prevents blocking on the "Press Enter" prompt.
  # shellcheck disable=SC2317
  read() { return 0; }

  EXTENSION_NAME="my_module"
  EXTENSION_TYPE="Module"
  EXTENSION_DIR="${UNIT_TMPDIR}/modules/my_module"
  mkdir -p "${EXTENSION_DIR}"
  touch "${EXTENSION_DIR}/my_module.info.yml"

  run check_atd_module
  assert_output --partial "ATD"
}

@test "check_atd_module: succeeds silently when the ATD module is installed" {
  printf '#!/usr/bin/env bash\necho "atd"\n' > "${STUBS_DIR}/drush"

  EXTENSION_NAME="my_module"
  EXTENSION_TYPE="Module"
  EXTENSION_DIR="${UNIT_TMPDIR}/modules/my_module"
  mkdir -p "${EXTENSION_DIR}"
  touch "${EXTENSION_DIR}/my_module.info.yml"

  run check_atd_module
  assert_success
  refute_output --partial "not installed"
}

@test "check_atd_module: succeeds when translation keys already exist in .info.yml" {
  # Default drush stub returns no output → ATD not installed.
  EXTENSION_NAME="my_module"
  EXTENSION_TYPE="Module"
  EXTENSION_DIR="${UNIT_TMPDIR}/modules/my_module"
  mkdir -p "${EXTENSION_DIR}"
  cat > "${EXTENSION_DIR}/my_module.info.yml" << 'YAML'
name: My Module
type: module
interface translation project: my_module
interface translation server pattern: web/modules/custom/my_module/translations/%project.%language.po
YAML

  run check_atd_module
  assert_success
  assert_output --partial "already present"
  refute_output --partial "not installed"
}

@test "check_atd_module: warns when ATD absent and only one key exists in .info.yml" {
  # Default drush stub returns no output → ATD not installed.
  # No-op read() prevents blocking on the "Press Enter" prompt.
  # shellcheck disable=SC2317
  read() { return 0; }

  EXTENSION_NAME="my_module"
  EXTENSION_TYPE="Module"
  EXTENSION_DIR="${UNIT_TMPDIR}/modules/my_module"
  mkdir -p "${EXTENSION_DIR}"
  # Only one of the two required keys is present.
  cat > "${EXTENSION_DIR}/my_module.info.yml" << 'YAML'
name: My Module
type: module
interface translation project: my_module
YAML

  run check_atd_module
  assert_output --partial "ATD"
  refute_output --partial "already present"
}

@test "check_atd_module: instructions include interface translation project key" {
  # shellcheck disable=SC2317
  read() { return 0; }

  EXTENSION_NAME="my_module"
  EXTENSION_TYPE="Module"
  EXTENSION_DIR="${UNIT_TMPDIR}/modules/my_module"
  mkdir -p "${EXTENSION_DIR}"
  touch "${EXTENSION_DIR}/my_module.info.yml"

  run check_atd_module
  assert_output --partial "interface translation project"
}

@test "check_atd_module: instructions include interface translation server pattern key" {
  # shellcheck disable=SC2317
  read() { return 0; }

  EXTENSION_NAME="my_module"
  EXTENSION_TYPE="Module"
  EXTENSION_DIR="${UNIT_TMPDIR}/modules/my_module"
  mkdir -p "${EXTENSION_DIR}"
  touch "${EXTENSION_DIR}/my_module.info.yml"

  run check_atd_module
  assert_output --partial "interface translation server pattern"
}
