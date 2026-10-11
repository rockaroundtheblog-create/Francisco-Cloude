# Gera loja.html: os discos a venda no Discogs (inventario do vendedor), no mesmo estilo do site.
# Le o inventario pela API do Discogs (DISCOGS_TOKEN em chaves.env), junta o style/genero de cada
# disco (guardado em discogs-discos.json para nao voltar a pedir) e escreve a pagina a partir de modelo-loja.html.
# Uso: .\loja.ps1 [-Saida loja.html]
param([string]$Saida)
$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$utf8 = New-Object System.Text.UTF8Encoding($false)
function Ler-Texto($p) { [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) }
function Gravar-Texto($p, $t) { [IO.File]::WriteAllText($p, $t, $utf8) }

$vendedor = 'franciscoratb'
$cfgPath = Join-Path $dir 'config.json'
if (Test-Path $cfgPath) { $cfg = Ler-Texto $cfgPath | ConvertFrom-Json; if ($cfg.loja -and $cfg.loja.vendedor) { $vendedor = $cfg.loja.vendedor } }

$chaves = @{}
$envPath = Join-Path $dir 'chaves.env'
if (Test-Path $envPath) { foreach ($l in Get-Content $envPath) { if ($l -match '^\s*([A-Z_]+)\s*=\s*(.*?)\s*$') { $chaves[$Matches[1]] = $Matches[2] } } }
if (-not $chaves['DISCOGS_TOKEN'] -and $env:DISCOGS_TOKEN) { $chaves['DISCOGS_TOKEN'] = $env:DISCOGS_TOKEN }
$cab = @{ 'User-Agent' = 'Leiloes45/1.0' }
# com o token o Discogs devolve tambem as fotos dos discos
if ($chaves['DISCOGS_TOKEN']) { $cab['Authorization'] = "Discogs token=$($chaves['DISCOGS_TOKEN'])" }

# pedidos com o texto lido em UTF-8 (o Invoke-RestMethod do PowerShell 5.1 estraga os acentos)
function Pedir-Json($url) {
    for ($tentativa = 1; ; $tentativa++) {
        try { $r = Invoke-WebRequest -Uri $url -Headers $cab -UseBasicParsing; break }
        catch {
            $codigo = 0; try { $codigo = [int]$_.Exception.Response.StatusCode } catch {}
            if ($codigo -ne 429 -or $tentativa -ge 3) { throw }
            Start-Sleep -Seconds (20 * $tentativa)
        }
    }
    [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json
}

# --- inventario (100 por pagina) ---
$listagens = @(); $pag = 1
do {
    $r = Pedir-Json "https://api.discogs.com/users/$vendedor/inventory?status=For%20Sale&sort=listed&sort_order=desc&per_page=100&page=$pag"
    $listagens += @($r.listings)
    $totalPag = [int]$r.pagination.pages; $pag++
    Start-Sleep -Milliseconds 1100
} while ($pag -le $totalPag)
Write-Host "Loja: $($listagens.Count) discos a venda"

# --- style e genero de cada disco (cache em discogs-discos.json) ---
$cachePath = Join-Path $dir 'discogs-discos.json'
$cache = @{}
if (Test-Path $cachePath) { (Ler-Texto $cachePath | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $cache[$_.Name] = $_.Value } }
$pedidos = 0
foreach ($l in $listagens) {
    $rid = [string]$l.release.id
    if ($cache.ContainsKey($rid)) { continue }
    try {
        $rel = Pedir-Json $l.release.resource_url
        $cache[$rid] = [pscustomobject]@{ s = @($rel.styles); g = @($rel.genres); p = [string]$rel.country }
    } catch { Write-Warning "Discogs $($rid): $($_.Exception.Message)" }
    $pedidos++; Start-Sleep -Milliseconds 1100
}
if ($pedidos -gt 0) { Write-Host "Loja: $pedidos discos novos consultados no Discogs" }
# so guarda os discos que ainda estao a venda
$ativos = @{}; foreach ($l in $listagens) { $ativos[[string]$l.release.id] = 1 }
$o = [ordered]@{}; foreach ($k in $cache.Keys) { if ($ativos.ContainsKey($k)) { $o[$k] = $cache[$k] } }
Gravar-Texto $cachePath ($o | ConvertTo-Json -Depth 4)

# --- montar os dados da pagina ---
function Primeiro($texto) { (([string]$texto) -split ',\s*' | Where-Object { $_ } | Select-Object -First 1) }
function Curto($cond) { if ($cond -match '\(([^)]+)\)\s*$') { $Matches[1] } else { [string]$cond } }
$itens = foreach ($l in $listagens) {
    $rel = $l.release; $info = $cache[[string]$rel.id]
    $img = $null
    $imgs = @($rel.images)
    if ($imgs.Count -gt 0) { $img = if ($imgs[0].uri) { $imgs[0].uri } else { $imgs[0].uri150 } }
    if (-not $img -and $rel.thumbnail) { $img = $rel.thumbnail }
    # artista sem o numero que o Discogs junta aos nomes repetidos: "Riviera (3)" -> "Riviera"
    $artista = ([string]$rel.artist) -replace '\s*\(\d+\)', '' -replace '\*$', ''
    [ordered]@{
        id = [string]$l.id; url = $l.uri
        artista = $artista; titulo = [string]$rel.title
        editora = ((Primeiro $rel.label) -replace '\s*\(\d+\)', ''); cat = (Primeiro $rel.catalog_number)
        ano = $(if ([int]$rel.year -gt 0) { [int]$rel.year } else { $null })
        formato = [string]$rel.format
        disco = (Curto $l.condition); capa = (Curto $l.sleeve_condition)
        preco = [double]$l.price.value; moeda = [string]$l.price.currency
        img = $img
        styles = @($info.s | Where-Object { $_ }); generos = @($info.g | Where-Object { $_ }); pais = $(if ($info) { [string]$info.p } else { '' })
        quer = $(if ($rel.stats -and $rel.stats.community) { [int]$rel.stats.community.in_wantlist } else { 0 })
        notas = [string]$l.comments; posto = [string]$l.posted
    }
}
$v = $listagens | Select-Object -First 1 | ForEach-Object { $_.seller }
$dados = [ordered]@{
    gerado = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    vendedor = [ordered]@{
        nome = $vendedor; url = "https://www.discogs.com/seller/$vendedor/profile"
        nota = $(if ($v) { [string]$v.stats.rating } else { '' }); avaliacoes = $(if ($v) { [int]$v.stats.total } else { 0 })
        envio = $(if ($v) { [string]$v.shipping } else { '' }); pagamento = $(if ($v) { [string]$v.payment } else { '' })
    }
    itens = @($itens)
}
$json = ($dados | ConvertTo-Json -Depth 6 -Compress).Replace('</', '<\/')
$modelo = Ler-Texto (Join-Path $dir 'modelo-loja.html')
$logo = Join-Path $dir 'player.gif'
if (Test-Path $logo) { $modelo = $modelo.Replace('src="player.gif"', 'src="data:image/gif;base64,' + [Convert]::ToBase64String([IO.File]::ReadAllBytes($logo)) + '"') }
$ficheiro = Join-Path $dir 'loja.html'
if ($Saida) { $ficheiro = if ([IO.Path]::IsPathRooted($Saida)) { $Saida } else { Join-Path $dir $Saida } }
Gravar-Texto $ficheiro ($modelo.Replace('/*DADOS*/null', $json))
Write-Host "Loja gerada: $ficheiro"
