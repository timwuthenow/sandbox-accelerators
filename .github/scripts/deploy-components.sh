#!/bin/bash
# deploy-components.sh - Handles PostgreSQL and application deployments

# Source configuration
if [ -f deploy.config ]; then
    source deploy.config
else
    echo "Configuration file not found!"
    exit 1
fi

# Function to create secure ingress with TLS certificate
create_secure_ingress() {
    local service_name=$1
    local service_port=$2
    local host="${service_name}-${NAMESPACE}.${DOMAIN_NAME}"

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
}

deploy_postgresql() {
    local db_name="$1-postgresql"
    echo "Deploying PostgreSQL database..."

    # Cleanup existing PostgreSQL resources
    echo "Cleaning up any existing PostgreSQL resources..."
	kubectl delete deployment $db_name -n $NAMESPACE --ignore-not-found=true
	kubectl delete service $db_name -n $NAMESPACE --ignore-not-found=true
	kubectl delete pvc $db_name-pvc -n $NAMESPACE --ignore-not-found=true
    sleep 10  # Wait for resources to be deleted

    # Create PostgreSQL secrets
    kubectl create secret generic postgresql-credentials -n $NAMESPACE \
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
  namespace: $NAMESPACE
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
  namespace: $NAMESPACE
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
  namespace: $NAMESPACE
spec:
  selector:
    app: $db_name
  ports:
  - port: 5432
    targetPort: 5432
EOF

    # Wait for PostgreSQL to be ready
    echo "Waiting for PostgreSQL to be ready..."
    kubectl wait --for=condition=available deployment/$db_name --timeout=300s -n $NAMESPACE || true

    echo "PostgreSQL deployment completed"
}

# Function to deploy application with Nexus registry
deploy_application() {
    echo "Deploying main application using Nexus registry..."

    # Set the application image name
    APP_IMAGE="${REGISTRY_URL}/${NAMESPACE}/${SERVICE_NAME}:latest"
    echo "Application will be deployed as: $APP_IMAGE"

    # Deploy the application
    echo "Deploying application..."
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $SERVICE_NAME
  namespace: $NAMESPACE
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
  namespace: $NAMESPACE
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
    VERSION="10.0.0"
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $TASK_CONSOLE_NAME
  namespace: $NAMESPACE
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
  namespace: $NAMESPACE
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
    VERSION="10.0.0"
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $MGMT_CONSOLE_NAME
  namespace: $NAMESPACE
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
  namespace: $NAMESPACE
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

# Create Nexus registry credentials
create_registry_credentials() {
    echo "Creating Docker registry credentials..."
    kubectl -n $NAMESPACE create secret docker-registry registry-credentials \
      --docker-server=$REGISTRY_URL \
      --docker-username=$NEXUS_USERNAME \
      --docker-password=$NEXUS_PASSWORD \
      --docker-email=admin@example.com \
      --dry-run=client -o yaml | kubectl apply -f -
}

# Main execution starts here
TASK_CONSOLE_NAME="${SERVICE_NAME}-task-console"
MGMT_CONSOLE_NAME="${SERVICE_NAME}-management-console"
APP_PART_OF="${SERVICE_NAME}-app"
REGISTRY_URL="${REGISTRY_URL:-docker.aletyx-labs.aletyx.dev}"
REALM="jbpm-openshift"

# Create registry credentials
create_registry_credentials

# Deploy PostgreSQL
deploy_postgresql "$SERVICE_NAME"

# Deploy application components
deploy_application
deploy_task_console
deploy_management_console

echo "Deployment completed!"
echo "Swagger UI: https://${SERVICE_NAME}.${DOMAIN_NAME}/q/swagger-ui"
echo "Task Console: https://${TASK_CONSOLE_NAME}.${DOMAIN_NAME}"
echo "Management Console: https://${MGMT_CONSOLE_NAME}.${DOMAIN_NAME}"
