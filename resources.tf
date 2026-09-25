module "network" {
  source  = "kn47ytv9mv/vpc/aws"
  version = "~> 1.0"

  vpc_cidr                = var.vpc_cidr
  availability_zone_count = var.availability_zone_count

  subnets = {
    public = { public = true }
    origin = { nat_gateway_access = true }
  }

  flow_logs = [
    {
      destination_arn  = module.flow_log_group.arn
      destination_type = "cloud-watch-logs"
    },
  ]

  tags = var.tags
}

module "flow_log_group" {
  source  = "kn47ytv9mv/cloudwatch-log-group/aws"
  version = "~> 1.0"

  name       = "/aws/vpc/${var.name}"
  kms_key_id = module.key.arn

  tags = var.tags
}

module "key" {
  source  = "kn47ytv9mv/kms-key/aws"
  version = "~> 1.0"

  description = "${var.name} architecture data key"

  tags = var.tags
}

module "key_alias" {
  source  = "kn47ytv9mv/kms-alias/aws"
  version = "~> 1.0"

  name          = var.name
  target_key_id = module.key.arn
}

module "log_bucket" {
  source  = "kn47ytv9mv/s3/aws"
  version = "~> 1.0"

  bucket = "${var.name}-logs"

  tags = var.tags
}

module "origin_security_group" {
  source  = "kn47ytv9mv/vpc-security-groups/aws"
  version = "~> 1.0"

  name        = "${var.name}-origin"
  vpc_id      = module.network.vpc_id
  description = "Origin load balancer for ${var.name}, reached by the edge."

  ingress_rules = [
    { description = "HTTPS from the edge", ip_protocol = "tcp", from_port = 443, to_port = 443, cidr_ipv4 = "0.0.0.0/0" },
    { description = "HTTP from the edge", ip_protocol = "tcp", from_port = 80, to_port = 80, cidr_ipv4 = "0.0.0.0/0" },
  ]

  egress_rules = [
    { description = "All outbound", ip_protocol = "-1", from_port = -1, to_port = -1, cidr_ipv4 = "0.0.0.0/0" },
  ]

  tags = var.tags
}

module "origin_alb" {
  source  = "kn47ytv9mv/alb/aws"
  version = "~> 1.0"

  name               = "${var.name}-origin"
  internal           = false
  subnet_ids         = module.network.subnet_ids["public"]
  security_group_ids = [module.origin_security_group.id]

  access_logs_bucket = module.log_bucket.bucket
  access_logs_prefix = "origin"

  tags = var.tags
}

module "origin_target_group" {
  source  = "kn47ytv9mv/alb-target-group/aws"
  version = "~> 1.0"

  name              = "${var.name}-origin"
  vpc_id            = module.network.vpc_id
  port              = 8080
  protocol          = "HTTP"
  health_check_path = var.health_check_path

  tags = var.tags
}

module "origin_certificate" {
  source  = "kn47ytv9mv/acm-certificate/aws"
  version = "~> 1.0"
  count   = var.domain_name != null ? 1 : 0

  domain_name = "origin.${var.domain_name}"

  tags = var.tags
}

module "origin_https_listener" {
  source  = "kn47ytv9mv/alb-listener/aws"
  version = "~> 1.0"
  count   = var.domain_name != null ? 1 : 0

  load_balancer_arn = module.origin_alb.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = module.origin_certificate[0].arn
  target_group_arn  = module.origin_target_group.arn

  tags = var.tags
}

module "origin_http_listener" {
  source  = "kn47ytv9mv/alb-listener/aws"
  version = "~> 1.0"
  count   = var.domain_name == null ? 1 : 0

  load_balancer_arn = module.origin_alb.arn
  port              = 80
  protocol          = "HTTP"
  target_group_arn  = module.origin_target_group.arn

  tags = var.tags
}

module "edge_certificate" {
  source  = "kn47ytv9mv/acm-certificate/aws"
  version = "~> 1.0"
  count   = var.domain_name != null ? 1 : 0

