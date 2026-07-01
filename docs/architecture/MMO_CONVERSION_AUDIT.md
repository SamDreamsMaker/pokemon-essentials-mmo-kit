# Stratégie de conversion MMO — Pokémon Essentials v21.1 (mkxp-z / MRI Ruby 3.1.3)

> Document d'architecture canonique. Objectif : transformer le moteur solo en **SDK MMO** déployable de façon identique en « hôte Windows entre amis » et « serveur dédié Linux en prod », **sans forker le core** (extension via PluginManager / HandlerHash / EventHandlers / SaveData / alias).
>
> Ce document a été produit par un audit multi-agents (7 sous-systèmes + faisabilité réseau), puis **corrigé par une revue adversariale** dont les conclusions sont tracées en §10. Les corrections principales portent sur §1 (concurrence) et §5.3 (combat).

---

## 1. Résumé exécutif

### Verdict de faisabilité : **FAISABLE en greenfield, sans édition du core** — sous réserve d'un dérisquage runtime bloquant (Phase 0).

Un fait **solide** et deux hypothèses **à dérisquer** :

1. ✅ **SOLIDE — Le runtime est un MRI Ruby 3.1.3 standard et complet.** Preuves : `x64-msvcrt-ruby310.dll`, chaîne `ruby 3.1.3`, symboles `Init_socket`, `rb_w32_socket`, `Init_nonblock`, `Init_json`, `Init_zlib`, `Init_digest`, `rb_thread_call_without_gvl`. La stdlib réseau (`socket`, `net/http`, `json`, `zlib`, `digest`, OpenSSL 1.1.1/TLSv1.3) est embarquée dans `Game.exe`. Aucun code réseau existant (`require 'socket'`/`TCPSocket` absents de `Data/Scripts`) → intégration sans conflit. **Le client PEUT faire du réseau natif.**

2. ⚠️ **À DÉRISQUER — La concurrence par thread réseau est *plausible* mais NON prouvée.** `Thread`/`Mutex`/`Queue` sont présents et le GVL est relâché sur l'I/O socket (`rb_thread_call_without_gvl`), ce qui *devrait* laisser la boucle de jeu tourner pendant une lecture socket bloquante. **MAIS** la « preuve » initialement avancée (`PluginManager.rb:291-298`) est en réalité un thread d'**affichage d'erreur** suivi de `Kernel.exit!` — il ne démontre ni le réseau, ni la durabilité, ni la concurrence avec le gameplay. → **Spike Phase 0 obligatoire** (voir §8), avec fallback non-bloquant `read_nonblock`/`IO.select` prévu comme chemin principal de repli.

3. ⚠️ **À REQUALIFIER — Le combat rejouable existe, mais en *record-replay*, pas en *seed-déterminisme*.** Le module `RecordedBattle` (`011_Battle/008_Other battle types/005_RecordedBattle.rb`) enregistre la **liste** des nombres aléatoires produits et la rejoue linéairement (`@randomnums[@randomindex]`). Ce n'est **pas** un modèle « seed distribué → chaque client re-simule ». Conséquence d'architecture (voir §5.3) : **le serveur doit calculer le combat (round par round) et diffuser un flux d'événements ; le client REJOUE, il ne re-simule pas.** De plus, plusieurs sources d'aléa **contournent** `pbRandom` (`pbAIRandom` ×18, `rand(2)` en command_phase, `rand(3)` pokérus) → un **audit RNG exhaustif** est un prérequis.

Le core expose bien les points d'extension nécessaires : `PluginManager` (chargement au boot via `eval(code, TOPLEVEL_BINDING)`), `EventHandlers` (bus nommé : `:on_frame_update`, `:on_enter_map`, `:on_step_taken`, `:on_start_battle`…), `SaveData.register/unregister` (backend de persistance redéfinissable par valeur), la convention `alias` dominante, et `RecordedBattle`/`Playback` comme point d'ancrage combat.

### Le pari technique central (corrigé)

> **Le serveur est l'unique autorité ; le client est un lecteur/interpolateur. Le combat suit un modèle record-replay filtré, pas une re-simulation par seed.**

Quatre inversions d'autorité, toutes réalisables via des points d'extension existants :

