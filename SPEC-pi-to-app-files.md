# SPEC — Pi → App: mandando imagens/arquivos para o celular

> Entrega em duas fatias (escopo escolhido pelo usuário 2026-09-28):
> **① imagem** (thumbnail inline, com downscale automático no Pi quando passa do teto)
> **② arquivo de texto pequeno** (preview). Binários/large = recusado com mensagem clara.
> Roda `app/` + `pi-remote/`; **relay não muda**.

## O problema

O fio só tem anexo na direção **App → Pi** (`user_message.images` / `.files`, plan/30).
`AssistantMsg` no app é texto puro; `ImageBubble` / `FileBubble` existem mas só
alimentam o balão do próprio usuário. Logo: quando o agente gera um gráfico, um
screenshot ou um relatório na máquina, o celular só recebe um caminho — inútil.

## Teto: por que ~2 MB e não "qualquer arquivo"

O relay aceita envelope externo de **4 MiB** (`RELAY_MAX_CT_MIB`, `relay/src/protocol/outer.rs`),
medido sobre `ct`, que é **Base64 do JSON interno**. Cálculo do pior caso:

```
bytes originais B
  → base64 (fio interno)      = 4/3 · B
  → JSON interno (escape ~1x) ≈ 4/3 · B
  → ct = base64(JSON interno)  = 16/9 · B   ≈ 1.78 · B
16/9 · B ≤ 4 MiB   ⇒   B ≤ ~2.3 MB
```

Teto adotado: **2 MiB de bytes originais**, com `data` sempre presente (nunca um
offer só com metadados). Quem pede bytes demais leva um erro acionável, não um
objeto quebrado.

## Wire

### Pi → App: `file_offer` (ServerMessage)

```jsonc
{
  "type": "file_offer",
  "id": "att_<toolCallId>",     // identidade estável: mesmo id no live e no replay
  "name": "chart.png",
  "path": "/home/p/.pi/tmp/chart.png",   // onde está na máquina
  "mime": "image/png",
  "size": 184320,               // bytes de `data` (pós-downscale)
  "data": "<base64>",
  "note": "gráfico do throughput",       // opcional (caption do agente)
  "resized": true,                        // opcional: houve downscale
  "original_size": 3145728                // opcional: tamanho em disco antes
}
```

`id` = `att_` + `toolCallId` em **todos** os lugares (live, histórico, resposta
de `file_get`), então o app faz upsert por id e o replay não duplica nem apaga
bytes já baixados.

### App → Pi: `file_get` (ClientMessage)

```jsonc
{ "type": "file_get", "id": "g-1", "path": "/home/p/.pi/tmp/chart.png" }
```

Resposta: um `file_offer` com `in_reply_to: "g-1"` e o **mesmo** `id` do
histórico (`att_<toolCallId>`), ou `error {code:"too_large"|"not_found"}`.
Uma só mensagem atende os dois usos (live e pull).

### `session_history`: evento `attachment` (só metadados)

```jsonc
{ "ts": 1730, "type": "attachment", "id": "att_tc-1", "name": "chart.png",
  "path": "/…", "mime": "image/png", "size": 184320, "note": "…",
  "tool_call_id": "tc-1" }
```

**Sem `data`, de propósito.** O `session_history` tem orçamento de 3 MiB e corta
os eventos mais antigos quando estoura (`SYNC_MAX_BYTES_DEFAULT`); embedder
base64 aqui (200 KB por imagem ≈ 270 KB) expulsaria meia conversa em ~10 imagens.
O app puxa sob demanda com `file_get` — a história fica barata e o byte trafega
uma vez, no momento em que alguém realmente olha.

## Pi: o gatilho

Tool `send_to_phone(path, note?)` (`registerTool`, portanto já ativo por default —
mesma regra de `agent_send`). Um arquivo por chamada; várias chamadas = vários
cards.

Pipeline do lado Pi:

1. Resolve o path com `realpath` (symlink/`~` não enganam o card) e exige arquivo
   regular legível.
2. **Conteúdo primeiro, nome nunca**: assinatura PNG/JPEG/GIF/WebP/BMP → imagem;
   senão UTF-8/UTF-16 estrito sem NUL → texto; senão recusado. (Um `.txt` que é
   PNG vai como imagem; um `.png` binário é recusado.)
