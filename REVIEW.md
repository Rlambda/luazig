---
name: luazig-review
description: Независимое глубокое ревью завершённой итерации luazig.
---

# Ревью завершённой итерации

Ты ревьювер-архитектор. Общие правила — `AGENTS.md`, маршрутизация —
`REVIEWER.md`. Этот документ применяется к **проверке уже выполненной**
research/implementation/correction-итерации. Цель — обоснованный вердикт о
её корректности, архитектуре, качестве кода, проверках, производительности и
provenance.

`report.md` — отчёт о работе имплементера, не доказательство их истинности.
Код, diff, воспроизводимое поведение и сырые артефакты являются независимыми
источниками evidence. Нельзя принять крупный этап только по отчёту и
сообщениям о зелёных gates. Ревьювер вправе организовать независимые
ограниченные аудиты или проверки, но сам сверяет противоречия и отвечает за
вердикт; реализацию product-исправлений он не подменяет.

## 1. Вход и охват

Полностью прочти `AGENTS.md`, `REVIEWER.md`, `CODING_RULES.md`, этот файл и переданный
`report.md`. Установи состояние worktree и владельца каждой незакоммиченной
правки. Прочти относящийся diff **целиком**: для много-коммитного milestone
также проследи каждый cut и итоговое дерево. Прочти актуальные пункты
`STATUS.md`, контракты затронутых подсистем и нужные участки PUC Lua.
`ARCHITECTURE_DEBT.md` читай при проверке архитектурного milestone или
объявленного закрытия долга. Perf-документацию читай целиком, если этап
предъявляет perf-вывод.

Составь перечень проверяемых заявлений: исходный дефект и negative-before,
целевой invariant, owner/data flow, все изменённые interfaces и call sites,
rollback/error/OOM/re-entry, удалённый legacy path, focused proofs,
обязательные gates, measured source/binary и остаточные findings. Для
каждого существенного заявления отделяй «проверено мной» от «заявлено в
отчёте». Для большого diff применяй карту изменённых путей и независимые
проверки, а не случайную выборку нескольких удобных функций.

## 2. Самостоятельное расследование

1. Проследи от входов до terminal state все затронутые ветви: обычный путь,
   failure edges, GC/realloc, protected boundary, suspension/resume,
   shutdown и rollback — в зависимости от подсистемы. Проверь все
   изменённые call sites и сохранённые legacy sites; representative site
   годится как иллюстрация, но не заменяет inventory.
2. Сравни с PUC не текст функций, а observable behavior, ownership,
   lifetime, publication order, error kind/object и fast/slow paths.
   Отступление от PUC должно иметь явное доказательство parity либо
   утверждённый владельцем trade-off.
3. Независимо проверь главный инвариант, самое рискованное окно
   ownership/OOM и отсутствие второго mutable authority. При rollback
   проверь возможность настоящего следующего GC cycle и дальнейшего
   использования VM. Не считай компиляцию доказательством этих свойств.
4. Проверь, что focused тест действительно отличает старое поведение от
   нового (negative-before или mutation), не исправляет production state
   вручную и сравнивает с PUC там, где заявлена parity. Повтори решающие
   короткие пробы; для большого или рискованного milestone перепроверь
   применимые battery/gates либо их сырые выводы, binary identity и
   соответствие финальному source. Не называй чужой лог независимым прогоном.
5. Проверь чистоту итогового кода: временные слои и diagnostics удалены,
   owner/invariant-комментарии описывают действующий код, нет запрещённых
   test-specific ветвей, мёртвых дублирующих механизмов или скрытой цены на
   hot path. Проверяй diff, ссылки и согласованность docs.

Глубина зависит от риска и масштаба, **не** от времени, затраченного
имплементером. Не передавай имплементеру обычную работу ревью ради экономии
токенов. Если после исчерпания доступных проверок evidence всё ещё не
позволяет установить инвариант, не выдавай ACCEPT: назначь bounded
research/verification именно недостающего факта. Timeout без диагностики —
INCONCLUSIVE, а не failure и не green. `_soft`, `_port`, нормализация вывода
или пропущенная differential lane не доказывают прохождение gate.

## 3. Контрольные вопросы по подсистемам

### VM, вызовы и coroutine

- `Thread` владеет stack/top/boxed/TBC state; `Vm` выбирает активный
  `Thread`; `CallFrame` владеет состоянием вызова. PC, error status,
  continuation, hook/trap и coroutine switching имеют одного владельца.
- Кэши требуют явной синхронизации. Не допускай второй call/return модели
  или replay state. Сопоставляй с PUC `CallInfo`, `savedpc`,
  `luaD_precall`, `luaD_poscall`, `finishCcall`.
- Переключение coroutine допустимо, только если пересекаемая continuation
  целиком представлена в `Thread`/`CallFrame`, а не на host stack.
  Проверь inline boundaries, MULTRET, yield/error/TBC/hooks и re-entry.

