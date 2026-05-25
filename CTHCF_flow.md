# Cross-Tenant Health Audit Framework

Cross-Tenant Health Audit Framework is an operational reconciliation framework designed to compare infrastructure inventory data against real monitoring visibility across multiple Dynatrace tenants.

It identifies hosts that are reporting correctly, hosts that stopped reporting, hosts missing from their expected tenant, hosts that exist in a different tenant than expected, and hosts that are not included in the expected Company_A Management Zone.

The framework is designed to reduce monitoring blind spots, expose inventory-to-monitoring mismatches, identify hidden stale Dynatrace entities, and provide actionable executive summaries without relying on manual Dynatrace UI checks.

---

## 1. Purpose

The purpose of **Cross-Tenant Health Audit Framework** is to validate the real monitoring state of infrastructure hosts across multiple Dynatrace tenants by comparing:

```text
Inventory source: ESL
Monitoring source: Dynatrace Environment API
````

The framework answers operational questions such as:

* Which hosts from ESL exist in Dynatrace?
* Which hosts are currently reporting?
* Which hosts exist in Dynatrace but stopped reporting recently?
* Which hosts are missing from their expected tenant?
* Which hosts exist in a different tenant than expected?
* Which hosts are not found in any configured tenant?
* Which hosts are known exceptions and should not be treated as monitoring gaps?
* Which Company_B PROD / Company_B NON-PROD hosts belong to the Company_A Management Zone?
* Which Dynatrace `entityId` and `displayName` support each finding?

The final goal is to provide a repeatable, auditable, and transferable process for monitoring coverage validation.

***

## 2. Expected Outcome

After each execution, the framework produces:

* A primary health audit report.
* A cross-tenant discovery report for hosts not found in their expected tenant.
* An exclusions report for hosts intentionally skipped.
* Executive summary reports for Company_B and Company_A.
* Execution logs.
* Intermediate host lists for troubleshooting and validation.

The most important operational outcomes are:

```text
DISCONNECTED
```

Hosts that exist in Dynatrace but have not reported within the configured primary stale threshold.

```text
NOT_FOUND_ALL_CONFIGURED_TENANTS
```

Hosts that were not found in any configured Dynatrace tenant.

```text
MZ Not Company_A
```

Company_B PROD / Company_B NON-PROD hosts that exist in the tenant but are not part of the Company_A Management Zone.

These groups are usually the most relevant for operational follow-up.

***

## 3. High-Level Architecture

```text
ESL Excel Export
  ↓
Inventory Parsing
  ↓
Domain Classification
  ↓
Environment Classification
  ↓
OS Exclusion Filtering
  ↓
Hostname Normalization
  ↓
Host List Generation
  ↓
Known Exclusions / Blacklist Filtering
  ↓
Dynatrace API Validation
  - HOST lookup
  - lastSeenTms
  - entityId
  - displayName
  - managementZones
  ↓
Primary Health Audit Report
  ↓
Cross-Tenant Discovery for NOT_FOUND Hosts
  ↓
