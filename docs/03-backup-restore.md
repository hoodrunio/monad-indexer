# Backup & Restore Guide - Monad Indexer

Complete disaster recovery guide for your Monad blockchain indexer infrastructure.

## Table of Contents

1. [Overview](#overview)
2. [Backup Strategy](#backup-strategy)
3. [PostgreSQL Backup](#postgresql-backup)
4. [Full Cluster Backup](#full-cluster-backup)
5. [Restore Procedures](#restore-procedures)
6. [Testing Backups](#testing-backups)
7. [Disaster Recovery Plan](#disaster-recovery-plan)

## Overview

### Backup Components

Your Monad indexer has several critical components that need backing up:

| Component | Backup Method | Frequency | Retention |
|-----------|--------------|-----------|-----------|
| **PostgreSQL Data** | pgBackRest (CloudNativePG) | Continuous WAL + Daily full | 30 days |
| **Kubernetes Configs** | Velero | Daily | 30 days |
| **Helm Values** | Git | Every commit | Forever |
| **ArgoCD Apps** | Git | Every commit | Forever |

### RPO/RTO Targets

- **RPO (Recovery Point Objective)**: < 5 minutes (WAL archiving)
- **RTO (Recovery Time Objective)**: < 30 minutes (automated restore)

## Backup Strategy

### Three-Layer Approach

1. **Application Layer**: Git-based GitOps (ArgoCD)
2. **Data Layer**: CloudNativePG with pgBackRest
3. **Infrastructure Layer**: Velero for cluster state

### Backup Storage

**Recommended**: S3-compatible storage
- AWS S3
- MinIO (self-hosted)
- Cloudflare R2
- Backblaze B2

## PostgreSQL Backup

### CloudNativePG Automated Backups

**Configuration** (values-production.yaml):
```yaml
postgresql:
  backup:
    enabled: true
    retentionPolicy: "30d"

    barmanObjectStore:
      destinationPath: "s3://monad-indexer-backups/postgresql"

      s3Credentials:
        accessKeyId:
          name: postgres-backup-creds
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: postgres-backup-creds
          key: SECRET_ACCESS_KEY

      wal:
        compression: gzip
        maxParallel: 8
```

### Create Backup Credentials

```bash
# Create S3 credentials secret
kubectl create secret generic postgres-backup-creds \
  --from-literal=ACCESS_KEY_ID=your-access-key \
  --from-literal=SECRET_ACCESS_KEY=your-secret-key \
  -n monad-indexer-prod
```

### Manual Backup

**Trigger On-Demand Backup**:
```bash
# Create backup
kubectl cnpg backup monad-indexer-postgresql \
  -n monad-indexer-prod

# Check backup status
kubectl cnpg backup list monad-indexer-postgresql \
  -n monad-indexer-prod
```

**Expected Output**:
```
NAME                                        PHASE       STARTED                COMPLETED
monad-indexer-postgresql-20241028-120000    completed   2024-10-28T12:00:00Z   2024-10-28T12:15:00Z
```

### Scheduled Backups

CloudNativePG automatically creates backups based on the schedule:

**Default Schedule** (configured in operator):
- **Full Backup**: Daily at 2 AM
- **WAL Archiving**: Continuous (every 60 seconds)

**Custom Schedule**:
```yaml
postgresql:
  backup:
    barmanObjectStore:
      # ... existing config

    schedule:
      # Cron schedule for full backups
      "0 2 * * *"  # 2 AM daily
```

### Verify Backups

```bash
# List all backups
kubectl get backups -n monad-indexer-prod

# Check backup details
kubectl describe backup monad-indexer-postgresql-20241028-120000 \
  -n monad-indexer-prod

# Verify S3 backup exists
aws s3 ls s3://monad-indexer-backups/postgresql/
```

### Backup Monitoring

**Prometheus Alerts**:
```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: postgres-backup-alerts
spec:
  groups:
  - name: postgresql-backup
    rules:
    # Alert if no backup in 25 hours
    - alert: PostgreSQLNoRecentBackup
      expr: |
        (time() - cnpg_pg_cluster_last_backup_timestamp) > 90000
      for: 1h
      labels:
        severity: warning
      annotations:
        summary: "No recent PostgreSQL backup"
        description: "Last backup was {{ $value | humanizeDuration }} ago"

    # Alert if backup failed
    - alert: PostgreSQLBackupFailed
      expr: |
        cnpg_pg_cluster_last_backup_succeeded == 0
      for: 5m
      labels:
        severity: critical
      annotations:
        summary: "PostgreSQL backup failed"
```

## Full Cluster Backup

### Velero Installation

```bash
# Install Velero CLI
brew install velero

# Install Velero in cluster (AWS example)
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.9.0 \
  --bucket monad-indexer-velero-backups \
  --backup-location-config region=us-east-1 \
  --snapshot-location-config region=us-east-1 \
  --secret-file ./velero-credentials
```

### Configure Velero Backup

**Schedule Full Cluster Backup**:
```bash
# Create backup schedule
velero schedule create monad-indexer-daily \
  --schedule="0 3 * * *" \
  --include-namespaces monad-indexer-prod \
  --ttl 720h \
  --storage-location default
```

**Backup Specific Resources**:
```bash
# Backup only configurations
velero backup create monad-indexer-config \
  --include-namespaces monad-indexer-prod \
  --include-resources configmaps,secrets,persistentvolumeclaims \
  --storage-location default
```

### Velero Backup Hooks

**Pre-Backup Hook** (pause writes):
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: monad-indexer-backend
  annotations:
    # Pre-backup: checkpoint database
    pre.hook.backup.velero.io/command: '["/bin/bash", "-c", "echo Preparing for backup"]'
    pre.hook.backup.velero.io/timeout: 30s

    # Post-backup: resume operations
    post.hook.backup.velero.io/command: '["/bin/bash", "-c", "echo Backup complete"]'
```

### Monitor Velero Backups

```bash
# List backups
velero backup get

# Check backup details
velero backup describe monad-indexer-daily-20241028-030000

# View backup logs
velero backup logs monad-indexer-daily-20241028-030000
```

## Restore Procedures

### Scenario 1: Database Corruption

**Symptoms**:
- PostgreSQL pod crash loop
- Data inconsistency errors
- Failed queries

**Restore Process**:

1. **Identify Last Good Backup**:
```bash
kubectl cnpg backup list monad-indexer-postgresql -n monad-indexer-prod
```

2. **Scale Down Backend** (stop writes):
```bash
kubectl scale deployment monad-indexer-backend --replicas=0 -n monad-indexer-prod
```

3. **Create New Cluster from Backup**:
```yaml
# restore-cluster.yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: monad-indexer-postgresql-restored
  namespace: monad-indexer-prod
spec:
  instances: 3

  bootstrap:
    recovery:
      source: monad-indexer-postgresql
      backup:
        name: monad-indexer-postgresql-20241028-120000

  externalClusters:
  - name: monad-indexer-postgresql
    barmanObjectStore:
      destinationPath: "s3://monad-indexer-backups/postgresql"
      s3Credentials:
        # ... same credentials as backup
```

4. **Apply Restore**:
```bash
kubectl apply -f restore-cluster.yaml
```

5. **Wait for Restore to Complete**:
```bash
kubectl get cluster monad-indexer-postgresql-restored -n monad-indexer-prod -w
```

6. **Update Backend Configuration**:
```yaml
# Point to restored cluster
backend:
  env:
    DATABASE_URL: "postgresql://...@monad-indexer-postgresql-restored-pooler-rw:5432/..."
```

7. **Scale Up Backend**:
```bash
kubectl scale deployment monad-indexer-backend --replicas=5 -n monad-indexer-prod
```

### Scenario 2: Point-in-Time Recovery (PITR)

**Use Case**: Recover to specific timestamp (e.g., before bad deployment)

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: monad-indexer-postgresql-pitr
spec:
  bootstrap:
    recovery:
      source: monad-indexer-postgresql
      recoveryTarget:
        targetTime: "2024-10-28T11:30:00Z"  # Specific time
        # OR
        targetXID: "12345"  # Specific transaction ID
        # OR
        targetName: "before-bad-migration"  # Named restore point
```

**Create Named Restore Point** (before risky operations):
```bash
kubectl exec -it monad-indexer-postgresql-1 -n monad-indexer-prod -- \
  psql -U postgres -d blockscout -c \
  "SELECT pg_create_restore_point('before-migration');"
```

### Scenario 3: Complete Cluster Loss

**Restore from Velero**:

1. **Recreate Cluster** (if needed):
```bash
# Ensure K3s is running
./infrastructure/k3s-install.sh

# Reinstall operators
./infrastructure/cloudnativepg-operator-install.sh
./infrastructure/external-secrets-operator-install.sh
```

2. **Restore from Velero**:
```bash
# List available backups
velero backup get

# Restore entire namespace
velero restore create monad-indexer-restore \
  --from-backup monad-indexer-daily-20241028-030000 \
  --wait
```

3. **Check Restore Status**:
```bash
velero restore describe monad-indexer-restore

# Check pods
kubectl get pods -n monad-indexer-prod
```

4. **Verify Application**:
```bash
# Check database
kubectl exec -it monad-indexer-postgresql-1 -n monad-indexer-prod -- \
  psql -U postgres -d blockscout -c "SELECT COUNT(*) FROM blocks;"

# Check API
kubectl port-forward svc/monad-indexer-backend 4000:4000 -n monad-indexer-prod
curl http://localhost:4000/api/v2/stats
```

### Scenario 4: Accidental Data Deletion

**Restore Specific Table**:

1. **Create Temporary Restore Cluster**:
```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: temp-restore
spec:
  instances: 1
  bootstrap:
    recovery:
      source: monad-indexer-postgresql
      backup:
        name: monad-indexer-postgresql-20241028-120000
```

2. **Extract Data**:
```bash
# Export deleted data
kubectl exec -it temp-restore-1 -n monad-indexer-prod -- \
  pg_dump -U postgres -d blockscout -t deleted_table \
  --data-only > deleted_data.sql

# Import to production
kubectl exec -i monad-indexer-postgresql-1 -n monad-indexer-prod -- \
  psql -U postgres -d blockscout < deleted_data.sql
```

3. **Delete Temporary Cluster**:
```bash
kubectl delete cluster temp-restore -n monad-indexer-prod
```

## Testing Backups

### Monthly Backup Test

**Test Procedure**:

1. **Create Test Namespace**:
```bash
kubectl create namespace monad-indexer-test
```

2. **Restore to Test Namespace**:
```bash
velero restore create test-restore-$(date +%Y%m%d) \
  --from-backup monad-indexer-daily-latest \
  --namespace-mappings monad-indexer-prod:monad-indexer-test \
  --wait
```

3. **Verify Data Integrity**:
```bash
# Connect to test database
kubectl exec -it monad-indexer-postgresql-1 -n monad-indexer-test -- \
  psql -U postgres -d blockscout

# Run queries
SELECT COUNT(*) FROM blocks;
SELECT COUNT(*) FROM transactions;
SELECT MAX(number) FROM blocks;
```

4. **Measure Restore Time** (document for RTO):
```bash
# Start time: [timestamp]
# End time: [timestamp]
# Total restore time: [duration]
```

5. **Cleanup**:
```bash
kubectl delete namespace monad-indexer-test
```

### Automated Backup Testing

**CronJob for Monthly Tests**:
```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: backup-test
spec:
  schedule: "0 4 1 * *"  # 4 AM on 1st of month
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: backup-tester
          containers:
          - name: test
            image: bitnami/kubectl
            command:
            - /bin/bash
            - -c
            - |
              # Create test namespace
              kubectl create namespace monad-test-$(date +%Y%m%d)

              # Restore latest backup
              velero restore create test-restore-$(date +%Y%m%d) \
                --from-backup monad-indexer-daily-latest \
                --namespace-mappings monad-indexer-prod:monad-test-$(date +%Y%m%d)

              # Wait for completion
              sleep 600

              # Verify
              kubectl exec -it monad-indexer-postgresql-1 \
                -n monad-test-$(date +%Y%m%d) -- \
                psql -U postgres -d blockscout -c "SELECT COUNT(*) FROM blocks;"

              # Cleanup
              kubectl delete namespace monad-test-$(date +%Y%m%d)
          restartPolicy: OnFailure
```

## Disaster Recovery Plan

### DR Runbook

**1. Assess Damage**:
```bash
# Check cluster status
kubectl get nodes
kubectl get pods -A

# Check database status
kubectl get cluster -n monad-indexer-prod

# Check recent backups
velero backup get
kubectl cnpg backup list monad-indexer-postgresql -n monad-indexer-prod
```

**2. Declare Disaster Level**:

| Level | Description | Action |
|-------|-------------|--------|
| **L1** | Single pod failure | Kubernetes auto-recovery |
| **L2** | Database failure | Restore from pgBackRest |
| **L3** | Namespace loss | Restore from Velero |
| **L4** | Cluster loss | Rebuild + restore |

**3. Execute Recovery** (based on level):

**L2 Recovery**:
```bash
# 1. Scale down backend
kubectl scale deployment monad-indexer-backend --replicas=0 -n monad-indexer-prod

# 2. Restore database (see Scenario 1 above)

# 3. Verify data
# 4. Scale up backend
```

**L3 Recovery**:
```bash
# 1. Restore namespace from Velero
velero restore create dr-restore --from-backup monad-indexer-daily-latest

# 2. Verify all pods running
kubectl get pods -n monad-indexer-prod

# 3. Test API endpoints
```

**L4 Recovery**:
```bash
# 1. Rebuild cluster
./infrastructure/k3s-install.sh
./infrastructure/argocd-install.sh
./infrastructure/cloudnativepg-operator-install.sh

# 2. Restore from Velero
velero restore create full-dr-restore --from-backup monad-indexer-daily-latest

# 3. Verify and test
```

**4. Post-Recovery Verification**:
```bash
# Check all pods
kubectl get pods -n monad-indexer-prod

# Verify database
kubectl exec -it monad-indexer-postgresql-1 -n monad-indexer-prod -- \
  psql -U postgres -d blockscout -c "SELECT COUNT(*) FROM blocks;"

# Test API
curl http://localhost:4000/api/v2/stats

# Check monitoring
kubectl port-forward svc/grafana 3000:80 -n monitoring
```

**5. Document Incident**:
- Time of disaster
- Root cause
- Recovery time
- Data loss (if any)
- Lessons learned

### Recovery Time Estimates

| Scenario | Recovery Time | Data Loss |
|----------|--------------|-----------|
| **Pod crash** | < 2 minutes | None |
| **Database corruption** | 15-30 minutes | < 5 minutes (WAL) |
| **Namespace deletion** | 10-20 minutes | < 5 minutes |
| **Full cluster loss** | 30-60 minutes | < 5 minutes |

## Backup Checklist

### Daily
- [ ] Verify automated backups completed
- [ ] Check backup size (should grow gradually)
- [ ] Review Prometheus alerts
- [ ] Verify WAL archiving is continuous

### Weekly
- [ ] Review backup retention (30 days)
- [ ] Check S3 storage usage and costs
- [ ] Verify Velero backups are completing
- [ ] Test backup download speed

### Monthly
- [ ] Perform full backup restore test
- [ ] Measure and document restore time
- [ ] Update DR runbook if needed
- [ ] Review and update backup policies
- [ ] Audit backup access logs

### Quarterly
- [ ] Full disaster recovery drill
- [ ] Test multi-region failover (if applicable)
- [ ] Review backup costs and optimization
- [ ] Update recovery time objectives

## Summary

Your Monad indexer has comprehensive backup coverage:

✅ **PostgreSQL**: Continuous WAL + daily full backups
✅ **Cluster State**: Daily Velero backups
✅ **Configuration**: Git-based (ArgoCD)
✅ **Monitoring**: Automated alerts for backup failures
✅ **Testing**: Monthly automated backup tests

**RPO**: < 5 minutes (WAL archiving)
**RTO**: < 30 minutes (automated restore)

**Next**: See [04-troubleshooting.md](04-troubleshooting.md) for common issues and solutions.
