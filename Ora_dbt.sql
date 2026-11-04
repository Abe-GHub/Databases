/*
  Oracle PL/SQL -> dbt SQL translation for the K-12 Stage -> Domain pipeline.

  IMPORTANT: dbt builds one relation per model file. This requested consolidated
  file documents the separate model SQL bodies; split each section marked
  "MODEL" into its own .sql file under models/ before running dbt. For example:
    dom_school.sql, dom_student.sql, dom_enrollment.sql,
    dom_attendance_daily.sql, etl_reject.sql

  Assumptions:
  - Define source('legacy', ...) entries for the four stg_* source tables.
  - Define ref('code_map') as a dbt seed/model with domain_name, input_code,
    output_code (normalize input_code to uppercase in that model/seed).
  - This SQL uses Oracle-compatible SQL expressions. Configure the dbt Oracle
    adapter/profile (or adapt date expressions for your target warehouse).
  - Incremental models use dbt's merge strategy and unique keys. dbt handles
    the merge/upsert; there is no PL/SQL package, sequence, commit, or run log.
  - Reject records are exposed as a model; dbt tests/run results replace the
    procedural run log. Add a run-id or invocation-id column if operationally
    required by your platform.
*/

/* ============================ MODEL: dom_school ============================
   Save this section as models/dom_school.sql.
*/
{{ config(materialized='incremental', incremental_strategy='merge', unique_key='school_code') }}

WITH source_rows AS (
    SELECT
        UPPER(TRIM(school_code)) AS school_code,
        INITCAP(TRIM(school_name)) AS school_name,
        UPPER(TRIM(school_type)) AS school_type_input,
        UPPER(TRIM(region)) AS region,
        UPPER(TRIM(low_grade)) AS low_grade_input,
        UPPER(TRIM(high_grade)) AS high_grade_input,
        load_dt,
        ROW_NUMBER() OVER (
            PARTITION BY UPPER(TRIM(school_code))
            ORDER BY load_dt DESC
        ) AS rn
    FROM {{ source('legacy', 'stg_school') }}
    WHERE TRIM(school_code) IS NOT NULL
      AND TRIM(school_name) IS NOT NULL
), latest AS (
    SELECT * FROM source_rows WHERE rn = 1
), mapped AS (
    SELECT
        s.school_code,
        s.school_name,
        COALESCE(cm.output_code, 'UNKNOWN') AS school_type,
        s.region,
        CASE
            WHEN s.low_grade_input IN ('K', 'KG', 'KN') THEN 'KG'
            WHEN s.low_grade_input IN ('TK', 'PK') THEN s.low_grade_input
            WHEN REGEXP_LIKE(s.low_grade_input, '^[0-9]{1,2}$')
             AND TO_NUMBER(s.low_grade_input) BETWEEN 1 AND 12
                THEN LPAD(s.low_grade_input, 2, '0')
            ELSE NULL
        END AS low_grade,
        CASE
            WHEN s.high_grade_input IN ('K', 'KG', 'KN') THEN 'KG'
            WHEN s.high_grade_input IN ('TK', 'PK') THEN s.high_grade_input
            WHEN REGEXP_LIKE(s.high_grade_input, '^[0-9]{1,2}$')
             AND TO_NUMBER(s.high_grade_input) BETWEEN 1 AND 12
                THEN LPAD(s.high_grade_input, 2, '0')
            ELSE NULL
        END AS high_grade
    FROM latest s
    LEFT JOIN {{ ref('code_map') }} cm
      ON cm.domain_name = 'SCHOOL_TYPE'
     AND cm.input_code = s.school_type_input
)
SELECT school_code, school_name, school_type, region, low_grade, high_grade,
       SYSDATE AS updated_dt
FROM mapped
{% if is_incremental() %}
WHERE school_code NOT IN (SELECT school_code FROM {{ this }} WHERE school_code IS NOT NULL)
   OR EXISTS (
       SELECT 1 FROM {{ this }} t
       WHERE t.school_code = mapped.school_code
         AND NVL(t.updated_dt, DATE '1900-01-01') < NVL(mapped.load_dt, DATE '1900-01-01')
   )
{% endif %}

