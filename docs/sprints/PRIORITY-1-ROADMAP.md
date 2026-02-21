# Priorité 1 - Roadmap d'implémentation

## Sprint 1 - Fondations testabilité UI + profils de capture
Objectif:
- Rendre les vues SwiftUI testables de façon automatisée.
- Introduire un système de profils par domaine pour la capture.

Livrables:
- Accessibilité/identifiants UI pour automatisation.
- Tests de rendu SwiftUI (smoke snapshot tests).
- `CaptureSiteProfile` + resolver (par host).

## Sprint 2 - Anti-spam / anti-bannières renforcé
Objectif:
- Étendre le filtrage anti-spam avec une base de domaines type BlockListProject.
- Structurer une boucle post-load avec métriques.

Livrables:
- Génération de règles WKContentRuleList additionnelles depuis domaines blocklist.
- Passe post-load 2-3 itérations avec agrégation métriques `dismissed/suppressed/clicked`.

## Sprint 3 - Détection "page prête" plus fiable
Objectif:
- Fiabiliser l'instant de snapshot via stabilité DOM/ressources.

Livrables:
- Observer de mutations DOM injecté côté page.
- Attente de stabilité (idle mutations + images chargées + convergence texte/noeuds).

## Sprint 4 - QA visuelle automatisée
Objectif:
- Détecter les régressions visuelles sur PNG/PDF.

Livrables:
- Tests snapshot visuels (hash/tolérance) sur sorties de référence.
- Baselines déterministes issues de fixtures locales.

## Ordre d'implémentation
1. Fondations Sprint 1
2. Renforcement anti-spam / anti-bannières Sprint 2
3. Readiness DOM Sprint 3
4. Snapshot QA Sprint 4
