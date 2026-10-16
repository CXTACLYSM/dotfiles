# dotfiles

Терминальное окружение для Go-разработки на macOS: zsh, tmux, Neovim,
iTerm2 и git-инструменты. Всё ПО ставится из Homebrew по `Brewfile`; в
репозитории только конфиги и скрипты.

## Быстрый старт

```sh
xcode-select --install            # git и компилятор C, если их ещё нет
# Homebrew: https://brew.sh

git clone <url-репозитория> ~/workspace/dotfiles   # путь любой
cd ~/workspace/dotfiles

./install.sh --dry-run            # что будет сделано; конфиги не меняются
./install.sh                      # установка
./install.sh --check              # проверка: ✓ / ✗ по каждому пункту
exec zsh
```

`install.sh` можно запускать повторно: сделанное пропускается. Всё, что
заменяется, сначала переносится в `~/.local/state/dotfiles/backup-<время>/`.
`sudo` не используется. Флаги: `--no-brew` (пакеты уже стоят),
`--skip-verify` (без проверок nvim).

## Что куда

| В репозитории | На машине |
|---|---|
| весь репозиторий | `~/.config/dotfiles` — ссылка, через неё ссылаются конфиги |
| `Brewfile` | `brew bundle --no-upgrade` |
| `zsh/zshrc.zsh` | строка `source ~/.config/dotfiles/zsh/zshrc.zsh` в конце `~/.zshrc` |
| `tmux/tmux.conf` | строка `source-file ~/.config/dotfiles/tmux/tmux.conf` в `~/.tmux.conf` |
| `tmux/dev`, `devlog`, `projects` | ссылки в `~/.local/bin` |
| `git/gitconfig` | `include.path` в `~/.gitconfig` |
| `git/lazygit.yml` | ссылка `~/Library/Application Support/lazygit/config.yml` |
| `iterm/go-backend.json` | копия в `~/Library/Application Support/iTerm2/DynamicProfiles/` |
| `nvim/` | ссылка `~/.config/nvim` |
| `nvim/tools/goindex` | собирается в `~/.local/share/nvim/change-tree/go-change-index` |

В `~/.zshrc`, `~/.tmux.conf` и `~/.gitconfig` добавляется по одной строке;
остальное их содержимое не трогается.

## Что скачивается из сети

- пакеты Homebrew из `Brewfile`;
- 8 плагинов Neovim — `git clone` с GitHub строго по коммитам из
  `nvim/nvim-pack-lock.json`;
- исходники парсеров Tree-sitter, которые собирает nvim-treesitter: Go
  (`go`, `gomod`, `gosum`, `gowork`), SQL (`sql`) и теги в комментариях
  (`comment`).

AST-хелпер дерева правок собирается локально из `nvim/tools/goindex`: только
стандартная библиотека Go, `GOPROXY=off`, `GOTOOLCHAIN=local`.

Во время работы плагины и парсеры в сеть не ходят: только при установке и
при обновлении вручную. `install.sh` выключает статистику Homebrew
(`brew analytics off`) и телеметрию Go (`go telemetry off`). `~/go/bin` и
`~/.local/bin` стоят в конце `PATH`: поставленное через `go install` не
подменит одноимённую системную программу.

## Локальные настройки (не в репозитории)

- `~/.zshrc` **выше** строки dotfiles: прокси, `GOPRIVATE` / `GOPROXY` /
  `GONOSUMDB`, `DEV_PROJECT_ROOTS`, свои алиасы. Строка dotfiles должна
  оставаться последней: внутри неё в самом конце подключается
  zsh-syntax-highlighting.
- `~/.gitconfig`: `user.name`, `user.email`.
- `~/.config/dev/<проект>.zsh` — раскладки `dev` для своих проектов.

## Вручную после установки

`install.sh` в конце печатает то, что осталось:

- **git:** `git config --global user.name "…"`, `git config --global user.email "…"`.
- **delve** (отладка в nvim) требует режима разработчика macOS:
  `sudo DevToolsSecurity -enable && sudo dscl . append /Groups/_developer GroupMembership $(whoami)`,
  после этого — новый вход в систему.
