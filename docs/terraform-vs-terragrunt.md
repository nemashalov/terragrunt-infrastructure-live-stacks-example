## Intro
- This repo is an `infrastructure-live` example: production- and non-production-account directories contain Terragrunt definitions that reference reusable Terraform modules from a separate catalog.
- Terragrunt stacks describe all units that must deploy together; Terragrunt handles provider/backend generation and shared inputs so individual stacks stay concise.
- In plain Terraform you must hand-write each environment’s provider and backend files because there is no built-in inheritance or code generation across folders.

## What Is a Stack?
- A stack is a Terragrunt construct representing a group of related units (Terraform modules) that should be deployed, planned, or destroyed together.
- Each stack has a `terragrunt.stack.hcl` file listing its units, their sources, environment-specific values, and dependency wiring (e.g., `service`, `db`, security groups).

## Terraform vs. Terragrunt Structure

### Pure Terraform Layout
- Each environment (e.g. `non-prod/us-east-1/stateful-ec2-asg-service`) holds its own `provider.tf`, `backend.tf`, and stack-specific `*.tf` files.
- Provider blocks are required to configure which cloud(s) Terraform talks to, authentication settings, and default regions; without Terragrunt, every directory must declare one explicitly.
- Backend blocks (often placed in `backend.tf`) tell Terraform where to store state; pure Terraform expects that configuration in every working directory, so you must copy it manually or script extra tooling.
- Shared modules are referenced directly, so every folder repeats boilerplate for AWS provider, remote state, tagging, and dependency wiring.
- To stay DRY you’d either copy/paste the same snippets or create thin wrapper modules—both approaches are fragile and hard to keep consistent.
- Terraform lacks built-in inheritance between directories, so changes to providers/backends must be propagated manually to every environment.

### Terragrunt Layout in This Repo
- Terraform code lives in a separate “catalog” repo; this repository contains only “live” configuration expressed as Terragrunt stacks.
- Directory hierarchy mirrors AWS scope: `account` → `region` → `stack`. Accounts are `non-prod` and `prod`; each contains `us-east-1/stateful-ec2-asg-service`.
- Every stack is represented by a single `terragrunt.stack.hcl` that orchestrates multiple modules (“units”) such as `service`, `db`, `asg_sg`, and `sg_to_db_sg_rule`.
- Modules are consumed through Git sources, so pinning specific versions or refs is straightforward and centralized.

## How Terragrunt Enforces DRY

### 1. Hierarchical Configuration Includes
- `root.hcl` executes in every stack and automatically loads the nearest `account.hcl` and `region.hcl` via `find_in_parent_folders`.  
- Account- and region-specific values (`account_name`, `aws_account_id`, `aws_region`) live in a single place and are inherited everywhere without duplication.

### 2. Generated Provider and Backend Blocks
- `generate "provider"` in `root.hcl` emits an identical `provider.tf` for every stack, including the `allowed_account_ids` guard.
- The `remote_state` block defines the S3 backend once, derives bucket names from account/region, and generates `backend.tf` files automatically.
- When requirements change (e.g., different DynamoDB lock table, encryption settings) you edit one file and every stack picks it up.

### 3. Automatic Input Propagation
- `inputs = merge(local.account_vars.locals, local.region_vars.locals)` exposes account and region locals to every unit, so Terraform modules can rely on consistent variables without redefining them.
- Additional shared inputs can be added centrally and flow to all stacks instantly.

### 4. Stack-Level Composition Only
- Each `terragrunt.stack.hcl` focuses on environment-specific values: resource names, instance sizes, dependency paths, credentials (placeholder in this example).
- Dependencies between modules are expressed declaratively (`db_path`, `asg_sg_path`, `sg_path`, `db_path`), keeping wiring logic in one place per stack.
- Because the stack files stay small, copying from non-prod to prod typically requires changing only the values that truly differ (e.g., names, sizes, credentials).

### 5. Separation Between Catalog and Live Config
- The **catalog** repository stores reusable Terraform modules—the building blocks (ASG service, database, security groups) that define how to provision a pattern. It’s versioned like any other library and doesn’t contain environment-specific values.
- The **live configuration** repository (this repo) references those catalog modules via Terragrunt stacks and supplies concrete inputs for each account/region/environment combination.
- Teams evolve module logic once in the catalog, cut a version (e.g., `v0.2.0`), and then bump the `source`/`version` in the live repo to roll it out. This keeps module code centralized while live configs stay thin and environment-focused.

## Practical Benefits
- **Consistency:** Provider, backend, and common locals are enforced globally; no risk of a forgotten setting in one environment.
- **Lower maintenance:** Adding a new account or region involves copying a tiny `account.hcl`/`region.hcl` and pointing stack folders at existing modules.
- **Safer changes:** Updates to shared concerns happen in one file, shrinking the blast radius and review surface.
- **Faster onboarding:** Clear hierarchy (`root.hcl` → `account.hcl` → `region.hcl` → stack) mirrors AWS mental model, so newcomers quickly see where to put configuration.
