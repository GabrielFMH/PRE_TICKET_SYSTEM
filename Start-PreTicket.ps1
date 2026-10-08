# Flujo preticket: crea el User Story, la rama en los repos elegidos y clona cada una.
# Requiere git en el PATH. Completa config.ps1 antes de ejecutarlo.
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir "config.ps1")

function Test-ConfigValue {
    param(
        [string]$Name,
        [AllowEmptyString()][string]$Value
    )
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "Falta la variable $Name en config.ps1."
    }
}

function Get-TfsErrorMessage {
    param($ErrorRecord)
    $detail = $ErrorRecord.ErrorDetails.Message
    if (-not [string]::IsNullOrWhiteSpace($detail)) {
        return $detail
    }
    return $ErrorRecord.Exception.Message
}

function Invoke-Tfs {
    param(
        [ValidateSet("Get", "Post")]
        [string]$Method = "Get",
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [string]$Body,
        [string]$ContentType = "application/json"
    )

    $params = @{
        Method  = $Method
        Uri     = $Uri
        Headers = $script:TfsHeaders
    }
    if (-not $script:UsePat) {
        $params.UseDefaultCredentials = $true
    }
    if ($PSBoundParameters.ContainsKey("Body")) {
        $params.Body = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $params.ContentType = $ContentType
    }

    try {
        $response = Invoke-WebRequest @params -UseBasicParsing
    } catch {
        throw ("TFS respondió un error en {0}: {1}" -f $Uri, (Get-TfsErrorMessage $_))
    }

    $content = $response.Content
    if ($content -is [byte[]]) {
        $content = [System.Text.Encoding]::UTF8.GetString($content)
    }
    $json = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$content)) {
        $json = $content | ConvertFrom-Json
    }
    return [pscustomobject]@{
        Json    = $json
        Headers = $response.Headers
    }
}

function Get-TfsValues {
    param($Json)
    if ($null -eq $Json) {
        return @()
    }
    if ($Json.PSObject.Properties.Name -contains "value") {
        return @($Json.value)
    }
    return @($Json)
}

function Get-TfsPaged {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    $items = @()
    $next = $Uri
    while ($next) {
        $response = Invoke-Tfs -Uri $next
        $items += Get-TfsValues $response.Json
        $token = $response.Headers["x-ms-continuationtoken"]
        if ([string]::IsNullOrWhiteSpace([string]$token)) {
            $next = $null
        } else {
            $separator = "?"
            if ($Uri.Contains("?")) {
                $separator = "&"
            }
            $next = "{0}{1}continuationToken={2}" -f $Uri, $separator, [uri]::EscapeDataString([string]$token)
        }
    }
    return @($items)
}

function Get-AllRepositories {
    $projectsUri = "{0}/_apis/projects?api-version={1}" -f $script:CollectionUrl, $script:ApiVersion
    Write-Host "Consultando proyectos..."
    $projects = @(Get-TfsPaged -Uri $projectsUri | Where-Object { -not [string]::IsNullOrWhiteSpace($_.name) })
    if ($projects.Count -eq 0) {
        throw "La colección no devolvió proyectos."
    }
    Write-Host ("Proyectos: {0}" -f $projects.Count)

    $repos = @()
    $index = 0
    foreach ($project in $projects) {
        $index++
        Write-Host ("Repositorios {0}/{1}: {2}" -f $index, $projects.Count, $project.name)
        $encodedProject = [uri]::EscapeDataString($project.name)
        $reposUri = "{0}/{1}/_apis/git/repositories?api-version={2}" -f $script:CollectionUrl, $encodedProject, $script:ApiVersion
        try {
            $projectRepos = @(Get-TfsPaged -Uri $reposUri)
        } catch {
            Write-Warning ("No se pudieron leer los repos de '{0}': {1}" -f $project.name, $_.Exception.Message)
            continue
        }
        foreach ($repo in $projectRepos) {
            if ([string]::IsNullOrWhiteSpace($repo.id) -or [string]::IsNullOrWhiteSpace($repo.name)) {
                continue
            }
            $repos += [pscustomobject]@{
                Id             = [string]$repo.id
                Name           = [string]$repo.name
                ProjectName    = [string]$project.name
                RemoteUrl      = [string]$repo.remoteUrl
                DefaultBranch  = [string]$repo.defaultBranch
            }
        }
    }

    return @($repos | Sort-Object ProjectName, Name)
}

