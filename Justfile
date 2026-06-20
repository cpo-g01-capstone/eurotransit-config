#EuroTransit cluster management

#if you do not have just use one of the following commands to install it 
#brew install just 
#cargo install just


set windows-shell := ["powershell.exe", "-NoLogo", "-Command"]

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

#install the Strimzi operator using Helm to pin the exact version deterministically
install-operator:
    @echo "Ensuring eurotransit namespace exists..."
    kubectl create namespace eurotransit --dry-run=client -o yaml | kubectl apply -f -
    @echo "Adding Strimzi Helm repository..."
    helm repo add strimzi https://strimzi.io/charts/
    helm repo update
    @echo "Installing Strimzi operator version 0.40.0..."
    helm upgrade --install strimzi-cluster-operator strimzi/strimzi-kafka-operator --namespace eurotransit --version 0.40.0
    @echo "Waiting for Strimzi cluster operator deployment to become available..."
    kubectl rollout status deployment/strimzi-cluster-operator -n eurotransit --timeout=120s
    @echo "Strimzi operator installed and ready."

deploy-topics:
    @echo "Waiting for Strimzi CRDs to be established..."
    kubectl wait --for=condition=Established crd/kafkas.kafka.strimzi.io crd/kafkatopics.kafka.strimzi.io --timeout=60s
    kubectl apply -f kafka/ -n eurotransit

#one-shot bootstrap: cluster + operator + topics, in the right order with the right waits
bootstrap: up install-operator deploy-topics
    @echo "EuroTransit cluster fully bootstrapped."