# Phase 8 — Unpin the memory-id timezone bug

Landmines 2 and 3 in `core/fixtures/memories-conformance/README.md` are a real
bug in the shipping app, found by writing the fixtures and pinned rather than
fixed so the port could be proved behaviour-identical. The port is done. This
change fixes it.

**Exit criterion:** for every UTC offset and every time of day, the id a memory
is pre-published under equals the id the app generates when that day arrives,
and the date inside the id names the day the memory is actually about.

## The bug, precisely

A calendar memory's id is date-qualified: `onThisDay-2024-06-11`,
`yearsAgo-5-2024-06-11`. The date comes from `LocalCalendar::iso_day_gmt`
(`time.rs:245`), which renders an **instant** in **GMT**. The two call sites
hand it two different instants:

| path | instant passed | file |
|---|---|---|
| live daily generation | `today = inputs.now` — the actual current instant | `lib.rs:481` |
| widget pre-publish | `day = start_of_day(now) + N days` — **local midnight** | `scheduled.rs:90` |

In UTC those render the same date and everything agrees. Anywhere else they do
not, and the failure is a function of the offset and the *time of day*:

- **Ahead of GMT** (offset `+h`): local midnight of day D is D−1 in GMT, so the
  scheduled id always says D−1. The live id says D once local time passes
  `+h` — i.e. after 09:00 in Tokyo. Open the app in the afternoon and the
  widget's pre-published id for today is one day behind the one the rail
  generated. The deep link does not resolve.
- **Behind GMT** (offset `−h`): local midnight of D is still D in GMT, so the
  scheduled id is right. But the *live* id rolls forward once local time
  passes `24−h` — 17:00 in Los Angeles. Evening usage produces `onThisDay-D+1`
  for a memory about day D.

The fixture's `asia-tokyo-horizon` scenario records the first case (three of
seven days with empty `matchedIDs`, and day +4's pre-published
`onThisDay-2024-06-11` colliding with day +3's live one — *same id, different
photos*). **The mirrored evening failure behind GMT is not in the fixture**:
the README asserts parity holds there, which is true only for the `now` that
scenario happens to use. Any regression suite for this fix has to cover it.

There is a third symptom that is not about parity at all: even when both sides
agree, the date in the id is simply wrong for a GMT-ahead user. Tokyo's
"On this day" for June 12 local is called `onThisDay-2024-06-11` (landmine 2).
It is user-visible only through the `MemoryCoordinator` seen/cool-down history,
but it is wrong.

## The fix

**Render the id from the local calendar day, never from a GMT instant.**

```rust
/// The id's date is the local calendar day the memory is about.
pub fn iso_day(&self, t: AppleDate) -> String   // replaces iso_day_gmt
```

formatting `self.ymd(t)` as `YYYY-MM-DD`. Both call sites then agree by
construction: `cal.ymd(now)` and `cal.ymd(local midnight of D)` are the same
y/m/d for every offset and every time of day, because both instants fall inside
the same local day. The wrong-day symptom goes with it.

`iso_day_gmt` is deleted, not kept as a deprecated alias — a second spelling of
the thing that caused this is a trap.

### DST inside the horizon

`iso_day` alone is not sufficient. `scheduled.rs` walks the horizon by
`adding_days`, which adds exactly 86 400 s at the run's single `now` offset. If
a DST transition falls inside the seven days, day +5's computed instant is an
hour off true local midnight — harmless when the clock springs forward (01:00
local, still day D), but a day wrong when it falls back (23:00 local on D−1,
so `ymd` returns D−1 and the bug comes back for two days a year).

So the horizon iterates **civil days**, not instants:

1. `let start = cal.ymd(inputs.now)` — today's local y/m/d.
2. Day N is `start` advanced N days in the Gregorian calendar
   (`gallery_model::date` already has the day arithmetic `adding_months` uses).