### GC, память и ошибки

- Проверь единственного owner, момент передачи владения, roots/barriers,
  открытые upvalues, TBC, secondary registries и симметрию accounting.
- Raw pointer/slice не переживает realloc/free владельца. На failure edge
  после rollback возможны настоящий GC cycle и дальнейшая работа VM.
- Error kind/status/object сохраняются через protected boundary,
  continuation и resume; OOM не маскируется как RuntimeError.

### C API и stdlib

- Сравни stack effects, error transport, `LUA_MINSTACK`, MULTRET и identity
  с PUC (`lapi.c`, `lauxlib.c`, `ldo.c`).
- Shared helper сохраняет семантику каждого exported wrapper и получает
  правильный `lua_State`, а не неявно текущий state.
- Stdlib-оптимизация не меняет observable behavior, interning,
  external-string lifetime или error timing.

## 4. Производительность и provenance

Для perf-review полностью прочти `tools/perf/README.md`. Установи exact
measured source, wrapper scope, toolchain, hashes и immutable A/B binaries;
проверь, что сырые данные и вычисленные выводы относятся к финальному коду.
Перепроверяй hashes после команд, способных пересобрать `zig-out`. Не
создавай рутинный блок SHA в ответе: provenance сообщай рядом с finding,
если есть несовпадение или оно необходимо для воспроизведения.

Причинный вывод прежде всего опирается на paired dynamic instructions;
wall, cycles, IPC, misses и code size помогают объяснить эффект. Не называй
всю стоимость `runBytecodeDispatch` dispatch floor: отделяй fetch, opcode
semantics, frame entry, calls/returns, hooks, GC и result movement. Снижение
instructions при росте wall/падении IPC не автоматически успех. После
крупного изменения профиль должен быть свежим. Финальные `current-*`
относятся к одному source/binary либо явно historical; baseline не
обновляется без решения владельца, manifest append-only.

Архитектурная миграция без цели ускорения не обязана сохранить скорость,
если владелец принял trade-off. Однако величина и причина регрессии должны
быть честно проверены; perf нельзя использовать для сокрытия correctness
дефекта. Жёсткий budget — gate лишь при заранее утверждённом пороге или
perf-цели самой задачи.

## 5. Findings и вердикт

Для существенного finding зафиксируй: первую неправильную операцию,
нарушенный invariant, PUC-механизм, origin (внесён этапом или pre-existing),
severity и судьбу из `AGENTS.md`, воспроизводимое evidence и путь исправления.
Нерешённый BLOCKER/HIGH внеси отдельным открытым пунктом `STATUS.md`.
Независимый pre-existing finding не перехватывает этап автоматически,
кроме условий из `AGENTS.md`. Неточность прошлого `report.md` исправляй
своим выводом, а не задачей на переписывание отчёта.

- **ACCEPT** — выполненные invariant, code quality, evidence и gates
  подтверждены достаточно для масштаба этапа. Затем перейди к
  `PLANNING.md`; не смешивай принятие с выбором следующего milestone.
- **ACCEPT + RECORD** — то же, с независимым backlog-finding, который
  не препятствует принятию. Затем перейди к `PLANNING.md`.
- **CORRECT** — этап внёс регрессию, не выполнил свой invariant, сломал
  обязательный gate или оставил небезопасным изменённый product-путь.
  Сформируй ограниченный correction `prompt.md` по доказанному дефекту.
- **INCONCLUSIVE** — решающее evidence недоступно или противоречиво.
  Нельзя объявлять ACCEPT; назначь bounded research/verification
  недостающего факта, сохраняя текущий milestone открытым.
- **REDESIGN** — исследование опровергло утверждённую архитектуру.
  Останови implementation handoff и обсуди новое решение с владельцем.

`CORRECT` допустим только ради product-кода, обязательного gate или
изменённого runtime-инварианта, не ради литературного качества отчёта.
При CORRECT/INCONCLUSIVE `prompt.md` задаёт invariant или вопрос,
точный scope, известное evidence, stop conditions, KEEP/REMOVE,
negative-before/focused proof и применимые gates. Не требуй повторного
выпуска прошлого `report.md`; новый отчёт станет результатом новой
содержательной работы.

Ответ ревьюера краток, но самодостаточен: вердикт, главные независимо
подтверждённые факты, findings и их судьба, что осталось непроверенным,
и ссылка на `prompt.md`, если он создан. Не называй полное принятие
частичной проверкой и не выдавай отчёт имплементера за собственное evidence.

## 6. Качество кода

Код должен быть кратким, понятных, хорошо поддерживаемым. Проси агента переделать сложный и тяжело поддерживыемый, "грязный код"
Следуй методологиям чистого кода.
