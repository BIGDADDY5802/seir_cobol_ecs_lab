# SEIR Module 3 / Lab 01 — Runbook
## COBOL on Amazon ECS Fargate: Issues, Fixes, and Diagnostics

**Student:** Jerome Hunter
**Date:** 2026-11-01
**Environment:** Windows 11, Docker Desktop 4.97.0, AWS CLI 2.39.3, us-east-1

> This runbook records every problem hit while completing the lab, in the order encountered: what was seen, why it happened, how it was fixed, and how the fix was verified. The clean procedure is in `documentation.md`.
>
> Account ID and IAM user ID are redacted as `<ACCOUNT_ID>` / `<USER_ID>`.

---

## Quick reference: resuming a session

Each new terminal needs:

```bash
wsl ~
cd ~/seir_cobol_ecs_lab
export AWS_REGION=us-east-1
```

Shell variables used in the drills (`VPC`, `SUBNET`, `SG`, `TASK`, `BAD_TD`) do not persist between terminals. Re-run the lookups:

```bash
VPC=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
SUBNET=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC}" --query 'Subnets[0].SubnetId' --output text)
SG=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=${VPC}" Name=group-name,Values=seir-cobol-no-ingress --query 'SecurityGroups[0].GroupId' --output text)
echo "VPC=$VPC SUBNET=$SUBNET SG=$SG"
```

---

## Issue 1 — Docker build fails: cannot connect to Docker API

**Phase:** Section 2, local test (Git Bash)

**Symptom:**

```text
ERROR: failed to connect to the docker API at npipe:////./pipe/dockerDesktopLinuxEngine;
check if the path is correct and if the daemon is running:
open //./pipe/dockerDesktopLinuxEngine: The system cannot find the file specified.
```

**Cause:** Docker Desktop was not running. `docker --version` only queries the client binary, so it succeeded and gave a false sense that Docker was ready. `docker build` needs the engine (server).

**Fix:**

```bash
docker desktop start
```

**Verify:** `docker version` must show **both** a `Client:` and a `Server:` section, with `Server ... OS/Arch: linux/amd64`.

**Lesson:** Use `docker version` (client + server), not `docker --version` (client only), as the readiness check.

---

## Issue 2 — `deploy.sh` is not compatible with Git Bash on Windows

**Phase:** Pre-deploy review of `deploy.sh`

**Symptom:** Found during code review before running. The script was not executed in Git Bash.

**Cause:** Git Bash runs Bash, but the AWS CLI it calls is the **Windows** binary (`aws-cli/... Windows/11 exe/AMD64`). Three mismatches:

| Problem | Detail | Status |
|---|---|---|
| `/tmp` path | Script writes the IAM trust policy to `/tmp/seir-ecs-trust.json` and passes `file:///tmp/...` to `aws`. The Windows CLI resolves that as `C:\tmp\`, which does not exist. IAM role creation would fail. | Confirmed by review |
| MSYS path conversion | Git Bash rewrites arguments starting with `/`, so `/ecs/seir-cobol-batch` could become `C:/Program Files/Git/ecs/seir-cobol-batch`. | Mitigated with `export MSYS_NO_PATHCONV=1` |
| Possible `\r` in CLI output | Windows programs may append a carriage return to output lines, corrupting captured IDs (`VPC`, `SG`) used later in the script. | Suspected, not tested |

**Fix:** Followed the README guidance: *"Windows users should use WSL2 with Docker Desktop integration."* Moved the entire build host to WSL2 Ubuntu (Issues 3–6). All three problems disappear in native Linux.

**Lesson:** Git Bash is not a substitute for Linux when a script calls Windows-native binaries. Read scripts before running them, especially ones that create IAM roles.

---

## Issue 3 — WSL2 present but no usable Linux distro

**Phase:** WSL2 setup

**Symptom:**

```text
wsl -l -v
  NAME              STATE           VERSION
* docker-desktop    Running         2
```

**Cause:** `docker-desktop` is Docker's internal distro for running the engine. It is not meant for user work.

**Fix (PowerShell):**

```powershell
wsl --install -d Ubuntu
wsl --set-default Ubuntu
```

**Verify:**

```text
  NAME              STATE           VERSION
