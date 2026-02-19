# Plan de Recodage macOS Swift (parite avec l'implementation legacy)

## Decisions confirmees
- UI: 100% native SwiftUI.
- Moteur de capture: WebKit uniquement (`WKWebView`).
- Workspace: implementation dans ce dossier courant.

## Objectif
Recoder une app macOS native qui reprend toutes les fonctionnalites legacy:
- capture URL en PNG 1920x1080;
- gestion de projets;
- historique + suppression;
- logs markdown des captures;
- edition ordre + notes markdown;
- generation HTML;
- export PDF de style slides.

## Etat source (reference)
- API et logique principale: version JavaScript historique.
- UI web: interface legacy.
- generation HTML: script Python legacy.
- donnees de reference: captures, ordre, notes.

## Cadrage technique Swift
### Architecture cible
- `App`: SwiftUI (navigation principale + etats globaux).
- `Domain`: modeles (`Project`, `CaptureItem`, `EditorState`, `ProjectMeta`).
- `Persistence`: lecture/ecriture fichiers (markdown, json, png, compteur).
- `CaptureEngine`: capture WebKit 1920x1080 + heuristique cookie banners.
- `DeckGenerator`: rendu HTML (templates Swift) + export PDF.
- `UseCases`: orchestration metier (capture, suppression, generation, export).

### Format de donnees a conserver (compatibilite)
- `screenshots/*.png` pour `default`;
- `screenshots/<project>/*.png` sinon;
- `screenshots/captures.md` et `screenshots/<project>/captures.md`;
- `screenshots/.counter` et `screenshots/<project>/.counter`;
- `screenshots/.project.json` et `screenshots/<project>/.project.json`;
- `order/<project>.md`;
- `notes/<project>/notes.md`;
- sorties `captures_<project>.html` et `captures_<project>.pdf`.

## Plan d’implementation (ordre recommande)
### Phase 1: Fondations app
- creer structure des modules Swift;
- centraliser chemins de travail dans un `WorkspacePaths`;
- definir erreurs metier et journalisation.

Etat: termine (structure + bootstrap + paths + erreurs + logging).

### Phase 2: Persistance et modeles
- parser/serializer `captures.md` (blocs `<!-- CAPTURE: ... -->`);
- parser/serializer `notes.md` (blocs `<!-- NOTE: ... -->`);
- gestion compteur `.counter` avec fallback scan des PNG;
- sanitation de noms projet (meme regles legacy).

Etat: termine (codec markdown/json legacy + store fichiers + compteur compatible + chargement projets au bootstrap).

### Phase 3: Capture WebKit
- charger URL dans `WKWebView` hors ecran;
- viewport fixe 1920x1080;
- attente `didFinish` + delai de rendu;
- tentative dismissal cookie banners;
- snapshot PNG + nommage `id_domain_YYYYMMDD_HHMM.png`;
- append capture dans `captures.md`.

Etat: termine (moteur WebKit offscreen + timeout + dismissal cookies + snapshot PNG + persistance legacy + declenchement UI).

### Phase 4: UI principale native
- ecran capture (URL + bouton Capturer + preview);
- ecran historique (liste par projet, tri date desc, suppression);
- ecran projets (selection, creation, titre HTML);
- feedback erreurs/succes equivalents au flux actuel.

Etat: termine (UI native avec sections projets/capture/preview/historique + suppression + feedback + ouverture des sorties generees existantes).

### Phase 5: Edition ordre + notes
- vue d’edition native:
  - reorder des captures;
  - edition note markdown simple par capture;
  - sauvegarde atomique ordre + notes.

Etat: termine (editeur natif ordre + notes avec chargement legacy, reordonnancement, edition par capture et sauvegarde atomique).

### Phase 6: Generation HTML
- porter `generate_captures_html.py` en Swift:
  - application ordre;
  - rendu notes markdown simple (`*gras*`, `_italique_`, listes `- `);
  - toolbar HTML (`Mode edition`, `Export PDF`) et layout equivalent.

Etat: termine (generateur HTML Swift branche dans l'app, bouton natif de generation, ouverture du HTML genere et statut de progression).

### Phase 7: Export PDF
- convertir HTML genere en PDF A4 paysage;
- injecter slide titre;
- 1 capture par page;
- conserver fond/couleurs/notes/liens.

Etat: termine (export PDF natif WebKit depuis l'app, regeneration HTML avant export, slide titre injectee, style print A4 paysage, ouverture automatique du PDF genere).

### Phase 8: QA parite
- tests unitaires parseurs markdown + sanitation + compteur;
- tests integration sur donnees de reference;
- checklist de non-regression fonctionnelle.

Etat: en cours (suite de tests Xcode ajoutee et validee, integration sur fixtures de reference en place, checklist manuelle documentee dans `PHASE8_QA_CHECKLIST.md`).
Automatisation validee le 17 fevrier 2026: 17 tests passes (unitaires + integrations). Reste a executer: checklist manuelle UI/PDF.

## Risques et points d’attention
- Capture WebKit vs Playwright: variations de rendu possibles selon sites.
- Dismiss cookies: heuristique a fiabiliser (iframes et boutons non standards).
- Export PDF: necessite un pipeline de rendu HTML stable pour pagination.

## Definition of Done (MVP parite)
- toutes les features README legacy fonctionnent en natif;
- donnees generees compatibles avec le format actuel;
- build Debug OK dans Xcode;
- aucune dependance au dossier d'archive.
