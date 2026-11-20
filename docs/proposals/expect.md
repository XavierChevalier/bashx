[Documentation](../README.md) › Propositions › API `expect`

# Écrire les tests avec `expect`

Statut : **proposition, pour validation**. Rien n'est livré dans `lib/`. Le
prototype [`expect/`](expect) charge `lib/bashx.sh` et ajoute les verbes
par-dessus : tous les exemples de cette page tournent.

```console
$ bash docs/proposals/expect/calc.test.sh      # l'exemple calculator réécrit
$ bash docs/proposals/expect/tour.test.sh      # valeurs, commandes, fichiers, mocks
$ bash docs/proposals/expect/failures.demo.sh  # à quoi ressemblent les échecs
```

## Le principe

Une phrase par vérification : **ce qu'on regarde**, **le matcher**, **la
valeur attendue**. `not` devant le matcher inverse n'importe lequel.

```bash
expect        "$(calc::add 2 3)"  to_be 5
expect_stdout                     to_contain "3 files"
expect_status                     not to_be 0
expect_file   "${dir}/app.conf"   to_exist
expect_mock   curl                to_have_been_called 2 times
```

Le fichier reste du bash ordinaire : `bash x.test.sh` marche, et le runner,
la couverture et `bashx mutate` ne voient aucune différence.

## Avant / après

Aujourd'hui (`examples/calculator/calc.test.sh`, extrait) :

```bash
test_should_refuse_a_division_by_zero() {
  local err rc=0
  err="$(calc::divide 1 0 2>&1)" || rc=$?
  test::assert_equals 1 "${rc}"
  test::assert_equals "calc: division by zero" "${err}"
}

test::init
test::run "should refuse a division by zero" test_should_refuse_a_division_by_zero
test::summary
```

Avec `expect` ([`expect/calc.test.sh`](expect/calc.test.sh)) :

```bash
test_should_refuse_a_division_by_zero() {
  run calc::divide 1 0
  expect_status to_be 1
  expect_stderr to_be "calc: division by zero"
  expect_stdout to_be_empty
}

test::main
```

---

## Référence

### Les sujets

| Verbe | Regarde |
| --- | --- |
| `expect <valeur> …` | une chaîne, souvent `"$(commande)"` |
| `run <commande> [args…]` | lance la commande sans arrêter le cas et garde son code, sa sortie et ses erreurs |
| `expect_status …` | le code de sortie du dernier `run` |
| `expect_stdout …` | la sortie standard du dernier `run` |
| `expect_stderr …` | la sortie d'erreur du dernier `run` |
| `expect_file <chemin> …` | un fichier : son existence ou son contenu |
| `expect_mock <nom> …` | les appels reçus par un mock |

`run` remplit aussi `$STATUS`, `$STDOUT` et `$STDERR` pour les cas
particuliers. `expect_status` sans `run` avant échoue avec un message
explicite.

### Les matchers de valeur

Valables après `expect`, `expect_stdout`, `expect_stderr`, `expect_status` et
`expect_file` (sur le contenu du fichier).

| Matcher | Vrai quand |
| --- | --- |
| `to_be <x>` | égal à `x` (diff affiché si plusieurs lignes) |
| `to_contain <x>` | contient `x` |
| `to_match <regex>` | correspond à la regex étendue |
| `to_start_with <x>` / `to_end_with <x>` | commence ou finit par `x` |
| `to_be_empty` | chaîne vide |
| `to_have_lines <n>` | `n` lignes |
| `to_be_greater_than <n>` / `to_be_less_than <n>` | comparaison entière stricte |
| `to_be_at_least <n>` / `to_be_at_most <n>` | comparaison entière large |

```bash
expect "${out}" to_contain "3 files"
expect "${out}" to_match '[0-9]+ms$'
expect "${out}" not to_contain "error"
expect "$(printf 'a\nb\nc')" to_have_lines 3
expect "${#out}" to_be_greater_than 10
```

### Les matchers de fichier

