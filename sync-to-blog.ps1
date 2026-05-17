# sync-to-blog.ps1 - Sync publish:true notes from vault to blog
param()

$vaultPath = 'F:\知识库'
$blogPostsPath = 'F:\weimo-blog\source\_posts'
$blogImgPath = 'F:\weimo-blog\source\img'

Write-Host '=== Sync Vault -> Blog ==='

New-Item -ItemType Directory -Path $blogPostsPath -Force | Out-Null
New-Item -ItemType Directory -Path $blogImgPath -Force | Out-Null

$count = 0
Get-ChildItem -Path $vaultPath -Recurse -Filter '*.md' -Exclude '*_旧版*','*去重备份*' | ForEach-Object {
    $content = Get-Content $_.FullName -Raw -Encoding UTF8
    if ($content -match 'publish:\s*true') {
        $destPath = Join-Path $blogPostsPath $_.Name
        Copy-Item $_.FullName -Destination $destPath -Force
        Write-Host "[OK] $($_.Name)"
        $count++
    }
}

$imgSource = Join-Path $vaultPath 'resource'
if (Test-Path $imgSource) {
    Get-ChildItem -Path $imgSource -File | ForEach-Object {
        Copy-Item $_.FullName -Destination $blogImgPath -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "Synced $count posts"
Write-Host '=== Done ==='
