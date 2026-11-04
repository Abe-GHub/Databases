/* =====================================================================
   K-12 District: Stage -> Domain (Oracle PL/SQL)
   Pattern adapted from CEDS Generate (CEDStandards on GitHub):
     source extract -> STG tables -> cleanse + code mapping -> DOM tables
   Kept intentionally simple: one package, one procedure per domain asset,
   MERGE for upserts, a reject table for bad rows, a run log.
   ===================================================================== */

-- ---------------------------------------------------------------------
-- 1. STAGE tables (raw, all VARCHAR2, loaded as-is from source extracts)
-- ---------------------------------------------------------------------
CREATE TABLE stg_school (
  school_code      VARCHAR2(50),
  school_name      VARCHAR2(200),
  school_type      VARCHAR2(50),     -- source code, e.g. 'ES','MS','HS','1'
  region           VARCHAR2(50),
  low_grade        VARCHAR2(10),
  high_grade       VARCHAR2(10),
  load_dt          DATE DEFAULT SYSDATE
);

CREATE TABLE stg_student (
  student_id       VARCHAR2(50),     -- district / SSID
  first_name       VARCHAR2(100),
  last_name        VARCHAR2(100),
  birth_date       VARCHAR2(30),     -- arrives as text
  gender           VARCHAR2(20),
  home_language    VARCHAR2(50),
  el_status        VARCHAR2(20),     -- English Learner flag
  frl_status       VARCHAR2(20),     -- free/reduced lunch
  load_dt          DATE DEFAULT SYSDATE
);

CREATE TABLE stg_enrollment (
  student_id       VARCHAR2(50),
  school_code      VARCHAR2(50),
  school_year      VARCHAR2(10),     -- '2025-26' or '2026'
  grade_level      VARCHAR2(10),     -- 'K','TK','01','1','12'
  entry_date       VARCHAR2(30),
  exit_date        VARCHAR2(30),
  load_dt          DATE DEFAULT SYSDATE
);

CREATE TABLE stg_attendance (
  student_id       VARCHAR2(50),
  school_code      VARCHAR2(50),
  attendance_date  VARCHAR2(30),
  attendance_code  VARCHAR2(20),     -- 'P','A','T','EX', etc.
  load_dt          DATE DEFAULT SYSDATE
);

-- Code mapping (same idea as CEDS Staging.SourceSystemReferenceData)
CREATE TABLE ref_code_map (
  domain_name      VARCHAR2(50),     -- 'SCHOOL_TYPE','GENDER','ATTEND','GRADE'
  input_code       VARCHAR2(50),
  output_code      VARCHAR2(50),
  CONSTRAINT pk_ref_code_map PRIMARY KEY (domain_name, input_code)
);

-- ---------------------------------------------------------------------
-- 2. DOMAIN tables (typed, conformed, keyed)
-- ---------------------------------------------------------------------
CREATE TABLE dom_school (
  school_code      VARCHAR2(20) PRIMARY KEY,
  school_name      VARCHAR2(200) NOT NULL,
  school_type      VARCHAR2(30),
  region           VARCHAR2(50),
  low_grade        VARCHAR2(5),
  high_grade       VARCHAR2(5),
  updated_dt       DATE
);

CREATE TABLE dom_student (
  student_id       VARCHAR2(20) PRIMARY KEY,
  first_name       VARCHAR2(100) NOT NULL,
  last_name        VARCHAR2(100) NOT NULL,
  birth_date       DATE,
  gender           VARCHAR2(20),
  home_language    VARCHAR2(50),
  is_english_learner CHAR(1),
  is_frl_eligible  CHAR(1),
  updated_dt       DATE
);

CREATE TABLE dom_enrollment (
  student_id       VARCHAR2(20) REFERENCES dom_student,
  school_code      VARCHAR2(20) REFERENCES dom_school,
  school_year      NUMBER(4),        -- ending year: 2025-26 -> 2026
  grade_level      VARCHAR2(5),
  entry_date       DATE,
  exit_date        DATE,
  updated_dt       DATE,
  CONSTRAINT pk_dom_enrollment PRIMARY KEY (student_id, school_code, school_year, entry_date)
);

