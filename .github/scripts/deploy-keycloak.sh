#!/bin/bash
# deploy-keycloak.sh - Handles Keycloak Adoption setup to add users to the realm and redirect URIs

# Source configuration
if [ -f deploy.config ]; then
    source deploy.config
else
    echo "Configuration file not found!"
    exit 1
fi

# Function to extract value from JSON response
extract_json_value() {
    local json="$1"
    local key="$2"
    echo "$json" | grep -o "\"$key\":[^,}]*" | cut -d':' -f2- | tr -d '"' | tr -d ' '
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

# Main execution
REALM="jbpm-openshift"
# Task console and management console names
TASK_CONSOLE_NAME="${SERVICE_NAME}-task-console"
MGMT_CONSOLE_NAME="${SERVICE_NAME}-management-console"
# Define the application group name
APP_PART_OF="${SERVICE_NAME}-app"

# Configure Keycloak
echo "Configuring Keycloak..."
get_token
setup_keycloak_realm "$REALM"
create_user "$REALM"

# Setup clients
setup_client "$REALM" "task-console" "https://${TASK_CONSOLE_NAME}.${DOMAIN_NAME}/*" true
setup_client "$REALM" "management-console" "https://${MGMT_CONSOLE_NAME}.${DOMAIN_NAME}/*" false "fBd92XRwPlWDt4CSIIDHSxbcB1w0p3jm"
