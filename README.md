# BetterYTMusic

Player de música pessoal para o iPhone, feito para funcionar **offline**, com interface própria.

- **Etapa 1:** biblioteca local + player nativo (segundo plano, tela bloqueada, controles na tela de bloqueio).
- **Etapa 2 (atual):** aba Playlists com botão "Atualizar playlists", que sincroniza playlists do YouTube Music (sem login) e baixa as músicas para ouvir offline.

## Sincronizando playlists (sem login)

Na aba **Playlists**, toque em **+** e cole:
- o link de uma playlist **pública ou não listada** (Compartilhar → Copiar link no app oficial); ou
- o link do seu perfil / `@nome`: o app acha sozinho todas as playlists **públicas** dele, inclusive as novas.

O botão **Atualizar playlists** (canto superior esquerdo) relê tudo, baixa as músicas novas e apaga as que saíram de todas as playlists. Músicas importadas à mão nunca são apagadas. Para remover uma playlist do app, toque e segure nela → **Remover playlist** e confirme.

Os downloads continuam enquanto o app está aberto ou tocando música em segundo plano. Para a primeira sincronização, deixe o app aberto (a tela não apaga sozinha durante os downloads).

O áudio vem do [YouTubeKit](https://github.com/alexeichhorn/YouTubeKit), que segue a branch `main`: quando o YouTube mudar algo e os downloads pararem, basta rodar o workflow de novo (Actions → Build IPA → Run workflow) para pegar a correção mais recente da biblioteca.

## Estrutura

| Caminho | O que é |
|---|---|
| `App/BetterYTMusicApp.swift` | Entrada do app |
| `App/Library.swift` | Biblioteca: arquivos em `Documents/Music`, leitura de título/artista/capa |
| `App/Player.swift` | AVPlayer, AVAudioSession `playback`, tela de bloqueio e controles remotos |
| `App/Views.swift` | Telas (playlists, músicas, mini player, "tocando agora") |
| `App/YTMusicAPI.swift` | Leitura anônima de playlists e perfis do YouTube Music |
| `App/Downloader.swift` | Download do áudio m4a e gravação de título/artista/capa |
| `App/Syncer.swift` | "Atualizar playlists": estado salvo, downloads e limpeza |
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
