# 1. Create the local k3d cluster (using settings from k3d-config.yaml)
just up

# 2. Create the namespace for Argo CD
kubectl create namespace argocd

# 3. Install Argo CD components (using server-side apply to avoid large annotation errors)
kubectl apply -k bootstrap/install --server-side

# 4. Wait for all Argo CD pods to be fully initialized and running
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=300s

# 5. Apply the root application to initialize the GitOps App-of-Apps loop
# NOTE: Make sure your changes are pushed to GitHub before running this, 
# as Argo CD pulls configurations from the remote repository.
kubectl apply -f bootstrap/root-app.yaml

# 6. Check the status of the Argo CD applications (wait until they are Synced and Healthy)
kubectl get applications -n argocd

# 7. Display the status of all pods across all namespaces to verify the core platforms (Traefik, DB, etc.)
kubectl get pods -A
