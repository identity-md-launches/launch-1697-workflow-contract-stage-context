# A Funeral For Every Dead Token

WAKE rewards for sending the full balance of a consecrated ERC-20 to
`0x000000000000000000000000000000000000dEaD`.

This deliverable implements the contract stage: Solidity sources, local tests,
vendored dependencies, ABI exports and integration documentation. The separate
manifest assignment produces `launch.json`; independent review, publication,
attestation, admission, deployment and the IPFS frontend follow through launch
services. No deployment transaction or wallet key is needed to build or test.

## Build and verify

Run from this repository's root with Foundry and Solidity **0.8.26** installed:

```sh
forge build
FOUNDRY_FUZZ_SEED=0xaf91a810c005e3e3370e6c64041c2c4ea3808ceab7892637ab5a32b83a78e911 forge test
forge fmt --check
python3 scripts/export_abis.py --check
```

The compiler is pinned by version in `foundry.toml`, with optimization at 200 runs,
Cancun EVM and `bytecode_hash = "none"`. There is no FFI, filesystem permission,
external library link, submodule, environment-dependent test, or RPC dependency.
OpenZeppelin Contracts v5.0.2 (the required source subset) and forge-std v1.9.7
are included as ordinary files in `lib/`, with upstream licenses and provenance.
The verifier provides the pinned compiler offline; no compiler binary is shipped.

Unit and adversarial tests cover permissions, full-balance transfers, reward
decay and rounding, atomic batches, epitaphs, flowers, failed payouts, nonreturning
tokens, rejected taxed/no-op tokens, callbacks and the launch deployment floor.
Fuzz tests run 512 cases each. Two stateful invariants run 128 sequences of up to
64 actions each, mixing funding, donations, burials, flowers and epitaphs while
checking conservation and all aggregate records. See [security notes](docs/SECURITY.md).

## Deployment parameters

| Contract | Source | Constructor arguments |
| --- | --- | --- |
| `LaunchToken` | `src/LaunchToken.sol` | None |
| `Graveyard` | `src/Graveyard.sol` | `address initialOwner = $owner` |

For this launch, `$owner` resolves to
`0x5cf93685a808af622aa052c17b172ba3043e434f`. The manifest must use `$owner` for
the privileged argument. Neither the factory nor IMD gains an administrative role.
`Graveyard`'s constructor is nonpayable and makes no external calls or code checks;
it can run on an otherwise empty chain. The WAKE binding is an explicit, one-time
owner operation after deployment, as requested in the workflow.

`LaunchToken` is named **A Funeral For Every Dead Token**, symbol **WAKE**, with
18 decimals and exactly **1,000,000,000 WAKE** (`10^27` minor units) minted once
to its deployer, the factory. Transfers are plain ERC-20 transfers. There is no
later mint, owner, tax, pause, blocklist or upgrade. Transfers to DEAD do not
reduce `totalSupply()`.

The factory handles the launch allocation: 10% to the swarm distributor, 87% to
the pool, and 3% to the launch payer or protocol treasury as the launch specifies.
**Graveyard receives no launch allocation.** It starts empty and needs voluntary
post-launch funding; it never mints WAKE. The factory also supplies the distributor
and pool initialization guard; neither is a contributor contract here.

The manifest handoff is Ethereum (chain ID 1), paired with IMD at
`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`, fee **12500 (1.25%)**,
tick spacing **60**, and manifest initial price
`79228162514264337593543950336`. The deployment service derives the effective
opening price from the policy's **2,500 IMD** whole-supply opening market cap
and final token ordering. These pool values do not enter either constructor;
the application adds no trading fee. The frontend must use the pool key in the
deployment handoff.

## After launch

The owner performs these operations with their own wallet:

1. Read the accepted deployment handoff to obtain the actual `LaunchToken` and
   `Graveyard` addresses. Verify the token identity and chain before calling
   **`setWakeToken(LaunchTokenAddress)`** on Graveyard. The address is permanently
   locked. The setter checks that it has code, but cannot prove it is the correct
   launch token; that verification is the owner's responsibility.
2. Inspect the tokens to admit, then call **`consecrate(address[] tokens)`**.
   Token addresses come from the owner's chosen cemetery listings. Only additions
   are possible. WAKE, the cemetery itself, DEAD, addresses without code and
   duplicates are rejected. An empty list reverts. Large lists can be split into
   transactions; the contract imposes no separate consecration count limit.
3. Acquire WAKE from their existing holdings or market, approve Graveyard for the
   desired amount, then call **`fund(amount)`**. The method is owner-only and
   requires a positive amount. Funds cannot be withdrawn. Anyone can also donate
   by transferring WAKE directly to Graveyard; such donations affect rewards but
   do not emit `Funded`. No funding amount or schedule is promised by the contract.

