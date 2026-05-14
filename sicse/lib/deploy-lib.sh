#!/usr/bin/env bash
# Deploy helper library. Source in deploy-acc and deploy-prod:
#   source /mnt/ddev_config/sicse/lib/deploy-lib.sh
#
# Note: set -euo pipefail is intentionally omitted here. Error mode is
# controlled by the sourcing script, not the library.

source /mnt/ddev_config/sicse/lib/common.sh

# Log deployment activity to a monthly log file.
#
# Arguments:
#   environment - Deployment environment identifier (e.g., acc, prod).
#   action      - Action name to include in the log entry.
#   status      - Status string to include in the log entry.
#
# Usage: log_deployment environment action status
log_deployment() {
  local environment="${1}"
  local action="${2}"
  local status="${3}"
  local log_dir="${WEB_ROOT}/deployment_logs"
  local log_file
  log_file="${log_dir}/deploy_${environment}_$(date +%Y%m).log"

  mkdir -p "${log_dir}"
  echo "[$(date -Iseconds)] ${action}: ${status}" >> "${log_file}"
}

# Create a full database dump from a remote alias, verify its
# integrity, and log the result. This dump includes all tables, such
# as cache, session, and watchdog log tables. To create a lean seed
# dump that omits those volatile tables, use the database-export-prod
# command instead, which passes --structure-tables-key=common to
# drush sql:dump. Extra arguments are forwarded to drush sql:dump.
#
# Arguments:
#   environment - Deployment environment identifier (e.g., acc, prod).
#   alias       - Drush remote alias to dump from.
#   dest_file   - Absolute path for the output SQL file.
#   [...]       - Extra arguments forwarded to drush sql:dump.
#
# Returns: 0 on success, 1 on failure (dest_file removed on failure).
# Usage: deploy_database_dump environment alias dest_file [extra_drush_args...]
deploy_database_dump() {
  local environment="${1}"
  local alias="${2}"
  local dest_file="${3}"
  shift 3

  mkdir -p "$(dirname "${dest_file}")"
  log_deployment "${environment}" "database:dump-${alias}" "started"
  print_info "Creating database dump from @${alias}..."

  if drush "@${alias}" sql:dump \
      --extra-dump='--single-transaction=false --no-tablespaces' \
      "$@" \
      > "${dest_file}" && verify_backup "${dest_file}"; then
    log_deployment "${environment}" "database:dump-${alias}" \
      "success - ${dest_file}"
    return 0
  fi

  log_deployment "${environment}" "database:dump-${alias}" "failed"
  rm -f "${dest_file}"
  return 1
}

# Install Composer dependencies without dev packages.
#
# Arguments:
#   environment - Deployment environment identifier (e.g., acc, prod).
#
# Returns: 0 on success, 1 on failure.
# Usage: deploy_composer_install environment
deploy_composer_install() {
  local environment="${1}"

  log_deployment "${environment}" "composer:install" "started"

  if composer install --no-dev --optimize-autoloader --no-interaction; then
    print_success "Composer dependencies installed"
    log_deployment "${environment}" "composer:install" "success"
    return 0
  else
    print_error "Failed to install Composer dependencies"
    log_deployment "${environment}" "composer:install" "failed"
    return 1
  fi
}

# Build theme assets via the theme-build command.
# Note: delegates to the theme-build web command via COMMANDS_DIR. If
# that command is ever renamed or moved, this function must be updated
# too.
#
# Arguments:
#   environment - Deployment environment identifier (e.g., acc, prod).
#
# Returns: 0 on success, 1 on failure.
# Usage: deploy_theme_build environment
deploy_theme_build() {
  local environment="${1}"

  log_deployment "${environment}" "theme:build" "started"

  if "${COMMANDS_DIR}/theme-build"; then
    print_success "Theme assets built"
    log_deployment "${environment}" "theme:build" "success"
    return 0
  else
    print_error "Failed to build theme assets"
    log_deployment "${environment}" "theme:build" "failed"
    return 1
  fi
}

# Enable maintenance mode and rebuild cache on the remote environment.
#
# Arguments:
#   environment - Deployment environment identifier (e.g., acc, prod).
#
# Returns: 0 on success, 1 on failure.
# Usage: deploy_maintenance_enable environment
deploy_maintenance_enable() {
  local environment="${1}"

  log_deployment "${environment}" "maintenance:enable" "started"

  if drush "@${environment}" maint:set 1 && \
     drush "@${environment}" cache:rebuild; then
    print_success "Maintenance mode enabled"
    log_deployment "${environment}" "maintenance:enable" "success"
    return 0
  else
    print_error "Failed to enable maintenance mode"
    log_deployment "${environment}" "maintenance:enable" "failed"
    return 1
  fi
}

