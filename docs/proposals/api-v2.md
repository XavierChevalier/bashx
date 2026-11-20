[Documentation](../README.md) › Propositions › API v2

# Réimaginer l'écriture des tests

Statut : **proposition**, à discuter. Rien n'est livré. Un prototype
fonctionnel accompagne ce document : [`spike/`](spike) (`next.sh` charge
`lib/bashx.sh` et ajoute les nouveaux verbes par-dessus).

```console
$ bash docs/proposals/spike/calc.test.sh       # l'exemple calculator réécrit
$ bash docs/proposals/spike/failures.demo.sh   # à quoi ressemblent les échecs
```

## En une image

Aujourd'hui (`examples/calculator/calc.test.sh`, extrait) :

```bash
source "${BASHX_LIB:-$(bashx lib)}/bashx.sh"
source "$(dirname "${BASH_SOURCE[0]}")/calc.sh"

test_should_refuse_a_division_by_zero() {
  local err rc=0
  err="$(calc::divide 1 0 2>&1)" || rc=$?
  test::assert_equals 1 "${rc}"
  test::assert_equals "calc: division by zero" "${err}"
}

test_should_tell_the_sign_of_a_number() {
  test::assert_equals negative "$(calc::sign -4)"
  test::assert_equals zero "$(calc::sign 0)"
  test::assert_equals positive "$(calc::sign 9)"
}

test::init
test::run "should refuse a division by zero" test_should_refuse_a_division_by_zero
test::run "should tell the sign of a number" test_should_tell_the_sign_of_a_number
test::summary
```

Proposé ([`spike/calc.test.sh`](spike/calc.test.sh)) :

```bash
source "${BASHX_LIB:-$(bashx lib)}/bashx.sh"
source "$(dirname "${BASH_SOURCE[0]}")/calc.sh"

test_should_refuse_a_division_by_zero() {
  capture calc::divide 1 0
  assert "${STATUS}" == 1
  assert "${STDERR}" == "calc: division by zero"
  assert "${STDOUT}" empty
}

test_should_tell_the_sign_of_a_number() {
  assert "$(calc::sign "$1")" == "$2"
}
test::cases test_should_tell_the_sign_of_a_number <<'EOF'
-4  negative
0   zero
9   positive
EOF
```

Plus de `test::init`, de `test::run`, de `test::summary` ; stdout et stderr
séparés ; un cas par ligne de table ; et quand ça casse :

```text
│  ✗ should add two integers (9ms)
│    ✗ calc.test.sh:7  assert "$(calc::add 2 3)" == 5
│      expected: 5
│      actual:   -1
```

Le fichier reste un script bash ordinaire : `bash calc.test.sh` marche, le
protocole du runner (fichier de résultat, code de sortie) ne change pas, donc
`bashx test`, la couverture et `bashx mutate` ne voient aucune différence.

---

## Ce qui gêne aujourd'hui

Constats tirés de l'API actuelle et des tests de bashx lui-même.

| # | Constat | Conséquence |
| --- | --- | --- |
| 1 | Chaque cas est nommé **trois fois** : la fonction `test_should_x`, la description `"should x"`, la ligne `test::run`. | Bruit, copier-coller, et un cas écrit mais jamais enregistré passe inaperçu. |
| 2 | L'ordre des arguments change d'une assertion à l'autre : `assert_equals <attendu> <obtenu>`, `assert_contains <obtenu> <aiguille>`, `assert_matches <obtenu> <regex>`. | Il faut relire la doc à chaque fois ; une inversion donne un message d'échec trompeur. |
| 3 | Tester une erreur demande `local err rc=0; err="$(cmd 2>&1)" \|\| rc=$?` et la règle « jamais `cmd; rc=$?` ». | Le cas le plus courant (code + message) est le plus verbeux, et stdout/stderr sont mélangés. |
| 4 | Une assertion qui échoue fait `return 1` et compte sur errexit. Or errexit est coupé sous `if`, `\|\|`, `&&`, `!` et dans `$( )`. | Une assertion dans un helper appelé par `if helper` est ignorée. Les tests de bashx écrivent `\|\| return 1` **163 fois** pour s'en protéger, alors que la doc dit que c'est inutile. |
| 5 | Un échec dit *quoi* mais pas *où* : pas de fichier ni de ligne, pas de diff pour les sorties multi-lignes. | Avec trois `assert_equals` dans un cas, il faut deviner lequel. |
| 6 | Un mock = `test::mock_command` + `PATH=…` à la main + un fichier de log à la main pour vérifier les appels. Il ne remplace pas une *fonction* appelée dans le même shell. | Chaque test de mock réécrit la même plomberie. |
| 7 | Pas de `setup` / `teardown`. | Préparation copiée en tête de chaque cas ; pas de nettoyage garanti en cas d'échec. |
| 8 | Ce que le cas affiche part directement dans la sortie, qu'il réussisse ou non. | Une suite verte est bavarde ; les traces de debug restent. |
| 9 | Pas moyen de lancer un seul cas. | On commente des `test::run` pour isoler un échec. |

