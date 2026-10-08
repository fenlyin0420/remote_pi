# [ORCH:probe-extension-folder] Estrutura de pastas pi-remote

**Status**: done
**Arquivos tocados**: nenhum

## Resumo

Árvore do cwd `/pi-remote/` (3 níveis, sem node_modules/dist/.git):

```
CLAUDE.md
package.json
pnpm-lock.yaml
tsconfig.json
src/
  index.ts
```

Projeto no estado inicial: único ponto de entrada `src/index.ts`, sem subpastas ainda.

## Notas pro orquestrador

- `src/` está plano — nenhuma estrutura de módulos criada ainda
- `dist/` existe no fs mas está no .gitignore (build anterior ou pasta vazia)
- Pronto para receber implementação do plano 03-protocol
