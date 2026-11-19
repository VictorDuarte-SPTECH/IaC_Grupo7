#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C

fail() { printf 'ERRO: %s\n' "$*" >&2; exit 1; }
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }

[[ $EUID -eq 0 ]] || fail "Execute com sudo."
config=${1:-/etc/codetracker-backup.conf}
[[ -r "$config" ]] || fail "Configuracao ausente: $config"
# O arquivo e codigo shell e deve pertencer ao root, sem escrita por terceiros.
source "$config"
: "${APP_ROOT:?Defina APP_ROOT}"
: "${BACKUP_MOUNT:?Defina BACKUP_MOUNT}"
: "${S3_URI:?Defina S3_URI}"
: "${GPG_RECIPIENT:?Defina GPG_RECIPIENT}"
: "${GNUPGHOME:?Defina GNUPGHOME}"
export GNUPGHOME

for cmd in docker aws gpg tar sha256sum mountpoint findmnt flock cmp; do
  command -v "$cmd" >/dev/null || fail "Comando ausente: $cmd"
done
[[ "$S3_URI" == s3://*/* ]] || fail "Use s3://bucket/prefixo em S3_URI."
[[ "$GPG_RECIPIENT" =~ ^[[:xdigit:]]{40}$ ]] || fail "Use o fingerprint completo da chave RSA."
[[ "$BACKUP_MOUNT" != / ]] || fail "O destino nao pode ser o disco raiz."
mountpoint -q "$BACKUP_MOUNT" || fail "Disco de backup nao montado: $BACKUP_MOUNT"
for dir in IaC_Grupo7 BackEnd_Grupo7 Etiquetas_Grupo7 FrontEnd_Grupo7 Banco_Grupo7; do
  [[ -d "$APP_ROOT/$dir" ]] || fail "Diretorio ausente: $APP_ROOT/$dir"
done
compose="$APP_ROOT/IaC_Grupo7/docker-compose.yml"
[[ -f "$compose" ]] || fail "Compose local nao encontrado."
dc() { docker compose --project-directory "$APP_ROOT/IaC_Grupo7" -f "$compose" "$@"; }

exec 9>/run/lock/codetracker-backup.lock
flock -n 9 || fail "Outro backup esta em execucao."
install -d -m 700 /var/lib/codetracker-backup
work=$(mktemp -d /var/lib/codetracker-backup/work.XXXXXXXX)
cleanup() {
  local status=$?
  trap - EXIT
  rm -f -- "$work/lamar.sql" "$work/aplicacao.tar.gz" "$work/mysql-image.txt" \
    "$work/images.txt" "$work/snapshot-epoch.txt" "$work/conteudo.sha256" "$work/backup.tar.gz"
  if [[ -d "$work/recebido" ]]; then
    rm -f -- "$work/recebido/backup.tar.gz.gpg" "$work/recebido/backup.sha256" \
      "$work/recebido/transporte.sha256"
    rmdir -- "$work/recebido"
  fi
  rmdir -- "$work"
  exit "$status"
}
trap cleanup EXIT
trap 'printf "ERRO na linha %s; backup NAO concluido.\n" "$LINENO" >&2' ERR

id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
stage="$BACKUP_MOUNT/.incompleto-$id"
mkdir -m 700 -- "$stage"
log "INICIO $id"
findmnt --target "$BACKUP_MOUNT" --output SOURCE,FSTYPE,TARGET
date +%s > "$work/snapshot-epoch.txt"

non_innodb=$(dc exec -T mysql sh -ec '
  export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"
  exec mysql -u root --batch --skip-column-names -e "
    SELECT COUNT(*) FROM information_schema.tables
    WHERE table_schema='\''lamar'\'' AND table_type='\''BASE TABLE'\''
      AND engine <> '\''InnoDB'\'';"
')
[[ "$non_innodb" == 0 ]] || fail "Ha tabelas nao InnoDB; reveja a estrategia de consistencia."
cid=$(dc ps -q mysql)
[[ -n "$cid" ]] || fail "Servico mysql indisponivel."
image_id=$(docker inspect --format '{{.Image}}' "$cid")
docker image inspect --format '{{index .RepoDigests 0}}' "$image_id" > "$work/mysql-image.txt"
dc images > "$work/images.txt"

dc exec -T mysql sh -ec '
  export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"
  exec mysqldump -u root --single-transaction --quick --routines --events \
    --triggers --hex-blob --no-tablespaces --set-gtid-purged=OFF --databases lamar
' > "$work/lamar.sql"
[[ -s "$work/lamar.sql" ]] || fail "Dump vazio."

tar --exclude=.git --exclude=node_modules --exclude=target \
  -C "$APP_ROOT" -czf "$work/aplicacao.tar.gz" \
  IaC_Grupo7 BackEnd_Grupo7 Etiquetas_Grupo7 FrontEnd_Grupo7 Banco_Grupo7
(
  cd "$work"
  sha256sum lamar.sql aplicacao.tar.gz mysql-image.txt images.txt snapshot-epoch.txt > conteudo.sha256
  tar -czf backup.tar.gz lamar.sql aplicacao.tar.gz mysql-image.txt images.txt snapshot-epoch.txt conteudo.sha256
  sha256sum backup.tar.gz > "$stage/backup.sha256"
)

# A VM recebe somente a chave publica; a privada permanece com o custodiante.
gpg --batch --trust-model always --recipient "$GPG_RECIPIENT" \
  --output "$stage/backup.tar.gz.gpg" --encrypt "$work/backup.tar.gz"
log "VALIDACAO_LOCAL $stage"
(
  cd "$stage"
  sha256sum backup.tar.gz.gpg backup.sha256 > transporte.sha256
  cat transporte.sha256
  sha256sum --check transporte.sha256
)

remote="${S3_URI%/}/$id"
mkdir -m 700 "$work/recebido"
for file in backup.tar.gz.gpg backup.sha256 transporte.sha256; do
  aws s3 cp "$stage/$file" "$remote/$file" --only-show-errors
  aws s3 cp "$remote/$file" "$work/recebido/$file" --only-show-errors
done
log "VALIDACAO_DOWNLOAD_S3 $remote"
(
  cd "$work/recebido"
  cmp transporte.sha256 "$stage/transporte.sha256"
  cmp backup.sha256 "$stage/backup.sha256"
  sha256sum --check transporte.sha256
)
printf 'TRANSFERENCIA_VALIDADA %s\nSNAPSHOT_EPOCH=%s\n' \
  "$(date -u +%FT%TZ)" "$(cat "$work/snapshot-epoch.txt")" > "$stage/SUCESSO.txt"
aws s3 cp "$stage/SUCESSO.txt" "$remote/SUCESSO.txt" --only-show-errors
mv -- "$stage" "$BACKUP_MOUNT/$id"
install -m 600 "$work/snapshot-epoch.txt" /var/lib/codetracker-backup/ultimo-sucesso.epoch
log "SUCESSO copia local=$BACKUP_MOUNT/$id copia externa=$remote"
