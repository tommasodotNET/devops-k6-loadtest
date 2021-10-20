param (
    ### Azure App Registration con permessi di Contributor sul Resource Group da utilizzare per le risorse Azure (Storage Account, Azure Container Instance) 
    [Parameter(Mandatory = $true)][string]$SubscriptionGuid,
    [Parameter(Mandatory = $true)][string]$TenantId,
    [Parameter(Mandatory = $true)][string]$ClientId,
    [Parameter(Mandatory = $true)][string]$ClientSecret,
    ### Azure resources
    [Parameter(Mandatory = $false)][string]$loadTestResourceGroup = "rg-devops-loadtest", #Il nome del resource group dove creare le risorse Azure 
    [Parameter(Mandatory = $false)][string]$loadTestLocation = "westeurope", #Location per le risorse Azure
    [Parameter(Mandatory = $true)][string]$storageAccountName, #Il nome dello storage account che conterrà i file delle esecuzioni dei test ed i risultati
    [Parameter(Mandatory = $false)][string]$storageShareName = "loadtestrun", #Il nome della file share all'interno dello storage account che effettivamente conterrà i file
    ### Load test resources
    [Parameter(Mandatory = $false)][string]$loadTestIdentifier = $(Get-Date -format "yyyyMMddhhmmss"), #Identificativo univoco per ogni run, usato anche come nome di cartella all'interno della Share dello storage account
    [Parameter(Mandatory = $false)][string]$loadTestK6Script = "$($env:Build_Repository_LocalPath)\src\LoadTests\loadtest.js", #Il percorso file di test di carico in K6
    [Parameter(Mandatory = $false)][string]$loadTestVUS = 30, #Il numero di Virtual Users concorrenti per ogni container
    [Parameter(Mandatory = $false)][string]$loadTestDuration = "20s", #La durata del test in secondi
    ### Containers info
    [Parameter(Mandatory = $false)][string]$K6AgentImage = "loadimpact/k6", # L'immagine K6 da utilizzare, in questo caso la pubblica ufficiale dal DockerHub
    [Parameter(Mandatory = $false)][int]$K6AgentInstances = 1, #Il numero di container da avviare
    [Parameter(Mandatory = $false)][int]$K6AgentCPU = 4, #Il numero di core CPU per ogni Container
    [Parameter(Mandatory = $false)][int]$K6AgentMemory = 4, #La quantità di RAM in Gb per ogni Container
    ### Log Analytics Workspace Ingestion
    [Parameter(Mandatory = $true)][string]$logWorkspaceID, #La Workspace ID della Log Analytics Workspace da utilizzare per l'ingestion dei risultati
    [Parameter(Mandatory = $true)][string]$logWorkspaceKey, #La Primary Key della Log Analytics Workspace 
    [Parameter(Mandatory = $false)][string]$logTableName = "loadtestresult", #Il nome della tabella di Custom Logs dove verranno portati i dati per cui è stata fatta ingestion
    [Parameter(Mandatory = $false)][string]$logFullTableName = "loadtestresultfull", #Il nome della tabella di Custom Logs dove verranno portati i dati FULL per cui è stata fatta ingestion
    [Parameter(Mandatory = $false)][switch]$uploadFullLogs, #Se selezionato lo switch, vengono salvati su Log Analytics anche i dati FULL
    [Parameter(Mandatory = $false)][int]$splitblock = 10000 #Il numero di righe da inviare se i full logs sono superiori a 30MB
)

### FUNCTIONS
#region "Log Analytics Workspace Ingestion Functions"

# Create the function to create the authorization signaturex\
Function Build-Signature ($customerId, $sharedKey, $date, $contentLength, $method, $contentType, $resource) {
    $xHeaders = "x-ms-date:" + $date
    $stringToHash = $method + "`n" + $contentLength + "`n" + $contentType + "`n" + $xHeaders + "`n" + $resource

    $bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
    $keyBytes = [Convert]::FromBase64String($sharedKey)

    $sha256 = New-Object System.Security.Cryptography.HMACSHA256
    $sha256.Key = $keyBytes
    $calculatedHash = $sha256.ComputeHash($bytesToHash)
    $encodedHash = [Convert]::ToBase64String($calculatedHash)
    $authorization = 'SharedKey {0}:{1}' -f $customerId, $encodedHash
    return $authorization
}

