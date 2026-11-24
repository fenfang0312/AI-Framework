#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Generate a README.md index from exported Confluence markdown tree.

.DESCRIPTION
    Scans the exported directory structure and creates a README.md
    with a hierarchical tree of all pages, preserving Confluence hierarchy.

.PARAMETER Dir
    Export output directory. Default: current directory.

.EXAMPLE
    .\Generate-ConfluenceIndex.ps1 -Dir ./exported-docs
#>
param(
    [string]$Dir = "."
)

function Get-FrontmatterTitle {
    param([string]$FilePath)
    $content = [System.IO.File]::ReadAllText($FilePath, [System.Text.Encoding]::UTF8)
    $match = [regex]::Match($content, "^---\n.*?^title:\s*\"([^\"]+)\"\s*\n", 'Singleline,Multiline')
    if ($match.Success) { return $match.Groups[1].Value }
    return [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
}

function Build-Tree {
    param(
        [string]$RootDir,
        [string]$Prefix = "",
        [switch]$IsLast
    )
    $lines = @()
    $items = Get-ChildItem -Path $RootDir -Directory | Sort-Object Name
    $entries = @()
    foreach ($item in $items) {
        $mdFile = Join-Path $item.FullName "$($item.Name).md"
        if (Test-Path $mdFile) {
            $entries += @{ Dir = $item; MdFile = $mdFile }
        }
    }
    
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $entry = $entries[$i]
        $isLastChild = ($i -eq $entries.Count - 1)
        $connector = if ($isLastChild) { "└── " } else { "├── " }
        $title = Get-FrontmatterTitle -FilePath $entry.MdFile
        $relPath = $entry.MdFile.Substring((Resolve-Path $Dir).Path.Length + 1).Replace('\', '/')
        $lines += "$Prefix$connector[$title]($relPath)"
        
        $extension = if ($isLastChild) { "    " } else { "│   " }
        $subLines = Build-Tree -RootDir $entry.Dir.FullName -Prefix "$Prefix$extension" -IsLast:$isLastChild
        $lines += $subLines
    }
    
    return $lines
}

$root = Resolve-Path $Dir
$lines = @("# Exported Confluence Pages", "", "_Generated from: $([System.IO.Path]::GetFileName($root))_", "", "## Page Tree", "")
$tree = Build-Tree -RootDir $root
if ($tree.Count -gt 0) {
    $lines += $tree
} else {
    $lines += "No pages found."
}
$lines += ""

$readme = Join-Path $root "README.md"
[System.IO.File]::WriteAllText($readme, ($lines -join "`n") + "`n", [System.Text.Encoding]::UTF8)
Write-Host "📋 Index written to $readme"