- **iTerm2**, если он был запущен во время установки: Settings → Profiles →
  Go Backend → Other Actions… → Set as Default.
- **Перечитать конфиги:** `exec zsh`; в уже запущенном tmux —
  `tmux source-file ~/.tmux.conf`.

## Обновление и откат

```sh
cd ~/.config/dotfiles && git pull && ./install.sh
```

Откат: удалить строки после `# dotfiles` в `~/.zshrc` и `~/.tmux.conf`,
`git config --global --unset include.path '~/.config/dotfiles/git/gitconfig'`,
удалить ссылки из таблицы выше и вернуть файлы из
`~/.local/state/dotfiles/backup-*`.

---

## Шпаргалка

### tmux (prefix — `Ctrl-b`)

| Клавиши | Действие |
|---|---|
| `prefix f` | проекты: открытые сессии и каталоги; Enter — перейти или создать через `dev`, Ctrl-X — закрыть сессию |
| `prefix g` | lazygit в каталоге текущей панели |
| `prefix i` | документация проекта: README и `docs/`, контракты (`.proto`, OpenAPI), Go-пакеты (`go doc`), шпаргалка клавиш; Enter — читать целиком, `q` — назад к списку, Esc — закрыть |
| `prefix t` | дедлайны: обзор с прогрессом; цифра — удалить |
| `prefix s` | дерево сессий и окон |
| `prefix 1..9` | окно по номеру |
| `prefix c` / `\|` / `-` | новое окно / split вбок / split вниз — в каталоге панели |
| `prefix h j k l` | между панелями |
| `prefix z` | развернуть панель (в статус-баре — `zoom`) |
| `prefix [` | copy mode: `v` выделить, `y` скопировать в системный буфер |
| `prefix r` | перечитать конфиг |
| `prefix d` | отключиться; процессы продолжают работать |

Статус-бар: имя сессии жёлтое — нажат prefix, сиреневое — copy mode. У
фоновых окон: `●` команда идёт, `✓` / `✗` — результат (гаснет при входе в
окно). Команда дольше 10 с звонит bell. Справа: `⚠` — проблема окружения
проекта (`dev -c`), плашки дедлайнов, время.

### dev — сессия проекта

```sh
dev                    # сессия текущего проекта (корень: go.work → go.mod → .git)
dev backend frontend   # монорепо: окна backend/editor, backend/tests, …
dev -b TASK-123        # сессия под ветку в отдельном git worktree
dev -k                 # закрыть сессию (чистый worktree удаляется)
dev -c                 # проверка: docker, compose, порты, Go toolchain, GOPROXY
```

Окна по умолчанию: `editor` (`nvim .`), `server` (набрано `devlog make run`),
`tests` (сюда отправляет тесты `Space gt`), `infra` (набрано `make up`),
`shell` (`DEV_SHELL=0` — без него). Своя раскладка —
`~/.config/dev/<проект>.zsh`:

```zsh
win editor -x 'nvim .'               # -x — запустить сразу
win server    'devlog make run'      # без -x — набрано, ждёт Enter
pane          'devlog make worker'   # панель под предыдущей
win tests                            # пусто: сюда шлёт тесты Space gt
win infra  -x 'make up'
```

`devlog команда` показывает JSON-логи (slog, zap) одной строкой на запись и
сохраняет сырой вывод в `~/.cache/dev/<сессия>/`. Где искать проекты для
`prefix f` — `DEV_PROJECT_ROOTS` (по умолчанию `~/workspace ~/Projects`).

### Neovim (leader — `Space`)

