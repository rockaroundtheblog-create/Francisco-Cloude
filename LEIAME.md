# Leilões 45s

Procura todos os dias leilões no eBay (só leilões, categoria Discos de vinil) para os tópicos de `config.json` e gera `leiloes.html`.

## Ficheiros
- `config.json`: tópicos, palavras a excluir, mercado (EBAY_US, EBAY_GB, EBAY_DE…) e categoria
- `chaves.env`: as suas chaves do eBay (criar a partir de `chaves.env.example`)
- `correr.bat`: corre a procura (`correr.bat -Demo` usa dados inventados; `-Abrir` abre a página no fim)
- `leiloes.ps1`: o script
- `modelo.html`: o modelo da página
- `vistos.json`: gerado; regista os leilões já vistos para marcar os novos

## Obter as chaves (uma vez)
1. Criar conta em https://developer.ebay.com e entrar.
2. Em *Application Keys*, criar um conjunto de chaves de **Production**.
3. Copiar o **App ID (Client ID)** e o **Cert ID (Client Secret)** para `chaves.env`.

## Observadores
Precisam de `EBAY_DEV_ID` e `EBAY_USER_TOKEN` em `chaves.env` (token Auth'n'Auth gerado em https://developer.ebay.com/my/auth).
1. O script tenta primeiro o GetItem com `IncludeWatchCount`.
2. Se o eBay não devolver o número, e `"usarListaObservados": true` estiver em `config.json`, junta os leilões à lista de observados da sua conta, lê o número com GetMyeBayBuying e desconta o seu. Os leilões que o script juntou e já terminaram são retirados da lista em cada execução (registo em `lista-observados.json`).

## Como encontra os singles (por site e por tópico)
1. **Características do anúncio**: leilões com tamanho 7" ou velocidade 45 preenchidos pelo vendedor (os nomes mudam com a língua do site e são descobertos automaticamente).
2. **Título**: `pesquisa` (ex.: `(punk,kbd) 45`).
3. **Descrição**: para os restantes leilões do género (`generos`), sem formato indicado, lê a descrição e as características; entra se falar em 45 rpm / 45 tours / 45 giri / 7" / single. Limites em `verificarDescricao` (`maxPesquisa`, `maxVerificar`).

4. **Discogs**: se nada escrito no anúncio indicar o formato, procura o disco no Discogs pelo título (sem palavras como "rare", "vg+", "45") e vê em que formatos essa edição existe. Entra se houver edições em 7"/45 RPM e não só em LP. Precisa de `DISCOGS_TOKEN` em `chaves.env` (gratuito, em discogs.com → Settings → Developers). Limite em `discogs.maxPorExecucao`; as respostas ficam em `discogs-cache.json` durante 30 dias.

Cada leilão entra uma só vez (pelo número). Cada site é pesquisado como se o comprador estivesse nesse país, para aparecerem todos os anúncios, incluindo os que só enviam dentro do país. Não há filtro por país de entrega: contam todos.

## Pesquisa do tópico
`pesquisa` usa a sintaxe do eBay: palavras separadas por espaço = todas; `(a,b)` = qualquer uma.
As palavras de `excluir` são retiradas pelo script, comparando com o título.

## Agendar 1 vez por dia (Agendador de Tarefas do Windows)
```
schtasks /Create /TN "Leiloes 45s" /SC DAILY /ST 09:00 /TR "\"C:\caminho\para\correr.bat\""
```
