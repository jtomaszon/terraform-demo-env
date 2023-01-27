module "demo-vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "demo-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["sa-east-1a", "sa-east-1b"]
  private_subnets = ["10.0.0.0/24", "10.0.1.0/24"]
  public_subnets  = ["10.0.100.0/24", "10.0.101.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true
  enable_vpn_gateway = false

  tags = {
    Environment = "Production"
    Type = "Demo"
  }
}

module "bastion-sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 4.0"

  name        = "bastion-sg"
  description = "Security group for Demo"
  vpc_id      = module.demo-vpc.vpc_id

  ingress_cidr_blocks = ["0.0.0.0/0"]
  ingress_rules       = ["ssh-tcp"]

  egress_rules        = ["all-all"]
}

module "bastion" {
  source                 = "terraform-aws-modules/ec2-instance/aws"
  version                = "~> 2.0"

  name                   = "bastion"
  instance_count         = 1

  ami                    = "ami-0747bdcabd34c712a"
  instance_type          = var.instance_type
  key_name               = "terraform-demo-env"
  monitoring             = true
  vpc_security_group_ids = [ "${module.bastion-sg.security_group_id}" ]
  subnet_id              = "${module.demo-vpc.public_subnets[0]}"

  associate_public_ip_address = true

  enable_volume_tags = true
  root_block_device = [
    {
      volume_type = "gp2"
      volume_size = 8
    },
  ]

  tags = {
    Environment = "Production"
    Type   = "Bastion"
  }
}

resource "aws_eip" "bastion" {
  instance = "${module.bastion.id[0]}"
  vpc      = true
}

resource "aws_placement_group" "demo-cluster" {
  name     = "demo-cluster"
  strategy = "cluster"
}

module "proxysql-sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 4.0"

  name        = "bastion-sg"
  description = "Security group for Demo"
  vpc_id      = module.demo-vpc.vpc_id

  ingress_cidr_blocks = ["0.0.0.0/0"]
  ingress_rules       = ["ssh-tcp", "mysql-tcp"]

  egress_rules        = ["all-all"]
}


module "demo-proxysql-a" {
  source                 = "terraform-aws-modules/ec2-instance/aws"
  version                = "~> 2.0"

  name                   = "demo-sql-a"
  instance_count         = 1
  placement_group        = "${aws_placement_group.demo-cluster.id}"

  ami                    = "ami-0747bdcabd34c712a"
  instance_type          = var.instance_type
  key_name               = "terraform-demo-env"
  monitoring             = true
  vpc_security_group_ids = [ "${module.proxysql-sg.security_group_id}" ]
  subnet_id              = "${module.demo-vpc.private_subnets[0]}"

  associate_public_ip_address = false

  enable_volume_tags = true
  root_block_device = [
    {
      volume_type = "gp2"
      volume_size = 10
    },
  ]

  tags = {
    Environment = "Production"
    Type   = "proxySQL"
  }
}

# TODO: Add SSM
resource "random_password" "master" {
  length = 32
  special          = true
  override_special = "_%@"
}

module "demo-db" {
  source  = "terraform-aws-modules/rds-aurora/aws"
  version = "~> 3.0"

  name                      = "demodb"
  engine                    = "aurora-mysql"
  engine_mode               = "provisioned"
  engine_version            = "5.7.mysql_aurora.2.11.0"
  instance_type             = "db.t3.small"

  vpc_id  = module.demo-vpc.vpc_id
  subnets = module.demo-vpc.private_subnets
  create_security_group = true

  replica_count           = 0
  database_name           = "demo"

  storage_encrypted   = true
  apply_immediately   = true
  skip_final_snapshot = true
  performance_insights_enabled = true
  auto_minor_version_upgrade = false
  monitoring_interval = 60
  backup_retention_period = 2
  preferred_backup_window = "06:00-07:00"

  allowed_cidr_blocks     = ["0.0.0.0/0"]

  create_random_password              = false
  iam_database_authentication_enabled = false
  password                            = random_password.master.result

  db_parameter_group_name         = aws_db_parameter_group.demo.id
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.demo.id
  enabled_cloudwatch_logs_exports = ["error", "slowquery"]

  tags = {
    Environment = "Production"
    Application = "Demo"
  }
}

resource "aws_db_parameter_group" "demo" {
  name        = "demo-aurora-db-57-parameter-group"
  family      = "aurora-mysql5.7"
  description = "demo-aurora-db-57-parameter-group"
}

resource "aws_rds_cluster_parameter_group" "demo" {
  name        = "demo-aurora-57-cluster-parameter-group"
  family      = "aurora-mysql5.7"
  description = "demo-aurora-57-cluster-parameter-group"
}

# Create elastic beanstalk application
 
resource "aws_elastic_beanstalk_application" "elastic_app" {
  name = var.elastic_app
}
 
# Create elastic beanstalk Environment
 
resource "aws_elastic_beanstalk_environment" "demo-env" {
  name                = var.beanstalk_app_env
  application         = aws_elastic_beanstalk_application.elastic_app.name
  solution_stack_name = var.solution_stack_name
  tier                = var.tier
 
  setting {
    namespace = "aws:ec2:vpc"
    name      = "VPCId"
    value     = module.demo-vpc.vpc_id
  }
  setting {
    namespace = "aws:autoscaling:launchconfiguration"
    name      = "IamInstanceProfile"
    value     =  "aws-elasticbeanstalk-ec2-role"
  }
  setting {
    namespace = "aws:ec2:vpc"
    name      = "AssociatePublicIpAddress"
    value     =  "True"
  }
 
  setting {
    namespace = "aws:ec2:vpc"
    name      = "Subnets"
    value     = join(",", module.demo-vpc.private_subnets)
  }
  setting {
    namespace = "aws:elasticbeanstalk:environment:process:default"
    name      = "MatcherHTTPCode"
    value     = "200"
  }
  setting {
    namespace = "aws:elasticbeanstalk:environment"
    name      = "LoadBalancerType"
    value     = "application"
  }
  setting {
    namespace = "aws:autoscaling:launchconfiguration"
    name      = "InstanceType"
    value     = "t3.micro"
  }
  setting {
    namespace = "aws:ec2:vpc"
    name      = "ELBScheme"
    value     = "internet facing"
  }
  setting {
    namespace = "aws:autoscaling:asg"
    name      = "MinSize"
    value     = 1
  }
  setting {
    namespace = "aws:autoscaling:asg"
    name      = "MaxSize"
    value     = 1
  }
  setting {
    namespace = "aws:elasticbeanstalk:healthreporting:system"
    name      = "SystemType"
    value     = "enhanced"
  }
 
}