/* ============================ MODEL: dom_student ===========================
   Save this section as models/dom_student.sql.
*/
{{ config(materialized='incremental', incremental_strategy='merge', unique_key='student_id') }}

WITH source_rows AS (
    SELECT
        UPPER(TRIM(student_id)) AS student_id,
        INITCAP(TRIM(first_name)) AS first_name,
        INITCAP(TRIM(last_name)) AS last_name,
        TRIM(birth_date) AS birth_date_text,
        UPPER(TRIM(gender)) AS gender_input,
        NVL(INITCAP(TRIM(home_language)), 'Unknown') AS home_language,
        CASE WHEN UPPER(TRIM(el_status)) IN ('Y','YES','1','EL') THEN 'Y' ELSE 'N' END AS is_english_learner,
        CASE WHEN UPPER(TRIM(frl_status)) IN ('Y','YES','1','F','R') THEN 'Y' ELSE 'N' END AS is_frl_eligible,
        load_dt,
        ROW_NUMBER() OVER (
            PARTITION BY UPPER(TRIM(student_id)) ORDER BY load_dt DESC
        ) AS rn
    FROM {{ source('legacy', 'stg_student') }}
    WHERE TRIM(student_id) IS NOT NULL
      AND TRIM(first_name) IS NOT NULL
      AND TRIM(last_name) IS NOT NULL
), parsed AS (
    SELECT s.*,
        CASE
            WHEN REGEXP_LIKE(birth_date_text, '^[0-9]{4}-[0-9]{2}-[0-9]{2}$')
                THEN TO_DATE(birth_date_text, 'FXYYYY-MM-DD')
            WHEN REGEXP_LIKE(birth_date_text, '^[0-9]{2}/[0-9]{2}/[0-9]{4}$')
                THEN TO_DATE(birth_date_text, 'FXMM/DD/YYYY')
            WHEN REGEXP_LIKE(birth_date_text, '^[0-9]{8}$')
                THEN TO_DATE(birth_date_text, 'FXYYYYMMDD')
            ELSE NULL
        END AS birth_date
    FROM source_rows s
), latest_valid AS (
    SELECT * FROM parsed
    WHERE rn = 1 AND birth_date IS NOT NULL AND birth_date <= SYSDATE
)
SELECT
    s.student_id, s.first_name, s.last_name, s.birth_date,
    COALESCE(cm.output_code, 'UNKNOWN') AS gender,
    s.home_language, s.is_english_learner, s.is_frl_eligible,
    SYSDATE AS updated_dt
FROM latest_valid s
LEFT JOIN {{ ref('code_map') }} cm
  ON cm.domain_name = 'GENDER'
 AND cm.input_code = s.gender_input

/* ========================== MODEL: dom_enrollment ==========================
   Save this section as models/dom_enrollment.sql.
*/
{{ config(materialized='incremental', incremental_strategy='merge',
          unique_key=['student_id', 'school_code', 'school_year', 'entry_date']) }}