- **État joueur** (`$player`, `$bag`, `$PokemonStorage`, `$game_player`) : retiré de l'autorité du save local, redirigé vers un backend serveur. Le `Game.rxdata` client ne fait **plus foi**. ⚠️ *L'anti-triche ne repose PAS sur ce seul fait* : un client modifié peut toujours mentir en mémoire — seule l'**autorité serveur des mutations** (validation de `money=`/`badges=`/party) protège (voir §10-G8).
- **Mouvement** : le client envoie ses **intentions** (tuile atteinte, direction) sur `:on_step_taken` ; le serveur valide (adjacence + passabilité + **rate-limiting temporel**) et diffuse ; les autres joueurs = `Game_Character` « fantômes » injectés via `:on_new_spriteset_map`, interpolés en rejouant le lerp `update_move` local.
- **Combat** : le serveur exécute une `Battle` **headless** (Scene no-op) qui **enregistre** choix + randoms + événements ; les clients rejouent via un **flux filtré** (ne révélant que l'information visible). ⚠️ Le combat client tourne sur des **copies** des Pokémon, jamais sur `$player.party` autoritatif (voir §5.3 & §10-G4).
- **Contenu** (`GameData::*::DATA`) : figé au packaging, identique des deux côtés, **read-only après boot**, validé par **checksum code+contenu** au handshake.

Le risque structurant n'est pas la faisabilité de principe mais l'**architecture des processus** : les singletons globaux (`$game_map`, `$game_switches`, `@@events`, `@values`) imposent **1 process = 1 contexte logique**. Le choix « 1 process = 1 zone » minimise la réécriture ; la virtualisation par-joueur des singletons est bien plus lourde (voir §9.1).

---

## 1-bis. Phase 0 — vérification runtime (empirique, 2026-07-01) ✅

Sonde exécutée dans le **vrai** runtime (mkxp-z 2.4.2 / MRI 3.1.3, via un plugin de boot `Plugins/MMOKit_Phase0Probe/`). Résultats **mesurés** — ils corrigent l'étude réseau statique, qui avait sur-estimé la stdlib disponible :

| Test | Résultat | Conséquence |
|---|---|---|
| `TCPSocket`/`TCPServer` loopback round-trip | ✅ **GO** | Transport MMO sur **TCP brut : viable, socle confirmé** |
| `read_nonblock` + `IO::WaitReadable` sur socket | ✅ OK | Poll non-bloquant par frame possible |
| `Marshal` roundtrip | ✅ OK | Wire-format Ruby↔Ruby dispo **nativement** |
| `zlib`, `digest`, `stringio`, `io/nonblock`, `fcntl`, `monitor` | ✅ OK | Compression, hash (handshake/checksum), nonblock |
| `require 'json'` | ❌ LoadError | **JSON stdlib absent** → Marshal primaire, ou **vendorer** un JSON pur-Ruby |
| `require 'net/http'`, `'openssl'` | ❌ LoadError | HTTP(S) hors-jeu via **`HTTPLite` natif mkxp-z** (présent), pas net/http |
| `require 'timeout'/'uri'/'securerandom'/'base64'/'resolv'` | ❌ LoadError | Pas de `Timeout.timeout` → timeouts via `IO.select`. base64/uri/DNS à vendorer/contourner |
| Thread bg, main **CPU-bound** | ⚠️ WARN | Un thread principal 100 % CPU affame le thread réseau (pas de préemption timer) |
| Thread bg, main **cède le GVL** (comme `Graphics.update`/vsync) | ✅ OK (`recv_at=0.301s`) | **Thread réseau d'arrière-plan viable dans la vraie boucle** (chaque frame cède le GVL) |

**Verdict Phase 0 : GO.** Amendements au §4 (Transport & runtime) :
- **Wire-format** : **Marshal** (dispo immédiatement) comme socle ; **JSON = à vendorer** (pur-Ruby) quand on veut interop/requêtabilité — la C-ext `json` est dans la DLL mais son loader `.rb` est **absent** du load path.
- **HTTP(S) hors-jeu** : **`HTTPLite`** (natif mkxp-z, présent), PAS `net/http`. TLS géré par HTTPLite.
- **Concurrence — modèle retenu = I/O non-bloquante pilotée par le thread principal (« pump » par frame).** La Phase 1 a révélé deux limites du scheduler mkxp-z qui invalident le modèle « thread par connexion » : (1) **les threads engendrés par un thread non-principal sont affamés** (un acceptor qui spawn un thread-lecteur par client → le lecteur ne tourne jamais) ; (2) **`IO.select` sur un socket d'écoute ne signale pas les connexions en attente**. Ce qui MARCHE de façon fiable : un `accept` **bloquant** dans **un** thread engendré par le thread principal, + tout le reste (reads/writes/relais) en `read_nonblock` sur le thread principal via un `pump()` appelé chaque frame. `NetClient` est 100 % non-bloquant sans thread ; `RelayServer` = 1 thread accept + `pump`. **Validé de bout en bout** (self-test Phase 1 : PASS). Un thread réseau d'arrière-plan *unique* engendré par le main reste viable (Phase 0 test B) mais on ne s'en sert pas — le pump par frame est plus robuste et colle à la boucle de jeu.
- **Quirk mkxp-z** : `require` d'une stdlib absente peut lever `SystemStackError` (pas seulement `LoadError`) sous pression de pile au boot — ne pas requérir de libs absentes ; prudence sur la récursion profonde.

> ⚠️ **Le dépôt est un OVERLAY, pas un jeu complet.** `.gitignore` exclut `Graphics/`, `Audio/`, `Plugins/`, `Game.ini`, la majeure partie de `Data/` (seuls `Scripts.rxdata`, `Scripts/`, `messages_core.dat` versionnés). Le clone nu ne boote pas seul — il a fallu un `Game.ini` minimal + l'argument `debug` pour amener mkxp-z jusqu'à `runPlugins`. **Le dev/test réel exige une copie complète d'Essentials v21.1** (assets de base non redistribuables). Décision d'environnement à prendre avant la Phase 1.

---

## 2. Cartographie de l'architecture Essentials

| Sous-système | Rôle | État global possédé | Sévérité MMO |
|---|---|---|---|
| **État & persistance** (`002_Save data/*`, `015_.../004_Player.rb`, `Game_System`) | Sérialise/restaure tout l'état solo via le registre `SaveData::Value` → globales → `Marshal.dump` dans un unique `Game.rxdata` | `$player`, `$bag`, `$PokemonStorage`, `$PokemonGlobal`, `SaveData.@values/@conversions` | **Critique** — mono-fichier/mono-slot/mono-joueur ; autorité économique (`money=`, `badges=`) et identité (`id = rand(2**16)`) côté client |
| **Boucle de jeu & timing** (`999_Main.rb`, `Scene_Map.rb`, `012_Overworld/001_Overworld.rb`, `Messages.rb`) | Boucle synchrone mono-thread cadencée par `Graphics.update` (~60fps) et `System.uptime` ; boucles bloquantes (messages/menus/`pbWait`) | `$scene`, `Graphics.frame_count`, `@@events` | **Critique** — boucles bloquantes gèlent un pump réseau *par frame* ; tick logique couplé au rendu ; serveur Linux headless sans `Graphics.update` naturel |
| **Classes de jeu & état monde** (`004_Game classes/*`) | Modèle d'état runtime RMXP : `Game_Map`, `Game_Switches/Variables/SelfSwitches`, `Game_System`, `Game_Screen`, `PokemonMapFactory` | `$game_map`, `$map_factory`, `$game_switches`/`$game_variables` (1..5000), `$game_self_switches`, `$game_temp`, `$game_screen` | **Critique** — singletons mono-joueur ; aucune distinction *world-shared* vs *per-player* dans les switches/variables (piège n°1) |
| **Overworld, mouvement & événements** (`Game_Character.rb`, `Game_Player.rb`, `Game_Event.rb`, `Sprite_Character.rb`, `Spriteset_Map.rb`) | Déplacement grille-par-tuiles (`x/y` + `real_x/real_y` interpolés), charset, rencontres, transferts de map, triggers par proximité | `$game_player` (unique), `$PokemonEncounters`, `$PokemonGlobal` (surf/vélo/repel) | **Critique** — `$game_player` câblé en dur partout (`passable?`, `check_event_trigger_*`) ; simulation locale autoritaire ; RNG de rencontre local |
| **Système de combat** (`011_Battle/*`) | Moteur tour-par-tour ; boucle bloquante `pbBattleLoop` ; `Battle::Scene` injectable ; `Battle::AI` séparée ; `RecordedBattle`/`Playback` (record-replay) | RNG global (`pbRandom → rand`) **+ sources hors-pbRandom** (`pbAIRandom`, `rand(2/3)`), `$player.party` (muté **par référence** via `Battler#hp=`), `money`, `pokedex`, `$stats` | **Critique** — RNG non-seed & fragmenté ; état autoritatif muté par référence côté client tout au long du combat ; confidentialité (le record contient les DEUX parties) ; boucle bloquante |
| **Données & pipeline contenu** (`010_Data/*`, `021_Compiler/*`) | Tables statiques immuables (`Species`, `Move`, `Item`, `Encounter`, `MapMetadata`) via `GameData.load_all` ; compilateur PBS→`.dat` (Marshal) | `GameData::*::DATA` (par classe), `$data_system`/`$data_tilesets`, artefacts `.dat` | **Élevée/Moyenne** — contenu idéal à figer identiquement, MAIS Marshal non versionné ; compilateur couplé à `Graphics`/`Input`/`$DEBUG` |
| **Architecture d'extension** (`001_Technical/005_PluginManager.rb`, `EventHandlers`, `SaveData`) | Hooks : PluginManager, HandlerHash/EventHandlers/MenuHandlers, SaveData ; convention `alias` | `@@Plugins`, `@@events`, `@@handlers`, `SaveData.@values` | **Élevée** — registres mono-process ; `:on_frame_update` seul tick, **mort hors overworld** ; aucun verrou de concurrence |
| **Faisabilité réseau** (étude runtime) | MRI 3.1.3 complet ; `socket`/`net/http`/`json`/`zlib`/OpenSSL embarqués ; threading GVL-relâché sur I/O | — | **Habilitant** — TCP natif viable ; thread réseau *plausible non prouvé* ; TLS/CA à valider au runtime |

**Frontière de portée :** `GameData::*::DATA` = **contenu** (règles, immuable) ; tout le reste des globales = **état runtime** dont l'autorité doit être arbitrée.

---

## 3. Le défi MMO : modèle d'autorité

Chaque global du core est reclassé selon sa **vraie portée**. Trois catégories :

### A. Server-authoritative — WORLD-SHARED (autoritatif serveur, diffusé à tous)
- Sous-ensemble **réservé** de `$game_switches` / `$game_variables` (ex. « boss mondial vaincu ») — espace d'IDs à partitionner (§9.4). *Écritures sérialisées côté serveur ; le client n'écrit jamais, il reçoit l'état résolu* (§10-G6).
- Positions/états des autres joueurs sur une zone.
- État d'events partagés (portes de scénario, PNJ de quête) — si le modèle « monde partagé » est retenu.
- Rencontres sauvages **si** arbitrage anti-triche (sinon restent client, §9.6).
- Compteurs de temps arbitrés : `play_time`, pokerus, bug contest.

### B. Server-authoritative — PER-PLAYER (autoritatif serveur, scoped par compte)
- **Identité** : `Trainer#id` — remplacer `rand(2**16)` par un `account_id`/`trainer_id` serveur (override `new_game_value` de `:player`).
- **Économie & progression** : `money`, `coins`, `battle_points`, `badges`, `pokedex` — aliaser les setters pour **validation serveur** ; le client n'affiche que le résultat.
- **Équipe / sac / boxes** : `$player.party`, `$bag`, `$PokemonStorage` — retirés de l'autorité locale, persistés serveur ; le combat applique des **deltas** serveur.
- **Progression d'events** : `$game_self_switches` (coffres, portes, PNJ), majorité de `$game_switches/$game_variables` (quêtes perso).
- **`$PokemonGlobal`** : stepcount, day_care, mailbox, escapePoint/healingSpot.

### C. Client-only (jamais envoyé — présentation/session)
- `$game_screen` (tone/flash/shake/météo/pictures), `Game_Map#display_x/display_y` (caméra), scroll/fog.
- Quasi tout `$game_temp` (`menu_calling`, `in_battle`, `player_transferring`…).
- `$PokemonSystem` (volume, langue, taille d'écran).
- Météo : client-only par défaut, éventuellement diffusée par zone (§9.12).

### Principe d'arbitrage
Le client **envoie des intentions, jamais des résultats**. Il ne possède **ni** le RNG de combat, **ni** l'équipe adverse, **ni** l'autorité sur argent/badges/équipe/identité. Toute mutation autoritative transite par le serveur, qui renvoie l'état résolu appliqué via handlers.

---

## 4. Transport & runtime

### Choix recommandé (fondé sur l'étude réseau)

**Socle = TCP brut via `TCPSocket`, framing longueur-préfixe (uint32 big-endian) + payload.**

- **Faisabilité `strong`** : `Init_socket` + `rb_w32_socket` confirment `TCPSocket` ; JSON C-ext (`Init_json`) et Marshal disponibles pour le payload.
- **Wire-format** : **JSON** pour le protocole applicatif (lisible, interop back-end, requêtable) ; **Marshal** acceptable comme format *initial* Ruby↔Ruby pour objets complexes (`Pokemon`), à migrer vers un **schéma typé JSON** rapidement (§10-G9 : Marshal couple aux définitions de classe exactes → fragile au versioning).
- **HTTP(S) via `net/http`** (`strong`) pour le **hors-jeu** : auth/login, matchmaking, REST — chaque appel dans un **Thread court**.
- **UDP** (`possible`) : optionnel, position haute fréquence + réconciliation. **Non nécessaire au MVP** (mouvement discret : ~1 paquet/tuile).
- **WebSocket maison** (`possible`) : seulement si l'infra serveur l'impose ; implémentable en Ruby pur (handshake Upgrade + framing RFC6455, masquage via `Init_digest`). Effort inutile pour un SDK entre amis.
- **Gems tierces** (`weak`) : **à proscrire** — aucun rubygems/vendor, pas de toolchain C-ext. Stdlib + Ruby pur uniquement.

### Concurrence : thread réseau (à valider), fallback poll non-bloquant

**Modèle visé :**
1. Un **Thread réseau d'arrière-plan** possède le socket, lectures bloquantes (GVL relâché sur l'I/O).
2. Il pousse les messages reçus dans une **`Queue` thread-safe** (ou `Array` + `Mutex`).
3. Le **thread principal draine la Queue une fois par frame** et applique l'état. **Aucune API RGSS (`Graphics`/`Sprite`/`Bitmap`/`Input`) touchée depuis le thread réseau** — il est cantonné réseau + sérialisation ; seul le thread principal mute l'état de jeu.

> ⚠️ **Ce modèle n'est pas prouvé sous mkxp-z** (voir §1.2 & §10-G3). Le spike Phase 0 doit mesurer, sur une session de 30+ min traversant overworld/combat/menus, que le thread progresse et que la latence de drain reste acceptable pendant les boucles bloquantes. **Fallback de premier plan** si le thread stagne : `read_nonblock` + `IO.select` (timeout 0) via `Init_nonblock`, drainé par frame.

**Pourquoi le poll par frame seul ne suffit pas :** `:on_frame_update` n'est déclenché que par `Scene_Map#updateSpritesets` — **hors overworld** (combats, menus à boucle `Graphics.update` propre) il ne tourne plus. Il faut donc aussi aliaser `pbUpdateSceneMap` (couvre messages/menus) et prévoir un tick pendant le combat.

### Inconnues à vérifier au runtime (checklist boot — Phase 0)
- [ ] `require 'socket'` OK et `TCPSocket.new('host', port)` connecte sous mkxp-z.
- [ ] `require 'json'` et `require 'net/http'` se chargent.
- [ ] `require 'openssl'` OK **ET** bundle CA accessible (`SSL_CERT_FILE`). Sans CA → TCP clair sur réseau privé, ou terminaison TLS au reverse-proxy.
- [ ] Le thread de lecture socket **progresse en session longue** (mesure latence frame-à-frame + drain pendant boucles bloquantes).
- [ ] **Fermeture propre du socket / pas de fuite de thread** au soft-reset RGSS (F12 / `Kernel.exit!`).
- [ ] DNS via `TCPSocket.new('host', …)` sous Windows ; sinon `resolv` ou IP directe.
- [ ] **Parité Linux** : même MRI 3.1 des deux côtés ; OpenSSL système.
- [ ] **Pare-feu Windows** : invite au premier trafic de `Game.exe` côté hôte.

---

## 5. Modèle de synchronisation

### 5.1 Mouvement / overworld & remote players

**État à synchroniser** : `(map_id, x, y, direction, move_speed, état de mouvement, outfit)`. Les `real_x/real_y` sont **dérivés localement** par lerp (`Game_Character#update_move`) → **non transmis**, le client rejoue le même modèle.

**Émission (client)** : `:on_step_taken` / `:on_player_step_taken` / `:on_player_change_direction` → 1 paquet par tuile (~0.25s à pied) ; `:on_leave_tile` pour sortie de zone.

**Réception (remote players)** : sous-classe **`RemotePlayer < Game_Character`** (réutilise l'interpolation `update_move`, **sans** la logique input/rencontre de `Game_Player`) ; sprites via `:on_new_spriteset_map` ; interpolation drainée sur `:on_frame_update`.

**Autorité position** : serveur valide chaque tuile — le modèle **discret par tuile** rend la validation triviale (adjacence + `passable?`), **plus** un rate-limiting temporel (§10-G12 : borner la fréquence de pas contre le speedhack) et une whitelist de warps pour les transferts. La caméra étant pilotée par le joueur **local**, les remote players se rendent relativement à elle sans couplage inverse — favorable.

**Charset distant** : transmettre un **enum d'état de mouvement** + `character_ID`/outfit (pas `character_name` brut, dérivé de `$PokemonGlobal.surfing/bicycle` local).

**Transferts de map** : aliaser `Scene_Map#transfer_player` (détruit/recrée le spriteset) pour émettre **join/leave de zone** et filtrer les remote players par map.

**Collision entre joueurs** : décision ouverte (§9.5) — solides (bloquants → griefing) vs traversables (`through`).

### 5.2 Monde partagé vs instances

Deux architectures (§9.1) :
- **1 process = 1 zone** (recommandé MVP) : singletons conservés ; chaque process simule **une** zone. Remote players = `Game_Character` fantômes injectés via `:on_game_map_setup`/`:on_enter_map`.
- **1 process multi-joueurs virtualisé** : `$game_map`/`$game_switches` virtualisés par joueur — réécriture lourde. À éviter au départ.

**Events partagés vs instanciés** : `Game_Event#refresh` dépend de `$game_switches`/`$game_self_switches`/`$game_variables`. Si ces switches deviennent per-player, un même event **diffère par joueur** → virtualisation par-joueur des events. `Game_System#map_interpreter` et `Game_CommonEvent#@interpreter` sont **mono-instance** → cutscenes/dialogues concurrents impossibles sans refonte → **cutscenes instanciées par joueur** (exécution client, validation serveur) est la voie pragmatique.

### 5.3 Combats & PvP — **modèle record-replay filtré** (corrigé)

> Correction majeure vs la première synthèse : le core ne supporte **PAS** « seed distribué → chaque client re-simule ». Il supporte le **record-replay**. L'architecture ci-dessous en tient compte.

1. **Le serveur est l'autorité de calcul.** Il exécute la `Battle` **headless** (sous-classe de `Battle::Scene` dont `pbDisplay`/`pbAnimation`/`pbShowCommands` deviennent des **émetteurs d'événements sérialisés**, injectée via `BattleCreationHelperMethods.create_battle_scene`). Il **enregistre** les choix, les randoms et les événements révélés.
2. **RNG maîtrisé — audit exhaustif requis (§10-G2).** Aliaser `Battle#pbRandom` vers un `Random.new` d'instance ne suffit **pas** : `pbAIRandom` (`011_Battle/005_AI/008_AI_Utilities.rb`, 18 usages), `rand(2)` en command_phase (`008_MoveEffects_MoveAttributes.rb:1143`), `rand(3)` pokérus (`002_Battle_StartAndEnd.rb:491,494`) contournent `pbRandom`. **Prérequis** : auditer TOUS les `rand`/`shuffle`/`sample` de `011_Battle/` et, pour chacun, soit le router vers l'enregistrement, soit le neutraliser côté serveur. Le carve-out `rand` vs `pbRandom` selon `@battle.command_phase` doit être **préservé** sinon la séquence enregistrée diverge.
3. **Le client REJOUE, il ne re-simule pas.** Chaque client reçoit le flux enregistré et le rejoue via `RecordedBattlePlaybackModule` avec sa `Battle::Scene` visuelle. Implication de latence : le serveur calcule le round (ou le combat) **avant/pendant** la diffusion — à assumer dans le protocole (streaming round-par-round pour la réactivité).
4. **Confidentialité — flux FILTRÉ obligatoire (§10-G11).** Le `RecordedBattle` existant Marshal-dump **les deux** parties (`properties['party1']` ET `['party2']`) → **inutilisable tel quel** pour le rejeu client (fuite de l'équipe adverse). Il faut concevoir un **flux de rejeu filtré** ne contenant que l'information révélée par round — c'est un développement à part entière, pas une réutilisation directe.
5. **État joueur isolé — combattre sur des COPIES (§10-G4).** `Battler#hp=` (`Battle_Battler.rb:109`) mute `$player.party` **par référence**, et `pbEndOfBattle` écrit `money`/party/pokedex sur ~14 sites. Le combat client ne doit **jamais** muter le party autoritatif : il tourne sur des **copies** (Marshal des `Pokemon`) ; l'état résolu n'est appliqué qu'**après acquittement serveur** (deltas idempotents, rejouables). Cela ferme la triche mémoire *et* le party incohérent sur déconnexion en plein combat.
6. **Choix réseau** : surcharger `pbCommandPhaseLoop`/`pbCommandMenu` — pour un battler distant, **attendre un message réseau** puis appeler `pbRegisterMove/Target/Switch/Item` (API déjà utilisée par le Playback). `pbCommandPhaseLoop` sépare déjà player vs AI → frontière naturelle. Prévoir un **timeout de choix → action par défaut/forfait** dès cette phase (§10-G5, exigence de correction).
7. **PvP** : deux flux de choix distants sur le **même Battle serveur**, `@controlPlayer=false` des deux côtés, IA désactivée.
8. **Effets post-combat** : `pbEndOfBattle` + `:on_end_battle` (argent, pokedex, évolutions) calculés serveur puis répliqués ; les scènes UI (`PokemonEvolutionScene`) restent purement clientes.

**Concurrence** : un combat = **un contexte isolé**. Le modèle « 1 process/worker par combat » est simple mais **coûteux à l'échelle** (§10-G7) → préférer Fibers/état-machine à terme. À trancher selon la densité cible.

**Parité de version obligatoire** : le record-replay exige client et serveur avec **exactement** le même code de combat + `002_BattleSettings.rb`. Handshake = **hash du code de combat + Settings**, pas seulement des `.dat` (§10-G9).

### 5.4 Échanges (trades)
Transaction autoritative serveur à **deux phases** : (1) **verrou** des deux Pokémon, (2) validation, (3) échange atomique avec **rollback idempotent** + résolution de la **double-dépense** (même Pokémon verrouillé dans deux trades). Périmètre du verrou (party seule vs boxes) : §9.11. UI reste cliente. À traiter comme exigence de **correction** en Phase 5, pas de durcissement Phase 6 (§10-G5).

### 5.5 Chat & social
`MenuHandlers.add(:pause_menu, :mmo_players, {...})` — liste joueurs / trade / chat **sans toucher le menu core**. Chat = message applicatif sur le socket TCP (broadcast par zone).

### 5.6 Persistance serveur
- **Retirer l'autorité locale sans casser le bootstrap (§10-G8)** : `new_game_value` de `:player` (`Game_SaveValues.rb:7`) est le **seul** bootstrap de `$player = Player.new`. Donc **ne pas `unregister` sèchement** — réenregistrer `:player`/`:bag`/`:storage_system` avec un `save_value` no-op/proxy et un `new_game_value`/`load_value` qui **hydrate depuis le serveur au login** (bloquant jusqu'à réception). Le reste du core continue d'utiliser les globales **inchangées**.
- **Rediriger les I/O** : aliaser `Game.save`/`Game.save_to_file`/`Game.load` vers le backend serveur.
- **Wire-format** : Marshal initial → **JSON/colonnes DB** rapidement (anti-triche, interop web/admin).
- **Migrations** : `SaveData.register_conversion` (déjà versionné) pour le schéma serveur — upgrade-safe depuis l'upstream. ⚠️ Prévoir un **versionnage distinct** pour le wire réseau live (register_conversion vise le save, pas le protocole).
- **Exclusions** : `Interpreter` de `Game_System` et références de map non (dé)sérialisables hors-process → exclure et reconstruire à la connexion.
- **Granularité** : persistance **incrémentale/transactionnelle par sous-état** (équipe/sac/boxes/argent), pas full-snapshot (§9.8).
- **Cohérence contenu** : `GameData::*::DATA` **read-only après boot** + **checksum au handshake** (refus si divergence). Découpler le compilateur PBS de `Graphics`/`Input`/`$DEBUG` (mode CLI) ou pré-compiler/distribuer les `.dat` versionnés.

---

## 6. Modèle de déploiement

### Le même artefact pour les deux cibles
Le SDK est **un plugin** (`Plugins/PokeMMO/` + `meta.txt`) chargé par `PluginManager`, plus un **mode d'exécution** commuté au boot (client / serveur-headless). Le **même code Ruby MRI 3.1** tourne Windows (amis) et Linux (prod).

### Windows « entre amis » (hôte embarqué)
- L'hôte lance `Game.exe` en **double rôle** : il joue **ET** héberge l'autorité (serveur-headless in-process ou process local séparé sur `127.0.0.1`).
- Les amis se connectent en TCP à l'IP de l'hôte.
- Contraintes documentées : invite pare-feu Windows ; TLS optionnel (réseau privé → TCP clair acceptable).

### Linux « prod » (serveur dédié) — ⚠️ non dérisqué (§10-G10)
Autorité serveur **headless**. Deux options **à valider en Phase 0** :
- **mkxp-z headless / dummy-video** : réutilise les scripts (dont le compilateur PBS couplé à `Graphics`/`Input`) → nécessite un mode dummy-video prouvé. **Non démontré dans le dépôt.**
- **Extraction en Ruby MRI pur** (sans RGSS) : plus léger, mais **casse la parité d'artefact** (le déterminisme combat en dépend) → impose un mécanisme de test croisé serveur-MRI vs client-mkxp-z sur un corpus de combats enregistrés.

**Tick serveur autonome** cadencé sur `System.uptime` (fixe, ex. 20–30 Hz), découplé du rendu, via une boucle serveur dédiée émettant un `:mmo_tick`.

### Contrainte de conception : embarqué == dédié
Le mode serveur-headless doit être **strictement le même artefact** que le client (diff = config : rôle + endpoint), pour garantir la parité de version.

---

## 7. Patterns & points d'extension (le plan de qualité)

### Règle d'or : `register` / `add` / `alias` **uniquement**. Jamais éditer `001_Technical` / `003_Game processing` / les 312 scripts core.

| Pattern | Application | Point d'extension core |
|---|---|---|
| **Client-Server autoritatif** | Serveur = seule source de vérité (position, RNG combat, économie) | `SaveData` proxy + alias setters `Player` |
| **State Sync / Replication** | Snapshots serveur → clients ; deltas d'état | Queue drainée sur `:on_frame_update` + alias `pbUpdateSceneMap` |
| **Command** | Intentions client (`RegisterMove`, intention de mouvement) exécutées serveur | `pbRegisterMove/Target/Switch/Item` ; `:on_step_taken` |
| **Observer / EventBus** | Diffusion des changements ; hooks cycle de vie | `EventHandlers` (`:on_enter_map`, `:on_start_battle`, `:on_frame_update`) |
| **Repository** | Persistance serveur par sous-état (équipe/sac/boxes) | `SaveData.register` (backend redéfini) |
| **Interpolation / dead-reckoning** | Lissage du mouvement remote | rejeu de `Game_Character#update_move` |
| **Instance vs shared-world** | 1 process = 1 zone ; events instanciés par joueur | `:on_game_map_setup` / `PokemonMapFactory` |
| **Deterministic Replay (record-replay)** | Combat serveur enregistré, rejoué client (flux **filtré**) | `RecordedBattleModule` / `RecordedBattlePlaybackModule` |
| **Guarded Alias (Decorator)** | Wrapper de méthodes core sans réécriture | modèle `@__clauses__aliased` (`006_Battle_Clauses.rb`) |
| **Producer-Consumer** | Thread réseau → `Queue` → thread principal | `Thread.new` + `Queue` + `Mutex` |

### Points d'extension concrets
- **Chargement** : plugin versionné (`meta.txt` : Name/Version/Essentials/Requires) chargé **après** le core → tous les `register`/`unregister`/`alias` s'appliquent au boot.
- **Persistance/autorité** : `SaveData.register`/proxy, `SaveData.register_conversion`, `new_game_value`/`load_value` (identité serveur, hydratation login).
- **Boucle & tick** : `:on_frame_update` (drain) + alias `pbUpdateSceneMap` (boucles bloquantes) + `:mmo_tick` custom (tick serveur).
- **Mouvement** : `:on_step_taken`, `:on_player_change_direction`, `:on_leave_tile` (émission) ; `:on_new_spriteset_map` (remote sprites) ; alias `Scene_Map#transfer_player`, `Sprite_Character#update`.
- **État monde** : réenregistrer `:switches`/`:variables`/`:self_switches` avec des `new_game_value`/`load_value` renvoyant des **sous-classes MMO** de `Game_Switches`/`Game_Variables` qui override `[]`/`[]=` pour router *world* vs *player* — **sans éditer `004_*`**.
- **Combat** : `create_battle_scene` (Scene headless), `WildBattle.start_core`/`TrainerBattle.start_core` (aiguillage `NetworkBattle`), `Battle::AI::Handlers`, `:on_start_battle`/`:on_end_battle`, `add_battle_rule`.
- **Contenu** : `HandlerHash*.add`, patron `__orig__methode`, hooks compilateur `modify_pbs_file_contents_before_compiling`.
- **Social** : `MenuHandlers.add(:pause_menu, …)`.

### Garde-fous de qualité
- **Isolation des erreurs** : `runPlugins` fait `eval` puis `Kernel.exit! true` sur exception (`PluginManager.rb:635-640`) → un crash d'init réseau **tue le process** ; encapsuler l'init réseau dans un rescue local.
- **PROD non-`$DEBUG`** : `listAll`/`needCompiling?` retournent tôt hors debug (`005_PluginManager.rb:471,556`) → **pré-compiler le plugin dans `PluginScripts.rxdata`** au packaging.
- **Ordre de chargement** : forcer via `Requires`/`Optional` du `meta.txt` si le plugin aliase d'autres plugins.
- **Thread-safety** : muter l'état de jeu **uniquement** côté thread principal ; le GVL protège l'atomicité simple, **pas** les séquences multi-étapes (déplacement, échange, save).

---

## 8. Feuille de route par phases

### Phase 0 — Dérisquage runtime — ✅ **PARTIELLEMENT FAIT (réseau : GO)** — voir §1-bis
- ✅ **Réseau client** : `socket`/`TCPSocket`/`TCPServer` OK, loopback round-trip OK, `read_nonblock` OK, `Marshal`/`zlib`/`digest` OK ; thread réseau d'arrière-plan **viable dans la boucle réelle** (`recv_at=0.301s` quand le main cède le GVL). Stdlib minimale (json/net-http/openssl absents → Marshal + HTTPLite). **Verdict : GO.**
- ⏳ **Reste à dérisquer** : (a) **serveur headless Linux** — mkxp-z dummy-video existe-t-il/tourne-t-il sans GPU ? (non testé) ; (b) **session longue** — stabilité du thread réseau sur 30+ min traversant overworld/combat/menus, fermeture propre au soft-reset (F12) ; (c) mise en place d'un **environnement de dev complet** (assets) pour tester au-delà du boot.

### Phase 1 — Walking skeleton multijoueur (présence & mouvement) — ✅ **FAIT (2026-07-01)**
Le plus petit MMO visible : **voir un ami bouger**. Plugin `Plugins/PokeMMO/` (voir son `README.md`) : `NetClient` non-bloquant + `RelayServer` mono-thread `pump` ; émission position sur `:on_player_step_taken`/`:on_player_change_direction` (avec `:speed` pour glisser au bon rythme) ; `RemotePlayer < Game_Character` (`@through=true`, interpolation native) ; sprites via `Spriteset_Map#addUserSprite` sur `:on_new_spriteset_map` ; pump par frame via `:on_frame_update` + alias `pbUpdateSceneMap`. `ROLE=:auto` (héberge ou rejoint). **Zéro édition du core.** Validé visuellement : mouvement **fluide**, demi-tour et arrivée sur map corrects. Écarts vs plan initial (imposés par mkxp-z, voir §1-bis/§4) : **pump non-bloquant par frame** au lieu de thread+Queue ; relais **broadcast simple** (routage par zone côté client via filtre `map`, pas encore par process). Limites connues : pas d'autorité/anti-triche, `Marshal` non sûr, ghosts à la déconnexion, léger drift (buffer d'interpolation à venir), pas de réseau en combat.

