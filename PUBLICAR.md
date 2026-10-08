# Publicar em 45recordsauction.com (GitHub Pages)

## 1. Conta e repositório
1. Crie uma conta gratuita em https://github.com (se ainda não tiver).
2. Carregue em **New repository**:
   - Nome: `45recordsauction`
   - **Public** (o GitHub Pages gratuito exige repositório público; as chaves não vão para lá)
   - Carregue em **Create repository**.

## 2. Carregar os ficheiros
1. No repositório novo, carregue em **uploading an existing file**.
2. Arraste **todo o conteúdo** desta pasta `github` (incluindo as pastas `.github` e `publicar`).
   - Se o Explorador do Windows não mostrar a pasta `.github`: Ver → Mostrar → Itens ocultos.
3. Carregue em **Commit changes**.

## 3. Ativar o GitHub Pages
1. **Settings → Pages**.
2. Em **Source**, escolha **GitHub Actions**.
3. Em **Custom domain**, escreva `45recordsauction.com` e carregue em **Save**.

## 4. Apontar o domínio (no seu fornecedor do domínio)
No painel DNS do domínio, crie estes registos (apague antes outros registos **A** de `@`, se houver):

| Tipo  | Nome | Valor                        |
|-------|------|------------------------------|
| A     | @    | 185.199.108.153              |
| A     | @    | 185.199.109.153              |
| A     | @    | 185.199.110.153              |
| A     | @    | 185.199.111.153              |
| CNAME | www  | rockaroundtheblog-create.github.io |

A propagação pode levar de minutos a 24 horas. Depois, em **Settings → Pages**, ative **Enforce HTTPS**.

## 5. Primeira publicação
**Actions → Atualizar 45recordsauction.com → Run workflow**. Sem chaves do eBay, publica a página atual.

## 6. Quando tiver as chaves do eBay
**Settings → Secrets and variables → Actions → New repository secret**, um de cada vez:
`EBAY_APP_ID`, `EBAY_CERT_ID`, `EBAY_DEV_ID`, `EBAY_USER_TOKEN`, `DISCOGS_TOKEN`.

A partir daí o site atualiza-se sozinho todos os dias às 06:00 UTC (07:00 em Portugal no inverno).
