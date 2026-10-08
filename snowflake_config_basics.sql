/* =============================================================================
   Snowflake Platform Configuration: 20 Essential Discovery Queries
   -----------------------------------------------------------------------------
   Purpose : Quickly understand how a Snowflake account is configured:
             identity, compute, storage, security, governance, and cost.
   Author  : Abraham Kirubakaran
   Notes   :
     - Most SHOW commands return only objects visible to your current role.
       Run as ACCOUNTADMIN (or a role with equivalent visibility) for a full view.
     - SNOWFLAKE.ACCOUNT_USAGE views require IMPORTED PRIVILEGES on the
       SNOWFLAKE database and have a data latency of roughly 45 min to 3 hours.
     - Replace <PLACEHOLDERS> before running.
   ============================================================================= */

USE ROLE ACCOUNTADMIN;


/* -----------------------------------------------------------------------------
   SECTION 1: ACCOUNT & SESSION CONTEXT
   ----------------------------------------------------------------------------- */

-- 01. Account identity: organization, account, cloud region, and Snowflake version
SELECT CURRENT_ORGANIZATION_NAME() AS org_name,
       CURRENT_ACCOUNT_NAME()      AS account_name,
       CURRENT_ACCOUNT()           AS account_locator,
       CURRENT_REGION()            AS region,
       CURRENT_VERSION()           AS snowflake_version;

-- 02. Session context: who you are and what you are pointed at
SELECT CURRENT_USER()            AS user_name,
       CURRENT_ROLE()            AS primary_role,
       CURRENT_SECONDARY_ROLES() AS secondary_roles,
       CURRENT_WAREHOUSE()       AS warehouse,
       CURRENT_DATABASE()        AS database_name,
       CURRENT_SCHEMA()          AS schema_name;

-- 03. Account-level parameters (timezone, timeouts, MFA, retention defaults, etc.)
SHOW PARAMETERS IN ACCOUNT;


/* -----------------------------------------------------------------------------
   SECTION 2: COMPUTE
   ----------------------------------------------------------------------------- */

-- 04. Virtual warehouses: size, auto-suspend, auto-resume, scaling policy, state
SHOW WAREHOUSES;

-- 05. Resource monitors: credit quotas and the warehouses they govern
SHOW RESOURCE MONITORS;


/* -----------------------------------------------------------------------------
   SECTION 3: STORAGE & DATA OBJECTS
   ----------------------------------------------------------------------------- */

-- 06. Databases: owner, retention time, origin (local vs. shared)
SHOW DATABASES;

-- 07. Schemas across the account
SHOW SCHEMAS IN ACCOUNT;

-- 08. Stages (internal and external) used for loading and unloading data
SHOW STAGES IN ACCOUNT;

-- 09. Secure data shares (inbound and outbound)
SHOW SHARES;


/* -----------------------------------------------------------------------------
   SECTION 4: IDENTITY & ACCESS
   ----------------------------------------------------------------------------- */

-- 10. Users: default role/warehouse, disabled flag, last login, auth type
SHOW USERS;

-- 11. Roles: the role hierarchy building blocks
SHOW ROLES;

-- 12. Privileges granted to a specific role
SHOW GRANTS TO ROLE <ROLE_NAME>;

-- 13. Roles granted to a specific user
SHOW GRANTS TO USER <USER_NAME>;

-- 14. Who currently holds ACCOUNTADMIN (should be a small, known list)
SELECT grantee_name,
       granted_by,
       created_on
FROM   SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS
WHERE  role = 'ACCOUNTADMIN'
  AND  deleted_on IS NULL
ORDER  BY created_on;


/* -----------------------------------------------------------------------------
   SECTION 5: SECURITY & INTEGRATIONS
   ----------------------------------------------------------------------------- */

-- 15. Network policies: allowed and blocked IP lists
SHOW NETWORK POLICIES;

-- 16. Integrations: SSO/SCIM/OAuth (security), storage, API, and notification
SHOW INTEGRATIONS;

-- 17. Failed logins in the last 7 days (security posture check)
SELECT event_timestamp,
       user_name,
       client_ip,
       reported_client_type,
       error_message
FROM   SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY
WHERE  is_success = 'NO'
  AND  event_timestamp >= DATEADD(day, -7, CURRENT_TIMESTAMP())
ORDER  BY event_timestamp DESC;


/* -----------------------------------------------------------------------------
   SECTION 6: COST & USAGE
   ----------------------------------------------------------------------------- */

-- 18. Credits consumed per warehouse over the last 30 days
SELECT warehouse_name,
       ROUND(SUM(credits_used), 2) AS credits_used_30d
FROM   SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE  start_time >= DATEADD(day, -30, CURRENT_TIMESTAMP())
GROUP  BY warehouse_name
ORDER  BY credits_used_30d DESC;

-- 19. Storage footprint per database (latest day), including Fail-safe
SELECT database_name,
       ROUND(average_database_bytes / POWER(1024, 3), 2) AS database_gb,
       ROUND(average_failsafe_bytes / POWER(1024, 3), 2) AS failsafe_gb
FROM   SNOWFLAKE.ACCOUNT_USAGE.DATABASE_STORAGE_USAGE_HISTORY
WHERE  usage_date = (SELECT MAX(usage_date)
                     FROM SNOWFLAKE.ACCOUNT_USAGE.DATABASE_STORAGE_USAGE_HISTORY)
ORDER  BY database_gb DESC;

-- 20. Top 20 longest-running queries in the last 7 days
SELECT query_id,
       user_name,
       warehouse_name,
       execution_status,
       ROUND(total_elapsed_time / 1000, 1) AS elapsed_seconds,
       start_time,
       LEFT(query_text, 200)               AS query_preview
FROM   SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE  start_time >= DATEADD(day, -7, CURRENT_TIMESTAMP())
ORDER  BY total_elapsed_time DESC
LIMIT  20;