  providers = {
    aws = aws.edge
  }

  domain_name               = var.domain_name
  subject_alternative_names = ["www.${var.domain_name}"]

  tags = var.tags
}

module "edge_firewall" {
  source  = "kn47ytv9mv/wafv2-web-acl/aws"
  version = "~> 1.0"

  providers = {
    aws = aws.edge
  }

  name           = "${var.name}-edge"
  scope          = "CLOUDFRONT"
  default_action = "allow"

  visibility_config = {
    metric_name = "${var.name}-edge"
  }

  rules_json = jsonencode([
    {
      Name     = "common"
      Priority = 0
      Statement = {
        ManagedRuleGroupStatement = {
          VendorName = "AWS"
          Name       = "AWSManagedRulesCommonRuleSet"
        }
      }
      OverrideAction = { None = {} }
      VisibilityConfig = {
        CloudWatchMetricsEnabled = true
        MetricName               = "${var.name}-common"
        SampledRequestsEnabled   = true
      }
    },
    {
      Name     = "rate-limit"
      Priority = 1
      Statement = {
        RateBasedStatement = {
          Limit            = 2000
          AggregateKeyType = "IP"
        }
      }
      Action = { Block = {} }
      VisibilityConfig = {
        CloudWatchMetricsEnabled = true
        MetricName               = "${var.name}-rate-limit"
        SampledRequestsEnabled   = true
      }
    },
  ])

  tags = var.tags
}

module "edge" {
  source  = "kn47ytv9mv/cloudfront/aws"
  version = "~> 1.0"

  comment     = "${var.name} edge distribution"
  aliases     = var.domain_name != null ? [var.domain_name, "www.${var.domain_name}"] : null
  price_class = var.price_class
  web_acl_id  = module.edge_firewall.arn

  origins = {
    origin = {
      domain_name = var.domain_name != null ? "origin.${var.domain_name}" : module.origin_alb.dns_name

      custom_origin_config = {
        origin_protocol_policy = var.domain_name != null ? "https-only" : "http-only"
      }
    }
  }

  default_cache_behavior = {
    target_origin_id = "origin"
    allowed_methods  = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods   = ["GET", "HEAD"]
  }

  viewer_certificate = var.domain_name != null ? {
    acm_certificate_arn = module.edge_certificate[0].arn
  } : null

  geo_restriction = var.geo_restriction_countries != null ? {
    restriction_type = "whitelist"
    locations        = var.geo_restriction_countries
  } : null

  logging_config = {
    bucket = "${module.log_bucket.bucket}.s3.amazonaws.com"
    prefix = "edge"
  }

  tags = var.tags
}

module "accelerator" {
  source  = "kn47ytv9mv/global-accelerator/aws"
  version = "~> 1.0"
  count   = var.accelerator_port != null ? 1 : 0

  providers = {
    aws = aws.edge
  }

  name = var.name

  flow_logs_enabled   = true
  flow_logs_s3_bucket = module.log_bucket.bucket
  flow_logs_s3_prefix = "accelerator"

  listeners = {
    primary = {
      protocol    = "TCP"
      port_ranges = [{ from_port = var.accelerator_port, to_port = var.accelerator_port }]

      endpoint_groups = {
        (var.region) = {
          health_check_path = var.health_check_path

          endpoint_configurations = [
            { endpoint_id = module.origin_alb.arn, weight = 100 },
          ]
        }
      }
    }
  }

  tags = var.tags
}

module "origin_health_check" {
  source  = "kn47ytv9mv/route53-health-check/aws"
  version = "~> 1.0"
  count   = var.domain_name != null ? 1 : 0

  type            = "HTTPS"
  fqdn            = "origin.${var.domain_name}"
  port            = 443
  resource_path   = var.health_check_path
  measure_latency = true

  tags = var.tags
}

module "zone" {
  source  = "kn47ytv9mv/route53-zone/aws"
  version = "~> 1.0"
  count   = var.domain_name != null ? 1 : 0

