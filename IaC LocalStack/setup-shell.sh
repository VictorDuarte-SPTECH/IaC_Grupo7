#!/bin/bash

#Autor: Victor
#Data: 30/08/2026
#Versão: 1.0.0

#Modo uso: bash setup-shell.sh

# Este comando interrompe o script caso dê algum erro ao invés de continuar
set -e

# --------------------------------------------------
# Arquitetura AWS para localstack - Grupo 7
#
# VPC: 10.0.0.0/25
#
# us-east-1a
#   Public A     10.0.0.0/28
#   Frontend A   10.0.0.32/27
#   Backend A    10.0.0.96/28
#
# us-east-1b
#   Public B     10.0.0.16/28
#   Frontend B   10.0.0.64/27
#   Backend B    10.0.0.112/28
#
# Componentes simulados:
# - VPC
# - Internet Gateway
# - NAT Gateways
# - Subnets
# - Route Tables
# - Security Groups
# - EC2
# - EBS
# - S3
# - CloudWatch
# - SNS
# - IAM
#
# Observação: Devido às limitações do LocalStack,
#             o recurso ELB não foram empregado 
#             neste script.
# --------------------------------------------------

# --------------------------------------------------
# --- CONFIGURAÇÕES ---
# --------------------------------------------------

REGION="us-east-1"
ENDPOINT="http://localhost:4566"
VPC_CIDR="10.0.0.0/25"


# --------------------------------------------------
# --- FUNÇÃO AUXILIAR ---
# --------------------------------------------------
aws_local() {
    aws --endpoint-url="${ENDPOINT}" \
        --region="${REGION}" \
        "$@"
}


# --------------------------------------------------
# --- CABEÇALHO NO TERMINAL ---
# --------------------------------------------------

echo ""
echo "--------------------------------------------------"
echo "   AWS LOCALSTACK - GESTÃO DE ESTOQUE AUTOPEÇAS"
echo "--------------------------------------------------"
echo ""
echo "Região: ${REGION}"
echo "VPC:    ${VPC_CIDR}"
echo "Endpoint: ${ENDPOINT}"
echo ""



# --------------------------------------------------
# --- 1. VERIFICAR DEPENDÊNCIAS ---
# --------------------------------------------------

echo "[1/13] Verificando dependências..."

if ! command -v aws >/dev/null 2>&1; then
    echo "ERRO: AWS CLI não encontrada."
    echo "Instale a AWS CLI antes de executar este script."
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "ERRO: curl não encontrado."
    exit 1
fi

echo "AWS CLI encontrada."
echo "Dependências OK."


# --------------------------------------------------
# --- 2. AGUARDAR LOCALSTACK ---
# --------------------------------------------------

echo ""
echo "[2/13] Aguardando LocalStack..."

MAX_ATTEMPTS=15
ATTEMPT=0

until curl -s "${ENDPOINT}/_localstack/health" >/dev/null 2>&1; do

    ATTEMPT=$((ATTEMPT + 1))

    if [ "${ATTEMPT}" -ge "${MAX_ATTEMPTS}" ]; then
        echo ""
        echo "ERRO: LocalStack não ficou disponível."
        echo ""
        echo "Execute primeiro:"
        echo "docker compose up -d"
        exit 1
    fi

    echo "Aguardando LocalStack..."
    sleep 2

done

echo "LocalStack disponível."


# --------------------------------------------------
# --- 3. VPC ---
# --------------------------------------------------

echo ""
echo "[3/13] Criando VPC..."

VPC_ID=$(aws_local ec2 create-vpc \
    --cidr-block "${VPC_CIDR}" \
    --tag-specifications \
    'ResourceType=vpc,Tags=[{Key=Name,Value=estoque-autopecas-vpc}]' \
    --query 'Vpc.VpcId' \
    --output text)

echo "VPC criada: ${VPC_ID}"


# Habilitar DNS da VPC

aws_local ec2 modify-vpc-attribute \
    --vpc-id "${VPC_ID}" \
    --enable-dns-support "{\"Value\":true}"

aws_local ec2 modify-vpc-attribute \
    --vpc-id "${VPC_ID}" \
    --enable-dns-hostnames "{\"Value\":true}"

echo "DNS da VPC habilitado."


# --------------------------------------------------
# --- 4. INTERNET GATEWAY ---
# --------------------------------------------------

