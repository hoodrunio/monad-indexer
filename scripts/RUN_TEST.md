# Quick Test Guide: pg_partman Dry-Run

Test pg_partman güvenle, production tablolarına dokunmadan.

## 1-Line Test (Hızlı)

```bash
# Copy script to pod and run
kubectl cp scripts/test_pg_partman.sh monad-indexer-dev-postgresql-1:/tmp/ -n monad-indexer-dev && \
kubectl exec -it monad-indexer-dev-postgresql-1 -n monad-indexer-dev -- bash /tmp/test_pg_partman.sh
```

## Test Ne Yapar?

1. **Test table oluşturur** (`blocks_test`) - production'a dokunmaz ✅
2. **7 günlük fake data** ekler (7000 satır)
3. **Partitioned table** oluşturur (`blocks_test_partitioned`)
4. **pg_partman** ile register eder (**1 gün retention** - test için)
5. **Data migration** yapar (batch'ler halinde)
6. **Partition pruning** test eder (query optimization)
7. **Retention** test eder (1 günden eski partitionları drop)
8. **Performance** karşılaştırır (partitioned vs non-partitioned)
9. **Cleanup** yapar (test resources siler)

## Beklenen Çıktı

```
================================================================
PG_PARTMAN DRY-RUN TEST
================================================================
Started: 2025-10-30 19:46:00 UTC

>>> Step 1: Verifying prerequisites
✓ pg_partman extension found
✓ pg_partman background worker running

>>> Step 2: Creating test table (blocks_test)
✓ Test table created

>>> Step 3: Inserting test data (7 days of blocks, 1000 blocks/day)
✓ Inserted 7000 test rows

>>> Step 4: Creating partitioned version
✓ Partitioned table created

>>> Step 5: Registering with pg_partman (1-day retention for testing)
✓ Table registered with pg_partman
✓ Retention set to 1 day

>>> Step 6: Verifying partition creation
Partitions created: 10
✓ Partitions created successfully

Partition details:
 partition_name                     | size
------------------------------------+-------
 blocks_test_partitioned_p20251023 | 152 kB
 blocks_test_partitioned_p20251024 | 152 kB
 ...

>>> Step 7: Migrating test data to partitions
Source table: 0 rows
Partitioned table: 7000 rows
✓ Data migration successful

>>> Step 8: Testing partition pruning (query optimization)
Query plan for recent data (should prune old partitions):
 Aggregate
   ->  Append
         Subplans Removed: 5  <-- ÖNEMLİ: Partition pruning çalışıyor!
         ->  Seq Scan on blocks_test_partitioned_p20251029
         ->  Seq Scan on blocks_test_partitioned_p20251030
✓ Partition pruning verified

>>> Step 9: Testing retention (checking what would be dropped)
Partitions older than 1 day (would be dropped by maintenance):
 partition_name                     | size   | status
------------------------------------+--------+-----------------
 blocks_test_partitioned_p20251023 | 152 kB | WOULD BE DROPPED
 blocks_test_partitioned_p20251024 | 152 kB | WOULD BE DROPPED
 ...
✓ Retention test complete

>>> Step 10: Running pg_partman maintenance manually
✓ Maintenance run complete
Partitions after maintenance: 4
Partitions before maintenance: 10
✓ Dropped 6 old partitions (>1 day old)

>>> Step 11: Verifying data integrity after maintenance
Rows after maintenance: 1000
Expected rows (last 1 day): 1000
✓ Data integrity verified

>>> Step 12: Performance comparison
Non-partitioned table:
 Execution Time: 15.234 ms

Partitioned table:
 Execution Time: 2.156 ms  <-- 7x FASTER!
✓ Performance comparison complete

>>> Step 13: Cleaning up test resources
✓ Test resources cleaned up

================================================================
TEST COMPLETED SUCCESSFULLY
================================================================

Summary:
  ✓ pg_partman extension verified
  ✓ Partitions created successfully (10 partitions)
  ✓ Data migration successful (7000 rows)
  ✓ Partition pruning working
  ✓ Retention working (dropped 6 old partitions)
  ✓ Data integrity verified
  ✓ Performance comparison complete

Next steps:
  1. Review partition pruning in EXPLAIN output
  2. Compare execution times for query performance
  3. If satisfied, proceed with production table setup
```

## Başarı Kriterleri

✅ **Extension found**: pg_partman yüklü
✅ **Partitions created**: 7+ partition (7 gün data + premake)
✅ **Migration successful**: 7000 rows taşındı
✅ **Partition pruning**: "Subplans Removed" görünmeli
✅ **Retention works**: Eski partitionlar drop edildi
✅ **No data loss**: Retention sonrası expected row count doğru
✅ **Performance gain**: Partitioned table daha hızlı

## Sorun Giderme

### pg_partman extension not found
```bash
# Extension install edilmemiş - deploy yapmalısın
helm upgrade monad-indexer-dev charts/monad-indexer \
  -n monad-indexer-dev \
  -f charts/monad-indexer/environments/values-dev.yaml
```

### Background worker not running
```bash
# shared_preload_libraries yüklenmemiş - rolling restart gerekli
# CloudNativePG otomatik yapar ama manuel kontrol:
kubectl get pods -n monad-indexer-dev -l cnpg.io/cluster=monad-indexer-dev-postgresql
```

### No partitions dropped during maintenance
- Normal! Eğer data 1 günden yeniyse drop edilmez
- Test için eski tarihli data eklenmiş olmalı
- `inserted_at` değerlerine bak: `SELECT MIN(inserted_at), MAX(inserted_at) FROM blocks_test_partitioned;`

### Row count mismatch
- Migration incomplete olabilir
- Tekrar çalıştır: `SELECT partman.partition_data_proc(...)`

## Production'a Geçiş

Test başarılı olduktan sonra:

```bash
# 1. Production tablolar için partition setup
kubectl cp scripts/pg_partman_setup.sql monad-indexer-dev-postgresql-1:/tmp/ -n monad-indexer-dev
kubectl exec -it monad-indexer-dev-postgresql-1 -n monad-indexer-dev -- \
  psql -U postgres -d blockscout -f /tmp/pg_partman_setup.sql

# 2. Migration job enable et
# values-dev.yaml: postgresql.partman.migration.enabled: true
helm upgrade monad-indexer-dev charts/monad-indexer ...

# 3. Migration tamamlanınca table swap (docs/PG_PARTMAN.md)
```