| Matcher | Vrai quand |
| --- | --- |
| `to_exist` | quelque chose existe au chemin |
| `to_be_a_directory` | c'est un dossier |
| `to_have_same_content_as <fichier>` | même contenu qu'un fichier de référence (« golden ») |
| tout matcher de valeur | appliqué au contenu ; échoue si le fichier n'existe pas |

```bash
expect_file "${dir}/app.conf" to_exist
expect_file "${dir}/app.conf" to_contain "port=8080"
expect_file "${dir}/report.md" to_have_same_content_as fixtures/report.md
expect_file "${dir}/cache" not to_exist
```

### Les mocks

`mock <nom>` remplace une commande ou une fonction jusqu'à la fin du cas et
enregistre chaque appel. Le remplaçant marche dans le shell du test (une
fonction) comme dans les sous-processus (un exécutable placé en tête du
`PATH`).

```bash
mock curl                           # ne fait rien, réussit
mock curl --exit 7                  # échoue avec 7
mock curl --stdout '{"ok":true}'    # répond ceci
mock git <<'EOF'                    # ou un corps bash ; "$@" = les arguments
[[ "$1" == rev-parse ]] && echo abc123
EOF
```

| Matcher | Vrai quand |
| --- | --- |
| `to_have_been_called` | au moins un appel |
| `to_have_been_called <n> times` | exactement `n` appels |
| `to_have_been_called_with <args…>` | un des appels contient ces arguments, dans cet ordre |
| `to_have_been_last_called_with <args…>` | le dernier appel les contient |

```bash
expect_mock curl to_have_been_called 3 times
expect_mock curl to_have_been_called_with --data "v1.4.0 is live"
expect_mock sleep not to_have_been_called
```

### Organisation d'un fichier

Repris de la première proposition, inchangé :

- chaque fonction `test_*` est un cas, et son nom donne la description ;
- `test::main` en dernière ligne les lance dans l'ordre du fichier. L'oublier
  fait échouer le fichier avec un message, pour ne pas laisser passer des cas
  jamais lancés ;
- `test::cases <fonction> <<'EOF'` lance la fonction une fois par ligne de la
  table ;
- `before_each`, `after_each` et `before_all` sont appelées si elles existent.
  `after_each` tourne même quand le cas échoue ;
- la sortie d'un cas n'est affichée que s'il échoue.

```bash
test_should_tell_the_sign_of_a_number() {
  expect "$(calc::sign "$1")" to_be "$2"
}
test::cases test_should_tell_the_sign_of_a_number <<'EOF'
-4  negative
0   zero
9   positive
EOF
```

---

## Les échecs

Chaque échec donne la ligne et son texte, ce qui était attendu, ce qui a été
obtenu, et le contexte utile : la commande lancée par `run`, la liste des
appels d'un mock, un diff pour le texte sur plusieurs lignes, la chaîne
d'appel quand l'`expect` est dans un helper. Extrait de
`bash docs/proposals/expect/failures.demo.sh` :

```text
│  ✗ a value (13ms)
│    ✗ failures.demo.sh:8  expect "$(calc::add 2 3)" to_be 6
│      expected value to be: 6
│      but it was: 5
│  ✗ a multiline output (15ms)
│    ✗ failures.demo.sh:12  expect "$(printf 'a\nb\nc')" to_be $'a\nB\nc'
│      expected value to be:
│      @@ -1,3 +1,3 @@
│       a
│      -B
│      +b
│       c
│  ✗ a command (14ms)
│    ✗ failures.demo.sh:21  expect_status to_be 0
│      after: run calc::divide 1 0
│      expected status to be: 0
│      but it was: 1
│  ✗ a mock (27ms)
│    ✗ failures.demo.sh:27  expect_mock curl to_have_been_called_with --data bye
│      expected curl to have been called with --data bye
│      calls (1):
│        --data hello https://example.org
│  ✗ a helper under if (12ms)
│    ✗ failures.demo.sh:37  is_even() { expect "$(($1 % 2))" to_be 0; }
│      called from failures.demo.sh:39 (test_a_helper_under_if)
│      expected value to be: 0
│      but it was: 1
```

