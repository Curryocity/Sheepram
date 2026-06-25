# Sheepram Technical Guide

[← Back to README](README.md)

## Table of Contents

- [Project Components](#project-components)
- [Movement Optimization in Minecraft](#movement-optimization-in-minecraft)
  - [Building the Movement Model](#building-the-movement-model)
  - [Objective Function](#objective-function)
  - [Constraints](#constraints)
  - [Unknown Variables](#unknown-variables)
- [Optimization Algorithm](#optimization-algorithm)
  - [From Constrained to Unconstrained Optimization](#from-constrained-to-unconstrained-optimization)
  - [ALM Algorithm](#alm-algorithm-outer-loop)
  - [Inner Loop](#inner-loop)
  - [Pseudocode](#pseudocode)
- [Future Prospects](#future-prospects)
  - [Significant Angles](#significant-angles)
  - [Global Search and Solver Reliability](#global-search-and-solver-reliability)
  - [Discrete Movement Decisions](#discrete-movement-decisions)

## Project Components

The system consists of these main components:

- **Numerical optimization engine**: `src/optimizer/optimizer.odin`
- **DSL package**: `src/dsl/` contains the shared lexer, optimization problem language, and Mothball movement language.
- **Application startup and rendering loop**: `src/main.odin`
- **GUI built with Dear ImGui**: `src/app/gui.odin`

## Movement Optimization in Minecraft

### Building the Movement Model

Our optimization problems are built on the **Minecraft horizontal movement model**. The full formulas can be found on the [Mcpk Wiki](https://www.mcpk.wiki/wiki/Horizontal_Movement_Formulas).

Horizontal velocity follows the following “linear” recurrence relation (with trigonometric terms):

$$
\begin{aligned}
Vx[t + 1] &= drag[t] \cdot Vx[t] + accel[t] \cdot \sin(\theta_t) \\
Vz[t + 1] &= drag[t] \cdot Vz[t] + accel[t] \cdot \cos(\theta_t)
\end{aligned}
$$

where

- $\theta_t$ is the player’s facing angle at tick $t$
- $drag[t]$ depends on block slipperiness
- $accel[t]$ depends on the player’s movement state (ground, air, sprint, etc.)

Position is then obtained by summing the velocity at each tick:

$$
\begin{aligned}
X[t] &= X[t-1] + Vx[t-1] \\
Z[t] &= Z[t-1] + Vz[t-1]
\end{aligned}
$$

Sheepram assumes that:

- the **block type** at each tick is known
- the **movement method** at each tick (ground, air, etc.) is predetermined

This avoids introducing additional discrete variables into the optimization problem.

### Objective Function

For most Minecraft Onejump problems, the goal is to minimize or maximize movement along a particular axis. A common **objective function** is:

$$
X[n] - X[mm]
$$

where $n$ denotes the last tick of the simulation, and $mm$ denotes the last momentum tick, that is, the tick just before the player leaves the takeoff block.

### Constraints

From the perspective of stratfinding, Minecraft jumps can roughly be divided into three categories (excluding gimmick-based cases):

- **Single-Axis Distance Jump**:
  These jumps are already **solved**. Their strategies can be derived using explicit formulas and algorithms. (As shown in my GitHub repo: [Stratfinder](https://github.com/Curryocity/Stratfinder)) This is mainly because in most cases $\theta = 0$, so the movement formula reduces to a purely linear function.

- **Double-Axis Distance Jump**:
  These jumps are only partially **solved**. The reason they are not fully solved is that the main direction of the run-up and the main direction after takeoff are not necessarily aligned, so finding the optimal interpolation between the two directions becomes quite complicated. These cases, as well as the next category, Neo, require numerical methods.

- **Neo**:
  This is the rabbit hole of Onejump stratfinding. It broadly refers to jumps that require wrapping around obstacles such as walls or corners. Much like turning in an acceleration-based racing game, the optimal route is not simply the geometric boundary. Instead, it is a trade-off between short-term distance loss and later velocity gain.

One major reason constraints are needed is precisely to describe Neo problems. Intuitively, we want the player to go around a wall and then move as far left (negative $X$) as possible after passing it.

> **A missing image of c4.5 p2p in-game with path visualization**

The constraints are used to **encode** what it means to “go around the wall.” In the example above, this can be written as:

```Sheepram
// At t = m, the player first reaches the +X side of the pillar
X[m] - X[0] > 7/16

// At t = m2, the player is about to wrap to the -X side of the pillar on the next tick
X[m2] - X[0] > 7/16

// Describes the pillar's length in the Z direction
// m-1 is used because Minecraft updates player X before Z
Z[m2] - Z[m-1] > 1 + 0.6000000238418579

// Here m = 2, m2 = 8
// Player hitbox width = 0.6f (f32)
```

### Unknown Variables

Since $drag[t]$, $accel[t]$, and the initial conditions are numerically known in advance, Sheepram simplifies / compiles every expression into a function that depends only on the $\theta_t$'s. More specifically, it reduces them to the form

$$
f(\theta) =
c +
\sum_i a_i \theta_i +
\sum_i b_i \sin(\theta_i) +
\sum_i d_i \cos(\theta_i)
$$

So the unknown variables are simply the player’s **facing angles** at each tick:

$$
\theta_0, \theta_1, \dots, \theta_{n-1}
$$

This representation allows the solver to compute **objective values** and **constraint values** efficiently, without re-evaluating the full movement model during every optimization step. In addition, it allows the gradient to be computed directly:

$$
\frac{\partial f}{\partial \theta_i} = a_i + b_i \cos(\theta_i) - d_i \sin(\theta_i)
$$

so numerical differentiation is not needed.

## Optimization Algorithm

> **Overall idea:** Convert the constrained problem into an unconstrained one, then optimize it using methods such as gradient descent, quasi-Newton methods, or Newton’s method.

### From Constrained to Unconstrained Optimization

Consider a constrained optimization problem:

$$
\begin{aligned}
\min_{\theta} \quad & f(\theta) \\
\text{subject to} \quad & g_i(\theta) \le 0
\end{aligned}
$$

The classical approach introduces **Lagrange multipliers**:

$$
L(\theta,\lambda) = f(\theta) + \sum_i \lambda_i g_i(\theta)
$$

At the optimal solution, the **KKT conditions** must hold.
**However, directly solving the KKT system is often difficult in practice**, so the multipliers $\lambda_i$ are not easy to solve for directly.

#### Candidate Alternative: Penalty Method

One idea is to introduce a **penalty term** $\rho$ to penalize solutions that violate the constraints:

$$
\min_\theta f(\theta) + \rho \sum_i \max(0,g_i(\theta))^2
$$

But this has a major drawback: when $\rho$ becomes large, the optimization problem becomes **numerically ill-conditioned**, and convergence becomes unstable.

#### Augmented Lagrangian Method (ALM)

The **Augmented Lagrangian Method** combines the ideas of the penalty method and Lagrange multipliers.

Its core idea is not to solve for $\lambda$ analytically, but to **iteratively update and learn $\lambda$** through the additional penalty term.

The augmented Lagrangian is defined as:

$$
L(\theta,\lambda) =
f(\theta)
+
\sum_i \lambda_i g_i(\theta)
+
\frac{\rho}{2}\sum_i \max(0,g_i(\theta))^2
$$

where $\lambda_i$ are the Lagrange multipliers and $\rho$ is the penalty parameter.

### ALM Algorithm (Outer Loop)

#### Step 1: Solve the unconstrained subproblem

For fixed multipliers $\lambda$ and penalty parameter $\rho$, minimize

$$
\min_\theta L(\theta,\lambda)
$$

This subproblem can be solved using any unconstrained optimization method. Solving this subproblem is what we call the inner loop iteration.

The goal of the inner loop is to approach **stationarity**, that is,

$$
\nabla_\theta L(\theta,\lambda) \approx 0
$$

#### Step 2: Update multipliers

After obtaining the current solution $\theta$, update the multipliers as

$$
\lambda_{i,\text{new}} =
\max\left(0,\lambda_i + \rho g_i(\theta)\right)
$$

When a constraint is violated, this update increases the corresponding multiplier.

#### Step 3: Adjust the penalty parameter

If the constraint violation is still large, increase the penalty parameter $\rho$ to enforce the constraints more strongly.

#### Step 4: Repeat until convergence

The **outer loop** keeps updating the multipliers and penalty parameter, gradually pushing the solution toward **constraint feasibility**. Once the constraint violation falls below a specified tolerance, the algorithm stops.

At that point, the solution approximately satisfies the **KKT conditions**.

### Inner Loop

The **inner loop** minimizes the Augmented Lagrangian and drives the solution toward **stationarity**. It terminates when the gradient of the Augmented Lagrangian becomes sufficiently small. Common methods for this type of unconstrained optimization problem include:

#### 1. Gradient Descent

This method repeatedly moves in the locally best linear descent direction, that is, the negative gradient.

It is computationally cheap because it only requires gradient evaluations. This makes it suitable for problems with very many parameters, such as machine learning, where second-order information is too expensive to compute.

However, it usually achieves only **linear convergence**, which becomes slow when high precision is needed.

#### 2. Newton’s Method

This method locally approximates the objective function with a quadratic function, then moves toward that extremum.

Near the optimum, it has **quadratic convergence**, but it also has several drawbacks:

- computing the Hessian matrix is expensive
- computing its inverse is also expensive
- the Hessian may be indefinite (pointing toward a non-minimum)

#### 3. Quasi-Newton: A Middle Ground

Quasi-Newton methods iteratively approximate the inverse Hessian using lighter-weight updates, while still achieving **superlinear convergence**.

**The quasi-Newton method used in Sheepram is BFGS**.

It works by maintaining an approximation $H$ of the inverse Hessian.

1. **Secant condition**:

   The updated inverse Hessian approximation must satisfy the secant equation at the current iteration:

$$
H \Delta grad(f) = \Delta \theta
$$

2. **Symmetry**:

   Like the inverse Hessian, the approximation matrix must remain symmetric.

3. **Least-change principle**:

   Among all matrices satisfying the secant condition, BFGS chooses the one “closest” to the previous inverse Hessian approximation.

   The idea is to preserve as much gradient information from previous iterations as possible. The exact meaning of “closest” depends on the particular quasi-Newton method.

**BFGS Update Formula**

Combining the three conditions above leads uniquely to the BFGS update formula:

$$
H_{k+1} =
\left(I - \rho_k s_k y_k^T\right)
H_k
\left(I - \rho_k y_k s_k^T\right)
+
\rho_k s_k s_k^T
$$

where

$$
s_k = \theta_{k+1} - \theta_k ,\quad
y_k = \nabla f_{k+1} - \nabla f_k ,\quad
\rho_k = \frac{1}{y_k^T s_k}
$$

I will not discuss the full derivation here (see [8.2 Quasi Newton and BFGS](https://youtu.be/QGFct_3HMzk?si=vemD5LnGdvlkR7mw)), but this is my intuition:

1. the sandwich structure $AHA^T$ preserves symmetry
2. the two “bread” terms in the sandwich only apply a rank-two update to $H$, so the change is minimal
3. the $\rho_k s_k s_k^T$ term adds new curvature information and ensures the secant condition is satisfied

#### Line Search

As mentioned in this video:
[Understanding scipy.minimize part 2: Line search](https://youtu.be/kM79eCS9cs8?si=67L2rNwh0u_D-BfG)

Modern numerical libraries usually **do not move directly to the minimizer predicted by the inverse Hessian approximation**. Instead, they treat it as a reference direction, and perform a **line search** along that direction to determine a suitable step length $\alpha_k$:

$$
\theta_{k+1} = \theta_k + \alpha_k p_k
$$

The purpose of line search is to ensure the quality of each iteration (**Wolfe conditions**):

1. the objective decreases sufficiently (**Armijo condition**)
2. the slope becomes sufficiently small; otherwise we should keep moving forward (**curvature condition**)

Line search is important in practice because it helps prevent divergence when the local quadratic model is inaccurate.

In my project, I use a weaker line search implementation than SciPy: its zoom phase mainly uses binary search instead of polynomial interpolation. I will not go into those details here.

### Pseudocode

```text
initialize θ, λ, rho

loop:
    construct L(θ, λ)
    loop:
        compute ∇L(θ, λ)
        compute BFGS search direction p
        choose step length α by line search
        update θ ← θ + αp
        update inverse Hessian approximation H
    end-if stationarity is reached

    update λ_i ← max(0, λ_i + rho * g_i(θ))

    if constraint violation is still large:
        increase rho
end-if feasibility are reached

return θ, trajectory, objective value
```

## Future Prospects

### Significant Angles

Minecraft angles are not truly continuous. Minecraft’s trigonometric functions rely on a lookup table with 65,536 precomputed values.

```cpp
static void init(){
    for (int i = 0; i < 65536; ++i)
        SIN_TABLE[i] = std::sin(i * PId * 2.0 / 65536.0);
}

static inline float sinr(float rad){
    return SIN_TABLE[(int)(rad * 10430.378f) & 65535];
}

static inline float cosr(float rad){
    return SIN_TABLE[(int)(rad * 10430.378f + 16384.0f) & 65535];
}
```

Therefore, the movement produced by an angle is piecewise constant with respect
to that angle. Two nearby yaw values may use the same table entry, while
crossing a lookup boundary causes a small discontinuous change. The effective
angular resolution of the table is

$$
\frac{360^\circ}{65536} \approx 0.005493^\circ.
$$

The current optimizer deliberately ignores this quantization and solves a
smooth, continuous relaxation using `sin` and `cos`. This is useful for finding
the overall shape of a strategy, but simply rounding every resulting angle to
its nearest lookup-table entry is not always sufficient. A tiny change at one
tick propagates through all later velocities and positions, and may turn a
barely feasible solution into one that clips the obstacle.

A promising approach is therefore a **hybrid continuous-discrete solver**:

1. Solve the continuous relaxation with ALM and BFGS.
2. Convert the continuous solution into nearby lookup-table indices.
3. Refine those indices with a discrete local search.
4. Re-evaluate the final candidate with Minecraft-compatible `f32` arithmetic
   and lookup-table trigonometry.

Several discrete refinement methods are worth exploring:

- **Coordinate descent**: change one tick's angle at a time and keep an
  improvement.
- **Limited-window 2-opt**: jointly search pairs of angles within a small tick
  window, capturing interactions that single-angle updates miss.
- **Simulated annealing**: occasionally accept a worse candidate so the search
  can escape local optima created by quantization.

The continuous solution would act as a strong starting point rather than being
discarded. This keeps the discrete search concentrated around strategically
meaningful routes instead of searching all $65536^n$ angle sequences.