# Create the function to create and post the request
Function Post-LogAnalyticsData($customerId, $sharedKey, $body, $logType) {
    $method = "POST"
    $contentType = "application/json"
    $resource = "/api/logs"
    $rfc1123date = [DateTime]::UtcNow.ToString("r")
    $contentLength = $body.Length
    $signature = Build-Signature `
        -customerId $customerId `
        -sharedKey $sharedKey `
        -date $rfc1123date `
        -contentLength $contentLength `
        -method $method `
        -contentType $contentType `
        -resource $resource
    $uri = "https://" + $customerId + ".ods.opinsights.azure.com" + $resource + "?api-version=2016-04-01"

    $headers = @{
        "Authorization"        = $signature;
        "Log-Type"             = $logType;
        "x-ms-date"            = $rfc1123date;
        "time-generated-field" = "";
    }

    $response = Invoke-WebRequest -Uri $uri -Method $method -ContentType $contentType -Headers $headers -Body $body -UseBasicParsing
    return $response.StatusCode

}
#endregion

#region "Storage Account integration function"

# Create the function to download the json file from storage account
Function Download-JSON-From-StorageAccount($loadTestIdentifier, $fileName, $tempDownloadDirectory, $storageAccountName, $storageAccountKey, $storageShareName) {
    $currentDownloadPath = "$tempDownloadDirectory/$fileName"
    $null = az storage file download --account-name $storageAccountName --account-key $storageAccountKey --share-name $storageShareName --path "$loadTestIdentifier/$fileName" --dest $currentDownloadPath
    
    $json = Get-Content $currentDownloadPath | ConvertFrom-Json
    $json | Add-Member NoteProperty "testIdentifier" $loadTestIdentifier
    return $json
}
#endregion

### DECLARATIONS
$AciK6AgentNamePrefix = "aci-loadtest-k6-agent-$loadTestIdentifier"
$AciK6AgentLoadTestHome = "loadtest"

### ACCOUNT LOGIN
if ([string]::IsNullOrWhiteSpace($ClientId) -eq $false) {
    Write-Host "Loggin into Subscription"
    az login --service-principal --username $ClientId --password $ClientSecret --tenant $TenantId
    az account set --subscription $SubscriptionGuid
}
else {
    Write-Host "Using Current Login Context"
}

### STORAGE ACCOUNT RESOURCE GROUP
Write-Host "Creating Storage Account Resource Group"
az group create --location $loadTestLocation --name $loadTestResourceGroup

### STORAGE ACCOUNT WITH SHARE CREATION
Write-Host "Creating Storage Account and Share for K6 test files"
az storage account create --name $storageAccountName --resource-group $loadTestResourceGroup --sku Standard_LRS
az storage share create --name $storageShareName --account-name $storageAccountName --quota 5
$storageAccountKey = $(az storage account keys list --resource-group $loadTestResourceGroup --account-name $storageAccountName --query "[0].value" --output tsv)
az storage directory create --account-name $storageAccountName --account-key $storageAccountKey --share-name $storageShareName --name $loadTestIdentifier
az storage file upload --account-name $storageAccountName --account-key $storageAccountKey --share-name $storageShareName --source $loadTestK6Script --path "$loadTestIdentifier/script.js"
Write-Host "Uploaded test files to storage account"

### AGENTS CONTAINER CREATION
$injectorsStart = Get-Date

Write-Host "Creating agents container(s)"
1..$K6AgentInstances | ForEach-Object -Parallel {   
    Write-Host "Creating K6 agent $_"
    az container create --resource-group $using:loadTestResourceGroup --name "$using:AciK6AgentNamePrefix-$_" --location $using:loadTestLocation `
        --image $using:K6AgentImage --restart-policy Never --cpu $using:K6AgentCPU --memory $using:K6AgentMemory `
        --environment-variables AGENT_NUM=$_ LOAD_TEST_ID=$using:loadTestIdentifier TEST_VUS=$using:loadTestVUS TEST_DURATION=$using:loadTestDuration MY_HOSTNAME="https://devopsconf2021-testapi.azurewebsites.net" `
        --azure-file-volume-account-name $using:storageAccountName --azure-file-volume-account-key $using:storageAccountKey --azure-file-volume-share-name $using:storageShareName --azure-file-volume-mount-path "/$using:AciK6AgentLoadTestHome/" `
        --command-line "k6 run /$using:AciK6AgentLoadTestHome/$using:loadTestIdentifier/script.js --summary-export /$using:AciK6AgentLoadTestHome/$using:loadTestIdentifier/${using:loadTestIdentifier}_${_}_summary.json --out json=/$using:AciK6AgentLoadTestHome/$using:loadTestIdentifier/${using:loadTestIdentifier}_$_.json" 
} -ThrottleLimit 10

$injectorsEnd = Get-Date

### WAIT FOR EXECUTION TO FINISH
do {
    $countRunning = 0;
    1..$K6AgentInstances | ForEach-Object {   
        if ($(az container show -g $loadTestResourceGroup -n "$AciK6AgentNamePrefix-$_" --query "containers[0].instanceView.currentState.state" -o tsv) -eq "Running") {
            $countRunning += 1
        }
    }
    if ($countRunning -gt 0) {
        Write-Host "Load test still running with $countRunning containers"
    }
    Start-Sleep -s 5
}while ($countRunning -gt 0)

Write-Host "Test completed"

#### CLEAN UP THE LOAD TEST RESOURCES
1..$K6AgentInstances | ForEach-Object -Parallel {   
    Write-Host "Removing agent container: $_"
    # az container delete --resource-group $using:loadTestResourceGroup --name "$using:AciK6AgentNamePrefix-$_" --yes
} -ThrottleLimit 10

### IMPORT RESULTS ON LOG WORKSPACE
$tempDownloadDirectory = "$PSScriptRoot\$loadTestIdentifier"
New-Item -ItemType "directory" -Path $tempDownloadDirectory
1..$K6AgentInstances | ForEach-Object {     
    $jsonSummary = Download-JSON-From-StorageAccount -loadTestIdentifier $loadTestIdentifier -fileName "${loadTestIdentifier}_${_}_summary.json" -tempDownloadDirectory $tempDownloadDirectory -storageAccountName $storageAccountName -storageAccountKey $storageAccountKey -storageShareName $storageShareName
    $jsonSummary | Add-Member NoteProperty "containerCurrentNumber" ${_}
    $jsonSummary | Add-Member NoteProperty "containersTestStart" $injectorsStart
    $jsonSummary | Add-Member NoteProperty "containersTestEnd" $injectorsEnd
    $finalJson = ConvertTo-Json @($jsonSummary) -Depth 99 

    Post-LogAnalyticsData -customerId $logWorkspaceID -sharedKey $logWorkspaceKey -body ([System.Text.Encoding]::UTF8.GetBytes($finalJson)) -logType $logTableName 

    if ($uploadFullLogs) {
        $jsonFull = Download-JSON-From-StorageAccount -loadTestIdentifier $loadTestIdentifier -fileName "${loadTestIdentifier}_${_}.json" -tempDownloadDirectory $tempDownloadDirectory -storageAccountName $storageAccountName -storageAccountKey $storageAccountKey -storageShareName $storageShareName    
        $fileSizeMB = (Get-Item "$tempDownloadDirectory/${loadTestIdentifier}_${_}.json").length / 1MB
        Write-Host "Full file $currentFullTestFile size: $fileSizeMb MB"
        if ($fileSizeMB -ge 30) {
            $nelements = $jsonFull.length 
            Write-Host "Number of rows: $nelements"
            $iterations = [Math]::Floor($nelements / $splitblock)
            Write-Host "Number of iterations: $iterations"
            for ($i = 0; $i -le $iterations; $i++) {
                $jsonSplitted = $jsonFull | Select-Object -first $splitblock -skip ($i * $splitblock)
                Write-Host "Sending $($jsonSplitted.length) elements - block $($i*$splitblock)"
                $finalJson = ConvertTo-Json @($jsonSplitted) -Depth 99            
                Post-LogAnalyticsData -customerId $logWorkspaceID -sharedKey $logWorkspaceKey -body ([System.Text.Encoding]::UTF8.GetBytes($finalJson)) -logType $logFullTableName
            }
        }
        else {            
            $finalJson = ConvertTo-Json @($jsonFull) -Depth 99            
            Post-LogAnalyticsData -customerId $logWorkspaceID -sharedKey $logWorkspaceKey -body ([System.Text.Encoding]::UTF8.GetBytes($finalJson)) -logType $logFullTableName
        }

    }
}
Remove-Item $tempDownloadDirectory -Force -Recurse