echo ""
echo "[4/13] Criando Internet Gateway..."

IGW_ID=$(aws_local ec2 create-internet-gateway \
    --tag-specifications \
    'ResourceType=internet-gateway,Tags=[{Key=Name,Value=estoque-autopecas-igw}]' \
    --query 'InternetGateway.InternetGatewayId' \
    --output text)

echo "Internet Gateway criado: ${IGW_ID}"


aws_local ec2 attach-internet-gateway \
    --vpc-id "${VPC_ID}" \
    --internet-gateway-id "${IGW_ID}"

echo "Internet Gateway associado à VPC."


# --------------------------------------------------
# --- 5. SUBNETS ---
# --------------------------------------------------

echo ""
echo "[5/13] Criando subnets..."


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# us-east-1a
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

echo "Criando subnets da us-east-1a..."


PUBLIC_A_ID=$(aws_local ec2 create-subnet \
    --vpc-id "${VPC_ID}" \
    --cidr-block "10.0.0.0/28" \
    --availability-zone "us-east-1a" \
    --tag-specifications \
    'ResourceType=subnet,Tags=[{Key=Name,Value=subnet-publica-1a},{Key=Tier,Value=public}]' \
    --query 'Subnet.SubnetId' \
    --output text)


FRONTEND_A_ID=$(aws_local ec2 create-subnet \
    --vpc-id "${VPC_ID}" \
    --cidr-block "10.0.0.32/27" \
    --availability-zone "us-east-1a" \
    --tag-specifications \
    'ResourceType=subnet,Tags=[{Key=Name,Value=subnet-frontend-1a},{Key=Tier,Value=frontend}]' \
    --query 'Subnet.SubnetId' \
    --output text)


BACKEND_A_ID=$(aws_local ec2 create-subnet \
    --vpc-id "${VPC_ID}" \
    --cidr-block "10.0.0.96/28" \
    --availability-zone "us-east-1a" \
    --tag-specifications \
    'ResourceType=subnet,Tags=[{Key=Name,Value=subnet-backend-1a},{Key=Tier,Value=backend}]' \
    --query 'Subnet.SubnetId' \
    --output text)


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# us-east-1b
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

echo "Criando subnets da us-east-1b..."


PUBLIC_B_ID=$(aws_local ec2 create-subnet \
    --vpc-id "${VPC_ID}" \
    --cidr-block "10.0.0.16/28" \
    --availability-zone "us-east-1b" \
    --tag-specifications \
    'ResourceType=subnet,Tags=[{Key=Name,Value=subnet-publica-1b},{Key=Tier,Value=public}]' \
    --query 'Subnet.SubnetId' \
    --output text)


FRONTEND_B_ID=$(aws_local ec2 create-subnet \
    --vpc-id "${VPC_ID}" \
    --cidr-block "10.0.0.64/27" \
    --availability-zone "us-east-1b" \
    --tag-specifications \
    'ResourceType=subnet,Tags=[{Key=Name,Value=subnet-frontend-1b},{Key=Tier,Value=frontend}]' \
    --query 'Subnet.SubnetId' \
    --output text)


BACKEND_B_ID=$(aws_local ec2 create-subnet \
    --vpc-id "${VPC_ID}" \
    --cidr-block "10.0.0.112/28" \
    --availability-zone "us-east-1b" \
    --tag-specifications \
    'ResourceType=subnet,Tags=[{Key=Name,Value=subnet-backend-1b},{Key=Tier,Value=backend}]' \
    --query 'Subnet.SubnetId' \
    --output text)


echo ""
echo "Subnets criadas:"
echo "  Public A:   ${PUBLIC_A_ID}  10.0.0.0/28"
echo "  Frontend A: ${FRONTEND_A_ID}  10.0.0.32/27"
echo "  Backend A:  ${BACKEND_A_ID}  10.0.0.96/28"
echo "  Public B:   ${PUBLIC_B_ID}  10.0.0.16/28"
echo "  Frontend B: ${FRONTEND_B_ID}  10.0.0.64/27"
echo "  Backend B:  ${BACKEND_B_ID}  10.0.0.112/28"


# --------------------------------------------------
# --- 6. ROUTE TABLES ---
# --------------------------------------------------