3. **Imagem**: se `size > 2 MiB`, `resizeImage(bytes, mime, { maxWidth: 1600,
   maxHeight: 1600, maxBytes: 2 MiB })` do próprio SDK (Photon/WASM, sem
   dependência nova). Retorna `null` só se não conseguir baixar do teto → erro.
4. **Texto**: teto 1 MiB (o conteúdo viaja como base64, então escape não dobra).
5. Responde ao `file_get` com o mesmo encoder (reaproveitado).

Tool result (curto, é o que o modelo lê): `Sent chart.png (image/png, 180 KB,
downscaled from 3.0 MB) to the phone.` / no erro, o motivo + o que fazer.

### No app

- `AttachmentMsg` (novo `ChatMessage`) com `blobName` (o nome do blob local, não
  os bytes); `data` nunca entra no domain.
- Bytes → arquivo em `<Hive dir>/attachments/<id>.bin`; o `MessageRecord` guarda
  só metadados + o nome do blob. Um blob de 2 MB numa row do Hive obrigaria a
  lista inteira da sala a carregar os bytes na memória.
- `AttachmentStore`: write (tmp + rename), read, prune. Sweeps serializados,
  teto 64 MB, mais antigo primeiro, tmp órfão só some depois de 1 h (senão a
  varredura come a escrita de um `put` concorrente).
- UI: `AttachmentCard` — imagem vira thumbnail (220 px, à **esquerda**, cor de
  superfície); texto vira nome + tamanho + preview inline (fatia de ~700
  caracteres, sem scroll aninhado — scroll dentro da lista de chat briga com o
  scroll da própria lista) e "show all" abre a tela cheia; sem bytes →
  "tap to load" e dispara `file_get`; erro → linha vermelha com o motivo;
  botões de copiar caminho e salvar.
- `AttachmentViewer`: tela cheia, `InteractiveViewer` + double-tap 2.5× (uma
  miniatura de 220 px não é um leitor de screenshot), texto com scroll/seleção
  até 200k caracteres, e o mesmo botão de salvar.
- **Salvar no celular**: `MediaSaver` (contrato) + `MethodChannelMediaSaver` +
  `MediaSaver.kt`. MediaStore, não `ACTION_CREATE_DOCUMENT`: `minSdk` é 34, o
  insert de arquivo criado pelo próprio app **não pede permissão nenhuma**, e um
  toque em vez de um diálogo por salvamento. Imagem → `Pictures/Remote Pi`, resto
  → `Download/Remote Pi`; devolve o caminho e a UI mostra onde foi. O canal
  confina o path ao **dataDir do app** (`/data/user/0/<pkg>`) — os blobs ficam ao
  lado das boxes do Hive, que o Flutter põe no documents dir (`<dataDir>/app_flutter`),
  então uma checagem por `filesDir` rejeita todo salvamento real.
- O tool card de `send_to_phone` é **suprimido** nos dois caminhos (live e
  replay); uma **falha** continua virando tool card, que é o único lugar onde o
  usuário vê que não foi. O evento `attachment` entra no lugar, então a ordem na
  timeline é a do envio.
- Upsert por id: evento de histórico sem `data` **não** apaga bytes já baixados —
  e o `_applyHistory` (que reconstrói a box inteira) carrega o `blobName`
  antigo, senão cada reconexão transformaria a sala em "toque para carregar".

## Fora de escopo (fica para a trilha HTTP)

Vídeo, zip grande, PDF, qualquer binário. Quebrar 4 MiB exige upload para um host
que o celular alcança (o `download_server.py` de `rp-s3/selfhost` já é GET-only;
faltaria POST + token + TTL) — é a opção ③, e ela continua de pé.

## Segurança (inalterado, declarado)

`ct` é Base64 de JSON em claro: o operador do relay vê o arquivo. Cross-PC, o
relay entrega o offer a todo owner paired do room (mesma semântica do echo de
`user_message`).

## Verificação

- pi-remote: tool envia offer com/sem downscale, recusa > teto e binário,
  `file_get` responde, mapper de histórico emite `attachment` (e o par
  tool_request/tool_result sai) — `pnpm test` + `tsc`.
- app: parse do offer, upsert sem perder bytes, store write/read/prune, card
  nos 3 estados (bytes / sem bytes / erro) — `flutter test` + `analyze`.
