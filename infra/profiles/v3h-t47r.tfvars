# v3h T47r (plan 3b, human-approved 2026-11-12): one attempt to reproduce the run-6 gateway 401.
# Applied on top of lz-5-reference.tfvars + v3h-baseline.tfvars, INSTEAD of v3h-block2.tfvars.
# Run-6 setup as recorded: IAP policy V1, no gateway VPC egress. Paid (gateway hours): same-day teardown.
enable_v2_gateway             = true
enable_v2_gateway_vpc         = false
v2_gateway_iap_policy_version = "V1"
