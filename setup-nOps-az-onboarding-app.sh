#!/bin/bash

# Variables
subscriptionId=$(az account show --query id -o tsv)
resourceGroupName="your-resource-group-name"
storageAccountName="your-storage-account-name"
applicationName="your-application-name"
keyVaultName="your-key-vault-name"
webhook_url="https://your-webhook-url.com/endpoint"

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
echo "Client Secret created."

# Store the client secret in Azure Key Vault
echo "Storing client secret in Azure Key Vault..."
az keyvault secret set --vault-name "$keyVaultName" --name "ClientSecret" --value "$clientSecret"

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
