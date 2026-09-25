variable "region" {
  default     = "us-east-1"
  description = "Region the origin infrastructure is created in. The CloudFront distribution, its certificate, and its web ACL are always created in us-east-1, which AWS requires regardless of this setting."
}

variable "name" {
  default     = "global"
  description = "Name prefix applied to every resource, so one account can hold several copies of this architecture without collision."
}

variable "vpc_cidr" {
  default     = "10.0.0.0/16"
  description = "IPv4 range for the origin VPC."
}

variable "availability_zone_count" {
  default     = 2
  description = "Availability zones the origin load balancer spreads across."

  validation {
    condition     = var.availability_zone_count >= 2
    error_message = "An application load balancer requires subnets in at least two availability zones."
  }
}

variable "domain_name" {
  default     = null
  description = "Domain served at the edge. Setting it creates a public hosted zone, a certificate in us-east-1, and an alias record pointing at the distribution. If null, the distribution answers only on its own cloudfront.net name."
}

variable "price_class" {
  default     = "PriceClass_All"
  description = "Edge locations the distribution serves from. 'PriceClass_100' is North America and Europe only and costs least; 'PriceClass_All' serves every region at the highest rate."
}

variable "geo_restriction_countries" {
  default     = null
  description = "ISO 3166-1 alpha-2 country codes permitted to reach the distribution. If null, no geographic restriction applies."
}

variable "accelerator_port" {
  default     = null
  description = "TCP port to expose through a Global Accelerator, for a protocol CloudFront cannot carry. If null, no accelerator is created and the architecture is CloudFront only."
}

variable "health_check_path" {
  default     = "/healthz"
  description = "Path Route 53 requests when measuring origin health from each of its checker regions."
}

variable "alarm_email" {
  default     = null
  description = "Address subscribed to the alarm topic. An email subscription stays pending until the recipient confirms it, so alarms deliver nothing until then."
}

variable "monthly_budget" {
  default     = null
  description = "Monthly spend in USD to alarm on, as a string. If null, no budget is created."
}

variable "tags" {
  default     = null
  description = "A map of tags applied to every resource in the architecture."
}
