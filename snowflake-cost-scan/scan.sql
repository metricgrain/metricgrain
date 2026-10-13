-- =============================================================================
-- Snowflake Cost Scan v0.3.2 by Metricgrain (https://metricgrain.com)
--
-- Read-only. Reads Snowflake's own usage metadata (SNOWFLAKE.ACCOUNT_USAGE,
-- and ORGANIZATION_USAGE rates if your role can see them) plus SHOW WAREHOUSES.
-- Creates nothing, changes nothing.
--
-- What leaves your account if you share the result: spend totals, warehouse
-- names, dbt model names and tool/user labels. No query text, no table data.
--
-- How to run (Snowsight worksheet):
--   1. Use ACCOUNTADMIN, or a role granted IMPORTED PRIVILEGES on SNOWFLAKE.
--   2. Pick a warehouse (Small or Medium). Large accounts can take ~5 minutes.
--   3. Run it. Download the result as CSV and send it back.
--
-- Prices: contract rates are read automatically when visible; otherwise list
-- prices ($3.00/credit, $23/TB-month). Override them below if needed.
-- Window = last 30 full days, annualized. Trend = last 6 full months.
-- =============================================================================

EXECUTE IMMEDIATE $$
DECLARE
    credit_override  FLOAT  DEFAULT NULL;   -- e.g. 2.50 to force a price per credit
    storage_override FLOAT  DEFAULT NULL;   -- e.g. 23   to force a price per TB-month
    v_credit         FLOAT  DEFAULT 3.00;
    v_storage        FLOAT  DEFAULT 23.00;
    v_source         STRING DEFAULT 'list price (contract rates not visible to this role)';
    wh_qid           STRING;
    q_qid            STRING;
    p_qid            STRING;
    res              RESULTSET;
