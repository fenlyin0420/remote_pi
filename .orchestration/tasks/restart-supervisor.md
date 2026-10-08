# Task: comando CLI `remote-pi restart-supervisor`

## Contexto

O **Cockpit** (app desktop) ganhou um botão **"Reiniciar supervisor"** na aba
"Daemon Agents". Ele faz shell-out `remote-pi restart-supervisor`.

Por que isso é necessário: o `pi-supervisord` é um processo Node long-running e
**não faz hot-reload**. Toda vez que o `dist` do pi-remote é rebuildado, o
supervisor em execução continua rodando o código antigo em memória até o
**processo** ser reiniciado. Isso já mordeu 3x nesta leva (stop{id}/restart{id} e
o modelo nome-no-registry só passaram a valer depois de reiniciar o supervisor à
mão com `launchctl kickstart`). O Cockpit não tem como reiniciar o processo do
supervisor de forma cross-plataforma — então essa lógica de SO deve morar no
remote-pi, exposta como um comando de CLI.

> Importante: **reiniciar o PROCESSO do supervisor**, não os daemons. Não é
> `daemon restart` (que é `restart_all` dos filhos). É reiniciar o `pi-supervisord`
> pai — o que, de quebra, re-spawna todos os daemons.

## O que implementar

1. Novo comando top-level **`restart-supervisor`** no dispatch da CLI em
   `src/index.ts` (modo CLI = `dist/index.js`), perto de onde `create` / `remove`
   / `daemons` / `daemon` são tratados.

2. Comportamento cross-plataforma:
   - **macOS**: `launchctl kickstart -k gui/<uid>/dev.remotepi.supervisord`
     (uid via `process.getuid()`).
   - **Linux**: `systemctl --user restart remote-pi-supervisord`.
   - **Windows**: sem suporte ainda → imprimir mensagem clara e sair com código
     ≠ 0 (até o suporte a Windows do supervisor entrar).

3. Saída/exit:
   - Sucesso → imprimir uma confirmação curta e sair `0`.
   - Falha → sair com exitCode **≠ 0** (o Cockpit detecta falha pelo exit).
   - ⚠️ Hoje um comando desconhecido imprime o help e sai `0`. O sucesso real do
     `restart-supervisor` **não** pode imprimir o banner de usage (o Cockpit usa
     a presença de "Usage: remote-pi" pra detectar "comando indisponível"). Se
     der pra fazer comando desconhecido sair ≠ 0 também, melhor — mas não é
     obrigatório.

4. Adicionar a linha do comando no **help/usage** da CLI (seção "Service" ou uma
   nova). Algo como:
   `restart-supervisor             Restart the pi-supervisord process`

5. Rodar `npm run build` (tsc) pra atualizar o `dist`.

## Fora de escopo

- Não mexer no protocolo UDS (`control_protocol.ts` / `supervisor.ts`) — isto é
  um comando de CLI puro que reinicia o serviço do SO. `stop{id}`/`restart{id}`
  já estão prontos e validados.

## Como o Cockpit chama

`remote-pi restart-supervisor` (sem args). O Cockpit resolve o binário em
`/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin` ou no PATH.

## Aceite

- `remote-pi restart-supervisor` reinicia o `pi-supervisord` no macOS (e Linux),
  sai `0` no sucesso / ≠0 na falha, aparece no help, e o `dist` foi rebuildado.
- Validável: rodar o comando e ver o supervisor voltar (ex.: `remote-pi daemons`
  mostra os daemons com uptime resetado).
