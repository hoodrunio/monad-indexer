# Monitoring Guide - Monad Indexer

Complete guide for monitoring the Monad blockchain indexer using Prometheus, Grafana, and AlertManager.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Installation](#installation)
- [Accessing Services](#accessing-services)
- [Dashboards](#dashboards)
- [Alerts](#alerts)
- [Custom Metrics](#custom-metrics)
- [Troubleshooting](#troubleshooting)

---

## Overview

The monitoring stack provides:

- **Prometheus Operator**: Manages Prometheus instances and CRDs
- **Prometheus**: Time-series database for metrics
- **Grafana**: Visualization and dashboards
- **AlertManager**: Alert routing and notifications
- **ServiceMonitor/PodMonitor**: Auto-discovery of metrics endpoints
- **Node Exporter**: System-level metrics
- **Kube State Metrics**: Kubernetes object metrics

### What Gets Monitored

| Component | Metrics Source | Dashboard |
|-----------|---------------|-----------|
| Cilium CNI | ServiceMonitor | Cilium Dashboard (GrafanaID: 16611) |
| PostgreSQL | PodMonitor (CloudNativePG) | PostgreSQL Dashboard (GrafanaID: 9628) |
| Redis | ServiceMonitor (Bitnami) | Redis Dashboard (GrafanaID: 11835) |
| Blockscout Backend | ServiceMonitor (custom) | Custom Blockscout Dashboard |
| Kubernetes Cluster | Kube State Metrics | K8s Cluster Dashboard (GrafanaID: 7249) |
| Nodes (CPU/Memory/Disk) | Node Exporter | Node Exporter Dashboard |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Monitoring Namespace                     │
│                                                               │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐  │
│  │  Prometheus  │───▶│  Grafana     │    │ AlertManager │  │
│  │  (scraping)  │    │ (dashboards) │◀───│ (alerts)     │  │
│  └──────────────┘    └──────────────┘    └──────────────┘  │
│         │                                                     │
└─────────┼─────────────────────────────────────────────────┘
          │
          ├── ServiceMonitor ──▶ Cilium (kube-system)
          ├── ServiceMonitor ──▶ Redis (monad-indexer-*)
          ├── PodMonitor ────▶ PostgreSQL (monad-indexer-*)
          ├── ServiceMonitor ──▶ Blockscout Backend
          ├── Node Exporter ──▶ All Nodes
          └── Kube State Metrics ──▶ K8s API
```

---

## Installation

### Method 1: Manual Installation (Recommended for First Time)

```bash
cd ~/monad-indexer/infrastructure

# Install for production
./prometheus-operator-install.sh production

# Or for development
./prometheus-operator-install.sh dev
```

This will:
1. Install Prometheus Operator (with all CRDs)
2. Deploy Prometheus instance
3. Deploy Grafana with pre-configured dashboards
4. Deploy AlertManager (production only)
5. Enable ServiceMonitor/PodMonitor auto-discovery

### Method 2: ArgoCD GitOps (Production)

```bash
# 1. Deploy infrastructure project
kubectl apply -f argocd/projects/infrastructure-project.yaml

# 2. Deploy monitoring stack
kubectl apply -f argocd/applications/infrastructure-monitoring.yaml

# 3. Wait for sync
argocd app sync kube-prometheus-stack
argocd app wait kube-prometheus-stack --health
```

### Verification

```bash
# Check all monitoring pods are running
kubectl get pods -n monitoring

# Check CRDs are installed
kubectl get crd | grep monitoring.coreos.com

# Expected CRDs:
# - servicemonitors.monitoring.coreos.com
# - podmonitors.monitoring.coreos.com
# - prometheusrules.monitoring.coreos.com
# - prometheuses.monitoring.coreos.com
# - alertmanagers.monitoring.coreos.com

# Check Prometheus is scraping
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
# Open http://localhost:9090/targets
```

---

## Accessing Services

### Prometheus

```bash
# Port forward
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090

# Access at: http://localhost:9090
```

**Useful URLs:**
- Targets: http://localhost:9090/targets
- Alerts: http://localhost:9090/alerts
- Rules: http://localhost:9090/rules
- Config: http://localhost:9090/config

### Grafana

```bash
# Port forward
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80

# Get admin password
kubectl get secret -n monitoring kube-prometheus-stack-grafana \
  -o jsonpath="{.data.admin-password}" | base64 --decode && echo

# Access at: http://localhost:3000
# Username: admin
# Password: (from above command)
```

### AlertManager

```bash
# Port forward
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093

# Access at: http://localhost:9093
```

---

## Dashboards

### Pre-installed Dashboards

All dashboards are auto-imported from Grafana.com:

| Dashboard | Grafana ID | Description |
|-----------|-----------|-------------|
| Cilium Metrics | 16611 | Cilium CNI performance, connections, policies |
| PostgreSQL Database | 9628 | CloudNativePG metrics, connections, queries |
| Redis | 11835 | Redis performance, memory, commands |
| Kubernetes Cluster | 7249 | Overall cluster health, resource usage |
| Node Exporter | (built-in) | CPU, memory, disk, network per node |

### Accessing Dashboards

1. Open Grafana: http://localhost:3000
2. Navigate to **Dashboards** → **Browse**
3. Select a dashboard from the list

### Important Metrics to Watch

#### Blockscout Indexer
```promql
# Blocks indexed per second
rate(blockscout_indexed_blocks_total[5m])

# Current indexing lag (blocks behind)
blockscout_indexing_lag_blocks

# Database connection pool usage
blockscout_db_connections_active / blockscout_db_connections_total

# API response time (p95)
histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m]))
```

#### PostgreSQL (CloudNativePG)
```promql
# Connection count
pg_stat_database_numbackends

# Query rate
rate(pg_stat_database_xact_commit[5m])

# Replication lag
pg_replication_lag_seconds

# Cache hit ratio (should be > 99%)
rate(pg_stat_database_blks_hit[5m]) /
(rate(pg_stat_database_blks_hit[5m]) + rate(pg_stat_database_blks_read[5m]))
```

#### Redis
```promql
# Memory usage
redis_memory_used_bytes / redis_memory_max_bytes

# Commands per second
rate(redis_commands_processed_total[5m])

# Cache hit ratio
rate(redis_keyspace_hits_total[5m]) /
(rate(redis_keyspace_hits_total[5m]) + rate(redis_keyspace_misses_total[5m]))

# Connected clients
redis_connected_clients
```

#### Cilium
```promql
# Packet forwarding rate
rate(cilium_forward_count_total[5m])

# Packet drops
rate(cilium_drop_count_total[5m])

# Network policy denies
rate(cilium_policy_endpoint_enforcement_outcome{verdict="denied"}[5m])

# BPF map pressure
cilium_bpf_map_pressure
```

---

## Alerts

### Default Alert Rules

The stack comes with pre-configured alerts:

| Alert | Severity | Description |
|-------|----------|-------------|
| KubePodCrashLooping | critical | Pod is crash looping |
| KubePodNotReady | warning | Pod not ready for > 15m |
| KubeDeploymentReplicasMismatch | warning | Deployment replicas mismatch |
| NodeMemoryPressure | warning | Node memory > 80% |
| NodeDiskPressure | critical | Node disk > 90% |
| PrometheusTargetDown | warning | Scrape target is down |

### Custom Alerts for Monad Indexer

Create custom alerts in `charts/monad-indexer/templates/monitoring/prometheusrules.yaml`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: monad-indexer-alerts
  namespace: {{ .Release.Namespace }}
spec:
  groups:
    - name: indexer
      interval: 30s
      rules:
        - alert: IndexerLagHigh
          expr: blockscout_indexing_lag_blocks > 100
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Indexer is lagging behind"
            description: "Indexer is {{ $value }} blocks behind"

        - alert: IndexerStalled
          expr: rate(blockscout_indexed_blocks_total[5m]) == 0
          for: 10m
          labels:
            severity: critical
          annotations:
            summary: "Indexer has stalled"
            description: "No blocks indexed in the last 10 minutes"

        - alert: DatabaseConnectionsHigh
          expr: (blockscout_db_connections_active / blockscout_db_connections_total) > 0.8
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Database connection pool nearly exhausted"
            description: "Connection pool usage: {{ $value | humanizePercentage }}"

        - alert: PostgreSQLReplicationLag
          expr: pg_replication_lag_seconds > 30
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "PostgreSQL replication lag high"
            description: "Replication lag: {{ $value }}s"

        - alert: RedisCacheHitRatioLow
          expr: |
            (
              rate(redis_keyspace_hits_total[5m]) /
              (rate(redis_keyspace_hits_total[5m]) + rate(redis_keyspace_misses_total[5m]))
            ) < 0.7
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Redis cache hit ratio is low"
            description: "Cache hit ratio: {{ $value | humanizePercentage }}"
```

### Configuring AlertManager

Edit `infrastructure/helm/kube-prometheus-stack/values-production.yaml`:

```yaml
alertmanager:
  config:
    receivers:
      # Slack notifications
      - name: 'slack'
        slack_configs:
          - api_url: 'https://hooks.slack.com/services/YOUR/WEBHOOK/URL'
            channel: '#alerts'
            title: '{{ .GroupLabels.alertname }}'
            text: '{{ range .Alerts }}{{ .Annotations.description }}{{ end }}'

      # PagerDuty for critical alerts
      - name: 'pagerduty'
        pagerduty_configs:
          - service_key: 'YOUR_PAGERDUTY_KEY'

    route:
      group_by: ['alertname', 'cluster']
      group_wait: 10s
      group_interval: 10s
      repeat_interval: 12h
      receiver: 'slack'
      routes:
        # Critical alerts go to PagerDuty
        - match:
            severity: critical
          receiver: 'pagerduty'
          continue: true
        # All alerts go to Slack
        - match_re:
            severity: .*
          receiver: 'slack'
```

---

## Custom Metrics

### Adding ServiceMonitor to Your App

If deploying additional services, enable monitoring:

```yaml
# In your Helm values
monitoring:
  enabled: true
  serviceMonitor:
    enabled: true
    interval: 30s
    path: /metrics
    labels:
      release: kube-prometheus-stack
```

### Exposing Metrics from Blockscout

Blockscout already exposes Prometheus metrics at `/metrics`. Ensure ServiceMonitor is enabled:

```yaml
# charts/monad-indexer/values.yaml
backend:
  monitoring:
    enabled: true
```

### Custom Metrics Example

```elixir
# In Blockscout code (Elixir)
defmodule BlockScout.Metrics do
  use Prometheus.Metric

  def setup do
    Counter.declare(
      name: :blockscout_indexed_blocks_total,
      help: "Total number of blocks indexed"
    )

    Gauge.declare(
      name: :blockscout_indexing_lag_blocks,
      help: "Number of blocks behind the chain tip"
    )

    Histogram.declare(
      name: :blockscout_db_query_duration_seconds,
      help: "Database query duration",
      buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10]
    )
  end

  def increment_indexed_blocks do
    Counter.inc(name: :blockscout_indexed_blocks_total)
  end

  def set_indexing_lag(lag) do
    Gauge.set([name: :blockscout_indexing_lag_blocks], lag)
  end

  def observe_query_duration(duration) do
    Histogram.observe([name: :blockscout_db_query_duration_seconds], duration)
  end
end
```

---

## Troubleshooting

### ServiceMonitor Not Appearing in Targets

**Symptoms:** ServiceMonitor created but not showing in Prometheus targets.

**Solution:**
```bash
# 1. Check ServiceMonitor exists
kubectl get servicemonitors -A

# 2. Check ServiceMonitor labels (must match Prometheus selector)
kubectl get servicemonitor <name> -n <namespace> -o yaml

# 3. Check Prometheus is configured to discover all ServiceMonitors
kubectl get prometheus -n monitoring -o yaml | grep -A 5 serviceMonitorSelector

# 4. Check Prometheus operator logs
kubectl logs -n monitoring -l app.kubernetes.io/name=prometheus-operator --tail=100

# 5. Force Prometheus reload
kubectl delete pod -n monitoring -l app.kubernetes.io/name=prometheus
```

### Grafana Dashboards Not Loading

**Symptoms:** Dashboards show "No data" or don't load.

**Solution:**
```bash
# 1. Check Prometheus datasource
# In Grafana: Configuration → Data Sources → Prometheus
# URL should be: http://kube-prometheus-stack-prometheus:9090

# 2. Test query in Prometheus directly
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
# Open http://localhost:9090 and run: up

# 3. Check ServiceMonitor/PodMonitor is scraping
# In Prometheus: Status → Targets
# Look for your service

# 4. Verify metrics endpoint
kubectl port-forward -n <namespace> <pod-name> 8080:8080
curl localhost:8080/metrics
```

### Prometheus Disk Full

**Symptoms:** Prometheus pod CrashLoopBackOff, "no space left on device".

**Solution:**
```bash
# 1. Check PVC usage
kubectl exec -n monitoring <prometheus-pod> -- df -h /prometheus

# 2. Reduce retention period
# Edit: infrastructure/helm/kube-prometheus-stack/values-production.yaml
prometheus:
  prometheusSpec:
    retention: 15d  # Reduce from 30d
    retentionSize: "80GB"  # Reduce from 100GB

# 3. Increase PVC size (if storage class supports it)
kubectl patch pvc -n monitoring <pvc-name> \
  -p '{"spec":{"resources":{"requests":{"storage":"200Gi"}}}}'

# 4. Clean up old data (last resort)
kubectl exec -n monitoring <prometheus-pod> -- \
  rm -rf /prometheus/wal /prometheus/chunks_head
```

### Metrics Not Scraping

**Symptoms:** Targets show "context deadline exceeded" or "connection refused".

**Solution:**
```bash
# 1. Check service exists
kubectl get svc -n <namespace>

# 2. Check service selector matches pods
kubectl get svc <service-name> -n <namespace> -o yaml
kubectl get pods -n <namespace> --show-labels

# 3. Test connectivity from Prometheus pod
kubectl exec -n monitoring <prometheus-pod> -- \
  wget -O- http://<service-name>.<namespace>:8080/metrics

# 4. Check NetworkPolicy isn't blocking
kubectl get networkpolicies -n <namespace>
# Ensure egress from monitoring namespace is allowed
```

### High Cardinality Metrics

**Symptoms:** Prometheus consuming excessive memory, slow queries.

**Solution:**
```bash
# 1. Identify high-cardinality metrics
# In Prometheus: Status → TSDB Status
# Look at "Top 10 label names with value count"

# 2. Drop problematic metrics
# Add to values-production.yaml:
prometheus:
  prometheusSpec:
    additionalScrapeConfigs:
      - job_name: 'kubernetes-service-endpoints'
        metric_relabel_configs:
          # Drop high-cardinality labels
          - source_labels: [__name__]
            regex: 'http_request_duration.*'
            target_label: user_id
            replacement: ''

# 3. Reduce scrape interval for expensive targets
# In ServiceMonitor:
spec:
  interval: 60s  # Increase from 30s
```

---

## Best Practices

### 1. Resource Planning

- **Prometheus**: Allocate ~2GB RAM per million active time series
- **Grafana**: 512MB-1GB RAM sufficient for most use cases
- **Retention**: Balance between history and disk usage (30d recommended)

### 2. Label Hygiene

- Use low-cardinality labels (avoid user IDs, request IDs)
- Keep labels consistent across services
- Use relabeling to clean up labels

### 3. Alert Tuning

- Set appropriate `for:` duration to avoid alert flapping
- Use `group_by` to reduce alert noise
- Test alerts with `amtool` before deploying

### 4. Dashboard Organization

- Group related metrics in single dashboard
- Use template variables for filtering
- Set reasonable refresh intervals (30s-1m)

### 5. Regular Maintenance

- Review alert rules monthly
- Clean up unused ServiceMonitors
- Check disk usage weekly
- Update dashboards with new metrics

---

## Additional Resources

- [Prometheus Documentation](https://prometheus.io/docs/)
- [Grafana Documentation](https://grafana.com/docs/)
- [Prometheus Operator Guide](https://prometheus-operator.dev/)
- [PromQL Cheat Sheet](https://promlabs.com/promql-cheat-sheet/)
- [Grafana Dashboard Library](https://grafana.com/grafana/dashboards/)

