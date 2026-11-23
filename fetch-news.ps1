# Lấy tin từ các nguồn RSS trong sources.json, gộp tin trùng, ghi ra site/news.json
# Chạy được trên Windows PowerShell 5.1 và PowerShell 7 (GitHub Actions).
param(
  [string]$SourcesFile = (Join-Path $PSScriptRoot 'sources.json'),
  [string]$OutFile     = (Join-Path $PSScriptRoot 'site/news.json'),
  [int]$KeepHours      = 48
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$handler = New-Object System.Net.Http.HttpClientHandler
$handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
$http = New-Object System.Net.Http.HttpClient($handler)
$http.Timeout = [TimeSpan]::FromSeconds(25)
$http.DefaultRequestHeaders.UserAgent.ParseAdd('Mozilla/5.0 (compatible; loc-tin/1.0)')
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Get-Text($node) {
  if ($null -eq $node) { return '' }
  if ($node -is [string]) { return $node.Trim() }
  if ($node -is [System.Xml.XmlNode]) { return $node.InnerText.Trim() }
  if ($node -is [array]) { return (Get-Text $node[0]) }
  return "$node".Trim()
}

function Remove-Html([string]$s) {
  if (-not $s) { return '' }
  $s = [regex]::Replace($s, '<[^>]+>', ' ')
  $s = [System.Net.WebUtility]::HtmlDecode($s)
  return ([regex]::Replace($s, '\s+', ' ')).Trim()
}

function ConvertTo-Date([string]$s) {
  if (-not $s) { return $null }
  $s = $s.Trim() -replace '\bGMT([+-]\d)', '$1' -replace '\s(GMT|UTC|UT|Z)$', ' +0000'
  $s = [regex]::Replace($s, '([+-])(\d{2})(\d{2})$', '$1$2:$3')
  $s = [regex]::Replace($s, '\s([+-])(\d{2})$', ' $1$2:00')   # "+07" -> "+07:00"
  if ($s -notmatch '([+-]\d{2}:\d{2}|Z)$') { $s += ' +07:00' }   # không ghi múi giờ -> giờ Việt Nam
  $d = [DateTimeOffset]::MinValue
  if ([DateTimeOffset]::TryParse($s, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$d)) { return $d.ToUniversalTime() }
  $s2 = $s -replace '^[A-Za-z]{3},\s*', ''
  if ([DateTimeOffset]::TryParse($s2, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$d)) { return $d.ToUniversalTime() }
  return $null
}

# Bỏ dấu tiếng Việt để so khớp tiêu đề
function Get-Plain([string]$s) {
  $s = $s.ToLowerInvariant().Replace('đ', 'd')
  $n = $s.Normalize([Text.NormalizationForm]::FormD)
  $sb = New-Object System.Text.StringBuilder
  foreach ($ch in $n.ToCharArray()) {
    if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [Globalization.UnicodeCategory]::NonSpacingMark) { [void]$sb.Append($ch) }
  }
  return ([regex]::Replace($sb.ToString(), '[^a-z0-9]+', ' ')).Trim()
}

$stop = @{}
'va cua la cho voi cac nhung mot trong khi da duoc bi tai sau ve nay do co khong ra vao len thi se dang nhu tu den the gi' -split ' ' | ForEach-Object { $stop[$_] = 1 }
function Get-Bigrams([string]$title) {
  $w = @((Get-Plain $title) -split ' ' | Where-Object { $_ -and -not $stop.ContainsKey($_) })
  $set = New-Object 'System.Collections.Generic.HashSet[string]'
  for ($i = 0; $i -lt $w.Count - 1; $i++) { [void]$set.Add($w[$i] + '_' + $w[$i + 1]) }
  return ,$set
}

$sources = Get-Content $SourcesFile -Raw -Encoding UTF8 | ConvertFrom-Json
$now = [DateTimeOffset]::UtcNow
$cutoff = $now.AddHours(-$KeepHours)
$items = New-Object System.Collections.ArrayList
$trends = New-Object System.Collections.ArrayList
$status = New-Object System.Collections.ArrayList

