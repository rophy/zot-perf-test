data "terraform_remote_state" "infra" {
  backend = "local"
  config  = { path = "${path.module}/../infra/terraform.tfstate" }
}
data "http" "myip" { url = "https://checkip.amazonaws.com" }

locals {
  operator_cidr = var.operator_cidr != "" ? var.operator_cidr : "${chomp(data.http.myip.response_body)}/32"
  ecr_registry  = data.terraform_remote_state.infra.outputs.ecr_registry
}

data "aws_vpc" "default" { default = true }

data "aws_subnet" "az" {
  vpc_id            = data.aws_vpc.default.id
  availability_zone = var.az
  default_for_az    = true
}

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "tls_private_key" "ssh" { algorithm = "ED25519" }

resource "local_sensitive_file" "ssh_key" {
  content         = tls_private_key.ssh.private_key_openssh
  filename        = "${path.module}/.ssh/id_ed25519"
  file_permission = "0600"
}

resource "aws_key_pair" "bench" {
  key_name   = "ccdn-bench"
  public_key = tls_private_key.ssh.public_key_openssh
}

resource "aws_placement_group" "bench" {
  name     = "ccdn-bench"
  strategy = "cluster"
}

resource "aws_security_group" "bench" {
  name   = "ccdn-bench"
  vpc_id = data.aws_vpc.default.id

  ingress {
    description = "ssh from operator"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.operator_cidr]
  }
  ingress {
    description = "all traffic between bench nodes"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "zot" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.zot_instance_type
  subnet_id              = data.aws_subnet.az.id
  placement_group        = aws_placement_group.bench.id
  key_name               = aws_key_pair.bench.key_name
  vpc_security_group_ids = [aws_security_group.bench.id]
  iam_instance_profile   = data.terraform_remote_state.infra.outputs.zot_instance_profile
  root_block_device {
    volume_type = "gp3"
    volume_size = 30
  }
  ebs_block_device {
    device_name           = "/dev/sdf"
    volume_type           = "gp3"
    volume_size           = var.zot_data_volume_size
    iops                  = var.zot_data_volume_iops
    throughput            = var.zot_data_volume_throughput
    delete_on_termination = true
  }
  user_data = templatefile("${path.module}/userdata-zot.sh.tpl", {
    zot_version           = var.zot_version
    node_exporter_version = var.node_exporter_version
    ecr_registry          = local.ecr_registry
    render_config         = file("${path.module}/../../zot/render-config.sh")
    zot_service           = file("${path.module}/../../zot/zot.service")
  })
  user_data_replace_on_change = true
  tags                        = { Name = "ccdn-zot" }
}

resource "aws_instance" "client" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.client_instance_type
  subnet_id              = data.aws_subnet.az.id
  placement_group        = aws_placement_group.bench.id
  key_name               = aws_key_pair.bench.key_name
  vpc_security_group_ids = [aws_security_group.bench.id]
  root_block_device {
    volume_type = "gp3"
    volume_size = 30
  }
  user_data = templatefile("${path.module}/userdata-client.sh.tpl", {
    k6_version            = var.k6_version
    prometheus_version    = var.prometheus_version
    node_exporter_version = var.node_exporter_version
    crane_version         = var.crane_version
    prometheus_yml        = templatefile("${path.module}/../../monitoring/prometheus.yml.tpl", { zot_ip = aws_instance.zot.private_ip })
  })
  user_data_replace_on_change = true
  tags                        = { Name = "ccdn-client" }
}

resource "local_file" "ssh_config" {
  filename = "${path.module}/ssh_config"
  content  = <<-EOT
    Host zot
      HostName ${aws_instance.zot.public_ip}
    Host client
      HostName ${aws_instance.client.public_ip}
    Host *
      User ec2-user
      IdentityFile ${abspath(local_sensitive_file.ssh_key.filename)}
      StrictHostKeyChecking accept-new
      UserKnownHostsFile ${abspath(path.module)}/.ssh/known_hosts
  EOT
}
