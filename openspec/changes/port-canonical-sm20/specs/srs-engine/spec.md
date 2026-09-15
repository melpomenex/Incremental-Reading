## Purpose

Defines the spaced-repetition scheduling behavior of the Incremental Reading KOReader
plugin: reviews are scheduled by a faithful port of the canonical SuperMemo 20 algorithm
(the `sm20/` reference package), including the five-model ensemble, forgetting-index
finalization, weight adaptation, and durable per-item/collection scheduling state.

## ADDED Requirements

### Requirement: Reviews are scheduled by the canonical SM-20 pipeline

When a card is graded, the system SHALL compute the next interval by running the canonical
SM-20 pipeline as implemented in the `sm20/` reference package: all five scheduling models
run on every review, their stability outputs are blended with the Algorithm Arena weights
(defaults 6, 14, 45, 25, 10 percent), and the blended stability is finalized through the
forgetting-index factor, the post-lapse curve or dispersal, clamping to [0.7, 44530],
rounding to an integer in [1, 44530], and the minimum-growth guard for passing reviews
with a prior repetition. The plugin's engine SHALL produce intervals equivalent to the
reference implementation for identical inputs (state, grade, elapsed days, forgetting
index, weights, and random stream).

#### Scenario: Passing review schedules via the ensemble blend
- **WHEN** a card with at least one prior repetition is graded as a pass and the engine
  runs with the same inputs as the canonical reference
- **THEN** the resulting interval equals the canonical `sm20/` pipeline's interval for
  those inputs, and the interval respects the minimum-growth floor relative to the
  interval actually used since the last review

#### Scenario: Lapse on an item with prior repetitions uses the post-lapse curve
- **WHEN** a card with at least one prior repetition receives a failing grade
- **THEN** the next interval is produced by the post-lapse path and lies within 1 to 11
  days

#### Scenario: First review initializes from the grade's canonical initial values
- **WHEN** a card that has never been reviewed is graded
- **THEN** the engine initializes its difficulty and stability from the canonical
  per-grade initial values before computing the interval

### Requirement: Grade buttons map to SuperMemo grades

The four review buttons SHALL map to integer SuperMemo grades: Again → 1, Hard → 3,
Good → 4, Easy → 5. A failing grade (Again) SHALL be treated as a lapse by every part of
the pipeline, and Hard/Good/Easy SHALL receive their distinct canonical pass-grade
treatment.

#### Scenario: Again triggers lapse handling
- **WHEN** the user taps "Again"
- **THEN** the engine runs the review with integer grade 1 and all pipeline components
  treat it as a lapse

#### Scenario: Distinct pass grades produce distinct scheduling
- **WHEN** the same card state is graded Hard, Good, and Easy in three separate previews
- **THEN** the three predicted intervals differ according to the canonical grade factors

### Requirement: Reviews use real elapsed time

The engine SHALL receive, for every review and preview, the number of days actually
elapsed since the card's last committed review (zero for never-reviewed cards), derived
from stored review timestamps — not from the card's current stability or interval.

#### Scenario: Late review reflects overdue time
- **WHEN** a card scheduled 10 days ago with a 5-day interval is reviewed today
- **THEN** the engine runs the review with an elapsed-days value of 10

#### Scenario: Preview of an unseen card
- **WHEN** a card that has never been reviewed is previewed
- **THEN** the engine evaluates it with elapsed days of zero

### Requirement: Arena weights adapt on committed reviews

On every committed (non-preview) review of an item with a prior repetition and a recorded
prior model prediction, the system SHALL update the five Arena weights using the canonical
decoded adaptation rule: mean-centered multiplicative update from each model's signed
prediction error, per-slot clamping (M1 [0.1, 30], M2 [2, 50], M3 [25, 99.9], M4 [15, 95],
M5 [0.1, 45]), and renormalization to a sum of 100. Previews SHALL NOT modify the weights.

#### Scenario: Weights shift toward a better-predicting model
- **WHEN** a committed review occurs where one model's prior prediction matched the
  outcome better than the others
- **THEN** that model's weight increases relative to the others within its clamp bounds
  and the five weights still sum to 100

#### Scenario: Preview leaves weights untouched
- **WHEN** grade-button previews are computed for a card
- **THEN** the Arena weights and all scheduling state are unchanged afterwards

### Requirement: Per-item scheduling state is complete and persistent

For each card the system SHALL persist the full canonical per-item scheduling state —
the difficulty/stability/retrievability state, repetition and lapse counters, last
scheduled interval, the per-model sub-states and prior-review model predictions, and the
lapse markers — such that a review after an app restart or device reboot schedules
identically to a review in an uninterrupted session. Preview SHALL NOT mutate any of this
state.

#### Scenario: State survives restart
- **WHEN** a card is reviewed, the app is closed and reopened, and the card is reviewed
  again
- **THEN** the second review's inputs and result match those of the same sequence run in
  one uninterrupted session

#### Scenario: Existing decks migrate to the new engine
- **WHEN** the plugin opens a database created by the previous engine version
- **THEN** the schema is migrated in place, existing cards and review history are
  retained, cards keep their due dates, and subsequent scheduling uses the canonical
  engine with per-card state initialized from the migrated fields

### Requirement: Collection-level scheduling state is shared and persistent

The system SHALL maintain collection-wide scheduling state shared by all cards — the
classic optimizer state, the matrix-scheduler matrices, and the Arena weights — persisted
so that adaptation accumulated across sessions is preserved, and updated transactionally
so a session interrupted mid-queue does not corrupt it.

#### Scenario: Weight adaptation accumulates across sessions
- **WHEN** reviews adapt the Arena weights in one session and the app is restarted
- **THEN** subsequent reviews blend with the adapted weights, not the compile-time
  defaults

#### Scenario: Interrupted session keeps collection state consistent
- **WHEN** a review session is closed with pending batched writes
- **THEN** all committed reviews' per-card and collection state are flushed together, and
  the collection state on disk reflects every review the user graded

### Requirement: Grade previews are deterministic

The predicted intervals shown on grade buttons SHALL be computed without stochastic
dispersal or post-lapse jitter randomness, and SHALL present the deterministic finalized
interval for each grade.

#### Scenario: Repeated previews agree
- **WHEN** previews for the same card are computed twice without an intervening review
- **THEN** both computations return identical intervals for each grade

### Requirement: Engine parity is verified against the canonical implementation

The repository SHALL include an automated parity check that runs the same review
sequences through the canonical `sm20/` Python package and the plugin's Lua engine
(including state carry-over between reviews) and compares intervals and post-review
state, runnable without a KOReader installation. The parity check SHALL cover each
scheduling model, the ensemble blend, the finalization paths (pass, post-lapse,
min-growth), weight adaptation, and multi-review sequences with committed state.

#### Scenario: Golden-vector suite passes
- **WHEN** the parity check runs against the generated golden vectors
- **THEN** every case matches the canonical implementation within the defined numeric
  tolerance (exact for integer outputs such as intervals)