foreach ($src in $sources) {
  try {
    try { $bytes = $http.GetByteArrayAsync($src.url).GetAwaiter().GetResult() }
    catch { Start-Sleep -Seconds 3; $bytes = $http.GetByteArrayAsync($src.url).GetAwaiter().GetResult() }  # thử lại 1 lần
    $text = $utf8.GetString($bytes).TrimStart([char]0xFEFF)
    $text = [regex]::Replace($text, '[\x00-\x08\x0B\x0C\x0E-\x1F]', '')   # ký tự rác làm hỏng XML
    $xml = New-Object System.Xml.XmlDocument
    $xml.XmlResolver = $null
    $xml.LoadXml($text)
    $nodes = @($xml.SelectNodes('//*[local-name()="item" or local-name()="entry"]'))
    $count = 0
    foreach ($it in $nodes) {
      $title = Remove-Html (Get-Text $it.title)
      if (-not $title) { continue }
      $link = Get-Text $it.link
      if (-not $link -and $it.link) { $link = $it.link.href }
      $dateStr = Get-Text $it.pubDate; if (-not $dateStr) { $dateStr = Get-Text $it.published }; if (-not $dateStr) { $dateStr = Get-Text $it.updated }
      $date = ConvertTo-Date $dateStr
      if (-not $date -or $date -gt $now) { $date = $now }

      if ($src.group -eq 'trends') {
        $news = @()
        foreach ($n in @($it.SelectNodes('*[local-name()="news_item"]'))) {
          $news += [ordered]@{ title = Remove-Html (Get-Text $n.news_item_title); link = Get-Text $n.news_item_url; source = Get-Text $n.news_item_source }
        }
        [void]$trends.Add([ordered]@{ term = $title; traffic = (Get-Text $it.approx_traffic); time = $date.ToString('o'); news = $news })
        $count++; continue
      }
      if ($date -lt $cutoff) { continue }

      $rawDesc = Get-Text $it.description
      if (-not $rawDesc) { $rawDesc = Get-Text $it.summary }
      $image = ''
      $m = [regex]::Match($rawDesc, '<img[^>]+src="([^"]+)"')
      if ($m.Success) { $image = $m.Groups[1].Value }
      if (-not $image) {
        $enc = $it.SelectSingleNode('*[local-name()="enclosure" or local-name()="content" or local-name()="thumbnail"][@url]')
        if ($enc) { $image = $enc.GetAttribute('url') }
      }
      $summary = Remove-Html $rawDesc
      $sourceName = $src.name
      if ($src.group -eq 'hot') {
        $s = Get-Text $it.source
        if ($s) { $sourceName = $s; $title = $title -replace ('\s+-\s+' + [regex]::Escape($s) + '$'), '' }
        $summary = ''
      }
      if ($summary.Length -gt 260) { $summary = $summary.Substring(0, 257) + '...' }

      [void]$items.Add([ordered]@{
        title = $title; link = $link; source = $sourceName; feed = $src.name; group = $src.group
        time = $date.ToString('o'); summary = $summary; image = $image; heat = 1; cluster = 0
      })
      $count++
    }
    [void]$status.Add([ordered]@{ name = $src.name; ok = $true; count = $count })
    Write-Host ("OK   {0,-16} {1} tin" -f $src.name, $count)
  } catch {
    [void]$status.Add([ordered]@{ name = $src.name; ok = $false; count = 0; error = $_.Exception.Message })
    Write-Warning ("LỖI {0}: {1}" -f $src.name, $_.Exception.Message)
  }
}

# Gộp tin trùng: tiêu đề có nhiều cặp từ giống nhau -> cùng một cụm
$grams = @(); foreach ($x in $items) { $grams += ,(Get-Bigrams $x.title) }
$parent = 0..([Math]::Max(0, $items.Count - 1))
function Find-Root($i) { while ($parent[$i] -ne $i) { $parent[$i] = $parent[$parent[$i]]; $i = $parent[$i] }; return $i }
for ($i = 0; $i -lt $items.Count; $i++) {
  $a = $grams[$i]; if ($a.Count -lt 2) { continue }
  for ($j = $i + 1; $j -lt $items.Count; $j++) {
    if ($items[$i].feed -eq $items[$j].feed) { continue }
    $b = $grams[$j]; if ($b.Count -lt 2) { continue }
    $common = 0; foreach ($g in $a) { if ($b.Contains($g)) { $common++ } }
    if ($common -ge 2 -and ($common / [Math]::Min($a.Count, $b.Count)) -ge 0.4) {
      $ri = Find-Root $i; $rj = Find-Root $j; if ($ri -ne $rj) { $parent[$rj] = $ri }
    }
  }
}
$clusterSources = @{}
for ($i = 0; $i -lt $items.Count; $i++) {
  $r = Find-Root $i
  $items[$i].cluster = $r
  if (-not $clusterSources.ContainsKey($r)) { $clusterSources[$r] = @{} }
  $srcKey = (Get-Plain $items[$i].source) -replace '^bao ', '' -replace ' ', ''   # "Báo Tuổi Trẻ" = "Tuổi Trẻ"
  $clusterSources[$r][$srcKey] = 1
}
for ($i = 0; $i -lt $items.Count; $i++) {
  $h = $clusterSources[$items[$i].cluster].Count
  if ($items[$i].group -eq 'hot') { $h++ }   # có trong "Tin nổi bật" của Google News
  $items[$i].heat = $h
}

$sorted = @($items | Sort-Object { $_.time } -Descending)
$out = [ordered]@{ updated = $now.ToString('o'); sources = $status; trends = $trends; items = $sorted }
$dir = Split-Path $OutFile -Parent
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
[IO.File]::WriteAllText($OutFile, ($out | ConvertTo-Json -Depth 6 -Compress), $utf8)
$multi = @($clusterSources.Values | Where-Object { $_.Count -ge 2 }).Count
Write-Host ("Xong: {0} tin, {1} xu hướng, {2} sự kiện được nhiều báo đưa -> {3}" -f $items.Count, $trends.Count, $multi, $OutFile)
