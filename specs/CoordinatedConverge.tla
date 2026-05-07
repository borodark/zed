--------------------------- MODULE CoordinatedConverge ---------------------------
\* TLA+ specification for Zed's multi-host coordinated convergence protocol.
\*
\* Models the P0 bug found in the dual-Mac runbook (R5): when host B fails
\* mid-converge, host A's successful changes are NOT rolled back. The spec
\* defines the correct 2-phase protocol and proves no execution ordering
\* can leave partial state.
\*
\* To check: tlc CoordinatedConverge.tla
\* Invariant: NoPartialState
\* Liveness: ConvergenceTerminates

EXTENDS Naturals, FiniteSets, Sequences

CONSTANTS
    Hosts,          \* set of host names, e.g. {"mac_248", "mac_247"}
    MaxRetries      \* max rollback retries before giving up (bound for model checking)

VARIABLES
    phase,          \* global protocol phase: "idle" | "snapshot" | "converge" | "verify" | "rollback" | "done" | "failed"
    hostState,      \* function: host -> "clean" | "snapshotted" | "converged" | "verified" | "rolled_back" | "failed"
    hostSnapshot,   \* function: host -> snapshot name or ""
    convergeResult, \* function: host -> "ok" | "error" | "pending"
    rollbackCount   \* number of rollback attempts (bounded for model checking)

vars == <<phase, hostState, hostSnapshot, convergeResult, rollbackCount>>

\* -----------------------------------------------------------------------
\* Initial state: all hosts clean, protocol idle
\* -----------------------------------------------------------------------

Init ==
    /\ phase = "idle"
    /\ hostState = [h \in Hosts |-> "clean"]
    /\ hostSnapshot = [h \in Hosts |-> ""]
    /\ convergeResult = [h \in Hosts |-> "pending"]
    /\ rollbackCount = 0

\* -----------------------------------------------------------------------
\* Phase 1: Snapshot all hosts BEFORE any changes
\* -----------------------------------------------------------------------

\* Take a pre-converge snapshot on one host (atomic per host)
TakeSnapshot(h) ==
    /\ phase = "snapshot"
    /\ hostState[h] = "clean"
    /\ hostState' = [hostState EXCEPT ![h] = "snapshotted"]
    /\ hostSnapshot' = [hostSnapshot EXCEPT ![h] = "pre-converge"]
    /\ UNCHANGED <<phase, convergeResult, rollbackCount>>

\* All hosts snapshotted -> move to converge phase
AllSnapshotted ==
    /\ phase = "snapshot"
    /\ \A h \in Hosts : hostState[h] = "snapshotted"
    /\ phase' = "converge"
    /\ UNCHANGED <<hostState, hostSnapshot, convergeResult, rollbackCount>>

\* Start the protocol: idle -> snapshot phase
StartProtocol ==
    /\ phase = "idle"
    /\ phase' = "snapshot"
    /\ UNCHANGED <<hostState, hostSnapshot, convergeResult, rollbackCount>>

\* -----------------------------------------------------------------------
\* Phase 2: Converge each host (may succeed or fail, independently)
\* -----------------------------------------------------------------------

\* A host converges successfully
ConvergeSuccess(h) ==
    /\ phase = "converge"
    /\ hostState[h] = "snapshotted"
    /\ hostState' = [hostState EXCEPT ![h] = "converged"]
    /\ convergeResult' = [convergeResult EXCEPT ![h] = "ok"]
    /\ UNCHANGED <<phase, hostSnapshot, rollbackCount>>

\* A host fails to converge (ZFS error, permission denied, quota, etc.)
ConvergeFail(h) ==
    /\ phase = "converge"
    /\ hostState[h] = "snapshotted"
    /\ hostState' = [hostState EXCEPT ![h] = "failed"]
    /\ convergeResult' = [convergeResult EXCEPT ![h] = "error"]
    /\ UNCHANGED <<phase, hostSnapshot, rollbackCount>>

