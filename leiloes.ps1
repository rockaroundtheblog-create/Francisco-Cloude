# Procura leiloes no eBay (Browse API) para os topicos de config.json
# e gera leiloes.html a partir de modelo.html.
# Uso:  .\leiloes.ps1          (dados reais, precisa de chaves.env)
#       .\leiloes.ps1 -Demo    (dados de exemplo, sem chaves)
param([switch]$Demo, [switch]$Abrir, [string]$Saida)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$dir = $PSScriptRoot
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Ler-Texto($p) { [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) }
function Gravar-Texto($p, $t) { [IO.File]::WriteAllText($p, $t, $utf8) }

$config = Ler-Texto (Join-Path $dir 'config.json') | ConvertFrom-Json
$dominios = @{
    EBAY_US = 'www.ebay.com'; EBAY_GB = 'www.ebay.co.uk'; EBAY_DE = 'www.ebay.de'; EBAY_FR = 'www.ebay.fr'
    EBAY_IT = 'www.ebay.it'; EBAY_ES = 'www.ebay.es'; EBAY_CA = 'www.ebay.ca'; EBAY_AU = 'www.ebay.com.au'
}
$paises = @{
    EBAY_US = 'US'; EBAY_GB = 'GB'; EBAY_DE = 'DE'; EBAY_FR = 'FR'
    EBAY_IT = 'IT'; EBAY_ES = 'ES'; EBAY_CA = 'CA'; EBAY_AU = 'AU'
}
$mercados = @($config.mercados)
$agora = (Get-Date).ToUniversalTime()
$carimbo = $agora.ToString('yyyy-MM-ddTHH:mm:ssZ')

# --- itens ja vistos (para marcar os novos) ---
$vistosPath = Join-Path $dir 'vistos.json'
$vistos = @{}
if (Test-Path $vistosPath) {
    $obj = Ler-Texto $vistosPath | ConvertFrom-Json
    foreach ($p in $obj.PSObject.Properties) { $vistos[$p.Name] = $p.Value }
}
$primeiraVez = ($vistos.Count -eq 0)
# "__inicio" guarda a data da primeira execucao: o que foi visto nessa altura nunca conta como novo
if (-not $vistos.ContainsKey('__inicio')) { $vistos['__inicio'] = $carimbo }
$inicio = $vistos['__inicio']
# novo = visto pela primeira vez nas ultimas X horas (config "horasNovo", por omissao 24)
$horasNovo = 24; if ($config.horasNovo) { $horasNovo = [double]$config.horasNovo }
$limiteNovo = $agora.AddHours(-$horasNovo).ToString('yyyy-MM-ddTHH:mm:ssZ')

function Pedir-Json($url, $headers) {
    $r = Invoke-WebRequest -Uri $url -Headers $headers -UseBasicParsing
    $txt = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
    return $txt | ConvertFrom-Json
}

function Obter-Token {
    $k = $script:chaves
    if (-not $k['EBAY_APP_ID'] -or -not $k['EBAY_CERT_ID']) { throw "chaves.env tem de ter EBAY_APP_ID e EBAY_CERT_ID preenchidos." }
    $basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($k['EBAY_APP_ID']):$($k['EBAY_CERT_ID'])"))
    $body = 'grant_type=client_credentials&scope=' + [Uri]::EscapeDataString('https://api.ebay.com/oauth/api_scope')
    $r = Invoke-RestMethod -Method Post -Uri 'https://api.ebay.com/identity/v1/oauth2/token' `
        -Headers @{ Authorization = "Basic $basic" } -ContentType 'application/x-www-form-urlencoded' -Body $body
    return $r.access_token
}

function Ler-Chaves {
    $envPath = Join-Path $dir 'chaves.env'
    if (-not (Test-Path $envPath)) { throw "Falta o ficheiro chaves.env (copie chaves.env.example e preencha as chaves)." }
    $k = @{}
    foreach ($l in Get-Content $envPath) {
        if ($l -match '^\s*([A-Z_]+)\s*=\s*(.*?)\s*$') { $k[$Matches[1]] = $Matches[2] }
    }
    return $k
}

# ---------- Observadores (Trading API, precisa de EBAY_USER_TOKEN) ----------
# 1) GetItem com IncludeWatchCount. Se o eBay devolver WatchCount, usa-se esse valor.
# 2) Se nao devolver e "usarListaObservados" estiver ligado: junta os leiloes a lista de
#    observados da conta (AddToWatchList) e le o numero com GetMyeBayBuying.

function Trading($chamada, $corpo) {
    $xml = '<?xml version="1.0" encoding="utf-8"?>' +
        "<${chamada}Request xmlns=""urn:ebay:apis:eBLBaseComponents"">" +
        "<RequesterCredentials><eBayAuthToken>$($script:chaves['EBAY_USER_TOKEN'])</eBayAuthToken></RequesterCredentials>" +
        $corpo + "</${chamada}Request>"
    $h = @{
        'X-EBAY-API-CALL-NAME' = $chamada; 'X-EBAY-API-SITEID' = '0'
        'X-EBAY-API-COMPATIBILITY-LEVEL' = '1349'
        'X-EBAY-API-APP-NAME' = $script:chaves['EBAY_APP_ID']; 'X-EBAY-API-CERT-NAME' = $script:chaves['EBAY_CERT_ID']
        'X-EBAY-API-DEV-NAME' = $script:chaves['EBAY_DEV_ID']
    }
    $r = Invoke-WebRequest -Method Post -Uri 'https://api.ebay.com/ws/api.dll' -Headers $h `
        -ContentType 'text/xml; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($xml)) -UseBasicParsing
    [xml]$x = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
    $resp = $x.DocumentElement
    if ($resp.Ack -eq 'Failure') {
        $e = @($resp.Errors)[0]
        throw "$chamada falhou: $($e.LongMessage)"
    }
    return $resp
}

