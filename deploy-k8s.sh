#!/bin/bash

export VERSION=10.0.0
# Function to extract value from JSON response
extract_json_value() {
    local json="$1"
    local key="$2"
    echo "$json" | grep -o "\"$key\":[^,}]*" | cut -d':' -f2- | tr -d '"' | tr -d ' '
}

# Create secure ingress with TLS certificate
create_secure_ingress() {
    local service_name=$1
    local service_port=$2
    local host="${service_name}.${DOMAIN_NAME}"

    echo "Creating secure ingress for $service_name (port $service_port) at $host"

    # Create the ingress with TLS configuration
    cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: $service_name
  namespace: $NAMESPACE
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
    kubernetes.io/ingress.class: "nginx"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/use-regex: "true"
    nginx.ingress.kubernetes.io/rewrite-target: /\$1
spec:
  tls:
  - hosts:
    - $host
    secretName: $service_name-tls
  rules:
  - host: $host
    http:
      paths:
      - path: /(.*)
        pathType: Prefix
        backend:
          service:
            name: $service_name
            port:
              number: $service_port
EOF

    echo "Secure ingress created for $service_name"
    echo "Your service will be available at https://$host once the certificate is issued"
    echo "Certificate issuance may take a few minutes"
}

# Update the registry configuration to use Nexus registry
configure_for_registry() {
    local namespace=$1
    echo "Configuring for Nexus Docker registry usage..."

    # Create namespace if it doesn't exist
    kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f -

    # Set registry URL to use Nexus
    REGISTRY_URL="docker.aletyx-labs.aletyx.dev"
    echo "Will use Nexus Docker registry at: $REGISTRY_URL"

    # Set current namespace context
    kubectl config set-context --current --namespace="$namespace"
    NAMESPACE="$namespace"

    # Create registry credential secret for pulling images
    kubectl create secret docker-registry registry-credentials \
      --docker-server=$REGISTRY_URL \
      --docker-username=admin \
      --docker-password=$(read -s -p "Enter Nexus Docker registry password: " pwd; echo $pwd) \
      --docker-email=admin@example.com \
      || true

    echo "Created Kubernetes secret 'registry-credentials' for Nexus Docker registry"
}

# Function to get Keycloak access token
get_token() {
    echo "Attempting to get token from: https://${KEYCLOAK_BASE_URL}/auth/realms/master/protocol/openid-connect/token"

    local token_response
    token_response=$(curl -s -k -X POST "https://${KEYCLOAK_BASE_URL}/auth/realms/master/protocol/openid-connect/token" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -d "username=${ADMIN_USERNAME}" \
      -d "password=${ADMIN_PASSWORD}" \
      -d "grant_type=password" \
      -d "client_id=admin-cli")

    TOKEN=$(extract_json_value "$token_response" "access_token")

    if [ -z "$TOKEN" ] || [ "$TOKEN" == "null" ]; then
        echo "Failed to obtain access token. Response:"
        echo "$token_response"
        exit 1
    fi

    echo "Successfully obtained access token"
}

# Function to check if realm exists and create if needed
setup_keycloak_realm() {
    local realm="$1"
    echo "Checking if realm $realm exists..."

    local realm_check
    realm_check=$(curl -s -k -X GET "https://${KEYCLOAK_BASE_URL}/auth/admin/realms/${realm}" \
      -H "Authorization: Bearer ${TOKEN}")

    if echo "$realm_check" | grep -q "error"; then
        echo "Creating realm $realm..."
        curl -s -k -X POST "https://${KEYCLOAK_BASE_URL}/auth/admin/realms" \
            -H "Authorization: Bearer ${TOKEN}" \
            -H "Content-Type: application/json" \
            -d '{
                "realm": "'"${realm}"'",
                "enabled": true,
                "sslRequired": "external",
                "registrationAllowed": false,
                "loginWithEmailAllowed": true,
                "duplicateEmailsAllowed": false,
                "resetPasswordAllowed": true,
                "editUsernameAllowed": false,
                "bruteForceProtected": true
            }'
        echo "Realm created successfully"
    else
        echo "Realm $realm already exists"
    fi
}

