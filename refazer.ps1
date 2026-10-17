# Refaz index.html SEM pesquisar o eBay: usa os leiloes que ja estao na pagina publicada,
# o modelo.html atual e os seguidores de observadores.json. Serve quando so mudou o aspeto
# da pagina ou os seguidores (demora segundos e nao gasta o limite diario de pedidos ao eBay).
# Uso: .\refazer.ps1 [-Pagina index.html]
param([string]$Pagina = 'index.html')
$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot
$utf8 = New-Object System.Text.UTF8Encoding($false)
function Ler-Texto($p) { [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) }

$ficheiro = if ([IO.Path]::IsPathRooted($Pagina)) { $Pagina } else { Join-Path $dir $Pagina }
$html = Ler-Texto $ficheiro
# os dados estao na pagina entre "const D=" e o ";" depois de "cambio"
$i = $html.IndexOf('const D=')
if ($i -lt 0) { throw "Nao encontrei os dados em $Pagina" }
$i += 8
$j = $html.IndexOf(';', $html.IndexOf('"cambio"', $i))
$json = $html.Substring($i, $j - $i)
$dados = $json | ConvertFrom-Json

# seguidores lidos a mao: os numeros de observadores.json sao os mais recentes
$obsPath = Join-Path $dir 'observadores.json'
if (Test-Path $obsPath) {
    $om = Ler-Texto $obsPath | ConvertFrom-Json
    $wm = @{}; foreach ($p in $om.w.PSObject.Properties) { $wm[$p.Name] = [int]$p.Value }
    foreach ($n in (([string]$om.zero) -split ',')) { if ($n -and -not $wm.ContainsKey($n)) { $wm[$n] = 0 } }
    $usados = 0
    foreach ($tp in $dados.topicos) { foreach ($it in $tp.itens) {
        if ($wm.ContainsKey([string]$it.id)) { $it.observadores = $wm[[string]$it.id]; $usados++ }
    } }
    Write-Host "Seguidores de observadores.json ($($om.lido)): $usados leiloes"
}

$novoJson = ($dados | ConvertTo-Json -Depth 8 -Compress).Replace('</', '<\/')
$modelo = Ler-Texto (Join-Path $dir 'modelo.html')
$logo = Join-Path $dir 'player.gif'
if (Test-Path $logo) { $modelo = $modelo.Replace('src="player.gif"', 'src="data:image/gif;base64,' + [Convert]::ToBase64String([IO.File]::ReadAllBytes($logo)) + '"') }
[IO.File]::WriteAllText($ficheiro, $modelo.Replace('/*DADOS*/null', $novoJson), $utf8)
Write-Host "Pagina refeita (sem pesquisar o eBay): $ficheiro"
