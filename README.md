# Morpheus Lumerin SessionRouter — self-dealing PoC

Foundry test proving a Lumerin provider can bill the Morpheus funding account for
compute that never happened: the provider opens a session with themselves as the
user, signs their own approval and close receipt, and gets paid from the
funding account. No user != provider check exists in `openSession`/`closeSession`.

Target: LumerinDiamond `0x6aBE1d282f72B474E54527D93b979A4f64d3030a` on Base,
fork pinned to block 58516882.

## Run

```shell
forge test
```

One command, no setup beyond Foundry. The test drains 584.32 MOR from the
funding account across two sessions (292.16 MOR each) and asserts the
funding-account balance drop, the `providersTotalClaimed` growth, and the
attacker's balance. Dependencies under `lib/` are committed as files.

Reported to the Morpheus Bug Bounty Program (devs@mor.org). Keep details
private until the fix is live and disclosure is confirmed.
