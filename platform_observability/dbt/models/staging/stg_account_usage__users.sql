{#
  User directory, used to resolve USER_ID (as reported by Cortex usage views)
  to a person. Includes dropped users so historical usage still resolves.
#}

select
    user_id,
    name                                                    as user_name,
    login_name,
    display_name,
    email,
    type                                                    as user_type,
    default_role,
    default_warehouse,
    disabled                                                as is_disabled,
    created_on,
    deleted_on,
    deleted_on is not null                                  as is_deleted,
    last_success_login

from {{ source('account_usage', 'users') }}
