mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }
}

mock_provider "aws" {
  alias = "edge"

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

mock_provider "random" {}

run "a_single_availability_zone_is_rejected" {
  command = plan

  variables {
    availability_zone_count = 1
  }

  expect_failures = [var.availability_zone_count]
}

run "without_a_domain_the_origin_is_reached_over_plain_http" {
  command = plan

  assert {
    condition     = length(module.origin_http_listener) == 1 && length(module.origin_https_listener) == 0
    error_message = "With no certificate to attach, the origin listener has to be the plain HTTP one."
  }

  assert {
    condition     = length(module.edge_certificate) == 0 && length(module.origin_certificate) == 0
    error_message = "No certificate should be requested when no domain name was supplied."
  }

  assert {
    condition     = length(module.zone) == 0 && length(module.records) == 0
    error_message = "No hosted zone or records should be created when no domain name was supplied."
  }

  assert {
    condition     = length(output.name_servers) == 0
    error_message = "Without a hosted zone there are no name servers to delegate to."
  }
}

run "a_domain_moves_the_origin_to_https_and_creates_both_certificates" {
  command = plan

  variables {
    domain_name = "example.com"
  }

  assert {
    condition     = length(module.origin_https_listener) == 1 && length(module.origin_http_listener) == 0
    error_message = "Once a certificate exists the origin should be reached over HTTPS, not HTTP."
  }

  assert {
    condition     = length(module.edge_certificate) == 1 && length(module.origin_certificate) == 1
    error_message = "The edge and the origin need separate certificates, in different regions."
  }

  assert {
    condition     = length(module.origin_health_check) == 1
    error_message = "A health check should measure the origin once it has a resolvable name."
  }
}

run "a_domain_creates_the_apex_www_and_origin_records" {
  command = plan

  variables {
    domain_name = "example.com"
  }

  assert {
    condition     = length(module.records) == 1
    error_message = "Supplying a domain name should create the record set."
  }

  assert {
    condition     = length(module.records[0].ids) == 3
    error_message = "Without an accelerator the record set is the apex, www, and origin names."
  }
}

run "an_accelerator_port_adds_the_accelerator_and_its_record" {
  command = plan

  variables {
    domain_name      = "example.com"
    accelerator_port = 5671
  }

  assert {
    condition     = length(module.accelerator) == 1
    error_message = "Supplying a port should create the accelerator."
  }

  assert {
    condition     = length(module.records[0].ids) == 4
    error_message = "The accelerator should add a fourth record alongside the apex, www, and origin names."
  }
}

run "no_accelerator_port_creates_no_accelerator" {
  command = plan

  assert {
    condition     = length(module.accelerator) == 0
    error_message = "An accelerator should only be created when a port is supplied."
  }

  assert {
    condition     = output.accelerator_dns_name == null
    error_message = "With no accelerator there is no accelerator DNS name to report."
  }
}

run "the_origin_load_balancer_is_monitored" {
  command = plan

  assert {
    condition     = module.monitoring.alarm_count == 3
    error_message = "The origin load balancer should get its 5XX, unhealthy host, and response time alarms."
  }

  assert {
    condition     = length(module.monitoring.alarm_names) == module.monitoring.alarm_count
    error_message = "Every alarm created should appear in the alarm_names output."
  }
}

run "a_geo_restriction_plans_as_a_whitelist" {
  command = plan

  variables {
    geo_restriction_countries = ["US", "CA", "GB"]
  }
}

run "a_budget_amount_creates_a_budget_notifying_the_alarm_topic" {
  command = plan

  variables {
    monthly_budget = "500"
  }

  assert {
    condition     = length(module.budget) == 1
    error_message = "Supplying a monthly amount should create a budget."
  }
}

run "no_budget_amount_creates_no_budget" {
  command = plan

  assert {
    condition     = length(module.budget) == 0
    error_message = "A budget should only be created when a monthly amount is supplied."
  }
}

run "an_alarm_email_subscribes_to_the_topic" {
  command = plan

  variables {
    alarm_email = "ops@example.com"
  }

  assert {
    condition     = length(module.alerts.subscription_arns) == 1
    error_message = "Supplying an address should subscribe it to the alarm topic."
  }
}
