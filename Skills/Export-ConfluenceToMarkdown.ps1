#!/usr/bin/env pwsh
#Requires -Version 5.1
<#
.SYNOPSIS
    Confluence Recursive Markdown Exporter (PowerShell Edition)
    Export a Confluence page and all its children to Markdown.

.DESCRIPTION
    Uses Invoke-RestMethod to call Confluence REST API and regex-based
    HTML-to-Markdown conversion. Downloads draw.io diagrams and handles
    common Confluence macros (info, warning, note, code, jira, panel, etc.).
    No Python dependencies required.

.PARAMETER Url
    Confluence base URL. For Cloud: https://yourcompany.atlassian.net/wiki
    For Data Center: https://wiki.company.com (no /wiki suffix)

.PARAMETER PageId
    Root page ID to start export.

.PARAMETER Token
    API Token (Cloud) or Personal Access Token (DC).

.PARAMETER Email
    Email address (required for Cloud auth).

.PARAMETER Output
    Output directory. Default: ./confluence-export

.PARAMETER DataCenter
    Switch to use Data Center PAT authentication.

.EXAMPLE
    .\Export-ConfluenceToMarkdown.ps1 `
        -Url "https://company.atlassian.net/wiki" `
        -PageId "123456" `
        -Token "ABCD..." `
        -Email "you@company.com" `
        -Output "./exported-docs"
#>
param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$PageId,
    [Parameter(Mandatory)][string]$Token,
    [string]$Email,
    [string]$Output = "./confluence-export",
    [switch]$DataCenter
)

# ─── Validate ──────────────────────────────────────────────────────────────
if (-not $DataCenter -and -not $Email) {
    Write-Error "--Email is required for Confluence Cloud."
    exit 1
}

# Normalize URL
$BaseUrl = $Url.TrimEnd('/')
if ($BaseUrl -match 'atlassian\.net$' -and $BaseUrl -notmatch '/wiki$') {
    $BaseUrl += '/wiki'
}

# Resolve/create output dir
if (Test-Path $Output) {
    $OutputDir = (Resolve-Path $Output).Path
} else {
    $OutputDir = (New-Item -ItemType Directory -Force -Path $Output).FullName
}

$ExportedCount = 0
$DownloadedImages = 0

# ─── Auth ──────────────────────────────────────────────────────────────────
if ($DataCenter) {
    # PAT: username = token, password = empty
    $AuthPair = "$Token`:"
} else {
    $AuthPair = "$Email`:$Token"
}
$AuthBase64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($AuthPair))
$Headers = @{
    "Authorization" = "Basic $AuthBase64"
    "Accept"        = "application/json"
    "Content-Type"  = "application/json"
}

