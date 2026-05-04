#!/usr/bin/env bash
# Shared utilities for DDEV commands.
#
# Source at the top of each web-container command:
#   source /mnt/ddev_config/sicse/lib/common.sh
#
# Source at the top of each host command:
#   source "${DDEV_APPROOT}/.ddev/sicse/lib/common.sh"

# --- Color codes ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Path constants ---
WEB_ROOT="/var/www/html"
COMMANDS_DIR="/mnt/ddev_config/commands/web"
# Seed database: committed to version control, imported by ddev init-dev.
DB_SEED_FILE="${WEB_ROOT}/database/seed/database.sql"
# Exports directory: deployment safety-net dumps, not committed.
DB_EXPORTS_DIR="${WEB_ROOT}/database/exports"

# --- Output helpers ---

# Print the opening banner: === Title ===
print_header() {
  echo -e "${BLUE}=== ${1} ===${NC}"
}

# Print a numbered step line: Step N: Description...
print_step() {
  echo -e "${BLUE}Step ${1}: ${2}...${NC}"
}

# Print a green success tick: ✓ Message
print_success() {
  echo -e "${GREEN}✓ ${1}${NC}"
}

# Print a yellow warning: ⚠ Message
print_warning() {
  echo -e "${YELLOW}⚠ ${1}${NC}"
}

# Print a red error line (no exit): ✗ Error: Message
print_error() {
  echo -e "${RED}✗ Error: ${1}${NC}"
}

# Print a red error line and exit 1: ✗ Error: Message
fail() {
  echo -e "${RED}✗ Error: ${1}${NC}"
  exit 1
}

# Print a plain blue informational message.
print_info() {
  echo -e "${BLUE}${1}${NC}"
}

# Print a blue key/value detail line (2-space indented label).
# Usage: print_detail "Label" "value"
print_detail() {
  echo -e "${BLUE}  ${1}:${NC} ${2}"
}

# Print a blue horizontal separator (40 equals signs).
print_separator() {
  echo -e "${BLUE}========================================${NC}"
}

# Print a blue section header surrounded by separator lines.
# Usage: print_section "Section title"
print_section() {
  print_separator
  echo -e "${BLUE}${1}${NC}"
  print_separator
}

# Print a blue tip message prefixed with a lightbulb icon.
# Usage: print_tip "message"
print_tip() {
  echo -e "${BLUE}💡 TIP: ${1}${NC}"
}

# Print a yellow per-second countdown from N to 1, then continue.
# Usage: countdown 5
countdown() {
  local n="${1}"
  for i in $(seq "${n}" -1 1); do
    echo -e "${YELLOW}Starting in ${i}s... (Ctrl+C to abort)${NC}"
    sleep 1
  done
}

# Print the closing banner with elapsed time: === Title in Xs ===
# Usage: print_footer "Title" start_time
print_footer() {
  local title="${1}"
  local duration
  duration=$(( $(date +%s) - ${2} ))
  echo ""
  echo -e "${GREEN}=== ${title} in ${duration}s ===${NC}"
}

# --- Validation helpers ---

# Check that a binary is available in PATH.
# Usage: check_command composer
check_command() {
  if ! command -v "${1}" &> /dev/null; then
    fail "${1} command not found"
  fi
}

# Verify Composer is available.
check_composer() {
  check_command composer
}

# Verify Drush is available.
check_drush() {
  check_command drush
}

# Verify npm is available.
check_npm() {
  check_command npm
}

# Verify the SSH agent has loaded keys.
check_ssh_agent() {
  if ! ssh-add -l &> /dev/null; then
    fail "No SSH keys available. Add your SSH key with 'ddev auth ssh'."
  fi
}

# Verify a Drush site alias is configured.
# Usage: check_drush_alias prod
check_drush_alias() {
  local alias="${1}"
  if ! drush site:alias "@${alias}" &> /dev/null; then
    fail "Drush alias '@${alias}' not found. Check drush/sites/ configuration."
  fi
}

# Prompt for y/N confirmation; exits 0 (graceful abort) on anything other
# than y/Y.
# Usage: confirm "Continue?"
confirm() {
  local reply
  read -r -p "${1} (y/N): " -n 1 reply
  echo
  if [[ ! ${reply} =~ ^[Yy]$ ]]; then
    print_warning "Aborted."
    exit 0
  fi
}

# --- File validation helpers ---

# Verify a SQL dump file is non-empty and contains a mysqldump header.
# Usage: verify_backup /path/to/file.sql
verify_backup() {
  local backup_file="${1}"

  if [[ ! -f "${backup_file}" ]]; then
    print_error "Backup file not found: ${backup_file}"
    return 1
  fi

  if [[ ! -s "${backup_file}" ]]; then
    print_error "Backup file is empty: ${backup_file}"
    return 1
  fi

  if ! grep -qE "^-- (MySQL|MariaDB) dump" "${backup_file}"; then
    print_error "Backup file appears invalid: ${backup_file}"
    return 1
  fi

  print_success "Backup verified: ${backup_file}"
  return 0
}
