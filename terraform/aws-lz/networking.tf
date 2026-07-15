##############################################################################
# networking.tf — AWS Landing Zone
# Centralized VPC per environment, owned by the Network account, subnets
# shared out to workload accounts via AWS RAM. This is the closest AWS
# mirror to GCP's Shared VPC pattern in shared_vpc.tf: one account owns the
# network, other accounts attach workloads to it without owning network
# resources of their own.
#
# Architecture:
#   Network account  → owns VPC, subnets, NAT Gateway, route tables,
#                       Transit Gateway, private Route 53 zone
#   Workload account → RAM-shared subnets; workloads launch into them but
#                       cannot create their own VPCs (blocked by SCP scope,
#                       enforced organizationally rather than technically —
#                       see note below)
##############################################################################

# ── VPC (per environment) — created in the Network account ─────────────────

resource "aws_vpc" "main" {
  provider = aws.network_account
  for_each = toset(var.environments)

  cidr_block           = var.vpc_cidr_primary
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name        = "${var.org_prefix}-${each.key}-vpc"
    environment = each.key
  })
}

# ── Subnets — private only, spread across AZs ───────────────────────────────
# No public subnets by design; egress goes through NAT Gateway, ingress
# through a load balancer subnet if/when one is needed. Mirrors the GCP LZ
# posture of no external IPs on compute by default.

data "aws_availability_zones" "available" {
  provider = aws.network_account
  state    = "available"
}

resource "aws_subnet" "private" {
  provider = aws.network_account
  for_each = {
    for pair in setproduct(var.environments, range(var.az_count)) :
    "${pair[0]}-${pair[1]}" => { env = pair[0], az_index = pair[1] }
  }

  vpc_id            = aws_vpc.main[each.value.env].id
  availability_zone = data.aws_availability_zones.available.names[each.value.az_index]

  # Simple /24 carve-out per AZ within the environment's VPC CIDR.
  cidr_block = cidrsubnet(var.vpc_cidr_primary, 4, each.value.az_index)

  tags = merge(local.common_tags, {
    Name        = "${var.org_prefix}-${each.value.env}-private-${each.value.az_index}"
    environment = each.value.env
  })
}

# ── NAT Gateway — one per AZ for prod, single for dev/staging ──────────────
# Dev/staging keep the cost-conscious single-NAT default: doubling/tripling
# NAT cost for environments with no production traffic buys nothing. Prod
# gets one NAT Gateway per AZ, each fronted by its own EIP, with each AZ's
# private route table pointed at the NAT Gateway in the *same* AZ — this is
# the actual resilience property, not just "more NAT Gateways": if one AZ's
# NAT fails, only that AZ's egress is affected, and traffic never crosses an
# AZ boundary to reach a NAT Gateway (which would also add cross-AZ data
# transfer cost). Flagged as a gap in resilience_disaster_recovery.md —
# single NAT Gateway per environment was a deliberate cost tradeoff that
# became a real SPOF for prod specifically.

locals {
  # Key set for NAT resources: prod gets one entry per AZ, everything else
  # gets exactly one entry (AZ index 0), matching the previous single-NAT
  # behavior for dev/staging.
  nat_keys = {
    for pair in setproduct(var.environments, range(var.az_count)) :
    "${pair[0]}-${pair[1]}" => { env = pair[0], az_index = pair[1] }
    if pair[0] == "prod" || pair[1] == 0
  }
}

resource "aws_eip" "nat" {
  provider = aws.network_account
  for_each = local.nat_keys
  domain   = "vpc"

  tags = merge(local.common_tags, {
    Name        = "${var.org_prefix}-${each.value.env}-nat-eip-${each.value.az_index}"
    environment = each.value.env
  })
}

resource "aws_nat_gateway" "main" {
  provider = aws.network_account
  for_each = local.nat_keys

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.private[each.key].id

  tags = merge(local.common_tags, {
    Name        = "${var.org_prefix}-${each.value.env}-nat-${each.value.az_index}"
    environment = each.value.env
  })
}