* Ubuntu            Stopped         2
  docker-desktop    Running         2
```

`Stopped` is normal; WSL idles distros not in use.

---

## Issue 4 — `docker` not found inside Ubuntu

**Phase:** WSL2 setup

**Symptom:**

```text
The command 'docker' could not be found in this WSL 2 distro.
We recommend to activate the WSL integration in Docker Desktop settings.
```

**Cause:** Setting Ubuntu as the default distro and restarting Docker Desktop did **not** enable integration. Inspecting the settings file showed the integration keys were absent:

```powershell
Get-Content "$env:APPDATA\Docker\settings-store.json" | Select-String -Pattern "Wsl"
```

```text
"EngineTypeWindows": "wsl2",
```

**Fix (PowerShell, CLI instead of the Docker Desktop GUI):**

```powershell
$f = "$env:APPDATA\Docker\settings-store.json"
Copy-Item $f "$f.bak"                      # backup first
docker desktop stop                        # stop so Docker cannot overwrite the edit
$s = Get-Content $f -Raw | ConvertFrom-Json
$s | Add-Member -NotePropertyName EnableIntegrationWithDefaultWslDistro -NotePropertyValue $true -Force
$s | Add-Member -NotePropertyName IntegratedWslDistros -NotePropertyValue @("Ubuntu") -Force
[System.IO.File]::WriteAllText($f, ($s | ConvertTo-Json -Depth 10))
docker desktop start
```

`WriteAllText` is used instead of `Set-Content` because Windows PowerShell 5.1 writes a UTF-8 BOM, which can make the JSON unreadable to Docker.

**Verify:**

```powershell
Get-Content $f | Select-String -Pattern "IntegratedWslDistros" -Context 0,2
```

```text
>     "IntegratedWslDistros":  [
                                   "Ubuntu"
                               ]
```

Inside Ubuntu, `docker version` now shows `Client OS/Arch: linux/amd64` and a `Server:` section.

**Rollback (if needed):** `Copy-Item "$f.bak" $f -Force`, then restart Docker Desktop.

---

## Issue 5 — AWS CLI missing in Ubuntu; Windows CLI not suitable

**Phase:** WSL2 setup

**Symptom:** A fresh Ubuntu has no AWS CLI. The Windows CLI is reachable from WSL as `aws.exe`, but using it reintroduces the Windows path and line-ending problems from Issue 2.

**Fix:** Install the Linux AWS CLI and reuse the existing Windows credentials via symlink (one credential source, no duplicate keys):

```bash
sudo apt update && sudo apt install -y unzip
cd ~
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip -q awscliv2.zip
sudo ./aws/install
ln -s /mnt/c/Users/<WindowsUser>/.aws ~/.aws
```

**Verify:**

```text
aws --version
aws-cli/2.39.3 Python/3.14.8 Linux/6.6.87.2-microsoft-standard-WSL2 exe/x86_64.ubuntu.26

