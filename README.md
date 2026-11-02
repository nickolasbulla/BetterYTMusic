# BetterYTMusic

Player de música pessoal para o iPhone, feito para funcionar **offline**, com interface própria.

- **Etapa 1 (atual):** biblioteca local + player nativo (segundo plano, tela bloqueada, controles na tela de bloqueio).
- **Etapa 2 (próxima):** botão "Atualizar playlists" que sincroniza playlists públicas/não listadas do YouTube Music (sem login) e baixa as músicas para ouvir offline.

## Estrutura

| Caminho | O que é |
|---|---|
| `App/BetterYTMusicApp.swift` | Entrada do app |
| `App/Library.swift` | Biblioteca: arquivos em `Documents/Music`, leitura de título/artista/capa |
| `App/Player.swift` | AVPlayer, AVAudioSession `playback`, tela de bloqueio e controles remotos |
| `App/Views.swift` | Telas (lista, mini player, "tocando agora") |
| `project.yml` | Definição do projeto (XcodeGen). Bundle ID fixo: `com.marcao.betterytmusic` |
| `.github/workflows/build.yml` | Compila no macOS, gera `.ipa` sem assinatura e publica num Release |

## Build e instalação

Cada push na `main` gera um novo `.ipa` no GitHub Actions:

`https://github.com/nickolasbulla/BetterYTMusic/releases/latest/download/BetterYTMusic.ipa`

Instale pelo iloader (ou Sideloadly) no PC. O bundle ID é fixo, então cada versão nova substitui a anterior **sem apagar as músicas**.

## Colocando músicas no app

- No app, toque em **+** e escolha arquivos de áudio (mp3, m4a, aac, wav, flac...) no app Arquivos; ou
- Copie arquivos para **Arquivos → No Meu iPhone → BetterYTM → Music**. Eles aparecem ao voltar para o app (ou puxando a lista para baixo).

Para apagar uma música, deslize para a esquerda na lista.

## Checklist da etapa 1

- [ ] Importar uma ou mais músicas.
- [ ] Tocar; ver capa, título e artista.
- [ ] Ir para a tela inicial e bloquear a tela: a música continua.
- [ ] Na tela de bloqueio / Central de Controle: pausar, avançar, voltar, arrastar a barra de tempo.
- [ ] Modo avião: tudo continua funcionando.
