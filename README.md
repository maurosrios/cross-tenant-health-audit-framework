# Cross-Tenant Health Audit Framework

An operational reconciliation framework designed to validate infrastructure monitoring coverage across multiple Dynatrace tenants by comparing inventory data against real-time monitoring visibility.

## Overview
This framework automates the validation of monitoring coverage, identifying blind spots, mismatches between inventory and monitoring, and stale entities. It provides actionable executive summaries without manual UI intervention.

## Key Features
- **Cross-Tenant Reconciliation:** Detects if hosts are missing from their expected tenant but reporting in another.
- **Management Zone Validation:** Automatically validates Company_A Management Zone membership for Company_B hosts.
- **Resilient API Interaction:** Single-call optimization per host to reduce API load and throttling risks.
- **Actionable Insights:** Generates primary health reports, discovery reports for missing hosts, and executive summaries.
- **Operational Hygiene:** Handles known exclusions via blacklist and generates clean inventory lists.

## Security & Privacy
- **Hardened Design:** Designed to operate with non-root security principles.
- **Sensitive Data:** API tokens are stored in external, permission-restricted configuration files (`~/.ct_health_audit.conf`). 
  *Note: Never commit configuration files to version control.*

## License
This project is licensed under the **GNU Affero General Public License v3.0 (AGPLv3)**.

You are free to use, modify, and distribute this software. If you run a modified version of this software on a network (as a service), you must make the source code of your modifications available.

**Commercial Use:**
This project is free for personal, internal, and educational use. For any commercial use or integration into enterprise product offerings, please contact the author for a commercial license.

## Usage
Refer to the detailed internal documentation for setup, configuration thresholds, and cron integration.
