#!/usr/bin/env bash
# Daily backup of all service data volumes (Vaultwarden + Grocy + CouchDB).
# - VACUUM INTO for each SQLite database: compact, WAL-free, safe on live containers
# - _all_docs dump for CouchDB databases (not SQLite, so VACUUM INTO doesn't apply)
# - tar archive of remaining volume data (RSA keys, attachments, config, etc.)
# - Local retention: 30 days in /opt/backups
# - Remote: Azure Blob Storage via VM managed identity (no credentials stored)
# Config: /etc/vaultwarden-backup.conf (written by deploy.sh)
#
# Installed by scripts/install-backup.sh. To pick up changes to this file,
# re-run: sudo bash /opt/vaultwarden-setup/scripts/install-backup.sh
set -euo pipefail

BACKUP_DIR=/opt/backups
TIMESTAMP=$(date +%F-%H%M)
mkdir -p "$BACKUP_DIR"

# ── backup_volume: back up one Docker volume ──────────────────────────────────
# Args:
#   $1  archive prefix   e.g. "vaultwarden" → vaultwarden-data-TIMESTAMP.tar.gz
#   $2  docker volume    e.g. "vaultwarden-setup_vw-data"
#   $3  db path in vol   e.g. "db.sqlite3" or "data/grocy.db" (relative to vol root)
#   $@  extra tar excludes (relative paths, no leading ./)
backup_volume() {
  local prefix="$1" volume="$2" db_relpath="$3"
  shift 3
  local archive="${BACKUP_DIR}/${prefix}-data-${TIMESTAMP}.tar.gz"
  local tmpdir
  tmpdir=$(mktemp -d "${BACKUP_DIR}/.tmp-${prefix}-XXXXX")

  echo "  Backing up ${prefix}..."

  # VACUUM INTO: write a compacted, WAL-free db snapshot into a mirrored path
  # inside tmpdir so it lands at the correct location when tar'd.
  mkdir -p "${tmpdir}/$(dirname "$db_relpath")"
  docker run --rm \
    -v "${volume}:/vol:ro" \
    -v "${tmpdir}:/tmp-backup" \
    alpine sh -c "apk add -q --no-cache sqlite \
      && sqlite3 /vol/${db_relpath} \"VACUUM INTO '/tmp-backup/${db_relpath}';\""

  # tar: vacuum'd db (correct relative path) + everything else from the volume,
  # excluding the live db files (replaced) and any caller-specified paths.
  docker run --rm \
    -v "${volume}:/vol:ro" \
    -v "${tmpdir}:/tmp-backup:ro" \
    -v "${BACKUP_DIR}:/backup" \
    alpine tar czf "/backup/${prefix}-data-${TIMESTAMP}.tar.gz" \
      -C /tmp-backup "${db_relpath}" \
      -C /vol \
      --exclude="./${db_relpath}" \
      --exclude="./${db_relpath}-wal" \
      --exclude="./${db_relpath}-shm" \
      $(printf -- '--exclude=./%s ' "$@") \
      .

  rm -rf "$tmpdir"
  echo "    ${archive} ($(du -sh "$archive" | cut -f1))"
}

# ── Vaultwarden ───────────────────────────────────────────────────────────────
backup_volume "vaultwarden" \
  "vaultwarden-setup_vw-data" \
  "db.sqlite3" \
  "icon_cache"

# ── Grocy ─────────────────────────────────────────────────────────────────────
# linuxserver/grocy stores its database at /config/data/grocy.db
backup_volume "grocy" \
  "vaultwarden-setup_grocy-data" \
  "data/grocy.db"

# ── CouchDB (Obsidian LiveSync) ────────────────────────────────────────────────
# CouchDB isn't SQLite, so VACUUM INTO doesn't apply. Instead, dump each
# user database's documents via the HTTP API (_all_docs) — a consistent,
# portable snapshot that's safe to take against a live server.
backup_couchdb() {
  local prefix="couchdb"
  local archive="${BACKUP_DIR}/${prefix}-data-${TIMESTAMP}.tar.gz"
  local tmpdir
  tmpdir=$(mktemp -d "${BACKUP_DIR}/.tmp-${prefix}-XXXXX")

  echo "  Backing up ${prefix}..."

  if ! docker ps --format '{{.Names}}' | grep -qx couchdb; then
    echo "    WARN: couchdb container not running — skipping."
    rm -rf "$tmpdir"
    return
  fi

  local env_file="/opt/vaultwarden-setup/.env"
  local user pass
  user=$(grep -E '^COUCHDB_USER=' "$env_file" | cut -d= -f2-)
  pass=$(grep -E '^COUCHDB_PASSWORD=' "$env_file" | cut -d= -f2-)
  if [[ -z "$user" || -z "$pass" ]]; then
    echo "    WARN: COUCHDB_USER/PASSWORD not set in .env — skipping."
    rm -rf "$tmpdir"
    return
  fi

  local dbs
  dbs=$(docker run --rm --network vaultwarden-setup_vw-internal alpine sh -c \
    "apk add -q --no-cache curl && curl -sf -u '${user}:${pass}' http://couchdb:5984/_all_dbs" \
    | python3 -c "import sys,json; print('\n'.join(d for d in json.load(sys.stdin) if not d.startswith('_')))")

  for db in $dbs; do
    docker run --rm --network vaultwarden-setup_vw-internal \
      -v "${tmpdir}:/out" alpine sh -c \
      "apk add -q --no-cache curl && curl -sf -u '${user}:${pass}' 'http://couchdb:5984/${db}/_all_docs?include_docs=true' -o '/out/${db}.json'"
  done

  docker run --rm -v "${tmpdir}:/tmp-backup:ro" -v "${BACKUP_DIR}:/backup" \
    alpine tar czf "/backup/${prefix}-data-${TIMESTAMP}.tar.gz" -C /tmp-backup .

  rm -rf "$tmpdir"
  echo "    ${archive} ($(du -sh "$archive" | cut -f1))"
}
backup_couchdb

