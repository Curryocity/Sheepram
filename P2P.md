## How to optimize c4.5 p2p neo:

### 1. Movement Model

```text
initGnd(0.31695) sj.w sa.wa(11)
```
- `initGnd(0.31695)` sets an initial ground speed of `0.31695 b/t`, based on the maximum-speed c4.5 strategy.
- `sj.w` performs a sprint jump while holding W. (for 1 tick implicitly)
- `sa.wa(11)` sprints in the air while holding W+A for 11 ticks.

### 2. Objective

Minimize:
```text
X[n]
```
In Sheepram’s coordinate system, X decreases toward the left. Because this is a right-side p2p strategy, minimizing `X[n]` finds a route that lands as far left as possible.

`n` is derived automatically from the Mothball script and represents the final movement tick.

### 3. Constraints
```text
X[2] > 0.4375
X[8] > 0.4375
Z[8] - Z[1] > 1 + 0.6
```
Simply minimizing X would make the player face left and move as quickly as possible without completing the neo. The constraints encode what "completing the p2p" means.

1. The player must pass around the right side of the neo:
   ```text
   X[m] > 0.4375
   ```
2. The player must remain on that side until reaching the second clearance tick:
   ```text
   X[m2] > 0.4375
   ```
3. Between these clearance points, the player must travel far enough along Z to clear the one-block obstacle plus the player’s `0.6`-block hitbox:
   ```text
   Z[m2] - Z[m-1] > 1 + 0.6
   ```
For this example, `m = 2` and `m2 = 8` are the best ticks to clear the blockage, and that only requires some simple process of trial and error to figure out.

### Result
```text
Minimum X[n]: -0.005078
```
The c4.5 p2p neo is solved.