Un `expect` raté termine le cas **partout**, même sous `if`, `||`, `&&`, `!`
ou dans un `$( )`. Il ne compte pas sur errexit : il marque le cas en échec
et sort du sous-shell du cas. Le dernier exemple ci-dessus en est la preuve :
le helper est appelé sous `if`.

---

## De la v1 à `expect`

| v1 | `expect` |
| --- | --- |
| `test::assert_equals <attendu> <obtenu>` | `expect <obtenu> to_be <attendu>` |
| `test::assert_not_equals <x> <obtenu>` | `expect <obtenu> not to_be <x>` |
| `test::assert_contains <obtenu> <x>` | `expect <obtenu> to_contain <x>` |
| `test::assert_not_contains <obtenu> <x>` | `expect <obtenu> not to_contain <x>` |
| `test::assert_matches <obtenu> <regex>` | `expect <obtenu> to_match <regex>` |
| `test::assert_exit_code <n> cmd…` | `run cmd…` puis `expect_status to_be <n>` |
| `test::assert_file_exists <f>` | `expect_file <f> to_exist` |
| `test::assert_file_not_exists <f>` | `expect_file <f> not to_exist` |
| `test::assert_file_contains <f> <x>` | `expect_file <f> to_contain <x>` |
| `test::assert_file_not_contains <f> <x>` | `expect_file <f> not to_contain <x>` |
| `test::assert_file_equals <f> <x ou golden>` | `expect_file <f> to_be <x>` ou `to_have_same_content_as <golden>` |
| `out="$(cmd 2>&1)" \|\| rc=$?` | `run cmd` |
| `PATH="$(test::mock_command curl '…'):$PATH"` + log à la main | `mock curl …` + `expect_mock curl …` |
| `test::init` / `test::run` / `test::summary` | `test::main` |

Les fonctions v1 restent et gardent leur comportement : les fichiers
existants tournent sans changement. Une migration automatique
(`bashx migrate`) est possible pour la table ci-dessus, qui est mécanique.

---

## À décider

1. **`run`** est le nom de bats et de cette option C. Mais un script testé qui
   définit sa propre fonction `run()` (c'est courant) écrase celle de bashx
   sans bruit, puisque le code testé est sourcé après `bashx.sh`. Je propose
   de garder `run`, et que `test::main` refuse de démarrer avec un message si
   `run` n'est plus celui de bashx. Alternative : `run_cmd` ou `when`.
2. **`to_be` contre `to_equal`** : un seul des deux suffit. Je garde `to_be`,
   plus court.
3. **Préfixe** : des noms courts (`expect`, `mock`) dans l'espace global,
   avec un alias `test::expect`, `test::mock`… pour le cas où le code testé
   utilise déjà ces noms ?
4. **Sortie masquée pour les cas réussis** : c'est un changement de
   comportement, donc une version 0.2.0. D'accord ?
5. **Matchers supplémentaires** à ajouter tout de suite ou à la demande :
   `to_be_one_of`, `to_have_been_called_with_exactly`, `to_be_executable`,
   `to_have_line <n> <texte>`.

## Plan de livraison

Une fois les choix faits, une PR par étape, chacune avec ses tests et la
doc (`api.md`, `writing-tests.md`) :

1. Le moteur : `expect`, les matchers de valeur, `not`, les messages
   d'échec, et l'échec qui ne dépend pas d'errexit.
2. `run`, `expect_status`, `expect_stdout`, `expect_stderr`.
3. `expect_file`.
4. `mock` et `expect_mock`.
5. `test_*`, `test::main` et son filet, `test::cases`, les hooks.
6. La sortie masquée, et `--filter` / `-v` dans le runner.
7. La migration des tests de bashx et de `examples/calculator`, et
   éventuellement `bashx migrate`.

## Limites du prototype

C'est un prototype : il redéfinit `test::run` et le trap EXIT par-dessus la
v1 au lieu de les modifier, et il n'a pas de tests à lui. Ses deux fichiers
`*.test.sh` tournent dans `bashx test` (donc dans la CI : bash 5.0, 5.1, 5.2
et macOS), et il passe shellcheck `-S warning`.