function Test-BranchName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }
    if ($Name.StartsWith("-") -or $Name.StartsWith("/") -or $Name.EndsWith(".") -or $Name.EndsWith(".lock") -or $Name.EndsWith("/")) {
        return $false
    }
    if ($Name.Contains("..") -or $Name.Contains("//") -or $Name.Contains("@{") -or $Name.Contains("\")) {
        return $false
    }
    return $Name -notmatch '[~^:?*\[\]\s"]'
}

function Read-Ticket {
    while ($true) {
        $ticket = (Read-Host "Nombre del ticket").Trim()
        if ([string]::IsNullOrWhiteSpace($ticket)) {
            Write-Host "Escribe el nombre completo. Ejemplo: 2026_03467A_AB Subida de archivos desembolso"
            continue
        }
        $code = ($ticket -split "\s+", 2)[0]
        if (-not (Test-BranchName $code)) {
            Write-Host "El primer texto del ticket no es un nombre de rama válido: $code"
            continue
        }
        return [pscustomobject]@{
            Title = $ticket
            Code  = $code
        }
    }
}

function New-UserStory {
    param([string]$Title)
    $encodedProject = [uri]::EscapeDataString($script:WorkItemProject)
    $encodedType = [uri]::EscapeDataString("$" + $script:WorkItemType)
    $uri = "{0}/{1}/_apis/wit/workitems/{2}?api-version={3}" -f $script:CollectionUrl, $encodedProject, $encodedType, $script:ApiVersion
    $field = @{
        op    = "add"
        path  = "/fields/System.Title"
        value = $Title
    } | ConvertTo-Json -Compress
    $body = "[$field]"
    Write-Host "Creando $($script:WorkItemType)..."
    $response = Invoke-Tfs -Method Post -Uri $uri -Body $body -ContentType "application/json-patch+json; charset=utf-8"
    if ($null -eq $response.Json -or $null -eq $response.Json.id) {
        throw "TFS no devolvió el id del work item."
    }
    return $response.Json
}

function Select-Repositories {
    param($Repos)

    $selected = New-Object System.Collections.Generic.List[object]
    $selectedIds = @{}

    while ($true) {
        Write-Host ""
        if ($selected.Count -gt 0) {
            Write-Host ("Seleccionados ({0}):" -f $selected.Count)
            foreach ($item in $selected) {
                Write-Host ("  - {0} / {1}" -f $item.ProjectName, $item.Name)
            }
            Write-Host ""
        }
        Write-Host "Buscar repositorio (vacío = todos). Escribe 'listo' para continuar."
        $query = (Read-Host "Buscar").Trim()
        if ($query -eq "listo") {
            if ($selected.Count -eq 0) {
                Write-Host "Elige al menos un repositorio."
                continue
            }
            break
        }

        $filtered = @($Repos)
        if (-not [string]::IsNullOrWhiteSpace($query)) {
            $pattern = "*{0}*" -f [System.Management.Automation.WildcardPattern]::Escape($query)
            $filtered = @($Repos | Where-Object {
                $_.Name -like $pattern -or $_.ProjectName -like $pattern
            })
        }
        if ($filtered.Count -eq 0) {
            Write-Host "Sin coincidencias."
            continue
        }

        $number = 1
        foreach ($repo in $filtered) {
            $mark = ""
            if ($selectedIds.ContainsKey($repo.Id)) {
                $mark = " [ya elegido]"
            }
            Write-Host ("  [{0}] {1} / {2}{3}" -f $number, $repo.ProjectName, $repo.Name, $mark)
            $number++
        }

        $choice = (Read-Host "Números separados por coma (Enter = otra búsqueda)").Trim()
        if ([string]::IsNullOrWhiteSpace($choice)) {
            continue
        }
        foreach ($part in ($choice -split "[,\s]+" | Where-Object { $_ })) {
            if ($part -notmatch "^\d+$") {
                Write-Host "  No es un número: $part"
                continue
            }
            $idx = [int]$part
            if ($idx -lt 1 -or $idx -gt $filtered.Count) {
                Write-Host "  Número fuera de rango: $part"
                continue
            }
            $repo = $filtered[$idx - 1]
            if ($selectedIds.ContainsKey($repo.Id)) {
                continue
            }
            [void]$selected.Add($repo)
            $selectedIds[$repo.Id] = $true
            Write-Host ("  + {0} / {1}" -f $repo.ProjectName, $repo.Name)
        }
    }

    Write-Host ""
    Write-Host ("Se creará la rama y se descargarán {0} repositorio(s)." -f $selected.Count)
    $confirm = (Read-Host "Continuar? (s/n)").Trim()
    if ($confirm -notmatch "^[sS]$") {
        return
    }
    return @($selected.ToArray())
}

