param(
  [int]$CampaignId = 2313,
  [int]$GoalAmount = 340000,

  # GitHub
  [string]$Owner = "sheikhnobi",
  [string]$Repo  = "sheikhnobi.github.io",
  [string]$Branch = "main",
  [string]$PathInRepo = "status.json"
)

$ErrorActionPreference = "Stop"

$token = "xxxx"   # <-- your PAT
if ([string]::IsNullOrWhiteSpace($token)) { throw "Missing GitHub token" }

# HARD GUARD: PathInRepo must not be empty
if ([string]::IsNullOrWhiteSpace($PathInRepo)) { $PathInRepo = "status.json" }
$PathInRepo = $PathInRepo.TrimStart("/")

$mohidApi = "https://us.mohid.co/ma/worcester/wic/masjid/widget/api/index/?m=ajax_get_campaign_card_instant_details&_campaign_id=$CampaignId"

function Parse-Money($v) {
  if ($null -eq $v) { return 0 }
  $s = [string]$v -replace '[^0-9\.]', ''
  if ([string]::IsNullOrWhiteSpace($s)) { return 0 }
  $n = 0.0
  [double]::TryParse($s, [ref]$n) | Out-Null
  return $n
}

function Get-PropOrDefault($obj, $propName, $defaultVal) {
  if ($null -eq $obj) { return $defaultVal }
  $p = $obj.PSObject.Properties[$propName]
  if ($null -eq $p -or $null -eq $p.Value) { return $defaultVal }
  return $p.Value
}

function To-Base64Utf8($s) {
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($s)
  [System.Convert]::ToBase64String($bytes)
}

# ---- GitHub HttpClient wrapper (PowerShell 5.1 reliable) ----
Add-Type -AssemblyName System.Net.Http
$client = New-Object System.Net.Http.HttpClient
$client.DefaultRequestHeaders.UserAgent.ParseAdd("WIC-TV-Dashboard/1.0")
$client.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json")
$client.DefaultRequestHeaders.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", $token)

function Invoke-GitHub([string]$Method, [string]$Url, [string]$JsonBody) {
  $req = New-Object System.Net.Http.HttpRequestMessage($Method, $Url)
  if ($JsonBody) {
    $req.Content = New-Object System.Net.Http.StringContent($JsonBody, [System.Text.Encoding]::UTF8, "application/json")
  }
  $resp = $client.SendAsync($req).GetAwaiter().GetResult()
  $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
  return [pscustomobject]@{
    Ok         = $resp.IsSuccessStatusCode
    StatusCode = [int]$resp.StatusCode
    Body       = $body
  }
}

# If direct GET fails, list root and find sha for status.json
function Find-Sha-From-RootListing([string]$Owner, [string]$Repo, [string]$Branch, [string]$FileName) {
  $listUrl = "https://api.github.com/repos/$Owner/$Repo/contents?ref=$Branch"
  $list = Invoke-GitHub "GET" $listUrl $null
  if (-not $list.Ok) { return $null }

  $items = $list.Body | ConvertFrom-Json
  if ($items -and -not ($items -is [System.Array])) { $items = @($items) }

  foreach ($it in $items) {
    if ($it.type -eq "file" -and $it.name -eq $FileName -and $it.sha) {
      return [string]$it.sha
    }
  }
  return $null
}

