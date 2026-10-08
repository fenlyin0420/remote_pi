# Contrato — Pareamento (rollback E2E, 2026-05-19)

Fonte de verdade do pareamento entre **app** (Flutter) e **pi-remote**
(Node), com **relay** (Rust) só roteando payload opaco. Modelo MVP:
**1 pareamento = 1 sessão Pi**.

> **Cripto E2E removida** (plano 06). Mensagens trafegam em **JSON em claro
> base64** no `ct` do outer envelope. Confiança contra terceiros vem de
> TLS no transporte (futuro relay público) + Ed25519 challenge-response
> pra impedir squatting. Operador do relay vê conteúdo — usuário sério
> deve self-hostar o relay (open-source). Re-ativar E2E é roadmap aditivo
> (plano 09 opcional) — shape do envelope permanece igual.

---

## QR payload

URI scheme: `remotepi://pair?...`

Campos (query string, URL-encoded):

| Campo | Tipo | Descrição |
|---|---|---|
| `t` | base64url, 16 bytes | Token efêmero. Single-use. Válido por 60s |
| `epk` | base64url, 32 bytes | Pubkey **Ed25519** de longo prazo do Mac. Único peer ID do Pi no relay |
| ~~`r`~~ | ~~string~~ | **REMOVIDO (plano 14, 2026-05-21)** — relay agora vem de config do app (`Preferences.relayUrl`) e do pi-ext (env `REMOTE_PI_RELAY` ou config file). Encurta QR em ~30-50 chars. Legacy QRs com `r` ainda são lidos pelo app com aviso de conflito (modal) |
| `n` | string UTF-8, max 80 chars | Nome legível da sessão (ex: `remote_pi · feature/protocol`) |
| `rm` | base64url, 12 chars | **ADICIONADO (plano 17 fix, 2026-05-21)** — room_id derivado do cwd (`base64url(sha256(realpath(cwd)))[:12]`). Sem isso, app não saberia pra qual room mandar `pair_request` e tentaria a "main" (que falha porque Pi atual está em room=hash). Legacy QRs sem `rm` fallback pra "main" |

> **Por que só Ed25519?** O `pk` (Curve25519) do plano 04 servia ao
> handshake Noise XX. Sem Noise, sobra apenas a chave de autenticação
> Ed25519 — usada pelo challenge-response do relay e como identificador
> de peer roteável. O `epk` do plano 04 vira simplesmente `epk` (não há
> mais ambiguidade com `pk`).

> **Por que sem `r` (plano 14)?** App e pi-ext compartilham a mesma
> constante `kDefaultRelayUrl = 'wss://relay.remote-pi.dev'`, ambas
> sobreponíveis via Settings (app) / env+config (pi-ext). Pareamento
> assume mesmo relay nos 2 lados. Se app tem relay diferente do Pi,
> sync `pair_request` simplesmente falha por timeout — app mostra erro
> "Pi não respondeu, verifique se está no mesmo relay".

**Regras**:
- QR rotaciona a cada 60s no terminal do Pi
- Cada token aceita **1 uso** — pi-remote marca consumido após `pair_request` válido
- Novo `/remote-pi pair` invalida o token anterior (um pair em curso = um QR ativo)
- Token expirado/consumido/desconhecido → Pi responde `pair_error` (não fecha WS)

---

## Fluxo de pareamento (3 mensagens, sem cripto)

```
APP                                       PI-EXTENSION
───                                       ────────────
escaneia QR, valida t não expirou local
abre WS, auth Ed25519 (challenge-resp)

pair_request {                            ──▶  valida t (presente, vivo, não consumido)
  id: uuid,                                    valida peer Ed25519 do app (já tem do relay auth)
  token: "<t do QR>",                          consome t
  device_name: "iPhone do Jacob"               salva peer em peers.json:
}                                                {epk_app, name, paired_at}

                                          ◀──  pair_ok {
                                                 in_reply_to: <uuid>,
                                                 session_name: "remote_pi · feature/protocol",
                                                 session_started_at: 1716234500000  // epoch ms quando /remote-pi start rodou — usado pelo session_sync (plano 11) pra detectar Pi restart
                                               }

                                          OU em erro:
                                          ◀──  pair_error {
                                                 in_reply_to: <uuid>,
                                                 code: "token_expired" | "token_consumed"
                                                       | "token_unknown" | "internal_error",
                                                 message: "Token efêmero expirou..."
                                               }

UI mostra "Pareado com <session_name>"
adopta canal pra ChatPage
```

A partir daí, todas as mensagens do inner envelope (`protocol.md`)
trafegam em **JSON em claro base64** no `ct` do outer envelope.

> **Sem `safety number`** — não há derivação criptográfica bilateral
> pra mostrar. Confiança vem de: (a) token do QR ser single-use, (b)
> peer ID (Ed25519) do Pi estar no QR, (c) auth no relay garantir que
> só quem tem a privkey Ed25519 do app consegue assinar como o app.