function Observadores-GetItem($nums) {
    $res = @{}; $semValor = 0
    foreach ($n in $nums) {
        # um leilao com erro (ex.: terminou entretanto) nao estraga os outros
        try { $r = Trading 'GetItem' "<ItemID>$n</ItemID><IncludeWatchCount>true</IncludeWatchCount><DetailLevel>ReturnAll</DetailLevel>" }
        catch { Write-Warning "Seguidores de $n : $($_.Exception.Message)"; continue }
        $w = $r.Item.WatchCount
        if ($null -ne $w -and "$w" -ne '') { $res[$n] = [int]$w } else { $semValor++ }
        # se os primeiros 5 nao trazem numero, o eBay nao o da para anuncios de outros vendedores
        if ($res.Count -eq 0 -and $semValor -ge 5) { return $null }
    }
    return $res
}

function Observadores-Lista($nums) {
    $adicPath = Join-Path $dir 'lista-observados.json'
    $adic = @{}
    if (Test-Path $adicPath) { (Ler-Texto $adicPath | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $adic[$_.Name] = $_.Value } }
    # tira da lista os leiloes que o script juntou e ja nao aparecem nos resultados (terminados)
    $velhos = @($adic.Keys | Where-Object { $nums -notcontains $_ })
    for ($i = 0; $i -lt $velhos.Count; $i += 10) {
        $lote = $velhos[$i..([Math]::Min($i + 9, $velhos.Count - 1))]
        try { Trading 'RemoveFromWatchList' (($lote | ForEach-Object { "<ItemID>$_</ItemID>" }) -join '') | Out-Null } catch { Write-Warning $_.Exception.Message }
        $lote | ForEach-Object { $adic.Remove($_) }
    }
    # le a lista atual
    $naLista = @{}; $pag = 1
    do {
        $r = Trading 'GetMyeBayBuying' "<WatchList><Include>true</Include><Pagination><EntriesPerPage>200</EntriesPerPage><PageNumber>$pag</PageNumber></Pagination></WatchList><DetailLevel>ReturnAll</DetailLevel>"
        $itens = @($r.WatchList.ItemArray.Item)
        foreach ($it in $itens) { if ($it.ItemID) { $naLista[[string]$it.ItemID] = $it } }
        $totalPag = [int]$r.WatchList.PaginationResult.TotalNumberOfPages
        $pag++
    } while ($pag -le $totalPag)
    # junta os que faltam
    $faltam = @($nums | Where-Object { -not $naLista.ContainsKey($_) })
    $max = [int]$config.observadores.maxNaLista
    $espaco = [Math]::Max(0, $max - $naLista.Count)
    if ($faltam.Count -gt $espaco) { Write-Warning "Lista de observados quase cheia: so cabem mais $espaco leiloes."; $faltam = @($faltam | Select-Object -First $espaco) }
    for ($i = 0; $i -lt $faltam.Count; $i += 10) {
        $lote = $faltam[$i..([Math]::Min($i + 9, $faltam.Count - 1))]
        try { Trading 'AddToWatchList' (($lote | ForEach-Object { "<ItemID>$_</ItemID>" }) -join '') | Out-Null; $lote | ForEach-Object { $adic[$_] = $carimbo } }
        catch { Write-Warning $_.Exception.Message }
    }
    Gravar-Texto $adicPath ($adic | ConvertTo-Json)
    # volta a ler para ter os numeros
    $res = @{}; $pag = 1
    do {
        $r = Trading 'GetMyeBayBuying' "<WatchList><Include>true</Include><Pagination><EntriesPerPage>200</EntriesPerPage><PageNumber>$pag</PageNumber></Pagination></WatchList><DetailLevel>ReturnAll</DetailLevel>"
        foreach ($it in @($r.WatchList.ItemArray.Item)) {
            if ($it.ItemID -and $null -ne $it.WatchCount -and "$($it.WatchCount)" -ne '') {
                # desconta a propria conta, que tambem esta a observar
                $res[[string]$it.ItemID] = [Math]::Max(0, [int]$it.WatchCount - 1)
            }
        }
        $totalPag = [int]$r.WatchList.PaginationResult.TotalNumberOfPages
        $pag++
    } while ($pag -le $totalPag)
    return $res
}

function Excluido($titulo, $palavras) {
    $t = $titulo.ToLowerInvariant()
    foreach ($w in $palavras) {
        $re = '(^|[^a-z0-9])' + [Regex]::Escape($w.ToLowerInvariant()) + '($|[^a-z0-9])'
        if ($t -match $re) { return $true }
    }
    # "6LP", "2xLP", "LPs": tambem sao LPs
    if (($palavras -contains 'lp') -and ($t -match '(^|[^a-z0-9])\d+\s*x?\s*lps?($|[^a-z])|(^|[^a-z])lps($|[^a-z])')) { return $true }
    return $false
}