Executive Summaries
```

***

## 4. Core Capabilities

### 4.1 Inventory Reconciliation

The framework compares hosts from ESL against Dynatrace HOST entities.

It validates whether each host:

* Exists in the expected tenant.
* Has a valid `lastSeenTms`.
* Is reporting recently.
* Is stale / disconnected.
* Is missing from the expected tenant.
* Exists in a different tenant.
* Is excluded by a known exception rule.
* Has Dynatrace evidence through `entityId` and `displayName`.

***

### 4.2 Cross-Tenant Discovery

When a host is not found in its expected tenant, the framework performs a second validation round against all configured tenants.

Configured tenants:

```text
Company_B_PROD
Company_B_NONPROD
Company_A
```

This helps identify cases where the inventory says one thing, but the host actually exists somewhere else.

Example:

```text
Expected: Company_B_NONPROD
Actually found in: Company_B_PROD
```

This is reported as:

```text
FOUND_IN_DIFFERENT_TENANT
```

Cross-tenant discovery is executed regardless of the selected option.

Examples:

* If option `1` is selected and Company_B PROD has `NOT_FOUND` hosts, those hosts are searched in Company_B PROD, Company_B NON-PROD, and Company_A.
* If option `3` is selected and Company_A has `NOT_FOUND` hosts, those hosts are searched in Company_B PROD, Company_B NON-PROD, and Company_A.
* If option `4` is selected, the global report is followed by the same cross-tenant discovery process.

***

### 4.3 Tenant-Level Parallelism

The framework intentionally does **not** parallelize per host.

Instead, it uses safe tenant-level parallelism.

For single-tenant options:

```text
1) Company_B PROD
2) Company_B NON-PROD
3) Company_A
```

Processing is sequential inside the selected tenant.

For global execution:

```text
4) ALL / GLOBAL
```

The framework runs the three tenant validations in parallel:

```text
Company_B_PROD     ┐
Company_B_NONPROD  ├── parallel tenant-level execution
Company_A         ┘
```

Cross-tenant discovery also runs in parallel by tenant:

```text
All NOT_FOUND hosts → Company_B_PROD
All NOT_FOUND hosts → Company_B_NONPROD
All NOT_FOUND hosts → Company_A
```

This reduces total runtime without flooding any single tenant with excessive concurrent requests.

***

### 4.4 Known Exclusions / Blacklist

Some hosts should not be treated as monitoring gaps.

Examples:

* Self-managed Dynatrace environments with no access.
* Appliances with limited operating systems.
* Legacy operating systems.
* Network devices.
* Hosts that should not run OneAgent by design.

These hosts can be listed in an exclusion file so the framework does not waste time querying them.

Excluded hosts are not hidden. They are explicitly reported as:

```text
EXCLUDED_BY_BLACKLIST
```

***

### 4.5 Company_A Management Zone Validation for Company_B Hosts

For Company_B PROD and Company_B NON-PROD hosts, the framework identifies whether the host belongs to the Dynatrace Management Zone named:

```text
Company_A
```

Important design principle:

```text
The primary host lookup is NOT filtered by Management Zone.
```

The framework first searches the host in the full tenant.

Then it checks the `managementZones` returned by the same Dynatrace API response.

This avoids hiding hosts that exist in the tenant but are not part of the Company_A Management Zone.

The output column is:

```text
in_Company_A_management_zone
```

Possible values:

```text
MZ Company_A
MZ Not Company_A
UNKNOWN
N/A
```

Meaning:

```text
MZ Company_A
```

The host exists in Company_B PROD or Company_B NON-PROD and belongs to the Company_A Management Zone.

```text
MZ Not Company_A
```

The host exists in Company_B PROD or Company_B NON-PROD but does not belong to the Company_A Management Zone.

```text
UNKNOWN
```

The framework could not determine the Management Zone status.

```text
N/A
```

The check does not apply, for example for Company_A tenant hosts.

***

### 4.6 Single API Call Optimization

The framework uses a single Dynatrace Environment API call per host to retrieve:

* `entityId`
* `displayName`
* `lastSeenTms`
* `managementZones`

The API request uses:

```text
/api/v2/entities
```

With:

```text
entitySelector=type(HOST),entityName.startsWith("hostname")
fields=+lastSeenTms,+managementZones
```

The framework does **not** run a second API call to validate the Company_A Management Zone.

Instead, it reads the returned `managementZones` field from the same response.

This reduces:

* API calls.
* Runtime.
* Tenant load.
* Risk of API throttling.
* Operational inefficiency.

***

### 4.7 Executive Summaries

The framework generates additional executive summary CSV files focused only on actionable items.

Executive summaries include:

```text
STALE_XH_PLUS
```

Hosts that have not reported within the configured executive threshold.

```text
NOT_FOUND_ALL_TENANTS
```

Hosts that were not found in any configured tenant.

There are two executive outputs:

```text
Company_B executive summary
Company_A executive summary
```

The Company_B executive summary includes both:

```text
Company_B_PROD
Company_B_NONPROD
```

The Company_A executive summary includes:

```text
Company_A
```

***

## 5. Runtime Directory Structure

The recommended runtime directory is:

```bash
~/dt_reports/
```

This directory contains all input and output runtime files.

```text
~/dt_reports/
  ├── esl_report.*.xlsx
  ├── ct_health_audit_exclusions.csv
  ├── dt_connectivity_exclusions.csv
  ├── servers_prod.txt
  ├── servers_non_prod.txt
  ├── servers_Company_A.txt
  ├── ct_health_audit_*_report_<timestamp>.csv
  ├── ct_health_audit_*_report_<timestamp>.log
  ├── ct_health_audit_*_notfound_discovery_<timestamp>.csv
  ├── ct_health_audit_*_excluded_<timestamp>.csv
  ├── ct_health_audit_Company_B_executive_summary_<timestamp>.csv
  └── ct_health_audit_Company_A_executive_summary_<timestamp>.csv