# One private route table per AZ in prod (each routing to its own AZ's NAT
# Gateway), one shared route table per environment for dev/staging (all
# subnets routing to the single NAT Gateway) — same key set as the subnets
# themselves so every subnet gets an unambiguous route table association.
resource "aws_route_table" "private" {
  provider = aws.network_account
  for_each = { for k, v in aws_subnet.private : k => v }

  vpc_id = aws_vpc.main[each.value.tags.environment].id

  route {
    cidr_block = "0.0.0.0/0"
    # Prod: route to the NAT Gateway in this exact AZ. Dev/staging: every
    # subnet routes to the single AZ-0 NAT Gateway, same as before.
    nat_gateway_id = aws_nat_gateway.main[
      each.value.tags.environment == "prod" ? each.key : "${each.value.tags.environment}-0"
    ].id
  }

  tags = merge(local.common_tags, {
    Name        = "${var.org_prefix}-${each.value.tags.environment}-private-rt-${each.key}"
    environment = each.value.tags.environment
  })
}

resource "aws_route_table_association" "private" {
  provider = aws.network_account
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

# ── RAM Resource Share — attach workload accounts to the Network VPC ───────
# Mirrors google_compute_shared_vpc_service_project — the workload account
# doesn't own the subnet, it's granted permission to launch resources into
# a subnet owned elsewhere.

resource "aws_ram_resource_share" "vpc_subnets" {
  provider = aws.network_account
  for_each = toset(var.environments)

  name                      = "${var.org_prefix}-${each.key}-subnet-share"
  allow_external_principals = false

  tags = local.common_tags
}

resource "aws_ram_resource_association" "vpc_subnets" {
  provider = aws.network_account
  for_each = aws_subnet.private

  resource_arn       = each.value.arn
  resource_share_arn = aws_ram_resource_share.vpc_subnets[each.value.tags.environment].arn
}

resource "aws_ram_principal_association" "workload_accounts" {
  provider = aws.network_account
  for_each = toset(var.environments)

  principal          = aws_organizations_account.workloads[each.key].id
  resource_share_arn = aws_ram_resource_share.vpc_subnets[each.key].arn
}

# ── Security Groups — deny-by-default, explicit allow ───────────────────────
# Mirrors the firewall posture in shared_vpc.tf: no ingress unless explicit.

resource "aws_security_group" "internal" {
  provider = aws.network_account
  for_each = toset(var.environments)

  name        = "${var.org_prefix}-${each.key}-allow-internal"
  description = "Allow traffic within the VPC CIDR only. No default-open ingress."
  vpc_id      = aws_vpc.main[each.key].id

  ingress {
    description = "Internal VPC traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr_primary]
  }

  egress {
    description = "All outbound - NAT Gateway handles internet egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.common_tags
}

# ── Private Route 53 Zone ────────────────────────────────────────────────────
# Mirrors google_dns_managed_zone (private visibility) — internal service
# resolution stays inside the VPC.

resource "aws_route53_zone" "private" {
  provider = aws.network_account
  for_each = toset(var.environments)

  name = "${each.key}.${var.org_prefix}.internal"

  vpc {
    vpc_id = aws_vpc.main[each.key].id
  }

  tags = local.common_tags
}

# ── VPC Flow Logs → Network account CloudWatch Logs ──────────────────────────
# Mirrors the flow log config in shared_vpc.tf (5s aggregation, 50% sampling,
# full metadata). AWS Flow Logs don't have a sampling knob — capture-all,
# rely on log retention/lifecycle instead for cost control.

resource "aws_flow_log" "vpc" {
  provider = aws.network_account
  for_each = toset(var.environments)

  vpc_id               = aws_vpc.main[each.key].id
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow_logs[each.key].arn
  iam_role_arn         = aws_iam_role.flow_logs[each.key].arn

  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "flow_logs" {
  provider = aws.network_account
  for_each = toset(var.environments)

  name              = "/${var.org_prefix}/${each.key}/vpc-flow-logs"
  retention_in_days = local.is_prod ? 365 : 90

  tags = local.common_tags
}

resource "aws_iam_role" "flow_logs" {
  provider = aws.network_account
  for_each = toset(var.environments)

  name = "${var.org_prefix}-${each.key}-flow-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "flow_logs" {
  provider = aws.network_account
  for_each = toset(var.environments)

  name = "${var.org_prefix}-${each.key}-flow-logs-policy"
  role = aws_iam_role.flow_logs[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
      ]
      Resource = "*"
    }]
  })
}

# ── Note: Snowflake connects here via a VPC Interface Endpoint using AWS
# PrivateLink, landed in the Network account's private subnets — the direct
# AWS equivalent of the Private Service Connect endpoint in the GCP host
# project. See account_landing_zone_guardrails.md for the integration map.
