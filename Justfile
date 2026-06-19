#EuroTransit cluster management

#if you do not have just use one of the following commands to install it 
#brew install just 
#cargo install just

#creating the local k3d cluster using declarative configuration
up:
    @echo "Creating the local k3d cluster..."
    k3d cluster create --config k3d-config.yaml
    @echo "Cluster ready! Kubeconfig context updated."

#delete
down:
    @echo "Deleting the local k3d cluster..."
    k3d cluster delete eurotransit-cluster

#status of nodes and main components
status:
    kubectl get nodes -o wide
    kubectl get pods -A