echo ""
echo "[6/13] Criando Route Tables..."


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Route Table Pública
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

PUBLIC_RT_ID=$(aws_local ec2 create-route-table \
    --vpc-id "${VPC_ID}" \
    --tag-specifications \
    'ResourceType=route-table,Tags=[{Key=Name,Value=public-route-table}]' \
    --query 'RouteTable.RouteTableId' \
    --output text)

echo "Public Route Table: ${PUBLIC_RT_ID}"


aws_local ec2 create-route \
    --route-table-id "${PUBLIC_RT_ID}" \
    --destination-cidr-block "0.0.0.0/0" \
    --gateway-id "${IGW_ID}" \
    >/dev/null


aws_local ec2 associate-route-table \
    --route-table-id "${PUBLIC_RT_ID}" \
    --subnet-id "${PUBLIC_A_ID}" \
    >/dev/null


aws_local ec2 associate-route-table \
    --route-table-id "${PUBLIC_RT_ID}" \
    --subnet-id "${PUBLIC_B_ID}" \
    >/dev/null


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Route Table Frontend A
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

FRONTEND_RT_A_ID=$(aws_local ec2 create-route-table \
    --vpc-id "${VPC_ID}" \
    --tag-specifications \
    'ResourceType=route-table,Tags=[{Key=Name,Value=private-route-table-frontend-a}]' \
    --query 'RouteTable.RouteTableId' \
    --output text)


aws_local ec2 associate-route-table \
    --route-table-id "${FRONTEND_RT_A_ID}" \
    --subnet-id "${FRONTEND_A_ID}" \
    >/dev/null


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Route Table Frontend B
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

FRONTEND_RT_B_ID=$(aws_local ec2 create-route-table \
    --vpc-id "${VPC_ID}" \
    --tag-specifications \
    'ResourceType=route-table,Tags=[{Key=Name,Value=private-route-table-frontend-b}]' \
    --query 'RouteTable.RouteTableId' \
    --output text)


aws_local ec2 associate-route-table \
    --route-table-id "${FRONTEND_RT_B_ID}" \
    --subnet-id "${FRONTEND_B_ID}" \
    >/dev/null


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Route Table Backend A
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

BACKEND_RT_A_ID=$(aws_local ec2 create-route-table \
    --vpc-id "${VPC_ID}" \
    --tag-specifications \
    'ResourceType=route-table,Tags=[{Key=Name,Value=private-route-table-backend-a}]' \
    --query 'RouteTable.RouteTableId' \
    --output text)


aws_local ec2 associate-route-table \
    --route-table-id "${BACKEND_RT_A_ID}" \
    --subnet-id "${BACKEND_A_ID}" \
    >/dev/null


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Route Table Backend B
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

BACKEND_RT_B_ID=$(aws_local ec2 create-route-table \
    --vpc-id "${VPC_ID}" \
    --tag-specifications \
    'ResourceType=route-table,Tags=[{Key=Name,Value=private-route-table-backend-b}]' \
    --query 'RouteTable.RouteTableId' \
    --output text)


aws_local ec2 associate-route-table \
    --route-table-id "${BACKEND_RT_B_ID}" \
    --subnet-id "${BACKEND_B_ID}" \
    >/dev/null


echo "Route Tables criadas."


# --------------------------------------------------
# --- 7. NAT GATEWAYS ---
# --------------------------------------------------

echo ""
echo "[7/13] Criando NAT Gateways..."


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Elastic IP A
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

EIP_A_ALLOC_ID=$(aws_local ec2 allocate-address \
    --domain vpc \
    --tag-specifications \
    'ResourceType=elastic-ip,Tags=[{Key=Name,Value=eip-nat-a}]' \
    --query 'AllocationId' \
    --output text)


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# NAT Gateway A
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

NAT_A_ID=$(aws_local ec2 create-nat-gateway \
    --subnet-id "${PUBLIC_A_ID}" \
    --allocation-id "${EIP_A_ALLOC_ID}" \
    --tag-specifications \
    'ResourceType=natgateway,Tags=[{Key=Name,Value=nat-gateway-a}]' \
    --query 'NatGateway.NatGatewayId' \
    --output text 2>/dev/null || true)


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Elastic IP B
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

