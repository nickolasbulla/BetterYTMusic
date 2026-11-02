# BetterYTMusic

Interface pessoal para o YouTube Music no iPhone: um app SwiftUI com WKWebView que abre `music.youtube.com`.

## Estrutura

| Caminho | O que é |
|---|---|
| `App/BetterYTMusicApp.swift` | Entrada do app + AVAudioSession em modo `playback` |
| `App/MusicWebView.swift` | WKWebView, user agent, bloqueio de redirecionamento para o app oficial, injeção |
| `Inject/custom.css` | Seu CSS (injetado no início da página) |
| `Inject/custom.js` | Seu JavaScript (injetado quando o documento termina de carregar) |
| `project.yml` | Definição do projeto (XcodeGen). Bundle ID fixo: `com.marcao.betterytmusic` |
| `.github/workflows/build.yml` | Compila no macOS, gera `.ipa` sem assinatura e publica num Release |

## Compilar (sem Mac)

1. Crie um repositório no GitHub (público é mais simples: o Safari baixa o asset sem precisar de login).
2. Envie este código para a branch `main`:
   ```
   git init -b main
   git add .
   git commit -m "Protótipo"
   git remote add origin https://github.com/SEU_USUARIO/BetterYTMusic.git
   git push -u origin main
   ```
3. Em **Actions**, espere o workflow "Build IPA" terminar (~5 min). Também dá para rodar manualmente com "Run workflow".
4. No iPhone, abra pelo Safari:
   `https://github.com/SEU_USUARIO/BetterYTMusic/releases/latest/download/BetterYTMusic.ipa`
5. No SideStore: aba **My Apps** → **+** → escolha o `.ipa` em Downloads.

Cada push gera um novo build, e ele substitui o anterior porque o bundle ID é o mesmo.
Com Apple ID gratuito, o app precisa ser renovado no SideStore a cada 7 dias.

## Checklist do protótipo

- [ ] **Login:** entre na conta Google. Feche o app pelo multitarefa e abra de novo: você deve continuar logado.
- [ ] **Reprodução:** toque uma música.
- [ ] **Segundo plano:** vá para a tela inicial e depois bloqueie a tela. A música deve continuar tocando.

### Se algo falhar

- **Google bloqueia o login** ("navegador não seguro"): em `MusicWebView.swift`, troque `webView.customUserAgent = Config.userAgent` por `Config.desktopUserAgent`.
- **A música pausa ao bloquear a tela:** o script `Scripts.keepAlive` esconde do site que o app foi para segundo plano. Diga o que aconteceu (pausa na hora? depois de alguns segundos?) para ajustarmos.
