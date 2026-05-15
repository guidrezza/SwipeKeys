# SwipeKeys

A tiny macOS app that lets `WASD`, arrow keys, and Space work in
trackpad-first games.

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
| `Control` + `Option` + `Command` + `K` | Toggle on/off |

The original key presses still pass through normally. Actions happen around the
cursor.

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

The first run asks for Accessibility permission. Enable SwipeKeys in System
Settings, then open SwipeKeys again.

Use the "Test here" box in the app to confirm the real bindings. Put your
cursor inside the box, then press `WASD`, an arrow key, or Space. SwipeKeys will
show where it posted the actual swipe or tap action.

Press `Command` + `Q` while SwipeKeys is focused to quit.

## License

MIT. See [LICENSE](LICENSE).