EIP_B_ALLOC_ID=$(aws_local ec2 allocate-address \
    --domain vpc \
    --tag-specifications \
    'ResourceType=elastic-ip,Tags=[{Key=Name,Value=eip-nat-b}]' \
    --query 'AllocationId' \
    --output text)


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# NAT Gateway B
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

NAT_B_ID=$(aws_local ec2 create-nat-gateway \
    --subnet-id "${PUBLIC_B_ID}" \
    --allocation-id "${EIP_B_ALLOC_ID}" \
    --tag-specifications \
    'ResourceType=natgateway,Tags=[{Key=Name,Value=nat-gateway-b}]' \
    --query 'NatGateway.NatGatewayId' \
    --output text 2>/dev/null || true)


if [ -n "${NAT_A_ID}" ] && [ "${NAT_A_ID}" != "None" ]; then

    echo "NAT Gateway A criado: ${NAT_A_ID}"

    aws_local ec2 create-route \
        --route-table-id "${FRONTEND_RT_A_ID}" \
        --destination-cidr-block "0.0.0.0/0" \
        --nat-gateway-id "${NAT_A_ID}" \
        >/dev/null 2>&1 || true

    aws_local ec2 create-route \
        --route-table-id "${BACKEND_RT_A_ID}" \
        --destination-cidr-block "0.0.0.0/0" \
        --nat-gateway-id "${NAT_A_ID}" \
        >/dev/null 2>&1 || true

else

    echo "AVISO: NAT Gateway A não pôde ser criado pelo ambiente local."

fi


if [ -n "${NAT_B_ID}" ] && [ "${NAT_B_ID}" != "None" ]; then

    echo "NAT Gateway B criado: ${NAT_B_ID}"

    aws_local ec2 create-route \
        --route-table-id "${FRONTEND_RT_B_ID}" \
        --destination-cidr-block "0.0.0.0/0" \
        --nat-gateway-id "${NAT_B_ID}" \
        >/dev/null 2>&1 || true

    aws_local ec2 create-route \
        --route-table-id "${BACKEND_RT_B_ID}" \
        --destination-cidr-block "0.0.0.0/0" \
        --nat-gateway-id "${NAT_B_ID}" \
        >/dev/null 2>&1 || true

else

    echo "AVISO: NAT Gateway B não pôde ser criado pelo ambiente local."

fi


# --------------------------------------------------
# --- 8. SECURITY GROUPS ---
# --------------------------------------------------

echo ""
echo "[8/13] Criando Security Groups..."


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Load Balancer
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

SG_LB_ID=$(aws_local ec2 create-security-group \
    --group-name "sg-load-balancer" \
    --description "Security Group do Load Balancer" \
    --vpc-id "${VPC_ID}" \
    --tag-specifications \
    'ResourceType=security-group,Tags=[{Key=Name,Value=sg-load-balancer}]' \
    --query 'GroupId' \
    --output text)


aws_local ec2 authorize-security-group-ingress \
    --group-id "${SG_LB_ID}" \
    --protocol tcp \
    --port 80 \
    --cidr "0.0.0.0/0" \
    >/dev/null 2>&1 || true


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Frontend
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

SG_FRONTEND_ID=$(aws_local ec2 create-security-group \
    --group-name "sg-frontend" \
    --description "Security Group do Frontend" \
    --vpc-id "${VPC_ID}" \
    --tag-specifications \
    'ResourceType=security-group,Tags=[{Key=Name,Value=sg-frontend}]' \
    --query 'GroupId' \
    --output text)


aws_local ec2 authorize-security-group-ingress \
    --group-id "${SG_FRONTEND_ID}" \
    --protocol tcp \
    --port 80 \
    --source-group "${SG_LB_ID}" \
    >/dev/null 2>&1 || true


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Backend
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

SG_BACKEND_ID=$(aws_local ec2 create-security-group \
    --group-name "sg-backend" \
    --description "Security Group do Backend" \
    --vpc-id "${VPC_ID}" \
    --tag-specifications \
    'ResourceType=security-group,Tags=[{Key=Name,Value=sg-backend}]' \
    --query 'GroupId' \
    --output text)


aws_local ec2 authorize-security-group-ingress \
    --group-id "${SG_BACKEND_ID}" \
    --protocol tcp \
    --port 8080 \
    --source-group "${SG_FRONTEND_ID}" \
    >/dev/null 2>&1 || true


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Banco
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