| Клавиши | Действие |
|---|---|
| `Space f` / `Space F` | файлы проекта / включая игнорируемые |
| `Space .` | файлы текущего пакета |
| `Space /` | поиск текста по проекту |
| `Space *` | слово под курсором по проекту, целым словом; в Visual — выделенное |
| `Space b` | открытые буферы |
| `Space ss` / `Space sS` | символы файла / живой поиск символов проекта |
| `K`, `Ctrl-]`, `Ctrl-o` | документация, определение, назад |
| `gp` / `gP` / `gI` | **подсмотреть** определение / тип / реализацию во всплывающем окне, не уходя с места: объявление целиком с doc-комментарием (ниже) |
| `gri` / `grt` | реализации интерфейса / определение типа |
| `Space ga` | файл ↔ его тест; нового `_test.go` — заготовка с `package` и `testing` |
| `grr` | ссылки и реализации интерфейса с превью |
| `[r` / `]r` | использования символа в файле |
| `gre` | граф выходов функции (`return`, `panic`, …) |
| `grc` / `gro` | кто вызывает / что вызывает символ |
| `Space ct` | **дерево правок**: что изменено относительно HEAD и что от этого зависит |
| `Space cT` | строить дерево правок после каждого `:w` (по умолчанию выключено) |
| `grn` / `Space rn` | переименование через gopls по всему проекту: затронутые файлы сохраняются, места — в quickfix (`]q`); на строке `package x` — пакет вместе с папкой и импортами; локальная переменная — только в своей области видимости |
| `Space gf` / `Space gi` | форматирование / импорты |
| `Space gb` | `go build` + `go vet` в quickfix |
| `Space gt` / `Space gT` | тест под курсором / все тесты — в окно `tests` tmux |
| `Space q`, `]q` / `[q` | диагностики проекта в quickfix и переход по ним |
| `Space d` | диагностика под курсором целиком; коротко она и так видна в конце строки, на которой курсор |
| `Space ih` | inlay hints |
| `Space cf` | к началу текущей функции |
| `Space st`, `]t` / `[t` | все TODO / FIXME / HACK / XXX / BUG проекта с превью; следующий / предыдущий в файле |
| `Space sQ` | **SQL-запросы проекта** по таблицам (ниже) |
| `Space m` | в markdown: оформленный вид ↔ сырой текст (ниже) |
| `zM` / `zR` / `za` | свернуть файл до оглавления (одни объявления) / развернуть / свернуть-развернуть под курсором |
| `gra` | действия gopls под курсором или для выделения (ниже) |
| `af` `if` `ac` `ic` `aa` `ia` | текстовые объекты: функция, тип, аргумент |
| `]f` `[f` `]a` `[a` | к следующей / предыдущей функции, параметру |
| `]c` / `[c` | git-hunks; `Space hs` `hr` `hp` `hb` `hd` — stage, reset, preview, blame, diff |
| `Space tt` `tp` `tb` `tc` `tn` `ti` `to` `tx` | отладка delve: тест, main, breakpoint, continue, шаги, стоп |
| `Ctrl-Space` | дополнение вручную |
| `jk` | выход из Insert |

**Подсмотр (`gp` / `gP` / `gI`).** Окно появляется рядом с курсором и
закрывается, как только курсор сдвинется. Та же клавиша ещё раз — войти в
окно; внутри `gp` / `gP` / `gI` на любом имени показывают следующий уровень
в том же окне, `Backspace` — назад, так цепочка «хендлер → сервис →
репозиторий» читается, не уходя с места. Enter открывает строку под
курсором (`Ctrl-o` вернёт), `q` закрывает. `gI` на вызове через интерфейс
показывает реализацию: моки и тестовые типы откладываются, если настоящая
реализация одна (в заголовке — сколько отложено), несколько настоящих —
список с превью.

**SQL (`Space sQ`).** Все запросы проекта в одном дереве, справа — код
выбранного:

- строки Go, которые начинаются с запроса (`SELECT … FROM`, `INSERT INTO`,
  `UPDATE x SET`, `DELETE FROM`, `WITH x AS (`, DDL); склейки через `+` и
  строковые константы пакета подставляются;
- цепочки squirrel: `sq.Select(…).From("orders o").Join(…)`,
  `sq.Insert(ordersTable)`, `psql.Update(…)`;
- `.sql`: миграции goose (`↓` — секция Down) и запросы sqlc (`-- name:`).

Группы — таблицы (запрос с JOIN попадает в каждую); `Tab` переключает на
виды запросов (`SELECT`, `INSERT`, …) и на файлы. Чтения — синим, записи —
жёлтым, схема — фиолетовым. Enter на запросе открывает его, на группе —
сворачивает и разворачивает (`zM` / `zR` — все), `r` — пересканировать.
Превью группы-таблицы — её `CREATE TABLE` из миграции. Сгенерированный код
(`// Code generated … DO NOT EDIT.`) и `vendor/` пропускаются.

