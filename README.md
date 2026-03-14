# Sheepram

![Sheepram Icon](readmeResource/Sheepram.png)

Sheepram is a tool for solving **Minecraft Onejump angle optimization problems**

## Guide

### 1. Model (Drags & Accels Table)

The solver assumes you already know the movement state on each tick.  
Sheepram optimizes the **angles only**.

### 2. Objective Function

This is the value you want to optimize.

Examples:

- `X[n]`
- `Z[n]`
- a custom expression written in the scripting language

### 3. Global Variables

Optional, but useful for:

- reusing constants
- defining indices relative to something else

### 4. Constraints

You can write constraints using the custom scripting language.

Supported indexed variables:

| Variable | Meaning |
| -------- | ------- |
| `X[i]`   | X position at tick `i` |
| `Z[i]`   | Z position at tick `i` |
| `Vx[i]`  | X velocity: `X[i+1] - X[i]` |
| `Vz[i]`  | Z velocity: `Z[i+1] - Z[i]` |
| `F[i]`   | Facing angle (degrees) |
| `T[i]`   | Turn: `F[i+1] - F[i]` |

Example:

```txt
// Every non-comment line is parsed as a constraint

F[1] - F[0] = -45
// Equivalent to T[0] = -45
// Probably useful in noja

X[m] - X[0] > 8/16
// m must be defined in the table above

X[m2] > 0.5
// Since X[0] and Z[0] are always 0, you can omit them
// Yes, something goofy like X[X[X[X[0]]]] still compiles

Z[m2] - Z[m-1] > 1 + 0.6
Z[n] - Z[m-1] < 1.5625 + 0.6

Vz[it] < 0.005/0.91
// Means you hit inertia on X while tick = it in the air
// You should also set dragX = 0 on that tick
```

Nonlinear expressions such as `X[1] * X[2]` are not supported and will not compile.

### **5. Postprocessor:** 
- Shift the coordinate origin (affects the output table and plot)
- Change table precision
- Change the angle offsets (affects manual copy section)

## Tips

### Resizing

* You can resize the constraint panel vertically
* You can drag the divider between the input and output panels

### Table insertion / deletion

You can select a slot in the table (both in the model table and the global variables table), then press the `+` or `-` button.

### Plot hover

Hovering over a plotted point shows information for that tick.

### Global variable declaration order

Variables are declared in the following order:

`n` → `initV` → table entries from left to right

A later variable may use previously defined variables.
Redefining a variable overwrites the old value.

### Preview (`low Z h2h.json` by HammSamichz)

![Preview](readmeResource/showcase.png)

## Installation

Download the `.zip` for your platform from the latest release.

### macOS

1. Unzip the downloaded file
2. Drag `Sheepram.app` into `Applications`
3. Open `Sheepram.app`

### Windows

1. Unzip the downloaded file
2. Open the extracted folder
3. Double-click `Sheepram.exe`

Keep all shipped files in the extracted folder:

* `Sheepram.exe`
* `asset/`
* `presets/`
* bundled `.dll` files

### Known Issues (Windows)

#### Error

`GLFW Error 65544: WGL: Failed to make context current: The handle is invalid.`

This can happen on dual-GPU laptops (integrated + discrete GPU) when Windows runs the app on the wrong GPU path.

#### Fix

1. Open `Settings` → `System` → `Display` → `Graphics`
2. Add `Sheepram.exe`
3. Click `Options`
4. Choose `High performance`
5. Save and restart the app

If needed, also force `Sheepram.exe` to use the discrete GPU in the NVIDIA / AMD control panel.

### Linux

1. If downloaded from workflow artifacts, unzip first to get `Sheepram-<version>-linux-x86_64.tar.gz`
2. Extract `Sheepram-<version>-linux-x86_64.tar.gz`
3. Open a terminal in the extracted folder
4. Run:

```bash
chmod +x Sheepram
./Sheepram
```

`Sheepram` is the launcher script. It loads bundled libraries from `lib/` before starting `Sheepram.bin`.

Optional launcher:

```bash
chmod +x Sheepram.desktop
```

Then open `Sheepram.desktop` from your desktop environment.

## User Data Location

Sheepram stores preferences and presets in the user data directory:

* macOS: `~/Library/Application Support/Sheepram`
* Windows: `%APPDATA%\Sheepram`
* Linux: `~/.local/share/Sheepram`

