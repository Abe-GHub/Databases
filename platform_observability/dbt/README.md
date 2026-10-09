# dbt project: platform_observability

Builds the `PLATFORM_OBSERVABILITY` history database from `SNOWFLAKE.ACCOUNT_USAGE`. Requires the Step 2 infrastructure (`../setup/02_infrastructure_setup.sql`) to be in place.

## Project layout

```
dbt/
├── dbt_project.yml          configs, vars, full_refresh safeguard on HISTORY
├── packages.yml             dbt_utils
├── macros/
│   ├── generate_schema_name.sql    prod -> STAGING/HISTORY/MARTS, dev -> DBT_<you>_*
│   └── categorize_query_type.sql   QUERY_TYPE -> activity category
└── models/
    ├── staging/             views over ACCOUNT_USAGE (Step 3)
    ├── history/             incremental, permanent history (Steps 4 to 6)
    └── marts/               daily summaries (Step 6)
```

## Staging models (Step 3)

| Model | Source | Grain |
|---|---|---|
| `stg_account_usage__query_history` | `QUERY_HISTORY` | One row per query, plus `ACTIVITY_CATEGORY` |
| `stg_account_usage__ddl_events` | `ACCESS_HISTORY` | One row per CREATE / ALTER / DROP / REPLACE / UNDROP |
| `stg_account_usage__users` | `USERS` | One row per user, including dropped users |
| `stg_account_usage__cortex_ai_functions_usage` | `CORTEX_AI_FUNCTIONS_USAGE_HISTORY` | One row per query per one-hour usage window |

All are views, so they cost nothing to store. Tests scan only the last 3 days (`test_window_days`) to stay cheap.

## Variables

| Variable | Default | Purpose |
|---|---|---|
| `lookback_days` | 3 | Days re-read on each incremental run to catch late-arriving rows |
| `retention_days` | 730 | History older than this is purged (2 years) |
| `backfill_start_date` | 2025-01-01 | Earliest date for the initial load (ACCOUNT_USAGE holds ~365 days) |
| `test_window_days` | 3 | Days of data tests scan |

## dbt Cloud setup

### 1. Connect the repository
- **Account settings > Projects > New project**, name it `platform_observability`.
- **Repository:** GitHub, `Abe-GHub/Databases`.
- **Project subdirectory:** `platform_observability/dbt` (the repo holds more than this project).

### 2. Snowflake connection

| Setting | Value |
|---|---|
| Account | `<orgname>-<account_name>` |
| Database | `PLATFORM_OBSERVABILITY` |
| Warehouse | `OBSERVABILITY_WH` |
| Role | `OBSERVABILITY_TRANSFORMER` |

### 3. Development credentials (dbt Cloud IDE)
- **Auth method:** your own Snowflake login (key pair or SSO).
- **Schema:** `DBT_<YOURNAME>`, for example `DBT_ABE`. Models build into `DBT_ABE_STAGING`, `DBT_ABE_HISTORY` and so on, never the production schemas.

### 4. Production environment
- **Environment type:** Deployment, Production.
- **dbt version:** Latest (1.10 or newer is required).
- **Deployment credentials:** user `DBT_CLOUD_SVC`, auth method **Key pair**; upload the private key and passphrase from Step 2.
- **Schema:** `STAGING` (fallback only; the schema macro routes models to their real schemas).
- **Target name:** `prod`. **This matters:** the schema macro routes to `STAGING`/`HISTORY`/`MARTS` only when the target name is `prod`.

The daily job is defined in Step 7.

## Validate Step 3

In the dbt Cloud IDE, run:

```bash
dbt deps
dbt debug                       # connection and permissions
dbt source freshness            # ACCOUNT_USAGE is reachable and current
dbt build --select staging      # creates the 4 views and runs 10 tests
```

**Expected:** all four views are created in `DBT_<YOURNAME>_STAGING`, and the tests pass. Warnings are acceptable on:
- `accepted_values` for `change_type`, if `ACCESS_HISTORY` reports an operation type not yet mapped;
- the Cortex `relationships` test, for usage recorded before user attribution began.

Then spot-check the activity mapping in Snowflake:

```sql
select activity_category, query_type, count(*) as queries
from   PLATFORM_OBSERVABILITY.DBT_<YOURNAME>_STAGING.STG_ACCOUNT_USAGE__QUERY_HISTORY
where  start_time >= dateadd(day, -7, current_timestamp())
group  by 1, 2
order  by 1, 3 desc;
```

Anything landing in `OTHER` that you would rather categorize goes into `macros/categorize_query_type.sql`.
