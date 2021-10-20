param (
    ### ClientID and ClientSecret
    [Parameter(Mandatory = $true)][string]$SubscriptionGuid,
    [Parameter(Mandatory = $true)][string]$TenantId,
    [Parameter(Mandatory = $true)][string]$clientID,
    [Parameter(Mandatory = $true)][string]$clientSecret,
    ### Log Analytics Workspace Ingestion
    [Parameter(Mandatory = $true)][string]$logWorkspaceID, # LogAnalytics Workspace ID
    [Parameter(Mandatory = $true)][string]$logWorkspaceKey, # LogAnalytics Primary Key
    [Parameter(Mandatory = $false)][string]$logTableName = "loadtestresult", # Name of the record type that we're creating
    [Parameter(Mandatory = $false)][string]$logFullTableName = "loadtestresultfull" # Name of the Custom Logs Table in which the FULL datas are going to be imported
)

az config set extension.use_dynamic_install=yes_without_prompt
az login --service-principal --username $ClientId --password $ClientSecret --tenant $TenantId
az account set --subscription $SubscriptionGuid

$queryString = "$($logTableName)_CL | where metrics_http_req_duration_p_95__d > 600 | count"
$queryResult = az monitor log-analytics query -w $logWorkspaceID --analytics-query $queryString -t P3DT12H | ConvertFrom-Json

if($($queryResult).Count -eq 0) {
    Write-Host "Succeed"
} else {
    Write-Host "Fail"
    throw "One or more thresholds have failed."
}