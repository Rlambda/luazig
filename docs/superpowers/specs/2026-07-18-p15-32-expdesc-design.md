# P15.32 expdesc: PUC Lua expression descriptor для Zig codegen

## Контекст

Текущий codegen (`src/lua/codegen_bc.zig`) возвращает из `genExp` значение типа `u8` —
номер регистра, в который уже материализован результат. Это приводит к избыточным
инструкциям:

- `local x = a` → `MOVE R[tmp] R[a]` вместо прямого использования `R[a]`
- `local x = a + b` → `MOVE R[t1] R[a]; MOVE R[t2] R[b]; ADD R[x] R[t1] R[t2]`
  вместо `ADD R[x] R[a] R[b]`
- `local x = 42` → `LOADI R[tmp]` + `MOVE R[x] R[tmp]` вместо `LOADI R[x]`

PUC Lua решает это через `expdesc` — структуру, описывающую выражение **до**
материализации в регистр. Значение "дисчарджится" в регистр только когда коду
действительно нужен регистр (call argument, assignment target, condition test).

## Цель

Портировать архитектуру PUC Lua `expdesc` в Zig codegen, используя идиоматичные
Zig-конструкции (tagged union вместо C enum+union, slices вместо указателей).

Закрывает 3 чекбокса P15.32:
1. Ввести PUC-подобный operand/expdesc
2. Не материализовать local/constant до инструкции, которой действительно нужен регистр
3. Писать результат выражения сразу в destination assignment/return slot

## Архитектура PUC Lua

### expkind (виды выражений)

```
VVOID      — пустой список (для explist)
VNIL       — константа nil
VTRUE      — константа true
VFALSE     — константа false
VK         — константа в pool (info = индекс)
VKFLT      — float константа (nval)
VKINT      — int константа (ival)
VKSTR      — string константа (strval)
VNONRELOC  — значение в фиксированном регистре (info = регистр)
VLOCAL     — локальная переменная (var.ridx = регистр)
VUPVAL     — upvalue (info = индекс)
VCONST     — compile-time const local
VINDEXED   — t[k] с регистрами для t и k
VINDEXI    — t[const_int]
VINDEXSTR  — t["string"]
VINDEXUP   — upvalue[k]
VJMP       — test/comparison (info = pc jump)
VRELOC     — инструкция, результат в любой регистр (info = pc)
VCALL      — вызов функции (info = pc)
VVARARG    — vararg выражение (info = pc)
```

### Ключевые операции

- `dischargevars(e)` — преобразует variable-kinds (VLOCAL, VUPVAL, VINDEXED*, VCONST)
  в non-variable kinds (VNONRELOC, VRELOC, VK*, VNIL, VTRUE, VFALSE). Не эмитит
  регистр — только "разрешает" значение.
- `discharge2reg(e, reg)` — discharge + материализация в конкретный регистр.
- `exp2nextreg(e)` — discharge в следующий свободный регистр (freereg).
- `exp2anyreg(e)` — discharge в любой регистр (переиспользует VNONRELOC если уже в регистре).
- `exp2val(e)` — discharge до значения (без требования регистра).
- `storevar(var, e)` — присваивание: discharge `e` в регистр `var`.
- `indexed(t, k)` — создать VINDEXED/VINDEXI/VINDEXSTR из `t` и `k`.
- `goiftrue(e)` / `goiffalse(e)` — условные переходы.

### Поток данных для `local x = a + b`

1. `singlevar("a")` → `expdesc{ .k = VLOCAL, .var.ridx = 0 }`
2. `singlevar("b")` → `expdesc{ .k = VLOCAL, .var.ridx = 1 }`
3. `luaK_infix(ADD, &e1)` — сохраняет e1 (VLOCAL r=0)
4. `simpleexp("b")` → `expdesc{ .k = VLOCAL, .var.ridx = 1 }`
5. `luaK_posfix(ADD, &e1, &e2)`:
   - `dischargevars(e1)` → e1 становится VNONRELOC(info=0)
   - `dischargevars(e2)` → e2 становится VNONRELOC(info=1)
   - `codebinexpval(ADD, e1, e2)` → эмитит `ADD R[freereg] R[0] R[1]`
   - результат: `expdesc{ .k = VRELOC, .info = pc }`
6. `adjustlocalvars("x")` — выделяет регистр 2 для x
7. `luaK_storevar(&var_x, &e)`:
   - `discharge2reg(e, 2)` → VRELOC: `SETARG_A(instr, 2)` — инструкция ADD
     получает destination R[2] напрямую, без MOVE

Итог: **одна инструкция** `ADD R[2] R[0] R[1]`.

## Zig-адаптация

### ExpDesc как tagged union

Вместо C `enum + union` используем Zig tagged union:

