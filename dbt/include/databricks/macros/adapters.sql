{% macro databricks__file_format_clause() %}
  {%- set file_format = config.get('file_format', default='delta') -%}
  {%- if file_format is not none %}
    using {{ file_format }}
  {%- endif %}
{%- endmacro -%}

{% macro databricks__options_clause() -%}
  {%- set options = config.get('options') -%}
  {%- if config.get('file_format', default='delta') == 'hudi' -%}
    {%- set unique_key = config.get('unique_key') -%}
    {%- if unique_key is not none and options is none -%}
      {%- set options = {'primaryKey': config.get('unique_key')} -%}
    {%- elif unique_key is not none and options is not none and 'primaryKey' not in options -%}
      {%- set _ = options.update({'primaryKey': config.get('unique_key')}) -%}
    {%- elif options is not none and 'primaryKey' in options and options['primaryKey'] != unique_key -%}
      {{ exceptions.raise_compiler_error("unique_key and options('primaryKey') should be the same column(s).") }}
    {%- endif %}
  {%- endif %}

  {%- if options is not none %}
    options (
      {%- for option in options -%}
      {{ option }} "{{ options[option] }}" {% if not loop.last %}, {% endif %}
      {%- endfor %}
    )
  {%- endif %}
{%- endmacro -%}


{% macro tblproperties_clause() -%}
  {{ return(adapter.dispatch('tblproperties_clause', 'dbt')()) }}
{%- endmacro -%}

{% macro databricks__tblproperties_clause() -%}
  {%- set tblproperties = config.get('tblproperties') -%}
  {%- if tblproperties is not none %}
    tblproperties (
      {%- for prop in tblproperties -%}
      '{{ prop }}' = '{{ tblproperties[prop] }}' {% if not loop.last %}, {% endif %}
      {%- endfor %}
    )
  {%- endif %}
{%- endmacro -%}

{% macro liquid_clustered_cols(label, required=false) -%}
  {{ return(adapter.dispatch('liquid_clustered_cols', 'dbt')(label, required)) }}
{%- endmacro -%}

{% macro databricks__liquid_clustered_cols(label, required=false) -%}
  {%- set cols = config.get('liquid_clustered_by', validator=validation.any[list, basestring]) -%}
  {%- if cols is not none %}
    {%- if cols is string -%}
      {%- set cols = [cols] -%}
    {%- endif -%}
    {{ label }} (
    {%- for item in cols -%}
      {{ item }}
      {%- if not loop.last -%},{%- endif -%}
    {%- endfor -%}
    )
  {%- endif %}
{%- endmacro -%}

