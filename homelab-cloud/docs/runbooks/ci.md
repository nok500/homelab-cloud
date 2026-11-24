# Runbook: CI (Argo Workflows, Argo Events, rootless BuildKit)

Design: [ADR 0015](../decisions/0015-ci-argo-workflows-buildkit.md). Workflows run in namespace `ci`; images go to
Harbor project `ci` (https://registry.lab.macpro/harbor/projects → ci).

## How a commit gets built

1. Every 2 min the `poll` EventSource fires, and the `poll` Sensor starts workflow `ci-poll-*`.
2. `ci-poll` reads `main`'s commit (`git ls-remote`, the repo is public) and applies workflow `ci-build-<sha>`.
   That step is memoized on the commit (ConfigMap `ci-submitted-commits`): a commit is submitted once.
3. `ci-build` runs one rootless BuildKit pod per image. It builds from GitHub at the commit and pushes
   `registry.lab.macpro/ci/<image>:<sha>`; Harbor scans it on push.

## Access

| What | Where | Login |
|---|---|---|
| Argo Workflows UI | https://workflows.lab.macpro | **Login** → Keycloak as `labadmin` (group `argo-workflows-admins`). Nobody else gets in |
| CLI | `kubectl -n ci get workflows` (`wf`), `kubectl -n ci logs <pod> -c main` | lab kubeconfig |
| Build logs after the pod is gone | Grafana → Explore → Loki: `{namespace="ci", container="main"}` | |
| Images | Harbor project `ci` | `labadmin` via OIDC |

## Check

```sh
make verify                                        # section 13
kubectl -n ci get workflows --sort-by=.metadata.creationTimestamp | tail
kubectl -n ci get eventbus,eventsources,sensors
kubectl -n ci get cm ci-submitted-commits -o jsonpath='{.data}' | head -c 400   # commits already submitted
```

## Common jobs

| Job | How |
|---|---|
| Rebuild a commit | `kubectl -n ci delete workflow ci-build-<sha>`, then remove its key from ConfigMap `ci-submitted-commits` (`kubectl -n ci edit cm ci-submitted-commits`); the next poll submits it again. Or submit by hand: `kubectl -n ci create -f -` with a Workflow using `workflowTemplateRef: {name: ci-build}` and parameter `sha` |
| Build now, without waiting for the poll | `kubectl -n ci create -f - <<<'{"apiVersion":"argoproj.io/v1alpha1","kind":"Workflow","metadata":{"generateName":"ci-poll-"},"spec":{"workflowTemplateRef":{"name":"ci-poll"}}}'` |
| Pause CI | `kubectl -n ci scale deploy -l sensor-name=poll --replicas=0` (Argo CD scales it back on its next sync: suspend the `ci` app's auto-sync first if it must stay paused) |
| Add an image to the build | another step in `ci-build` (`k8s/platform/ci/workflowtemplates.yaml`) calling template `build-image` with its `path` and `image` |
| Give someone the UI | add them to `argo-workflows-admins` in `terraform/identity`, `make identity` |
| New moby seccomp profile | bump the tag in `scripts/seccomp-buildkit.py`, delete `terraform/talos/seccomp/UPSTREAM.sha256`, run it, review the diff, `scripts/tf.sh talos apply` (no reboot) |

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Build pod fails at once: `unshare ... operation not permitted` or `newuidmap` errors | The worker lacks the Talos patch: `talosctl -n <worker> read /proc/sys/user/max_user_namespaces` must be > 0 and `talosctl -n <worker> ls /var/lib/kubelet/seccomp/profiles` must list `buildkit-rootless.json`; else `scripts/tf.sh talos apply` |
| `RUN` step fails: `unable to join session keyring: operation not permitted` | The profile on the node is older than the ENOSYS keyring rule: regenerate (`scripts/seccomp-buildkit.py`), `scripts/tf.sh talos apply` |
| Pod rejected: `violates PodSecurity "baseline"` | Something asked for more than baseline (privileged, Unconfined seccomp, unmasked /proc). The build pod must use `seccompProfile: Localhost` and `--oci-worker-no-process-sandbox` |
| Push fails: `401`/`denied` | Robot secret differs between Harbor and OpenBao: `secret/ci/harbor-robot` vs the seed `harbor-ci-robot-secret`; bump `secret_wo_version` in `terraform/identity` and `make identity` |
| Push fails: `x509: certificate signed by unknown authority` | On `registry.lab.macpro/v2/...`: BuildKit isn't reading `/etc/buildkit/buildkitd.toml` or the `lab-root-ca` Secret (`kubectl -n ci get cm buildkitd secret lab-root-ca`). On `.../service/token`: that's buildctl, which only trusts `SSL_CERT_DIR` (`/etc/ssl/certs:/etc/lab-ca` in `ci-build`) |
| `ci-poll`'s submit step: `open /tmp/manifest.yaml: read-only file system` | The `podSpecPatch` that mounts `/tmp` into Argo's `init` container is missing from `ci-poll` |
| Argo server exits: `secrets "argo-server-sso" is forbidden` | The chart only lets the server read Secrets in `sso.rbac.secretWhitelist`: `argo-server-sso` must be listed |
| No `ci-poll` workflows appear | `kubectl -n ci logs -l sensor-name=poll` and `-l eventsource-name=poll`; the EventBus: `kubectl -n ci get eventbus default -o yaml` (status conditions) |
| Polls succeed but nothing builds | The commit is already in `ci-submitted-commits` (see *Rebuild a commit*) |
| UI login: "permission denied" / empty | Not in `argo-workflows-admins`, or the `argo-admin.service-account-token` Secret is missing in `argo` |
| UI login loops or `invalid_client` | Client secret differs between Keycloak and `argo/argo-server-sso`: OpenBao `secret/argo/sso` vs the seed, then `make identity` |