  name = var.domain_name

  tags = var.tags
}

module "records" {
  source  = "kn47ytv9mv/route53-record/aws"
  version = "~> 1.0"
  count   = var.domain_name != null ? 1 : 0

  records = merge(
    {
      apex = {
        zone_id = module.zone[0].id
        name    = var.domain_name
        type    = "A"

        alias = {
          name    = module.edge.domain_name
          zone_id = module.edge.hosted_zone_id
        }
      }

      www = {
        zone_id = module.zone[0].id
        name    = "www.${var.domain_name}"
        type    = "A"

        alias = {
          name    = module.edge.domain_name
          zone_id = module.edge.hosted_zone_id
        }
      }

      origin = {
        zone_id = module.zone[0].id
        name    = "origin.${var.domain_name}"
        type    = "A"

        alias = {
          name    = module.origin_alb.dns_name
          zone_id = module.origin_alb.zone_id
        }
      }
    },
    var.accelerator_port != null ? {
      accelerator = {
        zone_id = module.zone[0].id
        name    = "tcp.${var.domain_name}"
        type    = "A"

        alias = {
          name    = module.accelerator[0].dns_name
          zone_id = module.accelerator[0].hosted_zone_id
        }
      }
    } : {},
  )
}

module "alerts" {
  source  = "kn47ytv9mv/sns-topic/aws"
  version = "~> 1.0"

  name         = "${var.name}-alerts"
  display_name = "${var.name} alerts"

  subscriptions = var.alarm_email != null ? [
    { protocol = "email", endpoint = var.alarm_email },
  ] : []

  tags = var.tags
}

module "monitoring" {
  source  = "kn47ytv9mv/monitoring-baseline/aws"
  version = "~> 1.0"

  name_prefix   = var.name
  alarm_actions = [module.alerts.arn]
  ok_actions    = [module.alerts.arn]

  load_balancers = {
    origin = { arn_suffix = module.origin_alb.arn_suffix }
  }

  tags = var.tags
}

module "budget" {
  source  = "kn47ytv9mv/budget/aws"
  version = "~> 1.0"
  count   = var.monthly_budget != null ? 1 : 0

  name         = "${var.name}-monthly"
  limit_amount = var.monthly_budget

  notifications = [
    {
      threshold                 = 80
      notification_type         = "FORECASTED"
      subscriber_sns_topic_arns = [module.alerts.arn]
    },
  ]

  tags = var.tags
}

output "distribution_domain_name" {
  description = "The distribution's own cloudfront.net name — the architecture's entry point when no domain_name was supplied."
  value       = module.edge.domain_name
}

output "distribution_id" {
  description = "The ID of the distribution, for cache invalidation."
  value       = module.edge.id
}

output "origin_dns_name" {
  description = "DNS name of the origin load balancer the distribution pulls from."
  value       = module.origin_alb.dns_name
}

output "accelerator_dns_name" {
  description = "DNS name of the Global Accelerator. Null when no accelerator_port was supplied."
  value       = var.accelerator_port != null ? module.accelerator[0].dns_name : null
}

output "accelerator_ip_sets" {
  description = "Static anycast addresses of the Global Accelerator. Empty when no accelerator_port was supplied."
  value       = var.accelerator_port != null ? module.accelerator[0].ip_sets : []
}

output "web_acl_arn" {
  description = "ARN of the web ACL filtering requests at the edge."
  value       = module.edge_firewall.arn
}

output "alerts_topic_arn" {
  description = "ARN of the topic every alarm in this architecture notifies."
  value       = module.alerts.arn
}

output "alarm_count" {
  description = "Number of CloudWatch alarms the monitoring baseline created."
  value       = module.monitoring.alarm_count
}

output "name_servers" {
  description = "Name servers for the hosted zone, to delegate the domain to. Empty when no domain_name was supplied."
  value       = var.domain_name != null ? module.zone[0].name_servers : []
}
