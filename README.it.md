# ComposerGlass Engine

[English documentation](README.md)

ComposerGlass Engine è un motore indipendente e non ufficiale, scritto in
Swift e progettato per essere compatibile con Composer. Non è affiliato al
progetto Composer né approvato dai suoi responsabili.

La baseline comportamentale attuale della serie `0.2.x` è Composer `2.10.3`, tag `2.10.3`, commit
`f0de0bf90226853b841672f086d8b58b02332504`. Consulta
[COMPOSER-UPSTREAM.it.md](COMPOSER-UPSTREAM.it.md) per il riferimento
machine-readable e la procedura di confronto con le versioni future.

Il pacchetto è destinato agli strumenti di sviluppo nativi che devono
analizzare, risolvere e installare dipendenze PHP senza avviare PHP, Composer,
una shell o un altro eseguibile. Le prime versioni `0.x` implementano
intenzionalmente un sottoinsieme sicuro di Composer e non eseguono mai il
codice dei pacchetti scaricati.

## Documentazione

| Argomento | Documento autorevole |
| --- | --- |
| Panoramica API ed esempi | Questo README |
| Funzionalità supportate ed esclusioni | [COMPATIBILITY.md](COMPATIBILITY.md) |
| Versione Composer di riferimento e aggiornamenti | [COMPOSER-UPSTREAM.it.md](COMPOSER-UPSTREAM.it.md) |
| Requisiti per contribuire | [CONTRIBUTING.md](CONTRIBUTING.md) |
| Perimetro di sicurezza e segnalazioni private | [SECURITY.md](SECURITY.md) |
| Cronologia delle versioni | [CHANGELOG.md](CHANGELOG.md) |

## Perimetro supportato

- **File di progetto:** conservazione strutturale di `composer.json` e
  `composer.lock`, `content-hash` compatibile, serializzazione byte-identica,
  validazione e rilevamento dei duplicati.
- **Risoluzione:** metadati Composer 2, versioni numeriche e di sviluppo,
  operatori di vincolo comuni, stabilità, backtracking transitivo, alias,
  conflitti, sostituzioni, provider e pacchetti della piattaforma.
- **Trasporto ed estrazione:** accesso esclusivamente HTTPS, cache condizionale,
  verifiche SHA-1/SHA-256, download ZIP limitati ed estrazione nativa
  stored/DEFLATE con protezioni per percorsi, collisioni, CRC-32 ed espansione.
- **Output generato:** alberi `vendor` deterministici, metadati dei pacchetti,
  autoload PSR-0, PSR-4, classmap e files, oltre ai proxy `vendor/bin`.
- **Operazioni e recupero:** installazione, aggiornamento completo o selettivo,
  `require`, `remove`, `validate`, `show`, `outdated`, `audit` e
  `dump-autoload`, con stato transazionale esterno, backup, recupero e rollback.

Il pacchetto non ha dipendenze runtime ed è adatto al collegamento statico.
Consulta [COMPATIBILITY.md](COMPATIBILITY.md) prima di modificare un progetto.

## Compatibilità byte per byte del lockfile

A parità di dipendenze risolte, ogni operazione supportata deve produrre gli
stessi byte della release ufficiale di Composer usata come baseline. La sola
uguaglianza semantica del JSON non basta: differenze di spaziatura, escaping,
ordine o presenza dei campi generano rumore in Git. Il contratto completo e i
test obbligatori sono in [COMPATIBILITY.md](COMPATIBILITY.md); gli aggiornamenti
della baseline seguono [COMPOSER-UPSTREAM.it.md](COMPOSER-UPSTREAM.it.md).

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
dopo un’interruzione. Lo stato delle transazioni, le directory di staging e i
backup vengono salvati fuori dai progetti gestiti, nella directory Application
Support di ComposerGlass. Le directory `.composerglass-engine` esistenti
vengono migrate automaticamente, compresi i percorsi dei journal necessari per
il recupero e il rollback.

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
