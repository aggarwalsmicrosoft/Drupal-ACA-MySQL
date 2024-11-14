# PowerShell script for Drupal 10 on Azure Container Apps
# Database: Azure MySQL
Set-PSDebug -Trace 1
# Set variables
$RG = "NS_Drupal_Replatform"
$LOCATION = "centralus"
$ACRNAME = "netscoutdemoacr"
$REGISTRY = "$ACRNAME.azurecr.io"
$ACAENV = "acacms-env"
$SA = "cmsstorageaccount"
$FS = "cmsfileshare"
$STORAGE_MOUNT_NAME = "mydrupalstoragemount"
$CONTAINER_APP_NAME = "mydrupalapp"
# MySQL Configuration
$RANDOM_NUMBER = Get-Random -Minimum 1000 -Maximum 9999
$DB_SERVER_NAME = "acaMySqlServerNetscout$RANDOM_NUMBER"  # Unique server name
$DRUPAL_DB_HOST = "$DB_SERVER_NAME.mysql.database.azure.com"
$DB_SERVER_SKU = "Standard_B1ms"
$DRUPAL_DB_USER = "myAdmin"
$DRUPAL_DB_PASSWORD = "Abe@12superSecret"
$DRUPAL_DB_NAME = "drupal_db"
$MIN_REPLICAS = "1"
$MAX_REPLICAS = "3"
$SUBSCRIPTION = ""
$DRUPAL_DB_CERT = "/var/www/html/sites/default/files/DigiCertGlobalRootCA.crt.pem"
# Log in to Azure with the service principal
Write-Output "Logging in to Azure..."
az login
Write-Output "Azure login successful."
# Set the Azure subscription
az account set --subscription $SUBSCRIPTION
Write-Output "Subscription set to $SUBSCRIPTION."
# Create a resource group if it doesn't exist
$rgExists = az group exists --name $RG
if (-not $rgExists) {
    Write-Output "Creating resource group $RG in $LOCATION..."
    az group create --name $RG --location $LOCATION
    Write-Output "Resource group $RG created successfully."
} else {
    Write-Output "Resource group $RG already exists."
}
# Create ACR if it doesn't exist
$acrExists = az acr show --name $ACRNAME --resource-group $RG --query "name" -o tsv 2>$null
if (-not $acrExists) {
    Write-Output "Creating Azure Container Registry (ACR) $ACRNAME..."
    az acr create --resource-group $RG --name $ACRNAME --sku Basic
    az acr update -n $ACRNAME --admin-enabled true
    Write-Output "ACR $ACRNAME created and admin access enabled."
} else {
    Write-Output "ACR $ACRNAME already exists."
}
# Create an Azure Container App Environment if it doesn't exist
$appEnvExists = az containerapp env show --name $ACAENV --resource-group $RG --query "name" -o tsv 2>$null
if (-not $appEnvExists) {
    Write-Output "Creating Azure Container App Environment $ACAENV..."
    az containerapp env create --name $ACAENV --resource-group $RG --location $LOCATION
    Write-Output "Container App Environment $ACAENV created successfully."
} else {
    Write-Output "Container App Environment $ACAENV already exists."
}
# Retrieve the environment ID
$ENVIRONMENT_ID = $(az containerapp env show --name $ACAENV --resource-group $RG --query "id" --output tsv)
Write-Output "Environment ID for ACAENV: $ENVIRONMENT_ID"
# Create an Azure Storage Account if it doesn't exist
$SARAND = $SA.ToLower() + $RANDOM_NUMBER
$storageAccountExists = az storage account check-name --name $SARAND --query "nameAvailable" -o tsv
if ($storageAccountExists -eq "true") {
    Write-Output "Creating Azure Storage Account $SARAND..."
    az storage account create --name $SARAND --resource-group $RG --location $LOCATION --sku Standard_LRS --kind StorageV2 --enable-large-file-share --query provisioningState
    Write-Output "Storage Account $SARAND created successfully."
} else {
    Write-Output "Storage Account $SARAND already exists or is not available."
}
# Get the account key
$account_key = az storage account keys list --resource-group $RG --account-name $SARAND --query "[0].value" --output tsv
# Create a File Share if it doesn't exist
$share_exists = az storage share exists --name $FS --account-name $SARAND --account-key $account_key --query exists
if ($share_exists -eq "false") {
    Write-Output "Creating file share $FS in storage account $SARAND..."
    az storage share create --name $FS --account-name $SARAND --account-key $account_key
    # Verify Azure Files is enabled in Storage Account
    az storage share-rm list --resource-group $RG --storage-account $SARAND
    Write-Output "File share $FS created successfully."
} else {
    Write-Output "File share $FS already exists in storage account $SARAND."
}
# Configure storage for the Container App Environment
az containerapp env storage set --access-mode ReadWrite --azure-file-account-name $SARAND --azure-file-account-key $account_key --azure-file-share-name $FS --storage-name $STORAGE_MOUNT_NAME --name $ACAENV --resource-group $RG --output table
# Create a MySQL flexible server if it doesn't exist
$mysqlServerExists = az mysql flexible-server show --name $DB_SERVER_NAME --resource-group $RG --query "name" -o tsv 2>$null
if (-not $mysqlServerExists) {
    Write-Output "Creating MySQL flexible server $DB_SERVER_NAME in $LOCATION..."
    az mysql flexible-server create --resource-group $RG --name $DB_SERVER_NAME --location $LOCATION --admin-user $DRUPAL_DB_USER --admin-password $DRUPAL_DB_PASSWORD --sku-name $DB_SERVER_SKU --storage-size 32
    Write-Output "MySQL server $DB_SERVER_NAME created successfully."
} else {
    Write-Output "MySQL server $DB_SERVER_NAME already exists."
}
# Create the MySQL database if it doesn't exist
$dbExists = az mysql flexible-server db show --server-name $DB_SERVER_NAME --resource-group $RG --database-name $DRUPAL_DB_NAME --query "name" -o tsv 2>$null
if (-not $dbExists) {
    Write-Output "Creating database $DRUPAL_DB_NAME on server $DB_SERVER_NAME..."
    az mysql flexible-server db create --resource-group $RG --server-name $DB_SERVER_NAME --database-name $DRUPAL_DB_NAME
    Write-Output "Database $DRUPAL_DB_NAME created successfully on server $DB_SERVER_NAME."
} else {
    Write-Output "Database $DRUPAL_DB_NAME already exists on server $DB_SERVER_NAME."
}
# Define the YAML for the container app
$storageMountYaml = @"
location: $LOCATION
name: $CONTAINER_APP_NAME
resourceGroup: $RG
type: Microsoft.App/containerApps
properties:
 managedEnvironmentId: $ENVIRONMENT_ID
 configuration:
   activeRevisionsMode: Single
   dapr: null
   ingress:
     external: true
     allowInsecure: false
     targetPort: 80
     traffic:
       - latestRevision: true
         weight: 100
     transport: Auto
   registries: null
   secrets:
     - name: drupal-db-name
       value: $DRUPAL_DB_NAME
     - name: drupal-db-password
       value: $DRUPAL_DB_PASSWORD
     - name: drupal-db-user
       value: $DRUPAL_DB_USER
     - name: drupal-db-host
       value: $DRUPAL_DB_HOST
     - name: drupal-db-cert
       value: $DRUPAL_DB_CERT
   service: null
 template:
   revisionSuffix: ''
   containers:
     - image: drupal:10.2
       name: drupal
       env:
       - name: MYSQL_DATABASE
         secretRef: drupal-db-name
       - name: MYSQL_PASSWORD
         secretRef: drupal-db-password
       - name: MYSQL_USER
         secretRef: drupal-db-user
       - name: MYSQL_PORT
         value: '3306'
       - name: MYSQL_HOST
         secretRef: drupal-db-host
       - name: MYSQL_SSL_CA
         secretRef: drupal-db-cert
       resources:
         cpu: 2
         ephemeralStorage: 8Gi
         memory: 4Gi
       volumeMounts:
       - mountPath: /var/www/html/sites/default/files
         volumeName: mystoragemount
   volumes:
   - name: mystoragemount
     storageName: $STORAGE_MOUNT_NAME
     storageType: AzureFile
   scale:
     minReplicas: $MIN_REPLICAS
     maxReplicas: $MAX_REPLICAS
"@
$storageMountYaml | Out-File -FilePath aca-DoNotCheckIn.yaml -Encoding utf8
Write-Output "YAML configuration written to aca-DoNotCheckIn.yaml."
az containerapp create `
-n $CONTAINER_APP_NAME `
-g $RG `
--environment $ACAENV `
--yaml aca-DoNotCheckIn.yaml `

Write-Output "Container App $CONTAINER_APP_NAME created successfully." 

# Get Container App FQDN  
$FQDN = az containerapp show --name $CONTAINER_APP_NAME --resource-group $RG --query properties.configuration.ingress.fqdn --output tsv  
Write-Output "Container App is available at: $FQDN"  
