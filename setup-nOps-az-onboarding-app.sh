#!/bin/bash

# Variables
subscriptionId=$(az account show --query id -o tsv)
resourceGroupName=${1:-"nops-resource-group"}
storageAccountName=${2-"nopscurexportstorage"}
applicationName=${3:-"nops-app-v1"}
webhook_url=${4:-"https://webhook.site/216f04d8-73b9-476d-9f26-d2946b839f4b"}


# Create the Azure AD application
echo "Creating Azure AD application..."
appId=$(az ad app create \
  --display-name "$applicationName" \
  --query appId -o tsv)
echo "Application ID: $appId"

# Create the service principal
echo "Creating service principal..."
spId=$(az ad sp create --id "$appId" --query id -o tsv)
echo "Service Principal ID: $spId"

# Get the tenant ID
tenantId=$(az account show --query tenantId -o tsv)
echo "Tenant ID: $tenantId"

# Create a client secret
echo "Creating client secret..."
clientSecret=$(az ad app credential reset \
  --id "$appId" \
  --display-name "appSecret" \
  --query password -o tsv)
echo "Client Secret created --$clientSecret"

# Assign the role to the application
echo "Assigning role to the application..."
storageAccountResourceId=$(az storage account show \
  --name "$storageAccountName" \
  --resource-group "$resourceGroupName" \
  --query id -o tsv)

az role assignment create \
  --assignee "$appId" \
  --role "Storage Blob Data Contributor" \
  --scope "$storageAccountResourceId"

echo "Role assignment completed."

# Trigger the webhook (without clientSecret)
echo "Triggering webhook..."
payload=$(cat <<EOF
{
    "tenantId": "$tenantId",
    "clientId": "$appId",
    "storageAccountName": "$storageAccountName",
    "message": "Azure AD application setup completed."
}
EOF
)

curl -X POST -H "Content-Type: application/json" -d "$payload" "$webhook_url"

echo "Webhook triggered successfully."
