{#
  Cortex AI Function usage. Snowflake aggregates each query into one-hour
  windows, so a long-running query can appear in several rows (one per
  window); IS_COMPLETED marks the final one.

  The person is resolved from USER_ID in the history layer (Step 6) by
  joining stg_account_usage__users.
#}

select
    query_id,
    start_time::date                                        as usage_date,
    start_time                                              as window_start_time,
    end_time                                                as window_end_time,

    'AI_FUNCTIONS'                                          as cortex_service,
    function_name,
    nullif(model_name, '')                                  as model_name,

    user_id,
    role_names[0]::string                                   as primary_role_name,
    role_names,
    warehouse_id,
    query_tag,

    credits,
    metrics                                                 as usage_metrics,
    is_completed

from {{ source('account_usage', 'cortex_ai_functions_usage_history') }}
