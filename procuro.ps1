# Pagina privada "Wanted": corre as pesquisas guardadas da conta eBay (My eBay > Saved searches)
# e gera procuro.html com os resultados ENCRIPTADOS (AES-256 + HMAC, chave tirada da palavra-passe
# com PBKDF2-SHA256). A pagina pede a palavra-passe e desencripta no browser; sem ela nao se ve nada.
# Precisa de chaves.env com EBAY_APP_ID, EBAY_CERT_ID, EBAY_DEV_ID, EBAY_USER_TOKEN e PROCURO_SENHA.
# Uso: .\procuro.ps1 [-Saida procuro.html] [-Demo]
param([string]$Saida, [switch]$Demo)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$dir = $PSScriptRoot
$utf8 = New-Object System.Text.UTF8Encoding($false)
function Ler-Texto($p) { [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) }

$chaves = @{}
$envPath = Join-Path $dir 'chaves.env'
if (Test-Path $envPath) { foreach ($l in Get-Content $envPath) { if ($l -match '^\s*([A-Z_]+)\s*=\s*(.*?)\s*$') { $chaves[$Matches[1]] = $Matches[2] } } }
foreach ($n in 'EBAY_APP_ID', 'EBAY_CERT_ID', 'EBAY_DEV_ID', 'EBAY_USER_TOKEN', 'PROCURO_SENHA') {
    if (-not $chaves[$n] -and (Get-Item "env:$n" -ErrorAction SilentlyContinue)) { $chaves[$n] = (Get-Item "env:$n").Value }
}
if (-not $chaves['PROCURO_SENHA']) { throw 'Falta PROCURO_SENHA (a palavra-passe da pagina privada).' }

$dominioMercado = @{ 'ebay.com' = 'EBAY_US'; 'ebay.co.uk' = 'EBAY_GB'; 'ebay.de' = 'EBAY_DE'; 'ebay.fr' = 'EBAY_FR'
                     'ebay.it' = 'EBAY_IT'; 'ebay.es' = 'EBAY_ES'; 'ebay.ca' = 'EBAY_CA'; 'ebay.com.au' = 'EBAY_AU' }
$paisMercado = @{ EBAY_US = 'US'; EBAY_GB = 'GB'; EBAY_DE = 'DE'; EBAY_FR = 'FR'; EBAY_IT = 'IT'; EBAY_ES = 'ES'; EBAY_CA = 'CA'; EBAY_AU = 'AU' }

function Pedir-Json($url, $headers) {
    for ($tentativa = 1; ; $tentativa++) {
        try { $r = Invoke-WebRequest -Uri $url -Headers $headers -UseBasicParsing; break }
        catch {
            $codigo = 0; try { $codigo = [int]$_.Exception.Response.StatusCode } catch {}
            if ($codigo -ne 429 -or $tentativa -ge 3) { throw }
            Start-Sleep -Seconds (30 * $tentativa)
        }
    }
    [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json
}

function Trading($chamada, $corpo) {
    $xml = '<?xml version="1.0" encoding="utf-8"?>' +
        "<${chamada}Request xmlns=""urn:ebay:apis:eBLBaseComponents"">" +
        "<RequesterCredentials><eBayAuthToken>$($chaves['EBAY_USER_TOKEN'])</eBayAuthToken></RequesterCredentials>" +
        $corpo + "</${chamada}Request>"
    $h = @{
        'X-EBAY-API-CALL-NAME' = $chamada; 'X-EBAY-API-SITEID' = '0'; 'X-EBAY-API-COMPATIBILITY-LEVEL' = '1349'
        'X-EBAY-API-APP-NAME' = $chaves['EBAY_APP_ID']; 'X-EBAY-API-CERT-NAME' = $chaves['EBAY_CERT_ID']; 'X-EBAY-API-DEV-NAME' = $chaves['EBAY_DEV_ID']
    }
    $r = Invoke-WebRequest -Method Post -Uri 'https://api.ebay.com/ws/api.dll' -Headers $h `
        -ContentType 'text/xml; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($xml)) -UseBasicParsing
    [xml]$x = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
    if ($x.DocumentElement.Ack -eq 'Failure') { throw "$chamada falhou: $(@($x.DocumentElement.Errors)[0].LongMessage)" }
    return $x.DocumentElement
}

function Obter-Token {
    $basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($chaves['EBAY_APP_ID']):$($chaves['EBAY_CERT_ID'])"))
    $body = 'grant_type=client_credentials&scope=' + [Uri]::EscapeDataString('https://api.ebay.com/oauth/api_scope')
    (Invoke-RestMethod -Method Post -Uri 'https://api.ebay.com/identity/v1/oauth2/token' -Headers @{ Authorization = "Basic $basic" } `
        -ContentType 'application/x-www-form-urlencoded' -Body $body).access_token
}