SG_DATABASE_ID=$(aws_local ec2 create-security-group \
    --group-name "sg-database" \
    --description "Security Group do Banco de Dados" \
    --vpc-id "${VPC_ID}" \
    --tag-specifications \
    'ResourceType=security-group,Tags=[{Key=Name,Value=sg-database}]' \
    --query 'GroupId' \
    --output text)


aws_local ec2 authorize-security-group-ingress \
    --group-id "${SG_DATABASE_ID}" \
    --protocol tcp \
    --port 3306 \
    --source-group "${SG_BACKEND_ID}" \
    >/dev/null 2>&1 || true


echo "Security Groups criados."


# --------------------------------------------------
# --- 9. EC2 ---
# --------------------------------------------------

echo ""
echo "[9/13] Criando instâncias EC2..."


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# AMI utilizada apenas como identificador local.
#
# O LocalStack pode trabalhar com AMIs mockadas para
# representar as instâncias.
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

AMI_ID="ami-12345678"


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# FRONTEND A
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

FRONTEND_A_INSTANCE=$(aws_local ec2 run-instances \
    --image-id "${AMI_ID}" \
    --instance-type "t3.micro" \
    --subnet-id "${FRONTEND_A_ID}" \
    --security-group-ids "${SG_FRONTEND_ID}" \
    --tag-specifications \
    'ResourceType=instance,Tags=[{Key=Name,Value=frontend-a},{Key=Role,Value=frontend},{Key=Environment,Value=local}]' \
    --query 'Instances[0].InstanceId' \
    --output text)


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# FRONTEND B
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

FRONTEND_B_INSTANCE=$(aws_local ec2 run-instances \
    --image-id "${AMI_ID}" \
    --instance-type "t3.micro" \
    --subnet-id "${FRONTEND_B_ID}" \
    --security-group-ids "${SG_FRONTEND_ID}" \
    --tag-specifications \
    'ResourceType=instance,Tags=[{Key=Name,Value=frontend-b},{Key=Role,Value=frontend},{Key=Environment,Value=local}]' \
    --query 'Instances[0].InstanceId' \
    --output text)


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# BACKEND A
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

BACKEND_A_INSTANCE=$(aws_local ec2 run-instances \
    --image-id "${AMI_ID}" \
    --instance-type "t3.micro" \
    --subnet-id "${BACKEND_A_ID}" \
    --security-group-ids "${SG_BACKEND_ID}" \
    --tag-specifications \
    'ResourceType=instance,Tags=[{Key=Name,Value=backend-a},{Key=Role,Value=backend},{Key=Environment,Value=local}]' \
    --query 'Instances[0].InstanceId' \
    --output text)


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# BACKEND B
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

BACKEND_B_INSTANCE=$(aws_local ec2 run-instances \
    --image-id "${AMI_ID}" \
    --instance-type "t3.micro" \
    --subnet-id "${BACKEND_B_ID}" \
    --security-group-ids "${SG_BACKEND_ID}" \
    --tag-specifications \
    'ResourceType=instance,Tags=[{Key=Name,Value=backend-b},{Key=Role,Value=backend},{Key=Environment,Value=local}]' \
    --query 'Instances[0].InstanceId' \
    --output text)


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# DATABASE A
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# DATABASE_A_INSTANCE=$(aws_local ec2 run-instances \
#     --image-id "${AMI_ID}" \
#     --instance-type "t3.micro" \
#     --subnet-id "${BACKEND_A_ID}" \
#     --security-group-ids "${SG_DATABASE_ID}" \
#     --tag-specifications \
#     'ResourceType=instance,Tags=[{Key=Name,Value=database-a},{Key=Role,Value=database},{Key=Environment,Value=local}]' \
#     --query 'Instances[0].InstanceId' \
#     --output text)


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# DATABASE B
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

DATABASE_B_INSTANCE=$(aws_local ec2 run-instances \
    --image-id "${AMI_ID}" \
    --instance-type "t3.micro" \
    --subnet-id "${BACKEND_B_ID}" \
    --security-group-ids "${SG_DATABASE_ID}" \
    --tag-specifications \
    'ResourceType=instance,Tags=[{Key=Name,Value=database-b},{Key=Role,Value=database},{Key=Environment,Value=local}]' \
    --query 'Instances[0].InstanceId' \
    --output text)