function Converter-Item($s, $mercado) {
    $preco = $s.currentBidPrice; if (-not $preco) { $preco = $s.price }
    $envio = $null
    if ($s.shippingOptions -and $s.shippingOptions[0].shippingCost) { $envio = [double]$s.shippingOptions[0].shippingCost.value }
    # foto maior (o eBay devolve s-l225; s-l500 serve bem para a grelha)
    $img = $null; if ($s.image) { $img = $s.image.imageUrl -replace 's-l\d+\.', 's-l500.' }
    $bids = 0; if ($s.bidCount) { $bids = [int]$s.bidCount }
    # link direto e limpo para o anuncio: https://www.ebay.xx/itm/<numero>
    # o link e o site seguem o pais do vendedor (ex.: vendedor dos EUA -> ebay.com), mesmo que encontrado noutro site
    $dominio = $dominios[$mercado]
    # paises sem eBay proprio (Grecia, Portugal, Japao...) -> ebay.com
    $porPais = @{ US = 'www.ebay.com'; GB = 'www.ebay.co.uk'; FR = 'www.ebay.fr'; DE = 'www.ebay.de'; IT = 'www.ebay.it'; ES = 'www.ebay.es'
                  CA = 'www.ebay.ca'; AU = 'www.ebay.com.au'; AT = 'www.ebay.at'; NL = 'www.ebay.nl'; BE = 'www.befr.ebay.be'
                  IE = 'www.ebay.ie'; CH = 'www.ebay.ch'; PL = 'www.ebay.pl' }
    if ($s.itemLocation -and $s.itemLocation.country) {
        $p = [string]$s.itemLocation.country
        $dominio = if ($porPais.ContainsKey($p)) { $porPais[$p] } else { 'www.ebay.com' }
    }
    $url = $s.itemWebUrl
    if ($s.legacyItemId) { $url = "https://$dominio/itm/$($s.legacyItemId)" }
    [ordered]@{
        id         = $s.itemId
        titulo     = $s.title
        url        = $url
        img        = $img
        # preco na moeda do vendedor (o eBay converte para a moeda do site onde se pesquisou)
        preco      = $(if ($preco.convertedFromValue) { [double]$preco.convertedFromValue } else { [double]$preco.value })
        moeda      = $(if ($preco.convertedFromCurrency) { $preco.convertedFromCurrency } else { $preco.currency })
        licitacoes = $bids
        fim        = $s.itemEndDate
        estado     = $s.condition
        vendedor   = $s.seller.username
        feedback   = $s.seller.feedbackScore
        pais       = $s.itemLocation.country
        envio      = $envio
        num        = [string]$s.legacyItemId
        site       = $dominio -replace '^www\.', ''
        observadores = $null
    }
}

# ---------- Pesquisa (Browse API) ----------
# Pesquisa num site do eBay "como se" o comprador estivesse nesse pais, para aparecerem
# tambem os anuncios que so enviam dentro do pais (contam todos, sejam locais ou nao).
function Cabecalhos($mercado) {
    @{
        Authorization = "Bearer $script:token"; 'X-EBAY-C-MARKETPLACE-ID' = $mercado
        'X-EBAY-C-ENDUSERCTX' = 'contextualLocation=' + [Uri]::EscapeDataString("country=$($paises[$mercado])")
    }
}

# $aspecto: @{ nome = 'Record Size'; valor = '7"' } ou $null
function Pesquisar($mercado, $q, $aspecto, $max) {
    if (-not $max) { $max = $config.maxPorTopico }
    $filtro = 'buyingOptions:{AUCTION}'
    $itens = @(); $offset = 0; $limite = 200
    do {
        $url = 'https://api.ebay.com/buy/browse/v1/item_summary/search?q=' + [Uri]::EscapeDataString($q) +
            '&category_ids=' + $config.categoria +
            '&filter=' + [Uri]::EscapeDataString($filtro) +
            '&sort=endingSoonest&limit=' + $limite + '&offset=' + $offset
        if ($aspecto) {
            $af = "categoryId:$($config.categoria),$($aspecto.nome):{$($aspecto.valor)}"
            $url += '&aspect_filter=' + [Uri]::EscapeDataString($af)
        }
        $r = Pedir-Json $url (Cabecalhos $mercado)
        if ($r.itemSummaries) { $itens += $r.itemSummaries }
        $offset += $limite
    } while ($r.next -and $itens.Count -lt $max)
    return $itens
}

