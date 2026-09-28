output "zot_private_ip" { value = aws_instance.zot.private_ip }
output "zot_public_ip" { value = aws_instance.zot.public_ip }
output "client_public_ip" { value = aws_instance.client.public_ip }
output "ecr_registry" { value = local.ecr_registry }