WITH raw AS (
    SELECT
        UPPER(TRIM(e.student_id)) AS student_id,
        UPPER(TRIM(e.school_code)) AS school_code,
        TRIM(e.school_year) AS school_year_text,
        UPPER(TRIM(e.grade_level)) AS grade_input,
        TRIM(e.entry_date) AS entry_date_text,
        TRIM(e.exit_date) AS exit_date_text,
        CASE
            WHEN REGEXP_LIKE(TRIM(e.school_year), '^[0-9]{4}-[0-9]{2}$')
                THEN TO_NUMBER(SUBSTR(TRIM(e.school_year), 1, 2) || SUBSTR(TRIM(e.school_year), 6, 2))
            WHEN REGEXP_LIKE(TRIM(e.school_year), '^[0-9]{4}$')
                THEN TO_NUMBER(TRIM(e.school_year))
            ELSE NULL
        END AS school_year,
        CASE
            WHEN UPPER(TRIM(e.grade_level)) IN ('K','KG','KN') THEN 'KG'
            WHEN UPPER(TRIM(e.grade_level)) IN ('TK','PK') THEN UPPER(TRIM(e.grade_level))
            WHEN REGEXP_LIKE(TRIM(e.grade_level), '^[0-9]{1,2}$')
             AND TO_NUMBER(TRIM(e.grade_level)) BETWEEN 1 AND 12
                THEN LPAD(TRIM(e.grade_level), 2, '0')
            ELSE NULL
        END AS grade_level,
        CASE
            WHEN REGEXP_LIKE(TRIM(e.entry_date), '^[0-9]{4}-[0-9]{2}-[0-9]{2}$') THEN TO_DATE(TRIM(e.entry_date), 'FXYYYY-MM-DD')
            WHEN REGEXP_LIKE(TRIM(e.entry_date), '^[0-9]{2}/[0-9]{2}/[0-9]{4}$') THEN TO_DATE(TRIM(e.entry_date), 'FXMM/DD/YYYY')
            WHEN REGEXP_LIKE(TRIM(e.entry_date), '^[0-9]{8}$') THEN TO_DATE(TRIM(e.entry_date), 'FXYYYYMMDD')
            ELSE NULL
        END AS entry_date,
        CASE
            WHEN REGEXP_LIKE(TRIM(e.exit_date), '^[0-9]{4}-[0-9]{2}-[0-9]{2}$') THEN TO_DATE(TRIM(e.exit_date), 'FXYYYY-MM-DD')
            WHEN REGEXP_LIKE(TRIM(e.exit_date), '^[0-9]{2}/[0-9]{2}/[0-9]{4}$') THEN TO_DATE(TRIM(e.exit_date), 'FXMM/DD/YYYY')
            WHEN REGEXP_LIKE(TRIM(e.exit_date), '^[0-9]{8}$') THEN TO_DATE(TRIM(e.exit_date), 'FXYYYYMMDD')
            ELSE NULL
        END AS exit_date
    FROM {{ source('legacy', 'stg_enrollment') }} e
), valid AS (
    SELECT DISTINCT r.*
    FROM raw r
    INNER JOIN {{ ref('dom_student') }} st ON st.student_id = r.student_id
    INNER JOIN {{ ref('dom_school') }} sc ON sc.school_code = r.school_code
    WHERE r.grade_level IS NOT NULL
      AND r.school_year IS NOT NULL
      AND r.entry_date IS NOT NULL
      AND NVL(r.exit_date, DATE '9999-12-31') >= r.entry_date
)
SELECT student_id, school_code, school_year, grade_level, entry_date, exit_date,
       SYSDATE AS updated_dt
FROM valid

/* ====================== MODEL: dom_attendance_daily ========================
   Save this section as models/dom_attendance_daily.sql.
*/
{{ config(materialized='incremental', incremental_strategy='merge',
          unique_key=['student_id', 'attendance_date']) }}

