# terraform-aws-architecture-global

Terraform module for a global edge architecture — a CloudFront
distribution and web ACL in front of a regional load balancer origin,
with an optional Global Accelerator for traffic CloudFront cannot
carry.

## Cost

CloudFront bills per gigabyte served and per request, at rates that vary
by edge region, plus a charge for each invalidation path beyond the
monthly free allotment. `price_class` is the main lever: `PriceClass_100`
serves only North America and Europe at the lowest rates, while
`PriceClass_All` serves every region at the highest. The web ACL bills
per month and per million requests inspected, and each managed rule group
adds its own monthly charge.

The origin side carries the standing charges: a NAT gateway per
availability zone, an application load balancer, and the instances or
containers behind it, which this architecture does not create. A Global
Accelerator adds a fixed hourly charge plus a premium per gigabyte on
top of ordinary data transfer, and bills that hourly charge whether or
not any traffic flows — leave `accelerator_port` null unless something
genuinely needs it.

## Design

Every resource comes from a published module in this family. This module
contains no `resource` blocks of its own; it is wiring and nothing else.

### What it builds

| Layer | Contents |
|---|---|
| Edge | CloudFront distribution, WAFv2 web ACL with AWS's common rule set and an IP rate limit, optional geographic whitelist |
| Origin | VPC across `availability_zone_count` zones, internet-facing application load balancer, target group, and a listener whose protocol depends on whether a certificate exists |
| Acceleration | Optional Global Accelerator with one TCP listener and an endpoint group targeting the origin load balancer |
| DNS | Optional public hosted zone, apex, `www`, and `origin` records, plus a latency-measuring health check against the origin |
| Cross-cutting | Customer managed KMS key, S3 log bucket, SNS alarm topic, three CloudWatch alarms, optional budget |

### Two regions, on purpose

CloudFront is global, but two of its dependencies are not: **an ACM
certificate for a distribution must live in `us-east-1`, and a
`CLOUDFRONT`-scoped web ACL must be created there too.** Both are real
AWS constraints rather than defaults, and neither can be satisfied by a
certificate in the region the origin runs in.

This module therefore declares a second provider aliased `edge`, pinned
to `us-east-1`, and passes it to the edge certificate, the web ACL, and
the accelerator. `region` controls only where the origin infrastructure
lands. Setting `region = "us-east-1"` is fine and simply makes both
providers point at the same place.

The origin needs its own certificate, in the origin's region, because it
is a different load balancer answering on a different name. That is why
a single `domain_name` produces two certificates.

### What `domain_name` changes

Left null, the distribution answers only on its own `*.cloudfront.net`
name, no certificates are requested, and **the origin listener falls
back to plain HTTP on port 80** — there is no certificate to attach, so
CloudFront reaches the origin unencrypted across the public internet.
This is acceptable for a demonstration and is not acceptable for
anything carrying real traffic.

Set `domain_name` and the shape changes: a hosted zone, a certificate in
`us-east-1` covering the apex and `www`, a second certificate in the
origin region covering `origin.<domain>`, an HTTPS origin listener, and
alias records for all three names. CloudFront then reaches the origin
over HTTPS by name rather than by load balancer hostname.

**A newly created hosted zone is not authoritative until the registrar
points at it**, and neither certificate can validate until it is. Take
the `name_servers` output to the registrar; until you do, the apply
waits on certificate validation and eventually times out.

### CloudFront or Global Accelerator

These solve different problems and this architecture can run either or
both. CloudFront caches HTTP content at the edge and is the right answer
for a website or an API. A Global Accelerator gives one fixed pair of
anycast IP addresses that AWS's own backbone routes to the nearest
healthy endpoint on every packet, which matters for a protocol CloudFront
does not carry or for a client that cannot re-resolve DNS. Reach for
CloudFront first; add `accelerator_port` only once the public internet
path is a measured problem.

### Things it deliberately does not do

Trivy reports three findings on this configuration, all of them choices
rather than oversights:

- **Unrestricted egress** from the origin security group. An origin that
  cannot reach the internet cannot install packages or call a
  third-party API. Narrow this once you know what the workload talks to.
- **An internet-facing load balancer**, which is what an origin
  CloudFront can reach has to be.
- **No access logging on the log bucket itself.**