# Function to create or update client
setup_client() {
    local realm="$1"
    local client_id="$2"
    local redirect_uri="$3"
    local is_public="${4:-true}"
    local client_secret="${5:-}"

    echo "Setting up client $client_id..."

    # Check if client exists
    local clients_response
    clients_response=$(curl -s -k -X GET "https://${KEYCLOAK_BASE_URL}/auth/admin/realms/${realm}/clients" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json")

    local client_internal_id
    client_internal_id=$(echo "$clients_response" | grep -o "{[^}]*\"clientId\":\"$client_id\"[^}]*}" | grep -o '"id":"[^"]*"' | cut -d'"' -f4)

    local payload='{
        "clientId": "'"${client_id}"'",
        "enabled": true,
        "publicClient": '"${is_public}"',
        "redirectUris": ["'"${redirect_uri}"'"],
        "webOrigins": ["+"]'

    if [ "$is_public" = "false" ] && [ -n "$client_secret" ]; then
        payload="${payload}"',"secret": "'"${client_secret}"'"'
    fi

    payload="${payload}"'}'

    if [ -z "$client_internal_id" ]; then
        echo "Creating new client $client_id..."
        curl -s -k -X POST "https://${KEYCLOAK_BASE_URL}/auth/admin/realms/${realm}/clients" \
            -H "Authorization: Bearer ${TOKEN}" \
            -H "Content-Type: application/json" \
            -d "$payload"
    else
        echo "Updating existing client $client_id..."
        curl -s -k -X PUT "https://${KEYCLOAK_BASE_URL}/auth/admin/realms/${realm}/clients/${client_internal_id}" \
            -H "Authorization: Bearer ${TOKEN}" \
            -H "Content-Type: application/json" \
            -d "$payload"
    fi
}

create_user() {
    local realm="$1"
    local username="jdoe"
    local password="jdoe"
    local firstname="John"
    local lastname="Doe"
    local email="jdoe@example.com"

    echo "Creating user $username in realm $realm..."

    # Create user with direct JSON string
    local user_payload='{
        "username": "'"$username"'",
        "enabled": true,
        "emailVerified": true,
        "firstName": "'"$firstname"'",
        "lastName": "'"$lastname"'",
        "email": "'"$email"'",
        "credentials": [{
            "type": "password",
            "value": "'"$password"'",
            "temporary": false
        }]
    }'

    # Create user
    local create_response
    create_response=$(curl -s -k -X POST "https://${KEYCLOAK_BASE_URL}/auth/admin/realms/${realm}/users" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$user_payload")

    if [ -n "$create_response" ] && echo "$create_response" | grep -q "error"; then
        echo "User might already exist, proceeding to get user ID"
    else
        echo "User $username created successfully"
    fi

    # Get user ID
    local user_response
    user_response=$(curl -s -k -X GET "https://${KEYCLOAK_BASE_URL}/auth/admin/realms/${realm}/users?username=$username" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json")

    local user_id
    user_id=$(echo "$user_response" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

    if [ -z "$user_id" ]; then
        echo "Failed to get user ID for $username"
        return 1
    fi

    echo "Found user ID: $user_id"

    # Array of roles to create and assign
    local roles=("HR" "IT" "user")

    # Create and assign roles
    for role in "${roles[@]}"; do
        echo "Setting up role: $role"

        # Create role if it doesn't exist
        local role_payload='{
            "name": "'"$role"'"
        }'

        curl -s -k -X POST "https://${KEYCLOAK_BASE_URL}/auth/admin/realms/${realm}/roles" \
            -H "Authorization: Bearer ${TOKEN}" \
            -H "Content-Type: application/json" \
            -d "$role_payload" || true

        # Get role ID
        local role_response
        role_response=$(curl -s -k -X GET "https://${KEYCLOAK_BASE_URL}/auth/admin/realms/${realm}/roles/${role}" \
            -H "Authorization: Bearer ${TOKEN}" \
            -H "Content-Type: application/json")

        local role_id
        role_id=$(echo "$role_response" | grep -o '"id":"[^"]*"' | cut -d'"' -f4)

        if [ -n "$role_id" ]; then
            # Assign role to user
            local role_mapping_payload='[{
                "id": "'"$role_id"'",
                "name": "'"$role"'"
            }]'

            curl -s -k -X POST "https://${KEYCLOAK_BASE_URL}/auth/admin/realms/${realm}/users/${user_id}/role-mappings/realm" \
                -H "Authorization: Bearer ${TOKEN}" \
                -H "Content-Type: application/json" \
                -d "$role_mapping_payload"

            echo "Role $role assigned to user $username"
        else
            echo "Could not find role ID for $role"
        fi
    done
}

