{#
  One row per DDL event (object created, altered, dropped, replaced or
  restored), taken from ACCESS_HISTORY.OBJECT_MODIFIED_BY_DDL.

  Object names are kept fully qualified here. Splitting them into
  database / schema / object parts happens in Step 4, once Step 1 query Q7
  confirms the JSON shape for every object domain in this account.
#}

with ddl as (

    select
        query_id,
        query_start_time,
        user_name,
        object_modified_by_ddl                              as ddl
    from {{ source('account_usage', 'access_history') }}
    where object_modified_by_ddl is not null

)

select
    query_id,
    query_start_time::date                                  as event_date,
    query_start_time                                        as event_time,
    user_name,

    ddl:"objectDomain"::string                              as object_domain,
    ddl:"objectId"::number                                  as object_id,
    ddl:"objectName"::string                                as object_name,
    ddl:"operationType"::string                             as operation_type,

    case ddl:"operationType"::string
        when 'CREATE'  then 'CREATED'
        when 'REPLACE' then 'REPLACED'
        when 'ALTER'   then 'ALTERED'
        when 'DROP'    then 'DROPPED'
        when 'UNDROP'  then 'RESTORED'
        else 'OTHER'
    end                                                     as change_type,

    ddl:"properties"                                        as ddl_properties

from ddl
