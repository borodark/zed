--------------------------- MODULE CoordinatedConverge ---------------------------
\* TLA+ specification for Zed's multi-host coordinated convergence protocol.
\*
\* v2: models both CREATE (dataset absent → created) and MODIFY (dataset
\* exists → snapshotted → modified) paths. Rollback is zfs-rollback for
\* modified datasets, zfs-destroy for created datasets.
\*
\* To check: java -jar tla2tools.jar -config CoordinatedConverge.cfg CoordinatedConverge.tla
\* Invariant: NoPartialState
\* Liveness: ConvergenceTerminates

EXTENDS Naturals, FiniteSets, Sequences

CONSTANTS
    Hosts,          \* set of host names, e.g. {"mac_248", "mac_247"}
    MaxRetries      \* max rollback retries before giving up (bound)

VARIABLES
    phase,          \* "idle" | "prepare" | "converge" | "verify" | "rollback" | "done" | "failed"
    hostState,      \* host -> "absent" | "clean" | "prepared" | "converged" | "verified" | "rolled_back" | "failed"
    hostSnapshot,   \* host -> "pre-converge" | "none" | ""
    convergeResult, \* host -> "ok" | "error" | "pending"
    convergeAction, \* host -> "create" | "modify" — determined during prepare
    rollbackCount   \* bounded counter

vars == <<phase, hostState, hostSnapshot, convergeResult, convergeAction, rollbackCount>>

\* -----------------------------------------------------------------------
\* Initial state
\*
\* Each host's dataset is EITHER absent (needs create) or clean (exists,
\* needs modify). Both are valid starting points — TLC explores both.
\* -----------------------------------------------------------------------

Init ==
    /\ phase = "idle"
    /\ hostState \in [Hosts -> {"absent", "clean"}]
    /\ hostSnapshot = [h \in Hosts |-> ""]
    /\ convergeResult = [h \in Hosts |-> "pending"]
    /\ convergeAction = [h \in Hosts |-> ""]
    /\ rollbackCount = 0

\* -----------------------------------------------------------------------
\* Phase 1: Prepare — snapshot existing datasets, mark absent ones
\*
\* For existing datasets: take a snapshot (rollback target).
\* For absent datasets: mark as "create" (rollback = destroy).
\* -----------------------------------------------------------------------

StartProtocol ==
    /\ phase = "idle"
    /\ phase' = "prepare"
    /\ UNCHANGED <<hostState, hostSnapshot, convergeResult, convergeAction, rollbackCount>>

\* Prepare a host with an EXISTING dataset: snapshot it
PrepareExisting(h) ==
    /\ phase = "prepare"
    /\ hostState[h] = "clean"
    /\ hostState' = [hostState EXCEPT ![h] = "prepared"]
    /\ hostSnapshot' = [hostSnapshot EXCEPT ![h] = "pre-converge"]
    /\ convergeAction' = [convergeAction EXCEPT ![h] = "modify"]
    /\ UNCHANGED <<phase, convergeResult, rollbackCount>>

\* Prepare a host with an ABSENT dataset: no snapshot, mark for create
PrepareAbsent(h) ==
    /\ phase = "prepare"
    /\ hostState[h] = "absent"
    /\ hostState' = [hostState EXCEPT ![h] = "prepared"]
    /\ hostSnapshot' = [hostSnapshot EXCEPT ![h] = "none"]
    /\ convergeAction' = [convergeAction EXCEPT ![h] = "create"]
    /\ UNCHANGED <<phase, convergeResult, rollbackCount>>

\* All hosts prepared -> move to converge
AllPrepared ==
    /\ phase = "prepare"
    /\ \A h \in Hosts : hostState[h] = "prepared"
    /\ phase' = "converge"
    /\ UNCHANGED <<hostState, hostSnapshot, convergeResult, convergeAction, rollbackCount>>

\* -----------------------------------------------------------------------
\* Phase 2: Converge (create or modify, may fail)
\* -----------------------------------------------------------------------

ConvergeSuccess(h) ==
    /\ phase = "converge"
    /\ hostState[h] = "prepared"
    /\ hostState' = [hostState EXCEPT ![h] = "converged"]
    /\ convergeResult' = [convergeResult EXCEPT ![h] = "ok"]
    /\ UNCHANGED <<phase, hostSnapshot, convergeAction, rollbackCount>>

ConvergeFail(h) ==
    /\ phase = "converge"
    /\ hostState[h] = "prepared"
    /\ hostState' = [hostState EXCEPT ![h] = "failed"]
    /\ convergeResult' = [convergeResult EXCEPT ![h] = "error"]
    /\ UNCHANGED <<phase, hostSnapshot, convergeAction, rollbackCount>>