function ConvertTo-RefName {
    param([string]$Name)
    if ($Name -like "refs/heads/*") {
        return $Name
    }
    return "refs/heads/$Name"
}

function Get-RefObjectId {
    param(
        $Repo,
        [string]$RefName
    )
    $fullName = ConvertTo-RefName $RefName
    $filter = [uri]::EscapeDataString($fullName.Substring("refs/".Length))
    $encodedProject = [uri]::EscapeDataString($Repo.ProjectName)
    $uri = "{0}/{1}/_apis/git/repositories/{2}/refs?filter={3}&api-version={4}" -f `
        $script:CollectionUrl, $encodedProject, $Repo.Id, $filter, $script:ApiVersion
    $response = Invoke-Tfs -Uri $uri
    $match = @(Get-TfsValues $response.Json | Where-Object { $_.name -eq $fullName })
    if ($match.Count -eq 0) {
        return $null
    }
    return [string]$match[0].objectId
}

function New-RepoBranch {
    param(
        $Repo,
        [string]$BranchName,
        [string]$NewObjectId
    )
    $encodedProject = [uri]::EscapeDataString($Repo.ProjectName)
    $uri = "{0}/{1}/_apis/git/repositories/{2}/refs?api-version={3}" -f `
        $script:CollectionUrl, $encodedProject, $Repo.Id, $script:ApiVersion
    $ref = @{
        name        = "refs/heads/$BranchName"
        oldObjectId = "0000000000000000000000000000000000000000"
        newObjectId = $NewObjectId
    } | ConvertTo-Json -Compress
    $response = Invoke-Tfs -Method Post -Uri $uri -Body "[$ref]" -ContentType "application/json"
    $updates = @(Get-TfsValues $response.Json)
    if ($updates.Count -gt 0 -and $updates[0].PSObject.Properties.Name -contains "success" -and -not $updates[0].success) {
        $message = [string]$updates[0].customMessage
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = "TFS rechazó la creación de la rama."
        }
        throw $message
    }
}

function ConvertTo-SafeFolderName {
    param([string]$Name)
    $safe = $Name -replace '[\\/:*?"<>|]', "_"
    $safe = $safe.Trim().TrimEnd(".")
    if ([string]::IsNullOrWhiteSpace($safe)) {
        return "repo"
    }
    return $safe
}

function Get-CloneFolderName {
    param(
        $Repo,
        $Selected
    )
    $safeName = ConvertTo-SafeFolderName $Repo.Name
    $sameName = @($Selected | Where-Object { (ConvertTo-SafeFolderName $_.Name) -eq $safeName })
    if ($sameName.Count -gt 1) {
        return "{0}__{1}" -f (ConvertTo-SafeFolderName $Repo.ProjectName), $safeName
    }
    return $safeName
}

function Invoke-GitClone {
    param(
        $Repo,
        [string]$BranchName,
        [string]$Destination
    )
    $gitArgs = @()
    if ($script:UsePat) {
        $basic = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":" + $script:Pat))
        $gitArgs += @("-c", "http.extraHeader=Authorization: Basic $basic")
    }
    $gitArgs += @("clone", "--branch", $BranchName, "--single-branch", $Repo.RemoteUrl, $Destination)
    & git @gitArgs
    if ($LASTEXITCODE -ne 0) {
        throw "git clone terminó con código $LASTEXITCODE."
    }
}