# Descobre, em cada site, os nomes e valores das caracteristicas que indicam um single:
# tamanho 7" e velocidade 45 (os nomes mudam com a lingua do site).
$script:cacheAspectos = @{}
# aspas tipograficas criadas a partir do codigo, para o ficheiro ficar so com caracteres simples
$aspa = [string][char]0x201D
$aspasTodas = [string][char]0x201C + [string][char]0x201D + [string][char]0x2018 + [string][char]0x2019
$reValor7  = '^\s*7\s*("|' + $aspa + '|''''|in\b|inch|zoll|pouces?|pollici|pulgadas)'
$reValor45 = '^\s*45\s*(rpm|u/?min|tours|giri|t\b|r\.?p\.?m)'
function Aspectos-Single($mercado, $q) {
    if ($script:cacheAspectos.ContainsKey($mercado)) { return $script:cacheAspectos[$mercado] }
    $url = 'https://api.ebay.com/buy/browse/v1/item_summary/search?q=' + [Uri]::EscapeDataString($q) +
        '&category_ids=' + $config.categoria + '&fieldgroups=ASPECT_REFINEMENTS&limit=1'
    $r = Pedir-Json $url (Cabecalhos $mercado)
    $res = @()
    foreach ($a in @($r.refinement.aspectDistributions)) {
        foreach ($v in @($a.aspectValueDistributions)) {
            $val = [string]$v.localizedAspectValue
            if ($val -match $reValor7 -or $val -match $reValor45) {
                $res += @{ nome = $a.localizedAspectName; valor = $val }
            }
        }
    }
    $script:cacheAspectos[$mercado] = $res
    return $res
}

# Formato de um leilao lido nos detalhes (caracteristicas e descricao): $true / $false / $null.
# Um pedido por leilao (o getItems de 20 de cada vez exige autorizacao especial do eBay e da 403).
# A resposta fica guardada em vistos.json ("f:<numero>"), para nao voltar a pedir nos dias seguintes;
# $script:maxDetalhes limita os pedidos por execucao (o eBay da 5000 pedidos/dia a Browse API).
$script:pedidosDetalhe = 0
$script:maxDetalhes = 1000; if ($config.verificarDescricao.maxPedidos) { $script:maxDetalhes = [int]$config.verificarDescricao.maxPedidos }
# Cada combinacao site+genero tem a sua parte dos pedidos ($script:quotaCombo), para um genero
# com muitos anuncios (ex.: Garage no ebay.com) nao gastar tudo e deixar os outros sem nada.
$script:quotaCombo = 0
# Devolve @{ single = $true/$false/$null; generos = 'texto das caracteristicas Genero/Estilo' ou $null }
function Info-Detalhes($mercado, $num) {
    $k = "f:$num"
    if ($vistos.ContainsKey($k)) {
        $partes = ([string]$vistos[$k]) -split '\|', 3
        $single = switch ($partes[1]) { 's' { $true } 'n' { $false } default { $null } }
        if ($partes.Count -ge 3) { return @{ single = $single; generos = $partes[2] } }
        $guardado = @{ single = $single; generos = $null }
    }
    if ($script:pedidosDetalhe -ge $script:maxDetalhes -or $script:quotaCombo -le 0) {
        if ($guardado) { return $guardado } else { return @{ single = $null; generos = $null } }
    }
    $script:pedidosDetalhe++; $script:quotaCombo--
    $url = 'https://api.ebay.com/buy/browse/v1/item/get_item_by_legacy_id?legacy_item_id=' + $num
    try { $det = Pedir-Json $url (Cabecalhos $mercado) }
    catch { Write-Warning "Detalhes $($num): $($_.Exception.Message)"; return @{ single = $null; generos = $null } }
    $single = E-Single $det
    # genero/estilo indicados pelo vendedor (os nomes mudam com a lingua do site)
    $gen = @($det.localizedAspects | Where-Object { [string]$_.name -match 'genre|genere|g.nero|style|stil|estilo|musik' } |
        ForEach-Object { ([string]$_.value).ToLowerInvariant() }) -join ';'
    $gen = $gen -replace '\|', ' '
    $letra = if ($single -eq $true) { 's' } elseif ($single -eq $false) { 'n' } else { 'x' }
    $vistos[$k] = "$carimbo|$letra|$gen"
    return @{ single = $single; generos = $gen }
}

# Regex com as palavras do genero (config "generos"), ex.: "(punk,kbd)" -> (punk|kbd)
function Regex-Genero($t) {
    $palavras = ([string]$t.generos) -replace '[()"]', '' -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    # palavra inteira (aceita plural): "psych" nao apanha "Psycho"
    '(?i)\b(' + (($palavras | ForEach-Object { [Regex]::Escape($_) -replace '(\\ |-)+', '[\s\-]*' }) -join '|') + ')s?\b'
}


# Decide, a partir dos detalhes, se o disco e um single. $true / $false / $null (nao se sabe)
$reTexto45 = '\b45\s*(rpm|r\.p\.m|u/?min|tours|giri|t\b)|\b7\s*("|' + $aspa + '|''''|-?inch|-?zoll|pouces|pollici|pulgadas)|\bsingle\b|\bsp\b'
$reTextoLP = '\b((\d+\s*x?\s*)?lps?|33\s*(rpm|tours|giri|u/?min)|12\s*("|' + $aspa + '|''''|-?inch|-?zoll)|album)\b'
$reGrande = '^\s*(10|12)\s*("|' + $aspa + '|in|inch|zoll)'
# no titulo tambem conta "45" sozinho (ex.: "garage 45", "45s", "45er")
$reTitulo45 = $reTexto45 + '|\b45(s|er)?\b'
function E-Single($det) {
    foreach ($a in @($det.localizedAspects)) {
        $v = [string]$a.value
        if ($v -match $reValor7 -or $v -match $reValor45) { return $true }
        if ($v -match $reGrande -or $v -match '^\s*(33|78)\s*(rpm|u/?min|tours|giri)' -or $v -match '^\s*LP\b') { return $false }
    }
    $texto = (([string]$det.shortDescription) + ' ' + ([string]$det.description)) -replace '<[^>]+>', ' '
    if ($texto -match $reTexto45) { return $true }
    if ($texto -match $reTextoLP) { return $false }
    return $null
}

# ---------- Discogs ----------
# Para os leiloes sem nenhuma indicacao de formato: procura o disco no Discogs pelo titulo
# do anuncio e ve em que formatos essa edicao existe. $true = single 7"/45, $false = LP/12",
# $null = nao se sabe. As respostas ficam guardadas em discogs-cache.json (30 dias).
$script:discogsCache = @{}
$script:discogsPedidos = 0
$discogsCachePath = Join-Path $dir 'discogs-cache.json'
if (Test-Path $discogsCachePath) {
    (Ler-Texto $discogsCachePath | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $script:discogsCache[$_.Name] = $_.Value }
}

# palavras dos titulos do eBay que nao ajudam a encontrar o disco
$ruidoTitulo = @('rare','vg','vg+','ex','nm','m-','mint','near','promo','dj','wlp','hear','listen','orig','original',
    'vinyl','record','records','single','45','45rpm','rpm','7"','7','inch','garage','psych','psychedelic','punk','kbd',
    'rockabilly','rock','roll','soul','r&b','60s','50s','70s','1960s','1950s','scarce','obscure','killer','label',
    'sleeve','ps','pic','picture','lp','ep','us','uk','oz','w/','with','the','and','on','of','a','by','great','nice',
    'clean','sharp','new','sealed','unplayed','copy','press','pressing','1st','first','vintage','oop','htf','hot',
    'tours','giri','disque','schallplatte','disco','singles','lot','lote','bundle','collection','set')

function Limpar-Titulo($titulo) {
    $t = $titulo.ToLowerInvariant() -replace ('[~\-/\\|*!(),.:;"''_+#' + $aspasTodas + ']'), ' '
    # tambem fora: "2singles", "60er", "70ersammlung", "sammlung" (lotes/colecoes em alemao e afins)
    $palavras = @($t -split '\s+' | Where-Object { $_.Length -gt 1 -and ($ruidoTitulo -notcontains $_) -and ($_ -notmatch '^\d{2,4}s?$') -and
        ($_ -notmatch '^\d*(singles?|er|ers|x)$') -and ($_ -notmatch 'sammlung|konvolut') })
    return (($palavras | Select-Object -First 8) -join ' ')
}

# Edicoes do Discogs que sao o mesmo disco do anuncio: as que tem a maioria das palavras
# do titulo (o mesmo disco, nao so o mesmo artista). Devolve formato e style de cada uma.
function Correspondencias($consulta, $resultados) {
    $palavras = @($consulta -split ' ' | Where-Object { $_.Length -gt 2 })
    if ($palavras.Count -eq 0) { return @() }
    $minimo = [Math]::Max(2, [Math]::Ceiling($palavras.Count * 0.6))
    $minimo = [Math]::Min($minimo, $palavras.Count)
    $lista = @()
    foreach ($r in @($resultados)) {
        $rt = ([string]$r.title).ToLowerInvariant()
        $comuns = @($palavras | Where-Object { $rt.Contains($_) }).Count
        if ($comuns -lt $minimo) { continue }
        $lista += [pscustomobject]@{ f = (@($r.format) -join '|'); s = (@($r.style) -join '|') }
    }
    return $lista
}

# Decide a partir das edicoes encontradas e dos styles do topico (ex.: Garage Rock, Beat).
# Entra so se pelo menos METADE das edicoes Vinyl 7"/45 RPM encontradas tiver um dos styles do
# topico (uma so edicao "Garage Rock" entre varias Punk, ex.: Stiff Little Fingers, nao chega).
function Decidir-Lista($lista, $estilos) {
    $estilos = @($estilos | Where-Object { $_ })
    $singles = 0; $comEstilo = 0; $haGrande = $false
    foreach ($c in @($lista)) {
        $formatos = @(([string]$c.f) -split '\|')
        $single = ($formatos -contains 'Vinyl') -and (($formatos -contains '7"') -or ($formatos -contains '45 RPM'))
        if ($single) {
            $singles++
            $styles = @(([string]$c.s) -split '\|')
            if ($estilos.Count -eq 0 -or @($styles | Where-Object { $estilos -contains $_ }).Count -gt 0) { $comEstilo++ }
        }
        elseif (@($formatos | Where-Object { 'LP', '12"', '10"', 'Album', 'CD', 'Cassette' -contains $_ }).Count -gt 0) { $haGrande = $true }
    }
    if ($comEstilo -gt 0 -and ($comEstilo * 2) -ge $singles) { return $true }
    if ($singles -gt 0 -or $haGrande) { return $false }   # single de outro estilo, ou so existe em LP/CD
    return $null
}



# (para os testes) as duas coisas juntas
function Decidir-Discogs($consulta, $resultados, $estilos) {
    return Decidir-Lista (Correspondencias $consulta $resultados) $estilos
}

# Edicoes do Discogs que correspondem ao titulo do anuncio (com cache).
# Devolve $null se nao se pode procurar (sem token, titulo vago ou limite atingido).
function Discogs-Edicoes($titulo) {
    if (-not $config.discogs.ativo -or -not $script:chaves['DISCOGS_TOKEN']) { return $null }
    $consulta = Limpar-Titulo $titulo
    if (@($consulta -split ' ').Count -lt 2) { return $null }
    # a cache guarda as edicoes encontradas; a decisao e feita de novo para cada topico
    # (uma resposta vazia antiga, sem "r", volta a ser procurada com a 2.a tentativa abaixo)
    $c = $null; if ($script:discogsCache.ContainsKey($consulta)) { $c = $script:discogsCache[$consulta] }
    if ($c -and $null -ne $c.m -and (@($c.m).Count -gt 0 -or $c.r -or @($consulta -split ' ').Count -lt 4)) {
        return ,@($c.m)
    }
    $lista = @()
    if (-not ($c -and $null -ne $c.m)) {
        $lista = Discogs-Procurar $consulta
        if ($null -eq $lista) { return $null }
    }
    # 2.a tentativa: titulos com erros ou palavras a mais ("vor lovin", "70er Sammlung") nao dao nada;
    # procura so as 3 primeiras palavras (em geral o artista e o inicio do titulo)
    if ($lista.Count -eq 0 -and @($consulta -split ' ').Count -ge 4) {
        $curta = (@($consulta -split ' ') | Select-Object -First 3) -join ' '
        $l2 = Discogs-Procurar $curta
        if ($null -eq $l2) { return $null }
        $lista = $l2
    }
    $script:discogsCache[$consulta] = [pscustomobject]@{ m = $lista; d = $carimbo; r = 1 }
    return ,$lista
}

# Um pedido ao Discogs; devolve as edicoes que correspondem a $consulta, ou $null (erro/limite)
function Discogs-Procurar($consulta) {
    if ($script:discogsPedidos -ge $config.discogs.maxPorExecucao) { return $null }
    $script:discogsPedidos++
    Start-Sleep -Milliseconds 1100   # o Discogs aceita ~60 pedidos por minuto
    $url = 'https://api.discogs.com/database/search?type=release&per_page=10&q=' + [Uri]::EscapeDataString($consulta)
    $h = @{ Authorization = "Discogs token=$($script:chaves['DISCOGS_TOKEN'])"; 'User-Agent' = 'Leiloes45/1.0' }
    try { $r = Pedir-Json $url $h } catch { Write-Warning "Discogs: $($_.Exception.Message)"; return $null }
    return ,@(Correspondencias $consulta $r.results)
}

# So o formato: $true se o Discogs tem este disco em single Vinyl 7"/45, $false se so em LP/CD, $null se nao sabe
function Discogs-Formato($titulo) {
    $lista = Discogs-Edicoes $titulo
    if ($null -eq $lista) { return $null }
    return Decidir-Lista $lista @()
}

function Discogs-Single($titulo, $estilos) {
    $lista = Discogs-Edicoes $titulo
    if ($null -eq $lista) { return $null }
    return Decidir-Lista $lista $estilos
}


function Guardar-DiscogsCache {
    $lim = $agora.AddDays(-30).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $o = [ordered]@{}
    foreach ($k in $script:discogsCache.Keys) { $v = $script:discogsCache[$k]; if ([string]$v.d -ge $lim) { $o[$k] = $v } }
    Gravar-Texto $discogsCachePath ($o | ConvertTo-Json -Depth 3)
}

# Taxas de cambio do dia do Banco Central Europeu (1 EUR = x moeda), para mostrar tudo em euros.
# Se falhar, usa valores aproximados para a pagina continuar a funcionar.
function Obter-Cambio {
    $taxas = [ordered]@{ EUR = 1.0 }
    try {
        $x = [xml](Invoke-WebRequest -UseBasicParsing 'https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml').Content
        foreach ($c in $x.Envelope.Cube.Cube.Cube) { $taxas[[string]$c.currency] = [double]::Parse($c.rate, [Globalization.CultureInfo]::InvariantCulture) }
    } catch {
        Write-Warning "Cambio do BCE indisponivel; a usar valores aproximados."
        $taxas['USD'] = 1.10; $taxas['GBP'] = 0.85; $taxas['CAD'] = 1.55; $taxas['AUD'] = 1.65
    }
    return $taxas
}

function Itens-Demo($topico, $n) {
    $bandas = 'The Outcasts','The Shag','Twelfth Night','The Boss Five','The Liberty Bell','Sue Patrick & The Nomads','The Weirdos','The Zeros','The Avengers','Back Street','The Fugitives','The Spiders'
    $editoras = 'Impact','Renfro','Capitol','Dangerhouse','Bomp','Process','Private press','Teen Sound'
    $graus = 'NM','VG+','EX','VG'
    $rnd = New-Object Random ($topico.nome.GetHashCode())
    1..$n | ForEach-Object {
        $b = $bandas[$rnd.Next($bandas.Count)]
        [ordered]@{
            id = "demo-$($topico.nome.Length)-$_"
            titulo = "EXEMPLO - $($topico.nome.ToUpper()) - $b - $($editoras[$rnd.Next($editoras.Count)]) 45 $($graus[$rnd.Next($graus.Count)])"
            url = 'https://www.ebay.com/sch/i.html?_nkw=' + [Uri]::EscapeDataString($topico.pesquisa) + '&LH_Auction=1'
            img = $null
            preco = [Math]::Round(5 + $rnd.NextDouble() * 300, 2)
            moeda = 'USD'
            licitacoes = $rnd.Next(0, 25)
            fim = $agora.AddMinutes($rnd.Next(20, 7 * 24 * 60)).ToString('yyyy-MM-ddTHH:mm:ss.000Z')
            estado = 'Used'
            vendedor = 'vendedor_exemplo'
            feedback = $rnd.Next(10, 5000)
            pais = ('US','FR','DE','IT','ES')[$rnd.Next(5)]
            envio = [Math]::Round(4 + $rnd.NextDouble() * 15, 2)
            site = ('ebay.com','ebay.fr','ebay.de','ebay.it','ebay.es')[$rnd.Next(5)]
        }
    }
}

# --- recolha ---
$token = $null
if (-not $Demo) { $script:chaves = Ler-Chaves; $token = Obter-Token; $script:token = $token }
$resultado = @(); $erros = @()
# Discos que um topico manda para outro (config "reencaminhar"): ex.: "garage punk" no titulo
# fica so em Garage, a menos que o titulo tenha outra palavra de punk ("kbd", "punk" solto...).
# Depois o Discogs pode acrescentar-lhe Punk, se o style dele for Punk.
$outros = @()
# "fixo": o disco fica SO nesse genero (ex.: "kbd" -> so Punk); sai dos outros e o Discogs nao lhe acrescenta generos
$fixos = @{}
function Reencaminhar-Para($t, $titulo) {
    foreach ($r in @($t.reencaminhar)) {
        if (-not $r -or [string]$titulo -notmatch $r.padrao) { continue }
        $resto = [string]$titulo -replace $r.padrao, ' '
        if (-not $r.manterSe -or $resto -notmatch $r.manterSe) { return $r }
    }
    return $null
}

foreach ($t in $config.topicos) {
    Write-Host "A procurar: $($t.nome) ..."
    try {
        if ($Demo) { $lista = Itens-Demo $t 12 }
        else {
            # junta todos os sites; o numero do leilao evita repeticoes
            $lista = @(); $ids = @{}
            foreach ($m in $mercados) {
                try {
                    # Regra simples:
                    #  A) o titulo tem a palavra do genero (garage, psych, rockabilly, power pop, punk/kbd) -> entra
                    #     (desde que seja um single 7"/45);
                    #  B) o titulo nao tem a palavra -> so entra se o style do Discogs for deste genero.
                    $generos = $t.generos; if (-not $generos) { $generos = $t.pesquisa }
                    $reGen = Regex-Genero $t
                    $script:quotaCombo = [Math]::Max(20, [int]($script:maxDetalhes / [Math]::Max(1, @($mercados).Count * @($config.topicos).Count)))
                    $cand = [ordered]@{}   # num -> @{ s = resumo; single = $true (veio da pesquisa 7"/45) / $null }

                    # 1) leiloes com a caracteristica 7" ou 45 rpm e a palavra do genero (no titulo ou no anuncio)
                    foreach ($a in @(Aspectos-Single $m $generos)) {
                        foreach ($s in (Pesquisar $m $generos $a)) { $cand[[string]$s.legacyItemId] = @{ s = $s; single = $true } }
                    }
                    # 2) todos os leiloes com a palavra do genero (sem exigir 45): aqui so contam os que a tem no titulo
                    foreach ($s in (Pesquisar $m $generos $null -max $config.verificarDescricao.maxPesquisa)) {
                        $k = [string]$s.legacyItemId
                        if (-not $cand.Contains($k) -and $s.title -match $reGen) { $cand[$k] = @{ s = $s; single = $null } }
                    }

                    $novos = 0; $pelaDiscogs = 0; $semFormato = 0; $naoDiscogs = 0
                    foreach ($num in $cand.Keys) {
                        $s = $cand[$num].s
                        if (-not $num -or $ids.ContainsKey($num)) { continue }
                        if (Excluido $s.title $t.excluir) { continue }
                        $single = $cand[$num].single
                        if ($s.title -match $reTitulo45) { $single = $true }                # 7" / 45 / single no titulo
                        elseif ($null -eq $single -and $s.title -match $reTextoLP) { continue } # LP / 12" / album no titulo

                        if ($s.title -match $reGen) {
                            # A) genero no titulo: falta so confirmar que e single (detalhes do anuncio, ou Discogs)
                            if ($null -eq $single) { $single = (Info-Detalhes $m $num).single }
                            if ($null -eq $single) { $single = Discogs-Formato $s.title }
                            if ($single -ne $true) { $semFormato++; continue }
                        } else {
                            # B) genero fora do titulo: o Discogs tem de dizer single E style deste genero
                            if ((Discogs-Single $s.title $t.estilosDiscogs) -ne $true) { $naoDiscogs++; continue }
                            $pelaDiscogs++
                        }
                        $ids[$num] = 1
                        $i = Converter-Item $s $m
                        $i['id'] = $num
                        $para = Reencaminhar-Para $t $s.title
                        if ($para) { $outros += @{ para = $para.para; item = $i; fixo = [bool]$para.fixo }; continue }
                        $lista += $i; $novos++
                    }
                    Write-Host "  $($dominios[$m]): $novos (dos quais $pelaDiscogs pelo Discogs; fora: $semFormato sem formato single confirmado, $naoDiscogs sem o genero no titulo nem no Discogs)"
                } catch {
                    $msg = "$($t.nome) on $($dominios[$m]): $($_.Exception.Message)"
                    Write-Warning $msg; $erros += $msg
                }
            }
        }
        $resultado += [ordered]@{ nome = $t.nome; pesquisa = $t.pesquisa; itens = @($lista) }
        Write-Host "  $(@($lista).Count) leiloes"
    } catch {
        $msg = "$($t.nome): $($_.Exception.Message)"
        Write-Warning $msg
        $erros += $msg
        $resultado += [ordered]@{ nome = $t.nome; pesquisa = $t.pesquisa; itens = @() }
    }
}

# --- discos reencaminhados (ex.: "garage punk" -> Garage) ---
foreach ($o in $outros) {
    $tp = $resultado | Where-Object { $_.nome -eq $o.para } | Select-Object -First 1
    if (-not $tp) { continue }
    if (@($tp.itens | Where-Object { $_.id -eq $o.item.id }).Count -eq 0) { $tp.itens = @($tp.itens) + $o.item }
    if ($o.fixo) { $fixos[$o.item.id] = $o.para }
}
if ($outros.Count -gt 0) { Write-Host "Reencaminhados para outro genero: $($outros.Count)" }

# --- Discogs: acrescenta generos ---
# Um disco ja escolhido (pelo titulo ou pelo Discogs) aparece tambem noutro genero se o style do Discogs
# for desse genero (regra da metade: uma so edicao "Garage Rock" entre varias Punk nao chega).
# Excecoes: "kbd" no titulo -> so Punk (regra "fixo" no config.json).
if (-not $Demo -and $config.discogs.confirmarTodos) {
    $unicos = [ordered]@{}
    foreach ($tp in $resultado) { foreach ($i in $tp.itens) { if (-not $unicos.Contains($i.id)) { $unicos[$i.id] = $i } } }
    $novaLista = @{}; foreach ($tp in $resultado) { $novaLista[$tp.nome] = New-Object System.Collections.ArrayList }
    $mudados = 0
    foreach ($id in $unicos.Keys) {
        $i = $unicos[$id]
        $destino = @($resultado | Where-Object { @($_.itens | Where-Object { $_.id -eq $id }).Count -gt 0 } | ForEach-Object { $_.nome })
        if ($fixos.ContainsKey($id)) { $destino = @($fixos[$id]) }
        else {
            $ed = Discogs-Edicoes $i.titulo
            if ($null -ne $ed -and @($ed).Count -gt 0) {
                $extra = @($config.topicos | Where-Object { $destino -notcontains $_.nome -and (Decidir-Lista $ed $_.estilosDiscogs) -eq $true } |
                    Where-Object { $r = Reencaminhar-Para $_ $i.titulo; -not ($r -and $r.fixo) } | ForEach-Object { $_.nome })
                if ($extra.Count -gt 0) { $destino += $extra; $mudados++ }
            }
        }
        foreach ($n in $destino) { [void]$novaLista[$n].Add($i) }
    }
    foreach ($tp in $resultado) { $tp.itens = @($novaLista[$tp.nome]) }
    Write-Host "Discogs: $mudados discos acrescentados a outros generos"
}
foreach ($tp in $resultado) {
    foreach ($i in $tp.itens) {
        if (-not $vistos.ContainsKey($i.id)) { $vistos[$i.id] = $carimbo }
        $visto = [string]$vistos[$i.id]
        $i['novo'] = (-not $primeiraVez) -and ($visto -gt $inicio) -and ($visto -ge $limiteNovo)
    }
}

# --- observadores ---
$todos = @($resultado | ForEach-Object { $_.itens } | Where-Object { $_.num })
if (-not $Demo -and $todos.Count -gt 0 -and $config.observadores.ativo) {
    if (-not $script:chaves['EBAY_USER_TOKEN']) {
        $erros += 'Watchers: EBAY_USER_TOKEN is missing in chaves.env.'
    } else {
        $nums = @($todos | ForEach-Object { $_.num } | Select-Object -Unique)
        try {
            Write-Host "Observadores: a tentar GetItem ..."
            $obs = Observadores-GetItem $nums
            if ($null -eq $obs) {
                if ($config.observadores.usarListaObservados) {
                    Write-Host "  GetItem nao devolve o numero; a usar a lista de observados da conta ..."
                    $obs = Observadores-Lista $nums
                } else {
                    # (ler as paginas dos leiloes tambem nao serve: o eBay bloqueia programas com 403 / Error Page)
                    # so no registo, nao na pagina: para quem visita aparece "watchers: unknown" em cada leilao
                    Write-Host '  Seguidores: o eBay nao da o numero pelo GetItem (so ao vendedor).'
                    $obs = @{}
                }
            }
            foreach ($i in $todos) { if ($obs.ContainsKey($i.num)) { $i['observadores'] = $obs[$i.num] } }
            Write-Host "  $($obs.Count) leiloes com numero de observadores"
        } catch {
            $erros += "Watchers: $($_.Exception.Message)"
        }
    }
}
# --- seguidores lidos a mao no browser (observadores.json: { "lido": data, "w": { "numero": seguidores } }) ---
# O eBay nao da o numero a programas; estes numeros sao lidos nas paginas dos leiloes, num browser,
# e carregados no GitHub. Servem enquanto o leilao estiver ativo (so para os que a API nao trouxe).
$obsManualPath = Join-Path $dir 'observadores.json'
if (-not $Demo -and (Test-Path $obsManualPath)) {
    try {
        $om = Ler-Texto $obsManualPath | ConvertFrom-Json
        $wm = @{}; foreach ($p in $om.w.PSObject.Properties) { $wm[$p.Name] = [int]$p.Value }
        # "zero": numeros dos leiloes lidos sem seguidores, separados por virgulas
        foreach ($n in (([string]$om.zero) -split ',')) { if ($n -and -not $wm.ContainsKey($n)) { $wm[$n] = 0 } }
        $usados = 0
        foreach ($tp in $resultado) { foreach ($i in $tp.itens) {
            if ($null -eq $i['observadores'] -and $wm.ContainsKey([string]$i.id)) { $i['observadores'] = $wm[[string]$i.id]; $usados++ }
        } }
        Write-Host "Seguidores lidos a mao ($($om.lido)): $usados leiloes"
    } catch { Write-Warning "observadores.json: $($_.Exception.Message)" }
}
if ($Demo) {
    $rnd = New-Object Random 7
    foreach ($tp in $resultado) { foreach ($i in $tp.itens) { $i['observadores'] = $rnd.Next(0, 40) } }
}

# --- guardar vistos (esquece itens com mais de 45 dias) ---
$limiteData = $agora.AddDays(-45).ToString('yyyy-MM-ddTHH:mm:ssZ')
$limpo = [ordered]@{}
foreach ($k in $vistos.Keys) { if ($k -eq '__inicio' -or $vistos[$k] -ge $limiteData) { $limpo[$k] = $vistos[$k] } }
if (-not $Demo) {
    Gravar-Texto $vistosPath ($limpo | ConvertTo-Json -Depth 3)
    if ($script:discogsCache.Count -gt 0) { Guardar-DiscogsCache }
    if ($script:discogsPedidos -gt 0) { Write-Host "Discogs: $($script:discogsPedidos) pesquisas" }
    Write-Host "Detalhes de leiloes pedidos ao eBay: $($script:pedidosDetalhe) (limite $($script:maxDetalhes))"
}

# --- gerar pagina ---
$dados = [ordered]@{
    gerado = $carimbo; demo = [bool]$Demo; primeiraVez = $primeiraVez
    mercado = (($mercados | ForEach-Object { $dominios[$_] -replace '^www\.', '' }) -join ', ')
    topicos = $resultado; erros = $erros
    cambio = (Obter-Cambio)
}
$json = $dados | ConvertTo-Json -Depth 8 -Compress
$json = $json.Replace('</', '<\/')
$modelo = Ler-Texto (Join-Path $dir 'modelo.html')
# o logo vai dentro da propria pagina, para aparecer tambem quando se partilha so o leiloes.html
$logo = Join-Path $dir 'player.gif'
if (Test-Path $logo) {
    $modelo = $modelo.Replace('src="player.gif"', 'src="data:image/gif;base64,' + [Convert]::ToBase64String([IO.File]::ReadAllBytes($logo)) + '"')
}
# (o PowerShell nao distingue maiusculas: $ficheiroPagina nao pode chamar-se $saida, senao apaga o parametro -Saida)
$ficheiroPagina = Join-Path $dir 'leiloes.html'
if ($Saida) {
    # ex.: index.html no GitHub
    $ficheiroPagina = if ([IO.Path]::IsPathRooted($Saida)) { $Saida } else { Join-Path $dir $Saida }
    $pastaSaida = Split-Path $ficheiroPagina
    if (-not (Test-Path $pastaSaida)) { New-Item -ItemType Directory -Path $pastaSaida | Out-Null }
}
Gravar-Texto $ficheiroPagina ($modelo.Replace('/*DADOS*/null', $json))
Write-Host "Pagina gerada: $ficheiroPagina"
if ($Abrir) { Start-Process $ficheiroPagina }