WITH raw AS (
    SELECT
        UPPER(TRIM(a.student_id)) AS student_id,
        UPPER(TRIM(a.school_code)) AS school_code,
        TRIM(a.attendance_date) AS attendance_date_text,
        UPPER(TRIM(a.attendance_code)) AS attendance_code,
        a.load_dt,
        CASE
            WHEN REGEXP_LIKE(TRIM(a.attendance_date), '^[0-9]{4}-[0-9]{2}-[0-9]{2}$') THEN TO_DATE(TRIM(a.attendance_date), 'FXYYYY-MM-DD')
            WHEN REGEXP_LIKE(TRIM(a.attendance_date), '^[0-9]{2}/[0-9]{2}/[0-9]{4}$') THEN TO_DATE(TRIM(a.attendance_date), 'FXMM/DD/YYYY')
            WHEN REGEXP_LIKE(TRIM(a.attendance_date), '^[0-9]{8}$') THEN TO_DATE(TRIM(a.attendance_date), 'FXYYYYMMDD')
            ELSE NULL
        END AS attendance_date
    FROM {{ source('legacy', 'stg_attendance') }} a
), mapped AS (
    SELECT r.student_id, r.school_code, r.attendance_date, r.load_dt,
           COALESCE(cm.output_code, 'UNKNOWN') AS attendance_status,
           ROW_NUMBER() OVER (
               PARTITION BY r.student_id, r.attendance_date ORDER BY r.load_dt DESC
           ) AS rn
    FROM raw r
    INNER JOIN {{ ref('dom_student') }} st ON st.student_id = r.student_id
    INNER JOIN {{ ref('dom_school') }} sc ON sc.school_code = r.school_code
    LEFT JOIN {{ ref('code_map') }} cm
      ON cm.domain_name = 'ATTEND' AND cm.input_code = r.attendance_code
    WHERE r.attendance_date IS NOT NULL
), latest AS (
    SELECT * FROM mapped WHERE rn = 1 AND attendance_status <> 'UNKNOWN'
)
SELECT student_id, school_code, attendance_date, attendance_status,
       CASE WHEN attendance_status = 'ABSENT' THEN 'Y' ELSE 'N' END AS is_absent,
       SYSDATE AS updated_dt
FROM latest

/* ============================== MODEL: etl_reject ==========================
   Save this section as models/etl_reject.sql. This consolidates validation
   rejects from the source pipeline; it deliberately does not create run IDs.
*/
{{ config(materialized='table') }}

