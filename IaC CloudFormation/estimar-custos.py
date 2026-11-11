"""Compare the two application templates using c3x prices, without deploying."""

import argparse
from collections import defaultdict
from decimal import Decimal
import json
from pathlib import Path
import subprocess

import yaml


ROOT = Path(__file__).resolve().parent
D = Decimal


class CloudFormationLoader(yaml.SafeLoader):
    pass


def intrinsic(loader, tag, node):
    if isinstance(node, yaml.ScalarNode):
        value = loader.construct_scalar(node)
    elif isinstance(node, yaml.SequenceNode):
        value = loader.construct_sequence(node)
    else:
        value = loader.construct_mapping(node)
    return {tag: value}


CloudFormationLoader.add_multi_constructor("!", intrinsic)


def load_template(path):
    return yaml.load(path.read_text(encoding="utf-8"), Loader=CloudFormationLoader)


def one_rate(estimate, kind, dimension):
    rates = {
        D(item["unit_rate"])
        for resource in estimate["costs"] if resource["kind"] == kind
        for item in resource["line_items"] if item["dimension"] == dimension
    }
    if len(rates) != 1 or next(iter(rates)) <= 0:
        raise ValueError(f"Tarifa ausente ou ambigua: {kind}.{dimension}: {rates}")
    return rates.pop()


def scheduled_costs(estimate, template, days, root_gb, gp3_rate, ipv4_rate):
    """Reprice quantities, not rounded c3x subtotals; retain full-month EBS."""
    calendar_hours = D(days * 24)
    running_hours = D(days * 16)
    resources = template["Resources"]
    groups = defaultdict(lambda: D(0))
    rows = []

    def add(group, resource, dimension, quantity, rate, source):
        cost = quantity * rate
        groups[group] += cost
        rows.append(dict(group=group, resource=resource, dimension=dimension,
                         quantity=str(quantity), unit_rate=str(rate),
                         cost=str(cost), source=source))

    categories = {
        "aws_instance": "EC2",
        "aws_ebs_volume": "EBS",
        "aws_eip": "IPv4",
        "aws_nat_gateway": "NAT",
        "aws_lb": "ALB",
        "aws_route53_zone": "Route53",
        "aws_lambda_function": "Lambda",
    }
    hourly = {"gateway_hours", "lb_hours", "ip_hours"}
    for resource in estimate["costs"]:
        for item in resource["line_items"]:
            dimension = item["dimension"]
            quantity, rate = D(item["quantity"]), D(item["unit_rate"])
            source = "c3x:" + item["price_source"]
            if dimension == "free":
                continue
            if resource["kind"] not in categories:
                raise ValueError("Recurso tarifado sem classificacao: " + resource["resource"])
            group = categories[resource["kind"]]
            if dimension in ("root_volume", "ebs_volumes"):
                group = "EBS"
            if dimension == "compute_hours":
                quantity = running_hours
            elif dimension in hourly:
                quantity = calendar_hours
            elif group == "Route53" and dimension == "hosted_zone":
                # c3x 0.3.21 returns $0.0005 instead of $0.50 per zone-month.
                rate = D("0.50")
                source = "https://aws.amazon.com/route53/pricing/"
            elif group == "Route53" and dimension == "queries":
                if "VPCs" not in resources[resource["name"]]["Properties"]:
                    raise ValueError("Reavaliar consultas DNS da zona publica.")
                quantity = D(0)  # Private hosted-zone queries are free.
            elif group == "Lambda" and dimension == "requests":
                quantity = D(days * 2)
            elif group == "Lambda" and dimension == "duration":
                # Two invocations/day, 128 MiB and an assumed 1 second each.
                quantity = D(days * 2) * D("0.125")
            add(group, resource["resource"], dimension, quantity, rate, source)

    for name, resource in resources.items():
        if resource["Type"] == "AWS::EC2::Instance":
            props = resource["Properties"]
            if not props.get("BlockDeviceMappings"):
                add("EBS", name, "assumed_root_gp3_gb", D(root_gb), gp3_rate,
                    "premissa: disco raiz da AMI nao declarado no template")
            for interface in props.get("NetworkInterfaces", []):
                if interface.get("AssociatePublicIpAddress") is True:
                    add("IPv4", name, "ephemeral_ip_hours", running_hours, ipv4_rate,
                        "tarifa IPv4 c3x; endereco liberado no stop")
        elif resource["Type"] == "AWS::ElasticLoadBalancingV2::LoadBalancer":
            props = resource["Properties"]
            if props.get("Scheme") == "internet-facing":
                add("IPv4", name, "alb_minimum_ip_hours",
                    calendar_hours * D(len(props["Subnets"])), ipv4_rate,
                    "minimo: um IPv4 por subnet do ALB")
    return dict(total=str(sum(groups.values())), groups={k: str(v) for k, v in groups.items()},
                rows=rows)