CREATE TABLE dom_attendance_daily (
  student_id       VARCHAR2(20) REFERENCES dom_student,
  school_code      VARCHAR2(20) REFERENCES dom_school,
  attendance_date  DATE,
  attendance_status VARCHAR2(20),    -- PRESENT / ABSENT / TARDY / EXCUSED
  is_absent        CHAR(1),
  updated_dt       DATE,
  CONSTRAINT pk_dom_attendance PRIMARY KEY (student_id, attendance_date)
);

-- Rejects and run log
CREATE TABLE etl_reject (
  run_id           NUMBER,
  source_table     VARCHAR2(50),
  record_key       VARCHAR2(200),
  reject_reason    VARCHAR2(400),
  reject_dt        DATE DEFAULT SYSDATE
);

CREATE TABLE etl_run_log (
  run_id           NUMBER,
  step_name        VARCHAR2(50),
  rows_processed   NUMBER,
  status           VARCHAR2(20),
  message          VARCHAR2(4000),
  log_dt           DATE DEFAULT SYSDATE
);

CREATE SEQUENCE etl_run_seq;

-- ---------------------------------------------------------------------
-- 3. Helper functions (cleansing rules in one place)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_safe_date (p_txt VARCHAR2) RETURN DATE IS
BEGIN
  IF p_txt IS NULL THEN RETURN NULL; END IF;
  -- try the common formats seen in district extracts
  BEGIN RETURN TO_DATE(TRIM(p_txt), 'YYYY-MM-DD');  EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN RETURN TO_DATE(TRIM(p_txt), 'MM/DD/YYYY');  EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN RETURN TO_DATE(TRIM(p_txt), 'YYYYMMDD');    EXCEPTION WHEN OTHERS THEN NULL; END;
  RETURN NULL;
END;
/

CREATE OR REPLACE FUNCTION fn_map_code (p_domain VARCHAR2, p_input VARCHAR2)
RETURN VARCHAR2 IS
  v_out ref_code_map.output_code%TYPE;
BEGIN
  SELECT output_code INTO v_out
  FROM   ref_code_map
  WHERE  domain_name = p_domain
  AND    input_code  = UPPER(TRIM(p_input));
  RETURN v_out;
EXCEPTION
  WHEN NO_DATA_FOUND THEN RETURN 'UNKNOWN';
END;
/

-- Grade normalization: '1' -> '01', 'k' -> 'KG', 'tk' -> 'TK'
CREATE OR REPLACE FUNCTION fn_grade (p_txt VARCHAR2) RETURN VARCHAR2 IS
  v VARCHAR2(10) := UPPER(TRIM(p_txt));
BEGIN
  IF v IN ('K','KG','KN')   THEN RETURN 'KG'; END IF;
  IF v IN ('TK','PK')       THEN RETURN v;    END IF;
  IF REGEXP_LIKE(v, '^[0-9]{1,2}$') AND TO_NUMBER(v) BETWEEN 1 AND 12
     THEN RETURN LPAD(v, 2, '0'); END IF;
  RETURN NULL;   -- invalid
END;
/

-- School year: '2025-26' -> 2026, '2026' -> 2026
CREATE OR REPLACE FUNCTION fn_school_year (p_txt VARCHAR2) RETURN NUMBER IS
  v VARCHAR2(10) := TRIM(p_txt);
BEGIN
  IF REGEXP_LIKE(v, '^[0-9]{4}-[0-9]{2}$') THEN
    RETURN TO_NUMBER(SUBSTR(v,1,2) || SUBSTR(v,6,2));
  ELSIF REGEXP_LIKE(v, '^[0-9]{4}$') THEN
    RETURN TO_NUMBER(v);
  END IF;
  RETURN NULL;
END;
/

-- ---------------------------------------------------------------------
-- 4. The pipeline package
-- ---------------------------------------------------------------------
CREATE OR REPLACE PACKAGE pkg_k12_domain AS
  PROCEDURE run_all;
END;
/

