# Contract ABI and frontend integration

The files in `abi/` are ABI arrays exported from the pinned compiler's artifacts.
They include constructors, inherited ERC-20 methods, events and custom errors:

- [LaunchToken.json](abi/LaunchToken.json)
- [Graveyard.json](abi/Graveyard.json)

Amounts are unsigned integer minor units; use bigint or decimal strings, not
JavaScript floating-point numbers. WAKE has 18 decimals. Obtain each dead token's
display metadata separately and tolerate missing or reverting metadata. There
are no overloaded application methods, payable methods, signatures or permit flow.

## LaunchToken

`constructor()` mints `10^27` units to the factory. `name()`, `symbol()`,
`decimals()`, `totalSupply()`, `balanceOf(address)`, `allowance(address,address)`,
`approve(address,uint256)`, `transfer(address,uint256)` and
`transferFrom(address,address,uint256)` follow OpenZeppelin ERC-20 semantics.
Events are the standard `Transfer` and `Approval`. A transfer to DEAD preserves
total supply. No mint, burn, ownership or administrative ABI is exposed.

## Graveyard writes

Constructor: `constructor(address initialOwner)`, to be supplied as `$owner`.
All public mutations use a shared OpenZeppelin reentrancy guard.

| Function | Caller | Effect / return |
| --- | --- | --- |
| `setWakeToken(address token)` | Owner | Set WAKE once; token must have code and cannot be this contract or DEAD |
| `consecrate(address[] tokens)` | Owner | Append nonempty list; invalid or duplicate entries revert atomically |
| `fund(uint256 amount)` | Owner | Transfer positive approved WAKE to vault, irrevocably |
| `bury(address token)` | Any wallet | Burn caller's full approved token balance; return `uint256 reward` |
| `buryMany(address[] tokens)` | Any wallet | Atomically process 1–50 tokens; return `uint256 totalReward` |
| `epitaph(address token,string text)` | First burier | Write once, at most 64 bytes; empty text uses the right |
| `layFlowers(address token,uint256 amount)` | Any wallet | Transfer positive approved WAKE from caller to DEAD on an existing tombstone |

Use exact approvals when feasible. `bury` reads the balance at execution; if a
wallet receives more tokens after approval, an insufficient allowance causes a
revert. There is no way to supply a victim wallet, change the burn recipient or
choose a different reward recipient. Owner `fund` cannot pull from other wallets.

## Graveyard views

| Function | Return / meaning |
| --- | --- |
| `owner()` | Immutable launch owner address |
| `wakeToken()` | Bound WAKE address; zero means unconfigured storage, never a deployment parameter |
| `consecrated(address token)` | Token is permanently admitted |
| `consecratedCount()` | Number of admitted tokens, including those without a burial |
| `hasBuried(address wallet,address token)` | One-time burial right already used |
| `walletRecords(address wallet)` | `(uint256 burials,uint256 wakeEarned)` |
| `getTombstone(address token)` | A `Tombstone` tuple; all-zero/default fields if unknown |
| `getTombstones(uint256 start,uint256 count)` | `Tombstone[]`; count <= 100, in admission order |
| `canBury(address wallet,address token)` | Configured + admitted + not yet buried + positive reported balance; no allowance check |
| `nextReward()` | Current WAKE balance / 2000, rounded down; reverts before configuration |
| `totalBurials()` | Successful wallet/token burial pairs |
| `totalTokensBuried()` | Distinct tokens with one or more burials |
| `totalMourners()` | Distinct wallets with one or more burials |
| `totalWakePaidOut()` | Cumulative burial rewards |
| `totalFlowersBurned()` | Cumulative WAKE sent through `layFlowers` |

`Tombstone` field order is:

```text
address token
address firstMourner
uint256 firstBurialTime
uint256 mourners
uint256 totalBuried
string epitaphText
bool epitaphWritten
uint256 flowers
```

Time is an EVM block timestamp in seconds. A zero timestamp is valid in local
chains; use `mourners > 0` to distinguish a buried token. `canBury` returns false
for a missing token contract or reverting/malformed `balanceOf`, but it cannot
guarantee transferability, token honesty or successful execution. Frontends must
also handle failed RPC calls and gas exhaustion by hostile tokens.

Constant getters are `DEAD()`, `REWARD_DIVISOR()` (2000), `MAX_BURY_BATCH()` (50),
`MAX_PAGE_SIZE()` (100) and `MAX_EPITAPH_BYTES()` (64).

## Events

| Event | Indexed fields | Other fields |
| --- | --- | --- |
| `WakeTokenSet` | `token` | — |
| `Consecrated` | `token` | — |
| `Funded` | `funder` | `amount` |
| `Buried` | `token`, `mourner` | `amount`, `reward` |
| `Epitaph` | `token`, `mourner` | `text` |
| `Flowers` | `token`, `mourner` | `amount` |

Index `Buried` by mourner for personal history; the contract exposes per-wallet
counts and the wallet/token membership predicate rather than an unbounded history
array. Aggregate confirmed `Buried.reward` values for the share card. A batch emits
one event per successful token; a reverted batch emits no persistent events.
Record block/transaction/log identities so an indexer can handle reorganizations.

## Error handling and UI sequence

Configuration and authorization errors: `Unauthorized`, `InvalidAddress`,
`WakeNotConfigured`, `WakeAlreadyConfigured`, `InvalidToken`, `WakeCannotBeBuried`,
`AlreadyConsecrated`. Burial errors: `NotConsecrated`, `AlreadyBuried`,
`EmptyBalance`, `InvalidBatchSize`, `InexactTransfer`. Record errors: `PageTooLarge`,
`NoTombstone`, `NotFirstMourner`, `EpitaphAlreadyWritten`, `EpitaphTooLong`,
`ZeroAmount`. The exported ABI includes each error's argument types. Also handle
inherited `ReentrancyGuardReentrantCall`, SafeERC20/Address failures, ERC-20 errors,
and arbitrary revert data from external tokens.

1. Verify chain and deployment addresses, then enumerate pages of 100 admitted
   tokens. Read connected-wallet balances and `hasBuried`/`canBury` for eligibility.
2. Preview rewards sequentially: repeatedly subtract `V / 2000` from a local copy
   of the vault balance. Explain that another transaction can change the result
   and that zero rewards still consume burial rights.
3. Approve each token for its full balance, refresh balances, then simulate and
   submit `buryMany` batches of at most 50. Smaller batches may be required by gas
   limits or expensive token implementations. Different batches are independent;
   a failed later batch cannot undo earlier confirmed ones.
4. Use receipt events for share totals; refresh vault and wallet records. Show the
   epitaph editor only when the wallet equals `firstMourner` and `epitaphWritten`
   is false. Count encoded UTF-8 bytes client-side. Render all text with escaping.
5. Flowers require a WAKE approval, positive amount, existing tombstone and a
   separate `layFlowers` call. They do not draw from the reward vault.

The owner panel follows the README's **After launch** sequence. There is no
withdraw, claim, pause, ownership transfer or upgrade control to display.