```

The framework executable and configuration file remain outside the runtime directory:

```bash
~/cross_tenant_health_audit.sh
~/.ct_health_audit.conf
```

For backward compatibility, the framework can also use:

```bash
~/.dt_env.conf
~/dt_reports/dt_connectivity_exclusions.csv
```

if the new configuration or exclusion files are not present.

***

## 6. Dependencies

The framework requires a Linux or WSL environment.

Required operating system commands:

```bash
bash
curl
jq
python3
find
sort
awk
wc
date
mktemp
sed
xargs
cat
```

Required Python modules:

```text
pandas
openpyxl
```

Install Python dependencies:

```bash
python3 -m pip install --user pandas openpyxl
```

***

## 7. Configuration File

Recommended configuration file:

```bash
~/.ct_health_audit.conf
```

Backward-compatible configuration file:

```bash
~/.dt_env.conf
```

If `~/.ct_health_audit.conf` does not exist and `~/.dt_env.conf` exists, the framework uses `~/.dt_env.conf`.

Example:

```bash
# Company_B PROD
TENANT_PROD_URL="https://<Company_B-prod-api-base-url>"
TOKEN_PROD="<api-token-Company_B-prod>"

# Company_B NON-PROD
TENANT_NONPROD_URL="https://<Company_B-nonprod-api-base-url>"
TOKEN_NONPROD="<api-token-Company_B-nonprod>"

# Company_A
TENANT_Company_A_URL="https://<Company_A-api-base-url>"
TOKEN_Company_A="<api-token-Company_A>"

# Primary report threshold
STALE_HOURS=48

# Executive action threshold
EXEC_STALE_HOURS=0.25
```

Recommended permissions:

```bash
chmod 600 ~/.ct_health_audit.conf
```

or:

```bash
chmod 600 ~/.dt_env.conf
```

The configuration file contains sensitive API tokens and must not be committed to GitHub or shared through email, chat, tickets, screenshots, or documentation.

***

## 8. Threshold Configuration

There are two independent threshold concepts.

***

### 8.1 `STALE_HOURS`

```bash
STALE_HOURS=48
```

This threshold controls the primary health audit status:

```text
CONNECTED
DISCONNECTED
```

If a host exists in Dynatrace but its `lastSeenTms` is older than `STALE_HOURS`, the host is marked as:

```text
DISCONNECTED
```

If the host exists and its `lastSeenTms` is within the threshold, the host is marked as:

```text
CONNECTED
```

Recommended use:

```bash
STALE_HOURS=48
```

This keeps the primary report stable and avoids over-alerting.

***

### 8.2 `EXEC_STALE_HOURS`

```bash
EXEC_STALE_HOURS=0.25
```

This threshold controls the executive summary action items.

A host can still be `CONNECTED` in the primary report but appear in the executive summary if it has not reported within the executive threshold.

This is useful for early operational action.

***

### 8.3 Threshold Examples

#### 15 minutes

```bash
EXEC_STALE_HOURS=0.25
```

#### 45 minutes

```bash
EXEC_STALE_HOURS=0.75
```

#### 2 hours

```bash
EXEC_STALE_HOURS=2
```

#### 48 hours primary stale threshold

```bash
STALE_HOURS=48
```

Recommended model:

```bash
STALE_HOURS=48
EXEC_STALE_HOURS=0.25
```

This means:

```text
Primary report:
  DISCONNECTED only after 48 hours.

Executive summary:
  Action item after 15 minutes.