AllConverged ==
    /\ phase = "converge"
    /\ \A h \in Hosts : hostState[h] \in {"converged", "failed"}
    /\ IF \A h \in Hosts : convergeResult[h] = "ok"
       THEN phase' = "verify"
       ELSE phase' = "rollback"
    /\ UNCHANGED <<hostState, hostSnapshot, convergeResult, convergeAction, rollbackCount>>

\* -----------------------------------------------------------------------
\* Phase 3a: Verify (all succeeded)
\* -----------------------------------------------------------------------

VerifyDone ==
    /\ phase = "verify"
    /\ \A h \in Hosts : hostState[h] = "converged"
    /\ hostState' = [h \in Hosts |-> "verified"]
    /\ phase' = "done"
    /\ UNCHANGED <<hostSnapshot, convergeResult, convergeAction, rollbackCount>>

\* -----------------------------------------------------------------------
\* Phase 3b: Rollback
\*
\* Modified datasets: zfs rollback to pre-converge snapshot.
\* Created datasets: zfs destroy (undo the create).
\* Failed datasets: no-op (changes never applied, or create failed).
\* -----------------------------------------------------------------------

\* Rollback a MODIFIED dataset that was converged: zfs rollback
RollbackModified(h) ==
    /\ phase = "rollback"
    /\ hostState[h] = "converged"
    /\ convergeAction[h] = "modify"
    /\ hostSnapshot[h] = "pre-converge"
    /\ hostState' = [hostState EXCEPT ![h] = "rolled_back"]
    /\ rollbackCount' = rollbackCount + 1
    /\ UNCHANGED <<phase, hostSnapshot, convergeResult, convergeAction>>

\* Rollback a CREATED dataset that was converged: zfs destroy
RollbackCreated(h) ==
    /\ phase = "rollback"
    /\ hostState[h] = "converged"
    /\ convergeAction[h] = "create"
    /\ hostSnapshot[h] = "none"
    /\ hostState' = [hostState EXCEPT ![h] = "rolled_back"]
    /\ rollbackCount' = rollbackCount + 1
    /\ UNCHANGED <<phase, hostSnapshot, convergeResult, convergeAction>>

\* Skip a failed host (changes never applied or create failed)
SkipFailedHost(h) ==
    /\ phase = "rollback"
    /\ hostState[h] = "failed"
    /\ hostState' = [hostState EXCEPT ![h] = "rolled_back"]
    /\ UNCHANGED <<phase, hostSnapshot, convergeResult, convergeAction, rollbackCount>>

\* All hosts rolled back -> protocol failed cleanly
AllRolledBack ==
    /\ phase = "rollback"
    /\ \A h \in Hosts : hostState[h] = "rolled_back"
    /\ phase' = "failed"
    /\ UNCHANGED <<hostState, hostSnapshot, convergeResult, convergeAction, rollbackCount>>

\* -----------------------------------------------------------------------
\* Next-state relation
\* -----------------------------------------------------------------------

Next ==
    \/ StartProtocol
    \/ \E h \in Hosts : PrepareExisting(h)
    \/ \E h \in Hosts : PrepareAbsent(h)
    \/ AllPrepared
    \/ \E h \in Hosts : ConvergeSuccess(h)
    \/ \E h \in Hosts : ConvergeFail(h)
    \/ AllConverged
    \/ VerifyDone
    \/ \E h \in Hosts : RollbackModified(h)
    \/ \E h \in Hosts : RollbackCreated(h)
    \/ \E h \in Hosts : SkipFailedHost(h)
    \/ AllRolledBack
    \/ (phase \in {"done", "failed"} /\ UNCHANGED vars)

\* -----------------------------------------------------------------------
\* Safety invariants
\* -----------------------------------------------------------------------

\* At termination: either ALL verified or ALL rolled back. No partial state.
NoPartialState ==
    phase \in {"done", "failed"} =>
        \/ \A h \in Hosts : hostState[h] = "verified"
        \/ \A h \in Hosts : hostState[h] = "rolled_back"

\* No converged host left behind when any host failed.
NoConvergedWithFailure ==
    (\E h \in Hosts : hostState[h] = "failed") =>
        ~(\E h2 \in Hosts : hostState[h2] = "converged" /\ phase = "done")

\* Rollback action matches the converge action:
\*   modify -> uses snapshot (zfs rollback)
\*   create -> no snapshot (zfs destroy)
RollbackMatchesAction ==
    \A h \in Hosts :
        (hostState[h] = "rolled_back" /\ convergeAction[h] = "modify")
            => hostSnapshot[h] = "pre-converge"

\* -----------------------------------------------------------------------
\* Liveness
\* -----------------------------------------------------------------------

ConvergenceTerminates ==
    <>( phase \in {"done", "failed"} )

\* -----------------------------------------------------------------------
\* Spec
\* -----------------------------------------------------------------------

Spec ==
    /\ Init
    /\ [][Next]_vars
    /\ WF_vars(Next)

=============================================================================
