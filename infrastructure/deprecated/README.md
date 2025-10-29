# Deprecated Files

This directory contains old files that have been replaced by the new environment-specific architecture.

## Why Deprecated?

- **Old Approach**: Manual configuration, Ingress Controller, scattered files
- **New Approach**: Environment-specific, Gateway API only, automated scripts

## Migration Completed

- ✅ Gateway API CRDs: Now installed by k3s-install.sh
- ✅ Ingress Controller: Removed (Gateway API only)
- ✅ Gateway configs: Moved to `infrastructure/environments/*/gateway.yaml`
- ✅ IP Pools: Moved to `infrastructure/environments/*/lb-ippool.yaml`
- ✅ Certificates: Moved to `infrastructure/environments/*/certificates.yaml`
- ✅ HTTPRoutes: Moved to `infrastructure/environments/*/httproutes.yaml`
- ✅ ClusterIssuer: Moved to `infrastructure/common/cert-manager-clusterissuer.yaml`
- ✅ GatewayClass: Moved to `infrastructure/common/gatewayclass.yaml`

## Safe to Delete

All files in this directory can be safely deleted. They are kept temporarily for reference only.

## New Structure

```
infrastructure/
├── common/                        # Cluster-wide resources
│   ├── gatewayclass.yaml
│   ├── cert-manager-clusterissuer.yaml
│   └── cilium-values.yaml
│
├── environments/                  # Environment-specific configs
│   ├── dev/
│   ├── staging/
│   └── production/
│
├── k3s-install.sh                # Updated
├── cert-manager-install.sh       # Updated
└── install-environment.sh        # NEW
```
