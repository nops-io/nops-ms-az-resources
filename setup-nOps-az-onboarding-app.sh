#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# Function to output error messages and exit
error_exit() {
    echo "Error on line $1: $2"
    exit 1
}

# Trap errors and pass them to the error_exit function
trap 'error_exit $LINENO "$BASH_COMMAND"' ERR

# Default values (can be overridden by script arguments)
DEFAULT_RESOURCE_GROUP="nops-onboarding"
DEFAULT_LOCATION="eastus"
DEFAULT_STORAGE_ACCOUNT_PREFIX="nopsstorage"
DEFAULT_CONTAINER_NAME="nops"
DEFAULT_APP_NAME="nops-storage-access-app"
DEFAULT_EXPORT_NAME_CSV="nops-billing-export-csv-"
DEFAULT_EXPORT_NAME_PARQUET="nops-billing-export-parquet-"
DEFAULT_EXPORT_DIR_CSV="billingReportsCSV"
DEFAULT_EXPORT_DIR_PARQUET="billingReportsParquet"
CURRENT_SUBSCRIPTION_ID=$(az account show --query id -o tsv)

# Generate a random suffix to ensure uniqueness
randomSuffix=${11:-$RANDOM}

# Parameters (can be provided as script arguments)
billingAccountId=${1}
if [ -z "$billingAccountId" ]; then
    echo "Error: Billing Account ID must be provided as the first argument."
    exit 1
fi

resourceGroupName=${2:-$DEFAULT_RESOURCE_GROUP}
location=${3:-$DEFAULT_LOCATION}
storageAccountName=${4:-"$DEFAULT_STORAGE_ACCOUNT_PREFIX$randomSuffix"}
containerName=${5:-$DEFAULT_CONTAINER_NAME}
applicationName=${6:-"$DEFAULT_APP_NAME$randomSuffix"}
exportNameCSV=${7:-$DEFAULT_EXPORT_NAME_CSV$randomSuffix}
exportNameParquet=${8:-$DEFAULT_EXPORT_NAME_PARQUET$randomSuffix}
exportDirectoryCSV=${9:-$DEFAULT_EXPORT_DIR_CSV}
exportDirectoryParquet=${10:-$DEFAULT_EXPORT_DIR_PARQUET}

# Clear the screen
clear

# ASCII Art Banner with Provided Art
cat << "EOF"
           $$$$$$\                            $$$$$$\                         
          $$  __$$\                           \_$$  _|                        
$$$$$$$\  $$ /  $$ | $$$$$$\   $$$$$$$\         $$ |  $$$$$$$\   $$$$$$$\     
$$  __$$\ $$ |  $$ |$$  __$$\ $$  _____|        $$ |  $$  __$$\ $$  _____|    
$$ |  $$ |$$ |  $$ |$$ /  $$ |\$$$$$$\          $$ |  $$ |  $$ |$$ /          
$$ |  $$ |$$ |  $$ |$$ |  $$ | \____$$\         $$ |  $$ |  $$ |$$ |          
$$ |  $$ | $$$$$$  |$$$$$$$  |$$$$$$$  |      $$$$$$\ $$ |  $$ |\$$$$$$$\ $$\ 
\__|  \__| \______/ $$  ____/ \_______/       \______|\__|  \__| \_______|\__|
                    $$ |                                                      
                    $$ |                                                      
                    \__|                                                      
EOF

echo ""
echo "This script will perform the following actions:"
echo "1. Create a resource group: '$resourceGroupName'"
echo "2. Create a storage account and container for cost exports"
echo "   - Storage Account Name: $storageAccountName"
echo "   - Container Name: $containerName"
echo "3. Set up two cost and usage exports in CSV and Parquet formats"
echo "   - CSV export with Gzip compression in root directory $exportDirectoryCSV"
echo "   - Parquet export with Snappy compression in root directory $exportDirectoryParquet"
echo "4. Create an Azure AD application and service principal"
echo "   - Application Name: $applicationName"
echo "5. Assign 'Storage Blob Data Contributor' role to the application for above storage account"
echo ""
echo "Billing Account ID: $billingAccountId"
echo "Subscription ID: $currentSubscriptionId"
echo ""
echo "Press Enter to start the setup or Ctrl+C to cancel..."
read -r

