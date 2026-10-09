{#
  One row per query, with the activity category derived from QUERY_TYPE.
  Full SQL text is retained by design (project decision).
#}

select
    query_id,
    start_time::date                                        as activity_date,
    start_time,
    end_time,

    -- who and where
    user_name,
    role_name,
    warehouse_name,
    warehouse_size,
    database_name,
    schema_name,
    session_id,
    query_tag,

    -- what
    query_type,
    {{ categorize_query_type('query_type') }}               as activity_category,
    query_text,

    -- outcome
    execution_status,
    error_code,
    error_message,

    -- performance and volume
    total_elapsed_time                                      as total_elapsed_ms,
    execution_time                                          as execution_ms,
    queued_overload_time                                    as queued_overload_ms,
    bytes_scanned,
    rows_produced,
    rows_inserted,
    rows_updated,
    rows_deleted,
    credits_used_cloud_services

from {{ source('account_usage', 'query_history') }}