# ─── Helpers ───────────────────────────────────────────────────────────────
function Invoke-ConfluenceApi {
    param(
        [string]$Path,
        [hashtable]$Query = @{},
        [switch]$Binary
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("$BaseUrl$Path")
    if ($Query.Count -gt 0) {
        $pairs = foreach ($k in $Query.Keys) { "$k=$([Uri]::EscapeDataString($Query[$k]))" }
        [void]$sb.Append("?")
        [void]$sb.Append(($pairs -join "&"))
    }
    $uri = $sb.ToString()
    try {
        if ($Binary) {
            $resp = Invoke-RestMethod -Uri $uri -Headers $Headers -Method GET -TimeoutSec 30
            return $resp
        } else {
            $resp = Invoke-RestMethod -Uri $uri -Headers $Headers -Method GET -TimeoutSec 30
            return $resp
        }
    } catch {
        Write-Host "❌ API failed: $uri — $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

function ConvertTo-SafeFileName {
    param([string]$Name)
    $safe = $Name -replace '[<>:":"/\|?*\x00-\x1f]', '_'
    $safe = $safe.Trim('. ')
    if ($safe.Length -gt 100) { $safe = $safe.Substring(0, 100) }
    if ([string]::IsNullOrEmpty($safe)) { $safe = 'untitled' }
    return $safe
}

# ─── Get page attachments ─────────────────────────────────────────────────
function Get-PageAttachments {
    param([string]$PageId)
    $attachments = @()
    $path = "/rest/api/content/$PageId/child/attachment"
    $query = @{ limit = '100' }
    while ($path) {
        $data = Invoke-ConfluenceApi -Path $path -Query $query
        $attachments += $data.results
        $path = if ($data._links -and $data._links.next) { $data._links.next } else { $null }
        $query = @{}  # next already has params
    }
    return $attachments
}

# ─── Download attachment binary ────────────────────────────────────────────
function Download-Attachment {
    param(
        [PSCustomObject]$Attachment,
        [string]$SaveDir
    )
    # Try _links.download first
    $downloadUrl = $Attachment._links.download
    if (-not $downloadUrl) {
        # Fallback: construct URL from download path pattern
        $downloadUrl = $Attachment._links.self + "/download"
    }
    # Make absolute URL
    if ($downloadUrl -notmatch '^https?://') {
        $downloadUrl = "$BaseUrl$downloadUrl"
    }

    $fileName = $Attachment.title
    $safeFileName = ConvertTo-SafeFileName -Name $fileName
    $savePath = Join-Path $SaveDir $safeFileName

    try {
        # Use web client for binary download (more reliable than Invoke-RestMethod for bytes)
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("Authorization", "Basic $AuthBase64")
        $bytes = $wc.DownloadData($downloadUrl)
        [System.IO.File]::WriteAllBytes($savePath, $bytes)
        $script:DownloadedImages++
        Write-Host "    🖼️  Downloaded: $safeFileName" -ForegroundColor Cyan
        return $safeFileName
    } catch {
        Write-Host "    ⚠️  Failed to download $fileName`: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
}

# ─── Macro extraction helper ──────────────────────────────────────────────
function Extract-MacroParameter {
    param([string]$MacroBody, [string]$ParamName)
    $match = [regex]::Match($MacroBody, "ac:name=\"$ParamName\"[^>]*>([^<]*)</ac:parameter>", 'Singleline,IgnoreCase')
    if ($match.Success) { return $match.Groups[1].Value.Trim() }
    return $null
}

function Extract-MacroBodyText {
    param([string]$MacroBody)
    # Remove all <ac:*> tags, keep inner text
    $text = [regex]::Replace($MacroBody, '<ac:[^>]*>', '')
    $text = [regex]::Replace($text, '</ac:[^>]*>', '')
    # Strip remaining HTML
    $text = [regex]::Replace($text, '<[^>]+>', '')
    return $text.Trim()
}

# ─── HTML → Markdown (regex-based, with drawio + macro support) ──────────
function Convert-HtmlToMarkdown {
    param(
        [string]$Html,
        [string]$PageTitle,
        [hashtable]$DrawioMap,       # diagramName -> downloaded filename
        [string]$PageUrl,           # for Jira links
        [string]$SpaceKey           # for Jira links
    )

    if ([string]::IsNullOrWhiteSpace($Html)) { return '' }

    $md = $Html

    # 1. Strip <style> and <script>
    $md = [regex]::Replace($md, '<style[^>]*>.*?</style>', '', 'Singleline,IgnoreCase')
    $md = [regex]::Replace($md, '<script[^>]*>.*?</script>', '', 'Singleline,IgnoreCase')

    # 2. Handle drawio macro → Markdown image reference
    $md = [regex]::Replace($md, '<ac:structured-macro[^>]*ac:name="drawio"[^>]*>(.*?)</ac:structured-macro>', {
        param($m)
        $macroBody = $m.Groups[1].Value
        $diagramName = Extract-MacroParameter -MacroBody $macroBody -ParamName 'diagramName'
        if ($diagramName -and $DrawioMap.ContainsKey($diagramName)) {
            $fileName = $DrawioMap[$diagramName]
            return "`n![$diagramName](images/$fileName)`n"
        } elseif ($diagramName) {
            return "`n<!-- draw.io diagram: $diagramName (attachment not found) -->`n"
        } else {
            return "`n<!-- draw.io diagram (no name) -->`n"
        }
    }, 'Singleline,IgnoreCase')

    # 3. Handle info / warning / note / tip macros → blockquote
    $md = [regex]::Replace($md, '<ac:structured-macro[^>]*ac:name="(info|warning|note|tip)"[^>]*>(.*?)</ac:structured-macro>', {
        param($m)
        $macroName = $m.Groups[1].Value
        $macroBody = $m.Groups[2].Value
        # Extract title if present
        $title = Extract-MacroParameter -MacroBody $macroBody -ParamName 'title'
        $bodyText = Extract-MacroBodyText -MacroBody $macroBody
        $prefix = switch ($macroName) {
            'info'    { 'ℹ️ ' }
            'warning' { '⚠️ ' }
            'note'    { '📝 ' }
            'tip'     { '💡 ' }
            default   { '' }
        }
        $header = if ($title) { "$prefix**$title**`n`n" } else { "" }
        $lines = ($bodyText -split "`n" | ForEach-Object { "> $_" })
        return "`n$header> $($lines -join "`n> ")`n"
    }, 'Singleline,IgnoreCase')

    # 4. Handle panel macro → blockquote with title
    $md = [regex]::Replace($md, '<ac:structured-macro[^>]*ac:name="panel"[^>]*>(.*?)</ac:structured-macro>', {
        param($m)
        $macroBody = $m.Groups[1].Value
        $title = Extract-MacroParameter -MacroBody $macroBody -ParamName 'title'
        $bodyText = Extract-MacroBodyText -MacroBody $macroBody
        $header = if ($title) { "> **$title**`n`n" } else { "" }
        $lines = ($bodyText -split "`n" | ForEach-Object { "> $_" })
        return "`n$header> $($lines -join "`n> ")`n"
    }, 'Singleline,IgnoreCase')

    # 5. Handle code macro → fenced code block
    $md = [regex]::Replace($md, '<ac:structured-macro[^>]*ac:name="code"[^>]*>(.*?)</ac:structured-macro>', {
        param($m)
        $macroBody = $m.Groups[1].Value
        $language = Extract-MacroParameter -MacroBody $macroBody -ParamName 'language'
        $bodyText = Extract-MacroBodyText -MacroBody $macroBody
        $lang = if ($language) { $language } else { "" }
        return "`n```$lang`n$bodyText`n```" + "`n"
    }, 'Singleline,IgnoreCase')

    # 6. Handle jira macro → link or reference
    $md = [regex]::Replace($md, '<ac:structured-macro[^>]*ac:name="jira"[^>]*>(.*?)</ac:structured-macro>', {
        param($m)
        $macroBody = $m.Groups[1].Value
        $issueKey = Extract-MacroParameter -MacroBody $macroBody -ParamName 'key'
        $server = Extract-MacroParameter -MacroBody $macroBody -ParamName 'server'
        if ($issueKey) {
            $jiraUrl = if ($server) { "$server/browse/$issueKey" } else { "https://jira.atlassian.net/browse/$issueKey" }
            return "`n🎫 Jira: [$issueKey]($jiraUrl)`n"
        } else {
            $bodyText = Extract-MacroBodyText -MacroBody $macroBody
            return "`n<!-- jira macro -->`n"
        }
    }, 'Singleline,IgnoreCase')

    # 7. Handle children macro → list of child pages (we'll fill this later if needed)
    $md = [regex]::Replace($md, '<ac:structured-macro[^>]*ac:name="children"[^>]*>(.*?)</ac:structured-macro>', {
        param($m)
        return "`n<!-- children pages list (see directory structure) -->`n"
    }, 'Singleline,IgnoreCase')

    # 8. Handle excerpt macro → extract text
    $md = [regex]::Replace($md, '<ac:structured-macro[^>]*ac:name="excerpt"[^>]*>(.*?)</ac:structured-macro>', {
        param($m)
        $macroBody = $m.Groups[1].Value
        $bodyText = Extract-MacroBodyText -MacroBody $macroBody
        if ($bodyText) {
            return "`n> **Excerpt:** $bodyText`n"
        } else {
            return "`n<!-- excerpt macro -->`n"
        }
    }, 'Singleline,IgnoreCase')

    # 9. Handle other structured macros → generic fallback
    $md = [regex]::Replace($md, '<ac:structured-macro[^>]*ac:name="([^"]*)"[^>]*>(.*?)</ac:structured-macro>', {
        param($m)
        $macroName = $m.Groups[1].Value
        $macroBody = $m.Groups[2].Value
        $bodyText = Extract-MacroBodyText -MacroBody $macroBody
        if ($bodyText) {
            return "`n<!-- confluence-macro: $macroName -->`n> $bodyText"
        } else {
            return "`n<!-- confluence-macro: $macroName -->`n"
        }
    }, 'Singleline,IgnoreCase')

    # 10. Handle inline macros (ac:inline-macro)
    $md = [regex]::Replace($md, '<ac:inline-macro[^>]*ac:name="([^"]*)"[^>]*>(.*?)</ac:inline-macro>', {
        param($m)
        $macroName = $m.Groups[1].Value
        $bodyText = Extract-MacroBodyText -MacroBody $m.Groups[2].Value
        return "`n<!-- inline-macro: $macroName --> $bodyText`n"
    }, 'Singleline,IgnoreCase')

    # 11. Strip remaining <ac:*> tags
    $md = [regex]::Replace($md, '</?ac:[^>]*>', '')

    # 12. Headings
    $md = [regex]::Replace($md, '<h1[^>]*>(.*?)</h1>', "`n# $1`n", 'Singleline,IgnoreCase')
    $md = [regex]::Replace($md, '<h2[^>]*>(.*?)</h2>', "`n## $1`n", 'Singleline,IgnoreCase')
    $md = [regex]::Replace($md, '<h3[^>]*>(.*?)</h3>', "`n### $1`n", 'Singleline,IgnoreCase')
    $md = [regex]::Replace($md, '<h4[^>]*>(.*?)</h4>', "`n#### $1`n", 'Singleline,IgnoreCase')
    $md = [regex]::Replace($md, '<h5[^>]*>(.*?)</h5>', "`n##### $1`n", 'Singleline,IgnoreCase')
    $md = [regex]::Replace($md, '<h6[^>]*>(.*?)</h6>', "`n###### $1`n", 'Singleline,IgnoreCase')

    # 13. Paragraphs
    $md = [regex]::Replace($md, '<p[^>]*>(.*?)</p>', "`n$1`n", 'Singleline,IgnoreCase')

    # 14. Line breaks
    $md = $md -replace '<br\s*/?>', "`n"

    # 15. Bold / Italic
    $md = $md -replace '<strong[^>]*>(.*?)</strong>', '**$1**'
    $md = $md -replace '<b[^>]*>(.*?)</b>', '**$1**'
    $md = $md -replace '<em[^>]*>(.*?)</em>', '*$1*'
    $md = $md -replace '<i[^>]*>(.*?)</i>', '*$1*'

    # 16. Links
    $md = [regex]::Replace($md, '<a[^>]*href="([^"]*)"[^>]*>(.*?)</a>', '[$2]($1)', 'Singleline,IgnoreCase')

    # 17. Images (regular, non-drawio)
    $md = [regex]::Replace($md, '<img[^>]*src="([^"]*)"[^>]*alt="([^"]*)"[^>]*/>', '![$2]($1)', 'IgnoreCase')
    $md = [regex]::Replace($md, '<img[^>]*alt="([^"]*)"[^>]*src="([^"]*)"[^>]*/>', '![$1]($2)', 'IgnoreCase')
    $md = [regex]::Replace($md, '<img[^>]*src="([^"]*)"[^>]*/>', '![]($1)', 'IgnoreCase')

    # 18. Lists
    $md = $md -replace '<ul[^>]*>', "`n"
    $md = $md -replace '</ul>', "`n"
    $md = $md -replace '<ol[^>]*>', "`n"
    $md = $md -replace '</ol>', "`n"
    $md = $md -replace '<li[^>]*>', '- '
    $md = $md -replace '</li>', "`n"

    # 19. Code blocks (non-macro <pre>)
    $md = [regex]::Replace($md, '<pre[^>]*>(.*?)</pre>', "````n$1`n```", 'Singleline,IgnoreCase')
    $md = $md -replace '<code[^>]*>(.*?)</code>', '`$1`'

    # 20. Tables (basic)
    $md = [regex]::Replace($md, '<table[^>]*>(.*?)</table>', {
        param($m)
        $tableHtml = $m.Groups[1].Value
        $rows = [regex]::Matches($tableHtml, '<tr[^>]*>(.*?)</tr>', 'Singleline,IgnoreCase')
        $lines = @()
        $isHeader = $true
        foreach ($row in $rows) {
            $cells = [regex]::Matches($row.Groups[1].Value, '<t[dh][^>]*>(.*?)</t[dh]>', 'Singleline,IgnoreCase')
            $cellTexts = @()
            foreach ($c in $cells) {
                $inner = $c.Groups[1].Value
                $inner = [regex]::Replace($inner, '<[^>]+>', '').Trim()
                $cellTexts += $inner
            }
            $lines += "| " + ($cellTexts -join ' | ') + " |"
            if ($isHeader) {
                $sep = "|" + (" --- |" * $cells.Count)
                $lines += $sep
                $isHeader = $false
            }
        }
        return "`n" + ($lines -join "`n") + "`n"
    }, 'Singleline,IgnoreCase')

    # 21. Blockquotes
    $md = [regex]::Replace($md, '<blockquote[^>]*>(.*?)</blockquote>', {
        param($m)
        $inner = $m.Groups[1].Value
        $lines = ($inner -split "`n" | ForEach-Object { "> $_" })
        return "`n" + ($lines -join "`n") + "`n"
    }, 'Singleline,IgnoreCase')

    # 22. Horizontal rules
    $md = $md -replace '<hr\s*/?>', "`n---`n"

    # 23. Strip remaining HTML tags
    $md = [regex]::Replace($md, '<[^>]+>', '')

    # 24. Decode common HTML entities
    $md = $md -replace '&nbsp;', ' '
    $md = $md -replace '&lt;', '<'
    $md = $md -replace '&gt;', '>'
    $md = $md -replace '&amp;', '&'
    $md = $md -replace '&quot;', '"'
    $md = $md -replace '&#39;', "'"
    $md = $md -replace '&mdash;', '—'
    $md = $md -replace '&ndash;', '–'

    # 25. Collapse blank lines
    $md = [regex]::Replace($md, "`n{3,}", "`n`n")

    return $md.Trim()
}

# ─── Build YAML frontmatter ────────────────────────────────────────────────
function Build-Frontmatter {
    param([PSCustomObject]$Page)

    $title = if ($Page.title) { $Page.title } else { 'Untitled' }
    $pageId = $Page.id
    $space = if ($Page.space -and $Page.space.key) { $Page.space.key } else { '' }
    $spaceName = if ($Page.space -and $Page.space.name) { $Page.space.name } else { '' }
    $version = if ($Page.version -and $Page.version.number) { $Page.version.number } else { 1 }
    $created = if ($Page.history -and $Page.history.createdDate) { $Page.history.createdDate } else { '' }
    $modified = if ($Page.history -and $Page.history.lastUpdated -and $Page.history.lastUpdated.when) { $Page.history.lastUpdated.when } else { '' }
    $author = if ($Page.history -and $Page.history.createdBy -and $Page.history.createdBy.displayName) { $Page.history.createdBy.displayName } else { '' }
    $ancestors = if ($Page.ancestors) { $Page.ancestors } else { @() }
    $parentId = if ($ancestors.Count -gt 0) { $ancestors[-1].id } else { $null }
    $parentTitle = if ($ancestors.Count -gt 0) { $ancestors[-1].title } else { $null }

    $urlSuffix = if ($DataCenter) { "pages/viewpage.action?pageId=$pageId" } else { "spaces/$space/pages/$pageId" }
    $pageUrl = "$BaseUrl/$urlSuffix"

    $lines = @('---')
    $lines += "title: `"$title`""
    $lines += 'confluence:'
    $lines += "  id: `"$pageId`""
    $lines += "  space: `"$space`""
    $lines += "  space_name: `"$spaceName`""
    $lines += '  type: page'
    $lines += "  version: $version"
    $lines += "confluence_url: `"$pageUrl`""
    $lines += "author: `"$author`""
    $lines += "created: `"$created`""
    $lines += "modified: `"$modified`""
    if ($parentId) {
        $lines += 'parent:'
        $lines += "  id: `"$parentId`""
        $lines += "  title: `"$parentTitle`""
    }
    $lines += '---'
    return ($lines -join "`n")
}

# ─── Export Page (recursive, with draw.io + macro support) ──────────────
function Export-Page {
    param(
        [string]$PageId,
        [string]$ParentDir,
        [int]$Depth = 0
    )

    $indent = '  ' * $Depth
    Write-Host "$($indent)📄 Fetching page $PageId..."

    # Fetch page
    try {
        $page = Invoke-ConfluenceApi -Path "/rest/api/content/$PageId" -Query @{
            expand = 'body.storage,space,version,ancestors,history'
        }
    } catch {
        Write-Host "$($indent)⚠️ Skipping page $PageId (fetch failed)" -ForegroundColor Yellow
        return
    }

    $title = if ($page.title) { $page.title } else { 'Untitled' }
    $safeTitle = ConvertTo-SafeFileName -Name $title

    # Create directory
    $pageDir = Join-Path $ParentDir $safeTitle
    New-Item -ItemType Directory -Force -Path $pageDir | Out-Null

    # ─── Download page attachments (draw.io images) ──────────────────────
    $drawioMap = @{}
    try {
        $attachments = Get-PageAttachments -PageId $PageId
        if ($attachments.Count -gt 0) {
            Write-Host "$($indent)  📎 $($attachments.Count) attachment(s) found" -ForegroundColor DarkGray
            $imagesDir = Join-Path $pageDir "images"
            New-Item -ItemType Directory -Force -Path $imagesDir | Out-Null

            foreach ($att in $attachments) {
                $fileName = $att.title
                # Look for draw.io preview images: *.drawio.png or *.drawio.svg
                if ($fileName -match '\.drawio\.(png|svg)$') {
                    $downloaded = Download-Attachment -Attachment $att -SaveDir $imagesDir
                    if ($downloaded) {
                        $diagramBase = $fileName -replace '\.drawio\.(png|svg)$', ''
                        $drawioMap[$diagramBase] = $downloaded
                    }
                }
            }
        }
    } catch {
        Write-Host "$($indent)  ⚠️ Attachment fetch failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # Convert content
    $htmlBody = if ($page.body -and $page.body.storage -and $page.body.storage.value) { $page.body.storage.value } else { '' }
    $spaceKey = if ($page.space -and $page.space.key) { $page.space.key } else { '' }
    $urlSuffix = if ($DataCenter) { "pages/viewpage.action?pageId=$PageId" } else { "spaces/$spaceKey/pages/$PageId" }
    $pageUrl = "$BaseUrl/$urlSuffix"
    $markdown = Convert-HtmlToMarkdown -Html $htmlBody -PageTitle $title -DrawioMap $drawioMap -PageUrl $pageUrl -SpaceKey $spaceKey
    $frontmatter = Build-Frontmatter -Page $page

    # Write file
    $mdFile = Join-Path $pageDir "$safeTitle.md"
    $content = "$frontmatter`n`n# $title`n`n$markdown`n"
    [System.IO.File]::WriteAllText($mdFile, $content, [System.Text.Encoding]::UTF8)

    $script:ExportedCount++
    Write-Host "$($indent)✅ $title → $mdFile" -ForegroundColor Green

    # Fetch children
    $children = @()
    $childPath = "/rest/api/content/$PageId/child/page"
    $childQuery = @{ limit = '100'; expand = 'space' }
    while ($childPath) {
        $childData = Invoke-ConfluenceApi -Path $childPath -Query $childQuery
        $children += $childData.results
        $childPath = if ($childData._links -and $childData._links.next) { $childData._links.next } else { $null }
        $childQuery = @{}  # next already has params
    }

    if ($children.Count -gt 0) {
        Write-Host "$($indent)  ↳ $($children.Count) child page(s) found"
        foreach ($child in $children) {
            Export-Page -PageId $child.id -ParentDir $pageDir -Depth ($Depth + 1)
        }
    }
}

# ─── Main ──────────────────────────────────────────────────────────────────
Export-Page -PageId $PageId -ParentDir $OutputDir -Depth 0

Write-Host "`n🏁 Done! Exported $ExportedCount page(s), downloaded $DownloadedImages draw.io image(s) to $OutputDir"