---

## Les propositions

Classées par rapport bénéfice / coût. Chacune est indépendante et livrable
seule. ✅ = vérifiée dans le prototype.

### 1. Découverte des cas : la fonction suffit ✅

Toute fonction `test_*` est un cas. Sa description vient de son nom
(`test_should_add_two_integers` → « should add two integers »), l'ordre
d'exécution est l'ordre de définition dans le fichier (`shopt -s extdebug` +
`declare -F` donnent la ligne de chaque fonction).

```bash
source "${BASHX_LIB:-$(bashx lib)}/bashx.sh"
source ./backup.sh

test_should_keep_the_last_three_archives() {
  ...
}
```

**Comment.** Le trap EXIT que `bashx.sh` pose déjà lance, à la fin du
fichier, chaque `test_*` qui n'a pas déjà été lancé, puis le résumé. Il ne le
fait que si le fichier s'est terminé normalement (status 0) : une erreur au
`source` n'exécute pas de tests à moitié chargés.

**Compatibilité.** `test::init` devient implicite (appelé par le premier
`test::run`), `test::run` explicite reste possible pour donner une
description libre, et une fonction déjà lancée explicitement n'est pas
relancée. Les fichiers v1 tournent sans changement.

**Alternative écartée :** une syntaxe `@test "description" { … }` à la bats.
Elle exige de prétraiter le fichier : `bash fichier.test.sh` ne marche plus,
et les numéros de ligne de la couverture et des mutants ne correspondent plus
au fichier.

### 2. `assert <obtenu> <opérateur> [<attendu>]` : une seule assertion ✅

Toujours dans le même ordre, lisible comme un `[[ ]]` :

```bash
assert "$(calc::add 2 3)" == 5
assert "${out}" != ""
assert "${out}" contains "3 files saved"
assert "${out}" !contains "password"
assert "${version}" matches '^[0-9]+\.[0-9]+$'
assert "${out}" starts_with "Usage:"
assert "${out}" empty
assert "$(wc -l <log)" -ge 3
assert "${dir}/app.conf" is_file
assert "${dir}/cache" !exists
assert "${dir}/app.conf" has "port=8080"
assert "${dir}/report.md" same_as fixtures/report.md   # fichier « golden »
```

Un seul nom à retenir, l'opérateur se lit dans le message d'échec, et ajouter
un opérateur ne crée pas une fonction de plus. Les onze `test::assert_*`
restent, comme alias documentés « v1 ».

**Pourquoi pas `expect(x).toBe(y)` à la Jest :** bash n'a pas d'objets ; les
imitations (`expect "$x" | to_equal 5`, `expect "$x"; to_equal 5`) cassent
errexit ou dépendent d'un état global caché. La forme infixe ne triche pas.

### 3. Une assertion ratée termine le cas, partout ✅

Au lieu de `return 1`, une assertion ratée écrit un drapeau dans le dossier
du cas et fait `exit 1` du sous-shell du cas. Conséquences :

- elle échoue même appelée sous `if`, `||`, `&&`, `!` : fin des
  `|| return 1` (163 dans `lib/*.test.sh` à supprimer) ;
- appelée dans un `$( )`, elle ne sort que de la substitution, mais le
  drapeau marque quand même le cas en échec ;
- le piège n°1 de la page « Writing tests » disparaît pour les assertions (il
  reste pour le code testé, ce qui est son vrai sujet).

### 4. Les échecs disent où, et montrent un diff ✅

`BASH_SOURCE` / `BASH_LINENO` donnent la ligne de l'assertion ; on affiche
aussi le texte de cette ligne, la chaîne d'appel quand l'assertion est dans
un helper, et un `diff -u` quand l'attendu ou l'obtenu fait plusieurs lignes :

```text
│  ✗ assert under if still fails (7ms)
│    ✗ failures.demo.sh:8  helper() { assert "$1" == even; }
│      called from failures.demo.sh:16 (test_assert_under_if_still_fails)
│      expected: even
│      actual:   odd
│  ✗ multiline diff (9ms)
│    ✗ failures.demo.sh:13  assert $'a\nb\nc' == $'a\nB\nc'
│      @@ -1,3 +1,3 @@
│       a
│      -B
│      +b
│       c
```

