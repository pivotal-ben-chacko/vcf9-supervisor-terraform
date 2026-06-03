# Workload Cluster Example

A minimal `Cluster` CR (`tkc.yaml`) for spinning up a TKG workload
cluster on top of the Supervisor.

## Quick start

```sh
# 1. Confirm prereqs (Supervisor RUNNING, namespace + storage policy, content library bound)
kubectl get tanzukubernetesreleases       # must list at least one READY+COMPATIBLE tkr
kubectl get virtualmachineclass           # pick a size
kubectl get storageclass                  # confirm supervisor-storage is listed

# 2. Edit tkc.yaml — update `version:` to an exact tkr from step 1
$EDITOR tkc.yaml

# 3. Apply against your namespace
kubectl config use-context test-ns
kubectl apply -f tkc.yaml

# 4. Watch
kubectl get cluster,machine -n test-ns
# Provisioning → Provisioned → Running (~10-20 min on lab hardware)

# 5. Log into the new cluster
kubectl vsphere login \
  --server=k8s.skynetsystems.io \
  --insecure-skip-tls-verify \
  --vsphere-username=administrator@vsphere.local \
  --tanzu-kubernetes-cluster-namespace=test-ns \
  --tanzu-kubernetes-cluster-name=tkc-01

kubectl config use-context tkc-01
kubectl get nodes
```

## Cleanup

```sh
kubectl delete cluster tkc-01 -n test-ns
# Watch:  kubectl get cluster -n test-ns -w
```

## See also

- `../../HOW-TO-CREATE-WORKLOAD-CLUSTER.md` — full guide with prereqs,
  sizing, troubleshooting, and TKG version pinning details
- `../../PREREQUISITES.md` — the Supervisor setup this assumes
- `../../TROUBLESHOOTING.md` — DNS, login, and HAProxy diagnostics
