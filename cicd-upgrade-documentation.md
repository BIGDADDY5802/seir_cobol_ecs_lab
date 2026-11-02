# SEIR Foundations — Module 3 / Lab 01
## CI/CD Upgrade: GitHub Actions Quality Gates

[![CI](https://github.com/BIGDADDY5802/seir_cobol_ecs_lab/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/BIGDADDY5802/seir_cobol_ecs_lab/actions/workflows/ci.yml)
![Branch Protection](https://img.shields.io/badge/main-protected-success)
![Actions Pinned](https://img.shields.io/badge/actions-SHA%20pinned-success)
![Snyk](https://img.shields.io/badge/Snyk-container%20scan-4C4A73?logo=snyk&logoColor=white)
![Gitleaks](https://img.shields.io/badge/Gitleaks-secret%20scan-blue)
![Terraform](https://img.shields.io/badge/Terraform-validate-7B42BC?logo=terraform&logoColor=white)
![ShellCheck](https://img.shields.io/badge/ShellCheck-lint-4EAA25?logo=gnubash&logoColor=white)
![AWS Credentials](https://img.shields.io/badge/AWS%20credentials%20in%20CI-none-success)

**Student:** Jerome Hunter
**Date:** 2026-11-01
**Repository:** `BIGDADDY5802/seir_cobol_ecs_lab`

> This document covers the CI/CD upgrade added after completing the lab (see `documentation.md` and `Runbook.md`). It implements README "Next labs" item 5: pull-request quality gates in GitHub Actions.
>
> Account ID is redacted as `<ACCOUNT_ID>`. Secret values never appear in this document or the repository.

---

### Overview

Every pull request into `main`, and every push to `main`, runs four jobs in parallel. All four must pass before anything can merge, and branch protection enforces that rule for every user, including the repository owner.

```text
Pull request / push to main
  └─ GitHub Actions workflow: CI (.github/workflows/ci.yml)
     ├─ COBOL build and invariant test
     │    ├─ docker build (GnuCOBOL compile)
     │    ├─ docker run → must print FINANCIAL INVARIANT PASSED
     │    └─ Snyk container scan → fails on CRITICAL (documented exceptions in .snyk)
     ├─ Terraform fmt and validate   (no backend, no AWS credentials)
     ├─ ShellCheck deploy.sh
     └─ Secret scan
          ├─ Gitleaks across full git history
          └─ Block AWS account ID (value read from repository secret)
  └─ Branch protection on main: all 4 checks required, admins included
```

| Job | What it catches | Lab equivalent |
|---|---|---|
| COBOL build and invariant test | Compile errors, financial logic errors | Failure drills 5.1 and 5.2 |
| Snyk container scan | Critical vulnerabilities in the image | ECR scan-on-push, shifted left |
| Terraform fmt and validate | Unformatted or invalid infrastructure code | `terraform plan` review |
| ShellCheck | Common Bash bugs in `deploy.sh` | Manual script review |
| Secret scan | Keys, tokens, account ID in any commit | Manual `git grep` scans |

### Design decisions

- **No AWS credentials in CI.** None of the checks need AWS. Terraform runs `init -backend=false`, so it never touches the state bucket. Deployment from Actions is deferred to a later OIDC-based upgrade.
- **Least-privilege token.** The workflow default is `permissions: contents: read`. Only the secret-scan job gets `pull-requests: write`, so Gitleaks can comment on a leaking line.
- **Actions pinned to commit SHAs.** Tags can be moved by an action's owner; a SHA cannot. Each `uses:` line pins the exact reviewed code, with the version in a comment.
- **Minimal third-party code.** ShellCheck is preinstalled on GitHub's Ubuntu runners and is called directly instead of through an extra action.
- **Fail on CRITICAL for now.** The base image carries known HIGH findings. The Snyk threshold starts at CRITICAL and is tightened to HIGH as part of base-image hardening.

---

### 1. Create a working branch

All changes went through a branch and pull request, so the first PR tested the new checks.

```bash
git switch main && git pull
git switch -c ci/github-actions
mkdir -p .github/workflows
```

### 2. Verify action versions and pin by SHA

Versions were looked up from GitHub directly rather than assumed:

```bash
for r in actions/checkout hashicorp/setup-terraform gitleaks/gitleaks-action; do
  tag=$(gh release view --repo "$r" --json tagName -q .tagName)
  sha=$(gh api "repos/$r/commits/$tag" -q .sha)
  echo "$r  $tag  $sha"
done
gh api repos/snyk/actions/tags -q '.[0] | "\(.name)  \(.commit.sha)"'
```

| Action | Version | Pinned SHA |
|---|---|---|
| `actions/checkout` | v7.0.1 | `3d3c42e5aac5ba805825da76410c181273ba90b1` |
| `hashicorp/setup-terraform` | v4.0.1 | `dfe3c3f87815947d99a8997f908cb6525fc44e9e` |
| `gitleaks/gitleaks-action` | v3.0.0 | `e0c47f4f8be36e29cdc102c57e68cb5cbf0e8d1e` |
| `snyk/actions/docker` | v1.0.0 | `9adf32b1121593767fc3c057af55b55db032dc04` |

### 3. Store repository secrets

Secrets were entered at an interactive prompt or piped from memory, so values never appear in commands, shell history, files, or logs.

```bash
gh secret set AWS_ACCOUNT_ID          # prompted; value not echoed
printf '%s' "$SNYK_TEST" | gh secret set SNYK_TOKEN   # from a verified in-memory variable
gh secret list
```

```text
NAME            UPDATED
AWS_ACCOUNT_ID  ...
SNYK_TOKEN      ...
```

The Snyk token was verified against Snyk's API before being saved:

```bash
read -rs SNYK_TEST && echo "token length: ${#SNYK_TEST}"
curl -s -o /dev/null -w "Snyk says HTTP %{http_code}\n" \
  -H "Authorization: token $SNYK_TEST" "https://api.snyk.io/rest/self?version=2024-10-15"
```

```text
Snyk says HTTP 200
```

### 4. The workflow

`.github/workflows/ci.yml`:

```yaml
name: CI

on:
  pull_request:
    branches: [main]
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

defaults:
  run:
    shell: bash

jobs:
  cobol-build-test:
    name: COBOL build and invariant test
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - name: Build image
        run: docker build --platform linux/amd64 -t seir-cobol-finance:ci .
      - name: Run batch job and check invariant
        run: |
          docker run --rm --platform linux/amd64 seir-cobol-finance:ci | tee output.txt
          grep -q "FINANCIAL INVARIANT PASSED" output.txt
      - name: Snyk container scan
        uses: snyk/actions/docker@9adf32b1121593767fc3c057af55b55db032dc04 # v1.0.0
        env:
          SNYK_TOKEN: ${{ secrets.SNYK_TOKEN }}
        with:
          image: seir-cobol-finance:ci
          # Fail only on CRITICAL until the base image is hardened; tighten to high afterwards.
          args: --file=Dockerfile --severity-threshold=critical --policy-path=.snyk

  terraform:
    name: Terraform fmt and validate
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: terraform
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - uses: hashicorp/setup-terraform@dfe3c3f87815947d99a8997f908cb6525fc44e9e # v4.0.1
        with:
          terraform_version: "1.17.1"
      - name: Format check
        run: terraform fmt -check -recursive -diff
      - name: Init (no backend, no AWS credentials)
        run: terraform init -backend=false -input=false
      - name: Validate
        run: terraform validate

  shellcheck:
    name: ShellCheck deploy.sh
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - name: Lint
        run: shellcheck deploy.sh

  secret-scan:
    name: Secret scan
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          fetch-depth: 0
      - name: Gitleaks
        uses: gitleaks/gitleaks-action@e0c47f4f8be36e29cdc102c57e68cb5cbf0e8d1e # v3.0.0
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
      - name: Block AWS account ID
        env:
          ACCOUNT_ID: ${{ secrets.AWS_ACCOUNT_ID }}
        run: |
          if [ -z "$ACCOUNT_ID" ]; then
            echo "AWS_ACCOUNT_ID secret not set; skipping account ID check"
            exit 0
          fi
          if git grep -n "$ACCOUNT_ID"; then
            echo "::error::AWS account ID found in repository files"
            exit 1
          fi
          echo "No AWS account ID found"
```

Key settings:

| Setting | Purpose |
|---|---|
| `shell: bash` | Runs steps with `-eo pipefail`, so a failure inside a pipe still fails the step |
| `concurrency` | Cancels an older run on the same branch when a newer push arrives |
| `fetch-depth: 0` | Gives Gitleaks the full history, not just the latest commit |
| `--policy-path=.snyk` | Applies documented vulnerability exceptions (see section 5) |

### 5. Snyk finding triage and documented exception

The first authenticated Snyk run failed the build on one CRITICAL finding:

```text
✗ Critical severity vulnerability found in zlib/zlib1g
  Info: https://security.snyk.io/vuln/SNYK-DEBIAN12-ZLIB-6008963
  Image layer: Introduced by your base image (debian:bookworm-slim)
Tested 92 dependencies for known issues, found 1 issue.
```

**Investigation:** the finding is CVE-2023-45853, which affects zlib's `contrib/minizip` component. The Debian security tracker marks bookworm as `<ignored>` because minizip is not built into the `zlib1g` binary package. The COBOL batch job does not use minizip. Snyk's suggested base-image upgrade (`debian:13.6-slim`) still reported 3 critical findings, so changing base images was not a fix in itself.

Note that ECR rated the same zlib issue HIGH while Snyk rated it CRITICAL. Scanners can disagree on severity, which is why findings are verified against the distribution's own tracker before acting.

**Decision:** a time-boxed risk acceptance, recorded in `.snyk`:

```yaml
# Snyk (https://snyk.io) policy file
version: v1.25.0
ignore:
  SNYK-DEBIAN12-ZLIB-6008963:
    - '*':
        reason: >-
          CVE-2023-45853 affects zlib's contrib/minizip. Debian marks bookworm
          as <ignored>: minizip is not built into the zlib1g binary package used
          by this image, and the COBOL batch job does not use minizip.
          Revisit during base-image hardening.
        expires: 2027-02-01T00:00:00.000Z
        created: 2026-11-02T05:00:00.000Z
patch: {}
```

- Only this exact finding is excepted. Any new CRITICAL still fails the build.
- The exception **expires on 2027-02-01**, after which the build fails again until it is re-reviewed.

Also worth noting from the Snyk report: the `debian:bookworm-slim` base image carries 4 critical findings overall, but only 1 reached this image. The multi-stage Dockerfile copies only the runtime library and the compiled program into the final image, leaving the compiler and most base packages behind.

### 6. Pull request and results

```bash
git add .github/workflows/ci.yml .snyk
git commit -m "Add CI workflow ..."
git push -u origin ci/github-actions
gh pr create --base main --head ci/github-actions --title "Add CI quality gates" --body-file -
gh pr checks 2 --watch
```

```text
All checks were successful
0 cancelled, 0 failing, 4 successful, 0 skipped, and 0 pending checks

✓  CI/COBOL build and invariant test
✓  CI/Secret scan
✓  CI/ShellCheck deploy.sh
✓  CI/Terraform fmt and validate
```

Merged with a squash merge, so `main` receives one clean commit:

```bash
gh pr merge 2 --squash --delete-branch
```

```text
ddb15b7 Add CI quality gates (#2)
7d13fa3 Add Option B (Terraform) with remote state, Option A teardown, and runbook updates (#1)
f79a0ad SEIR Module 3 Lab 01: COBOL on ECS Fargate with docs, runbook, and failure drills
```

The merge triggered the workflow on `main` itself:

```text
STATUS  TITLE                      WORKFLOW  BRANCH  EVENT  ELAPSED
✓       Add CI quality gates (#2)  CI        main    push   32s
```

### 7. Branch protection

```bash
gh api -X PUT repos/BIGDADDY5802/seir_cobol_ecs_lab/branches/main/protection --input - <<'EOF'
{
  "required_status_checks": {
    "strict": true,
    "contexts": [
      "COBOL build and invariant test",
      "Terraform fmt and validate",
      "ShellCheck deploy.sh",
      "Secret scan"
    ]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_linear_history": true
}
EOF
```

| Rule | Effect |
|---|---|
| Required status checks (4) | No merge unless all four jobs pass |
| `strict: true` | Branch must be up to date with `main` before merging |
| `enforce_admins: true` | Rules apply to the repository owner too |
| `required_pull_request_reviews: null` | No second reviewer (solo repository; GitHub does not allow self-approval) |
| Force pushes and deletions blocked | `main` history cannot be rewritten or removed |
| Linear history | Matches the squash-merge workflow |

**Verification drill:** a direct push to `main` was attempted and rejected.

```bash
git commit --allow-empty -m "test: direct push to main"
git push
```

```text
remote: error: GH006: Protected branch update failed for refs/heads/main.
remote: - 4 of 4 required status checks are expected.
 ! [remote rejected] main -> main (protected branch hook declined)
```

The local test commit was discarded with `git reset --hard origin/main`.

---

### Issues encountered

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | `gh: command not found` | Command run in WSL Ubuntu, where `gh` is not installed | Run git/GitHub work from the repository's UCRT64 terminal, where `gh` is installed and authenticated |
| 2 | `gh pr checks --watch` printed `no checks reported` | Ran before GitHub had started the workflow | Wait a few seconds; use `gh run list` to confirm the run exists |
| 3 | Snyk `Authentication error (SNYK-0005)`, HTTP 401 | Stored token was not accepted by Snyk | Generated a new token, verified HTTP 200 against Snyk's API, saved it with `printf '%s'` to avoid a trailing newline |
| 4 | Token test reported `token length: 0` | Multi-line paste fed an empty line to `read` | Run `read -rs` on its own, then paste |
| 5 | Snyk failed on CRITICAL zlib finding | Real finding in base image | Triaged against Debian's tracker; documented, expiring exception in `.snyk` |
| 6 | Snyk still flagged the excepted finding | Container scan did not pick up `.snyk` automatically | Added `--policy-path=.snyk` to the Snyk arguments |

---

### Status

| Item | Status |
|---|---|
| CI workflow with 4 required jobs | ✅ |
| All actions pinned to SHAs | ✅ |
| Secrets stored in GitHub, none in code | ✅ |
| Snyk finding triaged with expiring exception | ✅ |
| CI green on PR and on `main` | ✅ |
| Branch protection enforced and verified | ✅ |

### Next steps

1. **Base-image hardening:** patch or replace the base image, then tighten Snyk from `critical` to `high` before the `.snyk` exception expires on 2027-02-01.
2. **ECR hardening in Terraform:** tag immutability and a lifecycle policy for untagged images.
3. **Deploy from Actions with OIDC:** short-lived AWS credentials via an IAM role trusted only by this repository, instead of stored keys.