SQL подсвечивается и в `.sql`, и внутри строк Go — по тем же правилам, так
что `"update order: %w"` остаётся обычным текстом. Теги TODO / FIXME / HACK
в комментариях выделены цветом.

**Markdown.** README, документы и всплывающая документация `K` видны
оформленными, как в просмотрщике: заголовки — цветными полосами без `#`,
код — на фоне, таблицы — в рамках, `- [x]` — галочками, у ссылок — только
текст. Строка под курсором и режим вставки показывают сырой текст, чтобы
его было удобно править; в окне документации `prefix i` (nvim только для
чтения) оформлена и она. `Space m` — сырой текст всего файла и обратно.
Значки — обычные символы Юникода, Nerd Font не нужен; формулы LaTeX не
рисуются (для них нужна внешняя программа).

**Строка «где я».** Над каждым окном с файлом: путь от корня проекта и то,
где стоит курсор — `internal/order/service.go › (*Service) PlaceOrder › func`
или `model.go › Order › Total`. Строится по дереву Tree-sitter, gopls не
нагружает; в больших файлах — только путь.

**Действия gopls (`gra`).** Что gopls предлагает в типичных местах:

| Где | Действие |
|---|---|
| выделены строки | Extract function |
| выделено выражение | Extract variable |
| на вызове функции | Inline call |
| на литерале `Order{}` | Fill Order — заполнить все поля |
| на имени функции | Add test for F — табличный тест в `_test.go`; Extract declarations to new file |
| на типе, который не реализует интерфейс (`var _ I = (*T)(nil)`) | Declare missing methods |
| на поле структуры | Add struct tags / Remove struct tags |
| на строковом литерале | Convert to raw string literal |

`Browse documentation / assembly / free symbols` открывают страницу gopls
в браузере.

**Замена текста по проекту** (комментарии, строки, SQL — то, что не
переименовать по смыслу): `Space /` → `Alt-a` (выбрать всё) → `Alt-q` (в
quickfix) → `:cdo s/старое/новое/gc | update`.

**Дерево правок.** Корни — Go-объявления, изменённые относительно `HEAD`
(`git diff HEAD` и неотслеживаемые `.go`). Без git — объявление под
курсором. Для каждого корня gopls находит:

- кто от него зависит: `caller`, `ref`, `test`, `impl`;
- что он использует: `calls`, `type`, `value`, `field`, `iface`.

В окне дерева Enter переходит к месту использования, `d` — к объявлению.
Символ `↑` означает, что узел уже есть выше по ветке.

Команды:

- `:ChangeTree!` — открыть последнее дерево без пересборки;
- `:ChangeTreeText`, `:ChangeTreeLedger`, `:ChangeTreeTrace`, `:ChangeTreeIndex` —
  граф текстом, разбор идентификаторов, запросы к gopls, список изменённых объявлений.

### git

- `git diff`, `show`, `log -p` и `add -p` выводятся через delta; `n` / `N` — следующий / предыдущий файл.
- `git ds` — две колонки.
- `git dft`, `git dshow <sha>`, `git dlog` — diff по синтаксису (difftastic).
- lazygit — `prefix g`; `|` переключает отображение diff: delta → difftastic → git.

### zsh

| Клавиши | Действие |
|---|---|
| `Ctrl-R` / `Ctrl-T` / `Alt-C` | fzf: история, файлы, перейти в каталог |
| `↑` / `↓` | история по набранному началу строки |
| `→` / `Alt-F` | принять подсказку целиком / по слову |
| `Ctrl-X Ctrl-E` | редактировать команду в nvim |
| `Ctrl-Z` | на пустой строке — вернуться в свёрнутый nvim |

`deadline 2030-01-15 10:00 Релиз` — плашка в статус-баре tmux;
`deadline` — список, `deadline clear` — убрать все.

## Проверки

```sh
nvim/verify.sh     # синтаксис, Lua-тесты, хелпер, плагины, gopls на фикстурах, дерево правок
```