Coût : quelques lignes dans `test::_fail`. C'est la proposition la plus
rentable après la 1.

### 5. `capture` : code, stdout et stderr sans piège ✅

```bash
capture backup::run /nope
assert "${STATUS}" == 1
assert "${STDERR}" contains "no such file: /nope"
assert "${STDOUT}" empty
```

`capture` lance la commande dans un sous-shell, stdin fermé, et remplit
`STATUS`, `STDOUT`, `STDERR` (fins de ligne retirées comme avec `$( )`). Le
`set +e` / `set -e` est fait à l'intérieur : impossible d'oublier le
`|| rc=$?`.

- **Majuscules, exprès** : shellcheck (lancé en CI sur tous les `.sh`) signale
  `status` en minuscules comme « jamais assigné » (SC2154) ; il ne le fait pas
  pour les majuscules. Constaté sur le prototype.
- **Pas de `$output` entrelacé** : séparer stdout et stderr *et* garder
  l'ordre d'écriture demande des `tee` en arrière-plan qui rendent `capture`
  lent et fragile. Pour l'entrelacé, `capture bash -c '… 2>&1'` ou
  `$(cmd 2>&1)` suffisent.
- **Nom** : `run` (bats) est tentant mais beaucoup de scripts testés
  définissent leur propre `run()`, qui écraserait celui de bashx sans bruit.

### 6. `mock` : remplace, enregistre, s'efface avec le cas ✅

```bash
test_should_retry_when_the_api_is_down() {
  mock curl --exit 7
  mock sleep
  api::fetch_with_retry 3 || true
  assert "$(mock::count curl)" == 3
}

test_should_post_the_message() {
  mock curl --stdout '{"ok":true}'
  deploy::notify "done"
  assert "$(mock::calls curl)" contains "--data done"
}

test_should_read_the_commit() {
  mock git <<'EOF'
[[ "$1" == rev-parse ]] && echo abc123
EOF
  assert "$(release::version)" == "0.1.0+abc123"
}
```

Un `mock <nom>` pose **deux** remplaçants, qui écrivent dans le même journal
d'appels :

- une **fonction** `<nom>` : prioritaire sur le `PATH` dans le shell courant,
  donc elle remplace aussi une fonction du code testé (`mock api::fetch`) ;
- un **exécutable** dans un `bin/` propre au cas, placé en tête du `PATH` par
  `test::run` : il couvre les sous-processus (`bash script.sh`, `xargs`,
  `env`…).

Le comportement se donne par options (`--exit`, `--stdout`, `--stderr`) ou par
un corps bash sur stdin. Tout vit dans le dossier du cas : rien à défaire.
`test::mock_command` reste pour la compatibilité.

À ajouter ensuite si le besoin se confirme : `mock::calls <nom> <n>` (le
n-ième appel), `--once` (réponses successives), et un `spy` qui enregistre
puis appelle le vrai.

### 7. Tables de cas ✅

```bash
test_should_truncate() {
  assert "$(strings::truncate "$1" "$2")" == "$3"
}
test::cases test_should_truncate <<'EOF'
hello           10  hello
"hello world"   6   hello…
""              3   ""
EOF
```

Chaque ligne devient un cas, nommé d'après la fonction et ses arguments
(« should truncate [hello world 6 hello…] »). Les mots suivent le quoting du
shell ; les lignes vides et `#` sont ignorées. `test::cases` n'exécute rien :
il attache la table à la fonction, que la découverte (1) lance à sa place
dans l'ordre du fichier.

### 8. `before_each`, `after_each`, `before_all` ✅

```bash
before_each() {
  WORK="$(test::tmp_dir)"
  cp -r fixtures/project "${WORK}"
  cd "${WORK}/project"
}
after_each() {
  docker rm -f bashx-test >/dev/null 2>&1 || true
}
```

Définies dans le fichier, elles sont appelées automatiquement :
`before_each` / `after_each` dans le sous-shell du cas (donc ce qu'elles
posent est visible du cas et disparaît avec lui), `after_each` via un trap
EXIT, donc **même quand le cas échoue** ; `before_all` une fois, dans le
shell du fichier, à l'init.

**Nom** : `setup` / `teardown` (bats) sont des noms que des scripts
d'installation testés utilisent eux-mêmes ; `before_each` l'est rarement.

### 9. Sortie des cas : silencieuse sauf en cas d'échec ✅

