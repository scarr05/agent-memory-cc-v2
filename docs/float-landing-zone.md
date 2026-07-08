# Float Landing Zone

## Account structure

| Account | ID | Purpose |
|---------|----|---------|
| management | 638920471710 | Org root, SCPs, IAM Identity Center (SSO home), billing |
| security | 601644127834 | Delegated GuardDuty, Security Hub, Config Aggregator, platform dashboard |
| log-archive | 852922979722 | CloudTrail log bucket (Object Lock), Config delivery bucket |
| workload | 180891490119 | Float app + Nextcloud + Obsidian LiveSync + shared VPC |
| shared-services | 007050358436 | IAM Identity Center delegated admin |
| sandbox | 146697354436 | Experimentation (relaxed region restrictions) |

## CLI auth

Auth is AWS SSO to the **management account**, profile **`float-management`**:

```bash
aws sso login --profile float-management
```

Token expiry symptom: `Error loading SSO Token` / `The SSO session associated with this profile has expired`. Fix is always the login command above — do not switch to keys.

All helper scripts in `scripts/aws/` default to this profile; override with `AWS_PROFILE=<other> script.sh` only for cross-account work.

The SSO session is `scarr-labs` (start URL `https://scarr-labs.awsapps.com/start`, SSO region eu-west-2, role AdministratorAccess). The per-account profiles — `float-security`, `float-workload`, `float-logarchive`, `float-sharedservices`, `float-sandbox` — assume `OrganizationAccountAccessRole` in their account with `source_profile = float-management`, so one SSO login covers all of them.

Note: CloudWatch metrics for the workloads (Nextcloud, Float, LiveSync) live in the **workload** account — use `AWS_PROFILE=float-workload` for those (this is `cw-dash.sh`'s default).

## Regions

Default region: eu-west-2.
