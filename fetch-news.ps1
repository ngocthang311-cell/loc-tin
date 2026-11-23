# Lấy tin từ các nguồn RSS trong sources.json, phân chuyên mục, gộp tin trùng, ghi ra site/news.json
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
  $ci = [Globalization.CultureInfo]::InvariantCulture
  if ([DateTimeOffset]::TryParse($s, $ci, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$d)) { return $d.ToUniversalTime() }
  $s2 = $s -replace '^[A-Za-z]{3},\s*', ''
  if ([DateTimeOffset]::TryParse($s2, $ci, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$d)) { return $d.ToUniversalTime() }
  return $null
}

# Bỏ dấu tiếng Việt để so khớp
function Get-Plain([string]$s) {
  $s = $s.ToLowerInvariant().Replace([string][char]0x111, 'd')
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

function Get-LinkKey([string]$link) { return ($link -replace '[?#].*$', '' -replace '^https?://(www\.)?', '').TrimEnd('/') }

$config = Get-Content $SourcesFile -Raw -Encoding UTF8 | ConvertFrom-Json
# Từ khóa phân loại: "=AI" nghĩa là khớp đúng chữ hoa trong tiêu đề gốc
$kwRules = @()
foreach ($p in $config.keywords.PSObject.Properties) {
  foreach ($k in $p.Value) {
    if ($k.StartsWith('=')) { $kwRules += [pscustomobject]@{ cat = $p.Name; exact = $true;  re = [regex]('\b' + [regex]::Escape($k.Substring(1)) + '\b') } }
    else                    { $kwRules += [pscustomobject]@{ cat = $p.Name; exact = $false; pad = ' ' + (Get-Plain $k) + ' ' } }
  }
}
function Get-KeywordCats([string]$title, [string]$plainPadded) {
  $cats = @{}
  foreach ($r in $kwRules) {
    if ($cats.ContainsKey($r.cat)) { continue }
    if ($r.exact) { if ($r.re.IsMatch($title)) { $cats[$r.cat] = 1 } }
    elseif ($plainPadded.Contains($r.pad)) { $cats[$r.cat] = 1 }
  }
  return @($cats.Keys)
}

$now = [DateTimeOffset]::UtcNow
$cutoff = $now.AddHours(-$KeepHours)
$items = New-Object System.Collections.ArrayList
$byLink = @{}
$trends = New-Object System.Collections.ArrayList
$status = New-Object System.Collections.ArrayList

foreach ($src in $config.sources) {
  $srcCount = 0; $errors = @()
  foreach ($feed in $src.feeds) {
    try {
      try { $bytes = $http.GetByteArrayAsync($feed.url).GetAwaiter().GetResult() }
      catch { Start-Sleep -Seconds 3; $bytes = $http.GetByteArrayAsync($feed.url).GetAwaiter().GetResult() }  # thử lại 1 lần
      $text = $utf8.GetString($bytes).TrimStart([char]0xFEFF)
      $text = [regex]::Replace($text, '[\x00-\x08\x0B\x0C\x0E-\x1F]', '')
      $xml = New-Object System.Xml.XmlDocument
      $xml.XmlResolver = $null
      $xml.LoadXml($text)
      foreach ($it in @($xml.SelectNodes('//*[local-name()="item" or local-name()="entry"]'))) {
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
          $srcCount++; continue
        }
        if ($date -lt $cutoff) { continue }

        # Cùng một bài xuất hiện ở nhiều RSS (trang chủ + chuyên mục) -> gộp chuyên mục
        $key = Get-LinkKey $link
        if ($byLink.ContainsKey($key)) {
          $old = $byLink[$key]
          if ($feed.cat -and ($old.cats -notcontains $feed.cat)) { $old.cats = @($old.cats) + $feed.cat }
          continue
        }

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
        if ($src.group -in 'hot', 'topic') {
          $s = Get-Text $it.source
          if ($s) { $sourceName = $s; $title = $title -replace ('\s+-\s+' + [regex]::Escape($s) + '$'), '' }
          $summary = ''
        }
        if ($summary.Length -gt 170) { $summary = $summary.Substring(0, 167) + '...' }

        $obj = [ordered]@{
          title = $title; link = $link; source = $sourceName; feed = $src.name; group = $src.group
          time = $date.ToString('o'); summary = $summary; image = $image
          cats = @(if ($feed.cat) { $feed.cat }); heat = 1; cluster = 0
        }
        $byLink[$key] = $obj
        [void]$items.Add($obj)
        $srcCount++
      }
    } catch {
      $errors += ($feed.url + ': ' + $_.Exception.Message)
      Write-Warning ("LỖI {0} ({1}): {2}" -f $src.name, $feed.url, $_.Exception.Message)
    }
  }
  $st = [ordered]@{ name = $src.name; ok = ($errors.Count -lt @($src.feeds).Count); count = $srcCount }
  if ($errors.Count) { $st.error = ($errors -join ' | ') }
  [void]$status.Add($st)
  Write-Host ("{0} {1,-16} {2} tin" -f $(if ($st.ok) { 'OK  ' } else { 'LỖI ' }), $src.name, $srcCount)
}

