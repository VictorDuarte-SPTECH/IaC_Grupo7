from diagrams import Diagram, Cluster
from diagrams.onprem.compute import Server
from diagrams.aws.network import InternetGateway, VPC, PrivateSubnet, PublicSubnet, RouteTable, ALB, NATGateway
from diagrams.aws.compute import EC2
from diagrams.aws.storage import EFS, EBS

with Diagram("Ingestao de Dados On-Premise", show=True):
    onprem = Server("Usuário")

    igw = InternetGateway("Internet Gateway")

    onprem >> igw

    with Cluster("VPC"):
        
        alb = ALB("Application Load Balancer")
        
        with Cluster("Zona de Disponibilidade 1"):
            with Cluster("Sub-rede Pública"):
                nat1 = NATGateway("NAT Gateway")

            with Cluster("Sub-rede Privada1"):
                route01 = RouteTable("Route Table")
                web_server01 = EC2("Web Server")
            with Cluster("Sub-rede Privada2"):
                backend01 = EC2("Backend")
                db01 = EC2("Banco de Dados")
                ebs_volume1 = EBS("EBS Volume")

        with Cluster("Zona de Disponibilidade 2"):
            with Cluster("Sub-rede Pública2"):
                nat2 = NATGateway("NAT Gateway")

            with Cluster("Sub-rede Privada3"):
                route02 = RouteTable("Route Table")
                web_server02 = EC2("Web Server")
            with Cluster("Sub-rede Privada4"):
                backend02 = EC2("Backend")
                db02 = EC2("Banco de Dados")
                ebs_volume2 = EBS("EBS Volume")

        route_table = RouteTable("Route Table")

        igw >> alb >> nat1
        alb >> nat2
        nat1 >> route01 >> web_server01
        nat2 >> route02 >> web_server02
        web_server01 >> backend01
        web_server02 >> backend02
        nat1 >> route_table
        nat2 >> route_table
        backend01 >> db01 >> ebs_volume1
        backend02 >> db02 >> ebs_volume2
