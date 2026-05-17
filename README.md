# SwipeKeys

A tiny macOS app that lets `WASD`, arrow keys, and Space work in
drag-first games.

I made this to play Subway Surfers City on my MacBook after enjoying the game a
bit too much.

Made by [Guilherme Drezza](https://guidrezza.com).

## Controls

| Key | Action |
| --- | --- |
| `W` or Up Arrow | Swipe up |
| `S` or Down Arrow | Swipe down |
| `A` or Left Arrow | Swipe left |
| `D` or Right Arrow | Swipe right |
| Space | Tap |
| `Command` + `Control` + `Option` + `K` | Toggle on/off |

SwipeKeys sends short mouse-drag gestures for swipes and a click for Space. The
original key presses still pass through normally. Actions happen around the
cursor.

Use the mode switch to choose:

- `Mouse Drag`: tiny mouse-down, drag, release, then return the cursor
- `Scroll Swipe`: the older simulated scroll swipe style

Inputs are handled one at a time in a short queue so fast key presses do not
overlap. The queue has a safety cap so accidental spam cannot build up forever,
and toggling off clears pending inputs immediately.

## Install

You need Xcode command line tools or Xcode installed.

```sh
git clone https://github.com/guidrezza/SwipeKeys.git
cd SwipeKeys
./Scripts/build-app.sh
```

This creates:

```sh
dist/SwipeKeys.app
```

Drag `dist/SwipeKeys.app` into your Applications folder, then open it like any
other Mac app.

SwipeKeys needs two macOS permissions:

- Accessibility
- Input Monitoring

Open SwipeKeys, use the `Accessibility` and `Input Monitoring` buttons, enable
both in System Settings, then reopen SwipeKeys if macOS asks you to.

Use the "Test here" box in the app to confirm the real bindings. Put your
cursor inside the box, then press `WASD`, an arrow key, or Space. SwipeKeys will
show an action only when the box receives the actual synthetic swipe or tap.

The window should say `Ready` when global input is working.

Press `Command` + `Q` while SwipeKeys is focused to quit.

## License

MIT. See [LICENSE](LICENSE).