---

## Storage pós-pareamento

### Mac — `~/.pi/remote/peers.json` (público)

```json
{
  "peers": [
    {
      "name": "iPhone do Jacob",
      "remote_epk": "<base64 standard, 32 bytes Ed25519>",
      "paired_at": "2026-05-19T16:00:00Z"
    }
  ]
}
```

Campos `remote_pk` (Curve25519), `session_id`, `session_name` removidos —
não havia mais uso fora do Noise/safety/cred-helper.

### Mac — Keychain (privado)

- ~~Chave de longo prazo Curve25519~~ removida (sem Noise)
- Chave Ed25519 pra auth no relay — **singleton por Mac**, gerada na 1ª
  invocação de `/remote-pi start`
- Bridge: `security add-generic-password -s dev.remotepi.mac -a longterm-ed25519 -w <base64>`

### Mobile — Keychain (iOS) / Keystore (Android)

Por pareamento (`service: dev.remotepi.peers`, account = hash do `remote_epk`):

```json
{
  "remote_epk": "<base64 standard, 32B Ed25519>",
  "session_name": "...",
  "relay_url": "...",
  "paired_at": "..."
}
```

Campos `remote_pk`, `local_pk`, `local_sk` (Curve25519) removidos — não
existem mais sem Noise.

Device-level singleton (`service: dev.remotepi.device`, account = `ed25519`):

```json
{
  "pk": "<base64 standard, 32B Ed25519>",
  "sk": "<base64 standard, 32B Ed25519>"
}
```

Gerada na primeira execução do app, persiste pra todos os pareamentos.
Implementação Flutter via `flutter_secure_storage`.

---

## Reconexão

Em cada reconexão (app reabrindo, rede caindo e voltando):

1. App lê pareamento do Keychain
2. Conecta no relay (challenge-response Ed25519)
3. **Sem novo handshake** — o canal já está paired no Pi (auto-listener
   do `started` state aceita peer presente em `peers.json`)
4. App envia próxima mensagem do protocolo normal (ex: `user_message` ou `ping`)

> **Sem forward secrecy nesta versão** — sem Noise, sem keys de sessão.
> TLS no transporte protege contra escuta passiva enquanto a conexão
> está aberta, mas o relay vê tudo. Trade-off aceito por simplicidade
> do MVP; revisitado em plano 09 (E2E restore).

---

## Challenge-response do relay (autenticação)

**Inalterado pelo rollback.** Antes de qualquer roteamento, peer
autentica no relay com sua chave **Ed25519 de longo prazo**:

1. Cliente abre WS, envia `{ "type": "hello", "pubkey": "<base64 Ed25519 32 bytes>" }`
2. Relay responde `{ "type": "challenge", "nonce": "<base64 32 bytes random>" }`
3. Cliente assina `nonce` com sua Ed25519 privkey e envia `{ "type": "auth", "sig": "<base64 64 bytes>" }`
4. Relay valida assinatura (`ed25519-dalek`)
5. Se válido → adiciona peer ao roteamento. Se não → fecha WS em <100ms

Relay **continua opaco** ao conteúdo do `ct`. Mesmo sem cifra E2E, o
relay **nunca chama `JSON.parse(ct)`** — só faz roteamento por `peer`.
Logs proibidos de incluir `ct` (princípio mantido, mesmo que conteúdo
agora seja teoricamente legível).

---

## Revoke (previsto, não implementado no MVP)

- Mac: remover entrada de `~/.pi/remote/peers.json` + comando `/remote-pi revoke <nome>`
- Mobile: remover entrada do Keychain/Keystore via UI de settings
- Sem propagação remota — cada lado limpa seu próprio storage
- Próxima tentativa de reconnect cai em `unknown_peer` quando app tentar
  mandar inner pra peer que não está mais em peers.json — Pi responde
  `error { code: "unknown_peer" }` e o app deve re-disparar fluxo de QR

---

## Códigos de erro do pareamento

Estes são erros do `pair_error` (inner envelope, in_reply_to do `pair_request`):

| `code` | Significado |
|---|---|
| `token_expired` | QR expirou (>60s desde geração) |
| `token_consumed` | QR já foi usado por outro `pair_request` |
| `token_unknown` | Token não foi emitido por este Pi |
| `internal_error` | Falha inesperada ao persistir peer ou outro side effect |

Erros adicionais que aparecem **fora** do pair_error (no `error` inner
genérico do `protocol.md`):

| `code` | Significado |
|---|---|
| `unknown_peer` | App mandou inner pra peer epk que não está em `peers.json` (não pareado ou revogado) |
| `auth_failed` | Challenge-response do relay falhou — WS é fechado, não há inner |
