# Long-lived resources shared by every benchmark run: ECR repos holding the
# pinned benchmark images, and the IAM role zot uses to pull from them.
# The per-run EC2 environment lives in ../app and reads these via remote state.

data "aws_caller_identity" "me" {}

locals {
  # Destination repos (3rd column) from images/images.txt, skipping comments and blanks.
  image_lines = [for l in split("\n", file("${path.module}/../../images/images.txt")) : trimspace(l)]
  repos = toset([
    for l in local.image_lines : split(" ", replace(l, "/\\s+/", " "))[2]
    if l != "" && !startswith(l, "#")
  ])
}

resource "aws_ecr_repository" "bench" {
  for_each     = local.repos
  name         = each.key
  force_delete = true
}

resource "aws_iam_role" "zot" {
  name = "ccdn-bench-zot"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "zot_ecr" {
  role       = aws_iam_role.zot.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "zot" {
  name = "ccdn-bench-zot"
  role = aws_iam_role.zot.name
}
