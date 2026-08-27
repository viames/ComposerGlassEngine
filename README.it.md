# ComposerGlass Engine

ComposerGlass Engine è un motore indipendente e non ufficiale, scritto in
Swift e progettato per essere compatibile con Composer. Non è affiliato al
progetto Composer né approvato dai suoi responsabili.

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
- Validazione dei pacchetti virtuali della piattaforma per PHP, estensioni,
  librerie e Composer.
- Supporto di `minimum-stability`, dei flag di stabilità dichiarati nel
  progetto principale e di `prefer-stable`.
- Descrizione strutturata degli errori di risoluzione, con vincoli coinvolti e
  versioni disponibili nel repository.
- Swift Package privo di dipendenze, adatto al collegamento statico.

Prima di utilizzare il pacchetto per modificare un progetto, consulta
[COMPATIBILITY.md](COMPATIBILITY.md).

## Requisiti

- Swift 6.0 o successivo
- macOS 14 o successivo

## Utilizzo

```swift
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
}
```

Il risolutore della serie `0.4` supporta versioni numeriche, vincoli `require`
principali e transitivi, pacchetti della piattaforma, livelli di stabilità,
cicli e backtracking deterministico. Gli alias dei rami, i vincoli `conflict`,
i meccanismi `replace` e `provide` — inclusi i pacchetti virtuali dichiarati
tramite `provide` — e la piena equivalenza con il risolutore SAT di Composer non
rientrano ancora in questa versione; le versioni non supportate non vengono mai
installate implicitamente.

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
