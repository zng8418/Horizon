#!/usr/bin/env bash
# Horizon daily run - production-grade wrapper
# Usage:
#   ./scripts/daily-run.sh                  # default profile (zhipu)
#   ./scripts/daily-run.sh minmax           # switch to minmax profile
#   ./scripts/daily-run.sh zhipu 48         # profile + hours
# Cron: 0 8 * * * /path/to/horizon/scripts/daily-run.sh >> /path/to/horizon/logs/cron.log 2>&1

set -euo pipefail

# ===== Config =====
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_DIR="$PROJECT_DIR/logs"
LOG_FILE="$LOG_DIR/daily-$(date +%Y%m%d).log"
PROFILE="${1:-zhipu}"          # zhipu | minmax
HOURS="${2:-24}"
LOCK_FILE="$PROJECT_DIR/.horizon.lock"
KEEP_LOGS_DAYS=14
MAX_RUN_MINUTES=25             # 超过 25 分钟自动 kill

# ===== Helpers =====
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE" ; }
die()  { log "❌ $*"; cleanup; exit 1; }
cleanup() { rm -f "$LOCK_FILE"; }

mkdir -p "$LOG_DIR"

# ===== Preflight =====
[ -d "$PROJECT_DIR" ]            || die "PROJECT_DIR not found: $PROJECT_DIR"
[ -f "$PROJECT_DIR/pyproject.toml" ] || die "pyproject.toml missing — is this a Horizon repo?"
command -v uv >/dev/null          || die "uv not installed (curl -LsSf https://astral.sh/uv/install.sh | sh)"
[ -f "$PROJECT_DIR/.env" ]       || die ".env missing (cp .env.example .env and fill in keys)"

# ===== Lock (prevent concurrent runs) =====
if [ -f "$LOCK_FILE" ]; then
  LOCK_AGE=$(( $(date +%s) - $(stat -c %Y "$LOCK_FILE") ))
  if [ "$LOCK_AGE" -lt 1800 ]; then  # 30 min
    die "Another run is in progress (lock age: ${LOCK_AGE}s). Aborting."
  else
    log "⚠️  Stale lock (${LOCK_AGE}s) — removing."
    rm -f "$LOCK_FILE"
  fi
fi
trap cleanup EXIT
echo $$ > "$LOCK_FILE"

# ===== Apply profile =====
case "$PROFILE" in
  zhipu)
    [ -f "$PROJECT_DIR/data/config.zhipu.json" ] && SRC="data/config.zhipu.json" || SRC="data/config.json"
    ;;
  minmax)
    [ -f "$PROJECT_DIR/data/config.minmax.json" ] || die "data/config.minmax.json not found"
    SRC="data/config.minmax.json"
    ;;
  *) die "Unknown profile: $PROFILE (use 'zhipu' or 'minmax')" ;;
esac

cd "$PROJECT_DIR"
if ! cmp -s "$SRC" data/config.json; then
  log "🔄 Switching profile: $PROFILE (from $SRC)"
  cp "$SRC" data/config.json
else
  log "🔧 Profile $PROFILE already active"
fi

# ===== Pre-run =====
log "🌅 Horizon starting (profile=$PROFILE hours=$HOURS)"
log "📂 Project: $PROJECT_DIR"

# Pull latest if it's a git repo
if [ -d .git ]; then
  log "📥 Pulling latest from origin/main..."
  git pull --quiet --ff-only origin main 2>>"$LOG_FILE" || log "⚠️  git pull failed (continuing with local code)"
fi

# Sync deps
log "📦 uv sync..."
uv sync --quiet 2>>"$LOG_FILE" || die "uv sync failed"

# Validate config
log "🔍 Validating config..."
uv run python -c "from src.storage.manager import StorageManager; from src.models import Config; \
  c = StorageManager('data').load_config(); \
  print(f'  ai.provider={c.ai.provider} model={c.ai.model} base_url={c.ai.base_url or \"(default)\"}')" \
  >> "$LOG_FILE" 2>&1 || die "Config validation failed (see $LOG_FILE)"

# Run Horizon with timeout
log "🚀 Running horizon (timeout: ${MAX_RUN_MINUTES}m)..."
START=$(date +%s)
if timeout "${MAX_RUN_MINUTES}m" uv run horizon --hours "$HOURS" >> "$LOG_FILE" 2>&1; then
  END=$(date +%s)
  log "✅ Horizon finished in $((END - START))s"
else
  EXIT_CODE=$?
  log "❌ Horizon failed (exit=$EXIT_CODE, see $LOG_FILE)"
  exit "$EXIT_CODE"
fi

# ===== Post-run: deploy to gh-pages (if docs/ updated) =====
if [ -d "$PROJECT_DIR/docs/_posts" ] && [ -n "$(ls -A "$PROJECT_DIR/docs/_posts" 2>/dev/null)" ]; then
  log "📄 Deploying docs/ to gh-pages..."
  TMPDIR=$(mktemp -d)
  trap "rm -rf $TMPDIR; cleanup" EXIT

  if git fetch origin gh-pages:gh-pages 2>/dev/null; then
    git worktree add "$TMPDIR" gh-pages
  else
    git worktree add --detach "$TMPDIR" main
    cd "$TMPDIR" && git checkout --orphan gh-pages && git rm -rf . >/dev/null 2>&1
    cd "$PROJECT_DIR"
  fi

  cp -r docs/* "$TMPDIR/"
  cd "$TMPDIR"
  git add -A
  if git diff --cached --quiet; then
    log "   (no doc changes to commit)"
  else
    git -c user.name="horizon-bot" -c user.email="bot@localhost" commit -m "📝 Daily Summary: $(date +%Y-%m-%d)" >/dev/null
    git push origin gh-pages && log "   Pushed to gh-pages"
  fi

  cd "$PROJECT_DIR"
  git worktree remove --force "$TMPDIR"
else
  log "ℹ️  No docs/_posts to deploy"
fi

# ===== Cleanup old logs =====
find "$LOG_DIR" -name "daily-*.log" -mtime +"$KEEP_LOGS_DAYS" -delete 2>/dev/null || true

log "🎉 Done."
