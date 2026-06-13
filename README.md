# Wavely AR

**Controlla i tuoi dispositivi Home Assistant in Realtà Aumentata.**

Wavely AR è un'app iOS nativa che sovrappone i tuoi dispositivi Home Assistant direttamente nello spazio fisico della tua casa, usando ARKit per ancorarli in punti specifici del mondo reale. Inquadra la stanza con il telefono per vedere lo stato di luci, prese, termostati, serrature e sensori, e controllali con un tap o con gesti della mano.

> **Nota**: Wavely AR non è disponibile sull'App Store. Per installarla su iPhone è necessario compilarla con Xcode partendo dal codice sorgente. → [Guida all'installazione](#installazione-su-iphone-via-xcode)

---

## Indice

- [Funzionalità](#funzionalità)
- [Requisiti](#requisiti)
- [Installazione su iPhone via Xcode](#installazione-su-iphone-via-xcode)
- [Configurazione Home Assistant](#configurazione-home-assistant)
- [Come si usa](#come-si-usa)
- [Rilevamento gesti mano](#rilevamento-gesti-mano)
- [Struttura del progetto](#struttura-del-progetto)

---

## Funzionalità

### Realtà Aumentata
- **Piazzamento**: ogni dispositivo viene ancorato a un punto dello spazio (parete, tavolo, soffitto) tramite ARKit; la posizione viene memorizzata tra una sessione e l'altra
- **Fumetti 3D**: ogni dispositivo mostra un pannello informativo che ruota sempre verso la camera, visibile da qualsiasi angolo
- **Anteprima profondità**: durante il piazzamento il fumetto si ridimensiona in base alla distanza dalla superficie inquadrata, dando una preview visiva della dimensione finale
- **Persistenza**: le posizioni vengono salvate con ARWorldMap e ripristinate automaticamente all'apertura successiva dell'app; al riavvio il sistema tenta di riconoscere l'ambiente (relocalization) e ricollocare i fumetti
- **Multi-elemento**: puoi selezionare più dispositivi dalla lista e posizionarli uno dopo l'altro in sequenza

### Informazioni in tempo reale
- Connessione WebSocket persistente a Home Assistant: ogni cambio di stato viene riflesso sul fumetto AR senza ricaricare
- Ogni fumetto mostra informazioni contestuali per tipo di dispositivo:
  - **Luci**: stato on/off, luminosità percentuale se disponibile, colore attuale
  - **Prese / Switch**: stato on/off
  - **Termostati**: temperatura attuale e target
  - **Serrature**: stato aperta/chiusa
  - **Videocamere**: nome e stato
  - **Sensori binari**: stato testuale basato sul `device_class`
  - **Sensori generici**: valore numerico con unità di misura

### Controllo dispositivi
- **Tap** su un fumetto per aprire il pannello dettaglio completo con attributi e azioni
- **Gesti della mano** per controllare luci e switch visibili nel frame (vedi sezione dedicata)

### Modifica elementi piazzati
- **Modalità modifica** (icona matita): trascina un fumetto per spostarlo, pizzica con due dita per scalarlo, ruota con due dita per orientarlo
- **Modalità elimina** (icona cestino): tocca un fumetto per rimuoverlo definitivamente
- **Riposiziona**: riavvia la sessione ARKit per riacquisire le posizioni degli elementi già salvati

### Connettività
- Discovery automatico di Home Assistant sulla rete locale via mDNS/Bonjour
- Autenticazione OAuth 2.0 nativa con Home Assistant (nessuna password salvata in chiaro)
- Token salvati in Keychain iOS, rinnovati automaticamente alla scadenza
- Riconnessione WebSocket automatica

---

## Requisiti

### Dispositivo
| Requisito | Minimo |
|-----------|--------|
| iPhone | iPhone XS o successivo |
| iOS | 17.0 o successivo |
| iPad | supportato (chip A12 Bionic o successivo) |

> Il rilevamento gesti mano usa il Neural Engine di Apple; richiede almeno un chip A12 (iPhone XS / iPad 2018 e successivi).

### Home Assistant
| Requisito | Note |
|-----------|-------|
| Home Assistant | qualsiasi versione recente (2023.x o successivo consigliato) |
| Rete | iPhone e Home Assistant devono essere sulla **stessa rete Wi-Fi locale** |
| Accesso | account Home Assistant con permessi per vedere e controllare i dispositivi |

### Per la compilazione
| Software | Versione minima |
|----------|-----------------|
| macOS | 14 (Sonoma) o successivo |
| Xcode | 16.0 o successivo |
| Apple Developer Account | gratuito (per installare su un solo dispositivo personale) |

---

## Installazione su iPhone via Xcode

Questa sezione guida passo per passo l'installazione, sia per chi ha già usato Xcode sia per chi lo usa per la prima volta.

### Fase 1 — Preparare il Mac

#### 1.1 Installare Xcode

1. Apri l'app **App Store** sul tuo Mac
2. Cerca **Xcode** nella barra di ricerca
3. Clicca **Installa** o **Ottieni** (è gratis, ma occupa circa 15 GB)
4. Attendi il completamento del download — può richiedere 20–40 minuti a seconda della connessione
5. Una volta installato, apri Xcode almeno una volta per completare l'installazione dei componenti aggiuntivi (ti verrà chiesto automaticamente)

> **Nota**: se hai già Xcode installato, verifica che la versione sia 16.0 o successiva. Puoi controllare andando su **Xcode → About Xcode** nella barra dei menu.

#### 1.2 Scaricare il codice sorgente

Hai due opzioni:

**Opzione A — Scarica come ZIP (più semplice, non richiede Git)**

1. Vai alla pagina del repository su GitHub
2. Clicca sul pulsante verde **Code**
3. Seleziona **Download ZIP**
4. Apri il file ZIP scaricato — si creerà una cartella chiamata `wavelyar-dev` (o simile)
5. Sposta la cartella dove preferisci (es. nella tua home o in `Documenti`)

**Opzione B — Clona con Git**

Apri il **Terminale** (cercalo con Spotlight: `⌘ + Spazio`, scrivi "Terminale") e incolla:

```bash
git clone -b dev https://github.com/dmsmartech/wavelyar.git
cd wavelyar
```

---

### Fase 2 — Configurare Xcode

#### 2.1 Aprire il progetto

1. Nel Finder, naviga fino alla cartella del progetto
2. Fai doppio clic sul file **`WavelyAR.xcodeproj`** — si aprirà direttamente in Xcode

> Se vedi una finestra di dialogo "Trust and Open", clicca **Trust and Open**.

#### 2.2 Collegare il tuo account Apple

Per installare l'app sul tuo iPhone, Xcode ha bisogno di firmarla con il tuo Apple ID. Questo è gratuito.

1. In Xcode, vai su **Xcode → Settings…** (oppure premi `⌘ ,`)
2. Clicca sulla scheda **Accounts**
3. Clicca il pulsante **+** in basso a sinistra
4. Seleziona **Apple ID** e clicca **Continue**
5. Inserisci la tua Apple ID (email) e password
6. Clicca **Next** — il tuo account verrà aggiunto

#### 2.3 Configurare il Team di firma

1. Nel pannello a sinistra di Xcode (**Project Navigator**), clicca sul file **WavelyAR** in cima alla lista (ha l'icona di un progetto Xcode, con sfondo blu)
2. Nella finestra centrale, sotto la sezione **TARGETS**, clicca su **WavelyAR**
3. Seleziona la scheda **Signing & Capabilities**
4. Nella riga **Team**, clicca sul menu a tendina e seleziona il tuo nome/account
5. Nella riga **Bundle Identifier**, cambia `com.wavely.ar` in qualcosa di unico, ad esempio `com.tuonome.wavelyar` — sostituisci "tuonome" con qualcosa che ti appartiene (es. le tue iniziali)

> **Perché cambiare il Bundle ID?** Con un account sviluppatore gratuito, il Bundle ID deve essere univoco. Se qualcun altro ha già usato `com.wavely.ar`, Xcode potrebbe darti un errore. Aggiungendo il tuo nome diventa univoco.

---

### Fase 3 — Preparare l'iPhone

#### 3.1 Attivare la modalità sviluppatore sull'iPhone

Su iOS 16 e successivi è necessario attivare la **Developer Mode** sull'iPhone prima di installare app da Xcode.

1. Sul tuo iPhone, apri **Impostazioni**
2. Scorri in basso e tocca **Privacy e sicurezza**
3. Scorri ancora in basso fino alla sezione **Sicurezza** e tocca **Modalità sviluppatore**
4. Attiva l'interruttore — l'iPhone ti chiederà di riavviare
5. Dopo il riavvio, ti verrà chiesto di confermare l'attivazione: tocca **Attiva**

#### 3.2 Collegare l'iPhone al Mac

1. Collega l'iPhone al Mac tramite cavo USB (o USB-C, secondo il tuo modello)
2. Sul tuo iPhone apparirà un messaggio **"Autorizzare questo computer?"** — tocca **Autorizza** (o **Considera attendibile**)
3. Se richiesto, inserisci il codice di sblocco dell'iPhone

---

### Fase 4 — Compilare e installare

#### 4.1 Selezionare il dispositivo di destinazione

1. In alto a sinistra in Xcode, troverai un menu a tendina che mostra il dispositivo di destinazione — normalmente è impostato su un simulatore iOS
2. Cliccaci sopra: vedrai una lista che include i simulatori e, in cima, **il tuo iPhone** (con il suo nome)
3. Seleziona il tuo iPhone

#### 4.2 Avviare la compilazione e l'installazione

1. Premi il pulsante **▶ Run** (il triangolo di play) oppure premi `⌘ R`
2. Xcode compilerà il codice — la prima volta può richiedere 1–3 minuti
3. Al termine, l'app viene installata automaticamente sull'iPhone e si avvia

> **Se compare un errore "Untrusted Developer":** sull'iPhone vai su **Impostazioni → Generali → VPN e gestione dispositivi**, trova il tuo Apple ID nella sezione "App sviluppatore" e tocca **Considera attendibile** seguito dalla tua email.

> **Se Xcode mostra un errore di firma:** controlla di aver selezionato il Team corretto nella scheda Signing & Capabilities e che il Bundle ID sia univoco.

#### 4.3 Durata della firma (account gratuito)

Con un account Apple Developer **gratuito**, l'app rimane installata per **7 giorni**. Dopo, è necessario ricollegare l'iPhone al Mac e premere di nuovo `⌘ R` per rinnovare la firma.

Con un account **Apple Developer a pagamento** (99 USD/anno) l'app dura un anno.

---

## Configurazione Home Assistant

### Prima apertura — Discovery automatico

Al primo avvio, Wavely AR cerca automaticamente le istanze di Home Assistant sulla rete locale:

1. Apri l'app — vedrai la schermata di ricerca
2. L'app scandisce la rete: se trova Home Assistant, lo mostra come voce cliccabile con nome e indirizzo IP
3. Tocca la voce trovata **oppure** inserisci manualmente l'indirizzo (es. `http://192.168.1.100:8123`)

> **Permesso rete locale**: la prima volta iOS chiederà se l'app può accedere alla rete locale. Tocca **Consenti** — senza questo permesso l'app non può trovare Home Assistant.

### Autenticazione OAuth

Wavely AR usa il sistema OAuth ufficiale di Home Assistant: nessuna password viene salvata nell'app.

1. Tocca il pulsante di accesso — si aprirà una finestra browser con la pagina di login di Home Assistant
2. Inserisci le tue credenziali HA come di consueto
3. Home Assistant ti chiederà di autorizzare l'app: clicca **OK** o **Autorizza**
4. La finestra si chiude automaticamente e l'app è pronta

Il token di accesso viene salvato nel **Keychain iOS** e rinnovato automaticamente: non verrà mai più chiesto di fare login (salvo logout manuale dalle Impostazioni).

---

## Come si usa

### Schermata principale — Lista dispositivi

All'apertura dopo il login, Wavely AR carica tutti i dispositivi da Home Assistant raggruppati per tipo (luci, prese, termostati, serrature, sensori, videocamere).

- **Barra di ricerca** in cima per filtrare per nome
- **Filtri per tipo** (pill selezionabili) per mostrare solo una categoria
- **Stato connessione** visibile in cima (verde = connesso, arancione = reconnecting)

### Piazzare un dispositivo in AR

1. Tieni premuto su un dispositivo nella lista per circa **0.8 secondi**
2. L'app apre automaticamente la vista AR
3. Inquadra il punto fisico dove vuoi collocare quel dispositivo
4. Al centro dello schermo c'è un **mirino**: puntalo sulla superficie desiderata
5. Il mirino diventa verde quando ARKit rileva una superficie
6. **Tocca lo schermo** per ancorare il fumetto in quella posizione

> **Consiglio**: muovi il telefono lentamente per qualche secondo prima di toccare — questo permette ad ARKit di mappare meglio la geometria della stanza.

### Piazzare più dispositivi in sequenza

1. Nella lista principale, attiva la **modalità selezione** e seleziona più dispositivi
2. Tocca il pulsante AR
3. L'app apre la vista AR con il primo dispositivo da piazzare
4. Tocca per piazzarlo — il secondo dispositivo appare automaticamente sul mirino
5. Continua così fino all'ultimo; il numero di rimanenti è mostrato nel banner in basso

### Controllare un dispositivo in AR

- **Tap** su un fumetto → apre il pannello dettaglio con attributi e azioni disponibili

### Modificare o eliminare un elemento piazzato

1. Tocca l'icona **matita** (in alto a destra nella vista AR) per attivare la modalità modifica
2. In modalità modifica:
   - **Trascina** con un dito per spostare l'elemento
   - **Pizzica** con due dita per scalarlo
   - **Ruota** con due dita per cambiarne l'orientamento
3. Tocca l'icona **cestino** per entrare in modalità elimina, poi tocca il fumetto da rimuovere

### Persistenza delle posizioni

Ogni volta che piazzi, sposti o elimini un elemento, la mappa AR viene salvata automaticamente. Alla prossima apertura l'app tenta di riconoscere l'ambiente e ricollocare i fumetti (relocalization) — durante questo processo i fumetti appaiono semitrasparenti con uno spinner.

---

## Rilevamento gesti mano

In modalità AR, la camera rileva in tempo reale i landmark della mano tramite il framework Vision di Apple. Lo scheletro della mano è visibile sullo schermo come overlay grafico.

Intorno al palmo appare un **cerchio** (aura) come indicatore visivo della presenza del gesto.

### Gesti riconosciuti

I gesti controllano **tutti i dispositivi di tipo luce o switch** i cui fumetti sono attualmente visibili nel frame della camera.

| Gesto | Azione |
|-------|--------|
| Mano aperta (tutte le dita estese) | Accende tutti i dispositivi visibili nel frame |
| Pugno chiuso (tutte le dita chiuse) | Spegne tutti i dispositivi visibili nel frame |

Il riconoscimento richiede che il gesto sia stabile per almeno 3 frame consecutivi prima di inviare il comando. Il comando viene inviato una sola volta per ogni transizione di stato (es. da aperto a chiuso), non ad ogni frame.

> Il rilevamento gesti funziona solo per dispositivi di dominio `light` e `switch`. Gli altri tipi (termostati, serrature, ecc.) non vengono controllati dai gesti.

---

## Struttura del progetto

```
WavelyAR/
├── App/
│   └── WavelyARApp.swift
├── Models/
│   ├── HADevice.swift             — Modello dispositivo, enum domini, HandGesture
│   ├── ARDeviceAnchor.swift       — Modello anchor AR persistito
│   └── HAConfig.swift             — Configurazione server HA
├── Services/
│   ├── HADiscoveryService.swift   — mDNS + TCP scan rete locale
│   ├── HAOAuthService.swift       — OAuth 2.0 + Keychain
│   ├── HARestService.swift        — REST API HA (stati, storico)
│   ├── HAWebSocketService.swift   — WebSocket realtime + reconnect
│   ├── ARPersistenceService.swift — Salvataggio/caricamento posizioni e ARWorldMap
│   └── HandGestureService.swift   — Vision ML, classificazione gesti, publisher Combine
├── Views/
│   ├── Components/
│   │   ├── WavelyButton.swift
│   │   ├── WavelyInputFields.swift
│   │   └── ScaleButtonStyle.swift
│   ├── Onboarding/
│   │   ├── SplashView.swift
│   │   ├── DiscoveryView.swift
│   │   └── OAuthView.swift
│   ├── Main/
│   │   └── MainListView.swift
│   ├── AR/
│   │   ├── WavelyARView.swift     — Vista AR principale
│   │   ├── ARCoordinator.swift    — ARSessionDelegate, piazzamento, gestures, billboard
│   │   ├── DeviceBubbleView.swift — Fumetto renderizzato come texture RealityKit
│   │   ├── HandSkeletonOverlay.swift — Overlay Canvas scheletro mano
│   │   ├── AuraOverlay.swift      — Overlay Canvas cerchio aura
│   │   └── LaserRayOverlay.swift  — Overlay Canvas raggio laser
│   ├── DeviceDetailSheet.swift
│   └── SettingsView.swift
└── Resources/
    └── Assets.xcassets
```

**Dipendenze esterne: nessuna** — solo framework Apple nativi (ARKit, RealityKit, Vision, WebSocket, Keychain, mDNS).

---

## Licenza

Distribuito sotto licenza **MIT**. Consulta il file [LICENSE](LICENSE) per il testo completo.