# Disable maintenance mode, rebuild cache, and warm the page cache.
#
# Arguments:
#   environment - Deployment environment identifier (e.g., acc, prod).
#
# Returns: 0 on success, 1 on failure.
# Usage: deploy_maintenance_disable environment
deploy_maintenance_disable() {
  local environment="${1}"

  log_deployment "${environment}" "maintenance:disable" "started"

  if drush "@${environment}" maint:set 0 && \
     drush "@${environment}" cache:rebuild && \
     drush "@${environment}" cache:warm; then
    print_success "Maintenance mode disabled"
    log_deployment "${environment}" "maintenance:disable" "success"
    return 0
  else
    print_error "Failed to disable maintenance mode"
    log_deployment "${environment}" "maintenance:disable" "failed"
    return 1
  fi
}

# Rsync code to the remote environment, then make Drush executable.
# Requires the rsync exclude file at ${RSYNC_EXCLUDE_FILE} to be
# present; returns 1 immediately if it is missing.
#
# Arguments:
#   environment - Deployment environment identifier (e.g., acc, prod).
#
# Returns: 0 on success, 1 on failure.
# Usage: deploy_code_sync environment
deploy_code_sync() {
  local environment="${1}"

  log_deployment "${environment}" "code:sync" "started"

  if [[ ! -f "${RSYNC_EXCLUDE_FILE}" ]]; then
    print_error "Rsync exclude file not found: ${RSYNC_EXCLUDE_FILE}"
    log_deployment "${environment}" "code:sync" \
      "failed - exclude file not found: ${RSYNC_EXCLUDE_FILE}"
    return 1
  fi

  if drush rsync -y "@self":../ "@${environment}":../ -- \
    --delete \
    --force \
    --chmod=Du=rwx,Dg=rx,Do=rx,Fu=rw,Fg=r,Fo=r \
    --exclude-from="${RSYNC_EXCLUDE_FILE}" && \
    drush "@${environment}" site:ssh \
      'chmod 0755 vendor/bin/drush vendor/bin/drush.php vendor/drush/drush/drush'; then

    print_success "Code synced"
    log_deployment "${environment}" "code:sync" "success"
    return 0
  else
    print_error "Failed to sync code"
    log_deployment "${environment}" "code:sync" "failed"
    return 1
  fi
}

# Run configuration synchronization on the remote environment.
# Note: delegates to the config-sync web command via COMMANDS_DIR. If
# that command is ever renamed or moved, this function must be updated
# too.
#
# Arguments:
#   environment - Deployment environment identifier (e.g., acc, prod).
#
# Returns: 0 on success, 1 on failure.
# Usage: deploy_config_sync environment
deploy_config_sync() {
  local environment="${1}"

  log_deployment "${environment}" "config:sync" "started"

  if "${COMMANDS_DIR}/config-sync" "@${environment}"; then
    log_deployment "${environment}" "config:sync" "success"
    return 0
  else
    print_error "Failed to sync configuration"
    log_deployment "${environment}" "config:sync" "failed"
    return 1
  fi
}

# Orchestrate all standard deployment steps.
#
# Arguments:
#   environment - Deployment environment identifier (e.g., acc, prod).
#   step_offset - Starting step number; allows callers to continue
#                 their own numbering sequence (default: 1).
#
# Returns: 0 on success, 1 on failure.
# Usage: deploy_execute environment step_offset
deploy_execute() {
  local environment="${1}"
  local step="${2:-1}"

  log_deployment "${environment}" "deployment" "started"

  echo ""
  print_step "${step}" "Installing Composer dependencies"
  deploy_composer_install "${environment}" || {
    log_deployment "${environment}" "deployment" "failed at step ${step}"
    return 1
  }
  ((step++))

  echo ""
  print_step "${step}" "Building theme assets"
  deploy_theme_build "${environment}" || {
    log_deployment "${environment}" "deployment" "failed at step ${step}"
    return 1
  }
  ((step++))

  echo ""
  print_step "${step}" "Enabling maintenance mode"
  deploy_maintenance_enable "${environment}" || {
    log_deployment "${environment}" "deployment" "failed at step ${step}"
    return 1
  }
  ((step++))

  echo ""
  print_step "${step}" "Syncing code to @${environment}"
  deploy_code_sync "${environment}" || {
    print_warning "Maintenance mode will remain active due to failure!"
    log_deployment "${environment}" "deployment" \
      "failed at step ${step}, maintenance mode still active!"
    return 1
  }
  ((step++))

  echo ""
  print_step "${step}" "Running configuration sync"
  deploy_config_sync "${environment}" || {
    print_warning "Maintenance mode will remain active due to failure!"
    log_deployment "${environment}" "deployment" \
      "failed at step ${step}, maintenance mode still active!"
    return 1
  }
  ((step++))

  echo ""
  print_step "${step}" "Disabling maintenance mode"
  deploy_maintenance_disable "${environment}" || {
    log_deployment "${environment}" "deployment" \
      "failed at step ${step}, maintenance mode may still be active!"
    return 1
  }

  return 0
}
