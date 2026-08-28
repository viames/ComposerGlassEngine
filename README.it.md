# ComposerGlass Engine

ComposerGlass Engine è un motore indipendente e non ufficiale, scritto in
Swift e progettato per essere compatibile con Composer. Non è affiliato al
progetto Composer né approvato dai suoi responsabili.

La baseline comportamentale attuale è Composer `2.10.2`, tag `2.10.2`, commit
`8d4439f572a97670a9edc039eb3b093cc976b4bc`. Consulta
[COMPOSER-UPSTREAM.it.md](COMPOSER-UPSTREAM.it.md) per il riferimento
machine-readable e la procedura di confronto con le versioni future.

Il pacchetto è destinato agli strumenti di sviluppo nativi che devono
analizzare, risolvere e installare dipendenze PHP senza avviare PHP, Composer,
una shell o un altro eseguibile. Le prime versioni `0.x` implementano
intenzionalmente un sottoinsieme sicuro di Composer e non eseguono mai il
codice dei pacchetti scaricati.

## Funzionalità attuali

- Decodifica e codifica strutturale di `composer.json`, con conservazione dei
  campi sconosciuti.
- Decodifica tipizzata e strutturale di `composer.lock`, con codifica
  deterministica.
- Generazione del `content-hash` compatibile con Composer e verifica
  dell'allineamento tra manifesto e lockfile.
- Ordinamento deterministico dei pacchetti bloccati e rilevamento dei
  duplicati.
- Accesso tipizzato ai requisiti principali e ai metadati comuni del manifesto.
- Interpretazione delle versioni numeriche in stile Composer e confronto del
  livello di stabilità.
- Vincoli esatti, comparativi, caret, tilde, wildcard, intervallo, AND e OR.
- Individuazione asincrona dei repository Composer 2 e caricamento dei metadati
  dei pacchetti.
- Espansione dei metadati minificati `composer/2.0`, cache HTTP condizionale e
  caricamento delle versioni di sviluppo.
- Validazione HTTPS dei repository e dei reindirizzamenti nel client conforme
  al profilo di sicurezza per App Store.
- Risoluzione deterministica della versione compatibile più alta, con requisiti
  transitivi e backtracking.
- Alias dei rami, versioni di sviluppo, `conflict`, `replace`, `provide` e
  individuazione dei fornitori di pacchetti virtuali.
- Validazione dei pacchetti virtuali della piattaforma per PHP, estensioni,
  librerie e Composer.
- Supporto di `minimum-stability`, dei flag di stabilità dichiarati nel
  progetto principale e di `prefer-stable`.
- Descrizione strutturata degli errori di risoluzione, con vincoli coinvolti e
  versioni disponibili nel repository.
- Download asincrono e limitato agli URL HTTPS degli archivi ZIP, con controllo
  della dimensione durante il trasferimento.
- Cache persistente degli archivi, con verifica SHA-256 e controllo facoltativo
  del checksum SHA-1 fornito dai repository Composer.
- Estrazione nativa degli archivi ZIP con voci memorizzate o DEFLATE, verifica
  CRC-32, contenimento dei percorsi, limiti di espansione e rollback in caso di
  errore.
- Creazione deterministica di nuovi alberi `vendor`, con metadati dei pacchetti
  installati e rimozione completa della destinazione in caso di errore.
- Generazione dell’autoload PSR-0, PSR-4, classmap e files, oltre ai proxy
  deterministici in `vendor/bin`.
- Sostituzione transazionale della directory `vendor`, con journal di recupero
  e rollback.
- Generazione deterministica del lockfile e flussi nativi per aggiornamento,
  aggiornamento selettivo, `require` e `remove`, con backup dei file di progetto.
- Servizi nativi per `install`, `validate`, `show`, `outdated`, `audit` e
  `dump-autoload`.
- Swift Package privo di dipendenze, adatto al collegamento statico.

Prima di utilizzare il pacchetto per modificare un progetto, consulta
[COMPATIBILITY.md](COMPATIBILITY.md).

## Requisiti

- Swift 6.0 o successivo
- macOS 14 o successivo

## Utilizzo

```swift
import Foundation
import ComposerGlassEngine

let manifesto = try ComposerManifest.decode(from: datiManifesto)
let lockfile = try ComposerLockFile.decode(from: datiLockfile)

if try lockfile.isFresh(for: datiManifesto) {
    let pacchetti = try lockfile.packages()
    // Il lockfile corrisponde al manifesto e i pacchetti sono disponibili.
}

if let urlRepository = URL(string: "https://repo.packagist.org") {
    let repository = try ComposerRepositoryClient(repositoryURL: urlRepository)
    let versioni = try await repository.packages(named: "psr/log")

    let piattaforma = try ComposerResolutionPlatform(packages: [
        "php": "8.4.1",
        "ext-json": "8.4.1"
    ])
    let risolutore = ComposerDependencyResolver(
        source: repository,
        platform: piattaforma
    )
    let risultato = try await risolutore.resolve(
        requirements: ["psr/log": "^3.0"]
    )

    if !risultato.packages.isEmpty,
       let directoryCache = FileManager.default.urls(
           for: .cachesDirectory,
           in: .userDomainMask
       ).first {
        let downloader = try ComposerPackageDownloader(
            cacheDirectory: directoryCache.appendingPathComponent("ComposerGlassEngine")
        )
        let materializzatore = ComposerPackageMaterializer(downloader: downloader)
        let materializzato = try await materializzatore.materialize(
            risultato,
            at: directoryCache.appendingPathComponent(
                "ComposerGlassEngine-Vendor-\(UUID().uuidString)"
            )
        )
    }
}
```

Il risolutore supporta versioni numeriche e di sviluppo, vincoli `require`
principali e transitivi, pacchetti della piattaforma, livelli di stabilità,
cicli, backtracking deterministico, alias dei rami, conflitti, sostituzioni e
fornitori virtuali. La piena equivalenza con il risolutore SAT di Composer non
rientra ancora in questa versione; i vincoli non supportati non vengono mai
accettati implicitamente.

Il downloader e l'estrattore accettano attualmente distribuzioni ZIP contenenti
voci memorizzate o DEFLATE. Prima del riutilizzo viene verificato il contenuto
della cache; l'estrazione rifiuta percorsi non sicuri, collegamenti simbolici,
voci cifrate, duplicati, collisioni e superamenti dei limiti configurati. Il
codice dei pacchetti non viene mai eseguito.

I servizi nativi di alto livello installano in una directory di staging,
generano i metadati di autoload e i proxy binari, quindi attivano `vendor` in
modo transazionale. Le operazioni che modificano le dipendenze registrano anche
`composer.json` e `composer.lock`, così da consentire il recupero o il rollback
dopo un’interruzione.

## Sviluppo

```sh
swift build
swift test
```

## Licenza e attribuzione

ComposerGlass Engine è distribuito con licenza MIT. Anche Composer è
distribuito con licenza MIT. Questo progetto studia i formati e il comportamento
pubblico di Composer per offrirne la compatibilità, ma rimane
un'implementazione indipendente. Consulta
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) per le attribuzioni.
