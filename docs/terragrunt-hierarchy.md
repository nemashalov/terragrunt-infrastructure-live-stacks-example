## Terragrunt Hierarchy Explained

This repo follows the canonical Terragrunt layout: account → region → resource stack. The seemingly inverted placement of `root.hcl` (top-level) and `region.hcl` (nested) is intentional, because Terragrunt evaluates `root.hcl` *from the perspective of whichever stack or unit includes it*. That lets `root.hcl` use helper functions such as `find_in_parent_folders` to “look up” context files that live closer to the stack you are running.

### Why `region.hcl` lives under each region directory
- Each AWS region gets its own settings (e.g., `aws_region`, per-region tags, AMI IDs). Keeping those in `prod/us-east-1/region.hcl`, `non-prod/us-west-2/region.hcl`, etc. keeps the values near the stacks that consume them.
- Account-scoped data (`account.hcl`) sits one level higher so that every region beneath inherits the same account number, partitions, IAM defaults.
- When you duplicate a region, you copy the whole directory (with its `region.hcl`) and immediately have correct defaults for every stack inside.

### How `find_in_parent_folders` ties it together
Inside `root.hcl`:

```
locals {
  account_vars = read_terragrunt_config(find_in_parent_folders("account.hcl"))
  region_vars  = read_terragrunt_config(find_in_parent_folders("region.hcl"))
}
```

Key points:
- `find_in_parent_folders("region.hcl")` starts from the directory of the Terragrunt file you invoked (e.g., `prod/us-east-1/stateful-ec2-asg-service`). It walks upward—`stateful-ec2-asg-service/`, then `us-east-1/`, etc.—until it finds a file named `region.hcl`.
- Even though `root.hcl` resides at the repo top, Terragrunt treats its `find_in_parent_folders` call as if it were running inside the child directory that included it. That’s why it can discover `prod/us-east-1/region.hcl` despite being “higher” in the tree.
- The same mechanism loads `account.hcl`. From the stack directory, Terragrunt walks past `us-east-1/` and finds `prod/account.hcl`.

### Execution flow when you run a stack
1. You execute `terragrunt run-all apply` inside `prod/us-east-1/stateful-ec2-asg-service`.
2. Terragrunt loads the local `terragrunt.stack.hcl`, which (directly or via generated units) includes `root.hcl`.
3. While evaluating `root.hcl`, Terragrunt resolves account/region context with `find_in_parent_folders`, merges them into `inputs`, and generates shared provider/remote-state blocks.
4. Units inside the stack automatically inherit those inputs, so they know which AWS account/region to target and where to store state.

### Mental model
- Think “bottom-up resolution”: stacks live deepest, contain business logic, and *pull in* shared context.
- `find_in_parent_folders` is the glue—no matter where you copy a stack, as long as it sits under the right account/region directories, it inherits the right configuration without any path edits.
- This pattern keeps global settings DRY in `root.hcl`, while still letting you customize per-account/per-region behavior alongside the stacks that need it.

### TL;DR
- `root.hcl` is global scaffolding; `account.hcl`/`region.hcl` are scoped context files.
- Terragrunt evaluates `root.hcl` from the child stack’s location, so “top-level” code can safely read “lower-level” files via `find_in_parent_folders`.
- Organizing the tree by account/region ensures each stack automatically picks up the closest matching context as you add environments.