deploy_postgresql() {
    local db_name="$1-postgresql"
    echo "Deploying PostgreSQL database..."

    # Cleanup existing PostgreSQL resources
    echo "Cleaning up any existing PostgreSQL resources..."
    kubectl delete deployment $db_name --ignore-not-found=true
    kubectl delete service $db_name --ignore-not-found=true
    kubectl delete pvc $db_name-pvc --ignore-not-found=true
    sleep 10  # Wait for resources to be deleted

    # Create PostgreSQL secrets
    kubectl create secret generic postgresql-credentials \
        --from-literal=database-name=kogito \
        --from-literal=database-user=kogito \
        --from-literal=database-password=kogito123 \
        || true

    # Create PVC first
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $db_name-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF

    # Wait for PVC to be created
    echo "Waiting for PVC to be created..."
    sleep 5

    # Create PostgreSQL deployment
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $db_name
  labels:
    app: $db_name
    app.kubernetes.io/part-of: $APP_PART_OF
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $db_name
  template:
    metadata:
      labels:
        app: $db_name
    spec:
      containers:
      - name: postgresql
        image: postgres:16.1-alpine3.19
        ports:
        - containerPort: 5432
        env:
        - name: POSTGRES_DB
          value: "kogito"
        - name: POSTGRES_USER
          value: "kogito"
        - name: POSTGRES_PASSWORD
          value: "kogito123"
        - name: PGDATA
          value: "/var/lib/postgresql/data/pgdata"
        volumeMounts:
        - name: postgresql-data
          mountPath: /var/lib/postgresql/data
      volumes:
      - name: postgresql-data
        persistentVolumeClaim:
          claimName: $db_name-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: $db_name
spec:
  selector:
    app: $db_name
  ports:
  - port: 5432
    targetPort: 5432
EOF

    # Wait for PostgreSQL to be ready
    echo "Waiting for PostgreSQL to be ready..."
    kubectl wait --for=condition=available deployment/$db_name --timeout=300s || true

    echo "PostgreSQL deployment completed"
}

