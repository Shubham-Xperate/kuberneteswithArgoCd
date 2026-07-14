# Terraform - Azure infrastructure for the e-commerce DevOps lab

This directory provisions the Azure infrastructure (networking, ACR, AKS,
Application Gateway + WAF) for the .NET + Angular e-commerce app used in
this DevOps practice project.

**This code has not been applied in this session** - no Azure credentials
were available. It is meant to be reviewed, then run by you against your
own Azure subscription.

## Layout

- `modules/` - reusable building blocks: `networking`, `acr`, `aks`, `appgw-waf`
- `environments/dev/` and `environments/prod/` - root configs that wire the
  modules together with environment-specific sizing/settings

## Usage

From either `environments/dev` or `environments/prod`:

```bash
cp terraform.tfvars.example terraform.tfvars   # then edit values for your subscription
az login
az account set --subscription "<your-subscription-id>"

terraform init
terraform plan  -var-file="terraform.tfvars"
terraform apply -var-file="terraform.tfvars"
```

Destroy with `terraform destroy -var-file="terraform.tfvars"` when done, to
avoid ongoing Azure charges (AKS, Application Gateway, and NAT Gateway all
bill continuously while running).

Remote state (`backend "azurerm" {}` in each `providers.tf`) is commented
out by default so this works standalone with local state; see the comments
there for how and why to enable it once you're working as a team.
