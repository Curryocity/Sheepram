# Sheepram

![Sheepram Icon](readmeResource/Sheepram.png)

## Guide

**1. Model (Drags & Accels Table):** The solver assume you know the movement method in every ticks. Sheepram does the angles only.
**2. Objective function:** The objective you are trying to optimize, `X[n]`? `Z[n]`? or a custom one(write it with the script below)?
**3. Global Variables:** Optional, it is useful for reusing constants, and index relative to something.
**4. Constraints**: You can write constraints with the custom scripting language.

Supported indexed variables:

| Variable | Meaning |
| -------- | ------------------------ |
| `X[i]`   | X position at tick i     |
| `Z[i]`   | Z position at tick i     |
| `Vx[i]`  | X vel:  `X[i+1] - X[i]` |
| `Vz[i]`  | Z vel:  `Z[i+1] - Z[i]` |
| `F[i]`   | Facing angle (degrees)   |
| `T[i]`   | Turn: `F[i+1] - F[i]` |

Example:

```
// Every lines except for comments will be parsed into a constraint

F[1] - F[0] = -45
// equivalent to T[0] = -45, probably used it in noja

X[m] - X[0] > 8/16
// m must be defined in the table above

X[m2] > 0.5
// X[0], Z[0] are always 0 so you can skip it
// It maybe means you can write goofy stuffs like X[X[X[X[0]]]] and it still compiles.

Z[m2] - Z[m-1] > 1 + 0.6
Z[n] - Z[m-1] < 1.5625 + 0.6

Vz[it] < 0.005/0.91
// It means you hit inertia on X while tick = it in the air
// You should set dragX = 0 on that tick too
```

Also, nonlinear expression like `X[1] * X[2]` will not compile.

**5. Postprocessor:** 
- Shift the coordinate origin(affects output table and plot)
- Change precision on the table
- Change the angle offsets

## Tips

**Resizing:**
You can resize the constraint panel vertically, and you could drag the bisector of input/output panel.

**Table insertion/deletion:**
You can select a slot in the table(Both in model and global var), press +/- button and should work as you expect.

**Hover the cursor on the plotted point will show the info on that tick**

**Global variable declaration order:**
It is declared in the order `n` → `initV` → table from left to right
The later variable can be define using previous variables.
Redefine a variable will cause an overwrite.

#### Preview('low Z h2h.json' by HammSamichz):

![meow](readmeResource/showcase.png)

## Download

Get the `.zip` for your platform from the latest release.
Workflow artifacts download as a `.zip`
for Linux, that `.zip` contains another `.tar.gz`.

## Install and Run

### macOS

1. Unzip the downloaded file.
2. Drag `Sheepram.app` to `Applications`.
3. Try to open `Sheepram.app`.

### Windows

1. Unzip the downloaded file.
2. Open the extracted folder.
3. Double-click `Sheepram.exe`.

Keep all shipped files in the extracted folder (`Sheepram.exe`, `asset/`, `presets/`, bundled `.dll` files).

### Known Issues (Windows)

- Error: `GLFW Error 65544: WGL: Failed to make context current: The handle is invalid.`

This can happen on dual-GPU laptops (integrated + discrete GPU) when Windows runs the app on the wrong GPU path.

Fix:

1. Open `Settings` -> `System` -> `Display` -> `Graphics`.
2. Add `Sheepram.exe` (from the extracted folder).
3. Click `Options` -> choose `High performance`.
4. Save and restart the app.

If needed, also set `Sheepram.exe` to the discrete GPU in NVIDIA/AMD control panel.

### Linux

1. If downloaded from workflow artifacts, unzip first to get `Sheepram-<version>-linux-x86_64.tar.gz`.
2. Extract `Sheepram-<version>-linux-x86_64.tar.gz`.
3. Open terminal in the extracted folder.
4. Run:

```bash
chmod +x Sheepram
./Sheepram
```

`Sheepram` is the launcher script and loads bundled libraries from `lib/` before starting `Sheepram.bin`.

Optional launcher:

```bash
chmod +x Sheepram.desktop
```

Then open `Sheepram.desktop` in your desktop environment.

## User Data Location

Sheepram stores preferences and presets in your user data directory:

- macOS: `~/Library/Application Support/Sheepram`
- Windows: `%APPDATA%\\Sheepram`
- Linux: `~/.local/share/Sheepram`
