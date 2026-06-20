# 1. Delete the local k3d cluster
# This command will completely destroy the 'eurotransit-cluster', 
# including all running pods, databases, Kafka topics, and Argo CD configurations.
# It effectively resets your local environment to a clean state.
just down

# Alternative: 
# k3d cluster delete eurotransit-cluster
