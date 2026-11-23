# --- GitHub Actions -> AWS, with no stored keys -------------------------------
# GitHub mints a short-lived OIDC token for each workflow run, signed by its
# issuer. AWS trusts that issuer (the provider below), and the role accepts a
# token only from this repository's main branch. The workflow trades the token
# for 1-hour credentials; nothing long-lived is stored in GitHub.
#
# The provider is account-wide (one per issuer URL per account). It lives here
# because dev is the only environment; a second one would move it to a shared
# root.

locals {
  github_repo = "ofelix60/scoreboard"
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "gha_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # The entire security of this role. Any GitHub repository can obtain a
    # validly signed token from the same issuer; only this condition limits the
    # role to ours. StringEquals on the exact repo and branch: a StringLike
    # wildcard, or no sub condition, would let a workflow in any repository
    # assume it. Pull requests don't match either (their sub ends in
    # ":pull_request"), so a PR can't push images.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${local.github_repo}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "gha_publish" {
  name                 = "scoreboard-dev-gha-publish"
  assume_role_policy   = data.aws_iam_policy_document.gha_trust.json
  max_session_duration = 3600
}

# Push to this environment's ECR repository, and nothing else. Deploying stays
# a reviewed terraform apply, so CI never needs permissions over the stack.
data "aws_iam_policy_document" "gha_publish" {
  # GetAuthorizationToken can't be scoped to a repository; AWS only accepts "*".
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
    ]
    resources = [module.service.ecr_repository_arn]
  }
}

resource "aws_iam_role_policy" "gha_publish" {
  name   = "ecr-push"
  role   = aws_iam_role.gha_publish.id
  policy = data.aws_iam_policy_document.gha_publish.json
}

output "gha_publish_role_arn" {
  value = aws_iam_role.gha_publish.arn
}
