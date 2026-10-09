{#
  Schema naming
  -------------
  Production (target name 'prod'): models build into the exact schemas
  created in Step 2: STAGING, HISTORY, MARTS.

  Any other target (dbt Cloud IDE, CI): models build into the developer's
  own schemas, e.g. DBT_ABE_STAGING, DBT_ABE_HISTORY, so development never
  touches production history.

  In dbt Cloud, set "Target name" = prod on the Production environment's
  jobs. Development environments keep the default target name.
#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- set default_schema = target.schema -%}
    {%- if custom_schema_name is none -%}
        {{ default_schema }}
    {%- elif target.name == 'prod' -%}
        {{ custom_schema_name | trim | upper }}
    {%- else -%}
        {{ default_schema }}_{{ custom_schema_name | trim | upper }}
    {%- endif -%}
{%- endmacro %}
