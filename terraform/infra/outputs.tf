output "ecr_registry" { value = "${data.aws_caller_identity.me.account_id}.dkr.ecr.${var.region}.amazonaws.com" }
output "ecr_repositories" { value = sort([for r in aws_ecr_repository.bench : r.name]) }
output "zot_instance_profile" { value = aws_iam_instance_profile.zot.name }
