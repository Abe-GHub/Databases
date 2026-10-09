{#
  Maps Snowflake QUERY_HISTORY.QUERY_TYPE to a small set of activity
  categories. Order matters: the first matching rule wins.

  To be finalized against Step 1, query Q5 (query type distribution).
  Any QUERY_TYPE not matched lands in OTHER, which the staging tests
  surface so nothing is silently miscategorized.
#}
{% macro categorize_query_type(query_type_column) -%}
    case
        when {{ query_type_column }} in ('USE', 'ALTER_SESSION', 'BEGIN_TRANSACTION', 'COMMIT', 'ROLLBACK')
            then 'SESSION_CONTROL'
        when {{ query_type_column }} in ('GRANT', 'REVOKE')
            or {{ query_type_column }} like 'GRANT%'
            or {{ query_type_column }} like 'REVOKE%'
            then 'DCL'
        when {{ query_type_column }} like 'CREATE%'
            or {{ query_type_column }} like 'UNDROP%'
            then 'DDL_CREATE'
        when {{ query_type_column }} like 'ALTER%'
            or {{ query_type_column }} like 'RENAME%'
            or {{ query_type_column }} in ('COMMENT')
            then 'DDL_ALTER'
        when {{ query_type_column }} like 'DROP%'
            then 'DDL_DROP'
        when {{ query_type_column }} in ('INSERT', 'MULTI_TABLE_INSERT', 'UPDATE', 'DELETE', 'MERGE', 'TRUNCATE_TABLE')
            then 'DML'
        when {{ query_type_column }} in ('COPY', 'UNLOAD', 'PUT_FILES', 'GET_FILES', 'LIST_FILES', 'REMOVE_FILES')
            then 'DATA_LOAD_UNLOAD'
        when {{ query_type_column }} = 'SELECT'
            then 'QUERY'
        when {{ query_type_column }} = 'CALL'
            then 'PROCEDURE_CALL'
        when {{ query_type_column }} like 'EXECUTE%'
            then 'EXECUTION'
        when {{ query_type_column }} in ('SHOW', 'DESCRIBE', 'EXPLAIN')
            then 'METADATA'
        else 'OTHER'
    end
{%- endmacro %}