One weakness Trivy does *not* report is worth more attention than any of
them: **the origin security group accepts traffic from anywhere on 80
and 443**, so the origin is reachable directly, bypassing the web ACL
and the cache. CloudFront publishes no small stable address range worth
hard-coding; the real fix is the managed prefix list
`com.amazonaws.global.cloudfront.origin-facing` combined with a secret
header CloudFront adds and the origin checks. Neither is modeled here.
Close this before putting real traffic through it.

## Usage

```hcl
module "edge" {
  source  = "kn47ytv9mv/architecture-global/aws"
  version = "~> 1.0"

  name        = "staging"
  alarm_email = "ops@example.com"
}
```

A production distribution on a custom domain, restricted to three
countries, with an accelerator for a message broker and a budget:

```hcl
module "edge" {
  source = "github.com/kn47ytv9mv/terraform-aws-architecture-global"

  name                    = "production"
  region                  = "eu-west-1"
  availability_zone_count = 3

  domain_name = "example.com"
  price_class = "PriceClass_100"

  geo_restriction_countries = ["US", "CA", "GB"]
  accelerator_port          = 5671

  alarm_email    = "ops@example.com"
  monthly_budget = "3000"

  tags = {
    Environment = "production"
  }
}
```

## Requirements

| Name | Version |
|---|---|
| terraform | >= 1.9 |
| aws | ~> 6.61 |

## Providers

| Name | Version |
|---|---|
| aws | ~> 6.61 |
| aws.edge | ~> 6.61 |

## Inputs

| Name | Description | Default | Required |
|---|---|---|---|
| region | Region the origin infrastructure is created in. The CloudFront distribution, its certificate, and its web ACL are always created in `us-east-1`, which AWS requires regardless of this setting. | `"us-east-1"` | no |
| name | Name prefix applied to every resource, so one account can hold several copies of this architecture without collision. | `"global"` | no |
| vpc_cidr | IPv4 range for the origin VPC. | `"10.0.0.0/16"` | no |
| availability_zone_count | Availability zones the origin load balancer spreads across. | `2` | no |
| domain_name | Domain served at the edge. Setting it creates a public hosted zone, a certificate in `us-east-1`, and an alias record pointing at the distribution. If null, the distribution answers only on its own `cloudfront.net` name. | `null` | no |
| price_class | Edge locations the distribution serves from. `'PriceClass_100'` is North America and Europe only and costs least; `'PriceClass_All'` serves every region at the highest rate. | `"PriceClass_All"` | no |
| geo_restriction_countries | ISO 3166-1 alpha-2 country codes permitted to reach the distribution. If null, no geographic restriction applies. | `null` | no |
| accelerator_port | TCP port to expose through a Global Accelerator, for a protocol CloudFront cannot carry. If null, no accelerator is created and the architecture is CloudFront only. | `null` | no |
| health_check_path | Path Route 53 requests when measuring origin health from each of its checker regions. | `"/healthz"` | no |
| alarm_email | Address subscribed to the alarm topic. An email subscription stays pending until the recipient confirms it, so alarms deliver nothing until then. | `null` | no |
| monthly_budget | Monthly spend in USD to alarm on, as a string. If null, no budget is created. | `null` | no |
| tags | A map of tags applied to every resource in the architecture. | `null` | no |

## Outputs

| Name | Description |
|---|---|
| distribution_domain_name | The distribution's own `cloudfront.net` name — the architecture's entry point when no `domain_name` was supplied. |
| distribution_id | The ID of the distribution, for cache invalidation. |
| origin_dns_name | DNS name of the origin load balancer the distribution pulls from. |
| accelerator_dns_name | DNS name of the Global Accelerator. Null when no `accelerator_port` was supplied. |
| accelerator_ip_sets | Static anycast addresses of the Global Accelerator. Empty when no `accelerator_port` was supplied. |
| web_acl_arn | ARN of the web ACL filtering requests at the edge. |
| alerts_topic_arn | ARN of the topic every alarm in this architecture notifies. |
| alarm_count | Number of CloudWatch alarms the monitoring baseline created. |
| name_servers | Name servers for the hosted zone, to delegate the domain to. Empty when no `domain_name` was supplied. |

## License

MIT — see [LICENSE.md](LICENSE.md).
