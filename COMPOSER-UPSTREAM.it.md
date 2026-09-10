# Baseline upstream di Composer

ComposerGlass Engine `0.1.0` utilizza Composer `2.10.3` come baseline per la
compatibilità comportamentale:

- data di pubblicazione: `2026-08-27`;
- tag upstream firmato: `2.10.3`;
- commit sorgente immutabile: `f0de0bf90226853b841672f086d8b58b02332504`;
- repository upstream: <https://github.com/composer/composer>.

Gli stessi dati sono disponibili per le automazioni in
`COMPOSER-UPSTREAM.json` e per i client Swift tramite
`ComposerUpstreamReference.current`. I test impongono che le due
rappresentazioni rimangano identiche.

Questa baseline identifica il sorgente e il comportamento di Composer
esaminati durante lo sviluppo delle funzionalità native supportate. Non implica
che l’implementazione Swift contenga codice sorgente di Composer o che ne
supporti ogni funzionalità. Le aree supportate e quelle intenzionalmente escluse
sono elencate in `COMPATIBILITY.md` e nel manifesto machine-readable.

## Confrontare una futura versione di Composer

Clona o aggiorna un checkout ufficiale di Composer, quindi esegui:

```sh
./script/compare_composer_upstream.sh /percorso/di/composer 2.11.0
```

Il resoconto raggruppa i file modificati nelle aree relative al risolutore e
alla semantica dei pacchetti, ai repository e ai download, all’installazione e
all’autoload, nonché ai comandi, agli schemi e alla sicurezza. Mostra inoltre
le statistiche complete delle differenze upstream.

Per ogni aggiornamento della baseline:

1. Verifica il tag ufficiale firmato e registra lo SHA del commit effettivo.
2. Esamina le differenze raggruppate del sorgente e il changelog upstream
   completo.
3. Considera obbligatoria la verifica delle modifiche di sicurezza, comprese
   quelle esterne al sottoinsieme attualmente implementato.
4. Aggiungi fixture deterministiche per i comportamenti osservabili pertinenti.
5. Confronta correttezza e prestazioni con le stesse fixture pubbliche o
   riproducibili, prima e dopo la modifica dell’engine.
6. Aggiorna `ComposerUpstreamReference.current`, `COMPOSER-UPSTREAM.json`,
   questo documento, `COMPATIBILITY.md` e `CHANGELOG.md` nella stessa pull
   request.
7. Esegui `swift test` e la suite di test dell’applicazione ComposerGlass.

La conservazione della baseline precedente nella cronologia Git rende ogni
versione dell’engine direttamente confrontabile con l’esatta revisione di
Composer presa come riferimento.
