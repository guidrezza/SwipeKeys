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

The original key presses still pass through normally. Gestures happen at the
mouse when it is over the game window; otherwise they happen at the center of
the game window.

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

## License

MIT. See [LICENSE](LICENSE).
