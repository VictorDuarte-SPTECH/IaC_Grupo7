#!/usr/bin/env bash
set -euo pipefail

test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
template="$test_dir/../cloudformationCodeTracker.yaml"
helper=$(awk '/^      Script: \|/ { extracting = 1; next } extracting && /^Resources:/ { exit } extracting { sub(/^        /, ""); sub(/\r$/, ""); print }' "$template")
[[ -n "$helper" ]]
printf '%s\n' "$helper" | bash -n
cfn-lint "$template"

run_case() {
  local scenario="$1"
  local output exit_status=0
  output=$(
    {
      printf '%s\n' \
        'BOOTSTRAP_RESOURCE=TestNode' \
        'BOOTSTRAP_SIGNAL_URL=https://example.invalid/signal' \
        'SECONDS=0' \
        'update_calls=0' \
        'timeout() {' \
        '  if [[ "$*" == *" update" ]]; then' \
        '    update_calls=$((update_calls + 1))' \
        '    printf "APT_ATTEMPT=%s\n" "$update_calls"' \
        '    [[ "$*" == *Acquire::ForceIPv4=true* && "$*" == *Acquire::Retries=0* && "$*" == *APT::Update::Error-Mode=any* ]] || exit 99' \
        '    if [[ "$CASE_MODE" == failure-window || "$CASE_MODE" == failure-offline ]]; then' \
        '      SECONDS=$((SECONDS + $3))' \
        '      return 124' \
        '    fi' \
        '    if [[ "$CASE_MODE" == recovery ]]; then' \
        '      if (( update_calls == 1 )); then printf "Temporary repository error\n" >&2; return 100; fi' \
        '      if (( update_calls == 2 )); then return 124; fi' \
        '    fi' \
        '    return 0' \
        '  fi' \
        '  printf "PACKAGE_INSTALL\n"' \
        '  [[ "$*" == *DPkg::Lock::Timeout=120* ]] || exit 99' \
        '  if [[ "$CASE_MODE" == failure-packages ]]; then return 124; fi' \
        '}' \
        'sleep() { SECONDS=$((SECONDS + $1)); }' \
        'curl() {' \
        '  if [[ "$CASE_MODE" == failure-offline || "$CASE_MODE" == failure-signal ]]; then return 28; fi' \
        '  while (( $# > 0 )); do' \
        '    if [[ "$1" == --data-binary ]]; then printf "SIGNAL=%s\n" "$2"; return 0; fi' \
        '    shift' \
        '  done' \
        '  return 1' \
        '}'
      printf '%s\n' "$helper"
      printf '%s\n' 'install_packages docker.io' 'printf "CONFIGURATION_REACHED\n"'
    } | CASE_MODE="$scenario" bash 2>&1
  ) || exit_status=$?

  case "$scenario" in
    success|recovery)
      [[ "$exit_status" == 0 ]]
      [[ "$output" == *CONFIGURATION_REACHED* && "$output" == *'"Status":"SUCCESS"'* ]]
      if [[ "$scenario" == recovery ]]; then
        [[ "$output" == *APT_ATTEMPT=3* && "$output" == *'codigo 100'* && "$output" == *'codigo 124'* ]]
      fi
      ;;
    failure-window|failure-offline)
      [[ "$exit_status" != 0 ]]
      [[ "$output" != *PACKAGE_INSTALL* && "$output" != *CONFIGURATION_REACHED* ]]
      [[ "$output" == *'janela de 600 segundos'* ]]
      if [[ "$scenario" == failure-window ]]; then
        [[ "$output" == *'"Status":"FAILURE"'* && "$output" == *'"Reason":"TestNode: apt-update-exhausted"'* ]]
      else
        [[ "$output" == *'sinal de falha nao entregue'* ]]
      fi
      ;;
    failure-packages)
      [[ "$exit_status" == 124 ]]
      [[ "$output" != *CONFIGURATION_REACHED* && "$output" == *'"Status":"FAILURE"'* ]]
      [[ "$output" == *'"Reason":"TestNode: packages"'* ]]
      ;;
    failure-signal)
      [[ "$exit_status" != 0 && "$output" == *'sinal de sucesso ao CloudFormation'* ]]
      ;;
  esac
  printf 'PASS: %s\n' "$scenario"
}

for scenario in success recovery failure-window failure-offline failure-packages failure-signal; do
  run_case "$scenario"
done

for resource in SwarmManagerInstance BackendInstanceAz1 BackendInstanceAz2 RabbitMqInstance DatabaseInstance WebInstanceAz1 WebInstanceAz2; do
  script=$(awk -v resource="$resource" -v helper="$helper" '
    $0 ~ "^  " resource ":" { selected = 1; next }
    selected && /^  [A-Za-z][A-Za-z0-9]*:/ { exit }
    selected && /^        - \|/ { extracting = 1; next }
    extracting && /^        - BootstrapScript:/ { exit }
    extracting {
      sub(/^          /, "")
      sub(/\r$/, "")
      if ($0 == "${BootstrapScript}") print helper
      else print
    }
  ' "$template")
  [[ "$script" == *"BOOTSTRAP_RESOURCE=$resource"* ]]
  printf '%s\n' "$script" | bash -n
  [[ $(printf '%s' "$script" | wc -c) -lt 16384 ]]
done
printf 'PASS: sete scripts compostos validos e abaixo de 16 KiB antes da substituicao de parametros\n'