$json = $input | Out-String | ConvertFrom-Json
$cmd = $json.tool_input.command
if ($cmd -notmatch 'project deploy start') { exit 0 }

$sf = "C:\Program Files\sf\bin\sf.cmd"

# Extract --target-org or -o value from the deploy command
$targetOrg = $null
if ($cmd -match '(?:--target-org|-o)\s+(\S+)') {
    $targetOrg = $Matches[1]
}
# Fall back to the default org if no --target-org flag was supplied
if (-not $targetOrg) {
    $defaultResult = & $sf org display --json 2>&1 | Out-String | ConvertFrom-Json
    $targetOrg = $defaultResult.result.username
}
if (-not $targetOrg) {
    Write-Host "post-deploy-activate: could not determine target org, skipping"
    exit 0
}

# Query FlexiPage Id via Tooling API against the same org
$result = & $sf data query --query "SELECT Id FROM FlexiPage WHERE DeveloperName = 'QueryStationRecordPage' LIMIT 1" --use-tooling-api --target-org $targetOrg --json 2>&1 | Out-String | ConvertFrom-Json
$pageId = $result.result.records[0].Id

if (-not $pageId) {
    Write-Host "post-deploy-activate: QueryStationRecordPage not found in $targetOrg, skipping"
    exit 0
}

$tmpApex = [System.IO.Path]::GetTempFileName() + ".apex"
"ConnectApi.RecordLayout.setDefaultRecordPage('QueryStation__c', '$pageId');" | Out-File -FilePath $tmpApex -Encoding utf8

& $sf apex run --file $tmpApex --target-org $targetOrg 2>&1 | Out-Null
Remove-Item $tmpApex -ErrorAction SilentlyContinue

Write-Host "post-deploy-activate: QueryStationRecordPage ($pageId) activated on $targetOrg"
