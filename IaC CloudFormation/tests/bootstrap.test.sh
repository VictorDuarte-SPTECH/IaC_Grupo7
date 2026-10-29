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
        'install_calls=0' \
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
        '  install_calls=$((install_calls + 1))' \
        '  if [[ "$CASE_MODE" == install-recovery && "$install_calls" == 1 ]]; then return 100; fi' \
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
    success|recovery|install-recovery)
      [[ "$exit_status" == 0 ]]
      [[ "$output" == *CONFIGURATION_REACHED* && "$output" == *'"Status":"SUCCESS"'* ]]
      if [[ "$scenario" == recovery ]]; then
        [[ "$output" == *APT_ATTEMPT=3* && "$output" == *'codigo 100'* && "$output" == *'codigo 124'* ]]
      fi
      if [[ "$scenario" == install-recovery ]]; then
        [[ $(printf '%s\n' "$output" | grep -c '^PACKAGE_INSTALL$') == 2 ]]
        [[ "$output" == *'APT install: tentativa 1 falhou (codigo 100)'* ]]
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
      [[ "$output" == *'janela de 600 segundos da instalacao esgotada'* ]]
      ;;
    failure-signal)
      [[ "$exit_status" != 0 && "$output" == *'sinal de sucesso ao CloudFormation'* ]]
      ;;
  esac
  printf 'PASS: %s\n' "$scenario"
}

for scenario in success recovery install-recovery failure-window failure-offline failure-packages failure-signal; do
  run_case "$scenario"
done

manager_service=$(awk '
  { sub(/\r$/, "") }
  /^          cat > \/usr\/local\/sbin\/label-swarm-workers <<'\''SCRIPT'\''/ { extracting = 1; next }
  extracting && /^          SCRIPT$/ { exit }
  extracting { sub(/^          /, ""); sub(/\r$/, ""); print }
' "$template")
[[ -n "$manager_service" ]]
printf '%s\n' "$manager_service" | bash -n

run_manager_case() {
  local scenario="$1"
  local output exit_status=0
  output=$(
    {
      printf '%s\n' \
        'WORKERS_AVAILABLE=false' \
        'SLEEP_COUNT=0' \
        'sleep() { SLEEP_COUNT=$((SLEEP_COUNT + 1)); if [[ "$CASE_MODE" != workers-timeout ]]; then WORKERS_AVAILABLE=true; fi; }' \
        'docker() {' \
        '  case "$1 $2" in' \
        '    "node ls")' \
        '      if [[ "$WORKERS_AVAILABLE" == true ]]; then' \
        '        if [[ "$CASE_MODE" != backend-timeout || "$*" != *name=backend-* ]]; then printf "node-id Ready\n"; fi' \
        '      fi ;;' \
        '    "node update") printf "NODE_UPDATED\n" >&2 ;;' \
        '    "service ls")' \
        '      if [[ "$*" == *"{{.Name}} {{.Replicas}}"* ]]; then' \
        '        if [[ "$CASE_MODE" == backend-short ]]; then printf "codetracker_backend 2/4 (max 2 per node)\n"; else printf "codetracker_backend 4/4 (max 2 per node)\n"; fi' \
        '        printf "codetracker_frontend 2/2 (max 1 per node)\n"' \
        '        if [[ "$CASE_MODE" == etiquetas-short ]]; then printf "codetracker_etiquetas 1/2 (max 1 per node)\n"; else printf "codetracker_etiquetas 2/2 (max 1 per node)\n"; fi' \
        '      else printf "SERVICE_LIST\n"; fi ;;' \
        '    "run --rm") return 1 ;;' \
        '    "stack deploy") : ;;' \
        '    *) return 1 ;;' \
        '  esac' \
        '}' \
        'curl() {' \
        '  printf "HTTP_CHECK=%s\n" "${*: -1}" >&2' \
        '  case "${*: -1}" in' \
        '    */api/) if [[ "$CASE_MODE" == api-failure ]]; then printf "503"; else printf "401"; fi ;;' \
        '    */etiquetas-api/) printf "404" ;;' \
        '    */) return 0 ;;' \
        '    *) return 1 ;;' \
        '  esac' \
        '}' \
        'aws() {' \
        '  if [[ "$1 $2" == "ssm get-parameter" ]]; then printf "%s\n" '\''${AWS::StackId}'\''; return; fi' \
        '  if [[ "$1 $2" == "cloudformation signal-resource" ]]; then printf "SIGNAL=%s\n" "${*: -1}"; return; fi' \
        '  return 1' \
        '}'
      printf '%s\n' "$manager_service"
    } | CASE_MODE="$scenario" bash 2>&1
  ) || exit_status=$?

  case "$scenario" in
    recovery)
      [[ "$exit_status" == 0 && "$output" == *SIGNAL=SUCCESS* ]]
      [[ "$output" != *SIGNAL=FAILURE* && "$output" == *NODE_UPDATED* ]]
      [[ "$output" == *'HTTP_CHECK=http://${ApplicationLoadBalancer.DNSName}/api/'* ]]
      ;;
    workers-timeout|backend-timeout)
      [[ "$exit_status" != 0 && "$output" == *SIGNAL=FAILURE* ]]
      [[ "$output" == *'workers previstos nao ficaram prontos'* && "$output" != *SIGNAL=SUCCESS* ]]
      ;;
    api-failure|backend-short|etiquetas-short)
      [[ "$exit_status" != 0 && "$output" == *SIGNAL=FAILURE* ]]
      [[ "$output" != *SIGNAL=SUCCESS* ]]
      ;;
  esac
  printf 'PASS: manager %s\n' "$scenario"
}