BEGIN
    BEGIN
        SELECT
            AVG(IFF(service_type = 'WAREHOUSE_METERING', effective_rate, NULL)),
            AVG(IFF(service_type = 'STORAGE', effective_rate, NULL))
        INTO :v_credit, :v_storage
        FROM SNOWFLAKE.ORGANIZATION_USAGE.RATE_SHEET_DAILY
        WHERE date >= DATEADD(day, -30, CURRENT_DATE())
          AND account_locator = CURRENT_ACCOUNT();
        IF (v_credit IS NOT NULL) THEN
            v_source := 'your contract rates';
        END IF;
    EXCEPTION
        WHEN OTHER THEN
            NULL;
    END;
    v_credit  := COALESCE(credit_override, v_credit, 3.00);
    v_storage := COALESCE(storage_override, v_storage, 23.00);
    IF (credit_override IS NOT NULL) THEN
        v_source := 'price set in script';
    END IF;

    SHOW WAREHOUSES;
    wh_qid := SQLID;

    -- Step 1 (the only heavy step): every query's credits, tagged with tool,
    -- environment and dbt model, then aggregated. Query text is read only to
    -- detect tool comments; it is never returned.
    WITH sess AS (
        SELECT session_id, client_application_id
        FROM SNOWFLAKE.ACCOUNT_USAGE.SESSIONS
        WHERE created_on >= DATEADD(day, -60, CURRENT_DATE())
    ),
    base AS (
        SELECT
            a.credits_attributed_compute AS credits,
            h.warehouse_name,
            h.user_name,
            h.role_name,
            h.query_tag,
            -- dbt / BI tools put their comment at the start or the end of the query
            LEFT(h.query_text, 1000) || ' ' || RIGHT(h.query_text, 1000) AS qt,
            s.client_application_id      AS client
        FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY a
        JOIN SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY h ON h.query_id = a.query_id
        LEFT JOIN sess s ON s.session_id = h.session_id
        WHERE a.start_time >= DATEADD(day, -30, CURRENT_DATE()) AND a.start_time < CURRENT_DATE()
          AND h.start_time >= DATEADD(day, -31, CURRENT_DATE()) AND h.start_time < CURRENT_DATE()
    ),
    tagged AS (
        SELECT
            credits,
            warehouse_name,
            user_name,
            COALESCE(REGEXP_SUBSTR(qt, '"node_id": ?"([^"]+)"', 1, 1, 'e'),
                     REGEXP_SUBSTR(query_tag, '"node_id": ?"([^"]+)"', 1, 1, 'e'))     AS dbt_node,
            LOWER(COALESCE(REGEXP_SUBSTR(qt, '"target_name": ?"([^"]+)"', 1, 1, 'e'),
                           REGEXP_SUBSTR(query_tag, '"target_name": ?"([^"]+)"', 1, 1, 'e'), '')) AS dbt_target,
            CASE
                WHEN qt ILIKE '%"app": "dbt"%' OR qt ILIKE '%"app":"dbt"%' OR query_tag ILIKE '%dbt%'            THEN 'dbt'
                WHEN qt ILIKE '%Looker Query Context%' OR user_name ILIKE '%LOOKER%' THEN 'Looker'
                WHEN user_name ILIKE '%FIVETRAN%'                                    THEN 'Fivetran'
                WHEN user_name ILIKE '%AIRBYTE%'                                     THEN 'Airbyte'
                WHEN user_name ILIKE '%MATIA%'                                       THEN 'Matia'
                WHEN user_name ILIKE '%STITCH%'                                      THEN 'Stitch'
                WHEN user_name ILIKE '%HEVO%'                                        THEN 'Hevo'
                WHEN user_name ILIKE '%CENSUS%'                                      THEN 'Census'
                WHEN user_name ILIKE '%HIGHTOUCH%'                                   THEN 'Hightouch'
                WHEN user_name ILIKE '%TABLEAU%' OR client ILIKE '%TABLEAU%'         THEN 'Tableau'
                WHEN qt ILIKE '%-- Sigma%' OR user_name ILIKE '%SIGMA%'              THEN 'Sigma'
                WHEN qt ILIKE '%-- Metabase%' OR user_name ILIKE '%METABASE%'        THEN 'Metabase'
                WHEN user_name ILIKE '%POWERBI%' OR client ILIKE '%POWER%BI%'        THEN 'Power BI'
                WHEN qt ILIKE '%-- Hex query metadata%'                              THEN 'Hex'
                WHEN user_name ILIKE '%AIRFLOW%' OR query_tag ILIKE '%airflow%'      THEN 'Airflow'
                WHEN user_name ILIKE '%DAGSTER%'                                     THEN 'Dagster'
                WHEN client ILIKE 'Snowflake UI%' OR client ILIKE 'Snowflake Web App%' THEN 'Snowsight (people)'
                WHEN client ILIKE 'Python%' OR client ILIKE 'Snowpark%'              THEN 'Python / notebooks'
                ELSE 'Other'
            END                                                                    AS tool,
            UPPER(warehouse_name || '_' || COALESCE(role_name, '') || '_' || user_name) AS env_hint
        FROM base
    )
    SELECT
        warehouse_name,
        tool,
        CASE
            WHEN dbt_target IN ('ci', 'test')
              OR REGEXP_LIKE(env_hint, '.*(^|_)(CI|GITLAB|GITHUB)(_|$).*')                 THEN 'CI'
            WHEN dbt_target IN ('dev', 'default', 'local')
              OR REGEXP_LIKE(env_hint, '.*(^|_)(DEV|SANDBOX|TEST|STAGE|STAGING)(_|$).*')
              OR user_name LIKE '%@%'                                                       THEN 'Dev & ad hoc'
            ELSE 'Production'
        END           AS env,
        dbt_node,
        SUM(credits)  AS credits,
        COUNT(*)      AS runs
    FROM tagged
    GROUP BY 1, 2, 3, 4;
    q_qid := SQLID;

    -- Step 2: per-warehouse query shape (no query text).
    SELECT
        warehouse_name,
        COUNT(*)                                 AS queries,
        APPROX_PERCENTILE(execution_time, 0.9)   AS p90_exec_ms,
        SUM(bytes_scanned)                       AS bytes_scanned,
        SUM(bytes_spilled_to_local_storage)      AS local_spill,
        SUM(bytes_spilled_to_remote_storage)     AS remote_spill
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE start_time >= DATEADD(day, -30, CURRENT_DATE()) AND start_time < CURRENT_DATE()
      AND warehouse_name IS NOT NULL
      AND execution_status = 'SUCCESS'
      AND execution_time > 0
    GROUP BY 1;
    p_qid := SQLID;

    res := (
        WITH params AS (
            SELECT
                :v_credit::FLOAT                                  AS credit_usd,
                :v_storage::FLOAT                                 AS storage_usd_tb_month,
                DATEADD(day, -30, CURRENT_DATE())::TIMESTAMP_LTZ AS window_start,
                CURRENT_DATE()::TIMESTAMP_LTZ                     AS window_end,
                365.0 / 30                                        AS annualize
        ),

        wh_config AS (
            SELECT
                "name"::STRING                        AS warehouse_name,
                "size"::STRING                        AS wh_size,
                TRY_TO_NUMBER("auto_suspend"::STRING) AS auto_suspend_s   -- NULL or 0 = never suspends
            FROM TABLE(RESULT_SCAN(:wh_qid))
        ),

        -- ------------------------------------------------------------ inputs --

        metering AS (
            SELECT m.warehouse_name, SUM(m.credits_used_compute) AS compute_credits
            FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY m
            CROSS JOIN params p
            WHERE m.start_time >= p.window_start AND m.start_time < p.window_end
              AND m.warehouse_name <> 'CLOUD_SERVICES_ONLY'
            GROUP BY 1
        ),

        services AS (
            SELECT d.service_type, SUM(d.credits_billed) AS billed_credits
            FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY d
            CROSS JOIN params p
            WHERE d.usage_date >= p.window_start::DATE AND d.usage_date < p.window_end::DATE
            GROUP BY 1
        ),

        storage AS (
            SELECT
                SUM(t.active_bytes + t.time_travel_bytes + t.failsafe_bytes + t.retained_for_clone_bytes)
                    / POWER(1024, 4)                                         AS total_tb,
                SUM(t.time_travel_bytes + t.failsafe_bytes) / POWER(1024, 4) AS history_tb
            FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS t
        ),

        q_agg AS (
            SELECT warehouse_name, tool, env, dbt_node, credits, runs
            FROM TABLE(RESULT_SCAN(:q_qid))
        ),

        attributed AS (
            SELECT warehouse_name, SUM(credits) AS query_credits FROM q_agg GROUP BY 1
        ),

        query_profile AS (
            SELECT warehouse_name, queries, p90_exec_ms, bytes_scanned, local_spill, remote_spill
            FROM TABLE(RESULT_SCAN(:p_qid))
        ),

        -- ------------------------------------------------------ calculations --

        idle_by_wh AS (
            -- Idle = credits billed while no query ran. suspend_share = part fixable
            -- with AUTO_SUSPEND = 60 ("never suspends" treated as 3600s). The rest is
            -- assumed 30% recoverable by consolidating warehouses and batching schedules.
            SELECT
                m.warehouse_name,
                GREATEST(m.compute_credits - COALESCE(a.query_credits, 0), 0)     AS idle_credits,
                GREATEST(1 - 60 / COALESCE(NULLIF(c.auto_suspend_s, 0), 3600), 0) AS suspend_share
            FROM metering m
            JOIN wh_config c ON c.warehouse_name = m.warehouse_name
            LEFT JOIN attributed a ON a.warehouse_name = m.warehouse_name
        ),

        oversized AS (
            -- Medium+ warehouses: 90% of queries < 10s, no remote spill, local spill
            -- < 1% of data scanned. Save 25% of their query credits (one size down).
            SELECT SUM(COALESCE(a.query_credits, 0) * 0.25) AS credits
            FROM wh_config c
            JOIN query_profile qp ON qp.warehouse_name = c.warehouse_name
            LEFT JOIN attributed a ON a.warehouse_name = c.warehouse_name
            WHERE UPPER(REPLACE(c.wh_size, '-', '')) NOT IN ('XSMALL', 'SMALL')
              AND qp.queries >= 100
              AND qp.p90_exec_ms < 10000
              AND qp.remote_spill = 0
              AND qp.local_spill < 0.01 * NULLIF(qp.bytes_scanned, 0)
        ),

        env_spend AS (
            SELECT env, SUM(credits) AS credits FROM q_agg GROUP BY 1
        ),

        top_models AS (
            SELECT dbt_node, SUM(credits) AS credits, SUM(runs) AS runs
            FROM q_agg
            WHERE dbt_node IS NOT NULL
            GROUP BY 1
            QUALIFY ROW_NUMBER() OVER (ORDER BY SUM(credits) DESC) <= 10
        ),

        areas AS (
            SELECT 'Idle time: warehouse consolidation & scheduling' AS focus_area,
                   SUM(idle_credits * (1 - suspend_share)) * 0.30 * MAX(p.credit_usd) * MAX(p.annualize) AS usd
            FROM idle_by_wh CROSS JOIN params p
            UNION ALL
            SELECT 'Idle time: auto-suspend settings',
                   SUM(idle_credits * suspend_share) * MAX(p.credit_usd) * MAX(p.annualize)
            FROM idle_by_wh CROSS JOIN params p
            UNION ALL
            SELECT 'Warehouse sizing',
                   COALESCE(MAX(o.credits), 0) * MAX(p.credit_usd) * MAX(p.annualize)
            FROM oversized o CROSS JOIN params p
            UNION ALL
            -- Trimming CI data, skipping unchanged models and duplicate runs: assume 30%.
            SELECT 'CI & dev workloads',
                   COALESCE(SUM(IFF(e.env IN ('CI', 'Dev & ad hoc'), e.credits, 0)), 0) * 0.30
                       * MAX(p.credit_usd) * MAX(p.annualize)
            FROM env_spend e CROSS JOIN params p
            UNION ALL
            -- Incremental loads, materialization and clustering on the 10 costliest models: assume 20%.
            SELECT 'Top 10 dbt models',
                   COALESCE(SUM(t.credits), 0) * 0.20 * MAX(p.credit_usd) * MAX(p.annualize)
            FROM top_models t CROSS JOIN params p
            UNION ALL
            SELECT 'Storage history (Time Travel / Fail-safe)',
                   COALESCE(MAX(s.history_tb), 0) * 0.5 * MAX(p.storage_usd_tb_month) * 12
            FROM storage s CROSS JOIN params p
        ),

        spend AS (
            SELECT
                SUM(s.billed_credits) * MAX(p.credit_usd) * MAX(p.annualize)
                    + MAX(st.total_tb) * MAX(p.storage_usd_tb_month) * 12                       AS total_usd,
                SUM(IFF(s.service_type = 'WAREHOUSE_METERING', s.billed_credits, 0))
                    * MAX(p.credit_usd) * MAX(p.annualize)                                      AS warehouse_usd,
                SUM(IFF(s.service_type NOT IN ('WAREHOUSE_METERING', 'WAREHOUSE_METERING_READER'),
                        s.billed_credits, 0)) * MAX(p.credit_usd) * MAX(p.annualize)            AS serverless_usd,
                MAX(st.total_tb) * MAX(p.storage_usd_tb_month) * 12                             AS storage_usd
            FROM services s CROSS JOIN storage st CROSS JOIN params p
        ),

        monthly AS (
            SELECT DATE_TRUNC('month', d.usage_date) AS month,
                   SUM(d.credits_billed) * MAX(p.credit_usd) AS usd
            FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY d
            CROSS JOIN params p
            WHERE d.usage_date >= DATEADD(month, -6, DATE_TRUNC('month', CURRENT_DATE()))
              AND d.usage_date <  DATE_TRUNC('month', CURRENT_DATE())
            GROUP BY 1
        ),

        growth AS (
            -- Average monthly growth across the trend window (compute only).
            SELECT
                POWER(MAX_BY(usd, month) / NULLIF(MIN_BY(usd, month), 0),
                      1 / NULLIF(COUNT(*) - 1, 0)) - 1 AS monthly_rate,
                MAX_BY(usd, month)                      AS last_month_usd
            FROM monthly
        ),

        measured AS (SELECT SUM(usd) AS usd FROM areas),

        -- ------------------------------------------------------------ report --

        report AS (
            SELECT 'Summary' AS section, 1 AS rank, 'Estimated annual Snowflake spend' AS item,
                   'Last 30 days, annualized' AS detail, sp.total_usd AS usd_per_year
            FROM spend sp
            UNION ALL
            SELECT 'Summary', 2, 'Estimated savings potential (low)',
                   'Measured by this scan', ms.usd
            FROM measured ms
            UNION ALL
            SELECT 'Summary', 3, 'Estimated savings potential (high)',
                   'Adds query tuning not measured here (5% of warehouse spend)', ms.usd + sp.warehouse_usd * 0.05
            FROM measured ms CROSS JOIN spend sp
            UNION ALL
            SELECT 'Summary', 4, 'Idle compute',
                   ROUND(100 * SUM(i.idle_credits) / NULLIF((SELECT SUM(compute_credits) FROM metering), 0))
                       || '% of warehouse credits billed with no query running',
                   SUM(i.idle_credits) * MAX(p.credit_usd) * MAX(p.annualize)
            FROM idle_by_wh i CROSS JOIN params p
            UNION ALL
            SELECT 'Summary', 5, 'Spend growth',
                   ROUND(100 * g.monthly_rate, 1) || '% per month over the last 6 months',
                   g.last_month_usd * 12 * POWER(1 + COALESCE(g.monthly_rate, 0), 6)
            FROM growth g
            UNION ALL
            SELECT 'Summary', 6, 'Prices used',
                   '$' || TRIM(TO_CHAR(p.credit_usd, '990.00')) || '/credit, $'
                       || TRIM(TO_CHAR(p.storage_usd_tb_month, '990.00')) || '/TB-month (' || :v_source || ')',
                   NULL
            FROM params p
            UNION ALL
            SELECT 'Spend mix', 1, 'Warehouses', NULL, sp.warehouse_usd FROM spend sp
            UNION ALL
            SELECT 'Spend mix', 2, 'Storage', NULL, sp.storage_usd FROM spend sp
            UNION ALL
            SELECT 'Spend mix', 3, 'Serverless & AI', NULL, sp.serverless_usd FROM spend sp
            UNION ALL
            SELECT 'Trend', ROW_NUMBER() OVER (ORDER BY month), TO_CHAR(month, 'YYYY-MM'),
                   'Monthly compute & services spend', usd * 12
            FROM monthly
            UNION ALL
            SELECT 'Focus areas', ROW_NUMBER() OVER (ORDER BY usd DESC), focus_area, 'Estimated annual savings', usd
            FROM areas
            UNION ALL
            SELECT 'By tool', ROW_NUMBER() OVER (ORDER BY SUM(q.credits) DESC), q.tool, 'Query compute',
                   SUM(q.credits) * MAX(p.credit_usd) * MAX(p.annualize)
            FROM q_agg q CROSS JOIN params p
            GROUP BY q.tool
            UNION ALL
            SELECT 'By environment', ROW_NUMBER() OVER (ORDER BY e.credits DESC), e.env, 'Query compute',
                   e.credits * p.credit_usd * p.annualize
            FROM env_spend e CROSS JOIN params p
            UNION ALL
            SELECT 'Top dbt models', ROW_NUMBER() OVER (ORDER BY t.credits DESC), t.dbt_node,
                   t.runs || ' runs in 30 days', t.credits * p.credit_usd * p.annualize
            FROM top_models t CROSS JOIN params p
            UNION ALL
            SELECT 'Top idle warehouses', ROW_NUMBER() OVER (ORDER BY i.idle_credits DESC), i.warehouse_name,
                   'Billed while no query ran', i.idle_credits * p.credit_usd * p.annualize
            FROM idle_by_wh i CROSS JOIN params p
            QUALIFY ROW_NUMBER() OVER (ORDER BY i.idle_credits DESC) <= 5
        )

        SELECT section, rank, item, detail, ROUND(usd_per_year, -2) AS usd_per_year
        FROM report
        WHERE section NOT IN ('By tool', 'Top dbt models') OR rank <= 10
        ORDER BY CASE section
                     WHEN 'Summary' THEN 1 WHEN 'Spend mix' THEN 2 WHEN 'Trend' THEN 3
                     WHEN 'Focus areas' THEN 4 WHEN 'By tool' THEN 5 WHEN 'By environment' THEN 6
                     WHEN 'Top dbt models' THEN 7 ELSE 8 END,
                 rank
    );
    RETURN TABLE(res);
END;
$$;