# parametros de um endereco de pesquisa do eBay (https://www.ebay.com/sch/i.html?_nkw=...&_sacat=...)
function Ler-Url($url) {
    $p = @{}
    $u = [Uri]$url
    foreach ($par in ($u.Query.TrimStart('?') -split '&')) {
        if (-not $par) { continue }
        $k, $v = $par -split '=', 2
        $p[[Uri]::UnescapeDataString($k)] = [Uri]::UnescapeDataString(([string]$v) -replace '\+', ' ')
    }
    $p['_host'] = ($u.Host -replace '^www\.', '')
    return $p
}

# --- 1) as pesquisas guardadas ---
$pesquisas = @()
if ($Demo) {
    $pesquisas = @(
        [pscustomobject]@{ nome = 'Sonics 45'; q = 'sonics 45'; cat = '176985'; tipo = 'All'; min = $null; max = $null; mercado = 'EBAY_US'; url = 'https://www.ebay.com/sch/i.html?_nkw=sonics+45' },
        [pscustomobject]@{ nome = 'Monks Black Monk Time'; q = 'monks black monk time'; cat = ''; tipo = 'AuctionsOnly'; min = $null; max = $null; mercado = 'EBAY_GB'; url = 'https://www.ebay.co.uk/sch/i.html?_nkw=monks' }
    )
} else {
    $r = Trading 'GetMyeBayBuying' '<FavoriteSearches><Include>true</Include></FavoriteSearches><DetailLevel>ReturnAll</DetailLevel>'
    foreach ($fs in @($r.FavoriteSearches.FavoriteSearch)) {
        if (-not $fs) { continue }
        $url = [string]$fs.SearchQuery
        $p = @{}; if ($url) { try { $p = Ler-Url $url } catch {} }
        $q = [string]$fs.QueryKeywords; if (-not $q) { $q = $p['_nkw'] }
        # so discos de vinil: categoria Music > Vinyl Records (176985), seja qual for a da pesquisa guardada
        # (sem isto vinham livros, postais, etc. com o mesmo nome)
        $cat = '176985'
        $tipo = [string]$fs.ItemType
        if (-not $tipo) { $tipo = if ($p['LH_Auction'] -eq '1') { 'AuctionsOnly' } elseif ($p['LH_BIN'] -eq '1') { 'FixedPricedItem' } else { 'All' } }
        $mercado = 'EBAY_US'; if ($p['_host'] -and $dominioMercado.ContainsKey($p['_host'])) { $mercado = $dominioMercado[$p['_host']] }
        $min = $fs.MinPrice; if (-not $min) { $min = $p['_udlo'] }
        $max = $fs.MaxPrice; if (-not $max) { $max = $p['_udhi'] }
        $nome = [string]$fs.SearchName; if (-not $nome) { $nome = $q }
        if (-not $q -and -not $cat) { continue }
        $pesquisas += [pscustomobject]@{ nome = $nome; q = $q; cat = $cat; tipo = $tipo; min = $min; max = $max; mercado = $mercado; url = $url }
    }
}
Write-Host "Pesquisas guardadas: $($pesquisas.Count)"

