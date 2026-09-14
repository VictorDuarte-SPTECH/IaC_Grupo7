from diagrams import Diagram, Cluster
from diagrams.onprem.compute import Server
from diagrams.aws.network import InternetGateway, VPC, RouteTable, NATGateway, ALB
from diagrams.aws.compute import EC2
from diagrams.aws.storage import S3, EBS
from diagrams.aws.management import Cloudwatch
from diagrams.aws.integration import SNS

with Diagram("Arquitetura Localstack - Estoque Autopeças", show=True):
    usuario = Server("Usuário")

    with Cluster("AWS"):

        igw = InternetGateway("Internet Gateway")

        usuario >> igw

        with Cluster("VPC (10.0.0.0/25)"):
            alb = ALB("Load Balancer")

            with Cluster("Zona de Disponibilidade - us-east-1a"):
                with Cluster("Subnet Pública A (10.0.0.0/27)"):
                    nat1 = NATGateway("NAT Gateway A")

                with Cluster("Subnet Frontend A (10.0.0.64/28)"):
                    route01 = RouteTable("Route Table A")
                    frontend_a = EC2("Frontend A")

                with Cluster("Subnet Backend A (10.0.0.96/28)"):
                    backend_a = EC2("Backend A")

            with Cluster("Zona de Disponibilidade - us-east-1b"):
                with Cluster("Subnet Pública B (10.0.0.32/27)"):
                    nat2 = NATGateway("NAT Gateway B")

                with Cluster("Subnet Frontend B (10.0.0.80/28)"):
                    route02 = RouteTable("Route Table B")
                    frontend_b = EC2("Frontend B")

                with Cluster("Subnet Backend B (10.0.0.112/28)"):
                    backend_b = EC2("Backend B")
                    db_b = EC2("Database B")
                    ebs_b = EBS("EBS Volume B")

        # Datalake S3
        bronze = S3("Bucket Bronze")
        silver = S3("Bucket Silver")
        gold = S3("Bucket Gold")

        # Observabilidade
        cw = Cloudwatch("CloudWatch")
        sns = SNS("SNS Alertas")

        # Conexões
        igw >> alb
        alb >> frontend_a
        alb >> frontend_b
        nat1 >> route01 >> frontend_a >> backend_a
        nat2 >> route02 >> frontend_b >> backend_b
        backend_b >> db_b >> ebs_b

        bronze >> silver >> gold

        ebs_b >> cw >> sns