CREATE OR REPLACE PACKAGE BODY pkg_k12_domain AS

  g_run_id NUMBER;

  PROCEDURE log_step (p_step VARCHAR2, p_rows NUMBER, p_status VARCHAR2, p_msg VARCHAR2 DEFAULT NULL) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    INSERT INTO etl_run_log (run_id, step_name, rows_processed, status, message)
    VALUES (g_run_id, p_step, p_rows, p_status, p_msg);
    COMMIT;
  END;

  -- ---------- SCHOOL ----------
  PROCEDURE load_school IS
  BEGIN
    INSERT INTO etl_reject (run_id, source_table, record_key, reject_reason)
    SELECT g_run_id, 'STG_SCHOOL', school_code, 'Missing school code or name'
    FROM   stg_school
    WHERE  TRIM(school_code) IS NULL OR TRIM(school_name) IS NULL;

    MERGE INTO dom_school t
    USING (
      SELECT UPPER(TRIM(school_code))                 AS school_code,
             INITCAP(TRIM(school_name))               AS school_name,
             fn_map_code('SCHOOL_TYPE', school_type)  AS school_type,
             UPPER(TRIM(region))                      AS region,
             fn_grade(low_grade)                      AS low_grade,
             fn_grade(high_grade)                     AS high_grade
      FROM (
        SELECT s.*, ROW_NUMBER() OVER (PARTITION BY UPPER(TRIM(school_code))
                                       ORDER BY load_dt DESC) rn
        FROM   stg_school s
        WHERE  TRIM(school_code) IS NOT NULL AND TRIM(school_name) IS NOT NULL
      ) WHERE rn = 1                                  -- dedupe: latest wins
    ) s
    ON (t.school_code = s.school_code)
    WHEN MATCHED THEN UPDATE SET
         t.school_name = s.school_name, t.school_type = s.school_type,
         t.region = s.region, t.low_grade = s.low_grade,
         t.high_grade = s.high_grade, t.updated_dt = SYSDATE
    WHEN NOT MATCHED THEN INSERT
         (school_code, school_name, school_type, region, low_grade, high_grade, updated_dt)
    VALUES (s.school_code, s.school_name, s.school_type, s.region, s.low_grade, s.high_grade, SYSDATE);

    log_step('LOAD_SCHOOL', SQL%ROWCOUNT, 'OK');
  END;

  -- ---------- STUDENT ----------
  PROCEDURE load_student IS
  BEGIN
    INSERT INTO etl_reject (run_id, source_table, record_key, reject_reason)
    SELECT g_run_id, 'STG_STUDENT', student_id,
           CASE WHEN TRIM(student_id) IS NULL THEN 'Missing student id'
                WHEN TRIM(first_name) IS NULL OR TRIM(last_name) IS NULL THEN 'Missing name'
                ELSE 'Invalid or future birth date' END
    FROM   stg_student
    WHERE  TRIM(student_id) IS NULL
       OR  TRIM(first_name) IS NULL OR TRIM(last_name) IS NULL
       OR  fn_safe_date(birth_date) IS NULL
       OR  fn_safe_date(birth_date) > SYSDATE;

    MERGE INTO dom_student t
    USING (
      SELECT UPPER(TRIM(student_id))                    AS student_id,
             INITCAP(TRIM(first_name))                  AS first_name,
             INITCAP(TRIM(last_name))                   AS last_name,
             fn_safe_date(birth_date)                   AS birth_date,
             fn_map_code('GENDER', gender)              AS gender,
             NVL(INITCAP(TRIM(home_language)), 'Unknown') AS home_language,
             CASE WHEN UPPER(TRIM(el_status))  IN ('Y','YES','1','EL')  THEN 'Y' ELSE 'N' END AS is_el,
             CASE WHEN UPPER(TRIM(frl_status)) IN ('Y','YES','1','F','R') THEN 'Y' ELSE 'N' END AS is_frl
      FROM (
        SELECT s.*, ROW_NUMBER() OVER (PARTITION BY UPPER(TRIM(student_id))
                                       ORDER BY load_dt DESC) rn
        FROM   stg_student s
        WHERE  TRIM(student_id) IS NOT NULL
          AND  TRIM(first_name) IS NOT NULL AND TRIM(last_name) IS NOT NULL
          AND  fn_safe_date(birth_date) <= SYSDATE
      ) WHERE rn = 1
    ) s
    ON (t.student_id = s.student_id)
    WHEN MATCHED THEN UPDATE SET
         t.first_name = s.first_name, t.last_name = s.last_name,
         t.birth_date = s.birth_date, t.gender = s.gender,
         t.home_language = s.home_language,
         t.is_english_learner = s.is_el, t.is_frl_eligible = s.is_frl,
         t.updated_dt = SYSDATE
    WHEN NOT MATCHED THEN INSERT
         (student_id, first_name, last_name, birth_date, gender, home_language,
          is_english_learner, is_frl_eligible, updated_dt)
    VALUES (s.student_id, s.first_name, s.last_name, s.birth_date, s.gender,
            s.home_language, s.is_el, s.is_frl, SYSDATE);

    log_step('LOAD_STUDENT', SQL%ROWCOUNT, 'OK');
  END;

  -- ---------- ENROLLMENT ----------
  PROCEDURE load_enrollment IS
  BEGIN
    -- reject orphans and bad values (referential + domain checks)
    INSERT INTO etl_reject (run_id, source_table, record_key, reject_reason)
    SELECT g_run_id, 'STG_ENROLLMENT', e.student_id || '|' || e.school_code,
           CASE WHEN st.student_id IS NULL THEN 'Unknown student'
                WHEN sc.school_code IS NULL THEN 'Unknown school'
                WHEN fn_grade(e.grade_level) IS NULL THEN 'Invalid grade'
                WHEN fn_school_year(e.school_year) IS NULL THEN 'Invalid school year'
                ELSE 'Exit date before entry date' END
    FROM   stg_enrollment e
    LEFT JOIN dom_student st ON st.student_id = UPPER(TRIM(e.student_id))
    LEFT JOIN dom_school  sc ON sc.school_code = UPPER(TRIM(e.school_code))
    WHERE  st.student_id IS NULL OR sc.school_code IS NULL
       OR  fn_grade(e.grade_level) IS NULL
       OR  fn_school_year(e.school_year) IS NULL
       OR  fn_safe_date(e.entry_date) IS NULL
       OR  fn_safe_date(e.exit_date) < fn_safe_date(e.entry_date);

    MERGE INTO dom_enrollment t
    USING (
      SELECT DISTINCT
             UPPER(TRIM(e.student_id))      AS student_id,
             UPPER(TRIM(e.school_code))     AS school_code,
             fn_school_year(e.school_year)  AS school_year,
             fn_grade(e.grade_level)        AS grade_level,
             fn_safe_date(e.entry_date)     AS entry_date,
             fn_safe_date(e.exit_date)      AS exit_date
      FROM   stg_enrollment e
      JOIN   dom_student st ON st.student_id  = UPPER(TRIM(e.student_id))
      JOIN   dom_school  sc ON sc.school_code = UPPER(TRIM(e.school_code))
      WHERE  fn_grade(e.grade_level) IS NOT NULL
        AND  fn_school_year(e.school_year) IS NOT NULL
        AND  fn_safe_date(e.entry_date) IS NOT NULL
        AND  NVL(fn_safe_date(e.exit_date), DATE '9999-12-31') >= fn_safe_date(e.entry_date)
    ) s
    ON (t.student_id = s.student_id AND t.school_code = s.school_code
        AND t.school_year = s.school_year AND t.entry_date = s.entry_date)
    WHEN MATCHED THEN UPDATE SET
         t.grade_level = s.grade_level, t.exit_date = s.exit_date, t.updated_dt = SYSDATE
    WHEN NOT MATCHED THEN INSERT
         (student_id, school_code, school_year, grade_level, entry_date, exit_date, updated_dt)
    VALUES (s.student_id, s.school_code, s.school_year, s.grade_level,
            s.entry_date, s.exit_date, SYSDATE);

    log_step('LOAD_ENROLLMENT', SQL%ROWCOUNT, 'OK');
  END;

  -- ---------- DAILY ATTENDANCE ----------
  PROCEDURE load_attendance IS
  BEGIN
    INSERT INTO etl_reject (run_id, source_table, record_key, reject_reason)
    SELECT g_run_id, 'STG_ATTENDANCE', a.student_id || '|' || a.attendance_date,
           CASE WHEN st.student_id IS NULL THEN 'Unknown student'
                WHEN fn_safe_date(a.attendance_date) IS NULL THEN 'Invalid date'
                ELSE 'Unmapped attendance code' END
    FROM   stg_attendance a
    LEFT JOIN dom_student st ON st.student_id = UPPER(TRIM(a.student_id))
    WHERE  st.student_id IS NULL
       OR  fn_safe_date(a.attendance_date) IS NULL
       OR  fn_map_code('ATTEND', a.attendance_code) = 'UNKNOWN';

    MERGE INTO dom_attendance_daily t
    USING (
      SELECT student_id, school_code, attendance_date, attendance_status,
             CASE WHEN attendance_status = 'ABSENT' THEN 'Y' ELSE 'N' END AS is_absent
      FROM (
        SELECT UPPER(TRIM(a.student_id))                 AS student_id,
               UPPER(TRIM(a.school_code))                AS school_code,
               fn_safe_date(a.attendance_date)           AS attendance_date,
               fn_map_code('ATTEND', a.attendance_code)  AS attendance_status,
               ROW_NUMBER() OVER (PARTITION BY UPPER(TRIM(a.student_id)),
                                               fn_safe_date(a.attendance_date)
                                  ORDER BY a.load_dt DESC) rn
        FROM   stg_attendance a
        JOIN   dom_student st ON st.student_id  = UPPER(TRIM(a.student_id))
        JOIN   dom_school  sc ON sc.school_code = UPPER(TRIM(a.school_code))
        WHERE  fn_safe_date(a.attendance_date) IS NOT NULL
          AND  fn_map_code('ATTEND', a.attendance_code) <> 'UNKNOWN'
      ) WHERE rn = 1
    ) s
    ON (t.student_id = s.student_id AND t.attendance_date = s.attendance_date)
    WHEN MATCHED THEN UPDATE SET
         t.school_code = s.school_code, t.attendance_status = s.attendance_status,
         t.is_absent = s.is_absent, t.updated_dt = SYSDATE
    WHEN NOT MATCHED THEN INSERT
         (student_id, school_code, attendance_date, attendance_status, is_absent, updated_dt)
    VALUES (s.student_id, s.school_code, s.attendance_date, s.attendance_status,
            s.is_absent, SYSDATE);

    log_step('LOAD_ATTENDANCE', SQL%ROWCOUNT, 'OK');
  END;

  -- ---------- ORCHESTRATOR ----------
  PROCEDURE run_all IS
  BEGIN
    g_run_id := etl_run_seq.NEXTVAL;
    load_school;        -- reference first
    load_student;
    load_enrollment;    -- depends on student + school
    load_attendance;
    COMMIT;
    log_step('RUN_ALL', NULL, 'SUCCESS');
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      log_step('RUN_ALL', NULL, 'FAILED', SQLERRM);
      RAISE;
  END;

