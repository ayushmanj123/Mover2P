# Mover2P

Moves a Power Pages site that uses the **standard data model** from one tenant to another, keeping the standard data model. It orchestrates the Power Platform CLI (`pac`) and adds the checks that are easy to miss when doing the move by hand.

## Status

Milestone 1 is built and unit tested, including an end-to-end run against a fake `pac`. **It has not yet been run against real environments.** The parts that only a live run can prove are listed under [Not yet verified](#not-yet-verified). Do the first run against non-production environments.

## Requirements

- Windows PowerShell 5.1
- Power Platform CLI 2.9 or later, installed with the Windows installer (the `pac data` commands need that build)
- System Administrator in both environments
- Pester 3.4 to run the tests (ships with Windows)

## How it works

| Command | Talks to | What it does |
| --- | --- | --- |
| `export` | Tenant A | Records the source environment, exports the listed solutions, downloads the site, and writes a package folder with a `manifest.json`. |
| `check` | Tenant B | Compares the target with the manifest. Changes nothing. |
| `import` | Tenant B | Runs `check`, asks for confirmation, then imports solutions, uploads the site and imports gap-table data. |
| `validate` | Tenant B | Counts the site's records per table in the target and compares them with the counts recorded at export. |

The package folder is the hand-off between tenants. `export` needs only the `source` section of the config and `import` only the `target` section, so the two halves can be run by different people on different machines.

## Before the first import

These steps are still done by hand in the target environment:

1. In the Power Platform admin center, turn **Switch to enhanced data model** off for the environment.
2. Provision a site from the same template as the source.
3. In Portal Management, delete the website record that provisioning created, and delete its portal app in Power Apps. Keep the Portal Management app.
4. Make sure the maximum attachment size is at least the source's, and the same languages are enabled. `check` verifies both.

## Usage

```powershell
# Copy the sample and fill in your environments
Copy-Item .\config\migration.sample.json .\config\contoso.json

.\Mover2P.ps1 export   -Config .\config\contoso.json
.\Mover2P.ps1 check    -Config .\config\contoso.json
.\Mover2P.ps1 import   -Config .\config\contoso.json -DryRun   # shows the pac commands only
.\Mover2P.ps1 import   -Config .\config\contoso.json
.\Mover2P.ps1 validate -Config .\config\contoso.json
```

If script execution is blocked, run it as `powershell -ExecutionPolicy Bypass -File .\Mover2P.ps1 ...`.

Options:

- `-DryRun` (export, import): print the `pac` commands without running them. Read-only checks still run.
- `-Yes` (import): skip the confirmation prompt, for unattended runs.
- `-Steps solutions,site,data` (import): run only some steps, for example to resume after a failure.

Exit code is `0` on success and `1` when a check, validation or command fails. Each run writes a log under `<workDir>\<name>\logs`.

After `import`, reactivate the site from **Inactive sites** on the Power Pages home page, convert it to production, and set up the custom domain.

## Config

| Key | Required | Meaning |
| --- | --- | --- |
| `name` | Yes | Name of the migration; also the package folder name. |
| `workDir` | No | Where packages are written, relative to the config file. Default `./work`. |
| `source`, `target` | One per command | `url`, `tenantId` and `auth` for each environment. |
| `auth.mode` | No | `interactive` (default) or `servicePrincipal`. |
| `auth.clientId` | For service principal | Application (client) ID. |
| `auth.clientSecretEnvVar` | For service principal | Name of the environment variable that holds the secret. The secret itself never goes in the config. |
| `site.websiteId` | Yes | GUID of the website record (`pac pages list`). |
| `site.deploymentProfileFile` | No | A `<profile>.deployment.yml` with target-specific overrides, copied into the site folder before upload. |
| `solutions` | No | Solutions that carry your custom tables, columns, forms and views: `name` and `managed` (default `true`). Imported in the listed order. |
| `data.schemaFile` | No | Configuration Migration Tool schema for tables the CLI does not move, such as column permission profiles. |
| `validation.tables` | No | Overrides the list of tables that are counted. |
| `check.portalSolutionPattern` | No | Regex that picks which solutions are compared by version. Default `(?i)portal\|powerpages`. |

With `interactive` mode you sign in twice per environment: once in the `pac` sign-in window, and once with a device code so the tool can read environment facts. The device-code sign-in uses Microsoft's shared sample app registration unless you set `auth.clientId`.

## Safety

- The tool's own Dataverse calls are read-only. Every change goes through `pac`, so `-DryRun` shows all of them.
- Before running anything, it confirms `pac` is connected to the environment named in the config, and passes `--environment` on every command.
- `import` stops if `check` finds a blocking problem, and asks you to type the target host name before it starts.
- Secrets are read from environment variables and redacted from console output and logs.
- It never deletes anything in either environment. Nothing in the source is modified.

## Not yet verified

These have only been exercised against stand-ins and need a live run:

- Sign-in to the Dataverse Web API, in both modes. Device-code sign-in with the sample app registration is the least certain.
- The Web API queries for environment facts and record counts. A table that cannot be counted is reported and skipped, not treated as a failure.
- The real `pac` export, download, import and upload commands as issued by the tool. Their argument names were checked against `pac` 2.9.3 help.

## Known limits

- Record counts cover tables with a direct website lookup. Child tables such as web links, form steps and form metadata are not counted yet.
- Counts include active records only.
- Public cloud only.
- Contacts, web role assignments and other business data are not moved.

## Roadmap

1. **Live run on a non-production pair.** Fix whatever the first real run shows, starting with the items under "Not yet verified".
2. **Deeper validation.** Count child tables through their parent, and compare site settings by name to flag values that still point at the source.
3. **Target preparation.** Provision the site and remove the default website record from the tool, behind an explicit confirmation.
4. **Gap-table schema.** Generate the Configuration Migration Tool schema for column permission profiles instead of requiring a hand-made file.
5. **Pipeline packaging.** An Azure DevOps or GitHub Actions wrapper for repeat deployments.

## Tests

```powershell
Invoke-Pester .\tests
```

The tests are written for Pester 3.4 and do not contact any environment.
