-- Cost-per-1000-RAG-requests query for the BigQuery billing export.
--
-- Prereqs:
--   1. Enable BigQuery billing export once per project
--        Console -> Billing -> Billing export -> Detailed usage cost
--        Dataset:  rag_thesis_billing
--        Table (created automatically): gcp_billing_export_resource_v1_<BILLING_ACCOUNT_ID>
--   2. Replace @billing_table below with your actual table name. The parameters
--      @window_start / @window_end / @rps_total / @arch are passed from the
--      thesis benchmark runner (see benchmarks/RESULTS.md template).
--
-- What this query outputs (one row per service + one grand total):
--
--   service                 total_cost_usd    idle_cost_usd   active_cost_usd
--   Kubernetes Engine       X                  Y               Z
--   Compute Engine          X                  Y               Z
--   Cloud Run               X                  Y               Z
--   Cloud Storage           X                  Y               Z
--   Artifact Registry       X                  Y               Z
--   N1/L4 GPU accelerator   X                  Y               Z
--   TOTAL                   S                                  active_S
--
--   cost_per_1k_requests = active_S / (@rps_total / 1000)
--
-- "Idle" vs "active" split:
--   - active = cost during the benchmark window [@window_start, @window_end]
--   - idle   = cost during an equal-length window immediately BEFORE the
--              benchmark started (baseline when no load is being driven).
-- The benchmark runner records both windows; we compute the delta inline.
--
-- The @arch parameter ("gke" or "cloudrun") filters the resource.name prefix
-- so the two architectures can be compared without cross-contamination when
-- both clusters are live in the same project.

DECLARE active_start TIMESTAMP DEFAULT @window_start;
DECLARE active_end   TIMESTAMP DEFAULT @window_end;
DECLARE window_seconds INT64 DEFAULT TIMESTAMP_DIFF(active_end, active_start, SECOND);
DECLARE idle_start TIMESTAMP DEFAULT TIMESTAMP_SUB(active_start, INTERVAL window_seconds SECOND);
DECLARE idle_end   TIMESTAMP DEFAULT active_start;

WITH
  window_costs AS (
    SELECT
      service.description AS service,
      sku.description     AS sku,
      -- Associate each row with idle or active window based on its usage_start_time.
      CASE
        WHEN usage_start_time >= active_start AND usage_start_time < active_end THEN 'active'
        WHEN usage_start_time >= idle_start   AND usage_start_time < idle_end   THEN 'idle'
        ELSE 'other'
      END AS window_label,
      cost,
      credits
    FROM
      -- IMPORTANT: replace this with your real table, e.g.
      -- `abstract-arc-480317-s4.rag_thesis_billing.gcp_billing_export_resource_v1_XXXXXX`
      `REPLACE_ME.rag_thesis_billing.gcp_billing_export_resource_v1_REPLACE_ME`
    WHERE
      (
        usage_start_time >= idle_start AND usage_start_time < active_end
      )
      AND (
        @arch = 'all'
        OR (@arch = 'gke'      AND service.description IN ('Kubernetes Engine', 'Compute Engine', 'Cloud Storage', 'Artifact Registry'))
        OR (@arch = 'cloudrun' AND service.description IN ('Cloud Run',         'Compute Engine', 'Cloud Storage', 'Artifact Registry', 'Serverless VPC Access'))
      )
  ),
  per_service AS (
    SELECT
      service,
      SUM(IF(window_label = 'active', cost, 0)) AS active_cost_usd,
      SUM(IF(window_label = 'idle',   cost, 0)) AS idle_cost_usd,
      SUM(IF(window_label IN ('active','idle'), cost, 0)) AS total_cost_usd,
      -- Credits reduce effective cost; GCP lists them as negative-valued rows.
      SUM(IF(window_label = 'active',
        (SELECT COALESCE(SUM(c.amount), 0) FROM UNNEST(credits) c), 0)) AS active_credits_usd
    FROM window_costs
    GROUP BY service
  ),
  totals AS (
    SELECT
      'TOTAL'                      AS service,
      SUM(active_cost_usd)         AS active_cost_usd,
      SUM(idle_cost_usd)           AS idle_cost_usd,
      SUM(total_cost_usd)          AS total_cost_usd,
      SUM(active_credits_usd)      AS active_credits_usd
    FROM per_service
  )
SELECT
  service,
  ROUND(total_cost_usd, 4)                                       AS total_cost_usd,
  ROUND(idle_cost_usd, 4)                                        AS idle_cost_usd,
  ROUND(active_cost_usd + active_credits_usd, 4)                 AS active_net_cost_usd,
  ROUND(idle_cost_usd / NULLIF(window_seconds / 3600, 0), 4)     AS idle_cost_per_hour_usd,
  ROUND(
    (active_cost_usd + active_credits_usd) /
    NULLIF(@request_count_total / 1000.0, 0),
    4
  ) AS active_cost_per_1k_requests_usd
FROM (
  SELECT * FROM per_service
  UNION ALL
  SELECT * FROM totals
)
ORDER BY service = 'TOTAL', active_cost_usd DESC;