Until step 1, consecration, funding, burial, flowers and `nextReward()` revert
with `WakeNotConfigured`; `canBury()` returns false. No outside oracle, signer,
registry, subscription, relayer or randomness provider is required.

The owner is immutable: no transfer or renunciation is implemented. Loss of its
key prevents new consecrations and, if still unset, WAKE configuration. Existing
burials and direct WAKE donations remain permissionless after configuration.

## Burial and reward rules

Approve Graveyard to spend the entire current balance of each chosen token, then
call `bury(token)` or `buryMany(tokens)`. All amounts are ERC-20 **minor units**;
burial accounting does not assume 18 decimals for dead tokens. Each caller/token
pair can succeed once. Additional tokens received later do not reopen that right.
No one can bury another wallet's tokens using its allowance.

For a vault balance `V`, each burial pays **`floor(V / 2000)`**, exactly the
integer representation of 0.05%. `V` is sampled immediately before the burial
token transfer. For example, 1,000,000 WAKE pays 500 WAKE first and 499.75 WAKE
second, with no intervening funding. The reward does not depend on how many dead
tokens were buried. Every positive balance, even one minor unit, qualifies.

`buryMany` accepts **1–50** entries. It processes them in array order and recomputes
the reward from the remaining vault after each payout. The entire transaction
reverts on an invalid entry, duplicate, inadequate allowance, failed transfer or
failed payout. Earlier burns and records are rolled back too. A positive vault
cannot be emptied by this reward formula: at fewer than 2,000 minor units, rewards
round to zero. **Burial is still allowed with a zero reward**, including an empty
vault, and consumes the one-time burial right. The frontend should prominently
show this before approval and submission.

The burn is a transfer to DEAD, not a token `burn()` call. Both the caller's debit
and DEAD's credit must exactly match the requested amount; otherwise everything
reverts. Fee-on-transfer, reflecting, rebasing-during-transfer or no-op tokens are
unsupported. Paused or blocked transfers fail atomically. SafeERC20 also supports
tokens that correctly transfer but return no bytes. A token can lie in its balance
reports, so admission of trustworthy token contracts remains an owner duty.

Rewards are paid immediately. There is no later claim, refund, timeout, withdrawal
or recovery route. Transaction ordering and intervening funding change a preview;
there is no minimum-reward argument. A confirmed transfer to DEAD is irreversible.
The rule is per wallet, not per person; it deliberately does not prevent Sybil
wallets, splitting dust among wallets, bots or owner participation.

## Epitaphs, flowers and records

The first successful burier of each token permanently receives the right to call
`epitaph(token, text)` once, for up to **64 bytes**. Empty text is allowed and
consumes that right. UTF-8 bytes, not displayed characters, are counted. The
`epitaphWritten` flag distinguishes an empty epitaph from an unused right.

`layFlowers(token, amount)` requires at least one prior burial and a positive
amount. Anyone, including a non-mourner, can approve and send their own WAKE to
DEAD. Flowers neither consume reward funding nor earn rewards. The tombstone
and global totals record the exact amount sent.

`getTombstones(start, count)` returns up to **100** entries in consecration order,
including consecrated tokens with no burials yet. Oversized pages revert; an empty
request or a start beyond the list returns an empty page. The subtraction-based
bound also handles the maximum uint256 start. The cemetery grid may filter on
`mourners > 0`; wallet discovery uses all entries. Sorting is a frontend concern.

`totalTokensBuried` counts tokens with a burial; `totalMourners` counts distinct
wallets; `totalBurials` counts wallet/token pairs. Each tombstone stores first
burier/time, mourner count, total buried, epitaph/flag and flowers. Wallet records
store burial count and cumulative WAKE earned, independent of later transfers or
flowers. Paid-out and flower totals are separate.

There is no payable entry point or ETH receiver. Forced ETH cannot be prevented
by an EVM contract and is unrecoverable here. Tokens other than WAKE accidentally
sent to the cemetery are also unrecoverable.

## Integration handoff

Use [ABI and frontend notes](docs/ABI.md), [LaunchToken ABI](docs/abi/LaunchToken.json)
and [Graveyard ABI](docs/abi/Graveyard.json). Regenerate ABI exports after source
changes with `forge build` followed by `python3 scripts/export_abis.py`.
The later frontend should render token metadata and epitaphs as untrusted text,
simulate transactions, refresh balances and rewards immediately before submission,
and use confirmed `Buried` event rewards for share cards.
