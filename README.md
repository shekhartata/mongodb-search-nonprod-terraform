# Terraform: MongoDB EA + MongoDB Search on EKS (non-prod)

Builds everything from zero, for **non-prod testing only**:

- **Stage 1 (`01-eks`)**: new VPC (2 AZs, single NAT) + EKS Auto Mode cluster
- **Stage 2 (`02-mongodb`)**: MCK Operator → MongoDB Enterprise replica set (plain StatefulSet) → users → MongoDB Search (`mongot`, managed by MCK)

No Cloud Manager or Ops Manager is needed: `mongod` runs as a plain StatefulSet and the operator manages only `mongot`.

Two stages because the Kubernetes providers need the cluster to exist before they can be configured.

```
01-eks/      VPC + EKS Auto Mode
02-mongodb/  storage class, MCK Operator, secrets, mongod StatefulSet, replica set init, MongoDBSearch
```

## Prerequisites

Terraform >= 1.6, AWS CLI, kubectl, and AWS credentials with rights to create VPC, EKS and IAM resources. Stage 2 runs `kubectl` locally once to initialize the replica set.

## Deploy

```bash
# Stage 1: VPC + EKS
cd 01-eks
terraform init
terraform apply                 # optional: -var region=... -var name=...
$(terraform output -raw configure_kubectl)
cd ..

# Stage 2: MongoDB + Search
cd 02-mongodb
cp terraform.tfvars.example terraform.tfvars    # only if you changed region/name in stage 1
terraform init
terraform apply

$(terraform output -raw wait_for_search)
$(terraform output -raw check_search_service)   # expect mdb-search-0-svc
```

## Test

```bash
terraform output -raw admin_password; echo      # copy it
$(terraform output -raw connect)                # paste the password at the prompt
```

```javascript
use search_test
db.movies.insertMany([
  { title: "Space Odyssey", plot: "A voyage through space" },
  { title: "Deep Sea",      plot: "Exploring the ocean" }
])
db.movies.createSearchIndex("default", { mappings: { dynamic: true } })
db.movies.getSearchIndexes()           // repeat until status "READY"
db.movies.aggregate([ { $search: { text: { query: "space", path: "title" } } } ])
```

Returns "Space Odyssey" → working.

## Troubleshooting

| Symptom | Check |
|---|---|
| `mdb-rs` pods crash-looping | `kubectl -n mongodb logs mdb-rs-0 -c mongod`. Usually keyfile permissions or a bad `--setParameter` |
| `rs_init` step hangs | All `mdb-rs` pods must be Running: `kubectl -n mongodb get pods`. Re-run `terraform apply` after fixing; the script is safe to re-run |
| Pods `Pending` | Auto Mode is launching nodes; wait. `kubectl describe pod` for details |
| `MongoDBSearch` not `Running` | `kubectl -n mongodb describe mdbs mdb`, and the mongot pod logs |
| `$search` errors | The `mongot` alias must point at the operator's Search Service. If `check_search_service` shows a different name: `kubectl -n mongodb patch svc mongot -p '{"spec":{"externalName":"<actual-svc>.mongodb.svc.cluster.local"}}'` |
| Operator logs | `kubectl -n mongodb logs deploy/mongodb-kubernetes-operator --tail=100` |

## Tear down

```bash
cd 02-mongodb && terraform destroy
kubectl -n mongodb delete pvc --all   # StatefulSet volumes aren't deleted automatically
kubectl get pv                        # wait until empty so no EBS volumes are orphaned
cd ../01-eks && terraform destroy
```

## Non-prod shortcuts in this code

- No TLS between components (traffic stays inside the cluster; SCRAM auth on)
- `mongod` as a plain StatefulSet (for production, manage it with Ops Manager or Cloud Manager)
- One `mongot` replica, gp3 EBS volumes (production guidance is local NVMe)
- Public EKS API endpoint, single NAT gateway
- Terraform state holds the generated database passwords and keyfile: keep state local or in an encrypted backend