{# Persist table-level and column-level constraints. #}
{% macro persist_constraints(relation, model) %}
  {{ return(adapter.dispatch('persist_constraints', 'dbt')(relation, model)) }}
{% endmacro %}

{% macro databricks__persist_constraints(relation, model) %}
  {%- set contract_config = config.get('contract') -%}
  {% set has_model_contract = contract_config and contract_config.enforced %}
  {% set has_databricks_constraints = config.get('persist_constraints', False) %}

  {% if (has_model_contract or has_databricks_constraints) %}
    {% if config.get('file_format', 'delta') != 'delta' %}
      {# Constraints are only supported for delta tables #}
      {{ exceptions.warn("Constraints not supported for file format: " ~ config.get('file_format')) }}
    {% elif relation.is_view %}
      {# Constraints are not supported for views. This point in the code should not have been reached. #}
      {{ exceptions.raise_compiler_error("Constraints not supported for views.") }}
    {% elif is_incremental() %}
      {# Constraints are not applied for incremental updates. This point in the code should not have been reached #}
      {{ exceptions.raise_compiler_error("Constraints are not applied for incremental updates. Full refresh is required to update constraints.") }}
    {% else %}
      {% do alter_table_add_constraints(relation, model) %}
      {% do alter_column_set_constraints(relation, model) %}
    {% endif %}
  {% endif %}
{% endmacro %}

{% macro alter_table_add_constraints(relation, constraints) %}
  {{ return(adapter.dispatch('alter_table_add_constraints', 'dbt')(relation, constraints)) }}
{% endmacro %}

{% macro databricks__alter_table_add_constraints(relation, model) %}
    {% set constraints = get_model_constraints(model) %}
    {% set statements = get_constraints_sql(relation, constraints, model) %}
    {% for stmt in statements %}
      {% call statement() %}
        {{ stmt }}
      {% endcall %}
    {% endfor %}
{% endmacro %}

{% macro get_model_constraints(model) %}
  {% set constraints = model.get('constraints', []) %}
  {% if config.get('persist_constraints', False) and model.get('meta', {}).get('constraints') is sequence %}
    {# Databricks constraints implementation.  Constraints are in the meta property. #}
    {% set db_constraints = model.get('meta', {}).get('constraints', []) %}
    {% set constraints = databricks_constraints_to_dbt(db_constraints) %}
  {% endif %}
  {{ return(constraints) }}
{% endmacro %}

{% macro get_column_constraints(column) %}
  {% set constraints = column.get('constraints', []) %}
  {% if config.get('persist_constraints', False) and column.get('meta', {}).get('constraint') %}
    {# Databricks constraints implementation.  Constraint is in the meta property. #}
    {% set db_constraints = [column.get('meta', {}).get('constraint')] %}
    {% set constraints = databricks_constraints_to_dbt(db_constraints, column) %}
  {% endif %}
  {{ return(constraints) }}
{% endmacro %}

{% macro alter_column_set_constraints(relation, column_dict) %}
  {{ return(adapter.dispatch('alter_column_set_constraints', 'dbt')(relation, column_dict)) }}
{% endmacro %}

{% macro databricks__alter_column_set_constraints(relation, model) %}
  {% set column_dict = model.columns %}
  {% for column_name in column_dict %}
    {% set column = column_dict[column_name] %}
    {% set constraints = get_column_constraints(column)  %}
    {% set statements = get_constraints_sql(relation, constraints, model, column) %}
    {% for stmt in statements %}
      {% call statement() %}
        {{ stmt }}
      {% endcall %}
    {% endfor %}
  {% endfor %}
{% endmacro %}

{% macro get_constraints_sql(relation, constraints, model, column) %}
  {% set statements = [] %}
  -- Hack so that not null constraints will be applied before primary key constraints
  {% for constraint in constraints|sort(attribute='type') %}
    {% if constraint %}
      {% set constraint_statements = get_constraint_sql(relation, constraint, model, column) %}
      {% for statement in constraint_statements %}
        {% if statement %}
          {% do statements.append(statement) %}
        {% endif %}
      {% endfor %}  
    {% endif %}
  {% endfor %}

  {{ return(statements) }}
{% endmacro %}

{% macro get_constraint_sql(relation, constraint, model, column={}) %}
  {% set statements = [] %}
  {% set type = constraint.get("type", "") %}

  {% if type == 'check' %}
    {% set expression = constraint.get("expression", "") %}
    {% if not expression %}
      {{ exceptions.raise_compiler_error('Invalid check constraint expression') }}
    {% endif %}

    {% set name = constraint.get("name") %}
    {% if not name and local_md5 %}
      {{ exceptions.warn("Constraint of type " ~ type ~ " with no `name` provided. Generating hash instead.") }}
      {%- set name = local_md5 (column.get("name", "") ~ ";" ~ expression ~ ";") -%}
    {% endif %}
    {% set stmt = "alter table " ~ relation ~ " add constraint " ~ name ~ " check (" ~ expression ~ ");" %}
    {% do statements.append(stmt) %}
  {% elif type == 'not_null' %}
    {% set column_names = constraint.get("columns", []) %}
    {% if column and not column_names %}
      {% set column_names = [column['name']] %}
    {% endif %}
    {% for column_name in column_names %}
      {% set column = model.get('columns', {}).get(column_name) %}
      {% if column %}
        {% set quoted_name = adapter.quote(column['name']) if column['quote'] else column['name'] %}
        {% set stmt = "alter table " ~ relation ~ " change column " ~ quoted_name ~ " set not null " ~ (constraint.expression or "") ~ ";" %}
        {% do statements.append(stmt) %}
      {% else %}
        {{ exceptions.warn('not_null constraint on invalid column: ' ~ column_name) }}
      {% endif %}
    {% endfor %}
  {% elif type == 'primary_key' %}
    {% if constraint.get('warn_unenforced') %}
      {{ exceptions.warn("unenforced constraint type: " ~ type)}}
    {% endif %}
    {% set column_names = constraint.get("columns", []) %}
    {% if column and not column_names %}
      {% set column_names = [column['name']] %}
    {% endif %}
    {% set quoted_names = [] %}
    {% for column_name in column_names %}
      {% set column = model.get('columns', {}).get(column_name) %}
      {% if not column %}
        {{ exceptions.warn('Invalid primary key column: ' ~ column_name) }}
      {% else %}
        {% set quoted_name = adapter.quote(column['name']) if column['quote'] else column['name'] %}
        {% do quoted_names.append(quoted_name) %}
      {% endif %}
    {% endfor %}

    {% set joined_names = quoted_names|join(", ") %}

    {% set name = constraint.get("name") %}
    {% if not name and local_md5 %}
      {{ exceptions.warn("Constraint of type " ~ type ~ " with no `name` provided. Generating hash instead.") }}
      {%- set name = local_md5("primary_key;" ~ column_names ~ ";") -%}
    {% endif %}
    {% set stmt = "alter table " ~ relation ~ " add constraint " ~ name ~ " primary key(" ~ joined_names ~ ");" %}
    {% do statements.append(stmt) %}
  {% elif type == 'foreign_key' %}

    {% if constraint.get('warn_unenforced') %}
      {{ exceptions.warn("unenforced constraint type: " ~ constraint.type)}}
    {% endif %}

    {% set name = constraint.get("name") %}
    {% if not name and local_md5 %}
      {{ exceptions.warn("Constraint of type " ~ type ~ " with no `name` provided. Generating hash instead.") }}
      {%- set name = local_md5("primary_key;" ~ column_names ~ ";") -%}
    {% endif %}

    {% if constraint.get('expression') %}
      {% set stmt = "alter table " ~ relation ~ " add constraint " ~ name ~ " foreign key" ~ constraint.get('expression') %}
    {% else %}
      {% set column_names = constraint.get("columns", []) %}
      {% if column and not column_names %}
        {% set column_names = [column['name']] %}
      {% endif %}
      {% set quoted_names = [] %}
      {% for column_name in column_names %}
        {% set column = model.get('columns', {}).get(column_name) %}
        {% if not column %}
          {{ exceptions.warn('Invalid foreign key column: ' ~ column_name) }}
        {% else %}
          {% set quoted_name = adapter.quote(column['name']) if column['quote'] else column['name'] %}
          {% do quoted_names.append(quoted_name) %}
        {% endif %}
      {% endfor %}

      {% set joined_names = quoted_names|join(", ") %}

      {% set parent = constraint.get("parent") %}
      {% if not parent %} 
        {{ exceptions.raise_compiler_error('No parent table defined for foreign key: ' ~ expression) }}
      {% endif %}
      {% if not "." in parent %}
        {% set parent = relation.schema ~ "." ~ parent%}
      {% endif %}
      {% set stmt = "alter table " ~ relation ~ " add constraint " ~ name ~ " foreign key(" ~ joined_names ~ ") references " ~ parent %}
      {% set parent_columns = constraint.get("parent_columns") %}
      {% if parent_columns %}
        {% set stmt = stmt ~ "(" ~ parent_columns|join(", ") ~ ")"%}
      {% endif %}
    {% endif %}
    {% set stmt = stmt ~ ";" %}
    {% do statements.append(stmt) %}
  {% elif constraint.get('warn_unsupported') %}
    {{ exceptions.warn("unsupported constraint type: " ~ constraint.type)}}
  {% endif %}

  {{ return(statements) }}
{% endmacro %}

{% macro databricks_constraints_to_dbt(constraints, column) %}
  {# convert constraints defined using the original databricks format #}
  {% set dbt_constraints = [] %}
  {% for constraint in constraints %}
    {% if constraint.get and constraint.get("type") %}
      {# already in model contract format #}
      {% do dbt_constraints.append(constraint) %}
    {% else %}
      {% if column %}
        {% if constraint == "not_null" %}
          {% do dbt_constraints.append({"type": "not_null", "columns": [column.get("name")]}) %}
        {% else %}
          {{ exceptions.raise_compiler_error('Invalid constraint for column ' ~ column.get("name", "") ~ '. Only `not_null` is supported.') }}
        {% endif %}
      {% else %}
        {% set name = constraint['name'] %}
        {% if not name %}
          {{ exceptions.raise_compiler_error('Invalid check constraint name') }}
        {% endif %}
        {% set condition = constraint['condition'] %}
        {% if not condition %}
          {{ exceptions.raise_compiler_error('Invalid check constraint condition') }}
        {% endif %}
        {% do dbt_constraints.append({"name": name, "type": "check", "expression": condition}) %}
      {% endif %}
    {% endif %}
  {% endfor %}

  {{ return(dbt_constraints) }}
{% endmacro %}

{% macro optimize(relation) %}
  {{ return(adapter.dispatch('optimize', 'dbt')(relation)) }}
{% endmacro %}

{%- macro databricks__optimize(relation) -%}
  {%- if var('DATABRICKS_SKIP_OPTIMIZE', 'false')|lower != 'true' and 
        var('databricks_skip_optimize', 'false')|lower != 'true' and 
        config.get('file_format', 'delta') == 'delta' -%}
    {%- if (config.get('zorder', False) or config.get('liquid_clustered_by', False)) -%}
      {%- call statement('run_optimize_stmt') -%}
        {{ get_optimize_sql(relation) }}
      {%- endcall -%}
    {%- endif -%}
  {%- endif -%}
{%- endmacro -%}

{%- macro get_optimize_sql(relation) %}
  optimize {{ relation }}
  {%- if config.get('zorder', False) and config.get('file_format', 'delta') == 'delta' %}
    {%- if config.get('liquid_clustered_by', False) %}
      {{ exceptions.warn("Both zorder and liquid_clustered_by are set but they are incompatible. zorder will be ignored.") }}
    {%- else %}
      {%- set zorder = config.get('zorder', none) %}
      {# TODO: predicates here? WHERE ...  #}
      {%- if zorder is sequence and zorder is not string %}
        zorder by (
        {%- for col in zorder %}
        {{ col }}{% if not loop.last %}, {% endif %}
        {%- endfor %}
        )
      {%- else %}
        zorder by ({{zorder}})
      {%- endif %}
    {%- endif %}
  {%- endif %}
{%- endmacro -%}

{% macro databricks__list_relations_without_caching(schema_relation) %}
  {{ return(adapter.get_relations_without_caching(schema_relation)) }}
{% endmacro %}

{% macro show_table_extended(schema_relation) %}
  {{ return(adapter.dispatch('show_table_extended', 'dbt')(schema_relation)) }}
{% endmacro %}

{% macro databricks__show_table_extended(schema_relation) %}
  {% call statement('show_table_extended', fetch_result=True) -%}
    show table extended in {{ schema_relation.without_identifier() }} like '{{ schema_relation.identifier }}'
  {% endcall %}

  {% do return(load_result('show_table_extended').table) %}
{% endmacro %}

{% macro show_tables(relation) %}
  {{ return(adapter.dispatch('show_tables', 'dbt')(relation)) }}
{% endmacro %}

{% macro databricks__show_tables(relation) %}
  {% call statement('show_tables', fetch_result=True) -%}
    show tables in {{ relation }}
  {% endcall %}

  {% do return(load_result('show_tables').table) %}
{% endmacro %}

{% macro show_views(relation) %}
  {{ return(adapter.dispatch('show_views', 'dbt')(relation)) }}
{% endmacro %}

{% macro databricks__show_views(relation) %}
  {% call statement('show_views', fetch_result=True) -%}
    show views in {{ relation }}
  {% endcall %}

  {% do return(load_result('show_views').table) %}
{% endmacro %}

{% macro databricks__generate_database_name(custom_database_name=none, node=none) -%}
    {%- set default_database = target.database -%}
    {%- if custom_database_name is none -%}
        {{ return(default_database) }}
    {%- else -%}
        {{ return(custom_database_name) }}
    {%- endif -%}
{%- endmacro %}

{% macro databricks__make_temp_relation(base_relation, suffix='__dbt_tmp', as_table=False) %}
    {% set tmp_identifier = base_relation.identifier ~ suffix %}
    {%- if as_table -%}
        {% set tmp_relation = api.Relation.create(
            identifier=tmp_identifier,
            schema=base_relation.schema,
            database=base_relation.database,
            type='table') %}
    {%- else -%}
        {% set tmp_relation = api.Relation.create(identifier=tmp_identifier, schema=base_relation.schema, database=base_relation.database, type='view') %}
    {%- endif -%}
    {% do return(tmp_relation) %}
{% endmacro %}

{% macro databricks__get_or_create_relation(database, schema, identifier, type, needs_information=False) %}
  {%- set target_relation = adapter.get_relation(
            database=database,
            schema=schema,
            identifier=identifier,
            needs_information=needs_information) %}

  {% if target_relation %}
    {% do return([true, target_relation]) %}
  {% endif %}

  {%- set new_relation = api.Relation.create(
      database=database,
      schema=schema,
      identifier=identifier,
      type=type
  ) -%}
  {% do return([false, new_relation]) %}
{% endmacro %}
