#!/usr/bin/env bash

echo "Initializing Terraform configurations..."

# Initialize root configuration
terraform init

# Initialize each standalone module
for dir in network vpc-peering workload; do
    echo "Initializing $dir..."
    (cd "$dir" && terraform init)
done

echo "Applying Terraform configurations..."

# Apply in dependency order
echo "Step 1: Applying network module..."
terraform apply --auto-approve -target module.network

echo "Step 2: Applying workload module..."
terraform apply --auto-approve -target module.workload

echo "Step 3: Applying VPC peering module..."
terraform apply --auto-approve -target module.vpc-peering