# --- 2) correr cada pesquisa (Browse API) ---
$resultado = @(); $erros = @()
if (-not $Demo) { $token = Obter-Token }
foreach ($ps in $pesquisas) {
    $itens = @()
    try {
        if ($Demo) {
            $rnd = New-Object Random ($ps.nome.Length)
            for ($k = 1; $k -le 6; $k++) {
                $leilao = ($rnd.Next(2) -eq 0)
                $itens += [ordered]@{ id = "demo$k"; titulo = "EXEMPLO $($ps.nome) #$k"; url = $ps.url; img = $null; preco = [double]$rnd.Next(5, 300); moeda = 'EUR'
                    tipo = $(if ($leilao) { 'leilao' } else { 'compra' }); licitacoes = $(if ($leilao) { $rnd.Next(0, 9) } else { $null })
                    fim = $(if ($leilao) { (Get-Date).ToUniversalTime().AddHours($rnd.Next(2, 150)).ToString('yyyy-MM-ddTHH:mm:ssZ') } else { $null }); pais = 'US'; site = 'ebay.com' }
            }
        } else {
            $filtros = @()
            switch ($ps.tipo) { 'AuctionsOnly' { $filtros += 'buyingOptions:{AUCTION}' } 'FixedPricedItem' { $filtros += 'buyingOptions:{FIXED_PRICE}' } default { $filtros += 'buyingOptions:{AUCTION|FIXED_PRICE}' } }
            if ($ps.min -or $ps.max) { $filtros += "price:[$($ps.min)..$($ps.max)]" }
            $url = 'https://api.ebay.com/buy/browse/v1/item_summary/search?limit=200&sort=newlyListed'
            if ($ps.q) { $url += '&q=' + [Uri]::EscapeDataString($ps.q) }
            if ($ps.cat) { $url += '&category_ids=' + $ps.cat }
            $url += '&filter=' + [Uri]::EscapeDataString(($filtros -join ','))
            $h = @{ Authorization = "Bearer $token"; 'X-EBAY-C-MARKETPLACE-ID' = $ps.mercado
                    'X-EBAY-C-ENDUSERCTX' = 'contextualLocation=' + [Uri]::EscapeDataString("country=$($paisMercado[$ps.mercado])") }
            $r = Pedir-Json $url $h
            foreach ($s in @($r.itemSummaries)) {
                if (-not $s) { continue }
                $leilao = @($s.buyingOptions) -contains 'AUCTION'
                $preco = $s.currentBidPrice; if (-not $preco) { $preco = $s.price }
                $img = $null; if ($s.image) { $img = $s.image.imageUrl -replace 's-l\d+\.', 's-l500.' }
                $dominio = ($ps.url -replace '^https?://(www\.)?([^/]+).*$', '$2'); if (-not $dominio -or $dominio -eq $ps.url) { $dominio = 'ebay.com' }
                $itens += [ordered]@{
                    id = [string]$s.legacyItemId; titulo = $s.title; url = "https://www.$dominio/itm/$($s.legacyItemId)"; img = $img
                    preco = $(if ($preco.convertedFromValue) { [double]$preco.convertedFromValue } else { [double]$preco.value })
                    moeda = $(if ($preco.convertedFromCurrency) { $preco.convertedFromCurrency } else { $preco.currency })
                    tipo = $(if ($leilao) { 'leilao' } else { 'compra' }); licitacoes = $(if ($s.bidCount) { [int]$s.bidCount } elseif ($leilao) { 0 } else { $null })
                    fim = $s.itemEndDate; pais = $s.itemLocation.country; site = $dominio; posto = $s.itemCreationDate
                }
            }
        }
    } catch { $erros += "$($ps.nome): $($_.Exception.Message)"; Write-Warning $erros[-1] }
    $resultado += [ordered]@{ nome = $ps.nome; url = $ps.url; tipo = $ps.tipo; itens = @($itens) }
    Write-Host "  $($ps.nome): $($itens.Count)"
}

# cambio do dia (BCE), para mostrar tudo em euros
$cambio = [ordered]@{ EUR = 1.0 }
try {
    $x = [xml](Invoke-WebRequest -UseBasicParsing 'https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml').Content
    foreach ($c in $x.Envelope.Cube.Cube.Cube) { $cambio[[string]$c.currency] = [double]::Parse($c.rate, [Globalization.CultureInfo]::InvariantCulture) }
} catch { $cambio['USD'] = 1.10; $cambio['GBP'] = 0.85 }

$dados = [ordered]@{ gerado = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); pesquisas = $resultado; erros = $erros; cambio = $cambio }
$json = $dados | ConvertTo-Json -Depth 7 -Compress

# --- 3) encriptar: PBKDF2-SHA256 (200 000 voltas) -> 32 bytes chave AES + 32 bytes chave HMAC ---
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
$sal = New-Object byte[] 16; $rng.GetBytes($sal)
$iv = New-Object byte[] 16; $rng.GetBytes($iv)
$voltas = 200000
$kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes($chaves['PROCURO_SENHA'], $sal, $voltas, [Security.Cryptography.HashAlgorithmName]::SHA256)
$k = $kdf.GetBytes(64)
$kAes = [byte[]]$k[0..31]; $kMac = [byte[]]$k[32..63]
$aes = [Security.Cryptography.Aes]::Create(); $aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'; $aes.Key = $kAes; $aes.IV = $iv
$claro = $utf8.GetBytes($json)
$cifra = $aes.CreateEncryptor().TransformFinalBlock($claro, 0, $claro.Length)
$hmac = New-Object Security.Cryptography.HMACSHA256 (, $kMac)
$mac = $hmac.ComputeHash([byte[]]($iv + $cifra))
$pacote = [ordered]@{ v = 1; voltas = $voltas; sal = [Convert]::ToBase64String($sal); iv = [Convert]::ToBase64String($iv)
                      mac = [Convert]::ToBase64String($mac); dados = [Convert]::ToBase64String($cifra) }

$modelo = Ler-Texto (Join-Path $dir 'modelo-procuro.html')
$logo = Join-Path $dir 'player.gif'
if (Test-Path $logo) { $modelo = $modelo.Replace('src="player.gif"', 'src="data:image/gif;base64,' + [Convert]::ToBase64String([IO.File]::ReadAllBytes($logo)) + '"') }
$ficheiro = Join-Path $dir 'procuro.html'
if ($Saida) { $ficheiro = if ([IO.Path]::IsPathRooted($Saida)) { $Saida } else { Join-Path $dir $Saida } }
[IO.File]::WriteAllText($ficheiro, $modelo.Replace('/*CIFRA*/null', ($pacote | ConvertTo-Json -Compress)), $utf8)
Write-Host "Pagina privada gerada (encriptada): $ficheiro"
