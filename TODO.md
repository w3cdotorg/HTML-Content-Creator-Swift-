 - Ajouter des tests SwiftUI pour tester l'interface sans avoir à rebuild le projet
 - Ajouter des filtres anti-spams plus puissants (https://github.com/blocklistproject/Lists)


Très bonne base maintenant. Voici les meilleures pistes, par ordre de valeur:

Robustesse capture par domaine
Ajouter des profils par site (nytimes, wordpress, etc.) avec stratégie dédiée: timeout, séquences JS, fallback explicite.

Moteur anti-bannières renforcé
Combiner WKContentRuleList + règles CSS/JS par domaine + boucle post-load (2-3 passes) avec métriques “dismissed/suppressed”.

Détection “page prête” plus fiable
Ne pas se limiter à didFinish: attendre aussi un DOM stable (taille texte, images chargées, mutation idle) avant snapshot.

Qualité/consistance export PDF
Ajouter un mode “strict slide”: 1 page = 1 slide garanti, marges verrouillées, tests visuels de pagination pour éviter tout recadrage.

QA automatisée visuelle
Créer des tests snapshot (PNG/PDF) sur un set de pages de référence pour détecter régressions de rendu/cookies/pub.

Observabilité produit
Ajouter un panneau debug exportable: timing navigation, étapes fallback, règles anti-cookie appliquées, raisons d’échec lisibles.

UX “batch capture”
Permettre coller une liste d’URLs et lancer une file de captures avec progression, retry, et rapport final.

Gouvernance des données projet
Versionner le format de projet (manifest v1/v2), inclure migration automatique et sauvegarde de sécurité avant changements.

Distribution macOS production
Finaliser signatures, notarization, sandbox entitlements minimaux, et checklist release (icône, Doc Types, erreurs utilisateur propres).

Performance
Précompiler/cacher les content rules, mutualiser les WKWebView/process pool, et limiter les relancements coûteux.

Si tu veux, je peux te proposer un plan concret “Phase 9” (2 semaines) avec backlog priorisé et estimations.