3. The id is formatted from those y/m/d directly. It never touches an instant.
4. The two remaining instants are derived under **different calendars**, and
   getting this backwards reintroduces the bug:
   - `valid_from` / `valid_to` use **that day's own offset**. They are compared
     against `now` by the widget, so they have to be true local midnights.
   - the `day` passed to the generators for month/day filtering uses the
     **`now` calendar**. The generators read it back through `zone.now()`
     (`calendar.rs:29,54`), so an instant built under a different offset
     resolves to the *neighbouring* day on a spring-forward horizon — the
     original bug, wearing a different hat. Building and reading it in one
     calendar is exact by construction.

   This split is safe only because the id no longer comes from an instant at
   all. Say so in the module doc, or the next reader will "simplify" the two
   calendars back into one.

   *(Corrected during implementation. The first draft of this plan said both
   instants should use the day's own offset, which is wrong for the second.)*

Point 4 needs an offset per horizon day, which the core cannot compute (no tz
database). It arrives the same way per-photo offsets already do:

- `MemoryInputs` gains `horizon_offset_seconds: Vec<i32>` — one per horizon
  day. **Empty means "use the `now` offset for everything"**, exactly as
  `Zone::per_photo` already documents, so a caller with no real calendar
  degrades instead of breaking.
- `CoreMemories.record(from:)` fills it: for each of the next
  `scheduledMemoryHorizonDays()` days, `Calendar.current.timeZone
  .secondsFromGMT(for: <that day's local noon>)`. Noon, not midnight — midnight
  is the instant a transition can land on, and noon is unambiguous in every
  real zone.
- `Zone` grows `at_horizon_day(n)` beside `at(photo_index)` / `now()`.

`Calendar.current.timeZone` rather than `TimeZone.current` — the existing rule
in `CoreMemories`, for the reason recorded there.

## What changes for users

`onThisDay-*` and `yearsAgo-*` ids change for every non-UTC user. Three
consequences, all bounded:

1. **Seen (−30) and cool-down (−25) history is orphaned** for calendar
   memories. A memory the user viewed last week can resurface without its
   penalty, once. Density and trip ids are unaffected — they are built from
   `YearMonthDay` fields already (`lib.rs:611`, `trips.rs:256`), not from
   `iso_day_gmt`, and `clusterKey` splits on `-` over numeric components.
   No migration: rewriting a stored history against a re-derived id would need
   the zone each entry was written in, which was never recorded.
2. **Already-published widget snapshots carry old ids.** Display is unaffected —
   `MemoriesWidget.makeEntry` filters on `validFrom`/`validTo`, not ids. Only a
   tap-through is at risk, and `AppRouter.applyMemory` already handles an id it
   cannot resolve (queue, then give up once memories exist). The next export
   replaces the snapshot. Nothing to migrate; a line in the plan is enough.
3. `MemoryCoordinator`'s hidden set is keyed by id, so a hidden calendar memory
   un-hides once. Same class as (1), same answer.

## Fixtures

This is the part that needs care, because the mechanism changed underneath the
fixtures: **the Swift engine is deleted**, so `TEST_RUNNER_CONFORMANCE_REGEN=1`
no longer records "what Swift did" — it records what the Rust core does through
the FFI. The regen command still works and still writes canonical JSON; what it
means is different.

That makes the strategy explicit:

- `scheduled_memories.json` and `memory_engine.json` are **regenerated on
  purpose**, and the README section "The landmines, in one place" is rewritten:
  entries 2 and 3 change from "pinned as-is, do not clean this up" to "fixed in
  `_plans/10`; the invariant is now X", keeping the description of the old
  behaviour so the diff in the fixture is explicable years later.
- Regenerating from the implementation being changed proves nothing on its own.
  The new expectations must be **hand-computed first**, written into the Rust
  unit tests as literals, and only then may the JSON be regenerated. The
  fixture's job after this change is regression, not verification.
- The `notes` arrays are part of the fixture and are compared; they live in the
  test sources and must be updated in the same commit or the suite fails —
  which is the intended forcing function.
- `asia-tokyo-horizon` keeps its name and gains the assertion it should always
  have had: `matchedIDs` covers every horizon day, and no two days share an id.
- **New scenarios**, because the existing pair (UTC, Asia/Tokyo — both
  DST-free, both with a morning `now`) cannot see two of the three symptoms:
  - `america-los-angeles-evening-horizon` — offset −7, `now` at 18:00 local.
    The mirrored failure. Must have failed before the fix.

    *(Corrected during implementation. It would not have: the `parity` block
    ran the live pipeline at **noon** of each horizon day, and noon is the one
    hour at which a GMT-rendered id and a local calendar day agree in every
    zone. Behind GMT the horizon itself was always right — local midnight of D
    is still D in GMT — so with a noon comparison this scenario passes before
    and after. The harness now runs the live half at the scenario's **own
    wall-clock time**, which is a no-op for the four scenarios that predate
    this one (all at local noon, so their fixture entries are byte-identical
    apart from the two new fields) and is what makes the evening claim true.)*
  - `europe-berlin-dst-fallback-horizon` — `now` a few days before the October
    transition, so the horizon crosses it. Exercises the per-day offset table.
  - `asia-kathmandu-horizon` — offset +5:45. A non-hour offset, because every
    piece of arithmetic here is in seconds and nothing currently proves it.

## Order of work

1. **`time.rs`** — `iso_day` replacing `iso_day_gmt`, `Zone::at_horizon_day`,
   and the two existing tests in that file inverted with a comment naming this
   plan. Rust unit tests for the zone × time-of-day matrix: `{−11, −7, 0, +5:45,
   +9, +13}` × `{00:30, 09:00, 12:00, 18:00, 23:30}` local, asserting live and
   scheduled ids agree and that the date names the local day.
2. **`scheduled.rs`** — civil-day horizon, per-day offsets for the instants,
   module doc rewritten (it currently instructs the reader not to fix this).
3. **`calendar.rs`** — the two `format!` sites.
4. **FFI + `CoreMemories`** — `horizon_offset_seconds` in and populated.
5. **Fixtures + README**, in the order described above.
6. **`MemoryCoordinatorTests`** — `testScheduledRefreshGeneratesAndSetsGate
   OnCompletion` asserts the literal id `onThisDay-2024-06-11` while its harness
   pins only the clock (`FixedClock`), not the zone.

   **The zone was a red herring.** Diagnosed during implementation: the
   harness's 12 photos on 2019-06-11 with `now` = 2024-06-11 satisfy the
   5-year milestone *and* on-this-day at the same 10-photo floor, so the engine
   correctly returns **two** memories where the test asserts one. Everything in
   that harness is noon UTC, so every offset shifts `now` and the photos
   together and the month/day always matches — the failure is zone-independent.
   The same extra memory explains the second known failure,
   `testHiddenMemoryIsFilteredFromVisible`, which contains no date literal at
   all and therefore could never have been a timezone bug.

   Both are **pre-existing test bugs**, fixed here because this phase diagnosed
   them, and reported separately from the timezone work. The zone is still
   pinned in that harness: after this change the hard-coded id *becomes*
   zone-dependent even though it is not today.
   `WidgetDeepLinkTests.testTagsCommaInPathSurvives` — the third known failure —
   is unrelated and stays out of scope.

## Risks

| Risk | Response |
|---|---|
| Regenerating fixtures hides a new bug | Hand-computed literals in Rust tests first; regen second. Stated as a rule above because the temptation runs the other way. |
| Seen/cool-down reset surprises a user | One-time, invisible except as a memory reappearing sooner than it would have. Cheaper than a migration that cannot be written correctly. |
| The per-day offset table is another `Zone` axis to get wrong | It reuses the empty-means-fallback convention that `per_photo` already documents and tests, and it is read in exactly one function. |
| Subtitles still format in the `now` calendar | Unchanged and still approximate — `time.rs`'s "What is still approximate" section covers it. Out of scope here: it is a one-hour label error, not an id mismatch. |
| A zone whose offset changes permanently (not DST) inside the horizon | Handled identically — the table is sampled per day from the platform's real calendar, which knows. |