run_manager_case recovery
run_manager_case workers-timeout
run_manager_case api-failure
run_manager_case backend-short
run_manager_case etiquetas-short
run_manager_case backend-timeout

run_broker_case() {
  local resource="$1" scenario="$2" broker_script output exit_status=0
  broker_script=$(awk -v resource="$resource" '
    { sub(/\r$/, "") }
    $0 ~ "^  " resource ":" { selected = 1; next }
    selected && /^  [A-Za-z][A-Za-z0-9]*:/ { exit }
    selected && /^          BOOTSTRAP_STAGE=rabbitmq-start$/ { extracting = 1 }
    extracting && /^          BOOTSTRAP_STAGE=swarm-worker-join$/ { exit }
    extracting { sub(/^          /, ""); print }
  ' "$template")
  [[ -n "$broker_script" ]]
  output=$(
    {
      printf '%s\n' \
        'set -euo pipefail' \
        'sleep() { :; }' \
        'docker() {' \
        '  case "$1 $2" in' \
        '    "volume create") [[ "$3" == rabbitmq-data ]] ;;' \
        '    "run --detach")' \
        '      [[ "$*" == *"--memory 1g"* && "$*" == *"--publish 127.0.0.1:15672:15672"* && "$*" == *"--volume rabbitmq-data:/var/lib/rabbitmq"* ]] || return 1' \
        '      printf "BROKER_STARTED\n" ;;' \
        '    "inspect --format") if [[ "$CASE_MODE" == healthy ]]; then printf healthy; else printf unhealthy; fi ;;' \
        '    *) return 1 ;;' \
        '  esac' \
        '}'
      printf '%s\n' "$broker_script"
    } | CASE_MODE="$scenario" bash 2>&1
  ) || exit_status=$?
  [[ "$output" == *BROKER_STARTED* ]]
  if [[ "$scenario" == healthy ]]; then
    [[ "$exit_status" == 0 ]]
  else
    [[ "$exit_status" != 0 && "$output" == *'nao ficou saudavel'* ]]
  fi
  printf 'PASS: broker %s %s\n' "$resource" "$scenario"
}

for resource in BackendInstanceAz1 BackendInstanceAz2; do
  run_broker_case "$resource" healthy
  run_broker_case "$resource" unhealthy
done

run_join_case() {
  local resource="$1" scenario="$2"
  local join_script output exit_status=0
  join_script=$(awk -v resource="$resource" '
    { sub(/\r$/, "") }
    $0 ~ "^  " resource ":" { selected = 1; next }
    selected && /^  [A-Za-z][A-Za-z0-9]*:/ { exit }
    selected && /^          BOOTSTRAP_STAGE=swarm-worker-join$/ { extracting = 1 }
    extracting && /^        - BootstrapScript:/ { exit }
    extracting { sub(/^          /, ""); print }
  ' "$template")
  [[ -n "$join_script" ]]
  output=$(
    {
      printf '%s\n' \
        'set -euo pipefail' \
        'JOINED=false' \
        'REGION=us-east-1' \
        'sleep() { :; }' \
        'aws() {' \
        '  case "$*" in' \
        '    *swarm/stack-id*) if [[ "$CASE_MODE" == stale-stack ]]; then printf "other-stack"; else printf "%s" '\''${AWS::StackId}'\''; fi ;;' \
        '    *swarm/manager-ip*) printf "10.0.0.68" ;;' \
        '    *swarm/worker-token*) [[ "$*" == *--with-decryption* ]] || return 1; printf "test-worker-token" ;;' \
        '    *) return 1 ;;' \
        '  esac' \
        '}' \
        'docker() {' \
        '  case "$1 $2" in' \
        '    "info --format")' \
        '      if [[ "$3" == "{{.Swarm.LocalNodeState}}" ]]; then' \
        '        if [[ "$JOINED" == true ]]; then printf active; else printf inactive; fi' \
        '      else return 1; fi ;;' \
        '    "swarm join")' \
        '      printf "JOIN_ATTEMPT\n"' \
        '      [[ "$CASE_MODE" != join-failure && "$*" == *"--token test-worker-token 10.0.0.68:2377"* && "$*" != *--availability* ]] || return 1' \
        '      JOINED=true ;;' \
        '    *) return 1 ;;' \
        '  esac' \
        '}'
      printf '%s\n' "$join_script"
    } | CASE_MODE="$scenario" bash 2>&1
  ) || exit_status=$?
  if [[ "$scenario" == success ]]; then
    [[ "$exit_status" == 0 && "$output" == *JOIN_ATTEMPT* ]]
  else
    [[ "$exit_status" != 0 && "$output" == *'Nao foi possivel adicionar'* ]]
    if [[ "$scenario" == stale-stack ]]; then [[ "$output" != *JOIN_ATTEMPT* ]]; fi
  fi
  [[ "$output" != *test-worker-token* ]]
  printf 'PASS: join %s %s\n' "$resource" "$scenario"
}

