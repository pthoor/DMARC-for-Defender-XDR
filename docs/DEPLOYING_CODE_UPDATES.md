# Deploying Code Updates

This covers how to actually get your code changes to reach the Function App,
depending on how you run CI and on the `scmAccessMode` parameter you chose in
`infra/main.bicep`.

## Verified deployment commands (read this first)

Not every tool that claims to support Flex Consumption zip deploy actually works
against this project's configuration (PowerShell runtime + Flex Consumption). This
was tested directly against a real deployment, not assumed from docs:

| Command | Status |
| --- | --- |
| `az functionapp deployment source config-zip --src <zip> --build-remote false` | ✅ **Verified working** - use this for manual/scripted CLI deploys. |
| `az functionapp deploy --type zip` | ❌ **Verified broken** - returns `415 Unsupported Media Type` against this app. The command itself prints `"This command is in preview and under development"`; don't use it here until that's resolved upstream. |
| `func azure functionapp publish <app> --powershell` (Azure Functions Core Tools) | Not independently verified in this repo. Use the verified `config-zip` command above for manual deployments. |
| `Azure/functions-action@v1` (GitHub Action) | Not independently verified in this repo. Documented below as the default for CI since it's the official, GA action. If a run fails with a `415`-style error, replace the action step with a raw `az functionapp deployment source config-zip` step instead (same auth already set up via `azure/login`). |

If you hit a `415` from any tool, don't debug the SCM/RBAC config first - switch to
`az functionapp deployment source config-zip`, which is the one path confirmed to
work end-to-end.

## Why this needs a choice at all

Azure Functions Flex Consumption doesn't use classic zip-deploy - every deployment
tool (`func azure functionapp publish`, `az functionapp deploy`, VS Code publish, the
`Azure/functions-action` GitHub Action) is meant to go through "One Deploy," which
transiently spins up the SCM (Kudu) site for the duration of the deployment. That
means **some** network path to `https://<app>.scm.azurewebsites.net` is required
whenever you push code - there's no way to deploy with SCM fully unreachable from
every possible direction. `scmAccessMode` controls whether that path is closed by
default (network gate) or open but identity-gated (auth gate). Either way, classic
username/password publish credentials are disabled unconditionally
(`basicPublishingCredentialsPolicies` for both `scm` and `ftp`) - a leaked or guessed
password can never authenticate a deploy, regardless of mode.

Day-to-day operation (ingesting reports, running detections, viewing the workbook)
never touches SCM - this only matters when you're pushing new code.

## Pick your flavor

### Flavor 1 - Manual / occasional deploys (`scmAccessMode=restricted`, the default)

Best if you deploy code by hand from your own machine once in a while and don't run
CI for this project. SCM stays closed to the public internet at all other times.

Follow the [manual publish commands in the README](../README.md#2-publish-function-code). They package the code, add an IP-scoped SCM rule, deploy with `config-zip`, and remove the rule and temporary ZIP afterward.

Note: this IP rule is added imperatively, not through `main.bicep` - it persists
until step 4 removes it, or until the next `az deployment group create` resets
`siteConfig` to whatever the template declares (which has no allow-rules by default).
Don't skip step 4 if you're not redeploying the template soon after.

### Flavor 2 - GitHub-hosted Actions runners (`scmAccessMode=identity-gated`)

Best for most open-source consumers: plain `ubuntu-latest` GitHub-hosted runners,
whose IP ranges are far too large and volatile to allow-list meaningfully. Deploy
`main.bicep` with `scmAccessMode=identity-gated` - SCM becomes network-reachable, but
only a valid Entra ID token from an authorized identity can actually deploy anything
(basic auth is always off). Set up OIDC once:

```bash
# 1. App registration + federated credential trusting your repo/branch
APP_ID=$(az ad app create --display-name "dmarc-defender-xdr-deploy" --query appId -o tsv)
az ad sp create --id "$APP_ID"

az ad app federated-credential create --id "$APP_ID" --parameters '{
  "name": "github-actions-main-branch",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:<owner>/<repo>:ref:refs/heads/main",
  "audiences": ["api://AzureADTokenExchange"]
}'

# 2. Grant only what's needed to redeploy code and infra - Website Contributor
#    covers code/config publish; Contributor at the resource-group scope if you
#    also want this identity to run `az deployment group create` for infra updates.
az role assignment create \
  --assignee "$APP_ID" --role "Website Contributor" \
  --scope "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Web/sites/<function-app-name>"
```

Then in the workflow:

```yaml
permissions:
  id-token: write
  contents: read

steps:
  - uses: actions/checkout@v4
  - uses: azure/login@v2
    with:
      client-id: ${{ secrets.AZURE_DEPLOY_CLIENT_ID }}
      tenant-id: ${{ secrets.AZURE_DEPLOY_TENANT_ID }}
      subscription-id: ${{ secrets.AZURE_DEPLOY_SUBSCRIPTION_ID }}
  - uses: Azure/functions-action@v1
    with:
      app-name: <function-app-name>
      package: src/function
```

No client secret in GitHub either way - same OIDC pattern as
[docs/CI_LIVE_VALIDATION.md](CI_LIVE_VALIDATION.md).

**If `Azure/functions-action` fails with a `415`-style error**, replace that step
with the verified CLI command instead (still uses the OIDC session from `azure/login`
above, no extra secrets needed):

```yaml
  - name: Deploy via config-zip (verified fallback)
    shell: bash
    run: |
      cd src/function
      zip -r /tmp/deploy.zip .
      az functionapp deployment source config-zip \
        --resource-group <rg> --name <function-app-name> \
        --src /tmp/deploy.zip --build-remote false
```

### Flavor 3 - Self-hosted or VNet-integrated runners (`scmAccessMode=restricted`)

Best if you want SCM to never be reachable from the public internet at all, even
identity-gated. Keep `scmAccessMode=restricted` and either run a self-hosted runner
inside the Function App's VNet, or use
[private networking for GitHub-hosted runners](https://learn.microsoft.com/organizations/managing-organization-settings/about-azure-private-networking-for-github-hosted-runners-in-your-organization)
so the runner reaches `*.scm.azurewebsites.net` over a private endpoint instead of
the public internet. Deployment auth is still OIDC (same as Flavor 2) - this only
changes the network path, not the identity model.

## Which one should I pick?

| Situation | Flavor |
| --- | --- |
| Deploying by hand occasionally, no CI | 1 - manual, scoped temporary IP |
| GitHub-hosted Actions runners (most forks) | 2 - `identity-gated` |
| Self-hosted runners, or GitHub-hosted with private networking enabled | 3 - `restricted` |
| Regulatory/compliance requirement that SCM never be internet-reachable | 3 - `restricted` |

If you're not sure, start with Flavor 1 (the default) and switch to Flavor 2 once
you set up CI - `scmAccessMode` is just a redeploy of `main.bicep`, not a one-way
door.