echo ""
echo "EC2 criadas:"
echo "  Frontend A: ${FRONTEND_A_INSTANCE}"
echo "  Frontend B: ${FRONTEND_B_INSTANCE}"
echo "  Backend A:  ${BACKEND_A_INSTANCE}"
echo "  Backend B:  ${BACKEND_B_INSTANCE}"
echo "  Database A: ${DATABASE_A_INSTANCE}"
echo "  Database B: ${DATABASE_B_INSTANCE}"


# --------------------------------------------------
# --- 10. EBS ---
# --------------------------------------------------

echo ""
echo "[10/13] Criando volumes EBS para os bancos..."


# EBS_A_ID=$(aws_local ec2 create-volume \
#     --availability-zone "us-east-1a" \
#     --size 20 \
#     --volume-type "gp3" \
#     --tag-specifications \
#     'ResourceType=volume,Tags=[{Key=Name,Value=ebs-database-a}]' \
#     --query 'VolumeId' \
#     --output text)


EBS_B_ID=$(aws_local ec2 create-volume \
    --availability-zone "us-east-1b" \
    --size 20 \
    --volume-type "gp3" \
    --tag-specifications \
    'ResourceType=volume,Tags=[{Key=Name,Value=ebs-database-b}]' \
    --query 'VolumeId' \
    --output text)


echo "EBS A: ${EBS_A_ID}"
echo "EBS B: ${EBS_B_ID}"


# Tentar anexar os volumes às instâncias.
# Algumas configurações do EC2 em LocalStack podem apenas
# representar o relacionamento via API.

# aws_local ec2 attach-volume \
#     --volume-id "${EBS_A_ID}" \
#     --instance-id "${DATABASE_A_INSTANCE}" \
#     --device "/dev/sdf" \
#     >/dev/null 2>&1 || true


aws_local ec2 attach-volume \
    --volume-id "${EBS_B_ID}" \
    --instance-id "${DATABASE_B_INSTANCE}" \
    --device "/dev/sdf" \
    >/dev/null 2>&1 || true



# --------------------------------------------------
# --- 11. S3 DATALAKE ---
# --------------------------------------------------

echo ""
echo "[11/13] Criando buckets S3 para datalake..."

for bucket in bronze silver gold; do
  aws_local s3 mb s3://$bucket || true
done

echo "Buckets bronze, silver e gold criados."


# --------------------------------------------------
# --- 12. SNS ---
# --------------------------------------------------

echo ""
echo "[12/13] Criando tópicos SNS para notificações..."

SNS_TOPIC_ARN=$(aws_local sns create-topic \
    --name estoque-autopecas-alertas \
    --query 'TopicArn' \
    --output text)

echo "SNS Topic criado: ${SNS_TOPIC_ARN}"

# Subscrever um endpoint de e-mail (mockado)
aws_local sns subscribe \
    --topic-arn "${SNS_TOPIC_ARN}" \
    --protocol email \
    --notification-endpoint "email.do.marcos@lamar.com" \
    >/dev/null 2>&1 || true



# --------------------------------------------------
# --- 13. CLOUDWATCH ---
# --------------------------------------------------

echo ""
echo "[13/13] Criando métricas e alarmes no CloudWatch..."

# Criar uma métrica customizada
aws_local cloudwatch put-metric-data \
    --namespace "EstoqueAutopecas" \
    --metric-name "RequestsBackend" \
    --value 1 \
    --unit Count

# Criar um alarme que dispara via SNS
aws_local cloudwatch put-metric-alarm \
    --alarm-name "BackendHighRequests" \
    --metric-name "RequestsBackend" \
    --namespace "EstoqueAutopecas" \
    --statistic Sum \
    --period 60 \
    --threshold 100 \
    --comparison-operator GreaterThanThreshold \
    --evaluation-periods 1 \
    --alarm-actions "${SNS_TOPIC_ARN}" \
    --output text



# --------------------------------------------------
# --- IAM ---
# --------------------------------------------------

echo ""
echo "Criando IAM Role para o backend..."


aws_local iam create-role \
    --role-name "estoque-autopecas-backend-role" \
    --assume-role-policy-document \
'{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "ec2.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}' \
    >/dev/null 2>&1 || true


echo "IAM Role criada."