Ce qu'un cas écrit (stdout et stderr, assertions comprises) est mis de côté et
affiché sous le cas seulement s'il échoue ou est sauté. `BASHX_VERBOSE=1`
(futur `bashx test -v`) l'affiche toujours. Effet de bord utile : stdin des
cas est `/dev/null`, donc un cas ne peut plus avaler l'entrée du fichier (bug
rencontré pendant le prototype).

### 10. Lancer un seul cas ✅

`BASHX_FILTER=retry bash api.test.sh` (futur `bashx test --filter=retry`) ne
lance que les cas dont la description contient le texte. Les autres ne sont
pas comptés (ni réussis, ni sautés).

### 11. Snapshots (non prototypé)

```bash
capture mytool --help
assert_snapshot "${STDOUT}"
```

Première exécution : écrit `__snapshots__/<fichier>/<cas>.txt`. Ensuite :
compare, avec le diff de (4). `bashx test --update-snapshots` réécrit. Très
utile pour les CLI dont la sortie est longue ; à faire après le reste, car
cela touche le runner et la doc de CI (snapshots à committer).

---

## Écarté

| Idée | Pourquoi non |
| --- | --- |
| Prétraitement `@test "…" { }` (bats) | Le fichier ne serait plus du bash : plus de `bash x.test.sh`, lignes décalées pour la couverture et les mutants. |
| `describe` / `it` imbriqués | Des descriptions longues en chaîne de caractères, des blocs qui ne peuvent pas être des fonctions bash sans `eval`. Le nom de fonction + un fichier par sujet suffisent. |
| Assertions « molles » (continuer après un échec) par défaut | Contraire à l'isolation par errexit qui fait la force de bashx ; une première erreur entraîne souvent les suivantes. Possible plus tard en option (`assert … --soft`). |
| Verbes courts seulement (`assert`, `capture`, `mock` sans `test::`) | Gardés, mais chacun a aussi son nom long (`test::assert`, `test::capture`) : si le code testé définit déjà `assert`, le nom long reste disponible. |

---

## Compatibilité et migration

- Toutes les fonctions v1 restent et gardent leur comportement, sauf deux
  changements visibles, à annoncer dans le changelog :
  - la sortie d'un cas réussi n'est plus affichée (9) ;
  - stdin d'un cas est `/dev/null`.
- Le protocole runner (`BASHX_RESULT_FILE`, code de sortie, statut 77) ne
  change pas : `bashx test`, `--coverage`, `bashx mutate`, les rapports
  JUnit/JSON fonctionnent tels quels.
- Migration des tests de bashx et de l'exemple calculator dans la même série :
  ils servent de démonstration et de test de non-régression.
- Version : tout est additif sauf (9) → **0.2.0**.

## Plan de livraison

Une PR par ligne, chacune avec ses tests et sa doc (`api.md`,
`writing-tests.md`) :

1. Localisation + diff des échecs (4), assertion qui termine le cas (3).
2. `assert` (2) ; alias v1 conservés.
3. Découverte + init/summary implicites (1).
4. `capture` (5).
5. `mock` (6) en remplacement documenté de `mock_command`.
6. Hooks (8), tables (7).
7. Sortie silencieuse + `-v`, `--filter` dans le runner (9, 10).
8. Migration des tests de bashx et de `examples/calculator`.
9. Snapshots (11), si le besoin est confirmé.

## Questions ouvertes

1. **Verbes courts** (`assert`, `capture`, `mock`) dans l'espace global, ou
   seulement les noms `test::` ? Je recommande les deux, comme dans le
   prototype.
2. **Variables de `capture`** en majuscules (`STATUS`) pour shellcheck, ou en
   minuscules comme bats (`status`) avec un `# shellcheck disable` à
   documenter ?
3. **Lancement implicite par le trap EXIT** : pratique mais « magique ».
   Alternative explicite : une dernière ligne `test::main`. Je recommande
   l'implicite, `test::main` restant disponible pour qui le préfère.
4. **Sortie silencieuse par défaut** (9) : changement de comportement ; OK
   pour 0.2.0 ?

## Limites du prototype

Le prototype n'est pas le code à livrer : il redéfinit `test::run` et le trap
EXIT par-dessus la v1 au lieu de les modifier, n'a pas ses propres tests et
n'a été essayé qu'avec la version de bash de ce conteneur (pas 5.0/5.1 ni
macOS, que la CI couvre). Il passe shellcheck `-S warning` et tourne sous
`bashx test` (son `calc.test.sh` est découvert et passe).
