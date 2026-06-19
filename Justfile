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

#kubectl apply --server-side -f https://strimzi.io/install/latest?namespace=kafka -n kafka

#install the Strimzi operator (CRDs, RBAC and operator deployment) into the kafka namespace
install-operator:
    @echo "Ensuring kafka namespace exists..."
    kubectl create namespace kafka --dry-run=client -o yaml | kubectl apply -f -
    @echo "Installing Strimzi operator..."
    
    kubectl create -f https://strimzi.io/install/latest?namespace=kafka -n kafka
    @echo "Waiting for Strimzi cluster operator deployment to become available..."
    kubectl rollout status deployment/strimzi-cluster-operator -n kafka --timeout=120s
    @echo "Strimzi operator installed and ready."

#deploy the Kafka broker and topics (waits for CRDs to be registered first, to avoid the discovery-cache race)
deploy-topics:
    @echo "Waiting for Strimzi CRDs to be established..."
    kubectl wait --for=condition=Established crd/kafkas.kafka.strimzi.io crd/kafkatopics.kafka.strimzi.io --timeout=60s
    kubectl apply -f kafka/ -n kafka

#one-shot bootstrap: cluster + operator + topics, in the right order with the right waits
bootstrap: up install-operator deploy-topics
    @echo "EuroTransit cluster fully bootstrapped."