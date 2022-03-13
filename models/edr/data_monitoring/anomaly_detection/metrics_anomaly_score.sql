{%- set timeframe_end = "'"~ run_started_at.strftime("%Y-%m-%d 00:00:00")~"'" %}

with data_monitoring_metrics as (

    select * from {{ ref('data_monitoring_metrics') }}
    where timeframe_end >= {{ elementary.cast_to_timestamp(dbt_utils.dateadd('day', '-7', timeframe_end)) }}

),

daily_buckets as (

    with dates as (
         select {{ elementary.date_trunc('day', 'min(timeframe_end)') }} as date
        from data_monitoring_metrics
    union all
        select {{ dbt_utils.dateadd('day', '1', 'date') }}
        from dates
        where {{ dbt_utils.dateadd('day', '1', 'date') }} <= {{ elementary.cast_to_timestamp(timeframe_end) }}
    )
    select date as edr_daily_bucket
    from dates

),

time_window_aggregation as (

    select
        *,
        avg(metric_value) over (partition by metric_name, full_table_name, column_name order by edr_daily_bucket asc rows between {{ var('days_back') }} preceding and current row) as training_avg,
        stddev(metric_value) over (partition by metric_name, full_table_name, column_name order by edr_daily_bucket asc rows between {{ var('days_back') }} preceding and current row) as training_stddev,
        count(metric_value) over (partition by metric_name, full_table_name, column_name order by edr_daily_bucket asc rows between {{ var('days_back') }} preceding and current row) as training_set_size,
        last_value(timeframe_end) over (partition by metric_name, full_table_name, column_name order by edr_daily_bucket asc rows between {{ var('days_back') }} preceding and current row) training_timeframe_end,
        first_value(timeframe_end) over (partition by metric_name, full_table_name, column_name order by edr_daily_bucket asc rows between {{ var('days_back') }} preceding and current row) as training_timeframe_start
    from daily_buckets left join
        data_monitoring_metrics on (edr_daily_bucket = timeframe_end)
    {{ dbt_utils.group_by(10) }}

),

metrics_anomaly_score as (

    select
        id,
        full_table_name,
        column_name,
        metric_name,
        case
           when training_stddev = 0 then 0
           else (metric_value - training_avg) / (training_stddev)
        end as z_score,
        metric_value as latest_metric_value,
        timeframe_start,
        timeframe_end,
        training_avg,
        training_stddev,
        training_timeframe_start,
        training_timeframe_end,
        training_set_size,
        max(updated_at) as updated_at
    from time_window_aggregation
        where
            metric_value is not null
            and training_avg is not null
            and training_stddev is not null
            and training_set_size >= {{ var('days_back') - 1 }}
    {{ dbt_utils.group_by(13) }}
    order by timeframe_end desc

),

final as (

    select *,
        case
            when abs(z_score) > {{ var('anomaly_score_threshold') }} then true
            else false end
        as is_anomaly
    from metrics_anomaly_score
    {{ dbt_utils.group_by(14) }}

)

select * from final