```

***

## 9. ESL Input

The framework uses an ESL Excel export as inventory source.

ESL report source:

```text
https://esl.svcs.entsvcs.net/pls/eslcgi/reports/esl_rep2.pl?gen_rep=1097759&is_owner=yes
```

The exported file must be placed in:

```bash
~/dt_reports/
```

Expected filename pattern:

```bash
esl_report.*.xlsx
```

Example:

```bash
~/dt_reports/esl_report.10734918.xlsx
```

If multiple ESL reports exist in the directory, the newest file by modification time is selected automatically.

***

## 10. Excel Override

A specific ESL Excel file can be forced using:

```bash
EXCEL_PATH="/path/to/esl_report.10734918.xlsx" ./cross_tenant_health_audit.sh
```

This bypasses the automatic newest-file detection.

***

## 11. Required Excel Columns

The Excel file must include at least the following columns:

```text
System Name
Environment
OS Class
```

***

### 11.1 `System Name`

Contains the hostname or FQDN.

Examples:

```text
server01.tul.Company_B.com
server02.Company_Bg.svcs.entsvcs.com
server03.mgmt.Company_B.com
```

The framework normalizes this value to short hostname.

Examples:

```text
server01.tul.Company_B.com  -> server01
SERVER02.DOMAIN.COM  -> server02
```

***

### 11.2 `Environment`

Used mainly for Company_B production / non-production classification.

Rule:

```text
Production -> Company_B_PROD
Anything else -> Company_B_NONPROD
```

Examples treated as non-production:

```text
Development
Sandbox
Staging
Test
Test Certification
Test Lab
Service Continuity - Warm
```

Company_A hosts are classified as Company_A based on domain suffix, not by this field.

***

### 11.3 `OS Class`

Used for high-level OS exclusions.

Excluded OS classes:

```text
IBM z
OpenVMS
SunOS/Solaris
VMware
Other
```

***

## 12. Domain Classification

Hosts are classified by domain suffix.

***

### 12.1 Company_A Domains

```text
.Company_Bg.svcs.entsvcs.com
.entsvcs.net
.resrc.entsvcs.com
.oktul.us.eds.com
.sabre.com
.Company_B.Company_A.com
.sharedmgmt.com
.oraclevcn.com
```

Hosts matching these suffixes are written to:

```text
servers_Company_A.txt
```

***

### 12.2 Company_B Domains

```text
.corpCompany_B.Company_B.com
.corpa.Company_B.com
.qcorpCompany_B.Company_B.com
.cdc.Company_B.com
.tul.Company_B.com
.pdc.Company_B.com
.Company_Blcorp.Company_B.com
.mgmt.Company_B.com
```

Company_B hosts are split into:

```text
servers_prod.txt
servers_non_prod.txt
```

based on the `Environment` column.

***

## 13. Exclusion File

Recommended exclusion file:

```bash
~/dt_reports/ct_health_audit_exclusions.csv
```

Backward-compatible exclusion file:

```bash
~/dt_reports/dt_connectivity_exclusions.csv
```

If `ct_health_audit_exclusions.csv` does not exist and `dt_connectivity_exclusions.csv` exists, the framework uses the legacy file.

Format:

```csv
environment,host,comments
Company_A,oldlinux01,selfmanaged
Company_B_PROD,legacywin01,old OS
GLOBAL,networkappliance01,network device
```

Supported environment values:

```text
Company_B_PROD
Company_B_NONPROD
Company_A
GLOBAL
```

`GLOBAL` excludes the host regardless of expected tenant.

***

### 13.1 Exclusion Behaviour

If a host matches the exclusion list:

* The host is not queried via API.
* The host is not included in cross-tenant discovery.
* The host is shown in the primary report as:

```text
EXCLUDED_BY_BLACKLIST
```

* The host is also written to the excluded report.

Comments are preserved in output reports.

Avoid commas inside the `comments` field. Use semicolons instead.

Good:

```csv
Company_A,oldlinux01,selfmanaged; no access
```

Avoid:

```csv
Company_A,oldlinux01,selfmanaged, no access
```

***

## 14. Generated Intermediate Files

Each execution rebuilds:

```bash
~/dt_reports/servers_prod.txt
~/dt_reports/servers_non_prod.txt
~/dt_reports/servers_Company_A.txt
```

Each file contains one normalized short hostname per line.

Example:

```text
Company_Aeis03
server01
server02
```

These files are useful for validation and troubleshooting.

***

## 15. Execution Options

Run interactively:

```bash
./cross_tenant_health_audit.sh
```

Menu:

```text
1) Company_B PROD
2) Company_B NON-PROD
3) Company_A
4) ALL / GLOBAL
5) Build lists only
0) Exit
```

***

### 15.1 Single Tenant Execution

Example:

```bash
printf "3\n" | ./cross_tenant_health_audit.sh
```

This runs Company_A only.

Single tenant executions are sequential inside that tenant.

Cross-tenant discovery still runs afterward if `NOT_FOUND` hosts exist.

***

### 15.2 Global Execution

```bash
printf "4\n" | ./cross_tenant_health_audit.sh
```

Global execution runs all configured tenants in parallel at tenant level.

***

## 16. Cron Examples

### Global execution every 30 minutes

```cron
*/30 * * * * printf "4\n" | /home/mrios22/cross_tenant_health_audit.sh >> /home/mrios22/dt_reports/cron_ct_health_audit.log 2>&1
```

***

### Global execution with 15-minute executive threshold

```cron
*/30 * * * * printf "4\n" | EXEC_STALE_HOURS=0.25 /home/mrios22/cross_tenant_health_audit.sh >> /home/mrios22/dt_reports/cron_ct_health_audit.log 2>&1
```

***

### Global execution with 45-minute executive threshold

```cron
*/30 * * * * printf "4\n" | EXEC_STALE_HOURS=0.75 /home/mrios22/cross_tenant_health_audit.sh >> /home/mrios22/dt_reports/cron_ct_health_audit.log 2>&1
```

***

### Global execution with 2-hour executive threshold

```cron
0 * * * * printf "4\n" | EXEC_STALE_HOURS=2 /home/mrios22/cross_tenant_health_audit.sh >> /home/mrios22/dt_reports/cron_ct_health_audit.log 2>&1
```

***

## 17. Primary Report

Primary report format:

```text
ct_health_audit_<scope>_report_<timestamp>.csv
```

Examples:

```text
ct_health_audit_Company_B_prod_report_1779720799.csv
ct_health_audit_Company_B_nonprod_report_1779720799.csv
ct_health_audit_Company_A_report_1779720799.csv
ct_health_audit_global_report_1779720799.csv
```

Header:

```csv
tenant_group,hostname,status,lastSeenTms,age_human,matches,entityId,displayName,in_Company_A_management_zone,notes
```

Example:

```csv
tenant_group,hostname,status,lastSeenTms,age_human,matches,entityId,displayName,in_Company_A_management_zone,notes
Company_B_PROD,bazweuscognsp02,DISCONNECTED,1777546509702,21d 8h 3m,1,HOST-5E9CF3AB234AF2AF,bazweuscognsp02,MZ Company_A,
Company_B_PROD,server01,CONNECTED,1779720000000,0d 0h 20m,1,HOST-1234567890ABCDEF,server01,MZ Not Company_A,
Company_A,datamallpgp01,DISCONNECTED,1779510401221,2d 10h 27m,1,HOST-44FD1B312EF1028A,datamallpgp01,N/A,
Company_A,oldlinux01,EXCLUDED_BY_BLACKLIST,,,0,,,N/A,selfmanaged
```

***

## 18. Primary Status Values

### `CONNECTED`

The host exists in Dynatrace and has reported within `STALE_HOURS`.

***

### `DISCONNECTED`

The host exists in Dynatrace but has not reported within `STALE_HOURS`.

Possible causes:

* OneAgent stopped.
* Host powered off.
* Connectivity issue.
* ActiveGate/routing issue.
* Host decommissioned but historically retained.
* Agent no longer reporting.
* Hidden stale Dynatrace entity only visible with a wider timeframe or direct `entityId`.

***

### `NOT_FOUND`

The host was not found in the expected tenant.

This does not necessarily mean the host is not monitored anywhere. It may still exist in another configured tenant.

***

### `EXCLUDED_BY_BLACKLIST`

The host was intentionally skipped based on the exclusion file.

***

### `NO_LASTSEEN`

The host was found, but no `lastSeenTms` was returned.

***

### `API_ERROR`

The API returned an invalid response or the tenant could not be queried correctly.

***

## 19. Management Zone Values

Column:

```text
in_Company_A_management_zone
```

Possible values:

```text
MZ Company_A
MZ Not Company_A
UNKNOWN
N/A
```

### `MZ Company_A`

The host exists in Company_B PROD or Company_B NON-PROD and belongs to the Company_A Management Zone.

### `MZ Not Company_A`

The host exists in Company_B PROD or Company_B NON-PROD but does not belong to the Company_A Management Zone.

### `UNKNOWN`

The Management Zone status could not be determined.

### `N/A`

The Management Zone check does not apply, for example for Company_A tenant hosts.

***

## 20. Cross-Tenant Discovery Report

Discovery report format:

```text
ct_health_audit_<scope>_notfound_discovery_<timestamp>.csv
```

Purpose:

```text
Find where NOT_FOUND hosts actually exist, if they exist in another configured tenant.
```

Discovery status values:

```text
FOUND_IN_DIFFERENT_TENANT
FOUND_IN_EXPECTED_TENANT_ON_RETRY
MULTI_TENANT_MATCH
NOT_FOUND_ALL_CONFIGURED_TENANTS
NOT_FOUND_IN_CONFIGURED_TENANTS_WITH_API_ERRORS
```

***

### 20.1 `FOUND_IN_DIFFERENT_TENANT`

The host was missing from the expected tenant but found in another configured tenant.

This indicates an inventory-to-monitoring mismatch.

***

### 20.2 `FOUND_IN_EXPECTED_TENANT_ON_RETRY`

The host was found in the expected tenant during discovery after being marked as `NOT_FOUND` in the primary pass.

This may indicate a temporary API inconsistency or transient response issue.

***

### 20.3 `MULTI_TENANT_MATCH`

The host exists in more than one configured tenant.

This may indicate duplicate monitoring, migration overlap, or historical data.

***

### 20.4 `NOT_FOUND_ALL_CONFIGURED_TENANTS`

The host was not found in any configured tenant.

This is one of the most important operational outcomes.

Possible causes:

* No OneAgent installed.
* Host never onboarded.
* Host exists in a self-managed tenant not accessible from this framework.
* Inventory is wrong.
* Host is decommissioned.
* Host uses a different name than expected.

***

### 20.5 `NOT_FOUND_IN_CONFIGURED_TENANTS_WITH_API_ERRORS`

The host was not found, but one or more tenant checks returned an API error.

This result requires caution because the discovery was not fully clean.

***

## 21. Executive Summary Reports

Executive summaries are additional action-oriented CSVs.

They do not replace the primary report or discovery report.

Files:

```text
ct_health_audit_Company_B_executive_summary_<timestamp>.csv
ct_health_audit_Company_A_executive_summary_<timestamp>.csv
```

Company_B executive summary includes:

```text
Company_B_PROD
Company_B_NONPROD
```

Company_A executive summary includes:

```text
Company_A
```

***

### 21.1 Executive Categories

```text
STALE_XH_PLUS
```

The host has not reported within the configured executive threshold.

Example:

```text
STALE_0.25H_PLUS
```

Means the host has not reported for at least 15 minutes.

```text
NOT_FOUND_ALL_TENANTS
```

The host was not found in any configured tenant.

***

### 21.2 Executive Report Header

```csv
run_ts,category,tenant_or_expected,hostname,age_hours,age_human,lastSeenTms,entityId,displayName,in_Company_A_management_zone,source_file
```

Example:

```csv
run_ts,category,tenant_or_expected,hostname,age_hours,age_human,lastSeenTms,entityId,displayName,in_Company_A_management_zone,source_file
1779300000,STALE_0.25H_PLUS,Company_B_PROD,server01,0.42,0d 0h 25m,1779298500000,HOST-1234567890ABCDEF,server01,MZ Company_A,ct_health_audit_global_report_1779300000.csv
1779300000,NOT_FOUND_ALL_TENANTS,Company_A,server02,,,,,,,ct_health_audit_global_notfound_discovery_1779300000.csv
```

***

## 22. Hidden Stale Entities

The framework can detect Dynatrace HOST entities that may not appear in the default Dynatrace UI timeframe.

A host can be classified as:

```text
DISCONNECTED
```

because the API returns a historical HOST entity with an old `lastSeenTms`.

Example evidence model:

```text
Tenant: Company_B_PROD
Host: bazweuscognsp02
Entity ID: HOST-5E9CF3AB234AF2AF
Display Name: bazweuscognsp02
Last Seen: 21d+
Status: DISCONNECTED
```

If the host does not appear in the default Dynatrace UI search, expand the timeframe or navigate directly using the `entityId`.

This is useful to detect:

* Hidden stale entities.
* Historical OneAgent leftovers.
* Hosts that stopped reporting long ago.
* Decommissioned hosts still present historically.
* Monitoring drift.

***

## 23. False Positive Protection

Dynatrace searches use:

```text
entityName.startsWith("hostname")
```

This can return false positives.

Example:

```text
rswebs1
rswebs14
rswebs15
```

To prevent this, the framework applies local filtering:

```text
^hostname(\.|$)
```

Valid matches:

```text
Company_Aeis03
Company_Aeis03.tul.Company_B.com
```

Invalid match:

```text
Company_Aeis031.tul.Company_B.com
```

***

## 24. Multiple Dynatrace Entities

Dynatrace may return more than one HOST entity for the same hostname.

This can happen after:

* OneAgent reinstall.
* Host rebuild.
* Host identity change.
* Historical retention.

When multiple valid matches exist, the framework uses the entity with the newest `lastSeenTms`.

The `matches` column preserves the number of valid matching entities found.

***

## 25. API Pre-Check

Before querying a tenant, the framework validates API access.

Possible pre-check outcomes:

```text
HTTP 200  -> reachable
HTTP 401  -> token issue
HTTP 000  -> network/connectivity issue
failed to resolve tenant -> wrong gateway/environment combination
```

If a tenant pre-check fails, hosts for that tenant are marked as:

```text
API_ERROR
```

instead of incorrectly marking them as `NOT_FOUND`.

***

## 26. API Cost, Fair Use, and Throttling

The framework performs read-only Dynatrace Environment API queries.

Current framework behaviour:

```text
GET /api/v2/entities
Read-only
No custom metric ingestion
No log ingestion
No trace ingestion
No event ingestion
No write configuration
```

Dynatrace documents read API access as free of charge under a fair use model.

The main operational risk is not direct read cost, but request throttling.

Dynatrace can return:

```text
HTTP 429
```

when request processing limits are reached.

The framework reduces API volume by using a single API call per host and reading `managementZones` from the same response.

Recommended future API-safety improvements:

* Capture HTTP status per request.
* Detect and report `HTTP 429`.
* Add retry/backoff for throttling.
* Add API call counters.
* Add optional sleep between requests if needed.

***

## 27. Security

API tokens are stored externally in:

```bash
~/.ct_health_audit.conf
```

or, for backward compatibility:

```bash
~/.dt_env.conf
```

Do not commit these files.

Do not expose tokens in:

* GitHub
* SharePoint
* emails
* tickets
* screenshots
* chat messages
* logs
* documentation

If a token is exposed, revoke it and generate a new one.

***

## 28. Historical File Retention

The framework does not delete previous CSV or log files.

This is intentional.

Each execution generates timestamped outputs.

Retention should be handled externally.

Example:

```bash
find ~/dt_reports -name '*.csv' -mtime +30 -delete
find ~/dt_reports -name '*.log' -mtime +30 -delete
```

Adjust retention according to operational requirements.

***

## 29. Troubleshooting

### Excel file not found

Check:

```bash
ls -ltr ~/dt_reports/esl_report.*.xlsx
```

Use override:

```bash
EXCEL_PATH="/home/mrios22/dt_reports/esl_report.10734918.xlsx" ./cross_tenant_health_audit.sh
```

***

### Missing Python modules

Install:

```bash
python3 -m pip install --user pandas openpyxl
```

***

### Too many `NOT_FOUND`

Check:

* Is the host expected in that tenant?
* Is the hostname different in Dynatrace?
* Is the host in another tenant?
* Is the host excluded by design?
* Is the host in a self-managed tenant?
* Is the ESL inventory stale?

***

### Too many `MZ Not Company_A`

Check:

* Whether the host exists in Company_B PROD or Company_B NON-PROD.
* Whether the host should be part of the Company_A Management Zone.
* Whether the Management Zone rules are correctly configured.
* Whether the entity is historical/stale and no longer matches current zone rules.

***

### Too many `UNKNOWN`

Check:

* API response validity.
* Token permissions.
* Whether `managementZones` is returned in the entity response.
* Tenant API availability.

***

### Too many `API_ERROR`

Check:

* API token permissions.
* Tenant URL.
* Network connectivity.
* Token expiration.
* API response body in the log.

***

## 30. Example Runs

### Company_A only

```bash
printf "3\n" | ./cross_tenant_health_audit.sh
```

Expected outputs:

```text
ct_health_audit_Company_A_report_<timestamp>.csv
ct_health_audit_Company_A_excluded_<timestamp>.csv
ct_health_audit_Company_A_executive_summary_<timestamp>.csv
ct_health_audit_Company_A_report_<timestamp>.log
```

If Company_A has `NOT_FOUND` hosts, a cross-tenant discovery file is also generated.

***

### Global

```bash
printf "4\n" | ./cross_tenant_health_audit.sh
```

Expected outputs:

```text
ct_health_audit_global_report_<timestamp>.csv
ct_health_audit_global_notfound_discovery_<timestamp>.csv
ct_health_audit_global_excluded_<timestamp>.csv
ct_health_audit_Company_B_executive_summary_<timestamp>.csv
ct_health_audit_Company_A_executive_summary_<timestamp>.csv
ct_health_audit_global_report_<timestamp>.log
```

***

## 31. Operational Interpretation

Use the reports as follows:

### Primary Report

Use for full technical detail.

Includes:

* Status.
* `lastSeenTms`.
* Human-readable age.
* Match count.
* Dynatrace `entityId`.
* Dynatrace `displayName`.
* Company_A Management Zone status for Company_B hosts.

***

### Discovery Report

Use to identify tenant mismatches.

Focus on:

```text
FOUND_IN_DIFFERENT_TENANT
MULTI_TENANT_MATCH
NOT_FOUND_ALL_CONFIGURED_TENANTS
```

***

### Excluded Report

Use to document known exceptions.

***

### Executive Summary

Use for action items.

Focus on:

```text
STALE_XH_PLUS
NOT_FOUND_ALL_TENANTS
```

***

## 32. Design Principles

```text
Do not hide inconsistencies.
```

If a host is expected in one tenant but found in another, the framework must show both:

```text
Expected tenant
Actual tenant
```

```text
Do not filter the primary lookup by Management Zone.
```

The framework must first determine whether the host exists in the tenant.

Management Zone membership is additional evidence, not a primary filter.

```text
Do not treat known exceptions as monitoring failures.
```

Hosts excluded by design must be documented, not repeatedly reported as gaps.

```text
Do not depend on manual UI validation.
```

The framework must rely on repeatable API-driven evidence.

```text
Do not create personal dependency.
```

Configuration, assumptions, inputs, outputs, and troubleshooting must be documented so ownership can be transferred.

***

## 33. Roadmap

### v1.0 — Released / Usable

Initial usable release.

Includes:

* ESL inventory parsing.
* Tenant classification.
* Dynatrace API validation.
* Primary report.
* Cross-tenant discovery.
* Exclusions.
* Executive summaries.
* Tenant-level parallelism.
* Timestamped CSV/log outputs.

***

### v1.1 — Entity Evidence + Company_A Management Zone Validation

Implemented / in progress:

* Add `entityId`.
* Add `displayName`.
* Add Company_A Management Zone status for Company_B hosts.
* Optimize Management Zone validation using `managementZones` from the same API response.
* Avoid second API call per Company_B host.
* Preserve hidden stale entity evidence.

***

### v1.2 — Power BI Dashboard

Planned:

* Host status by tenant.
* Connected vs disconnected.
* Stale hosts by age bucket.
* `NOT_FOUND_ALL_CONFIGURED_TENANTS`.
* `FOUND_IN_DIFFERENT_TENANT`.
* `MZ Company_A` vs `MZ Not Company_A`.
* Excluded hosts by reason.
* Executive action views.

***

### v1.3 — Historical Trend Model

Planned:

* Track changes across executions.
* Identify recurring disconnected hosts.
* Identify recurring missing hosts.
* Track monitoring drift.
* Build time-series-ready datasets.

***

### v1.4 — Tenant / Account Onboarding Template

Planned:

* Required tenant configuration.
* Required token permissions.
* Inventory source mapping.
* Domain classification mapping.
* Environment classification mapping.
* Exclusion file template.
* Output interpretation guide.
* Power BI onboarding notes.

***

## 34. Final Outcome

Cross-Tenant Health Audit Framework provides:

```text
Inventory Validation
+
Monitoring Coverage Validation
+
Cross-Tenant Discovery
+
Management Zone Evidence
+
Known Exception Handling
+
Executive Action Outputs
```

The result is a repeatable and auditable operational framework for monitoring coverage validation across multiple Dynatrace tenants.
