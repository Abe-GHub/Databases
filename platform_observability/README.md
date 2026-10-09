# Platform Observability

A Snowflake history database, built with dbt Cloud, that preserves platform activity beyond the roughly 365 days `SNOWFLAKE.ACCOUNT_USAGE` retains.

## What it captures

1. **Object changes:** objects created, altered, or dropped each day (event-based, driven by `ACCESS_HISTORY` DDL events)
2. **Activity history:** every query, categorized as DDL create / alter / drop, DML, SELECT, grants, procedure and function calls, and other
3. **Cortex usage:** AI usage across Cortex services, attributed to individual users wherever Snowflake provides it

## Design decisions

| Decision | Choice |
|---|---|
| Snowflake edition | Enterprise (`ACCESS_HISTORY` available) |
| Transformation | dbt Cloud, incremental models with a 3-day lookback to absorb `ACCOUNT_USAGE` latency |
| Object history grain | Only objects created, altered, or dropped that day |
| SQL text | Full text retained |
| Retention | Purge after 2 years |
| Initial load | Full backfill of all history Snowflake still holds |

## Target structure

```
PLATFORM_OBSERVABILITY
├── STAGING   views over ACCOUNT_USAGE
├── HISTORY   permanent, append-only history tables
└── MARTS     daily summaries for reporting
```

## Build steps

| Step | Deliverable | Status |
|---|---|---|
| 1 | [Discovery & validation notebook](notebooks/01_discovery_validation.ipynb) | Ready to run |
| 2 | [Infrastructure setup notebook](notebooks/02_infrastructure_setup.ipynb) and [runnable script](setup/02_infrastructure_setup.sql): database, schemas, warehouse, roles, dbt service user, grants | Ready to run |
| 3 | dbt project scaffold, sources, staging models | Planned |
| 4 | Object change history models and tests | Planned |
| 5 | Activity history models and tests | Planned |
| 6 | Cortex usage history and marts | Planned |
| 7 | Daily schedule, backfill, retention purge | Planned |

## Running the steps

- **Step 1:** import `notebooks/01_discovery_validation.ipynb` into Snowsight (*Projects > Notebooks > Import .ipynb file*) and run it with a role that has `IMPORTED PRIVILEGES` on the `SNOWFLAKE` database. All queries are read-only.
- **Step 2:** read `notebooks/02_infrastructure_setup.ipynb` for the walkthrough, then run `setup/02_infrastructure_setup.sql` in a Snowsight SQL worksheet as a user holding `ACCOUNTADMIN`. It switches between admin roles, which Snowflake Notebooks don't support. Replace the two placeholders first.