# Thêm chuyên mục theo từ khóa trong tiêu đề (Viễn thông, Công nghệ... và tin chưa có chuyên mục)
foreach ($x in $items) {
  $pt = ' ' + (Get-Plain $x.title) + ' '
  $extra = Get-KeywordCats $x.title $pt
  foreach ($c in $extra) {
    # Tin đã được báo xếp chuyên mục: từ khóa chỉ được thêm Viễn thông / Công nghệ (tránh xếp nhầm)
    if (@($x.cats).Count -and ($c -notin 'vien-thong', 'cong-nghe')) { continue }
    if ($x.cats -notcontains $c) { $x.cats = @($x.cats) + $c }
  }
}

# Gộp tin trùng giữa các báo (dùng chỉ mục ngược cho nhanh)
$n = $items.Count
$grams = New-Object 'object[]' $n
$index = @{}
for ($i = 0; $i -lt $n; $i++) {
  $grams[$i] = Get-Bigrams $items[$i].title
  foreach ($g in $grams[$i]) { if (-not $index.ContainsKey($g)) { $index[$g] = New-Object System.Collections.Generic.List[int] }; $index[$g].Add($i) }
}
$parent = New-Object 'int[]' ([Math]::Max(1, $n)); for ($i = 0; $i -lt $n; $i++) { $parent[$i] = $i }
function Find-Root([int]$i) { while ($parent[$i] -ne $i) { $parent[$i] = $parent[$parent[$i]]; $i = $parent[$i] }; return $i }
for ($i = 0; $i -lt $n; $i++) {
  $a = $grams[$i]; if ($a.Count -lt 2) { continue }
  $common = @{}
  foreach ($g in $a) { foreach ($j in $index[$g]) { if ($j -gt $i) { $common[$j] = 1 + [int]$common[$j] } } }
  foreach ($j in $common.Keys) {
    $c = $common[$j]
    if ($c -lt 2 -or $items[$i].feed -eq $items[$j].feed) { continue }
    if (($c / [Math]::Min($a.Count, $grams[$j].Count)) -ge 0.4) {
      $ri = Find-Root $i; $rj = Find-Root $j; if ($ri -ne $rj) { $parent[$rj] = $ri }
    }
  }
}
$clusterSources = @{}
for ($i = 0; $i -lt $n; $i++) {
  $r = Find-Root $i
  $items[$i].cluster = $r
  if (-not $clusterSources.ContainsKey($r)) { $clusterSources[$r] = @{} }
  $srcKey = (Get-Plain $items[$i].source) -replace '^bao ', '' -replace ' ', ''   # "Báo Tuổi Trẻ" = "Tuổi Trẻ"
  $clusterSources[$r][$srcKey] = 1
}
for ($i = 0; $i -lt $n; $i++) {
  $h = $clusterSources[$items[$i].cluster].Count
  if ($items[$i].group -eq 'hot') { $h++ }   # có trong "Tin nổi bật" của Google News
  $items[$i].heat = $h
}

$sorted = @($items | Sort-Object { $_.time } -Descending)
$out = [ordered]@{ updated = $now.ToString('o'); categories = $config.categories; sources = $status; trends = $trends; items = $sorted }
$dir = Split-Path $OutFile -Parent
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
[IO.File]::WriteAllText($OutFile, ($out | ConvertTo-Json -Depth 6 -Compress), $utf8)
$multi = @($clusterSources.Values | Where-Object { $_.Count -ge 2 }).Count
Write-Host ("Xong: {0} tin, {1} xu hướng, {2} sự kiện được nhiều báo đưa -> {3}" -f $n, $trends.Count, $multi, $OutFile)