for scenario in success stale-stack join-failure; do
  run_join_case BackendInstanceAz1 "$scenario"
  run_join_case BackendInstanceAz2 "$scenario"
done

etiquetas_service=$(awk '
  { sub(/\r$/, "") }
  /^            etiquetas:$/ { extracting = 1 }
  extracting && /^            frontend:$/ { exit }
  extracting { print }
' "$template")
[[ "$etiquetas_service" == *'replicas: 2'* ]]
[[ "$etiquetas_service" == *'constraints: [node.labels.tier == backend]'* ]]
[[ "$etiquetas_service" == *'max_replicas_per_node: 1'* ]]
for resource in BackendInstanceAz1 BackendInstanceAz2; do
  instance=$(awk -v resource="$resource" '
    $0 ~ "^  " resource ":" { selected = 1; next }
    selected && /^  [A-Za-z][A-Za-z0-9]*:/ { exit }
    selected { print }
  ' "$template")
  for ingress in SwarmManagementIngress SwarmDiscoveryTcpIngress SwarmDiscoveryUdpIngress SwarmOverlayIngress; do
    [[ "$instance" == *"- $ingress"* ]]
  done
  [[ "$instance" == *'- !Ref SwarmSecurityGroup'* ]]
  [[ "$instance" == *'- !Ref RabbitMqSecurityGroup'* ]]
  [[ "$instance" != *'docker swarm init'* ]]
  [[ "$instance" == *'--volume rabbitmq-data:/var/lib/rabbitmq'* ]]
  [[ "$instance" == *'install_aws_cli'* ]]
done
printf 'PASS: RabbitMQ e etiquetas em cada worker backend\n'

instance=$(awk '
  /^  SwarmManagerInstance:/ { selected = 1; next }
  selected && /^  [A-Za-z][A-Za-z0-9]*:/ { exit }
  selected { print }
' "$template")
[[ "$instance" == *'SubnetId: !Ref WebSubnetAz1'* ]]
[[ "$instance" == *'- WebSubnetAz1RouteTableAssociation'* ]]
[[ "$instance" == *'- PrivateDefaultRouteAz1'* ]]
[[ "$instance" == *'AssociatePublicIpAddress: false'* ]]
[[ "$instance" == *'- !Ref PrivateSshSecurityGroup'* ]]
[[ "$instance" == *'- !Ref SwarmSecurityGroup'* ]]
[[ "$instance" != *'- !Ref WebSecurityGroup'* ]]
[[ "$instance" == *'--availability drain'* ]]
! grep -Eq 'SwarmManagerInstanceAz2|MANAGER_AZ2_ID|swarm/manager-token' "$template"
! grep -Eq '^  RabbitMqInstance(Az2)?:|EnableRabbitMq' "$template"
[[ $(grep -c 'Type: AWS::EC2::Instance' "$template") == 8 ]]
printf 'PASS: manager unico e oito EC2, sem hosts RabbitMQ dedicados\n'

backend_service=$(awk '
  { sub(/\r$/, "") }
  /^            backend:$/ { extracting = 1 }
  extracting && /^            etiquetas:$/ { exit }
  extracting { print }
' "$template")
[[ "$backend_service" == *'replicas: 4'* ]]
[[ "$backend_service" == *'endpoint_mode: vip'* ]]
[[ "$backend_service" == *'constraints: [node.labels.tier == backend]'* ]]
[[ "$backend_service" == *'max_replicas_per_node: 2'* ]]
for resource in BackendInstanceAz1 BackendInstanceAz2; do
  instance=$(awk -v resource="$resource" '
    $0 ~ "^  " resource ":" { selected = 1; next }
    selected && /^  [A-Za-z][A-Za-z0-9]*:/ { exit }
    selected { print }
  ' "$template")
  [[ "$instance" == *'InstanceType: !Ref BackendInstanceType'* ]]
done
grep -Fq 'Default: t3.small' "$template"
printf 'PASS: quatro backends, dois por VM t3.medium por padrao, com VIP\n'

for parameter in InstanceType BackendInstanceType DatabaseInstanceType FrontendInstanceType; do
  expected_type=t3.micro
  if [[ "$parameter" == InstanceType ]]; then expected_type=t3.small; fi
  if [[ "$parameter" == BackendInstanceType ]]; then expected_type=t3.medium; fi
  definition=$(awk -v parameter="$parameter" '
    $0 ~ "^  " parameter ":" { selected = 1; next }
    selected && /^  [A-Za-z][A-Za-z0-9]*:/ { exit }
    selected { print }
  ' "$template")
  [[ "$definition" == *"Default: $expected_type"* ]]
done

admin_setup=$(awk '
  { sub(/\r$/, "") }
  /^          BOOTSTRAP_STAGE=admin-account$/ { extracting = 1 }
  extracting && /^          BOOTSTRAP_STAGE=configuration$/ { print "BOOTSTRAP_STAGE=configuration"; exit }
  extracting { sub(/^          /, ""); sub(/\r$/, ""); print }
' "$template" | sed -e 's/${AdminPassword}/TestAdminPassword123/g' -e 's/${DatabaseName}/lamar/g')
[[ -n "$admin_setup" ]]
printf '%s\n' "$admin_setup" | bash -n

for row_count in 1 0; do
  exit_status=0
  output=$(
    {
      printf '%s\n' \
        'htpasswd() {' \
        '  [[ "$*" == "-niB -C 10 admin" ]] || return 1' \
        '  IFS= read -r password' \
        '  [[ "$password" == TestAdminPassword123 ]] || return 1' \
        '  printf "admin:\$2y\$10\$examplehash\n"' \
        '}' \
        'mysql() {' \
        '  [[ "$*" == *"--database=lamar"* ]] || return 1' \
        '  query=$(cat)' \
        '  [[ "$query" == *"senha = "* && "$query" == *examplehash* ]] || return 1' \
        '  [[ "$query" == *"email = '\''admin@teste.com'\''"* && "$query" == *"ROLE_ADMIN"* ]] || return 1' \
        '  [[ "$query" != *TestAdminPassword123* ]] || return 1' \
        '  printf "%s\n" "$ROW_COUNT"' \
        '}'
      printf '%s\n' "$admin_setup"
    } | ROW_COUNT="$row_count" bash -e 2>&1
  ) || exit_status=$?
  [[ "$output" != *TestAdminPassword123* ]]
  if [[ "$row_count" == 1 ]]; then
    [[ "$exit_status" == 0 ]]
  else
    [[ "$exit_status" != 0 && "$output" == *'ROLE_ADMIN nao encontrado'* ]]
  fi
done
printf 'PASS: senha do administrador com BCrypt e falha se usuario nao existir\n'

for resource in BastionInstance SwarmManagerInstance BackendInstanceAz1 BackendInstanceAz2 DatabaseInstance DatabaseStandbyInstance WebInstanceAz1 WebInstanceAz2; do
  script=$(awk -v resource="$resource" '
    $0 ~ "^  " resource ":" { selected = 1; next }
    selected && /^  [A-Za-z][A-Za-z0-9]*:/ { exit }
    selected && /^        - \|/ { extracting = 1; next }
    extracting && /^        - BootstrapScript:/ { exit }
    extracting {
      sub(/^          /, "")
      sub(/\r$/, "")
      if ($0 == "${BootstrapScript}") print "SHELL_HELPER_MARKER"
      else print
    }
  ' "$template")
  script=${script/SHELL_HELPER_MARKER/$helper}
  [[ "$script" == *"BOOTSTRAP_RESOURCE=$resource"* ]]
  [[ "$script" != *'fluent-bit'* ]]
  printf '%s\n' "$script" | bash -n
  [[ $(printf '%s' "$script" | wc -c) -lt 16384 ]]
  instance=$(awk -v resource="$resource" '
    { sub(/\r$/, "") }
    $0 ~ "^  " resource ":" { selected = 1; next }
    selected && /^  [A-Za-z][A-Za-z0-9]*:/ { exit }
    selected { print }
  ' "$template")
  [[ "$instance" == *'IamInstanceProfile: !Ref InstanceProfileName'* ]]
  [[ "$instance" != *'BronzeLogsWritePolicy'* ]]
  case "$resource" in
    DatabaseInstance|DatabaseStandbyInstance) expected_parameter=DatabaseInstanceType ;;
    WebInstanceAz1|WebInstanceAz2) expected_parameter=FrontendInstanceType ;;
    BackendInstanceAz1|BackendInstanceAz2) expected_parameter=BackendInstanceType ;;
    *) expected_parameter=InstanceType ;;
  esac
  [[ "$instance" == *"InstanceType: !Ref $expected_parameter"$'\n'* ]]
done
printf 'PASS: quatro t3.micro, dois t3.small e dois t3.medium\n'
grep -Fq 'Count: 8' "$template"
! grep -Eiq 'fluent.?bit|BronzeLogs|AWS::S3::Bucket|s3:PutObject' "$template"
printf 'PASS: oito scripts validos sem Fluent Bit nem acesso a buckets\n'
grep -Fq 'systemctl start --no-block label-swarm-workers.service' "$template"
alb_dependencies=$(awk '/^  ApplicationLoadBalancer:/ { extracting = 1; next } extracting && /^    Properties:/ { exit } extracting { print }' "$template")
[[ "$alb_dependencies" == *InternetGatewayAttachment* && "$alb_dependencies" == *PublicDefaultRoute* ]]
grep -Fq "'http://\${ApplicationLoadBalancer.DNSName}/api/'" "$template"
! grep -Fq 'docker run --rm --network codetracker_application' "$template"
grep -Fq 'docker swarm init --advertise-addr "$PRIVATE_IP" > /dev/null' "$template"
grep -Fq "cat > /etc/mysql/mysql.conf.d/zz-lamar-network.cnf" "$template"
grep -Fq "SELECT @@global.bind_address;" "$template"
grep -Fq 'BOOTSTRAP_STAGE=database-import' "$template"
grep -Fq 'git clone --depth 1 https://github.com/EnzoServilha/Banco_Grupo7.git "$CLONE_DIR/repo"' "$template"
grep -Fq -- '--logical-resource-id SwarmManagerInstance' "$template"
grep -Fq -- '--status FAILURE' "$template"
grep -Fq "DB_HOST: '\${DatabaseEndpointRecord}'" "$template"
grep -Fq 'OnCalendar=*-*-* 00,12:00:00 UTC' "$template"
grep -Fq 'OnUnitInactiveSec=30s' "$template"
grep -Fq 'SPRING_RABBITMQ_ADDRESSES:' "$template"
grep -Fq "'/\${EnvironmentName}/database/standby-ready'" "$template"
printf 'PASS: oito scripts compostos validos e abaixo de 16 KiB antes da substituicao de parametros\n'
