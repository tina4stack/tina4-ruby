# Ruby Firebird rollback() suspected no-op (behavioral parity — twin of Node/PHP)

## Goal
Ruby's Firebird driver looks like it has the same silent-rollback shape as Node
(fixed) and PHP (fixed 3.13.86). Verify-then-fix against a REAL Firebird, NO mocks.
If it cannot be verified live in this environment, STOP and report — do NOT fix
from a code read and do NOT merge unverified.

## Suspected bug (from reading lib/tina4/drivers/firebird_driver.rb)
- `begin_transaction` (L216): `@transaction = @connection.transaction`
- `commit` (L220): `@transaction&.commit`  ;  `rollback` (L224): `@transaction&.rollback`
- `execute`/`execute_query` (L181/L170) run on `@connection` (`.execute`/`.query`)
- In the `fb` gem, `Fb::Connection#transaction` (no block) starts a transaction ON
  THE CONNECTION and likely returns nil -> `@transaction` is nil -> `commit`/
  `rollback` are `nil&.…` NO-OPS. Statements DO run in the connection's open txn
  (correct for `fb`), but nothing ever commits/rolls it back through `@transaction`.
  So this is a VARIANT of the Node bug: the fix is probably to commit/rollback the
  CONNECTION (`@connection.commit`/`@connection.rollback`), not a nil `@transaction`.
  MUST be confirmed against the real `fb` gem — its exact `transaction`/`commit`/
  `rollback` return + autocommit semantics decide the correct fix.

## Reference (Python master)
tina4-python firebird.py: single connection, start_transaction suppresses per-
statement autocommit, commit/rollback act on the connection. Match that CONTRACT.

## HARD feasibility gate (do FIRST)
The `fb` gem is NOT loadable on this macOS host (`cannot load such file -- fb`);
it needs native libfbclient (the lib that was clumplet-broken for PHP native on
macOS+FB5). So a live repro needs a LINUX Ruby + `fb` + FB5 environment:
- Live Firebird already up: container `tina4-fb-node` (firebirdsql/firebird:5.0.2),
  host port 3053, SYSDBA/masterkey, server db /var/lib/firebird/data/test.fdb.
- Stand up a Linux ruby container, install libfbclient/firebird-dev, `gem install fb`,
  and connect to the Firebird (share a docker network, or host.docker.internal:3053).
- IF the `fb` gem cannot build on modern Ruby OR cannot connect to FB5: STOP.
  Report the exact failure. Do NOT fix from a code read; do NOT merge. Surface it
  as "needs a working fb+FB5 env" (same honesty as PHP native clumplet on macOS).

## Scope
- [x] Feasibility gate: Linux ruby + fb gem + connect to live FB5. PASSED — ruby:3.3
      container on the default bridge, firebird-dev (FB4 client) + `gem install fb`
      (fb-0.10.0) built clean, connected to tina4-fb-node (FB 5.0.2) at
      172.17.0.9:3050, real `SELECT 1` over the wire returned `[{"ONE"=>1}]`.
- [x] REPRO FIRST: through real Tina4::Database against live FB5, `db.rollback`
      inside an explicit txn RAISED `NoMethodError: undefined method 'rollback'
      for true` at firebird_driver.rb:225 — the write was never undone (bug
      confirmed; sharper than a silent no-op).
- [x] Confirmed fb-gem semantics live: `Fb::Connection#transaction` (no block)
      STARTS the txn on the connection and returns `true` (a boolean, NOT a txn
      object); the connection itself responds to commit/rollback; a bare
      `conn.execute` AUTO-COMMITS (a fresh 2nd connection sees the row);
      `conn.commit`/`conn.rollback` with no active txn are harmless no-ops
      (return nil); `conn.query` inside a txn does read-after-write and does NOT
      commit the txn (a following rollback still undoes the row).
- [x] Fixed lib/tina4/drivers/firebird_driver.rb: begin_transaction starts the
      txn on the connection + sets @in_transaction; commit/rollback act on
      @connection and clear the flag (Python `_in_transaction` parity).
      with_reconnect / reconnect! now use @in_transaction. Read-after-write +
      standalone autocommit verified intact against live FB.
- [x] No-mock lock-in spec spec/firebird_rollback_spec.rb (positive + negative),
      real FB, env-gated on TINA4_TEST_FIREBIRD_URL (skip reason says "firebird",
      no other gate keyword → green skip). Negative (rollback-undoes) FAILS on
      old code (proven: NoMethodError at firebird_driver.rb:225). Green on live
      FB5: 3 examples, 0 failures.
- [x] Full `bundle exec rspec` GREEN at HEAD, run TWICE independently (macOS,
      ruby 4.0.2): 4141 examples, 0 failures, 74 pending (service-gated skips;
      firebird rollback spec green-skips — fb gem absent on macOS).
- [x] Branch feature/firebird-rollback-noop off v3. Committed. NOT merged, NOT tagged.

## Constraints
- No mocks. Real Firebird only. feedback_no_mock_testing, feedback_independent_verification.
- Python is master (feedback_python_master). If Python is wrong, surface it.
- One worker in this tree only (feedback_no_parallel_workers_one_tree).
- Verified-live or NOT DONE. An unverified "fix" is not a fix.

## Status: Fix complete, verified live on FB 5.0.2 — on feature/firebird-rollback-noop, awaiting owner release gate (NOT merged, NOT tagged)
