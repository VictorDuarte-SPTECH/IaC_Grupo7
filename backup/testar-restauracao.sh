#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export LC_ALL=C

fail() { printf 'ERRO: %s\n' "$*" >&2; exit 1; }
[[ $# -eq 2 ]] || fail "Uso: $0 s3://bucket/prefixo/ID /diretorio-de-testes"
remote=${1%/}
parent=$2
[[ "$remote" == s3://*/*/* ]] || fail "Informe o conjunto de backup, nao apenas o bucket."
[[ -d "$parent" && -w "$parent" ]] || fail "Diretorio de testes inexistente ou sem permissao."
for cmd in docker aws gpg tar sha256sum; do
  command -v "$cmd" >/dev/null || fail "Comando ausente: $cmd"
done
start=$(date +%s)
work=$(mktemp -d "$parent/restauracao.XXXXXXXX")
container_id=
cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n "$container_id" ]]; then
    if ! docker rm -fv "$container_id" >/dev/null; then
      printf 'ERRO: remova manualmente o container de teste %s e seu volume anonimo.\n' "$container_id" >&2
      status=1
    fi
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'printf "ERRO na linha %s; teste NAO aprovado. Evidencias: %s\n" "$LINENO" "$work" >&2' ERR
printf 'INICIO_UTC=%s\nDESTINO=%s\n' "$(date -u +%FT%TZ)" "$work"

for file in SUCESSO.txt backup.tar.gz.gpg backup.sha256 transporte.sha256; do
  aws s3 cp "$remote/$file" "$work/$file" --only-show-errors
done
(
  cd "$work"
  sha256sum --check transporte.sha256
  gpg --output backup.tar.gz --decrypt backup.tar.gz.gpg
  sha256sum --check backup.sha256
  mkdir dados aplicacao
  tar --no-same-owner -xzf backup.tar.gz -C dados \
    lamar.sql aplicacao.tar.gz mysql-image.txt images.txt snapshot-epoch.txt conteudo.sha256
  cd dados
  sha256sum --check conteudo.sha256
)
tar --no-same-owner -xzf "$work/dados/aplicacao.tar.gz" -C "$work/aplicacao"
image=$(cat "$work/dados/mysql-image.txt")
[[ "$image" =~ ^mysql@sha256:[[:xdigit:]]{64}$ ]] || fail "Digest da imagem MySQL ausente ou inesperado."
snapshot=$(cat "$work/dados/snapshot-epoch.txt")
[[ "$snapshot" =~ ^[0-9]+$ ]] || fail "Timestamp do snapshot invalido."
age=$((start - snapshot))
(( age >= 0 )) || fail "Snapshot no futuro; confira a sincronizacao dos relogios."

# Sem rede, sem portas publicadas e sem qualquer volume de producao.
container_id=$(docker create --network none --label codetracker.backup-test=true \
  -e MYSQL_ALLOW_EMPTY_PASSWORD=yes "$image")
docker start "$container_id" >/dev/null
ready=0
for ((attempt=0; attempt<90; attempt++)); do
  if docker exec "$container_id" mysqladmin --protocol=TCP -h 127.0.0.1 ping --silent >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 2
done
if (( ! ready )); then
  docker logs --tail 60 "$container_id" >&2
  fail "MySQL de teste nao iniciou em ate 180 segundos."
fi

docker exec -i "$container_id" mysql -u root < "$work/dados/lamar.sql"
docker exec "$container_id" mysqlcheck -u root --check lamar | tee "$work/verificacao-tabelas.txt"
docker exec "$container_id" mysql -u root --batch lamar -e "
  SELECT 'item' AS tabela, COUNT(*) AS registros FROM item
  UNION ALL SELECT 'usuario', COUNT(*) FROM usuario
  UNION ALL SELECT 'movimentacao_estoque', COUNT(*) FROM movimentacao_estoque;
" | tee "$work/contagens.txt"

elapsed=$(( $(date +%s) - start ))
{
  printf 'FIM_UTC=%s\n' "$(date -u +%FT%TZ)"
  printf 'TEMPO_RESTAURACAO_DADOS_SEGUNDOS=%s\n' "$elapsed"
  printf 'IDADE_SNAPSHOT_NO_INICIO_SEGUNDOS=%s\n' "$age"
  printf 'LIMITE_RPO_SEGUNDOS=604800\n'
  printf 'INTEGRIDADE_E_IMPORTACAO=OK\n'
  printf 'APLICACAO_EXTRAIDA=%s/aplicacao\n' "$work"
  printf 'RTO_COMPLETO=NAO_MEDIDO_NESTE_SCRIPT\n'
} | tee "$work/resultado.txt"
if (( age > 604800 )); then
  printf 'ERRO: restauracao tecnica concluida, mas o conjunto excede o RPO de 7 dias.\n' >&2
  exit 3
fi
printf 'TESTE_DADOS_APROVADO. Evidencias e arquivos privados: %s\n' "$work"