# Function to build and deploy application with Nexus registry
deploy_application() {
    echo "Building and deploying main application using Nexus registry..."

    # Set the application image name
    APP_IMAGE="${REGISTRY_URL}/${NAMESPACE}/${SERVICE_NAME}:latest"
    echo "Application will be built as: $APP_IMAGE"

    # Build the application with Maven
    echo "Building application using Maven with Nexus registry configuration..."
    mvn clean package \
        -Dquarkus.container-image.registry="${REGISTRY_URL}" \
        -Dquarkus.container-image.group="${NAMESPACE}" \
        -Dquarkus.container-image.name="${SERVICE_NAME}" \
        -Dquarkus.container-image.tag="latest" \
        -Dquarkus.container-image.build=true \
        -Dquarkus.kubernetes.deploy=true \
        -Dquarkus.kubernetes.deployment-target=kubernetes \
        -Dquarkus.kubernetes.namespace="${NAMESPACE}" \
        -Dquarkus.container-image.username="admin" \
        -Dquarkus.container-image.password="$(read -s -p 'Enter Nexus password for maven build: ' pwd; echo $pwd)" \
        -Dquarkus.container-image.insecure=true \
        -Pkubernetes

    # Capture the build result
    BUILD_RESULT=$?

    # Check if the build was successful
    if [ $BUILD_RESULT -ne 0 ]; then
        echo "ERROR: Application build failed!"
        exit 1
    fi

    # Deploy the application
    echo "Deploying application..."
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $SERVICE_NAME
  labels:
    app: $SERVICE_NAME
    app.kubernetes.io/part-of: $APP_PART_OF
    app.kubernetes.io/runtime: java
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $SERVICE_NAME
  template:
    metadata:
      labels:
        app: $SERVICE_NAME
    spec:
      imagePullSecrets:
      - name: registry-credentials
      containers:
      - name: $SERVICE_NAME
        image: $APP_IMAGE
        imagePullPolicy: Always
        ports:
        - containerPort: 8080
        env:
        - name: POSTGRESQL_USER
          value: "kogito"
        - name: POSTGRESQL_PASSWORD
          value: "kogito123"
        - name: POSTGRESQL_DATABASE
          value: "kogito"
        - name: POSTGRESQL_SERVICE
          value: "$SERVICE_NAME-postgresql"
        - name: KOGITO_SERVICE_URL
          value: "https://$SERVICE_NAME.$DOMAIN_NAME"
        - name: KOGITO_JOBS_SERVICE_URL
          value: "https://$SERVICE_NAME.$DOMAIN_NAME"
        - name: KOGITO_DATAINDEX_HTTP_URL
          value: "https://$SERVICE_NAME.$DOMAIN_NAME"
        - name: QUARKUS_OIDC_ENABLED
          value: "false"
        - name: QUARKUS_OIDC_AUTH_SERVER_URL
          value: "https://${KEYCLOAK_BASE_URL}/auth/realms/$REALM"
        - name: QUARKUS_HTTP_CORS
          value: "true"
        - name: QUARKUS_HTTP_CORS_ORIGINS
          value: "*"
        - name: QUARKUS_HTTP_CORS_METHODS
          value: "GET,POST,PUT,PATCH,DELETE,OPTIONS"
        - name: QUARKUS_HTTP_CORS_HEADERS
          value: "accept,authorization,content-type,x-requested-with,x-forward-for,content-length,host,origin,referer,Access-Control-Request-Method,Access-Control-Request-Headers"
        - name: QUARKUS_HTTP_CORS_EXPOSED_HEADERS
          value: "Content-Disposition,Content-Type"
        - name: QUARKUS_HTTP_CORS_ACCESS_CONTROL_MAX_AGE
          value: "24H"
        - name: QUARKUS_HTTP_CORS_ACCESS_CONTROL_ALLOW_CREDENTIALS
          value: "true"
EOF

    # Create Service
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: $SERVICE_NAME
spec:
  selector:
    app: $SERVICE_NAME
  ports:
  - port: 80
    targetPort: 8080
EOF

    # Create secure ingress with TLS
    create_secure_ingress "$SERVICE_NAME" 80
}

