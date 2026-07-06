## ============================================================================
## SageFS Transaction Manager
## ============================================================================
##
## Phase 3 — Data Integrity & Recovery.
##
## Groups multiple metadata mutations into atomic transactions on top of the
## write-ahead log (journal.sage).  A transaction either commits entirely (all
## its block updates become durable and will be replayed after a crash) or
## aborts (none of its updates are replayed).
##
## Nested transactions
## -------------------
## Complex operations such as `rename` (which touches two directories and an
## inode) are naturally expressed as a parent transaction containing several
## sub-operations.  SageFS uses FLAT nesting with savepoints:
##
##   * A nested `begin()` increments a depth counter and records a savepoint
##     (the number of staged updates at that point).
##   * A nested `commit()` decrements the depth; the real journal COMMIT is
##     only emitted when the OUTERMOST transaction commits.
##   * A nested `abort()` rolls the staged-update list back to its savepoint,
##     discarding just that sub-operation's changes, and marks the outer
##     transaction as poisoned so its eventual commit becomes an abort.
##
## This mirrors SQLite-style savepoints and guarantees all-or-nothing
## semantics for the whole logical operation.
## ============================================================================

from journal import Journal, REC_UPDATE

# ---------------------------------------------------------------------------
# Transaction states
# ---------------------------------------------------------------------------

let TXN_ACTIVE: Int = 0
let TXN_COMMITTED: Int = 1
let TXN_ABORTED: Int = 2

# ===========================================================================
# StagedUpdate — one pending block mutation
# ===========================================================================

class StagedUpdate:
    ## A block update buffered until the transaction commits.
    var target_blk: Int
    var image: Bytes

    proc init(self, target_blk: Int, image: Bytes):
        self.target_blk = target_blk
        self.image = image

# ===========================================================================
# Transaction
# ===========================================================================

class Transaction:
    ## A single logical transaction.  Updates are staged in memory and only
    ## written to the journal (and applied to the device) at commit time.
    var txn_id: Int
    var state: Int
    var depth: Int                  # current nesting depth (1 = outermost)
    var poisoned: Bool              # a nested abort forces the whole txn to abort
    var updates: Array              # Array[StagedUpdate]
    var savepoints: Array           # Array[Int] — updates length per open level

    proc init(self, txn_id: Int):
        self.txn_id = txn_id
        self.state = TXN_ACTIVE
        self.depth = 1
        self.poisoned = false
        self.updates = []
        self.savepoints = []

    proc is_active(self) -> Bool:
        return self.state == TXN_ACTIVE

    proc stage(self, target_blk: Int, image: Bytes):
        ## Buffer a block update.  If the same block is staged twice, the later
        ## image wins (last-write-wins within a transaction).
        var i: Int = 0
        while i < len(self.updates):
            if self.updates[i].target_blk == target_blk:
                self.updates[i].image = image
                return
            i = i + 1
        self.updates.push(StagedUpdate(target_blk, image))

    proc enter(self):
        ## Open a nested level, recording a savepoint at the current update count.
        self.savepoints.push(len(self.updates))
        self.depth = self.depth + 1

    proc leave_commit(self):
        ## Close a nested level successfully (no journal write yet).
        if len(self.savepoints) > 0:
            self.savepoints.pop()
        self.depth = self.depth - 1

    proc leave_abort(self):
        ## Close a nested level, rolling staged updates back to its savepoint
        ## and poisoning the whole transaction.
        if len(self.savepoints) > 0:
            let sp: Int = self.savepoints.pop()
            while len(self.updates) > sp:
                self.updates.pop()
        self.poisoned = true
        self.depth = self.depth - 1


# ===========================================================================
# TransactionManager
# ===========================================================================

class TransactionManager:
    ## Coordinates transactions against a journal and a device.
    ##
    ## `device` must expose `write_block(block_addr, data)`.
    var journal: Any                # Journal instance
    var device: Any
    var current: Any                # the in-flight Transaction, or nil

    proc init(self, journal: Any, device: Any):
        self.journal = journal
        self.device = device
        self.current = nil

    proc begin(self) -> Int:
        ## Begin a transaction, or open a nested level if one is already active.
        ## Returns the (outermost) transaction id.
        if self.current == nil:
            let txn_id: Int = self.journal.begin_txn()
            self.current = Transaction(txn_id)
            return txn_id
        self.current.enter()
        return self.current.txn_id

    proc stage_update(self, target_blk: Int, image: Bytes):
        ## Stage a metadata block update within the current transaction.
        if self.current == nil:
            raise "stage_update called with no active transaction"
        if not self.current.is_active():
            raise "stage_update called on a non-active transaction"
        self.current.stage(target_blk, image)

    proc commit(self) -> Bool:
        ## Commit the current level.  For a nested level this just closes the
        ## savepoint.  For the outermost level it writes all staged updates to
        ## the journal, emits COMMIT (making them durable), then applies them
        ## to the device in place.  Returns true on real commit, false if the
        ## transaction was poisoned and therefore aborted instead.
        if self.current == nil:
            raise "commit called with no active transaction"

        if self.current.depth > 1:
            self.current.leave_commit()
            return true

        ## Outermost commit.
        let txn: Any = self.current
        if txn.poisoned:
            ## A nested abort poisoned us — abort the whole thing instead.
            self.journal.abort_txn(txn.txn_id)
            txn.state = TXN_ABORTED
            self.current = nil
            return false

        ## 1. Write every staged update as a redo record.
        for upd in txn.updates:
            self.journal.log_update(txn.txn_id, upd.target_blk, upd.image)
        ## 2. Emit COMMIT + sync — the durability point.
        self.journal.commit_txn(txn.txn_id)
        ## 3. Apply updates in place now that they are safely logged.
        for upd in txn.updates:
            self.device.write_block(upd.target_blk, upd.image)

        txn.state = TXN_COMMITTED
        self.current = nil
        return true

    proc abort(self) -> Bool:
        ## Abort the current level.  A nested abort rolls back to the savepoint
        ## and poisons the transaction.  An outermost abort discards everything
        ## and emits a journal ABORT record.
        if self.current == nil:
            raise "abort called with no active transaction"

        if self.current.depth > 1:
            self.current.leave_abort()
            return true

        let txn: Any = self.current
        self.journal.abort_txn(txn.txn_id)
        txn.state = TXN_ABORTED
        self.current = nil
        return true

    proc in_transaction(self) -> Bool:
        return self.current != nil

    proc depth(self) -> Int:
        if self.current == nil:
            return 0
        return self.current.depth

    proc recover(self) -> Int:
        ## Delegate crash recovery to the journal: replay all committed
        ## transactions' updates to the device.  Returns blocks rewritten.
        return self.journal.replay()
