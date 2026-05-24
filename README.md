[![add-on registry](https://img.shields.io/badge/DDEV-Add--on_Registry-blue)](https://addons.ddev.com)
[![tests](https://github.com/SicseDev/ddev-sicse-toolkit/actions/workflows/tests.yml/badge.svg?branch=main)](https://github.com/SicseDev/ddev-sicse-toolkit/actions/workflows/tests.yml?query=branch%3Amain)
[![last commit](https://img.shields.io/github/last-commit/SicseDev/ddev-sicse-toolkit)](https://github.com/SicseDev/ddev-sicse-toolkit/commits)
[![release](https://img.shields.io/github/v/release/SicseDev/ddev-sicse-toolkit)](https://github.com/SicseDev/ddev-sicse-toolkit/releases/latest)

# DDEV Sicse Toolkit

## Overview

A DDEV add-on providing workflow commands for Drupal projects managed by Sicse.
It covers day-to-day development tasks (database import, theme building, and
configuration synchronization) as well as full deployment pipelines for
acceptance and production environments.

The toolkit eliminates the need to remember long Drush or Composer command 
sequences. Instead, every routine task, e.g., spinning up a fresh development
environment, extracting translation templates, or deploying to production, is a
single `ddev` command. Each command provides colored, step-by-step output, 
verifies its own preconditions (SSH agent, Drush aliases, required binaries),
and logs deployment activity to a local log file for traceability.

## Opinionated conventions

The toolkit makes several deliberate choices that suit how Sicse builds and
maintains Drupal projects. Understanding these helps you decide whether the
add-on is a good fit and what to customize after installation:

- **Theme management**: theme commands always look for themes under 
  `web/themes/custom/`. Every theme is expected to have a `package.json` that
  declares at least a `build` npm script. `ddev theme-watch` additionally 
  requires a `watch` script.
- **Translation extraction**: `ddev translations-extract` defaults to Dutch
  (`nl`) as the extraction language. It relies on the `potx` Drush command and
  expects custom extensions to live under `web/modules/custom/` or
  `web/themes/custom/`.
- **Database seed export**: `ddev database-export-prod` and the post-deployment
  snapshot created by `ddev deploy-prod` both pass
  `--structure-tables-key=common` to `drush sql:dump`. This exports only the
  schema of Drupal's volatile tables (cache, session, watchdog, etc.) rather 
  than their data, keeping the seed file lean and suitable for version control.
- **Configuration sync**: `ddev config-sync` always runs `config:import` twice
  when the `config_split` module is enabled, to ensure environment-specific
  configuration splits are fully applied.
- **Deploy confirmation**: `ddev deploy-prod` requires you to type 
  `deploy to production` before it proceeds, followed by a five-second
  countdown. This intentional friction prevents accidental production 
  deployments.
- **Cache warming**: after disabling maintenance mode, the deployment process
  calls `drush cache:warm`. If no cache warmer is configured in Drupal, this
  step is a no-op.
- **Deployment logs**: every deployment step is appended to a monthly log file
  in `deployment_logs/` in the project root. Add this directory to your 
  `.gitignore` unless you want to commit the logs.

## Requirements

- DDEV >= v1.24.10
- [Drush](https://www.drush.org/) installed as a project dependency
- Drush site aliases configured in `drush/sites/` for remote environments
- An SSH agent with your deployment key loaded (`ddev auth ssh`)
- [potx](https://www.drupal.org/project/potx) module installed and enabled
  (required only for `ddev translations-extract`)

## Installation

```bash
ddev add-on get SicseDev/ddev-sicse-toolkit
ddev restart
```

After installation, commit the `.ddev` directory to version control.

## Commands

### Development

| Command | Description |
| ------- | ----------- |
| `ddev apply-updates` | Initialise the dev environment, update Composer packages and theme npm dependencies, apply database updates, and export configuration |
| `ddev config-sync [env]` | Run the full Drupal update sequence: cache rebuild, `updatedb`, `config:import` (with a second pass when `config_split` is active), `deploy:hook`, locale update, cron, and a final cache rebuild; optionally targets a remote Drush alias (e.g. `@acc`, `@prod`) |
| `ddev database-export-prod` | Export a lean production database dump (volatile tables are schema-only) to `database/seed/database.sql` |
| `ddev database-import-dev` | Drop and re-import `database/seed/database.sql` into the local database |
| `ddev hash-salt` | Generate a random string suitable for use as a Drupal hash salt |
| `ddev init-dev` | Set up the local environment (Composer install, theme build, database import, config sync); supports `--skip-db`, `--skip-theme`, and `--skip-config` |
| `ddev login [username]` | Generate a one-time login link and open it in a browser; runs on the host machine and supports Linux, macOS, and WSL |
| `ddev theme-build [theme]` | Run `npm install` and `npm run build` in all custom themes, or in a single named theme |
| `ddev theme-update [theme]` | Run `npm update` in all custom themes, or in a single named theme |
| `ddev theme-watch [theme]` | Run `npm run watch` in the specified theme, or autodetect the first custom theme that declares a `watch` script |
| `ddev translations-extract` | Extract a `.po` translation template from a custom module or theme using `drush potx` |

### Deployment

| Command | Description |
| ------- | ----------- |
| `ddev deploy-acc` | Deploy to the acceptance environment |
| `ddev deploy-prod` | Deploy to the production environment |

Both deployment commands orchestrate the same set of steps: install Composer
dependencies (without dev packages), build theme assets, enable maintenance 
mode, sync code to the remote environment, run configuration synchronization,
and disable maintenance mode.

`ddev deploy-acc` additionally syncs the production database and managed files
to acceptance before running those steps. `ddev deploy-prod` creates a 
pre-deployment database backup first, and exports a post-deployment snapshot to
`database/seed/database.sql` at the end.

Every deployment step is logged to a monthly file in `deployment_logs/`. See
[Deployment logs](#deployment-logs) below.

## Database exports

The `database-export-prod` and `database-import-dev` commands share the file 
`database/seed/database.sql`. The project's `database/` directory is structured
as follows:

```
database/
  seed/           ← tracked in git (bootstraps ddev init-dev)
    database.sql
  exports/        ← gitignored (deployment safety nets)
    *.sql
```

`database/seed/database.sql` is a deliberate project-level artifact, kept
separate from DDEV's own snapshot mechanism (`.ddev/db_snapshots/`), which
stores binary filesystem-level snapshots managed by DDEV internally and are not
suited for version control or cross-machine sharing.

Committing `database/seed/database.sql` to version control gives every developer
a consistent and reproducible starting point. If the database contains sensitive
data, add it to your `.gitignore` and distribute it through other means instead.

Deployment backups created by `ddev deploy-acc` and `ddev deploy-prod` are
stored in `database/exports/`. These are local safety nets only, add 
`database/exports/` to your `.gitignore`.

## Deployment logs

Both `ddev deploy-acc` and `ddev deploy-prod` append timestamped entries to a
monthly log file under `deployment_logs/` in the project root:

```
deployment_logs/
  deploy_acc_202506.log
  deploy_prod_202506.log
```

Each entry records the environment, the action performed, and its status
(`started` / `success` / `failed` / `completed`). These logs remain on the 
developer's machine only and are never sent anywhere.

Add `deployment_logs/` to your `.gitignore` unless you actively want to commit
deployment history to version control.

## Customizing the rsync exclude list

When code is synced to a remote environment, rsync reads 
`.ddev/sicse/rsync-exclude.txt` as its exclude list. The add-on ships sensible
defaults covering common Drupal, Composer, Node.js, and development tool
patterns.

After installation, you can edit this file freely to match your project. The 
file ships with a `#ddev-generated` marker on the first line. As long as that
line is present, running `ddev add-on get SicseDev/ddev-sicse-toolkit` again
will restore the file to the add-on's defaults. To prevent that, remove the 
first line: DDEV will then treat the file as user-owned and leave it untouched 
on future updates.

## Testing

The test suite is organized into two layers, each in its own subdirectory under
`tests/`.

```
tests/
  helpers/
    setup.bash                  ← shared bats library loader
  unit/
    common.bats                 ← sicse/lib/common.sh
    deploy-lib.bats             ← sicse/lib/deploy-lib.sh
    theme-build.bats            ← theme-build command
    theme-watch.bats            ← theme-watch command
    translations-extract.bats   ← translations-extract command
  integration/
    installation.bats           ← DDEV add-on installation
```

### Prerequisites

Both [bats-core](https://github.com/bats-core/bats-core) and the three helper 
libraries must be installed on the host. The test suite looks for them in the
standard locations created by each package manager, so no environment variables 
need to be set.

**Debian / Ubuntu:**

```bash
sudo apt-get install bats bats-assert bats-file bats-support
```

**macOS / Linux with Homebrew:**

```bash
brew install bats-core bats-assert bats-file bats-support
```

### Unit tests

Unit tests live in `tests/unit/` and cover the shell library functions in 
`sicse/lib/common.sh` and `sicse/lib/deploy-lib.sh` (output helpers,
`verify_backup`, `check_command`, `log_deployment`, all `deploy_*` helpers,
etc.), the `theme-build` command (`build_theme` and `main`), the `theme-watch`
command (`find_theme_with_watch`), as well as all testable functions in the
`translations-extract` command (`parse_args`, `validate_inputs`,
`ensure_translations_dir`, `move_pot_to_translation`, `create_htaccess`, 
`check_enabled`, `run_extraction`, `verify_translation_file`, and 
`check_atd_module`). They run entirely without DDEV or Drupal, making them very
fast, a good first check during development.

**Run the full unit suite:**

```bash
bats ./tests/unit/
```

**Run a single unit test file:**

```bash
bats ./tests/unit/common.bats
bats ./tests/unit/deploy-lib.bats
bats ./tests/unit/theme-build.bats
bats ./tests/unit/theme-watch.bats
bats ./tests/unit/translations-extract.bats
```

**Verbose output (useful when debugging a failing test):**

```bash
bats ./tests/unit/ \
  --show-output-of-passing-tests \
  --verbose-run \
  --print-output-on-failure
```

### Integration tests

Integration tests live in `tests/integration/`. They create a temporary DDEV 
project, install the add-on from the local directory, and then verify that all
command files are installed, are executable, and are registered by DDEV.

They require a working DDEV installation in addition to bats-core.

**Run (excludes the release test that needs a published release):**

```bash
bats ./tests/integration/ --filter-tags '!release'
```

**Debug a failing test:**

```bash
bats ./tests/integration/ \
  --show-output-of-passing-tests \
  --verbose-run \
  --print-output-on-failure
```

### Continuous integration

GitHub Actions runs both layers automatically for every push and pull request.
Unit tests run first; integration tests only start if unit tests pass. See
`.github/workflows/tests.yml` for details.

## Credits

**Contributed and maintained by [@Sicse](https://github.com/SicseDev)**