WITH school_rejects AS (
    SELECT 'STG_SCHOOL' AS source_table, school_code AS record_key,
           'Missing school code or name' AS reject_reason
    FROM {{ source('legacy', 'stg_school') }}
    WHERE TRIM(school_code) IS NULL OR TRIM(school_name) IS NULL
), student_rejects AS (
    SELECT 'STG_STUDENT' AS source_table, student_id AS record_key,
           CASE
             WHEN TRIM(student_id) IS NULL THEN 'Missing student id'
             WHEN TRIM(first_name) IS NULL OR TRIM(last_name) IS NULL THEN 'Missing name'
             ELSE 'Invalid or future birth date'
           END AS reject_reason
    FROM {{ source('legacy', 'stg_student') }}
    WHERE TRIM(student_id) IS NULL
       OR TRIM(first_name) IS NULL OR TRIM(last_name) IS NULL
       OR CASE
            WHEN REGEXP_LIKE(TRIM(birth_date), '^[0-9]{4}-[0-9]{2}-[0-9]{2}$') THEN TO_DATE(TRIM(birth_date), 'FXYYYY-MM-DD')
            WHEN REGEXP_LIKE(TRIM(birth_date), '^[0-9]{2}/[0-9]{2}/[0-9]{4}$') THEN TO_DATE(TRIM(birth_date), 'FXMM/DD/YYYY')
            WHEN REGEXP_LIKE(TRIM(birth_date), '^[0-9]{8}$') THEN TO_DATE(TRIM(birth_date), 'FXYYYYMMDD')
            ELSE NULL
          END IS NULL
       OR CASE
            WHEN REGEXP_LIKE(TRIM(birth_date), '^[0-9]{4}-[0-9]{2}-[0-9]{2}$') THEN TO_DATE(TRIM(birth_date), 'FXYYYY-MM-DD')
            WHEN REGEXP_LIKE(TRIM(birth_date), '^[0-9]{2}/[0-9]{2}/[0-9]{4}$') THEN TO_DATE(TRIM(birth_date), 'FXMM/DD/YYYY')
            WHEN REGEXP_LIKE(TRIM(birth_date), '^[0-9]{8}$') THEN TO_DATE(TRIM(birth_date), 'FXYYYYMMDD')
            ELSE NULL
          END > SYSDATE
), attendance_rejects AS (
    SELECT 'STG_ATTENDANCE' AS source_table,
           a.student_id || '|' || a.attendance_date AS record_key,
           CASE
             WHEN st.student_id IS NULL THEN 'Unknown student'
             WHEN CASE
                    WHEN REGEXP_LIKE(TRIM(a.attendance_date), '^[0-9]{4}-[0-9]{2}-[0-9]{2}$') THEN TO_DATE(TRIM(a.attendance_date), 'FXYYYY-MM-DD')
                    WHEN REGEXP_LIKE(TRIM(a.attendance_date), '^[0-9]{2}/[0-9]{2}/[0-9]{4}$') THEN TO_DATE(TRIM(a.attendance_date), 'FXMM/DD/YYYY')
                    WHEN REGEXP_LIKE(TRIM(a.attendance_date), '^[0-9]{8}$') THEN TO_DATE(TRIM(a.attendance_date), 'FXYYYYMMDD')
                    ELSE NULL
                  END IS NULL THEN 'Invalid date'
             ELSE 'Unmapped attendance code'
           END AS reject_reason
    FROM {{ source('legacy', 'stg_attendance') }} a
    LEFT JOIN {{ ref('dom_student') }} st ON st.student_id = UPPER(TRIM(a.student_id))
    LEFT JOIN {{ ref('code_map') }} cm
      ON cm.domain_name = 'ATTEND' AND cm.input_code = UPPER(TRIM(a.attendance_code))
    WHERE st.student_id IS NULL
       OR CASE
            WHEN REGEXP_LIKE(TRIM(a.attendance_date), '^[0-9]{4}-[0-9]{2}-[0-9]{2}$') THEN TO_DATE(TRIM(a.attendance_date), 'FXYYYY-MM-DD')
            WHEN REGEXP_LIKE(TRIM(a.attendance_date), '^[0-9]{2}/[0-9]{2}/[0-9]{4}$') THEN TO_DATE(TRIM(a.attendance_date), 'FXMM/DD/YYYY')
            WHEN REGEXP_LIKE(TRIM(a.attendance_date), '^[0-9]{8}$') THEN TO_DATE(TRIM(a.attendance_date), 'FXYYYYMMDD')
            ELSE NULL
          END IS NULL
       OR cm.output_code IS NULL
), enrollment_rejects AS (
    SELECT 'STG_ENROLLMENT' AS source_table,
           e.student_id || '|' || e.school_code AS record_key,
           CASE
             WHEN st.student_id IS NULL THEN 'Unknown student'
             WHEN sc.school_code IS NULL THEN 'Unknown school'
             WHEN e.grade_level IS NULL THEN 'Invalid grade'
             WHEN e.school_year IS NULL THEN 'Invalid school year'
             ELSE 'Invalid or reversed enrollment dates'
           END AS reject_reason
    FROM {{ source('legacy', 'stg_enrollment') }} e
    LEFT JOIN {{ ref('dom_student') }} st ON st.student_id = UPPER(TRIM(e.student_id))
    LEFT JOIN {{ ref('dom_school') }} sc ON sc.school_code = UPPER(TRIM(e.school_code))
    WHERE st.student_id IS NULL OR sc.school_code IS NULL
       OR NOT REGEXP_LIKE(UPPER(TRIM(e.grade_level)), '^(K|KG|KN|TK|PK|[0-9]{1,2})$')
       OR NOT (REGEXP_LIKE(TRIM(e.school_year), '^[0-9]{4}-[0-9]{2}$')
               OR REGEXP_LIKE(TRIM(e.school_year), '^[0-9]{4}$'))
)
SELECT source_table, record_key, reject_reason, SYSDATE AS reject_dt
FROM school_rejects
UNION ALL
SELECT source_table, record_key, reject_reason, SYSDATE FROM student_rejects
UNION ALL
SELECT source_table, record_key, reject_reason, SYSDATE FROM enrollment_rejects
UNION ALL
SELECT source_table, record_key, reject_reason, SYSDATE FROM attendance_rejects