def run_estimate(executable, template, region, output):
    command = [executable, "estimate", "--path", str(template),
               "--region", region, "--currency", "USD", "--format", "json"]
    result = subprocess.run(command, capture_output=True, text=True, timeout=180)
    if result.stderr:
        print(result.stderr, end="")
    result.check_returncode()
    estimate = json.loads(result.stdout)
    for resource in estimate["costs"]:
        for item in resource["line_items"]:
            if D(item["quantity"]) > 0 and D(item["unit_rate"]) == 0 and item["dimension"] != "free":
                raise ValueError("Tarifa zero inesperada: " + resource["resource"])
            for caveat in item.get("caveats", []):
                if caveat["code"] != "usage_not_provided":
                    raise ValueError(f"Estimativa requer revisao: {caveat}")
    output.write_text(json.dumps(estimate, indent=2) + "\n", encoding="utf-8")
    return estimate


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--c3x", default="c3x", help="Caminho do c3x instalado.")
    parser.add_argument("--region", default="us-east-1")
    parser.add_argument("--days", type=int, choices=range(28, 32), default=30)
    parser.add_argument("--original-root-gb", type=int, default=8,
                        help="Premissa de tamanho de cada disco raiz nao declarado da stack atual.")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "custos-economica")
    args = parser.parse_args()
    if args.original_root_gb < 1:
        parser.error("--original-root-gb deve ser positivo.")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    version = subprocess.run([args.c3x, "version"], capture_output=True, text=True,
                             timeout=30, check=True).stdout.strip()
    scenarios = {}
    for name, filename in [
        ("atual", "cloudformationCodeTracker.yaml"),
        ("economica", "cloudformationCodeTracker-economica.yaml"),
    ]:
        path = ROOT / filename
        raw = run_estimate(args.c3x, path, args.region, args.output_dir / (name + "-c3x.json"))
        scenarios[name] = (raw, load_template(path))
    gp3_rate = one_rate(scenarios["atual"][0], "aws_ebs_volume", "storage")
    ipv4_rate = one_rate(scenarios["atual"][0], "aws_eip", "ip_hours")
    comparison = {
        "tool": version, "region": args.region, "currency": "USD",
        "days": args.days, "compute_hours": args.days * 16,
        "calendar_hours": args.days * 24, "original_root_gb_assumption": args.original_root_gb,
        "generated_at": scenarios["economica"][0]["generated_at"],
        "scenarios": {
            name: scheduled_costs(raw, template, args.days, args.original_root_gb, gp3_rate, ipv4_rate)
            for name, (raw, template) in scenarios.items()
        },
    }
    current = D(comparison["scenarios"]["atual"]["total"])
    cheap = D(comparison["scenarios"]["economica"]["total"])
    comparison["saving_percent"] = str((1 - cheap / current) * 100)
    (args.output_dir / "comparacao.json").write_text(
        json.dumps(comparison, indent=2) + "\n", encoding="utf-8")
    lines = [
        "# Estimativa da stack principal (USD)", "",
        f"- Ferramenta: {version}; consulta: {comparison['generated_at']}.",
        f"- Regiao: {args.region}; {args.days} dias; EC2: {args.days * 16} h (06h-22h Brasilia).",
        f"- NAT, ALB e EIP: {args.days * 24} h; EBS: mes inteiro, inclusive durante stop.",
        "- Tarifas consultadas pelo c3x; quantidades ajustadas pelo estimar-custos.py.",
        "", "| Componente | Atual | Economica |", "| --- | ---: | ---: |",
    ]
    for group in ("EC2", "EBS", "NAT", "ALB", "IPv4", "Route53", "Lambda"):
        values = [D(comparison["scenarios"][name]["groups"].get(group, "0"))
                  for name in ("atual", "economica")]
        lines.append(f"| {group} | {values[0]:.2f} | {values[1]:.2f} |")
    lines.extend([
        f"| **Base mensal estimada** | **{current:.2f}** | **{cheap:.2f}** |", "",
        f"Economia: **{D(comparison['saving_percent']):.2f}%**, aproximadamente **USD {current - cheap:.2f}/mes**.",
        "", "## Ajustes e limites", "",
        f"- Atual: cada disco raiz nao declarado assume {args.original_root_gb} GB gp3; confirmar na AMI/conta.",
        "- Inclui tres EIPs atuais, minimo de dois IPv4 do ALB e IPv4 dinamico da EC2 economica.",
        "- Route 53 privado: USD 0.50/zona-mes; consultas gratuitas. Corrige a tarifa 0.0005 do c3x 0.3.21.",
        "- Lambda: duas invocacoes/dia, 128 MiB e 1 segundo/invocacao como premissa; custo menor que USD 0.01.",
        "- NAO e a fatura total: faltam trafego, GB processados pelo NAT, LCUs, logs, backups e eventuais creditos CPU.",
        "- Uso variavel nao informado NAO significa gratuito; caveats originais permanecem nos JSONs c3x.",
        "- Sem Free Tier, creditos promocionais, impostos, cambio, Spot, reservas ou Savings Plans.",
        "- Data lake e observabilidade nao incluidos. Nenhum deploy foi executado.",
        "- ALB e NAT nao possuem stop: continuam cobrados 24h; nao foram artificialmente reduzidos para 16h.",
        "- A stack atual nao tem agendamento: seus custos pressupoem stop/start externo de todas as EC2.",
        "- O agendamento da stack economica depende das permissoes da role e do servico EventBridge.",
        "- JSONs *-c3x.json sao a saida bruta (730 h padrao); comparacao.json detalha cada ajuste.", "",
        "Fontes: https://aws.amazon.com/route53/pricing/ ; https://aws.amazon.com/vpc/pricing/ ;",
        "https://aws.amazon.com/elasticloadbalancing/pricing/ ; https://aws.amazon.com/ebs/pricing/ .", "",
    ])
    report = "\n".join(lines)
    (args.output_dir / "comparacao.md").write_text(report, encoding="utf-8")
    print(report)


if __name__ == "__main__":
    main()