```zig
const ExpDesc = struct {
    kind: Kind,
    u: U,
    t_list: ?JumpList = null,  // exit-when-true jumps
    f_list: ?JumpList = null,  // exit-when-false jumps

    const Kind = enum {
        void,
        nil,
        true,
        false,
        k,           // constant pool index
        k_int,       // i64
        k_float,     // f64
        k_str,       // []const u8 (decoded)
        non_reloc,   // fixed register
        local,       // local variable register
        upval,       // upvalue index
        const_local, // compile-time const local
        indexed,     // t[k] with registers
        index_i,     // t[const_int]
        index_str,   // t["string"]
        index_up,    // upvalue[k]
        jmp,         // test/comparison
        reloc,       // relocatable instruction
        call,        // function call
        vararg,      // vararg expression
    };

    const U = union {
        info: i32,           // generic (pc, upvalue index, const pool index)
        ival: i64,           // k_int
        nval: f64,           // k_float
        strval: []const u8,  // k_str
        var_: struct {       // local
            ridx: u8,
            vidx: i16,
        },
        ind: struct {        // indexed
            idx: i16,
            t: u8,
            ro: bool,
            keystr: i32,
        },
    };
};
```

### JumpList

PUC использует связанные списки через `Instruction` поля. В Zig можно использовать
`std.ArrayList(i32)` или собственный список. Для простоты — `?i32` (head) + patch
через `luaK_patchlist`-эквивалент.

### Изменения в Codegen

Текущий `genExp(e) -> u8` заменяется на `genExp(e) -> ExpDesc`. Все call sites
адаптируются:

- `genExpNextReg(e)` → `genExp(e); exp2nextreg(&ed); return ed.u.info`
- `genNameValue(name)` → возвращает ExpDesc с kind=VLOCAL/VUPVAL/VK вместо MOVE
- `genBinOp` → `luaK_infix` / `luaK_posfix` pattern
- `genAssign` → `storevar(var_ed, val_ed)` вместо MOVE в регистр
- `genCall` → `exp2nextreg` для аргументов, `setreturns` для multiret
- `genReturn` → `exp2anyreg` / `exp2val`

### Поэтапный план

#### Этап 1: ExpDesc struct + discharge (foundation)
- Добавить `ExpDesc` struct в codegen_bc.zig
- Реализовать `dischargevars`, `discharge2reg`, `exp2nextreg`, `exp2anyreg`, `exp2val`
- Реализовать `freeexp`/`freeexps` (free register if VNONRELOC)
- Пока НЕ менять существующие `genExp` — добавить параллельный путь

#### Этап 2: Константы и locals (main win)
- `genExp` для Nil/True/False/Integer/Number/String → возвращает ExpDesc с kind=nil/true/false/k_int/k_float/k_str
- `genNameValue` → возвращает ExpDesc с kind=local/upval вместо MOVE
- `genExpNextReg` → использует `exp2nextreg`
- `genBinOp` → использует discharge для операндов, эмитит напрямую в destination

#### Этап 3: Indexed variables
- `genField` / `genIndex` → возвращает ExpDesc с kind=indexed/index_i/index_str
- `storevar` для indexed → SETFIELD/SETI/SETTABLE напрямую

#### Этап 4: Calls и vararg
- `genCall` → возвращает ExpDesc с kind=call
- `genVararg` → возвращает ExpDesc с kind=vararg
- `setreturns` / `setoneret` для multiret

#### Этап 5: Jumps и conditions
- `genAndExp` / `genOrExp` → jump lists
- `goiftrue` / `goiffalse`
- `genIf` / `genWhile` / `genRepeat` → используют jump lists

## Ожидаемый perf gain

- `int_arith`: убрать MOVE для local reads → ~30-40% improvement
- `float_arith`: аналогично
- `comparisons`: убрать MOVE + прямой conditional jump → ~20%
- `branch_loop`: меньше инструкций в теле цикла → ~15%
- `lua_calls`: меньше MOVE для аргументов → ~10%

## Риски и митигации

1. **P15.32a провалился** — `genNameValue` возвращал регистр local напрямую без
   relocate-семантики. Решение: полноценный `dischargevars` с VLOCAL→VNONRELOC
   переходом, как в PUC.
2. **repeat/while с замыканиями** — P15.32a сломал это. Решение: `exp2nextreg`
   проверяет `r >= nvarstack` для VNONRELOC (как текущий `genExpNextReg`).
3. **Большой объём** — ~1500 строк. Решение: поэтапный план, каждый этап
   тестируется отдельно.
4. **Регрессии parity** — 31/31 должно сохраниться. Решение: после каждого этапа
   полный прогон testes_matrix + smoke.

## Критерий успеха

- 31/31 parity сохраняется
- Все smoke-тесты проходят
- Microbench: int_arith ≤ 0.8s (сейчас 1.05s), float_arith ≤ 0.8s (сейчас 1.02s)
- README обновлён, 3 чекбокса P15.32 закрыты
