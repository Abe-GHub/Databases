/* =============================================================================
   PLATFORM_OBSERVABILITY: Step 2 Infrastructure Setup
   -----------------------------------------------------------------------------
   Companion to notebooks/02_infrastructure_setup.ipynb (same statements, with
   explanations). Run in a Snowsight SQL worksheet or SnowSQL as a user holding
   ACCOUNTADMIN. Safe to re-run.

   BEFORE RUNNING, replace:
     <DBT_CLOUD_PUBLIC_KEY>  public key body from section 0 of the notebook
     <YOUR_USER_NAME>        your Snowflake login name
   ============================================================================= */


/* -----------------------------------------------------------------------------
   1. Roles
   ----------------------------------------------------------------------------- */
USE ROLE USERADMIN;

CREATE ROLE IF NOT EXISTS OBSERVABILITY_TRANSFORMER
  COMMENT = 'dbt Cloud role: builds and owns PLATFORM_OBSERVABILITY';

CREATE ROLE IF NOT EXISTS OBSERVABILITY_READER
  COMMENT = 'Read-only access to PLATFORM_OBSERVABILITY history and marts';

GRANT ROLE OBSERVABILITY_READER      TO ROLE OBSERVABILITY_TRANSFORMER;
GRANT ROLE OBSERVABILITY_TRANSFORMER TO ROLE SYSADMIN;

/* -----------------------------------------------------------------------------
   2. Warehouse and resource monitor
   ----------------------------------------------------------------------------- */
USE ROLE SYSADMIN;

CREATE WAREHOUSE IF NOT EXISTS OBSERVABILITY_WH
  WITH WAREHOUSE_SIZE              = 'XSMALL'
       AUTO_SUSPEND                = 60
       AUTO_RESUME                 = TRUE
       INITIALLY_SUSPENDED         = TRUE
       STATEMENT_TIMEOUT_IN_SECONDS = 3600
       COMMENT                     = 'Compute for PLATFORM_OBSERVABILITY dbt runs';

USE ROLE ACCOUNTADMIN;

CREATE RESOURCE MONITOR IF NOT EXISTS OBSERVABILITY_RM
  WITH CREDIT_QUOTA    = 20
       FREQUENCY       = MONTHLY
       START_TIMESTAMP = IMMEDIATELY
       TRIGGERS ON  80 PERCENT DO NOTIFY
                ON 100 PERCENT DO SUSPEND
                ON 110 PERCENT DO SUSPEND_IMMEDIATE;

ALTER WAREHOUSE OBSERVABILITY_WH SET RESOURCE_MONITOR = OBSERVABILITY_RM;

/* -----------------------------------------------------------------------------
   3. Database and schemas
   ----------------------------------------------------------------------------- */
USE ROLE SYSADMIN;

CREATE DATABASE IF NOT EXISTS PLATFORM_OBSERVABILITY
  DATA_RETENTION_TIME_IN_DAYS = 7
  COMMENT = 'Long-term history of Snowflake object changes, query activity and Cortex usage';

CREATE SCHEMA IF NOT EXISTS PLATFORM_OBSERVABILITY.STAGING
  COMMENT = 'dbt staging views over SNOWFLAKE.ACCOUNT_USAGE';

CREATE SCHEMA IF NOT EXISTS PLATFORM_OBSERVABILITY.HISTORY
  DATA_RETENTION_TIME_IN_DAYS = 30
  COMMENT = 'Permanent append-only history tables (2-year retention)';

CREATE SCHEMA IF NOT EXISTS PLATFORM_OBSERVABILITY.MARTS
  COMMENT = 'Daily summaries for reporting';

/* -----------------------------------------------------------------------------
   4. Hand the schemas to dbt
   ----------------------------------------------------------------------------- */
USE ROLE SYSADMIN;

GRANT USAGE, MONITOR       ON DATABASE PLATFORM_OBSERVABILITY TO ROLE OBSERVABILITY_TRANSFORMER;
GRANT CREATE SCHEMA        ON DATABASE PLATFORM_OBSERVABILITY TO ROLE OBSERVABILITY_TRANSFORMER;

GRANT OWNERSHIP ON SCHEMA PLATFORM_OBSERVABILITY.STAGING TO ROLE OBSERVABILITY_TRANSFORMER COPY CURRENT GRANTS;
GRANT OWNERSHIP ON SCHEMA PLATFORM_OBSERVABILITY.HISTORY TO ROLE OBSERVABILITY_TRANSFORMER COPY CURRENT GRANTS;
GRANT OWNERSHIP ON SCHEMA PLATFORM_OBSERVABILITY.MARTS   TO ROLE OBSERVABILITY_TRANSFORMER COPY CURRENT GRANTS;

GRANT USAGE, OPERATE ON WAREHOUSE OBSERVABILITY_WH TO ROLE OBSERVABILITY_TRANSFORMER;
GRANT USAGE          ON WAREHOUSE OBSERVABILITY_WH TO ROLE OBSERVABILITY_READER;

