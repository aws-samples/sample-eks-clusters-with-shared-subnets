#!/usr/bin/env bash

terraform destroy --auto-approve -target module.vpc-peering
terraform destroy --auto-approve -target module.network -target module.workload