aws sts get-caller-identity
"Arn": "arn:aws:iam::<ACCOUNT_ID>:user/awscli"
```

**Note:** Files under `/mnt/c` display as `rwxrwxrwx` because WSL cannot map NTFS ACLs to Linux permissions. The real access control is still the Windows ACL on the user profile. Acceptable for a single-user lab machine.

---

## Issue 6 — Lab files nested twice and located on the Windows filesystem

**Phase:** Section 1

**Symptom:**

```text
find /mnt/c/Users/<WindowsUser> -maxdepth 3 -type d -name seir_cobol_ecs_lab
/mnt/c/Users/<WindowsUser>/Downloads/seir_cobol_ecs_lab
/mnt/c/Users/<WindowsUser>/Downloads/seir_cobol_ecs_lab/seir_cobol_ecs_lab
```

**Cause:** The zip already contains a top-level folder and was extracted into a folder of the same name.

**Fix:** Use the inner folder, and copy it to the Linux filesystem so `chmod` works and Docker builds are faster:

```bash
cp -r /mnt/c/Users/<WindowsUser>/Downloads/seir_cobol_ecs_lab/seir_cobol_ecs_lab ~/seir_cobol_ecs_lab
cd ~/seir_cobol_ecs_lab
grep -c $'\r' deploy.sh Dockerfile hello.cbl
```

**Verify:** All files show `0` carriage-return lines. Real Linux permissions (`rwxr-xr-x`) are shown.

The Windows copy in Downloads is untouched and serves as a backup.

---

## Issue 7 — Unreliable exit-code check

**Phase:** Section 2

**Symptom:** Running `echo $?` as a separate, later command returned `0`, but it was unclear which command that code belonged to.

**Cause:** `$?` holds the exit code of the **immediately preceding** command only.

**Fix:** Chain the check on the same line:

```bash
docker run --rm --platform linux/amd64 seir-cobol-finance:lab1; echo "exit code: $?"
```

---

## Issue 8 — ECR shows three images and scan status `None`

**Phase:** Section 4 verification

**Symptom:** `describe-images` returned three entries (one tagged `lab1`, two untagged), and `imageScanStatus` was `None` for all.

**Cause:** Docker 29 / BuildKit pushes an **image index** that references the real image plus a **provenance attestation**. The `lab1` tag points to the index, which cannot be vulnerability-scanned. The scan result is attached to the actual image manifest and is only fully reported by `describe-image-scan-findings`.

**Fix:** Identify the real image by media type, then query its findings by digest:

```bash
aws ecr describe-images --repository-name seir-cobol-finance \
  --query 'imageDetails[].{digest:imageDigest,type:imageManifestMediaType,artifact:artifactMediaType}' \
  --output table

aws ecr describe-image-scan-findings --repository-name seir-cobol-finance \
  --image-id imageDigest=sha256:f7328142d39df48325eb08e5e0b73108040538e7d266b825181a0930ac795d24 \
  --query '{status:imageScanStatus,counts:imageScanFindings.findingSeverityCounts}'