echo "Starting Azure setup script..."

# Configure Azure CLI to allow automatic installation of preview extensions
az config set extension.use_dynamic_install=yes_without_prompt
az config set extension.dynamic_install_allow_preview=true

# Install required extension if not already installed
if ! az extension show --name costmanagement &> /dev/null; then
    echo "Installing costmanagement extension..."
    az extension add --name costmanagement
fi

# ---------------------------------------------
# 1. Create Resource Group
# ---------------------------------------------
echo "Creating resource group '$resourceGroupName' in location '$location'..."
az group create --name "$resourceGroupName" --location "$location" 1>/dev/null || {
    echo "Failed to create resource group '$resourceGroupName'"
    exit 1
}
echo "Resource group '$resourceGroupName' created successfully."

# ---------------------------------------------
# 2. Create Storage Account and Container
# ---------------------------------------------
echo "Creating storage account '$storageAccountName'..."
az storage account create \
    --name "$storageAccountName" \
    --resource-group "$resourceGroupName" \
    --location "$location" \
    --sku Standard_LRS \
    --kind StorageV2 \
    --enable-hierarchical-namespace false 1>/dev/null || {
    echo "Failed to create storage account '$storageAccountName'"
    exit 1
}
echo "Storage account '$storageAccountName' created successfully."

echo "Retrieving storage account key..."
storageAccountKey=$(az storage account keys list \
    --resource-group "$resourceGroupName" \
    --account-name "$storageAccountName" \
    --query '[0].value' -o tsv) || {
    echo "Failed to retrieve storage account key for '$storageAccountName'"
    exit 1
}

echo "Creating container '$containerName'..."
az storage container create \
    --name "$containerName" \
    --account-name "$storageAccountName" \
    --account-key "$storageAccountKey" 1>/dev/null || {
        echo "Failed to create container '$containerName'"
        exit 1
    }
echo "Container '$containerName' created successfully."

# ---------------------------------------------
# 2a. Create Cost and Usage Billing Exports
# ---------------------------------------------
echo "Setting up Cost and Usage Billing Exports..."

billingScope="/providers/Microsoft.Billing/billingAccounts/$billingAccountId"

# Get storage account resource ID
storageAccountResourceId=$(az storage account show \
    --name "$storageAccountName" \
    --resource-group "$resourceGroupName" \
    --query id -o tsv) || {
    echo "Failed to retrieve storage account resource ID"
    exit 1
}

# Calculate recurrence period dates
fromDate=$(date -u -d "+1 day" +"%Y-%m-%dT00:00:00Z")  # UTC tomorrow
toDate=$(date -u -d "+10 years +1 day" +"%Y-%m-%dT00:00:00Z")  # 10 years from 'from' date


# Create the request body for the export
cat <<EOF > body.json
{
  "properties": {
    "schedule": {
      "status": "Active",
      "recurrence": "Daily",
      "recurrencePeriod": {
        "from": "$fromDate",
        "to": "$toDate"
      }
    },
    "deliveryInfo": {
      "destination": {
        "resourceId": "$storageAccountResourceId",
        "container": "$containerName",
        "rootFolderPath": "$exportDirectoryCSV",
        "type": "AzureBlob"
      }
    },
    "definition": {
      "type": "FocusCost",
      "timeframe": "MonthToDate",
      "dataSet": {
        "configuration": {
          "columns": [],
          "dataVersion": "1.0",
          "filters": []
        },
        "granularity": "Daily"
      }
    },
    "format": "Csv",
    "partitionData": true,
    "dataOverwriteBehavior": "OverwritePreviousReport",
    "compressionMode": "gzip",
    "exportDescription": ""
  }
}
EOF