try {
  Write-Host "Fetching MOHID campaign $CampaignId..."

  $resp = Invoke-RestMethod -Method Get -Uri $mohidApi -Headers @{ "User-Agent"="WIC-TV-Dashboard/1.0" } -TimeoutSec 20
  $det = $resp
  if ($resp -is [System.Array] -and $resp.Count -gt 0) { $det = $resp[0] }

  $raised = Parse-Money (Get-PropOrDefault $det "total_amount" 0)

  $contributorsRaw = Get-PropOrDefault $det "total_contributors" 0
  $pledgersRaw     = Get-PropOrDefault $det "total_pledgers" 0
  $pctRaw          = Get-PropOrDefault $det "total_amount_percentage" 0

  $contributors = 0
  [int]::TryParse(([string]$contributorsRaw), [ref]$contributors) | Out-Null

  $pledgers = 0
  [int]::TryParse(([string]$pledgersRaw), [ref]$pledgers) | Out-Null

  $pct = 0.0
  [double]::TryParse(([string]$pctRaw), [ref]$pct) | Out-Null
  if ($pct -le 0 -and $GoalAmount -gt 0) { $pct = ($raised / $GoalAmount) * 100.0 }

  $remaining = [math]::Max(0, ($GoalAmount - $raised))

  $payloadObj = [ordered]@{
    campaign_id  = $CampaignId
    raised       = $raised
    goal         = $GoalAmount
    remaining    = $remaining
    pct          = [math]::Round($pct, 2)
    contributors = $contributors
    pledgers     = $pledgers
    updated_utc  = (Get-Date).ToUniversalTime().ToString("o")
    source       = "mohid ajax_get_campaign_card_instant_details"
  }

  $json = ($payloadObj | ConvertTo-Json -Depth 5)

  # ----------------------------
  # GitHub GET current file to obtain SHA
  # ----------------------------
  #$getUrl = "https://api.github.com/repos/$Owner/$Repo/contents/$PathInRepo?ref=$Branch"
  $getUrl = "https://api.github.com/repos/$Owner/$Repo/contents/$($PathInRepo.TrimStart('/'))?ref=$Branch"
  Write-Host "Checking existing file on GitHub ($getUrl)..."

  $get = Invoke-GitHub "GET" $getUrl $null
  Write-Host "GET status: $($get.StatusCode)"

  $existingSha = $null
  $existingContent = $null

  if ($get.Ok) {
    $existingObj = $get.Body | ConvertFrom-Json
    $existingSha = [string]$existingObj.sha

    if ($existingObj.content) {
      $b64 = ($existingObj.content -replace "`n","")
      $bytes = [System.Convert]::FromBase64String($b64)
      $existingContent = [System.Text.Encoding]::UTF8.GetString($bytes)
    }
  } elseif ($get.StatusCode -ne 404) {
    throw "GitHub GET failed ($($get.StatusCode)): $($get.Body)"
  }

  # If sha is missing but file exists (your 422 scenario), pull sha from root listing
  if ([string]::IsNullOrWhiteSpace($existingSha)) {
    $fileNameOnly = [System.IO.Path]::GetFileName($PathInRepo)
    $existingSha = Find-Sha-From-RootListing $Owner $Repo $Branch $fileNameOnly
  }

  # Optional skip if unchanged
  if ($existingContent -ne $null -and $existingContent.Trim() -eq $json.Trim()) {
    Write-Host "No change in status.json. Skipping update."
    exit 0
  }

  # ----------------------------
  # GitHub PUT create/update
  # ----------------------------
  $putUrl = "https://api.github.com/repos/$Owner/$Repo/contents/$PathInRepo"
  $commitMsg = "Update fundraiser status $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

  $bodyObj = [ordered]@{
    message = $commitMsg
    content = (To-Base64Utf8 $json)
    branch  = $Branch
  }
  if (-not [string]::IsNullOrWhiteSpace($existingSha)) { $bodyObj.sha = $existingSha }

  $bodyJson = ($bodyObj | ConvertTo-Json -Depth 6)

  Write-Host "Updating $PathInRepo on branch '$Branch' (sha included: $([bool]$existingSha))..."
  $put = Invoke-GitHub "PUT" $putUrl $bodyJson

  if (-not $put.Ok) {
    throw "GitHub PUT failed ($($put.StatusCode)): $($put.Body)"
  }

  Write-Host "Success: status.json updated on GitHub."
  exit 0
}
catch {
  Write-Host "ERROR: $($_.Exception.Message)"
  exit 1
}