```

**Verify:** `"status": "COMPLETE"`, counts `HIGH: 7, MEDIUM: 2, LOW: 2`.

**Note:** The image digest (`f7328142...`) is stable for identical code. The index digest changes on every build because the attestation records build time. Use the **image** digest to prove two builds are the same program.

---

## Issue 9 — CloudWatch output mixes multiple runs

**Phase:** Section 5.2 restore

**Symptom:** After restoring and redeploying, the log output showed both `INVARIANT FAILED` (previous run) and `FINANCIAL INVARIANT PASSED` (current run).

**Cause:** `deploy.sh` tails the last 20 minutes of the whole log group, not just the current task.

**Fix:** Match log lines to the task ID in the stream name (`ecs/cobol/<task-id>`), or filter to one task:

```bash
aws logs tail /ecs/seir-cobol-batch --log-stream-name-prefix ecs/cobol/<task-id>
```

**Lesson:** In an incident, always tie logs to the specific task ARN under investigation.

---

## Issue 10 — `lab1` tag silently overwritten

**Phase:** Section 5.2 (expected side effect of the drill)

**Symptom:** Running `deploy.sh` with broken code pushed a failing image under the existing `lab1` tag with no warning.

**Cause:** ECR repository tags are mutable by default. `deploy.sh` only knows the `lab1` tag.

**Fix:** Restored known-good code and redeployed. Verified by image digest returning to `f7328142...`.

**Follow-up:** Added to hardening backlog (tag immutability).

---

## Issue 11 — Bad task definition became the latest revision

**Phase:** Section 5.3

**Symptom:** Registering `task-def-badtag.json` created `seir-cobol-batch:4`, the newest revision. Any `run-task` naming only the family would use the broken one.

**Fix:**

```bash
aws ecs deregister-task-definition --task-definition "$BAD_TD"
```

**Verify:** `"revision": 4, "status": "INACTIVE"`. Subsequent drills named `seir-cobol-batch:3` explicitly.

---

## Issue 12 — IAM drill produced a different error than predicted

**Phase:** Section 5.4

**Expected:** `CannotPullContainerError` with an access-denied message.
**Actual:** `ResourceInitializationError ... unable to retrieve ecr registry auth ... AccessDeniedException ... ecr:GetAuthorizationToken`

**Explanation:** Without the execution role policy, ECS fails even earlier, while fetching the ECR auth token, before any pull is attempted. The error still names the exact principal, action, and reason.

**Restore and verify:** Re-attached `AmazonECSTaskExecutionRolePolicy`, waited 15 seconds for IAM propagation, re-ran the identical task: `exitCode: 0`.

---

## Issue 13 — `docker desktop start` fails inside Ubuntu

**Phase:** Option B, before pushing the image

**Symptom:**

```text
docker desktop start
✗ Failed to start Docker Desktop
starting Docker Desktop: fork/exec /opt/docker-desktop/bin/com.docker.backend: no such file or directory
```

**Cause:** Docker Desktop is a Windows application. Inside WSL2 Ubuntu, `docker desktop start` looks for a Linux install of Docker Desktop, which does not exist. Ubuntu only has the Docker CLI wired to the Windows engine.

**Fix:** Run it from Windows PowerShell:

```powershell
docker desktop start
```

**Verify (from Ubuntu):**

```bash
docker version --format '{{.Server.Version}}'
```

A version number means the engine is running and reachable from Ubuntu.

---

## Diagnostic guide: reading ECS task failures

| `stopCode` | `exitCode` | Reason contains | Meaning | Where to fix |
|---|---|---|---|---|
| `EssentialContainerExited` | `0` | `Essential container in task exited` | Success | — |
| `EssentialContainerExited` | non-zero (e.g. `12`) | `Essential container in task exited` | Program ran and failed | Application code; read CloudWatch logs |
| `TaskFailedToStart` | `null` | `CannotPullContainerError ... not found` | Image/tag does not exist | Image tag or task definition |
| `TaskFailedToStart` | `null` | `ResourceInitializationError ... AccessDenied` | Execution role lacks permissions | IAM execution role |
| (build fails) | n/a | `cobc` error with file:line | Syntax error | COBOL source |

**Rules of thumb:**
- The stop reason `Essential container in task exited` appears for **both** success and application failure. Always check `exitCode`.
- `exitCode: null` plus no CloudWatch logs means the container never started. Look at infrastructure (image, IAM, network), not code.
- `not found` = reached ECR, tag missing. `AccessDenied` = never authorized.

---

## Hardening backlog (deferred to follow-up session)

| # | Item | Evidence | Proposed direction |
|---|---|---|---|
| 1 | Base-image CVEs | 7 HIGH: `util-linux` ×5 (2.38.1-5+deb12u3), `glibc` ×1 (2.36-9+deb12u14), `zlib` ×1 (1.2.13.dfsg-1) | Check for Debian patches (`apt list --upgradable` in image); patch in Dockerfile or change base image; rescan and compare |
| 2 | Mutable ECR tags | `lab1` overwritten in Drill 5.2 | Enable tag immutability; deploy by digest or unique tags |
| 3 | ~~No log retention~~ ✅ Resolved | `create-log-group` sets no retention | **Resolved in Option B:** Terraform sets `retention_in_days = 7` |
| 4 | Errors swallowed in `deploy.sh` | `create-log-group ... 2>/dev/null \|\| true` hides all failures | Only ignore `ResourceAlreadyExistsException` |
| 5 | Wide-open egress | SG outbound `0.0.0.0/0`, public IP assigned | Private subnet with VPC endpoints for ECR, S3, CloudWatch Logs |
| 6 | No ECR lifecycle policy | Console: "No lifecycle policy"; untagged images from drills accumulate | Add a lifecycle rule to expire untagged images |
| 7 | Console signed in as root | Console header shows `root` | MFA on root; use an IAM user or IAM Identity Center for daily work (account-level, highest priority) |

---

## Final state of the account

| Item | State |
|---|---|
| Option A resources | Torn down manually and verified |
| Option B resources | Removed with `terraform destroy` (7 destroyed) |
| Terraform state | Remote in S3, empty after destroy; prior version retained by bucket versioning |
| Default VPC and subnets | Untouched (shared) |
| Running tasks | None |
| Local drill artifacts | `task-def-badtag.json`, `hello.cbl.orig`, `*.tfplan` (all gitignored) |
| Docker settings backup | `%APPDATA%\Docker\settings-store.json.bak` |
