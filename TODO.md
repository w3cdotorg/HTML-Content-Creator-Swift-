# Priorité 1

## Ajouter des tests SwiftUI pour tester l'interface sans avoir à rebuild le projet
## Ajouter des filtres anti-spams plus puissants (https://github.com/blocklistproject/Lists)
## Robustesse capture par domaine - Ajouter des profils par site (nytimes, wordpress, etc.) avec stratégie dédiée: timeout, séquences JS, fallback explicite.
## Moteur anti-bannières renforcé - Combiner WKContentRuleList + règles CSS/JS par domaine + boucle post-load (2-3 passes) avec métriques “dismissed/suppressed” et 
## Détection “page prête” plus fiable - Ne pas se limiter à didFinish: attendre aussi un DOM stable (taille texte, images chargées, mutation idle) avant snapshot.
## QA automatisée visuelle - Créer des tests snapshot (PNG/PDF) sur un set de pages de référence pour détecter régressions de rendu/cookies/pub.

# Priorité 2
## Reformater les règles spécifiques (cookies / bannières) par sites sous des fichiers distincts
## Qualité/consistance export PDF - Ajouter un mode “strict slide”: 1 page = 1 slide garanti, marges verrouillées, tests visuels de pagination pour éviter tout recadrage.
## Observabilité produit - Ajouter un panneau debug exportable: timing navigation, étapes fallback, règles anti-cookie appliquées, raisons d’échec lisibles.
## Performance - Précompiler/cacher les content rules, mutualiser les WKWebView/process pool, et limiter les relancements coûteux.
## Distribution macOS production - Finaliser signatures, notarization, sandbox entitlements minimaux, et checklist release (icône, Doc Types, erreurs utilisateur propres).