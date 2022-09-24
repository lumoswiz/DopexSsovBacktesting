# SSOV V3 Backtesting

** Dopex SSOV backtesting built with Foundry for Arbitrum fork testing of SSOV V3 contracts.**

## Setup

- Install [Foundry](https://github.com/foundry-rs/foundry).
- Configure Foundry for [fork testing](https://book.getfoundry.sh/forge/fork-testing) by ensuring you have a suitable `rpc_endpoint` set up ([guide](https://book.getfoundry.sh/cheatcodes/rpc?highlight=rpc#description)). Two RPC providers: [Alchemy](https://www.alchemy.com/) and [Infura](https://infura.io/).

## Running backtests

- Navigate to [`StrategyTest.t.sol`](./test/StrategyTest.t.sol). User input is required in the `setUp()` function.
- **Variables**:

  - `ssov`: contract address of the SSOV V3 to run backtests against. _NOTE: I have only currently run backtests against DPX WEEKLY CALLS SSOV V3_.
  - `epoch`: the **_expired_** epoch to run backtests against.
  - Deposit parameters (`depositBlockNumbers`, `depositStrikeIndexes` and `depositAmounts`): - Contracts require the block number, strike index and amount to deposit. To deposit 1 DPX (_1e18 precision_) at strike index 2 and block number 22962396 then the deposit parameter arrays will look like:
    ```sh
    depositBlockNumbers = [22962396];
    depositStrikeIndexes = [2];
    depositAmounts = [1e18];
    ```

- Purchase parameters (`purchaseBlockNumbers`, `purchaseStrikeIndexes` and `purchaseAmounts`):

  - Same rules apply as for deposit parameters. If you want to simulate two purchases, with: Purchase 1: 10 option tokens at strike index 1 at block number 23165341 & Purchase 2: 2 option tokens at strike index 0 at block number 23402497 the purchase parameters will look as follows:

  ```sh
  purchaseBlockNumbers = [23165341, 23402497];
  purchaseStrikeIndexes = [1, 0];
  purchaseAmounts = [10e18, 2e18];
  ```

- _NOTE_: if the desired purchase amount/s exceed the available collateral for the given parameters, the purchase amount will be adjusted to the available collateral and a log will be emitted to indicate this.

- **Testing**:
  - When parameters are input, in command line run:
  ```sh
  forge test --match-test testStrategy -vvv
  ```

## Backtests vs. actual performance

## Acknowledgements

- [Foundry](https://github.com/foundry-rs/foundry). Refer to the [book](https://book.getfoundry.sh/getting-started/installation.html).
- Dopex

```

```

```

```