# Function to deploy task console
deploy_task_console() {
    echo "Deploying task console..."
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $TASK_CONSOLE_NAME
  labels:
    app: $TASK_CONSOLE_NAME
    app.kubernetes.io/part-of: $APP_PART_OF
    app.kubernetes.io/runtime: nodejs
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $TASK_CONSOLE_NAME
  template:
    metadata:
      labels:
        app: $TASK_CONSOLE_NAME
    spec:
      imagePullSecrets:
      - name: registry-credentials
      containers:
      - name: task-console
        image: apache/incubator-kie-kogito-task-console:$VERSION
        imagePullPolicy: Always
        ports:
        - containerPort: 8080
        env:
        - name: RUNTIME_TOOLS_TASK_CONSOLE_KOGITO_ENV_MODE
          value: "PROD"
        - name: RUNTIME_TOOLS_TASK_CONSOLE_DATA_INDEX_ENDPOINT
          value: "https://$SERVICE_NAME.$DOMAIN_NAME/graphql"
        - name: KOGITO_CONSOLES_KEYCLOAK_HEALTH_CHECK_URL
          value: "https://${KEYCLOAK_BASE_URL}/auth/realms/$REALM/.well-known/openid-configuration"
        - name: KOGITO_CONSOLES_KEYCLOAK_URL
          value: "https://${KEYCLOAK_BASE_URL}/auth"
        - name: KOGITO_CONSOLES_KEYCLOAK_REALM
          value: "$REALM"
        - name: KOGITO_CONSOLES_KEYCLOAK_CLIENT_ID
          value: "task-console"
EOF

    # Create Service
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: $TASK_CONSOLE_NAME
spec:
  selector:
    app: $TASK_CONSOLE_NAME
  ports:
  - port: 80
    targetPort: 8080
EOF

    # Create secure ingress with TLS
    create_secure_ingress "$TASK_CONSOLE_NAME" 80
}

# Function to deploy management console
deploy_management_console() {
    echo "Deploying management console..."
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $MGMT_CONSOLE_NAME
  labels:
    app: $MGMT_CONSOLE_NAME
    app.kubernetes.io/part-of: $APP_PART_OF
    app.kubernetes.io/runtime: nodejs
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $MGMT_CONSOLE_NAME
  template:
    metadata:
      labels:
        app: $MGMT_CONSOLE_NAME
    spec:
      imagePullSecrets:
      - name: registry-credentials
      containers:
      - name: management-console
        image: apache/incubator-kie-kogito-management-console:$VERSION
        imagePullPolicy: Always
        ports:
        - containerPort: 8080
        env:
        - name: RUNTIME_TOOLS_MANAGEMENT_CONSOLE_KOGITO_ENV_MODE
          value: "DEV"
        - name: RUNTIME_TOOLS_MANAGEMENT_CONSOLE_DATA_INDEX_ENDPOINT
          value: "https://$SERVICE_NAME.$DOMAIN_NAME/graphql"
        - name: KOGITO_CONSOLES_KEYCLOAK_HEALTH_CHECK_URL
          value: "https://${KEYCLOAK_BASE_URL}/auth/realms/$REALM/.well-known/openid-configuration"
        - name: KOGITO_CONSOLES_KEYCLOAK_URL
          value: "https://${KEYCLOAK_BASE_URL}/auth"
        - name: KOGITO_CONSOLES_KEYCLOAK_REALM
          value: "$REALM"
        - name: KOGITO_CONSOLES_KEYCLOAK_CLIENT_ID
          value: "management-console"
        - name: KOGITO_CONSOLES_KEYCLOAK_CLIENT_SECRET
          value: fBd92XRwPlWDt4CSIIDHSxbcB1w0p3jm
EOF

    # Create Service
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: $MGMT_CONSOLE_NAME
spec:
  selector:
    app: $MGMT_CONSOLE_NAME
  ports:
  - port: 80
    targetPort: 8080
EOF

    # Create secure ingress with TLS
    create_secure_ingress "$MGMT_CONSOLE_NAME" 80
}

