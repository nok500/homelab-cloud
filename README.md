# lab

Hands-on infrastructure labs, one folder each. Every lab is self-contained: its own `Makefile`, docs, tools
(`<lab>/.tools`) and local state (`<lab>/.cache`, git-ignored). Run `make` from inside the lab's folder.

| Lab | What it is |
|---|---|
| [homelab-cloud](homelab-cloud/) | A production-shaped AWS-like platform built as code on one Mac Pro: VPC, "EKS" on Talos, managed-service equivalents, GitOps, DevSecOps |

## Shared tooling (repo root)

The git hooks and lint config apply to the whole repo: `.pre-commit-config.yaml`, `.yamllint.yaml`, `.tflint.hcl`,
`.editorconfig`. The hook tools currently come from `homelab-cloud/.tools/bin`:

```sh
git clone git@github.com:nok500/lab.git && cd lab/homelab-cloud
make hooks   # pinned tools into homelab-cloud/.tools, then the pre-commit hook for the whole repo
make lint    # pre-commit on this lab's files
```
