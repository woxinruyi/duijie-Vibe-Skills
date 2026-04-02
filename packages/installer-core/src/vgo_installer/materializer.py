from .ledger_service import MaterializationLedgerState


def empty_materialization_state() -> MaterializationLedgerState:
    return MaterializationLedgerState()