\* All hosts have reported (either converged or failed) -> decide
AllConverged ==
    /\ phase = "converge"
    /\ \A h \in Hosts : hostState[h] \in {"converged", "failed"}
    /\ IF \A h \in Hosts : convergeResult[h] = "ok"
       THEN phase' = "verify"         \* all succeeded -> verify
       ELSE phase' = "rollback"        \* any failed -> rollback ALL
    /\ UNCHANGED <<hostState, hostSnapshot, convergeResult, rollbackCount>>

\* -----------------------------------------------------------------------
\* Phase 3a: Verify (all succeeded)
\* -----------------------------------------------------------------------

VerifyDone ==
    /\ phase = "verify"
    /\ \A h \in Hosts : hostState[h] = "converged"
    /\ hostState' = [h \in Hosts |-> "verified"]
    /\ phase' = "done"
    /\ UNCHANGED <<hostSnapshot, convergeResult, rollbackCount>>

\* -----------------------------------------------------------------------
\* Phase 3b: Rollback (any failed -> rollback ALL hosts)
\* -----------------------------------------------------------------------

\* Rollback a converged host to its pre-converge snapshot
RollbackHost(h) ==
    /\ phase = "rollback"
    /\ hostState[h] = "converged"
    /\ hostSnapshot[h] = "pre-converge"
    /\ hostState' = [hostState EXCEPT ![h] = "rolled_back"]
    /\ rollbackCount' = rollbackCount + 1
    /\ UNCHANGED <<phase, hostSnapshot, convergeResult>>

\* A failed host doesn't need rollback (changes never applied)
SkipFailedHost(h) ==
    /\ phase = "rollback"
    /\ hostState[h] = "failed"
    /\ hostState' = [hostState EXCEPT ![h] = "rolled_back"]
    /\ UNCHANGED <<phase, hostSnapshot, convergeResult, rollbackCount>>

\* All hosts rolled back -> protocol failed cleanly
AllRolledBack ==
    /\ phase = "rollback"
    /\ \A h \in Hosts : hostState[h] = "rolled_back"
    /\ phase' = "failed"
    /\ UNCHANGED <<hostState, hostSnapshot, convergeResult, rollbackCount>>

\* -----------------------------------------------------------------------
\* Next-state relation
\* -----------------------------------------------------------------------

Next ==
    \/ StartProtocol
    \/ \E h \in Hosts : TakeSnapshot(h)
    \/ AllSnapshotted
    \/ \E h \in Hosts : ConvergeSuccess(h)
    \/ \E h \in Hosts : ConvergeFail(h)
    \/ AllConverged
    \/ VerifyDone
    \/ \E h \in Hosts : RollbackHost(h)
    \/ \E h \in Hosts : SkipFailedHost(h)
    \/ AllRolledBack
    \/ (phase \in {"done", "failed"} /\ UNCHANGED vars)  \* terminal stuttering

\* -----------------------------------------------------------------------
\* Safety: No Partial State
\*
\* THE PROPERTY THAT R5 VIOLATED: at protocol termination, either ALL
\* hosts are verified (success) or ALL hosts are rolled back (failure).
\* No host is left in "converged" state while another is "failed".
\* -----------------------------------------------------------------------

NoPartialState ==
    phase \in {"done", "failed"} =>
        \/ \A h \in Hosts : hostState[h] = "verified"      \* all succeeded
        \/ \A h \in Hosts : hostState[h] = "rolled_back"   \* all rolled back

\* Stronger: at ANY point during execution, if any host has failed,
\* no host should remain in "converged" without being rolled back.
NoConvergedWithFailure ==
    (\E h \in Hosts : hostState[h] = "failed") =>
        ~(\E h2 \in Hosts : hostState[h2] = "converged" /\ phase = "done")

\* -----------------------------------------------------------------------
\* Liveness: the protocol eventually terminates
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

\* -----------------------------------------------------------------------
\* Model checking configuration
\*
\* In TLC, set:
\*   Hosts <- {"mac_248", "mac_247"}
\*   MaxRetries <- 3
\*   Invariant: NoPartialState /\ NoConvergedWithFailure
\*   Property: ConvergenceTerminates
\* -----------------------------------------------------------------------

=============================================================================
