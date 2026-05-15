# SwipeKeys

A tiny macOS helper that lets `WASD`, arrow keys, and Space work in
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

The original key presses still pass through normally.

## Install

### Simple Mac app

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

### Command line

You can also run it without making the app:

```sh
swift build -c release
.build/release/swipekeys
```

## Options

```sh
swipekeys --match subway
swipekeys --intensity 24 --repeats 6
```

## License

MIT. See [LICENSE](LICENSE).