# ── Continuwuity (Matrix — optional, profile: matrix) ──────────────────────────
# Not a SQLite database (RocksDB), so VACUUM INTO doesn't apply, and unlike
# CouchDB there's no HTTP dump endpoint — this is a plain tar of the live data
# directory. RocksDB is crash-consistent, so this is safe for a personal/
# minimal-use server; it isn't a point-in-time transactional snapshot. Skips
# entirely if the matrix profile has never been enabled (no such container).
backup_continuwuity() {
  local prefix="continuwuity"
  local archive="${BACKUP_DIR}/${prefix}-data-${TIMESTAMP}.tar.gz"

  echo "  Backing up ${prefix}..."

  if ! docker ps -a --format '{{.Names}}' | grep -qx continuwuity; then
    echo "    SKIP: continuwuity not enabled (matrix profile never started)."
    return
  fi

  docker run --rm \
    -v "vaultwarden-setup_continuwuity-data:/vol:ro" \
    -v "${BACKUP_DIR}:/backup" \
    alpine tar czf "/backup/${prefix}-data-${TIMESTAMP}.tar.gz" -C /vol .

  echo "    ${archive} ($(du -sh "$archive" | cut -f1))"
}
backup_continuwuity

# ── Prune local archives older than 30 days ───────────────────────────────────
find "$BACKUP_DIR" -name "*-data-*.tar.gz" -mtime +30 -delete

# ── Upload to Azure Blob Storage ──────────────────────────────────────────────
# Reads storage account name from config written by deploy.sh.
# Uses the VM's managed identity via IMDS — no credentials stored anywhere.
CONF=/etc/vaultwarden-backup.conf
if [[ ! -f "$CONF" ]]; then
  echo "WARN: $CONF not found — skipping Azure upload. Run deploy.sh to configure."
  exit 0
fi
# shellcheck source=/dev/null
source "$CONF"

if [[ -z "${BACKUP_STORAGE_ACCOUNT:-}" ]]; then
  echo "WARN: BACKUP_STORAGE_ACCOUNT not set in $CONF — skipping Azure upload."
  exit 0
fi

# Get a short-lived bearer token from the Azure Instance Metadata Service
TOKEN=$(curl -sf \
  -H "Metadata: true" \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fstorage.azure.com%2F" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# Upload helper: posts one archive to the blob container
upload_blob() {
  local file="$1"
  local blob_name
  blob_name=$(basename "$file")
  curl -sf -X PUT \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "x-ms-version: 2020-04-08" \
    -H "x-ms-blob-type: BlockBlob" \
    -H "Content-Type: application/gzip" \
    --data-binary @"${file}" \
    "https://${BACKUP_STORAGE_ACCOUNT}.blob.core.windows.net/vw-backups/${blob_name}"
  echo "  Uploaded: ${blob_name}"
}

echo "Uploading to Azure (${BACKUP_STORAGE_ACCOUNT}/vw-backups)..."
upload_blob "${BACKUP_DIR}/vaultwarden-data-${TIMESTAMP}.tar.gz"
upload_blob "${BACKUP_DIR}/grocy-data-${TIMESTAMP}.tar.gz"
if [[ -f "${BACKUP_DIR}/couchdb-data-${TIMESTAMP}.tar.gz" ]]; then
  upload_blob "${BACKUP_DIR}/couchdb-data-${TIMESTAMP}.tar.gz"
fi
if [[ -f "${BACKUP_DIR}/continuwuity-data-${TIMESTAMP}.tar.gz" ]]; then
  upload_blob "${BACKUP_DIR}/continuwuity-data-${TIMESTAMP}.tar.gz"
fi