# Create the export using az rest
echo "Creating billing export '$exportNameCSV' using REST API..."
az rest --method put \
    --url "https://management.azure.com/$billingScope/providers/Microsoft.CostManagement/exports/$exportNameCSV?api-version=2023-07-01-preview" \
    --body @body.json 1>/dev/null || {
    echo "Failed to create billing export '$exportNameCSV' using REST API"
    exit 1
}
echo "Billing export '$exportNameCSV' created successfully."


# Repeat for Parquet export
# Update the request body for Parquet format
cat <<EOF > body.json
{
  "properties": {
    "schedule": {
      "status": "Active",
      "recurrence": "Daily",
      "recurrencePeriod": {
        "from": "$fromDate",
        "to": "$toDate"
      }
    },
    "deliveryInfo": {
      "destination": {
        "resourceId": "$storageAccountResourceId",
        "container": "$containerName",
        "rootFolderPath": "$exportDirectoryParquet",
        "type": "AzureBlob"
      }
    },
    "definition": {
      "type": "FocusCost",
      "timeframe": "MonthToDate",
      "dataSet": {
        "configuration": {
          "columns": [],
          "dataVersion": "1.0",
          "filters": []
        },
        "granularity": "Daily"
      }
    },
    "format": "Parquet",
    "compressionMode": "Snappy",
    "partitionData": true,
    "dataOverwriteBehavior": "OverwritePreviousReport",
    "exportDescription": ""
  }
}
EOF

echo "Creating billing export '$exportNameParquet' using REST API..."
az rest --method put \
    --url "https://management.azure.com/$billingScope/providers/Microsoft.CostManagement/exports/$exportNameParquet?api-version=2023-07-01-preview" \
    --body @body.json 1>/dev/null || {
    echo "Failed to create billing export '$exportNameParquet' using REST API"
    exit 1
}
echo "Billing export '$exportNameParquet' created successfully."

# Remove the temporary body.json file
rm body.json


# ---------------------------------------------
# 3. Create Azure AD Application Registration
# ---------------------------------------------
echo "Creating Azure AD application '$applicationName'..."
appId=$(az ad app create \
    --display-name "$applicationName" \
    --query appId -o tsv) || {
    echo "Failed to create Azure AD application '$applicationName'"
    exit 1
}
echo "Application ID: $appId"

echo "Creating service principal..."
spId=$(az ad sp create --id "$appId" --query id -o tsv) || {
    echo "Failed to create service principal for app '$applicationName'"
    exit 1
}
echo "Service Principal ID: $spId"

echo "Retrieving tenant ID..."
tenantId=$(az account show --query tenantId -o tsv) || {
    echo "Failed to retrieve tenant ID"
    exit 1
}
echo "Tenant ID: $tenantId"

echo "Creating client secret..."
clientSecret=$(az ad app credential reset \
    --id "$appId" \
    --display-name "appSecret" \
    --query password -o tsv) || {
        echo "Failed to create client secret"
        exit 1
}
echo "Client secret created."

# ---------------------------------------------
# 4. Assign Permissions to Storage Account
# ---------------------------------------------
echo "Assigning 'Storage Blob Data Contributor' role to the application..."

az role assignment create \
    --assignee "$appId" \
    --role "Storage Blob Data Contributor" \
    --scope "$storageAccountResourceId" 1>/dev/null || {
    echo "Failed to assign role to application"
    exit 1
}
echo "Role assigned successfully."

# ---------------------------------------------
# 5. Output Credentials and Billing Account ID
# ---------------------------------------------
echo ""
echo "============================================="
echo "             Setup Completed Successfully"
echo "============================================="
echo ""
echo "Please copy the following details into the nOps UI:"
echo ""
echo "Tenant ID:            $tenantId"
echo "Client ID:            $appId"
echo "Client Secret:        $clientSecret"
echo "Storage Account Name: $storageAccountName"
echo "Billing Account ID:   $billingAccountId"
echo "Subscription ID:      $currentSubscriptionId"
echo ""
echo "Ensure you handle these credentials securely."
echo "============================================="
