# Snowflake Configuration Basics

Twenty essential SQL statements for getting oriented in any Snowflake account. Useful for onboarding to a new environment, platform health checks, security reviews, and cost conversations.

## What's covered

| # | Area | Statement | What it tells you |
|---|------|-----------|-------------------|
| 01 | Account | `CURRENT_ORGANIZATION_NAME()` and friends | Org, account, region, version |
| 02 | Session | `CURRENT_USER()`, `CURRENT_ROLE()`, ... | Your active context |
| 03 | Account | `SHOW PARAMETERS IN ACCOUNT` | Account-wide defaults and settings |
| 04 | Compute | `SHOW WAREHOUSES` | Sizing, auto-suspend, scaling |
| 05 | Compute | `SHOW RESOURCE MONITORS` | Credit guardrails |
| 06 | Storage | `SHOW DATABASES` | Databases and retention |
| 07 | Storage | `SHOW SCHEMAS IN ACCOUNT` | Schema inventory |
| 08 | Storage | `SHOW STAGES IN ACCOUNT` | Load/unload locations |
| 09 | Storage | `SHOW SHARES` | Inbound and outbound data sharing |
| 10 | Access | `SHOW USERS` | User inventory and status |
| 11 | Access | `SHOW ROLES` | Role inventory |
| 12 | Access | `SHOW GRANTS TO ROLE` | Privileges held by a role |
| 13 | Access | `SHOW GRANTS TO USER` | Roles held by a user |
| 14 | Access | `ACCOUNT_USAGE.GRANTS_TO_USERS` | Who holds ACCOUNTADMIN |
| 15 | Security | `SHOW NETWORK POLICIES` | IP allow and block lists |
| 16 | Security | `SHOW INTEGRATIONS` | SSO, SCIM, OAuth, storage, API |
| 17 | Security | `ACCOUNT_USAGE.LOGIN_HISTORY` | Failed logins, last 7 days |
| 18 | Cost | `ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | Credits per warehouse, 30 days |
| 19 | Cost | `ACCOUNT_USAGE.DATABASE_STORAGE_USAGE_HISTORY` | Storage per database |
| 20 | Performance | `ACCOUNT_USAGE.QUERY_HISTORY` | Longest-running queries, 7 days |

## How to use

1. Open `snowflake_config_basics.sql` in Snowsight or SnowSQL.
2. Replace `<ROLE_NAME>` and `<USER_NAME>` placeholders in statements 12 and 13.
3. Run statements individually or by section.

## Prerequisites

- **Role:** `SHOW` commands only return objects visible to your active role. Use `ACCOUNTADMIN` (or an equivalent custom role) for a complete picture.
- **ACCOUNT_USAGE access:** Statements 14 and 17 to 20 need `IMPORTED PRIVILEGES` on the `SNOWFLAKE` database:
  ```sql
  GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE TO ROLE <ROLE_NAME>;
  ```
- **Latency:** `ACCOUNT_USAGE` views lag real time by roughly 45 minutes to 3 hours.

## Tip

Any `SHOW` output can be filtered with SQL using `RESULT_SCAN`:

```sql
SHOW WAREHOUSES;
SELECT "name", "size", "auto_suspend", "state"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "auto_suspend" IS NULL OR "auto_suspend" > 600;
```

## License

MIT