### Phase 2 — Identité & autorité de persistance
Identité serveur (override `new_game_value` de `:player`) ; proxy `SaveData` **avec bootstrap/hydratation** (pas d'`unregister` sec) ; alias `Game.save/load` → backend ; validation serveur de `money=`/`coins=`/`badges=`. **Critère** : le `Game.rxdata` local ne fait plus foi ; l'état survit à un redémarrage serveur.

### Phase 3 — Transferts de zone & monde partagé
Alias `transfer_player` → join/leave ; filtrage remote par map ; partition `$game_switches/$game_variables` (world vs player, **écritures world sérialisées serveur**) ; `$game_self_switches` per-player ; modèle 1 process = 1 zone. **Critère** : navigation multi-map cohérente, events per-player corrects.

### Phase 4 — Combat record-replay (PvE serveur-arbitré)
**Audit RNG exhaustif** de `011_Battle/` d'abord ; Scene headless serveur ; **flux de rejeu filtré** (confidentialité) ; combat client sur **copies** ; choix réseau via `pbRegisterMove/…` avec **timeout** ; deltas idempotents post-ack ; handshake **code+contenu**. **Critère** : un combat est arbitré serveur et rejoué à l'identique, sans fuite ni triche mémoire.

### Phase 5 — PvP & échanges (avec correction, pas hardening)
PvP (deux flux distants, IA off) + timeout/forfait ; trades transaction 2-phases (verrou → validation → échange atomique + rollback + anti-double-dépense). **Critère** : combat/échange sûrs, robustes à la déconnexion.

### Phase 6 — Social, scaling & durcissement
Chat/liste via `MenuHandlers` ; persistance incrémentale ; migrations ; TLS (si CA) ou reverse-proxy ; **section capacité** (empreinte/zone, densité joueurs, coût 1-process-par-combat vs Fibers) ; durcissement anti-triche.

---

## 9. Décisions ouvertes à trancher

1. **Architecture des processus (structurante n°1)** : 1 process = 1 zone (singletons conservés) **ou** virtualisation par joueur (réécriture lourde) ?
2. **Serveur headless Linux** : mkxp-z dummy-video **ou** extraction Ruby MRI pur ? (impacte la parité d'artefact — voir §10-G10)
3. **Wire-format** : Marshal (MVP) → JSON/DB (cible) ? Recommandation : oui.
4. **Partition IDs `$game_switches/$game_variables`** (irréversible) : convention d'IDs réservés, table de config, ou annotation PBS ? Self-switches mondiaux (boss de guilde) ?
5. **Collision entre joueurs** : solides (griefing) vs traversables ?
6. **Rencontres sauvages** : per-joueur locales (simple) vs arbitrées serveur (anti-triche) ?
7. **Interpreters d'events** : client + validation serveur, ou serveur-autoritatif ? (`map_interpreter` mono-instance → cutscenes instanciées par joueur probablement)
8. **Granularité save serveur** : full-snapshot vs incrémental transactionnel ?
9. **Recompilation contenu côté hôte** : autorisée (compilateur headless) vs figée/pré-packagée ? Cohérence via checksom handshake ou download au login ?
10. **TLS/HTTPS** : bundle CA disponible sous mkxp-z ? Sinon TCP clair privé + terminaison reverse-proxy.
11. **Trades — verrou** : party seule ou boxes ? Annulation atomique sur déconnexion.
12. **Météo/écran** : synchronisée par zone ou client-only ?
13. **Parité de version sur fork upstream** : comment garantir client == serveur (code combat + Settings) après une MàJ amont ? (le déterminisme en dépend)

---

## 10. Revue adversariale & corrections

Une passe adversariale a challengé la première synthèse. Résultats intégrés ci-dessus ; traçabilité :

**Affirmations corrigées (haute sévérité)**
- **G1 — « thread réseau prouvé par PluginManager:291-298 »** : FAUX (thread d'erreur + `Kernel.exit!`). → Rétrogradé en hypothèse à dérisquer (§1.2, §4, Phase 0). Fallback `read_nonblock` promu chemin de repli.
- **G2 — « RecordedBattle = seed-déterminisme »** : FAUX, c'est du **record-replay**. Et `pbAIRandom`/`rand(2)`/`rand(3)` contournent `pbRandom`. → §5.3 réécrit (record-replay + audit RNG exhaustif prérequis).
- **G4 — ré-appropriation d'état en combat** : `Battler#hp=` mute `$player.party` **par référence** tout au long du combat (pas qu'à la fin). → Combat sur **copies**, deltas post-ack (§5.3.5).

**Risques sous-estimés (moyenne sévérité)**
- **G5 — déconnexion/atomicité = correction, pas hardening** : timeout de choix combat + trades transactionnels dès Phases 4-5 (§5.3.6, §5.4).
- **G6 — race conditions switches world-shared** : écritures sérialisées serveur ; client n'écrit jamais un switch mondial sans round-trip (§3-A).
- **G7 — scaling 1-process-par-zone/combat** : non chiffré → section capacité Phase 6 ; préférer Fibers pour les combats.
- **G8 — bootstrap `$player`** : `unregister(:player)` sec laisse `$player` nil → proxy + hydratation login (§5.6). Anti-triche = autorité serveur des mutations, pas « rxdata ne fait plus foi ».
- **G9 — Marshal non versionné / parité code** : handshake = hash **code+contenu** ; versionner le wire distinct du save (§5.6, §4).
- **G10 — headless mkxp-z non prouvé** : Phase 0 bloquante ; sinon extraction MRI casse la parité (§6).
- **G11 — confidentialité combat** : `RecordedBattle` dump party1 **et** party2 → flux de rejeu **filtré** à concevoir (dev à part entière, §5.3.4).

**Risque faible**
- **G12 — anti-triche mouvement** : au-delà de l'adjacence, ajouter rate-limiting temporel des pas + whitelist de warps ; la passabilité serveur exige le même `Game_Map` chargé (§5.1).

---

*Contrainte respectée : aucune édition du core — tout passe par PluginManager / SaveData / EventHandlers / MenuHandlers / HandlerHash / alias, préservant la mise à jour depuis l'upstream.*
