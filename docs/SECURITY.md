# Security assumptions and validation

This is the builder's implementation review and test evidence, not an independent
audit. A separate contributor must review the accepted source and final manifest
before launch, including `$owner` and the one-time WAKE binding. This assignment
does not deploy or attest the contracts.

## Authority and custody

- The immutable owner can set WAKE once, add burial tokens and deposit funds.
  It cannot withdraw deposits, remove tokens, redirect rewards, change the reward
  rate, pause, upgrade or transfer ownership. The constructor uses its explicit
  argument rather than the factory or transaction origin.
- Correct WAKE selection is a trust boundary. Code presence does not prove token
  identity. The owner must use the actual accepted LaunchToken from the handoff.
- The owner controls which tokens earn rewards forever. It could admit a token
  it can mint or distribute, and any user could split token dust among many
  wallets. Such participants receive the same reward as other qualifying wallets.
  "No withdrawal" does not eliminate this economic trust in token admission.
- There is no minimum token amount other than a positive balance, no identity
  verification, and no promise that a reward has market value. No off-chain
  funding commitment is enforced. No randomness or price oracle is used.
- Direct donations immediately affect reward math. A reward preview can change
  through transaction ordering. A zero reward still consumes a burial right.
- Unsupported/reverting tokens cannot be removed from the enumeration. The UI
  should isolate failures and users should omit broken tokens from batches.

## External calls and accounting

All seven mutating application methods share a reentrancy guard. Burial and flower
records are written before transfer interactions; any error reverts all state and
token movements. The only burn destination is the fixed DEAD address. The sender
passed to the internal transfer helper always originates from `msg.sender`, and
rewards always return to that same caller.

SafeERC20 checks ERC-20 return data. Balance changes are additionally checked for
burials, flowers and vault funding. A taxed token that returns true still cannot
receive a reward with an incorrect burn. A token with dishonest balance reports
can defeat any check based on its own reports; the consecration trust boundary is
therefore necessary. Plain WAKE is assumed after the owner binds LaunchToken.

Each reward is `V / 2000`, avoiding multiplication overflow and rounding down.
With a positive vault, subtraction of this reward always leaves at least one minor
unit. A batch recomputes from the actual vault before each burial. The selected
token's decimals do not enter the calculation. Flowers spend the caller's balance
and do not alter vault accounting or burial counts. Transfers to DEAD preserve
the ERC-20 total supply while making those balances operationally inaccessible.

Neither contract contains external library linking, a proxy, delegatecall,
callcode, selfdestruct, native-asset transfers, or arbitrary external execution.
Constructors make no calls to already deployed contracts. Unexpected ETH or other
tokens have no rescue path. First burial timestamps only label records; timestamps
do not authorize payouts or provide randomness.

## Validation performed

The local Foundry suites exercise success and failure paths, including:

- Fixed supply, metadata, exact ERC-20 transfers, allowances and absent mint/admin
  selectors, including attempted calls from the original deployer.
- Factory-style CREATE2 deployment, whole supply retained by the factory,
  explicit owner, empty-chain constructors, EIP-170 size and an opcode scan that
  skips PUSH data and rejects DELEGATECALL, CALLCODE and SELFDESTRUCT.
- Unconfigured operations, owner-only setters/funding/consecration, one-time WAKE,
  duplicate/invalid admission and exclusion of WAKE.
- Whole balances, varied decimals, exact 0.05% decay, integer boundaries, empty
  funding, 1..50-token batches, duplicates and atomic rollback on late failures.
- Failed WAKE payouts reverting the dead-token transfer and allowing retry.
- Epitaph authorship, one-time empty text, 64-byte limit and multi-byte UTF-8;
  positive flowers, allowance failures and independent reward-vault accounting.
- No-return ERC-20 success; false returns, reverting transfers, no-op transfers,
  taxation and reflection rejected without reward or record changes.
- Reentrant attempts against every mutation from a burial transfer, and callback
  attempts during funding, reward payout and flowers; both caught callbacks and
  propagated failures are tested.
- Fuzzed complete balances, all uint256 reward-balance sizes, sequential reward
  conservation, plus stateful sequences checking balances, wallet records,
  tombstone records, distinct counts and immutable settings.

Tests use the task's seed
`0xaf91a810c005e3e3370e6c64041c2c4ea3808ceab7892637ab5a32b83a78e911`.
No live chain or production wallet was used. Slither and Mythril were not run.
The supplied protected checks are read-only inputs; their service-provided
environment is not fabricated here. Local deployment tests cover the same
constructor/supply/owner/opcode floor without reading environment variables.

Forge's heuristic lint flags external calls and reverts inside the bounded burial
loop and the internal transfer helper's `from` argument. These are reviewed:
atomic per-token checks are required, all entry points are guarded, and the helper
is private with only caller-derived senders. The tests exercise these boundaries.

## Operational responsibilities

Launch services publish, attest, admit, deploy and verify the accepted artifacts.
The manifest contributor provides the final contract list and constructor values;
the independent reviewer checks it against the implementation and launch policy.
The owner verifies and locks the WAKE address, vets consecrated tokens, funds the
vault and retains the admin key. The frontend/indexer handles token metadata
failures, gas estimation, receipt indexing, reorganizations and text escaping.
Users approve and authorize each irreversible burial or flower transfer.
