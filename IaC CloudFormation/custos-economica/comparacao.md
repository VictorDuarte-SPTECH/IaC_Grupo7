# Estimativa da stack principal (USD)

- Ferramenta: c3x 0.3.21 (windows/amd64, go1.27.3); consulta: 2026-11-02T22:01:21Z.
- Regiao: us-east-1; 30 dias; EC2: 480 h (06h-22h Brasilia).
- NAT, ALB e EIP: 720 h; EBS: mes inteiro, inclusive durante stop.
- Tarifas consultadas pelo c3x; quantidades ajustadas pelo estimar-custos.py.

| Componente | Atual | Economica |
| --- | ---: | ---: |
| EC2 | 79.87 | 9.02 |
| EBS | 8.32 | 1.60 |
| NAT | 64.80 | 0.00 |
| ALB | 16.20 | 0.00 |
| IPv4 | 18.00 | 2.40 |
| Route53 | 0.50 | 0.00 |
| Lambda | 0.00 | 0.00 |
| **Base mensal estimada** | **187.69** | **13.02** |

Economia: **93.06%**, aproximadamente **USD 174.67/mes**.

## Ajustes e limites

- Atual: cada disco raiz nao declarado assume 8 GB gp3; confirmar na AMI/conta.
- Inclui tres EIPs atuais, minimo de dois IPv4 do ALB e IPv4 dinamico da EC2 economica.
- Route 53 privado: USD 0.50/zona-mes; consultas gratuitas. Corrige a tarifa 0.0005 do c3x 0.3.21.
- Lambda: duas invocacoes/dia, 128 MiB e 1 segundo/invocacao como premissa; custo menor que USD 0.01.
- NAO e a fatura total: faltam trafego, GB processados pelo NAT, LCUs, logs, backups e eventuais creditos CPU.
- Uso variavel nao informado NAO significa gratuito; caveats originais permanecem nos JSONs c3x.
- Sem Free Tier, creditos promocionais, impostos, cambio, Spot, reservas ou Savings Plans.
- Data lake e observabilidade nao incluidos. Nenhum deploy foi executado.
- ALB e NAT nao possuem stop: continuam cobrados 24h; nao foram artificialmente reduzidos para 16h.
- A stack atual nao tem agendamento: seus custos pressupoem stop/start externo de todas as EC2.
- O agendamento da stack economica depende das permissoes da role e do servico EventBridge.
- JSONs *-c3x.json sao a saida bruta (730 h padrao); comparacao.json detalha cada ajuste.

Fontes: https://aws.amazon.com/route53/pricing/ ; https://aws.amazon.com/vpc/pricing/ ;
https://aws.amazon.com/elasticloadbalancing/pricing/ ; https://aws.amazon.com/ebs/pricing/ .