END pkg_k12_domain;
/

-- ---------------------------------------------------------------------
-- 5. Seed code mappings + run
-- ---------------------------------------------------------------------
INSERT INTO ref_code_map VALUES ('SCHOOL_TYPE','ES','Elementary');
INSERT INTO ref_code_map VALUES ('SCHOOL_TYPE','MS','Middle');
INSERT INTO ref_code_map VALUES ('SCHOOL_TYPE','HS','High');
INSERT INTO ref_code_map VALUES ('SCHOOL_TYPE','SP','Special Education');
INSERT INTO ref_code_map VALUES ('GENDER','M','Male');
INSERT INTO ref_code_map VALUES ('GENDER','F','Female');
INSERT INTO ref_code_map VALUES ('GENDER','X','Nonbinary');
INSERT INTO ref_code_map VALUES ('ATTEND','P','PRESENT');
INSERT INTO ref_code_map VALUES ('ATTEND','A','ABSENT');
INSERT INTO ref_code_map VALUES ('ATTEND','U','ABSENT');
INSERT INTO ref_code_map VALUES ('ATTEND','T','TARDY');
INSERT INTO ref_code_map VALUES ('ATTEND','EX','EXCUSED');
COMMIT;

-- EXEC pkg_k12_domain.run_all;
-- SELECT * FROM etl_run_log ORDER BY log_dt DESC;
-- SELECT reject_reason, COUNT(*) FROM etl_reject GROUP BY reject_reason;