/* -----------------------------------------------------------------------------
   5. Reader access (including tables dbt has not built yet)
   ----------------------------------------------------------------------------- */
USE ROLE SECURITYADMIN;

GRANT USAGE ON DATABASE PLATFORM_OBSERVABILITY         TO ROLE OBSERVABILITY_READER;
GRANT USAGE ON SCHEMA   PLATFORM_OBSERVABILITY.HISTORY TO ROLE OBSERVABILITY_READER;
GRANT USAGE ON SCHEMA   PLATFORM_OBSERVABILITY.MARTS   TO ROLE OBSERVABILITY_READER;

GRANT SELECT ON FUTURE TABLES IN SCHEMA PLATFORM_OBSERVABILITY.HISTORY TO ROLE OBSERVABILITY_READER;
GRANT SELECT ON FUTURE VIEWS  IN SCHEMA PLATFORM_OBSERVABILITY.HISTORY TO ROLE OBSERVABILITY_READER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA PLATFORM_OBSERVABILITY.MARTS   TO ROLE OBSERVABILITY_READER;
GRANT SELECT ON FUTURE VIEWS  IN SCHEMA PLATFORM_OBSERVABILITY.MARTS   TO ROLE OBSERVABILITY_READER;

/* -----------------------------------------------------------------------------
   6. Access to `SNOWFLAKE.ACCOUNT_USAGE`
   ----------------------------------------------------------------------------- */
USE ROLE ACCOUNTADMIN;

GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE TO ROLE OBSERVABILITY_TRANSFORMER;

/* -----------------------------------------------------------------------------
   7. dbt Cloud service user and developer access
   ----------------------------------------------------------------------------- */
USE ROLE USERADMIN;

CREATE USER IF NOT EXISTS DBT_CLOUD_SVC
  TYPE              = SERVICE
  DEFAULT_ROLE      = OBSERVABILITY_TRANSFORMER
  DEFAULT_WAREHOUSE = OBSERVABILITY_WH
  DEFAULT_NAMESPACE = 'PLATFORM_OBSERVABILITY.STAGING'
  RSA_PUBLIC_KEY    = '<DBT_CLOUD_PUBLIC_KEY>'
  COMMENT           = 'dbt Cloud production jobs for PLATFORM_OBSERVABILITY';

USE ROLE SECURITYADMIN;

GRANT ROLE OBSERVABILITY_TRANSFORMER TO USER DBT_CLOUD_SVC;
GRANT ROLE OBSERVABILITY_TRANSFORMER TO USER <YOUR_USER_NAME>;

/* -----------------------------------------------------------------------------
   8. Validate: grants and user setup
   ----------------------------------------------------------------------------- */
USE ROLE SECURITYADMIN;

SHOW GRANTS TO ROLE OBSERVABILITY_TRANSFORMER;
SHOW GRANTS TO ROLE OBSERVABILITY_READER;
SHOW FUTURE GRANTS IN SCHEMA PLATFORM_OBSERVABILITY.HISTORY;

DESC USER DBT_CLOUD_SVC;

/* -----------------------------------------------------------------------------
   9. Validate: act as dbt would
   ----------------------------------------------------------------------------- */
USE ROLE OBSERVABILITY_TRANSFORMER;
USE WAREHOUSE OBSERVABILITY_WH;

SELECT COUNT(*) AS queries_last_24h
FROM   SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE  start_time >= DATEADD(hour, -24, CURRENT_TIMESTAMP());

CREATE TABLE PLATFORM_OBSERVABILITY.STAGING.ZZ_SETUP_CHECK (id INT);
CREATE TABLE PLATFORM_OBSERVABILITY.HISTORY.ZZ_SETUP_CHECK (id INT);
CREATE TABLE PLATFORM_OBSERVABILITY.MARTS.ZZ_SETUP_CHECK   (id INT);

DROP TABLE PLATFORM_OBSERVABILITY.STAGING.ZZ_SETUP_CHECK;
DROP TABLE PLATFORM_OBSERVABILITY.HISTORY.ZZ_SETUP_CHECK;
DROP TABLE PLATFORM_OBSERVABILITY.MARTS.ZZ_SETUP_CHECK;

ALTER WAREHOUSE OBSERVABILITY_WH SUSPEND;

/* -----------------------------------------------------------------------------
   Rollback (commented out)
   ----------------------------------------------------------------------------- */
-- USE ROLE ACCOUNTADMIN;
-- DROP USER             IF EXISTS DBT_CLOUD_SVC;
-- DROP DATABASE         IF EXISTS PLATFORM_OBSERVABILITY;
-- DROP WAREHOUSE        IF EXISTS OBSERVABILITY_WH;
-- DROP RESOURCE MONITOR IF EXISTS OBSERVABILITY_RM;
-- DROP ROLE             IF EXISTS OBSERVABILITY_READER;
-- DROP ROLE             IF EXISTS OBSERVABILITY_TRANSFORMER;