# Function to check cert-manager installation
check_cert_manager() {
    echo "Checking if cert-manager is installed..."
    if ! kubectl get deployment -n cert-manager cert-manager &>/dev/null; then
        echo "cert-manager is not installed. Do you want to install it? (y/n)"
        read -r install_cert_manager
        if [[ "$install_cert_manager" =~ ^[Yy]$ ]]; then
            # Install cert-manager
            echo "Installing cert-manager..."
            kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.3/cert-manager.yaml

            # Wait for cert-manager to be ready
            echo "Waiting for cert-manager to be ready..."
            kubectl wait --for=condition=available deployment/cert-manager -n cert-manager --timeout=300s
            kubectl wait --for=condition=available deployment/cert-manager-cainjector -n cert-manager --timeout=300s
            kubectl wait --for=condition=available deployment/cert-manager-webhook -n cert-manager --timeout=300s

            # Create ClusterIssuer for Let's Encrypt
            echo "Creating Let's Encrypt ClusterIssuer..."
            cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@aletyx.dev
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: nginx
EOF
            echo "cert-manager installed and configured successfully."
        else
            echo "cert-manager is required for secure ingress with TLS. Installation skipped."
            echo "Please install cert-manager manually before continuing."
            exit 1
        fi
    else
        echo "cert-manager is already installed."

        # Check if ClusterIssuer exists, create if not
        if ! kubectl get clusterissuer letsencrypt-prod &>/dev/null; then
            echo "Creating Let's Encrypt ClusterIssuer..."
            cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@aletyx.dev
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: nginx
EOF
            echo "ClusterIssuer created successfully."
        else
            echo "Let's Encrypt ClusterIssuer already exists."
        fi
    fi
}

# Main execution starts here
read -p "Input Namespace: " NAMESPACE

# Check and setup cert-manager
check_cert_manager

# Configure registry
configure_for_registry "$NAMESPACE"

# Define the service name
SERVICE_NAME="cc-application-approval"

read -p "Enter your domain name (default: aletyx-labs.aletyx.dev): " DOMAIN_NAME
DOMAIN_NAME=${DOMAIN_NAME:-aletyx-labs.aletyx.dev}
read -p "Enter Keycloak base URL (default: keycloak.aletyx-labs.aletyx.dev): " KEYCLOAK_BASE_URL
KEYCLOAK_BASE_URL=${KEYCLOAK_BASE_URL:-keycloak.aletyx-labs.aletyx.dev}
REALM="jbpm-openshift"
ADMIN_USERNAME="admin"

echo "Keycloak Base URL is: $KEYCLOAK_BASE_URL"
read -p "Confirm service name ($SERVICE_NAME)? [Y/n]: " CONFIRM
if [[ $CONFIRM =~ ^[Nn]$ ]]; then
    read -p "Enter new service name: " SERVICE_NAME
fi

# Derive console names
TASK_CONSOLE_NAME="${SERVICE_NAME}-task-console"
MGMT_CONSOLE_NAME="${SERVICE_NAME}-management-console"
# Define the application group name
APP_PART_OF="${SERVICE_NAME}-app"
# Get Keycloak admin password
read -s -p "Enter Keycloak admin password: " ADMIN_PASSWORD
echo

# Configure Keycloak
echo "Configuring Keycloak..."
get_token
setup_keycloak_realm "$REALM"
create_user "$REALM"

# Deploy PostgreSQL
deploy_postgresql "$SERVICE_NAME"

# Setup clients
setup_client "$REALM" "task-console" "https://${TASK_CONSOLE_NAME}.${DOMAIN_NAME}/*" true
setup_client "$REALM" "management-console" "https://${MGMT_CONSOLE_NAME}.${DOMAIN_NAME}/*" false "fBd92XRwPlWDt4CSIIDHSxbcB1w0p3jm"

# Delete existing deployments if they exist
kubectl delete deployment "$SERVICE_NAME" --ignore-not-found=true
kubectl delete deployment "$TASK_CONSOLE_NAME" --ignore-not-found=true
kubectl delete deployment "$MGMT_CONSOLE_NAME" --ignore-not-found=true

# Deploy all components
deploy_application
deploy_task_console
deploy_management_console

echo "Finalizing deployment"
sleep 45

# Display final URLs
echo "Deployment completed. Application is available at https://$SERVICE_NAME.$DOMAIN_NAME/q/swagger-ui"
echo "Task Console is available at https://$TASK_CONSOLE_NAME.$DOMAIN_NAME"
echo "Management Console is available at https://$MGMT_CONSOLE_NAME.$DOMAIN_NAME"
echo ""
echo "Note: Certificate issuance may take a few minutes. If you encounter SSL errors, please wait for the certificates to be issued."