function Publish-SelectedRepositories {
    param(
        $Selected,
        [string]$BranchName,
        [string]$TicketRoot
    )

    $results = @()
    foreach ($repo in $Selected) {
        $folderName = Get-CloneFolderName -Repo $repo -Selected $Selected
        $destination = Join-Path $TicketRoot $folderName
        $status = "creada"
        Write-Host ""
        Write-Host ("{0} / {1}" -f $repo.ProjectName, $repo.Name)

        try {
            $existing = Get-RefObjectId -Repo $repo -RefName $BranchName
            if ($existing) {
                $status = "ya existía"
                Write-Host "  La rama ya existe. Se descarga sin volver a crearla."
            } else {
                $sourceName = $repo.DefaultBranch
                if (-not [string]::IsNullOrWhiteSpace($script:SourceBranch)) {
                    $sourceName = $script:SourceBranch
                }
                if ([string]::IsNullOrWhiteSpace($sourceName)) {
                    throw "El repositorio no tiene rama por defecto y SourceBranch está vacío."
                }
                $sourceId = Get-RefObjectId -Repo $repo -RefName $sourceName
                if ([string]::IsNullOrWhiteSpace($sourceId)) {
                    throw "No se encontró la rama origen '$sourceName'."
                }
                New-RepoBranch -Repo $repo -BranchName $BranchName -NewObjectId $sourceId
                Write-Host "  Rama creada desde $(ConvertTo-RefName $sourceName)."
            }

            if (Test-Path -LiteralPath $destination) {
                $status = "$status; carpeta ya existía"
                Write-Host "  La carpeta ya existe: $destination"
            } else {
                if (-not (Test-Path -LiteralPath $TicketRoot)) {
                    New-Item -ItemType Directory -Path $TicketRoot -Force | Out-Null
                }
                Write-Host "  Clonando en $destination"
                if ($script:UsePat) {
                    $previousPrompt = $env:GIT_TERMINAL_PROMPT
                    $env:GIT_TERMINAL_PROMPT = "0"
                }
                try {
                    Invoke-GitClone -Repo $repo -BranchName $BranchName -Destination $destination
                } finally {
                    if ($script:UsePat) {
                        $env:GIT_TERMINAL_PROMPT = $previousPrompt
                    }
                }
                Write-Host "  Descarga lista."
            }
            $results += [pscustomobject]@{
                Project = $repo.ProjectName
                Repo    = $repo.Name
                Branch  = $status
                Path    = $destination
                Error   = ""
            }
        } catch {
            Write-Host ("  Error: {0}" -f $_.Exception.Message)
            $results += [pscustomobject]@{
                Project = $repo.ProjectName
                Repo    = $repo.Name
                Branch  = "error"
                Path    = $destination
                Error   = $_.Exception.Message
            }
        }
    }
    return @($results)
}

try {
Test-ConfigValue -Name "TfsBaseUrl" -Value $TfsBaseUrl
Test-ConfigValue -Name "Collection" -Value $Collection
Test-ConfigValue -Name "WorkItemProject" -Value $WorkItemProject
Test-ConfigValue -Name "LocalRoot" -Value $LocalRoot
if ([string]::IsNullOrWhiteSpace($WorkItemType)) {
    $WorkItemType = "User Story"
}
if ([string]::IsNullOrWhiteSpace($ApiVersion)) {
    $ApiVersion = "6.0"
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "No se encontró git en el PATH."
}

$script:UsePat = -not [string]::IsNullOrWhiteSpace($Pat)
$script:Pat = $Pat
$script:ApiVersion = $ApiVersion
$script:WorkItemProject = $WorkItemProject
$script:WorkItemType = $WorkItemType
$script:SourceBranch = $SourceBranch
$script:CollectionUrl = "{0}/{1}" -f $TfsBaseUrl.TrimEnd("/"), $Collection.Trim("/")
$script:TfsHeaders = @{}
if ($script:UsePat) {
    $basic = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":" + $Pat))
    $script:TfsHeaders = @{ Authorization = "Basic $basic" }
}

$repositories = @(Get-AllRepositories)
if ($repositories.Count -eq 0) {
    throw "No se encontró ningún repositorio Git en la colección."
}
Write-Host ("Repositorios encontrados: {0}" -f $repositories.Count)

$ticket = Read-Ticket
$workItem = New-UserStory -Title $ticket.Title
Write-Host ("User Story creado: #{0}" -f $workItem.id)

$selected = @(Select-Repositories -Repos $repositories)
if ($selected.Count -eq 0) {
    Write-Host ""
    Write-Host ("Operación cancelada. El User Story #{0} ya fue creado." -f $workItem.id)
    return
}

$ticketRoot = Join-Path $LocalRoot $ticket.Code
$results = @(Publish-SelectedRepositories -Selected $selected -BranchName $ticket.Code -TicketRoot $ticketRoot)

Write-Host ""
Write-Host "Resumen"
Write-Host ("User Story: #{0} {1}" -f $workItem.id, $ticket.Title)
foreach ($result in $results) {
    if ([string]::IsNullOrWhiteSpace($result.Error)) {
        Write-Host ("  {0} / {1}: rama {2} -> {3}" -f $result.Project, $result.Repo, $result.Branch, $result.Path)
    } else {
        Write-Host ("  {0} / {1}: {2}" -f $result.Project, $result.Repo, $result.Error)
    }
}
if (@($results | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Error) }).Count -gt 0) {
    exit 1
}
} catch {
    Write-Host $_.Exception.Message
    exit 1
}
