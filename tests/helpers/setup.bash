#!/usr/bin/env bash
# Shared test helper for all bats test files in this repository.
#
# Load from each test file's setup() with:
#   load '../helpers/setup'
#
# After loading, call load_bats_libraries() to make bats-assert,
# bats-file, and bats-support available to the test file.
#
# The helper libraries must be installed on the host system:
#   Debian/Ubuntu: sudo apt-get install bats-assert bats-file bats-support
#   macOS/Linux:   brew install bats-assert bats-file bats-support
#
# To override the search path, set BATS_LIB_PATH to the directory
# that contains the bats-support, bats-assert, and bats-file
# subdirectories before running bats.

# Load bats helper libraries from the system package manager or
# Homebrew. Searches the following locations in order:
#   1. $BATS_LIB_PATH  (override)
#   2. /usr/lib/bats   (Debian/Ubuntu apt)
#   3. /usr/local/lib  (Homebrew macOS Intel)
#   4. $(brew --prefix)/lib  (Homebrew Apple Silicon / Linux)
load_bats_libraries() {
  local lib_dir=""

  local -a candidates=(
    "${BATS_LIB_PATH:-}"
    "/usr/lib/bats"
    "/usr/local/lib"
  )

  if command -v brew &>/dev/null; then
    candidates+=("$(brew --prefix)/lib")
  fi

  local dir
  for dir in "${candidates[@]}"; do
    if [[ -n "${dir}" && -d "${dir}/bats-support" ]]; then
      lib_dir="${dir}"
      break
    fi
  done

  if [[ -z "${lib_dir}" ]]; then
    echo "ERROR: bats helper libraries not found." >&2
    echo "  Debian/Ubuntu:" \
      "sudo apt-get install bats-assert bats-file bats-support" >&2
    echo "  macOS/Linux:" \
      "brew install bats-assert bats-file bats-support" >&2
    return 1
  fi

  load "${lib_dir}/bats-support/load"
  load "${lib_dir}/bats-assert/load"
  load "${lib_dir}/bats-file/load"
}
